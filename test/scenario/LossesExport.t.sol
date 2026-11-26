// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TestSwapper} from "../utils/TestActors.sol";
import {BudgetState} from "../../src/libraries/RiskBudget.sol";
import {Market, CuratorBase, HonestCurator, PoisonedCurator, Attacker} from "./ScenarioActors.sol";
import {HeadlineBase} from "./Headline.t.sol";

/// Frontend data export (test only, no contract change): replays the headline runs A, B and C of seed 0x7e2a and
/// writes every scoring event of the vault's pool to docs/results/losses.csv, one row per event, in emission order:
///   init           : the budget state at registration (budget = bMax0), the replay's starting point
///   RebalanceScored: immediate leakage of a decision (lossWad charged; lossValue = leakage if > 0)
///   MarkoutSettled : markout of a decision (lossWad/lossValue if alpha < 0, gainWad/gainValue if alpha >= 0)
/// with the hook's post-event budget, bMax (markouts only) and tier, so a replay of RiskBudget can be checked
/// against the hook bit for bit (frontend/src/math/budget.test.ts). The loop mirrors HeadlineBase._run exactly,
/// plus vm.recordLogs; `step` is the block index of headline.csv (-1 = the curator's first action before block 0).
contract LossesExportTest is HeadlineBase {
    bytes32 constant SCORED =
        keccak256("RebalanceScored(bytes32,uint256,int256,uint256,uint256,uint256,uint256,uint8)");
    bytes32 constant SETTLED =
        keccak256("MarkoutSettled(bytes32,uint256,int256,uint256,uint256,uint256,uint256,uint8)");
    string constant PATH = "docs/results/losses.csv";

    uint256 rowsWritten; // per run: vm.revertToState resets it, so each run is checked before the next revert

    function test_exportLosses() public {
        vm.pauseGasMetering(); // a data export over 3 x 600 blocks, not a gas measurement
        uint256 clean = vm.snapshotState();
        vm.writeFile(PATH, "");
        vm.writeLine(PATH, "run,step,blockNumber,event,recordId,lossWad,lossValue,gainWad,gainValue,budget,bMax,tier");
        (seed, staticOnly) = (SEED, false);
        _exportRun("A", false);
        assertGt(rowsWritten, 5, "run A: scoring events exported");
        vm.revertToState(clean);
        (seed, staticOnly) = (SEED, true); // set AFTER revertToState (it reverts this contract's storage too)
        _exportRun("B", true);
        assertGt(rowsWritten, 50, "run B: the unchecked attack produces many scored decisions");
        vm.revertToState(clean);
        (seed, staticOnly) = (SEED, false);
        _exportRun("C", true);
        assertGt(rowsWritten, 5, "run C: scoring events exported");
    }

    /// Same steps as HeadlineBase._run; only the event capture is added.
    function _exportRun(string memory run, bool poisoned) internal {
        _setUpVault();
        BudgetState memory b0 = hook.budgetOf(poolId);
        _row(run, -2, "init", "", "0", "0", "0", "0", b0.budget, vm.toString(b0.bMax), uint8(b0.tier));
        _deposit(ALICE, 40_000 ether, 40_000 ether);
        Market market = new Market(poolManager, oracle, swapper, key, seed, 20, 2_000 ether);
        TestSwapper atkSwapper = new TestSwapper(poolManager);
        _fund(address(atkSwapper), 10_000_000 ether);
        Attacker atk = new Attacker(poolManager, oracle, atkSwapper, key);
        CuratorBase cur = poisoned
            ? CuratorBase(new PoisonedCurator(cv, oracle, 600, 120, 30, PARK))
            : CuratorBase(new HonestCurator(cv, oracle, 600, 120, 30));
        cv.setCurator(address(cur));
        Run memory r;
        vm.recordLogs();
        cur.act();
        _drain(run, -1);
        for (uint256 i; i < BLOCKS; ++i) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(vm.getBlockTimestamp() + 12);
            market.step();
            if (poisoned && i == POISON_AT) PoisonedCurator(address(cur)).poison();
            if (poisoned && i >= POISON_AT) _attackStep(cur, atk, r, i);
            else cur.act();
            _drain(run, int256(i));
        }
    }

    function _drain(string memory run, int256 step) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 k; k < logs.length; ++k) {
            Vm.Log memory l = logs[k];
            if (l.emitter != address(hook) || l.topics.length < 3) continue;
            if (l.topics[1] != PoolId.unwrap(poolId)) continue;
            string memory id = vm.toString(uint256(l.topics[2]));
            if (l.topics[0] == SCORED) {
                (int256 leak,, uint256 lossW,, uint256 budget, uint8 tier) =
                    abi.decode(l.data, (int256, uint256, uint256, uint256, uint256, uint8));
                string memory lv = leak > 0 ? vm.toString(uint256(leak)) : "0";
                _row(run, step, "RebalanceScored", id, vm.toString(lossW), lv, "0", "0", budget, "", tier);
            } else if (l.topics[0] == SETTLED) {
                (int256 alpha, uint256 lossW, uint256 gainW, uint256 budget, uint256 bMax, uint8 tier) =
                    abi.decode(l.data, (int256, uint256, uint256, uint256, uint256, uint8));
                string memory lv = alpha < 0 ? vm.toString(uint256(-alpha)) : "0";
                string memory gv = alpha >= 0 ? vm.toString(uint256(alpha)) : "0";
                _row(
                    run,
                    step,
                    "MarkoutSettled",
                    id,
                    vm.toString(lossW),
                    lv,
                    vm.toString(gainW),
                    gv,
                    budget,
                    vm.toString(bMax),
                    tier
                );
            }
        }
    }

    function _row(
        string memory run,
        int256 step,
        string memory ev,
        string memory id,
        string memory lossW,
        string memory lossV,
        string memory gainW,
        string memory gainV,
        uint256 budget,
        string memory bMax,
        uint8 tier
    ) internal {
        string memory head = string.concat(run, ",", vm.toString(step), ",", vm.toString(vm.getBlockNumber()), ",");
        string memory mid = string.concat(ev, ",", id, ",", lossW, ",", lossV, ",", gainW, ",", gainV, ",");
        vm.writeLine(PATH, string.concat(head, mid, vm.toString(budget), ",", bMax, ",", vm.toString(uint256(tier))));
        ++rowsWritten;
    }
}
