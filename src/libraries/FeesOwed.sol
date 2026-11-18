// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {Holdings, Range} from "./PositionValue.sol";

/// @title FeesOwed
/// @notice Uncollected LP fees owed to a position, with v4's own formula (paid out on the position's next modify):
///         L * (feeGrowthInside - feeGrowthInsideLast) / 2^128, the subtraction wrapping mod 2^256.
/// @dev Shared by the hook (fee-inclusive H_before / H_after, tenure-math 4b) and the vault (fee-inclusive NAV).
library FeesOwed {
    using StateLibrary for IPoolManager;

    uint256 internal constant Q128 = 1 << 128;

    function owed(IPoolManager pm, PoolId id, address owner, Range memory r) internal view returns (Holdings memory h) {
        if (r.tickLower == r.tickUpper) return h;
        (uint128 l, uint256 last0, uint256 last1) = pm.getPositionInfo(id, owner, r.tickLower, r.tickUpper, bytes32(0));
        if (l == 0) return h;
        (uint256 in0, uint256 in1) = pm.getFeeGrowthInside(id, r.tickLower, r.tickUpper);
        unchecked {
            h.amount0 = FullMath.mulDiv(in0 - last0, l, Q128);
            h.amount1 = FullMath.mulDiv(in1 - last1, l, Q128);
        }
    }
}
