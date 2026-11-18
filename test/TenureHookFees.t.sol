// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {VaultFixture} from "./utils/VaultFixture.sol";
import {TenureHook, PoolSettings} from "../src/TenureHook.sol";
import {Holdings, Range} from "../src/libraries/PositionValue.sol";
import {Tier, BudgetState} from "../src/libraries/RiskBudget.sol";
import {TenureDefaults} from "./utils/TenureDefaults.sol";
import {Market, HonestCurator} from "./scenario/ScenarioActors.sol";

/// M3.3: LP fees in the markout, fee-inclusive H_before/H_after, and the honest-curator acceptance run.
contract TenureHookFeesTest is VaultFixture {
    using StateLibrary for IPoolManager;

    uint256 constant Q128 = 1 << 128;

    function _thirdPartyLiquidity() internal pure override returns (uint128) {
        return 2e23; // shallow pool: the vault's range earns a real share of fees
    }

    /// Realistic (default) budget: 2% of NAV, refilled over ~1 day of blocks.
    function _vaultSettings() internal pure override returns (PoolSettings memory s) {
        s = super._vaultSettings();
        s.budget = TenureDefaults.budgetParams();
    }

    function setUp() public {
        _setUpVault();
        _deposit(ALICE, 40_000 ether, 40_000 ether);
    }

    function _churn(uint256 rounds, uint256 amount) internal {
        for (uint256 i; i < rounds; ++i) {
            swapper.swapTo(key, true, amount, TickMath.MIN_SQRT_PRICE + 1);
            swapper.swapTo(key, false, amount, TickMath.MAX_SQRT_PRICE - 1);
        }
        _pushSpotTo(0);
    }

    // ============================================================================ fee estimate is exact
    /// For a position the vault kept untouched, the hook's fee estimate for the new range equals what v4 itself
    /// owes the vault (an independent formula: the position's feeGrowthInsideLast vs. now).
    function test_feesNew_equalsV4FeesOwed_forKeptPosition() public {
        uint256 id = _curatorRebalance(-600, 600, L_RANGE, 0); // from idle: old liquidity 0
        _churn(5, 2_000 ether);
        (Holdings memory fCf, Holdings memory fNew) = hook.windowFees(poolId, id);
        Holdings memory owed = cv.feesOwed();
        assertGt(owed.amount0 + owed.amount1, 1 ether, "fees really accrued");
        assertEq(fNew.amount0, owed.amount0, "token0 fees exact");
        assertEq(fNew.amount1, owed.amount1, "token1 fees exact");
        assertEq(fCf.amount0 + fCf.amount1, 0, "counterfactual (idle) earns nothing");
        // and v4 pays exactly that on collection
        uint256 b0 = _bal0(address(cv));
        vm.roll(vm.getBlockNumber() + 20);
        _curatorRebalance(-600, 600, L_RANGE, 0); // remove (collects fees) + re-add same range
        // remove L rounds the principal down, re-adding L rounds it up: the vault pays at most 1 wei of rounding
        assertLe(_bal0(address(cv)), b0 + owed.amount0, "collected fees never exceed owed");
        assertGe(_bal0(address(cv)) + 1, b0 + owed.amount0, "collected == owed up to 1 wei of v4 rounding");
    }

    /// Regression (found by the 500-block acceptance run): a range the curator abandons BEFORE its markout is
    /// settled must still be credited the fees it really earned. The hook snapshots its fee growth at the exit
    /// point; the credited fees equal exactly what v4 paid the vault on that removal.
    function test_abandonedRange_creditedExactFeesUntilExit() public {
        uint256 id = _curatorRebalance(-600, 600, L_RANGE, 0);
        _churn(5, 2_000 ether);
        Holdings memory owed = cv.feesOwed();
        assertGt(owed.amount0 + owed.amount1, 1 ether);
        vm.roll(vm.getBlockNumber() + 20); // < WINDOW: record `id` is not settled yet
        _curatorRebalance(-1200, 0, L_RANGE / 4, 0); // abandon [-600,600]; its ticks are cleared
        _churn(3, 2_000 ether); // fees after the exit must not be credited to the abandoned range
        (, Holdings memory fNew) = hook.windowFees(poolId, id);
        assertEq(fNew.amount0, owed.amount0, "token0: exactly the fees earned until exit");
        assertEq(fNew.amount1, owed.amount1, "token1: exactly the fees earned until exit");
    }

    /// Fees lift alpha: entering a range from idle with fee-paying flow scores better than it would without fees.
    function test_feesRaiseAlpha_overFeelessMarkout() public {
        uint256 id = _curatorRebalance(-600, 600, L_RANGE, 0);
        _churn(5, 2_000 ether);
        vm.roll(vm.getBlockNumber() + WINDOW);
        (, Holdings memory fNew) = hook.windowFees(poolId, id);
        int256 alpha = hook.settle(poolId, id);
        assertGt(alpha, 0, "uninformed flow + fees: providing liquidity beat staying idle");
        assertGt(fNew.amount0 + fNew.amount1, 0);
    }

    /// Counterfactual fallback: once the old range's ticks are uninitialized (the vault was its only LP and
    /// moved away), the old range is credited liquidity * global fee growth - an upper bound (curator-adverse).
    function test_counterfactualFallback_usesGlobalUpperBound() public {
        _curatorRebalance(-600, 600, L_RANGE, 0);
        vm.roll(vm.getBlockNumber() + 20);
        (uint256 g0, uint256 g1) = poolManager.getFeeGrowthGlobals(poolId);
        uint256 id = _curatorRebalance(-1200, 0, L_RANGE / 4, 0); // old range [-600,600] is abandoned
        (uint128 gross,) = poolManager.getTickLiquidity(poolId, 600);
        assertEq(gross, 0, "old upper tick uninitialized");
        _churn(3, 2_000 ether);
        (uint256 h0, uint256 h1) = poolManager.getFeeGrowthGlobals(poolId);
        (Holdings memory fCf,) = hook.windowFees(poolId, id);
        assertEq(fCf.amount0, FullMath.mulDivRoundingUp(h0 - g0, L_RANGE, Q128), "token0 upper bound");
        assertEq(fCf.amount1, FullMath.mulDivRoundingUp(h1 - g1, L_RANGE, Q128), "token1 upper bound");
    }

    // ============================================================================ fee masking (bug fixed in M3.3)
    /// A no-op-shaped rebalance (same range, same L, fair spot, no swap) after fees accrued must leak ~0.
    /// Before M3.3, H_before excluded the uncollected fees while H_after contained them (collected into idle),
    /// so it scored a NEGATIVE leak of ~ -fees - headroom that could hide a real leak of the same size.
    function test_collectedFees_doNotMaskLeakage() public {
        _curatorRebalance(-600, 600, L_RANGE, 0);
        _churn(5, 2_000 ether);
        Holdings memory owed = cv.feesOwed();
        assertGt(owed.amount0 + owed.amount1, 1 ether, "fees accrued");
        vm.roll(vm.getBlockNumber() + 20);
        vm.recordLogs();
        _curatorRebalance(-600, 600, L_RANGE, 0);
        (int256 leak,,) = _lastScore();
        assertGe(leak, 0, "never a negative leak from collected fees");
        assertLe(leak, 10, "only rounding dust");
    }

    /// A real leak smaller than the accrued fees is still charged (pre-M3.3 it scored <= 0 and was free).
    function test_smallLeak_chargedDespiteCollectedFees() public {
        _curatorRebalance(-600, 600, L_RANGE / 2, 0);
        _churn(5, 2_000 ether);
        Holdings memory owed = cv.feesOwed();
        vm.roll(vm.getBlockNumber() + 20);
        _pushSpotTo(-100); // ~1% below fair
        vm.recordLogs();
        _curatorRebalance(-600, 600, L_RANGE / 2, 300 ether); // sell token0 at the manipulated spot
        (int256 leak, uint256 lossW,) = _lastScore();
        uint256 feeValue = owed.amount0 + owed.amount1; // price ~1
        assertGt(leak, 0);
        assertLt(uint256(leak), feeValue, "leak smaller than the fees it would have hidden");
        assertGt(lossW, 0, "and it is charged");
    }

    // ============================================================================ M3.3 acceptance
    /// Seeded honest curator with normal swap flow (noise trades + arbitrage to a moving fair price) stays FULL
    /// for every one of 500 blocks.
    function test_acceptance_honestStaysFull_500Blocks() public {
        Market market = new Market(poolManager, oracle, swapper, key, 0x7e2a, 40, 2_000 ether);
        HonestCurator h = new HonestCurator(cv, oracle, 600, 120, 30); // re-center beyond 120 ticks: many decisions
        cv.setCurator(address(h));
        assertTrue(h.act());
        uint256 minRatio = type(uint256).max;
        for (uint256 i; i < 500; ++i) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(vm.getBlockTimestamp() + 12);
            market.step();
            h.act();
            BudgetState memory b = hook.budgetOf(poolId);
            uint256 ratio = b.budget * 1e18 / b.bMax;
            if (ratio < minRatio) minRatio = ratio;
            assertEq(uint256(b.tier), uint256(Tier.FULL), "honest curator stays FULL every block");
            assertGe(ratio, 0.5e18, "budget never below the FULL threshold");
        }
        console2.log("honest: actions", h.actions(), "records", hook.recordCount(poolId));
        console2.log("honest: min budget ratio (1e18 = 100%)", minRatio);
        assertGe(h.actions(), 5, "the curator made many decisions");
        assertGt(hook.settlePointer(poolId), 0, "markouts actually settled during the run");
    }

    // ---------------------------------------------------------------------------------------------- helpers
    function _lastScore() internal returns (int256 leak, uint256 lossW, uint256 navBefore) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; --i) {
            Vm.Log memory l = logs[i - 1];
            if (l.emitter == address(hook) && l.topics[0] == TenureHook.RebalanceScored.selector) {
                (leak, navBefore, lossW,,,) = abi.decode(l.data, (int256, uint256, uint256, uint256, uint256, Tier));
                return (leak, lossW, navBefore);
            }
        }
        revert("no RebalanceScored");
    }
}
