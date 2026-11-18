// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {VaultFixture} from "../utils/VaultFixture.sol";
import {TestSwapper} from "../utils/TestActors.sol";
import {Range} from "../../src/libraries/PositionValue.sol";
import {Tier} from "../../src/libraries/RiskBudget.sol";
import {Market, HonestCurator, PoisonedCurator, Attacker, ScenarioMath} from "./ScenarioActors.sol";

/// M4.1: scenario actors behave as specified, on a pool where the vault's concentrated liquidity matters.
contract ScenarioActorsTest is VaultFixture {
    int24 constant HALF_WIDTH = 600;
    uint256 constant RECENTER = 240;
    uint256 constant MAX_SPOT_DEV = 30;
    uint256 constant SEED = 0x7e2a;
    int24 constant PARK = 1500;

    Market market;
    TestSwapper attackerSwapper;
    Attacker attacker;

    function _thirdPartyLiquidity() internal pure override returns (uint128) {
        return 2e23; // ~200k of each token full-range: the vault's +-600 tick range dominates near the price
    }

    function setUp() public {
        _setUpVault();
        _deposit(ALICE, 40_000 ether, 40_000 ether);
        market = new Market(poolManager, oracle, swapper, key, SEED, 8, 50 ether);
        attackerSwapper = new TestSwapper(poolManager);
        _fund(address(attackerSwapper), 10_000_000 ether);
        attacker = new Attacker(poolManager, oracle, attackerSwapper, key);
    }

    // ------------------------------------------------------------------------------------------------ Market
    function test_market_seededWalk_andArbitragedSpot() public {
        int24 f = ScenarioMath.fairTick(oracle, poolId);
        for (uint256 i; i < 40; ++i) {
            int24 next = market.step();
            uint256 r = uint256(keccak256(abi.encode(SEED, i)));
            int24 expected = f + int24(int256(r % 17)) - 8;
            assertEq(next, expected, "deterministic seeded path");
            assertLe(ScenarioMath.absDiff(next, f), 8, "bounded step");
            assertLe(ScenarioMath.absDiff(ScenarioMath.spotTick(poolManager, poolId), next), 1, "spot arbitraged");
            f = next;
        }
    }

    // ------------------------------------------------------------------------------------------------ Honest
    function test_honest_tracksFair_withinMandate() public {
        market = new Market(poolManager, oracle, swapper, key, SEED, 30, 50 ether); // livelier walk
        HonestCurator h = new HonestCurator(cv, oracle, HALF_WIDTH, RECENTER, MAX_SPOT_DEV);
        cv.setCurator(address(h));
        assertTrue(h.act(), "opens a position");
        for (uint256 i; i < 200; ++i) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(vm.getBlockTimestamp() + 12);
            market.step();
            h.act();
        }
        (int24 c, bool has) = _center();
        assertTrue(has);
        assertLe(ScenarioMath.absDiff(c, market.fair()), RECENTER + uint256(int256(SPACING)), "tracks fair");
        assertGt(h.actions(), 1, "re-centered as fair moved");
        assertEq(h.refusals(), 0, "every honest decision is inside the mandate");
        console2.log("honest actions:", h.actions(), "tier:", uint256(hook.tierOf(poolId)));
    }

    function test_honest_refusesToActAtManipulatedSpot() public {
        HonestCurator h = new HonestCurator(cv, oracle, HALF_WIDTH, RECENTER, MAX_SPOT_DEV);
        cv.setCurator(address(h));
        attacker.push(-400);
        assertFalse(h.act(), "spot off fair: a prudent curator waits");
        assertEq(hook.recordCount(poolId), 0);
    }

    // ------------------------------------------------------------------------------------------------ Poisoned
    function test_poisoned_isHonestUntilPoisoned_thenFollowsSpot() public {
        PoisonedCurator p = new PoisonedCurator(cv, oracle, HALF_WIDTH, RECENTER, MAX_SPOT_DEV, PARK);
        cv.setCurator(address(p));
        assertTrue(p.act());
        (int24 c0,) = _center();
        assertLe(ScenarioMath.absDiff(c0, 0), uint256(int256(SPACING)), "honest: centered on fair");

        vm.roll(vm.getBlockNumber() + 30);
        attacker.push(-400);
        assertFalse(p.act(), "still honest: refuses the manipulated spot");

        p.poison();
        assertTrue(p.act(), "poisoned: follows the market");
        (int24 c1,) = _center();
        assertLe(ScenarioMath.absDiff(c1, -400), uint256(int256(SPACING)), "centered on the manipulated spot");

        vm.roll(vm.getBlockNumber() + 30);
        attacker.arbBack();
        assertTrue(p.act(), "poisoned at fair: parks the range away");
        (int24 c2,) = _center();
        assertLe(ScenarioMath.absDiff(c2, PARK), uint256(int256(SPACING)), "parked parkOffset from fair");
        assertEq(p.refusals(), 0, "every bad decision is inside the static mandate");
    }

    // ------------------------------------------------------------------------------------------------ Attacker
    /// The killer attack in one round: push spot, the poisoned curator re-centers there, arbitrage back.
    function test_attacker_profitsFromPoisonedPlacement() public {
        PoisonedCurator p = new PoisonedCurator(cv, oracle, HALF_WIDTH, RECENTER, MAX_SPOT_DEV, PARK);
        cv.setCurator(address(p));
        p.act();
        p.poison();
        vm.roll(vm.getBlockNumber() + 30);
        assertTrue(p.act(), "parks the range away from the price");
        vm.roll(vm.getBlockNumber() + 30);

        (uint256 nav0,) = cv.nav(false);
        uint256 a0 = attacker.valueAtFair(address(attackerSwapper));
        attacker.push(-400);
        assertTrue(p.act());
        attacker.arbBack();
        uint256 a1 = attacker.valueAtFair(address(attackerSwapper));
        (uint256 nav1,) = cv.nav(false);

        assertGt(a1, a0, "attacker profits at the fair price");
        assertLt(nav1, nav0, "the vault pays for it");
        console2.log("attacker profit:", a1 - a0, "vault loss:", nav0 - nav1);
    }

    function _center() internal view returns (int24, bool) {
        Range memory r = hook.currentRange(poolId);
        return ((r.tickLower + r.tickUpper) / 2, r.liquidity != 0);
    }
}
