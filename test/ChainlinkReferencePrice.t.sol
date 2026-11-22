// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {ChainlinkReferencePrice} from "../src/ChainlinkReferencePrice.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {IReferencePrice} from "../src/interfaces/IReferencePrice.sol";
import {ChainlinkPriceLib} from "../src/libraries/ChainlinkPriceLib.sol";
import {ReferencePriceLib} from "../src/libraries/ReferencePriceLib.sol";
import {MockAggregator} from "./utils/MockAggregator.sol";

/// @dev External wrappers so reverts from internal libraries can be asserted with vm.expectRevert.
contract ChainlinkHarness {
    function convert(uint256 a0, uint8 fd0, uint256 a1, uint8 fd1, uint8 dec0, uint8 dec1)
        external
        pure
        returns (uint160)
    {
        return ChainlinkPriceLib.sqrtPriceX96(a0, fd0, a1, fd1, dec0, dec1);
    }

    function readFresh(IReferencePrice o, PoolId id, uint256 maxAge) external view returns (uint160) {
        return ReferencePriceLib.readFresh(o, id, maxAge);
    }
}

/// @notice M4.6: Chainlink-backed fair price. Unit + fuzz against mock aggregators (decimals 6/8/18, direct and
///         two-feed modes, stale / negative / incomplete answers). Exact equality with sim/model.py is in
///         test/diff/ChainlinkPriceDiff.t.sol.
contract ChainlinkReferencePriceTest is Test {
    uint256 constant Q96 = 1 << 96;
    PoolId constant POOL = PoolId.wrap(bytes32(uint256(0x7e2a)));
    address constant EVE = address(0xE5E);

    ChainlinkReferencePrice adapter;
    ChainlinkHarness h;

    function setUp() public {
        vm.warp(1_700_000_000);
        adapter = new ChainlinkReferencePrice(address(this));
        h = new ChainlinkHarness();
    }

    function _twoFeeds(uint8 fd0, int256 a0, uint8 fd1, int256 a1, uint8 dec0, uint8 dec1)
        internal
        returns (MockAggregator f0, MockAggregator f1)
    {
        f0 = new MockAggregator(fd0, a0);
        f1 = new MockAggregator(fd1, a1);
        adapter.setFeeds(POOL, f0, f1, dec0, dec1);
    }

    // ------------------------------------------------------------------ conversion
    function test_wethUsdc_handExample() public {
        // ETH/USD 3,000 and USDC/USD 1 (8-decimal feeds); token0 WETH (18), token1 USDC (6): P = 3000e6/1e18 = 3e-9.
        _twoFeeds(8, 3000e8, 8, 1e8, 18, 6);
        (uint160 s, uint256 t) = adapter.getSqrtPriceX96(POOL);
        assertEq(uint256(s), 4339505179874779489431521, "= sim/model.py chainlink_sqrt_price_x96");
        assertEq(t, block.timestamp);
        // s^2 / 2^192 recovers 3e-9 to 1e-18 relative: s^2 * 1e18 / 2^192 = 3e9 (raw price * 1e18).
        assertApproxEqRel(FullMath.mulDiv(uint256(s) * uint256(s), 1e18, 1 << 192), 3e9, 1e9);
    }

    function test_directFeed_equalsTwoFeedMode() public {
        // Same price through one direct feed (token0 priced in token1, 8 decimals).
        MockAggregator direct = new MockAggregator(8, 3000e8);
        adapter.setFeeds(POOL, direct, AggregatorV3Interface(address(0)), 18, 6);
        (uint160 s,) = adapter.getSqrtPriceX96(POOL);
        assertEq(uint256(s), 4339505179874779489431521);
    }

    /// Equal USD prices and equal token decimals => exactly price 1 (Q96) for every feed-decimals combination.
    function testFuzz_decimalsCombos_parity(uint8 i0, uint8 i1, uint8 iDec, uint64 usd) public {
        uint8[3] memory d = [uint8(6), 8, 18];
        uint8 fd0 = d[i0 % 3];
        uint8 fd1 = d[i1 % 3];
        uint8 dec = d[iDec % 3];
        usd = uint64(bound(usd, 1, 1e9));
        _twoFeeds(fd0, int256(uint256(usd) * 10 ** fd0), fd1, int256(uint256(usd) * 10 ** fd1), dec, dec);
        (uint160 s,) = adapter.getSqrtPriceX96(POOL);
        assertEq(uint256(s), Q96);
    }

    /// Token decimals shift the raw price by 10^(dec1 - dec0): sqrt shifts by 10^((dec1-dec0)/2).
    function testFuzz_tokenDecimals_scaleRawPrice(uint8 i0, uint8 i1) public {
        uint8[3] memory d = [uint8(6), 8, 18];
        uint8 dec0 = d[i0 % 3];
        uint8 dec1 = d[i1 % 3];
        _twoFeeds(8, 1e8, 8, 1e8, dec0, dec1);
        (uint160 s,) = adapter.getSqrtPriceX96(POOL);
        // s = floor(sqrt(P * 2^192)) with raw P = 10^(dec1 - dec0): s^2 <= P * 2^192 < (s+1)^2.
        uint256 ss = uint256(s);
        if (dec1 >= dec0) {
            uint256 p = 10 ** (dec1 - dec0);
            assertLe(FullMath.mulDiv(ss, ss, 1 << 192), p, "s is a floor");
            assertGe(FullMath.mulDiv(ss + 1, ss + 1, 1 << 192), p, "s + 1 is above");
        } else {
            uint256 inv = 10 ** (dec0 - dec1); // P = 1 / inv
            assertLe(ss * ss * inv, uint256(1) << 192, "s is a floor");
            assertGt((ss + 1) * (ss + 1) * inv, uint256(1) << 192, "s + 1 is above");
        }
    }

    /// Swapping the two tokens inverts the price: s(a0,a1) * s(a1,a0) ~= 2^192.
    function testFuzz_inverse(uint96 a0, uint96 a1) public view {
        a0 = uint96(bound(a0, 1e6, 1e24));
        a1 = uint96(bound(a1, 1e6, 1e24));
        uint256 s = h.convert(a0, 8, a1, 8, 18, 18);
        uint256 r = h.convert(a1, 8, a0, 8, 18, 18);
        uint256 prod = FullMath.mulDiv(s, r, 1 << 96); // ~= 2^96
        assertApproxEqRel(prod, Q96, 1e6, "s(a0,a1) * s(a1,a0) == 2^192 within 1e-12");
        assertLe(prod, Q96, "both round down");
    }

    function testFuzz_monotonicInAnswer(uint96 a0, uint96 bump, uint96 a1) public view {
        a0 = uint96(bound(a0, 1, 1e26));
        a1 = uint96(bound(a1, 1, 1e26));
        bump = uint96(bound(bump, 1, 1e26));
        uint256 lo = h.convert(a0, 8, a1, 8, 18, 18);
        uint256 hi = h.convert(uint256(a0) + bump, 8, a1, 8, 18, 18);
        assertGe(hi, lo);
    }

    function test_highPriceBranch_relativeErrorTiny() public view {
        // P = 1e30 >= 2^64: the <<32 branch. s ~= 1e15 * 2^96; check s^2 / 2^192 vs 1e30 within 2^-90 relative.
        uint256 s = h.convert(1e30, 0, 1, 0, 18, 18);
        assertGe(s, 1 << 128, "high branch");
        uint256 p = FullMath.mulDiv(s, s, 1 << 192);
        assertLe(p, 1e30);
        assertApproxEqRel(p, 1e30, 1, "relative error < 1e-18");
    }

    function test_outOfRange_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceLib.Tenure__PriceOutOfRange.selector, uint256(0)));
        h.convert(1, 18, 1e30, 0, 18, 0); // P = 1e-48: sqrt rounds to 0
    }

    function test_scaleOverflow_reverts() public {
        vm.expectRevert(ChainlinkPriceLib.Tenure__ScaleOverflow.selector);
        h.convert(type(uint256).max / 10, 0, 1, 36, 0, 36);
    }

    // ------------------------------------------------------------------ answers and rounds
    function test_negativeOrZeroAnswer_reverts() public {
        (MockAggregator f0, MockAggregator f1) = _twoFeeds(8, 3000e8, 8, 1e8, 18, 6);
        f0.set(-1);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkReferencePrice.Tenure__InvalidAnswer.selector, address(f0), -1));
        adapter.getSqrtPriceX96(POOL);
        f0.set(3000e8);
        f1.set(0);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkReferencePrice.Tenure__InvalidAnswer.selector, address(f1), 0));
        adapter.getSqrtPriceX96(POOL);
    }

    function test_incompleteRound_reverts() public {
        (MockAggregator f0,) = _twoFeeds(8, 3000e8, 8, 1e8, 18, 6);
        f0.setRound(3000e8, block.timestamp, 5, 4); // answeredInRound < roundId
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkReferencePrice.Tenure__IncompleteRound.selector, address(f0), 5, 4, block.timestamp
            )
        );
        adapter.getSqrtPriceX96(POOL);
        f0.setRound(3000e8, 0, 5, 5); // never updated
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkReferencePrice.Tenure__IncompleteRound.selector, address(f0), 5, 5, 0)
        );
        adapter.getSqrtPriceX96(POOL);
    }

    function test_updatedAt_isTheOlderFeed_andStaleRevertsInTheHookPath() public {
        (MockAggregator f0, MockAggregator f1) = _twoFeeds(8, 3000e8, 8, 1e8, 18, 6);
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 2 hours);
        f0.set(3100e8); // fresh; f1 is still 2 hours old
        (, uint256 t) = adapter.getSqrtPriceX96(POOL);
        assertEq(t, t0, "older feed wins");
        // TenureHook reads the oracle through ReferencePriceLib.readFresh with its per-pool maxOracleAge.
        vm.expectRevert(abi.encodeWithSelector(ReferencePriceLib.Tenure__StalePrice.selector, t0, 1 hours));
        h.readFresh(adapter, POOL, 1 hours);
        f1.set(1e8);
        assertGt(h.readFresh(adapter, POOL, 1 hours), 0, "fresh again once both feeds update");
    }

    // ------------------------------------------------------------------ configuration
    function test_setFeeds_onlyOwner_once_validated() public {
        MockAggregator f0 = new MockAggregator(8, 3000e8);
        vm.prank(EVE);
        vm.expectRevert(ChainlinkReferencePrice.Tenure__NotOwner.selector);
        adapter.setFeeds(POOL, f0, AggregatorV3Interface(address(0)), 18, 6);

        vm.expectRevert(ChainlinkReferencePrice.Tenure__ZeroAddress.selector);
        adapter.setFeeds(POOL, AggregatorV3Interface(address(0)), AggregatorV3Interface(address(0)), 18, 6);

        vm.expectRevert(abi.encodeWithSelector(ChainlinkReferencePrice.Tenure__BadDecimals.selector, uint8(37)));
        adapter.setFeeds(POOL, f0, AggregatorV3Interface(address(0)), 37, 6);

        vm.expectEmit(true, false, false, true, address(adapter));
        emit ChainlinkReferencePrice.FeedsSet(POOL, address(f0), address(0), 8, 0, 18, 6);
        adapter.setFeeds(POOL, f0, AggregatorV3Interface(address(0)), 18, 6);
        assertEq(address(adapter.feedsOf(POOL).feed0), address(f0));

        // Feeds can never be swapped: that would let the owner pick the price every decision is scored at.
        MockAggregator other = new MockAggregator(8, 1); // created first: expectRevert binds to the NEXT call
        vm.expectRevert(ChainlinkReferencePrice.Tenure__AlreadyConfigured.selector);
        adapter.setFeeds(POOL, other, AggregatorV3Interface(address(0)), 18, 6);
    }

    function test_unconfiguredPool_reverts() public {
        vm.expectRevert(ChainlinkReferencePrice.Tenure__NotConfigured.selector);
        adapter.getSqrtPriceX96(PoolId.wrap(bytes32(uint256(1))));
    }

    function test_transferOwnership() public {
        vm.prank(EVE);
        vm.expectRevert(ChainlinkReferencePrice.Tenure__NotOwner.selector);
        adapter.transferOwnership(EVE);
        adapter.transferOwnership(EVE);
        assertEq(adapter.owner(), EVE);
    }
}
