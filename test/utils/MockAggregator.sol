// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/// @notice Settable Chainlink-style feed for tests (answer, decimals, round metadata).
contract MockAggregator is AggregatorV3Interface {
    uint8 public decimals;
    int256 public answer;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;
    uint256 public updatedAt;

    constructor(uint8 _decimals, int256 _answer) {
        decimals = _decimals;
        answer = _answer;
        updatedAt = block.timestamp;
    }

    /// @notice New round with `a`, stamped now.
    function set(int256 a) external {
        answer = a;
        ++roundId;
        answeredInRound = roundId;
        updatedAt = block.timestamp;
    }

    /// @notice Arbitrary round metadata (stale / incomplete rounds).
    function setRound(int256 a, uint256 t, uint80 rid, uint80 answeredIn) external {
        answer = a;
        updatedAt = t;
        roundId = rid;
        answeredInRound = answeredIn;
    }

    function description() external pure returns (string memory) {
        return "mock";
    }

    function version() external pure returns (uint256) {
        return 4;
    }

    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}
