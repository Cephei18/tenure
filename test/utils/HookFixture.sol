// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {TenureTestBase} from "./TenureTestBase.sol";
import {SessionVault} from "./TestActors.sol";
import {PoolSettings, Mandate} from "../../src/TenureHook.sol";
import {Tier} from "../../src/libraries/RiskBudget.sol";

/// @dev Hook + registered SessionVault with idle funds + deep third-party liquidity, and a "leak" primitive.
abstract contract HookFixture is TenureTestBase {
    SessionVault vault;
    uint256 constant VAULT_FUNDS = 100_000 ether; // per token => NAV 200k token1 at price 1

    /// @dev Settings for scoring/tier tests: real mandate rules, small budget (0.2% of NAV) so a few measured
    ///      leaks walk the tiers.
    function _fixtureSettings() internal pure virtual returns (PoolSettings memory s) {
        s = _settings();
        s.mandate = Mandate({minWidth: 120, maxWidth: 12_000, maxCenterDist: 3000, maxMoveWad: 0.2e18, cooldown: 10});
        s.budget.bMax0 = 2e15;
        s.budget.bMaxCap = 1e16;
        s.budget.refillRate = uint256(2e15) / 7200;
    }

    function _setUpFixture() internal {
        _deployTenureBase();
        vault = new SessionVault(poolManager, hook);
        _fund(address(vault), VAULT_FUNDS);
        _fund(address(this), 1_000_000_000 ether);
        _fund(address(swapper), 1e29); // the attacker/market can move a 1e27-deep pool
        _deepLiquidity(1e27); // ~1e27 of each token: swaps of 1e22-1e23 barely move the price
        hook.registerPool(key, address(vault), oracle, _fixtureSettings());
    }

    /// @dev Push pool spot to `tick` with a third-party swap (fair price unchanged).
    function _pushSpotTo(int24 tick) internal {
        uint160 target = TickMath.getSqrtPriceAtTick(tick);
        (uint160 cur,,,) = _slot0();
        if (target == cur) return;
        swapper.swapTo(key, target < cur, 1e29, target); // capped by the price limit, not the amount
    }

    function _slot0() internal view returns (uint160 s, int24 t, uint24 a, uint24 b) {
        return StateView.slot0(poolManager, poolId);
    }

    /// @dev One measured, individually "valid" bad decision: attacker moves spot ~3% below fair, the vault sells
    ///      `amountIn` token0 inside a rebalance session at that price, attacker restores spot to fair.
    function _leakOnce(uint256 amountIn) internal {
        _pushSpotTo(-300);
        SessionVault.Op[] memory ops = new SessionVault.Op[](1);
        ops[0] = _swapOp(true, amountIn);
        vault.rebalance(key, ops);
        _pushSpotTo(0);
    }

    /// @dev Leak repeatedly (respecting cooldowns) until the tier reaches `target`. Bounded.
    function _leakUntil(Tier target, uint256 amountIn) internal {
        for (uint256 i; i < 40 && uint256(hook.tierOf(poolId)) < uint256(target); ++i) {
            vm.roll(block.number + 30);
            _leakOnce(amountIn);
        }
        assertEq(uint256(hook.tierOf(poolId)), uint256(target), "reached target tier");
    }

    function _rebalance(SessionVault.Op[] memory ops) internal {
        vault.rebalance(key, ops);
    }

    function _sqrt(int24 tick) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }

    function _fairOne() internal view {
        (uint160 f,) = oracle.getSqrtPriceX96(poolId);
        assert(f == Constants.SQRT_PRICE_1_1);
    }
}

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

library StateView {
    using StateLibrary for IPoolManager;

    function slot0(IPoolManager pm, PoolId id) internal view returns (uint160, int24, uint24, uint24) {
        return pm.getSlot0(id);
    }
}
