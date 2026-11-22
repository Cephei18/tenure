// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Chainlink data feed interface, vendored (interface only, no implementation) so Tenure adds no dependency.
/// @dev Copied verbatim in content from smartcontractkit/chainlink
///      contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol (MIT). This ABI has been stable since the
///      v0.6 interface; only the pragma differs. Pinned here: do not "update" it from upstream without re-running
///      test/ChainlinkReferencePrice.t.sol.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
