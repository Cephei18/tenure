// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {VaultFixture} from "../utils/VaultFixture.sol";
import {TestSwapper} from "../utils/TestActors.sol";
import {TenureHook} from "../../src/TenureHook.sol";
import {Tier} from "../../src/libraries/RiskBudget.sol";
import {HonestCurator, PoisonedCurator, Attacker, ScenarioMath} from "../scenario/ScenarioActors.sol";
import {CuratedVault} from "../../src/CuratedVault.sol";
import {MockReferencePrice} from "../../src/mocks/MockReferencePrice.sol";

/// @dev Always-poisoned curator that parks WITHOUT an inventory swap, so a park costs no immediate leakage and the
///      repeated-rounds test isolates what the markout window does (the stock PoisonedCurator's park swap through
///      this thin pool is itself charged as leakage and freezes the curator after one round).
contract SwaplessPoisonedCurator is HonestCurator {
    int24 public immutable parkOffset;

    constructor(CuratedVault v, MockReferencePrice o, int24 hw, uint256 recenter, uint256 maxSpotDev, int24 parkTicks)
        HonestCurator(v, o, hw, recenter, maxSpotDev)
    {
        parkOffset = parkTicks;
    }

    function act() external override returns (bool) {
        if (!_cooldownOk() || hook.tierOf(id) == Tier.FROZEN) return false;
        int24 fairT = ScenarioMath.fairTick(oracle, id);
        int24 spotT = ScenarioMath.spotTick(pm, id);
        if (ScenarioMath.absDiff(spotT, fairT) <= maxSpotDev) return _recenter(fairT + parkOffset); // park
        return _recenter(spotT); // follow the manipulated spot
    }
}

