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

    /// M3.3: fee estimation from raw (wrapping) accumulator snapshots, and alpha with fees.
    function test_diff_feesAlpha() public view {
        string memory j = _load("fees");
        uint256 n = _count(j);
        assertGe(n, 200);
        for (uint256 i; i < n; ++i) {
            Holdings memory fCf = _feesFor(j, i, "o", "old", "validOld", true);
            Holdings memory fNew = _feesFor(j, i, "n", "new", "validNew", false);
            assertEq(fCf.amount0, _u(j, i, "feesCf0"), _msg("feesCf0", i));
            assertEq(fCf.amount1, _u(j, i, "feesCf1"), _msg("feesCf1", i));
            assertEq(fNew.amount0, _u(j, i, "feesNew0"), _msg("feesNew0", i));
            assertEq(fNew.amount1, _u(j, i, "feesNew1"), _msg("feesNew1", i));
            assertEq(_alphaFees(j, i, fCf, fNew), _i(j, i, "alpha"), _msg("alphaFees", i));
        }
    }

    function _feesFor(string memory j, uint256 i, string memory pre, string memory pos, string memory validKey, bool cf)
        internal
        pure
        returns (Holdings memory)
    {
        uint256 d0 =
            DecisionScore.feeGrowthDelta(_u(j, i, string.concat(pre, "Now0")), _u(j, i, string.concat(pre, "Then0")));
        uint256 d1 =
            DecisionScore.feeGrowthDelta(_u(j, i, string.concat(pre, "Now1")), _u(j, i, string.concat(pre, "Then1")));
        return DecisionScore.estimateFees(
            d0,
            d1,
            DecisionScore.feeGrowthDelta(_u(j, i, "gNow0"), _u(j, i, "gThen0")),
            DecisionScore.feeGrowthDelta(_u(j, i, "gNow1"), _u(j, i, "gThen1")),
            _range(j, i, pos).liquidity,
            _b(j, i, validKey),
            cf
        );
    }

    function _alphaFees(string memory j, uint256 i, Holdings memory fCf, Holdings memory fNew)
        internal
        pure
        returns (int256)
    {
        return DecisionScore.markoutAlphaWithFees(
            _range(j, i, "old"),
            Holdings(_u(j, i, "idleOld0"), _u(j, i, "idleOld1")),
            fCf,
            _range(j, i, "new"),
            Holdings(_u(j, i, "idleNew0"), _u(j, i, "idleNew1")),
            fNew,
            uint160(_u(j, i, "sqrtSpotT")),
            uint160(_u(j, i, "sqrtFairT"))
        );
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
