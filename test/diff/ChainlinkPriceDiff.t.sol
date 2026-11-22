// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ChainlinkReferencePrice} from "../../src/ChainlinkReferencePrice.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {MockAggregator} from "../utils/MockAggregator.sol";
import {VectorReader} from "./VectorReader.sol";

/// @notice Differential (M4.6): ChainlinkReferencePrice, end to end through mock feeds, must equal the sim/model.py
///         integer layer EXACTLY, and must revert on exactly the cases where the model raises.
contract ChainlinkPriceDiffTest is VectorReader {
    function test_diff_chainlinkSqrtPrice() public {
        string memory j = _load("chainlink");
        uint256 n = _count(j);
        assertGe(n, 200);
        ChainlinkReferencePrice adapter = new ChainlinkReferencePrice(address(this));
        uint256 ok;
        for (uint256 i; i < n; ++i) {
            PoolId id = PoolId.wrap(bytes32(i + 1));
            MockAggregator f0 = new MockAggregator(uint8(_u(j, i, "fd0")), _i(j, i, "a0"));
            AggregatorV3Interface f1 = _b(j, i, "direct")
                ? AggregatorV3Interface(address(0))
                : new MockAggregator(uint8(_u(j, i, "fd1")), _i(j, i, "a1"));
            adapter.setFeeds(id, f0, f1, uint8(_u(j, i, "dec0")), uint8(_u(j, i, "dec1")));
            try adapter.getSqrtPriceX96(id) returns (uint160 s, uint256) {
                assertTrue(_b(j, i, "ok"), _msg("model raises but Solidity returned", i));
                assertEq(uint256(s), _u(j, i, "sqrtPriceX96"), _msg("sqrtPriceX96", i));
                ++ok;
            } catch {
                assertFalse(_b(j, i, "ok"), _msg("Solidity reverted but model returned", i));
            }
        }
        assertGt(ok, 150, "most cases are valid prices");
        assertLt(ok, n, "some cases must exercise the revert paths");
    }
}
