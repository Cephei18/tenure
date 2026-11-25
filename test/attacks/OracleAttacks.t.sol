// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {VaultFixture} from "../utils/VaultFixture.sol";
import {TestSwapper} from "../utils/TestActors.sol";
import {ReferencePriceLib} from "../../src/libraries/ReferencePriceLib.sol";
import {CuratedVault} from "../../src/CuratedVault.sol";
import {Tier, BudgetState} from "../../src/libraries/RiskBudget.sol";
import {HonestCurator, Attacker} from "../scenario/ScenarioActors.sol";

/// M5.2 attack suite: the fair-price oracle and the gap between oracle and pool spot.
/// (Vault-level staleness basics live in CuratedVault.t.sol: deposits revert when stale, withdrawals never do.)
contract OracleAttacksTest is VaultFixture {
    int24 constant HALF_WIDTH = 600;

    TestSwapper attackerSwapper;
    Attacker attacker;
    uint256 snap;

    function _thirdPartyLiquidity() internal pure override returns (uint128) {
        return 2e23; // the vault's range dominates near the price (same pool as the M4.1 scenarios)
    }

    function setUp() public {
        _setUpVault();
        _deposit(ALICE, 40_000 ether, 40_000 ether);
        attackerSwapper = new TestSwapper(poolManager);
        _fund(address(attackerSwapper), 10_000_000 ether);
        attacker = new Attacker(poolManager, oracle, attackerSwapper, key);
    }

    // ================================================================================================ staleness
    /// A stale oracle across a whole markout cycle: the curator cannot act, swaps keep working, the due record
    /// waits (never scored at a stale price), and it settles normally once the price is fresh again.
    function test_staleOracle_fullCycle_noStaleScoring() public {
        uint256 rid = _curatorRebalance(-600, 600, L_RANGE, 0);
        vm.roll(vm.getBlockNumber() + WINDOW + 1);
        vm.warp(vm.getBlockTimestamp() + MAX_ORACLE_AGE + 1); // oracle now stale

        // The curator cannot open a measured session at a stale price.
        vm.prank(CURATOR);
        vm.expectPartialRevert(ReferencePriceLib.Tenure__StalePrice.selector);
        cv.rebalance(_params(-1200, 1200, L_RANGE / 2));

        // Swaps never revert on a stale oracle; afterSwap just skips settlement.
        _pushSpotTo(-10);
        _pushSpotTo(0);
        assertFalse(hook.recordOf(poolId, rid).settled, "not scored at a stale price");

        // Explicit settlement refuses too.
        vm.expectPartialRevert(ReferencePriceLib.Tenure__StalePrice.selector);
        hook.settle(poolId, rid);
        uint256[] memory ids = new uint256[](1);
        ids[0] = rid;
        vm.expectPartialRevert(ReferencePriceLib.Tenure__StalePrice.selector);
        hook.settleMany(poolId, ids);

        // Fresh price again: the record settles and the curator can act.
        oracle.setPrice(poolId, Constants.SQRT_PRICE_1_1);
        hook.settle(poolId, rid);
        assertTrue(hook.recordOf(poolId, rid).settled);
        vm.prank(CURATOR);
        cv.rebalance(_params(-1200, 1200, L_RANGE / 2));
    }

    /// An oracle timestamp in the future is rejected like a stale one (no "fresh forever" price).
    function test_futureOracleTimestamp_rejected() public {
        _curatorRebalance(-600, 600, L_RANGE, 0);
        oracle.setPriceAt(poolId, Constants.SQRT_PRICE_1_1, vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 20);
        vm.prank(CURATOR);
        vm.expectPartialRevert(ReferencePriceLib.Tenure__StalePrice.selector);
        cv.rebalance(_params(-1200, 1200, L_RANGE / 2));
    }

    // ================================================================================================ griefing
    /// Settlement spot, both directions. Settle is permissionless and allowed while |spot - fair| <= maxSettleDev,
    /// so an outsider picks the settlement spot within that band.
    /// - Griefing an honest curator DOWN is impossible: positions are valued at the fair price, and holdings at
    ///   any off-fair spot are worth at least the holdings at fair (the LP sold above / bought below fair on the
    ///   way), so every off-fair settlement grades the curator BETTER than settling at fair.
    /// - The flip side is a finding: an accomplice can INFLATE a record's alpha (reputation) by settling at the
    ///   edge of the band. It is bounded by maxSettleDev and it costs the pusher about what it adds.
    function test_settlementSpot_cannotGriefDown_canInflateUp() public {
        uint256 rid = _curatorRebalance(-600, 600, L_RANGE, 0); // honest: centered on fair, from idle
        uint256 navBefore = hook.recordOf(poolId, rid).navBefore;
        vm.roll(vm.getBlockNumber() + WINDOW - 1); // push one block before due: afterSwap must not settle it
        snap = vm.snapshotState();

        vm.roll(vm.getBlockNumber() + 1);
        int256 alphaFair = hook.settle(poolId, rid);
        uint256 bMaxFair = hook.budgetOf(poolId).bMax;
        int24 dev = int24(_vaultSettings().maxSettleDev);
        console2.log("alpha settled at fair:");
        console2.logInt(alphaFair);
        for (uint256 side; side < 2; ++side) {
            vm.revertToState(snap);
            uint256 a0 = attacker.valueAtFair(address(attackerSwapper));
            attacker.push(side == 0 ? -dev : dev);
            vm.roll(vm.getBlockNumber() + 1);
            int256 a = hook.settle(poolId, rid);
            uint256 bMaxOff = hook.budgetOf(poolId).bMax;
            attacker.arbBack();
            uint256 cost = a0 - attacker.valueAtFair(address(attackerSwapper));
            uint256 inflation = uint256(a - alphaFair);
            console2.log(side == 0 ? "settled at -maxSettleDev, alpha:" : "settled at +maxSettleDev, alpha:");
            console2.logInt(a);
            console2.log("  inflation (wei):", inflation, "pusher cost (wei):", cost);
            console2.log("  bMax after:", bMaxOff, "vs at fair:", bMaxFair);

            assertGe(a, alphaFair, "an off-fair settlement never grades the curator worse");
            assertLt(inflation * 1e18 / navBefore, 0.001e18, "inflation is under 0.1% of NAV per record");
            assertGe(cost * 2, inflation, "and costs the pusher at least half of what it adds");
        }
    }

    /// A prudent honest curator refuses to act while spot is pushed off fair, so a spot push can delay it but
    /// never charge its budget. (The hook cannot tell a naive honest curator from a poisoned one: a curator that
    /// re-centers on a manipulated spot is charged by the markout. That is the design: grade outcomes, not intent.)
    function test_spotPush_onlyDelaysPrudentCurator() public {
        HonestCurator h = new HonestCurator(cv, oracle, HALF_WIDTH, 240, 30);
        cv.setCurator(address(h));
        assertTrue(h.act(), "opens at fair");
        vm.roll(vm.getBlockNumber() + WINDOW + 1);
        hook.settle(poolId, 0);
        oracle.setPrice(poolId, uint160(uint256(Constants.SQRT_PRICE_1_1) * 102 / 100)); // fair moves ~396 ticks
        BudgetState memory b0 = hook.budgetOf(poolId);
        uint256 records = hook.recordCount(poolId);

        attacker.push(-400);
        for (uint256 i; i < 5; ++i) {
            vm.roll(vm.getBlockNumber() + 20);
            assertFalse(h.act(), "refuses while spot is off fair");
        }
        assertEq(hook.recordCount(poolId), records, "no decision recorded");
        assertGe(hook.budgetOf(poolId).budget, b0.budget, "budget never charged by the push");
        assertEq(uint256(hook.tierOf(poolId)), uint256(Tier.FULL));
        attacker.arbBack();
        assertTrue(h.act(), "acts as soon as spot is back at fair");
    }

    function _params(int24 tl, int24 tu, uint128 l) internal pure returns (CuratedVault.RebalanceParams memory) {
        return CuratedVault.RebalanceParams(tl, tu, l, 0, 0);
    }
}

