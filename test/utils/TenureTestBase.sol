// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseTest} from "./BaseTest.sol";
import {SessionVault, TestSwapper} from "./TestActors.sol";
import {TenureHook} from "../../src/TenureHook.sol";
import {MockReferencePrice} from "../../src/mocks/MockReferencePrice.sol";

/// @dev Shared fixture: real PoolManager, tokens, hook at a flag-encoded address, a 1:1 pool, oracle, swapper.
abstract contract TenureTestBase is BaseTest {
    using PoolIdLibrary for PoolKey;

    uint160 constant HOOK_FLAGS =
        uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);
    int24 constant SPACING = 60;
    uint32 constant MAX_ORACLE_AGE = 1 hours;

    Currency currency0;
    Currency currency1;
    PoolKey key;
    PoolId poolId;
    TenureHook hook;
    MockReferencePrice oracle;
    TestSwapper swapper;

    function _deployTenureBase() internal {
        vm.warp(1_700_000_000);
        vm.roll(100);
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        address hookAddr = address(HOOK_FLAGS ^ (uint160(0x7e2a) << 144)); // namespaced, low bits = flags
        deployCodeTo("TenureHook.sol:TenureHook", abi.encode(poolManager, address(this)), hookAddr);
        hook = TenureHook(hookAddr);
        vm.label(hookAddr, "TenureHook");

        key = PoolKey(currency0, currency1, 3000, SPACING, IHooks(hookAddr));
        poolId = key.toId();
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        oracle = new MockReferencePrice();
        oracle.setPrice(poolId, Constants.SQRT_PRICE_1_1);

        swapper = new TestSwapper(poolManager);
        _fund(address(swapper), 1_000_000 ether);
    }

    function _fund(address who, uint256 amount) internal {
        MockERC20(Currency.unwrap(currency0)).mint(who, amount);
        MockERC20(Currency.unwrap(currency1)).mint(who, amount);
    }

    function _ops1(int24 tl, int24 tu, int256 delta) internal pure returns (SessionVault.Op[] memory ops) {
        ops = new SessionVault.Op[](1);
        ops[0] = SessionVault.Op(tl, tu, delta);
    }

    function _ops2(int24 tl0, int24 tu0, int256 d0, int24 tl1, int24 tu1, int256 d1)
        internal
        pure
        returns (SessionVault.Op[] memory ops)
    {
        ops = new SessionVault.Op[](2);
        ops[0] = SessionVault.Op(tl0, tu0, d0);
        ops[1] = SessionVault.Op(tl1, tu1, d1);
    }

    function _fullRange() internal pure returns (int24, int24) {
        return (TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING));
    }
}
