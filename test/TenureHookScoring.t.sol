// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

import {HookFixture} from "./utils/HookFixture.sol";
import {SessionVault} from "./utils/TestActors.sol";
import {TenureHook, RebalanceRecord} from "../src/TenureHook.sol";
import {DecisionScore} from "../src/libraries/DecisionScore.sol";
import {Holdings} from "../src/libraries/PositionValue.sol";
import {BudgetState, Tier} from "../src/libraries/RiskBudget.sol";
import {ReferencePriceLib} from "../src/libraries/ReferencePriceLib.sol";

/// @notice M2.4: endRebalance scoring + records, settle() timing/idempotency, alpha sign, afterSwap auto-settle, gas.
contract TenureHookScoringTest is HookFixture {
    uint128 constant L = 1e22;

    function setUp() public {
        _setUpFixture();
    }

    // ================================================================ endRebalance scoring
    function test_rerangeAtFair_storesRecord_leaksOnlyDust() public {
        vm.recordLogs();
        _rebalance(_ops1(-600, 600, int128(L)));
        (uint256 id, int256 leak, uint256 navBefore, uint256 lossW,,,) = _lastScore();
        assertEq(id, 0);
        assertGe(leak, 0, "rounding never favors the curator");
        assertLe(leak, 10, "a re-range at fair spot leaks only rounding dust");
        assertEq(navBefore, 200_000 ether);
        assertLe(lossW, 1);

        RebalanceRecord memory r = hook.recordOf(poolId, 0);
        assertEq(r.newRange.tickLower, -600);
        assertEq(r.newRange.tickUpper, 600);
        assertEq(r.newRange.liquidity, L);
        assertEq(r.oldRange.liquidity, 0);
        assertEq(r.idleOld.amount0, VAULT_FUNDS);
        assertEq(r.navBefore, 200_000 ether);
        assertEq(r.blockNumber, vm.getBlockNumber());
        assertFalse(r.settled);
        assertEq(hook.recordCount(poolId), 1);
    }

    function test_swapAtManipulatedSpot_isChargedImmediately() public {
        BudgetState memory b0 = hook.budgetOf(poolId);
        vm.recordLogs();
        _leakOnce(2000 ether); // sell 2000 token0 ~3% below fair (+0.3% fee)
        (, int256 leak, uint256 navBefore, uint256 lossW,, uint256 budgetAfter, Tier t) = _lastScore();
        // ~3.3% of 2000 = ~66 token1 lost
        assertGt(leak, 60 ether);
        assertLt(leak, 70 ether);
        assertEq(lossW, DecisionScore.lossWad(leak, navBefore), "charged exactly the library's loss fraction");
        assertEq(budgetAfter, b0.budget - lossW);
        assertEq(uint256(t), uint256(Tier.FULL));
    }

    // ================================================================ settle(): timing, idempotency, errors
    function test_settle_tooEarly_reverts() public {
        _rebalance(_ops1(-600, 600, int128(L)));
        uint256 due = vm.getBlockNumber() + WINDOW;
        vm.roll(due - 1);
        vm.expectRevert(abi.encodeWithSelector(TenureHook.Tenure__TooEarly.selector, due));
        hook.settle(poolId, 0);
    }

    function test_settle_atDue_thenIdempotent() public {
        _rebalance(_ops1(-600, 600, int128(L)));
        vm.roll(vm.getBlockNumber() + WINDOW);
        hook.settle(poolId, 0);
        assertTrue(hook.recordOf(poolId, 0).settled);
        assertEq(hook.settlePointer(poolId), 1);
        vm.expectRevert(TenureHook.Tenure__AlreadySettled.selector);
        hook.settle(poolId, 0);
    }

    function test_settle_unknownRecord_reverts() public {
        vm.expectRevert(TenureHook.Tenure__UnknownRecord.selector);
        hook.settle(poolId, 0);
    }

    function test_settle_spotOffFair_reverts() public {
        _rebalance(_ops1(-600, 600, int128(L)));
        vm.roll(vm.getBlockNumber() + WINDOW);
        _pushSpotTo(-300);
        vm.expectRevert(abi.encodeWithSelector(TenureHook.Tenure__SpotOffFair.selector, 300, 100));
        hook.settle(poolId, 0);
    }

    function test_settle_staleOracle_reverts() public {
        _rebalance(_ops1(-600, 600, int128(L)));
        vm.roll(vm.getBlockNumber() + WINDOW);
        (uint160 f,) = oracle.getSqrtPriceX96(poolId);
        oracle.setPriceAt(poolId, f, vm.getBlockTimestamp() - MAX_ORACLE_AGE - 1);
        vm.expectPartialRevert(ReferencePriceLib.Tenure__StalePrice.selector);
        hook.settle(poolId, 0);
    }

    // ================================================================ alpha sign + budget/reputation effects
    /// The killer attack: poisoned curator places liquidity at a manipulated price; attacker trades against it.
    /// No single "theft" happens, but the markout catches it.
    function test_poisonedPlacement_negativeAlpha_chargesBudget() public {
        _pushSpotTo(-600); // attacker manipulates spot ~6% below fair
        _rebalance(_ops1(-900, -300, int128(L))); // curator "follows the market" (within mandate: center 600 <= 3000)
        _pushSpotTo(0); // attacker arbitrages back to fair, buying the vault's token0 cheap

        vm.roll(vm.getBlockNumber() + WINDOW);
        BudgetState memory b0 = hook.budgetOf(poolId);
        int256 expected = _expectedAlpha(0);
        vm.recordLogs();
        int256 alpha = hook.settle(poolId, 0);
        assertEq(alpha, expected, "hook alpha == library alpha on the stored record");
        assertLt(alpha, 0, "picked off => negative alpha");

        (int256 a, uint256 lossW, uint256 gainW, uint256 budget,, Tier t) = _lastSettle();
        assertEq(a, alpha);
        assertEq(gainW, 0);
        assertEq(lossW, DecisionScore.lossWad(-alpha, hook.recordOf(poolId, 0).navBefore));
        assertEq(budget, b0.budget > lossW ? b0.budget - lossW : 0);
        assertLe(uint256(t), uint256(Tier.FROZEN));
    }

    /// Dodging impermanent loss: exit the range to idle right before a move => positive alpha => reputation grows,
    /// but the budget is only scaled (budget/bMax unchanged), never refilled.
    function test_goodExit_positiveAlpha_growsReputationOnly() public {
        _rebalance(_ops1(-600, 600, int128(L))); // record 0
        vm.roll(vm.getBlockNumber() + 10);
        _rebalance(_ops1(-600, 600, -int128(L))); // record 1: exit to idle
        // the market then moves ~5% up (fair and spot)
        oracle.setPrice(poolId, _sqrt(500));
        _pushSpotTo(500);
        vm.roll(vm.getBlockNumber() + WINDOW);

        BudgetState memory b0 = hook.budgetOf(poolId);
        uint256 cap0 = hook.depositCap(poolId);
        int256 alpha = hook.settle(poolId, 1);
        assertEq(alpha, _expectedAlpha(1));
        assertGt(alpha, 0, "exiting before the move beat staying in range");

        BudgetState memory b1 = hook.budgetOf(poolId);
        assertGt(b1.bMax, b0.bMax, "bMax grows with proven alpha");
        assertEq(b1.budget, b0.budget * b1.bMax / b0.bMax, "budget scaled proportionally: no refill");
        assertEq(uint256(b1.tier), uint256(b0.tier), "success never changes the tier");
        assertGt(hook.depositCap(poolId), cap0, "deposit cap grows with proven alpha");
        assertEq(b1.cumAlphaValue, uint256(alpha));
    }

    // ================================================================ afterSwap auto-settle
    function test_afterSwap_autoSettlesDueRecord() public {
        _rebalance(_ops1(-600, 600, int128(L)));
        vm.roll(vm.getBlockNumber() + WINDOW);
        vm.expectEmit(true, true, false, false, address(hook));
        emit TenureHook.MarkoutSettled(poolId, 0, 0, 0, 0, 0, 0, Tier.FULL);
        _smallSwap();
        assertTrue(hook.recordOf(poolId, 0).settled);
        assertEq(hook.settlePointer(poolId), 1);
    }

    function test_afterSwap_notDue_noop() public {
        _rebalance(_ops1(-600, 600, int128(L)));
        vm.roll(vm.getBlockNumber() + WINDOW - 1);
        _smallSwap();
        assertFalse(hook.recordOf(poolId, 0).settled);
    }

    function test_afterSwap_staleOracle_skipsWithoutReverting() public {
        _rebalance(_ops1(-600, 600, int128(L)));
        vm.roll(vm.getBlockNumber() + WINDOW);
        vm.warp(vm.getBlockTimestamp() + MAX_ORACLE_AGE + 1);
        _smallSwap(); // must not revert the trader's swap
        assertFalse(hook.recordOf(poolId, 0).settled);
    }

    function test_afterSwap_spotOffFair_skips() public {
        _rebalance(_ops1(-600, 600, int128(L)));
        vm.roll(vm.getBlockNumber() + WINDOW);
        _pushSpotTo(-300); // this swap itself triggers afterSwap with spot 300 ticks off fair
        assertFalse(hook.recordOf(poolId, 0).settled);
    }

    /// M5.4: at most autoSettlePerSwap (= MAX_AUTO_SETTLE = 1) fee-aware settlement per swap; the rest wait for
    /// later swaps (or a keeper). Was 3 per swap before M5.4 (plan change, not a relaxation: the bound is tighter).
    function test_afterSwap_boundedPerSwap() public {
        assertEq(hook.MAX_AUTO_SETTLE(), 1);
        _makeRecords(5);
        vm.roll(vm.getBlockNumber() + WINDOW);
        for (uint256 k = 1; k <= 5; ++k) {
            _smallSwap();
            assertEq(hook.settlePointer(poolId), k, "exactly one settlement per swap");
            assertTrue(hook.recordOf(poolId, k - 1).settled);
            if (k < 5) assertFalse(hook.recordOf(poolId, k).settled, "the next record waits for the next swap");
        }
    }

    function test_afterSwap_skipsManuallySettled() public {
        _makeRecords(2);
        vm.roll(vm.getBlockNumber() + WINDOW);
        hook.settle(poolId, 1); // out of order: pointer stays at 0
        assertEq(hook.settlePointer(poolId), 0);
        _smallSwap();
        assertEq(hook.settlePointer(poolId), 2);
        assertTrue(hook.recordOf(poolId, 0).settled);
    }

    // ================================================================ gas (afterSwap with 0 / 1 / N due records)
    function test_gas_afterSwap_dueRecords() public {
        _deepSwapWarmup();
        uint256 g0 = _gasOfSmallSwap("afterSwap_0_due");

        _makeRecords(1);
        vm.roll(vm.getBlockNumber() + WINDOW);
        uint256 g1 = _gasOfSmallSwap("afterSwap_1_due");

        _makeRecords(3);
        vm.roll(vm.getBlockNumber() + WINDOW);
        uint256 g3 = _gasOfSmallSwap("afterSwap_3_due");

        console2.log("swap gas, 0 due records:", g0);
        console2.log("swap gas, 1 due record :", g1);
        console2.log("swap gas, 3 due records:", g3);
        // Raised from 150k by human decision (M3.3): fee measurement requires extra cold reads of pool state.
        // Reduction tracked in M5.4. Bound = max(default 193,854; deploy/via-IR 192,771) + 10% = 213,240.
        assertLt(g1 - g0, 213_240, "one fee-aware settlement is bounded");
        // M5.4: auto-settle is capped at ONE record per swap, so 3 due records cost no more than 1 (was < 400k).
        assertLt(g3 - g0, 213_240, "bounded: at most one settlement per swap");
    }

    // ---------------------------------------------------------------- helpers
    function _smallSwap() internal {
        swapper.swapTo(key, true, 1 ether, _sqrt(-100));
    }

    function _deepSwapWarmup() internal {
        _smallSwap();
        swapper.swapTo(key, false, 1 ether, _sqrt(100));
    }

    function _gasOfSmallSwap(string memory name) internal returns (uint256 g) {
        bool zf1 = (vm.getBlockNumber() % 2) == 0;
        swapper.swapTo(key, zf1, 1 ether, zf1 ? _sqrt(-100) : _sqrt(100));
        // Snapshot file is named per build profile: snapshots/TenureHook.<FOUNDRY_PROFILE>.json
        g = vm.snapshotGasLastCall(string.concat("TenureHook.", vm.envOr("FOUNDRY_PROFILE", string("default"))), name);
    }

    /// n cheap re-ranges at fair, alternating ranges, respecting the cooldown.
    function _makeRecords(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            vm.roll(vm.getBlockNumber() + 10);
            uint256 c = hook.recordCount(poolId);
            if (c % 2 == 0) {
                if (hook.currentRange(poolId).liquidity == 0) _rebalance(_ops1(-600, 600, int128(L)));
                else _rebalance(_ops2(-1200, 1200, -int128(L), -600, 600, int128(L)));
            } else {
                _rebalance(_ops2(-600, 600, -int128(L), -1200, 1200, int128(L)));
            }
        }
    }

    function _expectedAlpha(uint256 id) internal view returns (int256) {
        RebalanceRecord memory r = hook.recordOf(poolId, id);
        (uint160 spot,,,) = _slot0();
        (uint160 fair,) = oracle.getSqrtPriceX96(poolId);
        (Holdings memory fCf, Holdings memory fNew) = hook.windowFees(poolId, id);
        return DecisionScore.markoutAlphaWithFees(r.oldRange, r.idleOld, fCf, r.newRange, r.idleNew, fNew, spot, fair);
    }

    function _lastScore()
        internal
        returns (uint256 recordId, int256 leak, uint256 navBefore, uint256 lossW, uint256 movedW, uint256 b, Tier t)
    {
        Vm.Log memory l = _lastLog(TenureHook.RebalanceScored.selector);
        recordId = uint256(l.topics[2]);
        (leak, navBefore, lossW, movedW, b, t) = abi.decode(l.data, (int256, uint256, uint256, uint256, uint256, Tier));
    }

    function _lastSettle()
        internal
        returns (int256 alpha, uint256 lossW, uint256 gainW, uint256 budget, uint256 bMax, Tier t)
    {
        Vm.Log memory l = _lastLog(TenureHook.MarkoutSettled.selector);
        (alpha, lossW, gainW, budget, bMax, t) = abi.decode(l.data, (int256, uint256, uint256, uint256, uint256, Tier));
    }

    function _lastLog(bytes32 sig) internal returns (Vm.Log memory) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; --i) {
            if (logs[i - 1].topics[0] == sig) return logs[i - 1];
        }
        revert("event not found");
    }
}
