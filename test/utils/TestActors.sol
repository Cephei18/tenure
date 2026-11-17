// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {TenureHook} from "../../src/TenureHook.sol";

/// @dev Settles a BalanceDelta for `self` inside an unlock: pay what is owed, take what is owed to us.
library DeltaSettler {
    using CurrencySettler for Currency;

    function settleAll(IPoolManager pm, PoolKey memory key, BalanceDelta d, address self) internal {
        _one(pm, key.currency0, d.amount0(), self);
        _one(pm, key.currency1, d.amount1(), self);
    }

    function _one(IPoolManager pm, Currency c, int128 amt, address self) private {
        if (amt < 0) c.settle(pm, self, uint256(uint128(-amt)), false);
        else if (amt > 0) c.take(pm, self, uint256(uint128(amt)), false);
    }
}

/// @notice Minimal vault used to exercise TenureHook sessions in M2 tests (the real vault is src/CuratedVault.sol).
contract SessionVault is IUnlockCallback {
    using DeltaSettler for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable pm;
    TenureHook public immutable hook;

    /// @dev tickLower == tickUpper encodes a SWAP inside the session: liquidityDelta > 0 sells token0
    ///      (zeroForOne) for |liquidityDelta| exact-in, < 0 sells token1. Otherwise a modifyLiquidity.
    struct Op {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
    }

    constructor(IPoolManager _pm, TenureHook _hook) {
        pm = _pm;
        hook = _hook;
    }

    /// Measured rebalance: begin -> unlock(ops) -> end.
    function rebalance(PoolKey memory key, Op[] memory ops) external {
        hook.beginRebalance(key);
        pm.unlock(abi.encode(key, ops));
        hook.endRebalance(key);
    }

    /// Pro-rata session (deposit/withdraw shape).
    function proRata(PoolKey memory key, Op[] memory ops) external {
        hook.beginProRata(key);
        pm.unlock(abi.encode(key, ops));
        hook.endProRata(key);
    }

    /// Modify WITHOUT any session (must revert for the registered vault).
    function rawModify(PoolKey memory key, Op[] memory ops) external {
        pm.unlock(abi.encode(key, ops));
    }

    /// Open a session and return without closing it (to test cross-tx leakage of the flag).
    function beginOnly(PoolKey memory key) external {
        hook.beginRebalance(key);
    }

    /// Open a session and read the flag back inside the SAME transaction.
    function beginAndRead(PoolKey memory key) external returns (uint256) {
        hook.beginRebalance(key);
        return hook.sessionOf(key.toId());
    }

    /// Try to nest/misuse sessions inside one transaction; `which` selects the second call.
    function beginThen(PoolKey memory key, uint256 which) external {
        hook.beginRebalance(key);
        if (which == 0) hook.beginRebalance(key);
        else if (which == 1) hook.beginProRata(key);
        else hook.endProRata(key);
    }

    /// Safe mode: remove `liquidity` from the given (current) range to idle.
    function safeMode(PoolKey memory key, int24 tl, int24 tu, uint128 liquidity) external {
        hook.beginSafeMode(key);
        if (liquidity != 0) pm.unlock(abi.encode(key, _one(tl, tu, -int256(uint256(liquidity)))));
        hook.endSafeMode(key, liquidity);
    }

    /// Safe mode that tries to ADD (must be rejected by the hook).
    function safeModeAdd(PoolKey memory key, int24 tl, int24 tu, uint128 liquidity) external {
        hook.beginSafeMode(key);
        pm.unlock(abi.encode(key, _one(tl, tu, int256(uint256(liquidity)))));
        hook.endSafeMode(key, 0);
    }

    function _one(int24 tl, int24 tu, int256 d) internal pure returns (Op[] memory ops) {
        ops = new Op[](1);
        ops[0] = Op(tl, tu, d);
    }

    function endOnly(PoolKey memory key) external {
        hook.endRebalance(key);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (PoolKey memory key, Op[] memory ops) = abi.decode(data, (PoolKey, Op[]));
        for (uint256 i; i < ops.length; ++i) {
            BalanceDelta d;
            if (ops[i].tickLower == ops[i].tickUpper) {
                bool zeroForOne = ops[i].liquidityDelta > 0;
                int256 amt = zeroForOne ? ops[i].liquidityDelta : -ops[i].liquidityDelta;
                d = pm.swap(
                    key,
                    SwapParams(
                        zeroForOne, -amt, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                    ),
                    ""
                );
            } else {
                (d,) = pm.modifyLiquidity(
                    key,
                    ModifyLiquidityParams(ops[i].tickLower, ops[i].tickUpper, ops[i].liquidityDelta, bytes32(0)),
                    ""
                );
            }
            pm.settleAll(key, d, address(this));
        }
        return "";
    }
}

/// @notice Swaps to an exact sqrt price limit (the hookmate router has no price limit). Used by attackers/markets.
contract TestSwapper is IUnlockCallback {
    using DeltaSettler for IPoolManager;

    IPoolManager public immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    /// @notice Swap exact-in up to `amountIn` (huge = "move price all the way to the limit").
    function swapTo(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 sqrtPriceLimit)
        external
        returns (BalanceDelta d)
    {
        d = abi.decode(
            pm.unlock(abi.encode(key, SwapParams(zeroForOne, -int256(amountIn), sqrtPriceLimit))), (BalanceDelta)
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (PoolKey memory key, SwapParams memory p) = abi.decode(data, (PoolKey, SwapParams));
        BalanceDelta d = pm.swap(key, p, "");
        pm.settleAll(key, d, address(this));
        return abi.encode(d);
    }
}
