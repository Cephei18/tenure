// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IReferencePrice} from "./interfaces/IReferencePrice.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {ChainlinkPriceLib} from "./libraries/ChainlinkPriceLib.sol";

/// @title ChainlinkReferencePrice
/// @notice IReferencePrice backed by Chainlink data feeds: the FAIR price Tenure values vault holdings at. Lives
///         outside the hook (M4.6). Two modes per pool:
///         - two feeds in a common quote (token0/USD and token1/USD): P = answer0 / answer1, decimals-adjusted;
///         - one direct feed (token0 priced in token1): feed1 = address(0).
/// @dev Staleness: returns the OLDER of the feeds' `updatedAt`; TenureHook enforces its per-pool `maxOracleAge` on it
///      (ReferencePriceLib.readFresh, and afterSwap skips settlement on a stale/reverting oracle). Answers that are
///      non-positive, or from an incomplete round (updatedAt == 0 or answeredInRound < roundId), revert.
///      Feeds are set ONCE per pool: swapping a feed would let the owner choose the price every rebalance is scored
///      at, so a different source needs a new adapter and a new registration (which depositors can see coming).
contract ChainlinkReferencePrice is IReferencePrice {
    error Tenure__NotOwner();
    error Tenure__ZeroAddress();
    error Tenure__AlreadyConfigured();
    error Tenure__NotConfigured();
    error Tenure__BadDecimals(uint8 decimals);
    error Tenure__InvalidAnswer(address feed, int256 answer);
    error Tenure__IncompleteRound(address feed, uint80 roundId, uint80 answeredInRound, uint256 updatedAt);

    /// @dev Upper bound on any feed/token decimals: keeps 10^|e| inside uint256 (|e| <= 72).
    uint8 public constant MAX_DECIMALS = 36;

    struct Feeds {
        AggregatorV3Interface feed0; // token0 in the common quote, or token0 in token1 (direct)
        AggregatorV3Interface feed1; // token1 in the common quote; address(0) = direct mode
        uint8 feedDecimals0;
        uint8 feedDecimals1;
        uint8 tokenDecimals0;
        uint8 tokenDecimals1;
    }

    address public owner;
    mapping(PoolId => Feeds) internal _feeds;

    event FeedsSet(
        PoolId indexed poolId,
        address feed0,
        address feed1,
        uint8 feedDecimals0,
        uint8 feedDecimals1,
        uint8 dec0,
        uint8 dec1
    );
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address _owner) {
        if (_owner == address(0)) revert Tenure__ZeroAddress();
        owner = _owner;
        emit OwnershipTransferred(address(0), _owner);
    }

    /// @notice Hand over the right to configure NEW pools (existing pools' feeds can never change).
    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert Tenure__NotOwner();
        if (newOwner == address(0)) revert Tenure__ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Configure a pool's feeds, once. Feed decimals are read from the feeds.
    /// @param feed0 token0 priced in the common quote, or directly in token1 if `feed1` is zero.
    /// @param feed1 token1 priced in the common quote; address(0) for a direct feed.
    /// @param tokenDecimals0 ERC-20 decimals of currency0. @param tokenDecimals1 ERC-20 decimals of currency1.
    function setFeeds(
        PoolId poolId,
        AggregatorV3Interface feed0,
        AggregatorV3Interface feed1,
        uint8 tokenDecimals0,
        uint8 tokenDecimals1
    ) external {
        if (msg.sender != owner) revert Tenure__NotOwner();
        if (address(feed0) == address(0)) revert Tenure__ZeroAddress();
        if (address(_feeds[poolId].feed0) != address(0)) revert Tenure__AlreadyConfigured();
        uint8 fd0 = feed0.decimals();
        uint8 fd1 = address(feed1) == address(0) ? 0 : feed1.decimals();
        _checkDecimals(fd0);
        _checkDecimals(fd1);
        _checkDecimals(tokenDecimals0);
        _checkDecimals(tokenDecimals1);
        _feeds[poolId] = Feeds(feed0, feed1, fd0, fd1, tokenDecimals0, tokenDecimals1);
        emit FeedsSet(poolId, address(feed0), address(feed1), fd0, fd1, tokenDecimals0, tokenDecimals1);
    }

    /// @inheritdoc IReferencePrice
    /// @dev updatedAt = the older feed's timestamp, so the price is only as fresh as its stalest input.
    function getSqrtPriceX96(PoolId poolId) external view returns (uint160 sqrtPriceX96, uint256 updatedAt) {
        Feeds memory f = _feeds[poolId];
        if (address(f.feed0) == address(0)) revert Tenure__NotConfigured();
        (uint256 a0, uint256 t0) = _read(f.feed0);
        uint256 a1 = 1;
        updatedAt = t0;
        if (address(f.feed1) != address(0)) {
            uint256 t1;
            (a1, t1) = _read(f.feed1);
            if (t1 < updatedAt) updatedAt = t1;
        }
        sqrtPriceX96 = ChainlinkPriceLib.sqrtPriceX96(
            a0, f.feedDecimals0, a1, f.feedDecimals1, f.tokenDecimals0, f.tokenDecimals1
        );
    }

    /// @notice The configured feeds of a pool.
    function feedsOf(PoolId poolId) external view returns (Feeds memory) {
        return _feeds[poolId];
    }

    function _read(AggregatorV3Interface feed) internal view returns (uint256 answer, uint256 updatedAt) {
        (uint80 roundId, int256 a,, uint256 t, uint80 answeredInRound) = feed.latestRoundData();
        if (a <= 0) revert Tenure__InvalidAnswer(address(feed), a);
        if (t == 0 || answeredInRound < roundId) {
            revert Tenure__IncompleteRound(address(feed), roundId, answeredInRound, t);
        }
        return (uint256(a), t);
    }

    function _checkDecimals(uint8 d) internal pure {
        if (d > MAX_DECIMALS) revert Tenure__BadDecimals(d);
    }
}
