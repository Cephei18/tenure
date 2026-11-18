// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {HeadlineBase} from "./Headline.t.sol";
import {Tier} from "../../src/libraries/RiskBudget.sol";

/// M4.2b: the headline scenario over 20 market seeds. B and C use identical curator/attacker code and differ only
/// in whether Tenure's budget can bind (asserted in _runBC). Results: docs/results/sweep.csv; summary printed and
/// copied into docs/RESULTS.md.
contract SweepTest is HeadlineBase {
    uint256 constant SEEDS = 20;

    struct Row {
        int256 lossB; // NAV_A - NAV_B at the end, token1 wei (negative = B ended above A)
        int256 lossC;
        uint256 profitB;
        uint256 profitC;
        uint256 roundsB;
        uint256 roundsC;
        uint256 cToRestricted; // blocks from attack start (poison) to first RESTRICTED; 0 = never sampled
        uint256 cToFrozen; // blocks from attack start to FROZEN; 0 = never
        uint256 aMinRatio; // A's lowest budget/bMax, WAD
    }

    function test_sweep_20seeds() public {
        vm.pauseGasMetering(); // 20 x 3 x 600-block simulations, not a gas measurement
        uint256 clean = vm.snapshotState();
        Row[] memory rows = new Row[](SEEDS);
        uint256[] memory finalNavA = new uint256[](SEEDS);
        string memory path = "docs/results/sweep.csv";
        vm.writeFile(path, "");
        vm.writeLine(
            path, "seed,lossB,lossC,profitB,profitC,roundsB,roundsC,cBlocksToRestricted,cBlocksToFrozen,aMinRatio"
        );
        for (uint256 k; k < SEEDS; ++k) {
            uint256 s = uint256(keccak256(abi.encode("tenure-sweep", k)));
            vm.revertToState(clean); // also reverts this contract's storage: set the seed AFTER reverting
            seed = s;
            Run memory a = _run(false);
            finalNavA[k] = a.nav[BLOCKS - 1];
            for (uint256 i; i < BLOCKS; ++i) {
                assertEq(a.tier[i], uint8(Tier.FULL), "A stays FULL on every seed, every block");
            }
            (Run memory b, Run memory c) = _runBC(clean, s);
            Row memory w;
            int256 navA = int256(a.nav[BLOCKS - 1]);
            w.lossB = navA - int256(b.nav[BLOCKS - 1]);
            w.lossC = navA - int256(c.nav[BLOCKS - 1]);
            (w.profitB, w.profitC) = (b.attackerProfit, c.attackerProfit);
            (w.roundsB, w.roundsC) = (b.rounds, c.rounds);
            w.cToRestricted = c.restrictedAt == 0 ? 0 : c.restrictedAt - POISON_AT;
            w.cToFrozen = c.frozenAt == 0 ? 0 : c.frozenAt - POISON_AT;
            w.aMinRatio = a.minRatio;
            rows[k] = w;
            vm.writeLine(path, _csv(k, w));
        }
        // guard against the seed silently not taking effect: different seeds => different markets
        assertTrue(finalNavA[0] != finalNavA[1] && finalNavA[1] != finalNavA[2], "seeds produce different markets");
        _summary(rows);
    }

    // ---------------------------------------------------------------------------------------------- reporting
    function _csv(uint256 k, Row memory w) internal pure returns (string memory) {
        return string.concat(
            vm.toString(k),
            ",",
            vm.toString(w.lossB),
            ",",
            vm.toString(w.lossC),
            ",",
            vm.toString(w.profitB),
            ",",
            vm.toString(w.profitC),
            ",",
            string.concat(vm.toString(w.roundsB), ",", vm.toString(w.roundsC), ","),
            string.concat(vm.toString(w.cToRestricted), ",", vm.toString(w.cToFrozen), ",", vm.toString(w.aMinRatio))
        );
    }

    function _summary(Row[] memory rows) internal pure {
        int256[] memory lb = new int256[](SEEDS);
        int256[] memory lc = new int256[](SEEDS);
        int256[] memory pb = new int256[](SEEDS);
        int256[] memory pc = new int256[](SEEDS);
        int256[] memory tr = new int256[](SEEDS);
        int256[] memory tf = new int256[](SEEDS);
        int256[] memory am = new int256[](SEEDS);
        uint256 neverFrozen;
        uint256 skippedRestricted;
        for (uint256 k; k < SEEDS; ++k) {
            lb[k] = rows[k].lossB;
            lc[k] = rows[k].lossC;
            pb[k] = int256(rows[k].profitB);
            pc[k] = int256(rows[k].profitC);
            tr[k] = int256(rows[k].cToRestricted);
            tf[k] = int256(rows[k].cToFrozen);
            am[k] = int256(rows[k].aMinRatio);
            if (rows[k].cToFrozen == 0) ++neverFrozen;
            if (rows[k].cToRestricted == 0) ++skippedRestricted;
        }
        _sort(lb);
        _sort(lc);
        _sort(pb);
        _sort(pc);
        _sort(tr);
        _sort(tf);
        _sort(am);
        console2.log("================ M4.2b sweep: 20 seeds x (A, B, C), 600 blocks ================");
        console2.log(_l("B loss vs A (tokens)   median / worst", _tok(_med(lb)), _tok(lb[SEEDS - 1])));
        console2.log(_l("C loss vs A (tokens)   median / worst", _tok(_med(lc)), _tok(lc[SEEDS - 1])));
        console2.log(_l("B attacker profit      median / best ", _tok(_med(pb)), _tok(pb[SEEDS - 1])));
        console2.log(_l("C attacker profit      median / best ", _tok(_med(pc)), _tok(pc[SEEDS - 1])));
        console2.log(_l("C blocks to RESTRICTED median / max  ", _med(tr), tr[SEEDS - 1]));
        console2.log(_l("C blocks to FROZEN     median / max  ", _med(tf), tf[SEEDS - 1]));
        console2.log(_l("A min budget ratio bps worst / median", am[0] / 1e14, _med(am) / 1e14));
        console2.log(_l("C never frozen / RESTRICTED unsampled", int256(neverFrozen), int256(skippedRestricted)));
        console2.log(string.concat("C worst loss < B median loss: ", lc[SEEDS - 1] < _med(lb) ? "YES" : "NO"));
    }

    function _l(string memory label, int256 x, int256 y) internal pure returns (string memory) {
        return string.concat(label, ": ", vm.toString(x), " / ", vm.toString(y));
    }

    function _med(int256[] memory x) internal pure returns (int256) {
        return (x[SEEDS / 2 - 1] + x[SEEDS / 2]) / 2;
    }

    function _tok(int256 v) internal pure returns (int256) {
        return v / 1e18;
    }

    function _sort(int256[] memory x) internal pure {
        for (uint256 i = 1; i < x.length; ++i) {
            int256 v = x[i];
            uint256 j = i;
            while (j > 0 && x[j - 1] > v) {
                x[j] = x[j - 1];
                --j;
            }
            x[j] = v;
        }
    }
}