contract WindowGamingTest is VaultFixture {
    int24 constant HALF_WIDTH = 600;
    uint256 constant RECENTER = 240;
    uint256 constant MAX_SPOT_DEV = 30; // the curator "follows" spot only if it is more than this off fair
    int24 constant PARK = 1500;
    int24 constant SMALL_PUSH = -90; // inside maxSettleDev: the record can be graded at the manipulated spot
    int24 constant LARGE_PUSH = -400; // outside maxSettleDev: grading needs spot back near fair first

    PoisonedCurator p;
    TestSwapper attackerSwapper;
    Attacker attacker;
    uint256 snap;

    struct Round {
        uint256 damage; // vault NAV at fair before the push minus after the final arbitrage
        uint256 graded; // immediate leakage + markout loss actually charged for the follow decision
        uint256 afterGrade; // part of `damage` realized AFTER the record was graded (no grade ever sees it)
        uint256 profit; // attacker gain at the fair price
    }

    function _thirdPartyLiquidity() internal pure override returns (uint128) {
        return 2e23; // same pool as M4.1 (ScenarioActors.t.sol)
    }

    function setUp() public {
        _setUpVault();
        _deposit(ALICE, 40_000 ether, 40_000 ether);
        attackerSwapper = new TestSwapper(poolManager);
        _fund(address(attackerSwapper), 10_000_000 ether);
        attacker = new Attacker(poolManager, oracle, attackerSwapper, key);
        p = new PoisonedCurator(cv, oracle, HALF_WIDTH, RECENTER, MAX_SPOT_DEV, PARK);
        cv.setCurator(address(p));

        // Honest open at fair, then poisoned: park the range away from the price (M4.1 step 1).
        assertTrue(p.act(), "opens");
        p.poison();
        vm.roll(vm.getBlockNumber() + 30);
        assertTrue(p.act(), "parks");
        // Grade the setup records at fair so only the attack round's record is open.
        vm.roll(vm.getBlockNumber() + WINDOW + 1);
        uint256[] memory ids = new uint256[](2);
        ids[1] = 1;
        assertEq(hook.settleMany(poolId, ids), 2, "setup records graded");
        vm.roll(vm.getBlockNumber() + 30);
        assertEq(uint256(hook.tierOf(poolId)), uint256(Tier.FULL), "attack starts at FULL");
        snap = vm.snapshotState();
    }

    // ------------------------------------------------------------------------------------------------ rounds
    /// @dev Push, let the poisoned curator follow, then either arbitrage back inside W and settle after it
    ///      (`strikeAfterW` false), or arbitrage only down to `settleAt` ticks from fair, let the record be graded
    ///      there after W (the attacker calls the permissionless settle), and finish the arbitrage afterwards.
    function _round(int24 push, int24 settleAt, bool strikeAfterW) internal returns (Round memory r) {
        (uint256 nav0,) = cv.nav(false);
        uint256 a0 = attacker.valueAtFair(address(attackerSwapper));

        attacker.push(push);
        vm.recordLogs();
        assertTrue(p.act(), "poisoned curator follows the manipulated spot");
        uint256 rid = hook.recordCount(poolId) - 1;
        r.graded = _immediateCharge(rid);
        uint256 due = vm.getBlockNumber() + WINDOW;

        if (!strikeAfterW) {
            vm.roll(vm.getBlockNumber() + 5);
            attacker.arbBack(); // inside W: not due, afterSwap does not settle
            vm.roll(due);
        } else {
            vm.roll(vm.getBlockNumber() + 5);
            if (settleAt != push) attacker.push(settleAt); // partial arbitrage to the edge of maxSettleDev
            vm.roll(due);
        }
        int256 alpha = hook.settle(poolId, rid);
        (uint256 navGraded,) = cv.nav(false);
        if (strikeAfterW) attacker.arbBack(); // the rest of the arbitrage happens after grading
        assertTrue(hook.recordOf(poolId, rid).settled);

        if (alpha < 0) r.graded += uint256(-alpha);
        (uint256 nav1,) = cv.nav(false);
        r.damage = nav0 > nav1 ? nav0 - nav1 : 0;
        r.afterGrade = navGraded > nav1 ? navGraded - nav1 : 0;
        uint256 a1 = attacker.valueAtFair(address(attackerSwapper));
        r.profit = a1 > a0 ? a1 - a0 : 0;
    }

    /// @dev Immediate leakage charged by endRebalance for `rid` (lossWad of NAV_before), from RebalanceScored.
    function _immediateCharge(uint256 rid) internal returns (uint256) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != TenureHook.RebalanceScored.selector) continue;
            if (uint256(logs[i].topics[2]) != rid) continue;
            (, uint256 navBefore, uint256 lossWad,,,) =
                abi.decode(logs[i].data, (int256, uint256, uint256, uint256, uint256, uint8));
            return lossWad * navBefore / 1e18;
        }
        revert("no RebalanceScored");
    }

    function _log(string memory label, Round memory r) internal pure {
        console2.log(label);
        console2.log("  damage (wei):  ", r.damage);
        console2.log("  graded (wei):  ", r.graded);
        console2.log("  after grade:   ", r.afterGrade);
        console2.log("  attacker (wei):", r.profit);
    }

    // ------------------------------------------------------------------------------------------------ tests
    // Note: `graded` exceeds `damage` when struck inside W. That is the curator-adverse fee rule, not an error:
    // the parked old range's ticks are uninitialized after the vault leaves them, so the counterfactual is credited
    // the global fee-growth upper bound (DecisionScore.estimateFees). The fair comparison is therefore the SAME
    // attack inside vs after W: how much of the charge disappears, and how much damage lands after grading.

    /// Small push (inside maxSettleDev). Inside W the markout charges more than the whole loss; after W the attacker
    /// grades the record at the manipulated spot first, the charge drops to ~0 and the whole loss escapes.
    function test_windowGaming_smallPush_strikeAfterW_escapesGrading() public {
        Round memory inside = _round(SMALL_PUSH, SMALL_PUSH, false);
        vm.revertToState(snap);
        Round memory outside = _round(SMALL_PUSH, SMALL_PUSH, true);
        _log("small push (-90), strike inside W:", inside);
        _log("small push (-90), strike after W:", outside);

        assertGt(inside.damage, 0, "the follow decision loses money");
        assertGe(inside.graded, inside.damage, "inside W: the whole loss is charged");
        assertEq(inside.afterGrade, 0, "inside W: nothing is realized after grading");
        assertEq(outside.damage, inside.damage, "same attack, same damage; only the timing differs");
        assertEq(outside.profit, inside.profit, "and the same attacker profit");
        assertLt(outside.graded, 1e6, "after W: the charge is dust (immediate leakage rounding only)");
        assertGe(outside.afterGrade, outside.damage * 99 / 100, "after W: the whole loss lands after grading");
    }

    /// Large push (outside maxSettleDev). The record cannot be graded at the manipulated spot, so the attacker must
    /// arbitrage back to maxSettleDev first; only the last leg (maxSettleDev ticks back to fair) escapes.
    function test_windowGaming_largePush_onlyLastLegEscapes() public {
        int24 edge = -int24(_vaultSettings().maxSettleDev);
        Round memory inside = _round(LARGE_PUSH, LARGE_PUSH, false);
        vm.revertToState(snap);
        Round memory outside = _round(LARGE_PUSH, edge, true);
        _log("large push (-400), strike inside W:", inside);
        _log("large push (-400), partial arb to -100, settle, finish after W:", outside);

        assertGe(inside.graded, inside.damage, "inside W: the whole loss is charged");
        assertEq(outside.damage, inside.damage, "same attack, same damage");
        assertGt(outside.afterGrade, 0, "the last leg lands after grading");
        assertLt(outside.afterGrade, outside.damage / 10, "but it is under 10% of the damage");
        assertLt(outside.graded, inside.graded, "the charge drops by the last leg");
        assertGe(outside.graded, outside.damage - outside.afterGrade, "everything realized before grading is charged");
    }

    /// Repeated small-push rounds struck after W: the slow bleed the markout is meant to catch. Each round re-parks
    /// at fair (as in M4.1, but without a swap); the park records are graded normally and charge nothing either.
    function test_windowGaming_smallPush_repeated() public {
        HonestCurator c = new SwaplessPoisonedCurator(cv, oracle, HALF_WIDTH, RECENTER, MAX_SPOT_DEV, PARK);
        cv.setCurator(address(c));
        (uint256 nav0,) = cv.nav(false);
        uint256 a0 = attacker.valueAtFair(address(attackerSwapper));
        uint256 rounds;
        for (uint256 i; i < 20; ++i) {
            attacker.push(SMALL_PUSH);
            if (!c.act()) break; // follow (refused once FROZEN)
            uint256 rid = hook.recordCount(poolId) - 1;
            vm.roll(vm.getBlockNumber() + WINDOW);
            hook.settle(poolId, rid); // graded at the manipulated spot
            attacker.arbBack();
            _settleDue();
            vm.roll(vm.getBlockNumber() + 30);
            if (!c.act()) break; // re-park at fair
            vm.roll(vm.getBlockNumber() + WINDOW + 1);
            _settleDue();
            ++rounds;
        }
        (uint256 nav1,) = cv.nav(false);
        uint256 a1 = attacker.valueAtFair(address(attackerSwapper));
        console2.log("rounds completed:", rounds, "final tier:", uint256(hook.tierOf(poolId)));
        console2.log("vault loss (wei):", nav0 > nav1 ? nav0 - nav1 : 0);
        console2.log("attacker pnl (wei):");
        console2.logInt(int256(a1) - int256(a0));
        console2.log("budget left (wei of WAD):", hook.budgetOf(poolId).budget);
        console2.log("bMax:", hook.budgetOf(poolId).bMax);

        assertEq(rounds, 20, "every round completes");
        assertEq(uint256(hook.tierOf(poolId)), uint256(Tier.FULL), "never demoted");
        assertGe(hook.budgetOf(poolId).budget, hook.budgetOf(poolId).bMax * 99 / 100, "budget untouched");
        assertGt(nav0, nav1, "yet the vault bleeds");
        // Honest caveat (THREAT_MODEL.md section 6): in THIS pool the attacker loses money on the campaign
        // (0.3% fees on push + arbitrage through third-party liquidity exceed its take at 90-tick moves). The
        // grading gap is real; its profitability depends on fee tier and the vault's share of in-range liquidity.
        assertLt(a1, a0, "attacker pays more in fees than it extracts here");
    }

    function _settleDue() internal {
        uint256 n = hook.recordCount(poolId);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = i;
        }
        hook.settleMany(poolId, ids);
    }

    /// Settling at the manipulated spot is impossible once it is more than maxSettleDev off fair.
    function test_windowGaming_cannotGradeAtLargeManipulatedSpot() public {
        attacker.push(LARGE_PUSH);
        assertTrue(p.act());
        uint256 rid = hook.recordCount(poolId) - 1;
        vm.roll(vm.getBlockNumber() + WINDOW);
        vm.expectRevert(abi.encodeWithSelector(TenureHook.Tenure__SpotOffFair.selector, 400, 100));
        hook.settle(poolId, rid);
    }
}
