// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Holdings, Range} from "../../src/libraries/PositionValue.sol";
import {DecisionScore} from "../../src/libraries/DecisionScore.sol";
import {VectorReader} from "./VectorReader.sol";

/// @notice Differential: DecisionScore must equal the sim/model.py integer layer EXACTLY.
contract DecisionScoreDiffTest is VectorReader {
    function test_diff_leakage() public view {
        string memory j = _load("leakage");
        uint256 n = _count(j);
        assertGe(n, 200);
        for (uint256 i; i < n; ++i) {
            (int256 leak, uint256 navBefore) = DecisionScore.immediateLeakage(
                _range(j, i, "old"),
                Holdings(_u(j, i, "idleOld0"), _u(j, i, "idleOld1")),
                uint160(_u(j, i, "sqrtSpot")),
                _range(j, i, "new"),
                Holdings(_u(j, i, "idleNew0"), _u(j, i, "idleNew1")),
                uint160(_u(j, i, "sqrtSpotAfter")),
                uint160(_u(j, i, "sqrtFair"))
            );
            assertEq(leak, _i(j, i, "leakage"), _msg("leakage", i));
            assertEq(navBefore, _u(j, i, "navBefore"), _msg("navBefore", i));
        }
    }

    function test_diff_alpha() public view {
        string memory j = _load("alpha");
        uint256 n = _count(j);
        assertGe(n, 200);
        for (uint256 i; i < n; ++i) {
            int256 a = DecisionScore.markoutAlpha(
                _range(j, i, "old"),
                Holdings(_u(j, i, "idleOld0"), _u(j, i, "idleOld1")),
                _range(j, i, "new"),
                Holdings(_u(j, i, "idleNew0"), _u(j, i, "idleNew1")),
                uint160(_u(j, i, "sqrtSpotT")),
                uint160(_u(j, i, "sqrtFairT"))
            );
            assertEq(a, _i(j, i, "alpha"), _msg("alpha", i));
        }
    }

    function test_diff_loss() public view {
        string memory j = _load("loss");
        uint256 n = _count(j);
        assertGe(n, 200);
        for (uint256 i; i < n; ++i) {
            int256 v = _i(j, i, "value");
            uint256 navRef = _u(j, i, "navRef");
            assertEq(DecisionScore.lossWad(v, navRef), _u(j, i, "lossWad"), _msg("lossWad", i));
            assertEq(DecisionScore.gainWad(v, navRef), _u(j, i, "gainWad"), _msg("gainWad", i));
        }
    }
}
