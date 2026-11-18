// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {VaultFixture} from "../utils/VaultFixture.sol";
import {TestSwapper} from "../utils/TestActors.sol";
import {TenureDefaults} from "../utils/TenureDefaults.sol";
import {PoolSettings} from "../../src/TenureHook.sol";
import {Range} from "../../src/libraries/PositionValue.sol";
import {Tier, BudgetState} from "../../src/libraries/RiskBudget.sol";
import {Market, CuratorBase, HonestCurator, PoisonedCurator, Attacker, ScenarioMath} from "./ScenarioActors.sol";

/// M4.2 headline: one seeded market, three runs.
///   A: honest curator + Tenure             -> stays FULL every block
///   B: poisoned curator + static caps only -> slow bleed succeeds (no budget ever binds)
///   C: poisoned curator + Tenure           -> budget drains, RESTRICTED, FROZEN, safe mode; loss bounded
/// Each run starts from the same clean state (vm.snapshotState / revertToState); per-block NAV, budget ratio and
/// tier are written to docs/results/headline.csv.
contract HeadlineTest is VaultFixture {
    uint256 constant BLOCKS = 600;
    uint256 constant POISON_AT = 100;
    uint256 constant SEED = 0x7e2a;
    int24 constant PUSH = -400;
    int24 constant PARK = 1500;

    bool staticOnly; // run B: budget so large that no tier ever binds (only the static mandate applies)

    struct Run {
        uint256[] nav; // token1 units at the fair price
        uint256[] ratio; // budget / bMax, WAD
        uint8[] tier;
        uint256 attackerProfit;
        uint256 frozenAt; // block index, 0 = never
        uint256 restrictedAt; // first block index in RESTRICTED, 0 = never
        uint256 rounds; // completed push -> follow -> arb rounds
    }

    function _thirdPartyLiquidity() internal pure override returns (uint128) {
        return 2e23;
    }

    function _vaultSettings() internal view override returns (PoolSettings memory s) {
        s = super._vaultSettings();
        s.budget = TenureDefaults.budgetParams(); // realistic: 2% of NAV, refilled over ~1 day of blocks
        if (staticOnly) {
            s.budget.bMax0 = 1e18; // 100% of NAV: never binds
            s.budget.bMaxCap = 1e18;
        }
    }

    function test_headline_threeRuns() public {
        vm.pauseGasMetering(); // a 3 x 600-block simulation, not a gas measurement
        uint256 clean = vm.snapshotState();
        Run memory a = _run(false);
        vm.revertToState(clean);
        staticOnly = true;
        Run memory b = _run(true);
        vm.revertToState(clean);
        staticOnly = false;
        Run memory c = _run(true);

        uint256 navA = a.nav[BLOCKS - 1];
        uint256 lossB = _sub(navA, b.nav[BLOCKS - 1]);
        uint256 lossC = _sub(navA, c.nav[BLOCKS - 1]);
        _print(a, b, c, lossB, lossC);
        _writeCsv(a, b, c);

        for (uint256 i; i < BLOCKS; ++i) {
            assertEq(a.tier[i], uint8(Tier.FULL), "run A: honest curator stays FULL every block");
        }
        assertGt(c.restrictedAt, 0, "run C steps down to RESTRICTED");
        assertGt(c.frozenAt, c.restrictedAt, "run C then FREEZES");
        assertGt(b.rounds, 3 * c.rounds, "run B: static caps let the attack keep going");
        assertGt(lossB, 0, "run B bleeds");
        assertLt(lossC * 3, lossB, "loss(C) << loss(B)");
    }

    // ------------------------------------------------------------------------------------------------ one run
    function _run(bool poisoned) internal returns (Run memory r) {
        _setUpVault();
        _deposit(ALICE, 40_000 ether, 40_000 ether);
        Market market = new Market(poolManager, oracle, swapper, key, SEED, 20, 2_000 ether);
        TestSwapper atkSwapper = new TestSwapper(poolManager);
        _fund(address(atkSwapper), 10_000_000 ether);
        Attacker atk = new Attacker(poolManager, oracle, atkSwapper, key);
        CuratorBase cur = poisoned
            ? CuratorBase(new PoisonedCurator(cv, oracle, 600, 120, 30, PARK))
            : CuratorBase(new HonestCurator(cv, oracle, 600, 120, 30));
        cv.setCurator(address(cur));
        cur.act();

        r.nav = new uint256[](BLOCKS);
        r.ratio = new uint256[](BLOCKS);
        r.tier = new uint8[](BLOCKS);
        for (uint256 i; i < BLOCKS; ++i) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(vm.getBlockTimestamp() + 12);
            market.step();
            if (poisoned && i == POISON_AT) PoisonedCurator(address(cur)).poison();
            if (poisoned && i >= POISON_AT) _attackStep(cur, atk, r, i);
            else cur.act();
            (r.nav[i],) = cv.nav(false);
            BudgetState memory b = hook.budgetOf(poolId);
            r.ratio[i] = b.budget * 1e18 / b.bMax;
            r.tier[i] = uint8(b.tier);
            if (b.tier == Tier.RESTRICTED && r.restrictedAt == 0) r.restrictedAt = i;
        }
    }

    /// Poisoned curator's turn. If its range is parked away from the price, the attacker sandwiches the "follow
    /// the market" decision in one block: push spot, curator re-centers there, attacker arbitrages back.
    /// Otherwise the curator parks. Once FROZEN, the vault owner pulls liquidity to idle (safe mode).
    function _attackStep(CuratorBase cur, Attacker atk, Run memory r, uint256 i) internal {
        if (hook.tierOf(poolId) == Tier.FROZEN) {
            if (r.frozenAt == 0) {
                r.frozenAt = i;
                cv.enterSafeMode();
            }
            return;
        }
        Range memory pos = hook.currentRange(poolId);
        int24 center = (pos.tickLower + pos.tickUpper) / 2;
        bool parked = pos.liquidity != 0 && ScenarioMath.absDiff(center, ScenarioMath.fairTick(oracle, poolId)) > 600;
        if (parked) {
            if (!_curatorCanAct()) return; // the attacker only strikes when the curator can follow
            uint256 v0 = atk.valueAtFair(address(atk.swapper()));
            atk.push(PUSH);
            if (cur.act()) ++r.rounds;
            atk.arbBack();
            // per-round profit at one fixed fair price (the attacker's inventory is not marked to the walk)
            r.attackerProfit += _sub(atk.valueAtFair(address(atk.swapper())), v0);
        } else {
            cur.act();
        }
    }

    function _curatorCanAct() internal view returns (bool) {
        uint256 cd = hook.settingsOf(poolId).mandate.cooldown;
        if (hook.tierOf(poolId) == Tier.RESTRICTED) cd *= 2;
        return vm.getBlockNumber() >= hook.lastRebalanceBlock(poolId) + cd;
    }

    // ------------------------------------------------------------------------------------------------ output
    function _print(Run memory a, Run memory b, Run memory c, uint256 lossB, uint256 lossC) internal pure {
        console2.log("================ Tenure headline: 600 blocks, one seeded market ================");
        console2.log("columns: final NAV (tokens) | loss vs run A (tokens) | attack rounds");
        console2.log("A honest   + Tenure      ", a.nav[BLOCKS - 1] / 1e18, uint256(0), a.rounds);
        console2.log("B poisoned + static caps ", b.nav[BLOCKS - 1] / 1e18, lossB / 1e18, b.rounds);
        console2.log("C poisoned + Tenure      ", c.nav[BLOCKS - 1] / 1e18, lossC / 1e18, c.rounds);
        console2.log("C: RESTRICTED at block", c.restrictedAt, "FROZEN at block", c.frozenAt);
        console2.log("attacker profit (tokens): B", b.attackerProfit / 1e18, "C", c.attackerProfit / 1e18);
    }

    function _writeCsv(Run memory a, Run memory b, Run memory c) internal {
        string memory path = "docs/results/headline.csv";
        vm.writeFile(path, "");
        vm.writeLine(path, "block,navA,ratioA,tierA,navB,ratioB,tierB,navC,ratioC,tierC");
        for (uint256 i; i < BLOCKS; ++i) {
            vm.writeLine(path, string.concat(vm.toString(i), ",", _row(a, i), ",", _row(b, i), ",", _row(c, i)));
        }
    }

    function _row(Run memory r, uint256 i) internal pure returns (string memory) {
        return string.concat(vm.toString(r.nav[i]), ",", vm.toString(r.ratio[i]), ",", vm.toString(uint256(r.tier[i])));
    }

    function _sub(uint256 x, uint256 y) internal pure returns (uint256) {
        return x > y ? x - y : 0;
    }
}
