// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PositionValue, Holdings, Range} from "../../src/libraries/PositionValue.sol";
import {VectorReader} from "./VectorReader.sol";

/// @notice Differential: Solidity PositionValue must equal the sim/model.py integer layer EXACTLY (0 wei).
contract PositionValueDiffTest is VectorReader {
    function test_diff_holdings() public view {
        string memory j = _load("holdings");
        uint256 n = _count(j);
        assertGe(n, 200);
        for (uint256 i; i < n; ++i) {
            Range memory r =
                Range(int24(_i(j, i, "tickLower")), int24(_i(j, i, "tickUpper")), uint128(_u(j, i, "liquidity")));
            // the Python TickMath port must agree with v4-core
            assertEq(uint256(TickMath.getSqrtPriceAtTick(r.tickLower)), _u(j, i, "sqrtLower"), _msg("sqrtLower", i));
            assertEq(uint256(TickMath.getSqrtPriceAtTick(r.tickUpper)), _u(j, i, "sqrtUpper"), _msg("sqrtUpper", i));
            Holdings memory h = PositionValue.holdings(
                r, _u(j, i, "idle0"), _u(j, i, "idle1"), uint160(_u(j, i, "sqrtPrice")), _b(j, i, "roundUp")
            );
            assertEq(h.amount0, _u(j, i, "amount0"), _msg("amount0", i));
            assertEq(h.amount1, _u(j, i, "amount1"), _msg("amount1", i));
        }
    }

    function test_diff_nav() public view {
        string memory j = _load("nav");
        uint256 n = _count(j);
        assertGe(n, 200);
        for (uint256 i; i < n; ++i) {
            Holdings memory h = Holdings(_u(j, i, "amount0"), _u(j, i, "amount1"));
            uint256 v = PositionValue.navAt(h, uint160(_u(j, i, "sqrtFair")), _b(j, i, "roundUp"));
            assertEq(v, _u(j, i, "nav"), _msg("nav", i));
        }
    }
}
