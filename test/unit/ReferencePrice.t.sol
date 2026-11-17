// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IReferencePrice} from "../../src/interfaces/IReferencePrice.sol";
import {ReferencePriceLib} from "../../src/libraries/ReferencePriceLib.sol";
import {MockReferencePrice} from "../../src/mocks/MockReferencePrice.sol";

/// @dev External wrapper so library reverts can be caught by expectRevert.
contract ReaderHarness {
    function read(IReferencePrice o, PoolId id, uint256 maxAge) external view returns (uint160) {
        return ReferencePriceLib.readFresh(o, id, maxAge);
    }
}

contract ReferencePriceTest is Test {
    MockReferencePrice oracle;
    ReaderHarness reader;
    PoolId constant ID = PoolId.wrap(bytes32(uint256(1)));
    PoolId constant OTHER = PoolId.wrap(bytes32(uint256(2)));
    uint160 constant P = 79228162514264337593543950336; // 1:1

    function setUp() public {
        vm.warp(1_000_000);
        oracle = new MockReferencePrice();
        reader = new ReaderHarness();
    }

    function test_setGet() public {
        vm.expectEmit(true, false, false, true);
        emit MockReferencePrice.ReferencePriceSet(ID, P, block.timestamp);
        oracle.setPrice(ID, P);
        (uint160 s, uint256 t) = oracle.getSqrtPriceX96(ID);
        assertEq(s, P);
        assertEq(t, block.timestamp);
        (s, t) = oracle.getSqrtPriceX96(OTHER);
        assertEq(s, 0, "per-pool isolation");
        assertEq(t, 0);
    }

    function test_readFresh_ok_atBoundary() public {
        oracle.setPriceAt(ID, P, block.timestamp - 60);
        assertEq(reader.read(oracle, ID, 60), P);
    }

    function test_readFresh_stale_reverts() public {
        oracle.setPriceAt(ID, P, block.timestamp - 61);
        vm.expectRevert(abi.encodeWithSelector(ReferencePriceLib.Tenure__StalePrice.selector, block.timestamp - 61, 60));
        reader.read(oracle, ID, 60);
    }

    function test_readFresh_future_reverts() public {
        oracle.setPriceAt(ID, P, block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(ReferencePriceLib.Tenure__StalePrice.selector, block.timestamp + 1, 60));
        reader.read(oracle, ID, 60);
    }

    function test_readFresh_unset_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ReferencePriceLib.Tenure__InvalidPrice.selector, uint160(0)));
        reader.read(oracle, OTHER, 60);
    }

    function test_readFresh_outOfDomain_reverts() public {
        oracle.setPrice(ID, TickMath.MAX_SQRT_PRICE);
        vm.expectRevert(
            abi.encodeWithSelector(ReferencePriceLib.Tenure__InvalidPrice.selector, TickMath.MAX_SQRT_PRICE)
        );
        reader.read(oracle, ID, 60);
    }

    function testFuzz_staleness(uint256 age, uint256 maxAge) public {
        maxAge = bound(maxAge, 1, 1 days);
        age = bound(age, 0, 2 days);
        oracle.setPriceAt(ID, P, block.timestamp - age);
        if (age > maxAge) {
            vm.expectRevert(
                abi.encodeWithSelector(ReferencePriceLib.Tenure__StalePrice.selector, block.timestamp - age, maxAge)
            );
        }
        reader.read(oracle, ID, maxAge);
    }
}
