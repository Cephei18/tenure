// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {CuratedVault} from "../../src/CuratedVault.sol";
import {TenureHook} from "../../src/TenureHook.sol";
import {PositionValue, Holdings, Range} from "../../src/libraries/PositionValue.sol";
import {Tier} from "../../src/libraries/RiskBudget.sol";
import {MockReferencePrice} from "../../src/mocks/MockReferencePrice.sol";
import {TestSwapper} from "../utils/TestActors.sol";

/// @dev Shared tick helpers for the scenario actors.
library ScenarioMath {
    using StateLibrary for IPoolManager;

    function spotTick(IPoolManager pm, PoolId id) internal view returns (int24 t) {
        (, t,,) = pm.getSlot0(id);
    }

    function fairTick(MockReferencePrice oracle, PoolId id) internal view returns (int24) {
        (uint160 f,) = oracle.getSqrtPriceX96(id);
        return TickMath.getTickAtSqrtPrice(f);
    }

    /// Round toward negative infinity to a multiple of `spacing`.
    function floorTo(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 c = tick / spacing;
        if (tick < 0 && tick % spacing != 0) --c;
        return c * spacing;
    }

    function absDiff(int24 a, int24 b) internal pure returns (uint256) {
        return a > b ? uint256(int256(a) - int256(b)) : uint256(int256(b) - int256(a));
    }
}

/// @notice Moves the FAIR price along a seeded random walk and keeps pool spot arbitraged to it (normal flow:
///         a noise trade, then an arbitrageur closing the gap). Deterministic for a given seed.
contract Market {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable pm;
    MockReferencePrice public immutable oracle;
    TestSwapper public immutable swapper;
    PoolKey public key;
    PoolId public immutable id;
    uint256 public immutable seed;
    int24 public immutable maxStep; // max |fair tick change| per step
    uint256 public immutable noiseMax; // max noise trade size (token units)
    uint256 public steps;
    int24 public fair;

    constructor(
        IPoolManager _pm,
        MockReferencePrice _oracle,
        TestSwapper _swapper,
        PoolKey memory _key,
        uint256 _seed,
        int24 _maxStep,
        uint256 _noiseMax
    ) {
        pm = _pm;
        oracle = _oracle;
        swapper = _swapper;
        key = _key;
        id = PoolId.wrap(keccak256(abi.encode(_key)));
        seed = _seed;
        maxStep = _maxStep;
        noiseMax = _noiseMax;
        fair = ScenarioMath.fairTick(_oracle, id);
    }

    /// @notice Advance one step: move fair, publish it, noise-trade, then arbitrage spot to fair.
    function step() external returns (int24) {
        uint256 r = uint256(keccak256(abi.encode(seed, steps++)));
        int24 delta = int24(int256(r % uint256(int256(2 * maxStep + 1)))) - maxStep;
        fair += delta;
        oracle.setPrice(id, TickMath.getSqrtPriceAtTick(fair));
        if (noiseMax != 0) {
            bool zf1 = (r >> 128) & 1 == 1;
            uint256 amt = ((r >> 64) % noiseMax) + 1;
            swapper.swapTo(key, zf1, amt, zf1 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        }
        arbToFair();
        return fair;
    }

    /// @notice Arbitrage pool spot back to the fair price (the "informed" flow every LP pays for).
    function arbToFair() public {
        uint160 target = TickMath.getSqrtPriceAtTick(fair);
        (uint160 cur,,,) = pm.getSlot0(id);
        if (cur != target) swapper.swapTo(key, target < cur, type(uint128).max, target);
    }
}

/// @notice Base curator: re-centers a symmetric range around a target tick when it drifts. Never reverts the
///         scenario: a refused rebalance (mandate, cooldown, FROZEN) is reported as `false`.
abstract contract CuratorBase {
    CuratedVault public immutable vault;
    TenureHook public immutable hook;
    IPoolManager public immutable pm;
    MockReferencePrice public immutable oracle;
    PoolId public immutable id;
    int24 public immutable spacing;
    int24 public immutable halfWidth;
    uint256 public immutable recenterAt; // re-center when |center - target| > this (ticks)

    uint256 public actions;
    uint256 public refusals;

    constructor(CuratedVault _vault, MockReferencePrice _oracle, int24 _halfWidth, uint256 _recenterAt) {
        vault = _vault;
        hook = _vault.hook();
        pm = _vault.poolManager();
        oracle = _oracle;
        id = _vault.poolId();
        spacing = _vault.tickSpacing();
        halfWidth = _halfWidth;
        recenterAt = _recenterAt;
    }

    /// @notice One decision opportunity. Returns true if a rebalance was executed.
    function act() external virtual returns (bool);

    function _cooldownOk() internal view returns (bool) {
        (,,,, uint32 cd) = _mandate();
        uint256 c = hook.tierOf(id) == Tier.RESTRICTED ? uint256(cd) * 2 : cd;
        uint256 last = hook.lastRebalanceBlock(id);
        return last == 0 || block.number >= last + c;
    }

    function _mandate() internal view returns (uint24, uint24, uint24, uint64, uint32) {
        return (
            hook.settingsOf(id).mandate.minWidth,
            hook.settingsOf(id).mandate.maxWidth,
            hook.settingsOf(id).mandate.maxCenterDist,
            hook.settingsOf(id).mandate.maxMoveWad,
            hook.settingsOf(id).mandate.cooldown
        );
    }

    /// Re-center around `target` using (almost) all holdings, no swap.
    function _recenter(int24 target) internal returns (bool) {
        int24 c = ScenarioMath.floorTo(target, spacing);
        int24 tl = c - halfWidth;
        int24 tu = c + halfWidth;
        Holdings memory h = vault.totalHoldings();
        (uint160 spot,,,) = StateLibrary.getSlot0(pm, id);
        uint128 l = LiquidityAmounts.getLiquidityForAmounts(
            spot, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), h.amount0, h.amount1
        );
        l = uint128(uint256(l) * 98 / 100); // rounding headroom
        try vault.rebalance(CuratedVault.RebalanceParams(tl, tu, l, 0, 0)) {
            ++actions;
            return true;
        } catch {
            ++refusals;
            return false;
        }
    }

    function _center() internal view returns (int24 c, bool hasPosition) {
        Range memory r = hook.currentRange(id);
        return ((r.tickLower + r.tickUpper) / 2, r.liquidity != 0);
    }
}

/// @notice Honest curator: tracks the FAIR price and only acts when spot agrees with fair (a prudent agent does
///         not trade into a manipulated pool).
contract HonestCurator is CuratorBase {
    uint256 public immutable maxSpotDev;

    constructor(CuratedVault v, MockReferencePrice o, int24 hw, uint256 recenter, uint256 _maxSpotDev)
        CuratorBase(v, o, hw, recenter)
    {
        maxSpotDev = _maxSpotDev;
    }

    function act() external virtual override returns (bool) {
        return _actHonest();
    }

    function _actHonest() internal returns (bool) {
        if (!_cooldownOk() || hook.tierOf(id) == Tier.FROZEN) return false;
        int24 fairT = ScenarioMath.fairTick(oracle, id);
        if (ScenarioMath.absDiff(ScenarioMath.spotTick(pm, id), fairT) > maxSpotDev) return false;
        (int24 c, bool has) = _center();
        if (has && ScenarioMath.absDiff(c, fairT) <= recenterAt) return false;
        return _recenter(fairT);
    }
}

/// @notice Poisoned curator: honest until `poison()`. Its corrupted context then makes two individually "valid"
///         moves, each inside the static mandate (width, distance from fair, no swap):
///         - when spot agrees with fair, it "anticipates a move" and parks the range `parkOffset` ticks away, so an
///           attacker can push spot cheaply past it;
///         - when spot is off fair, it "follows the market" and re-centers on the manipulated spot, where the
///           attacker then arbitrages against it.
contract PoisonedCurator is HonestCurator {
    int24 public immutable parkOffset;
    bool public poisoned;

    constructor(CuratedVault v, MockReferencePrice o, int24 hw, uint256 recenter, uint256 maxSpotDev, int24 parkTicks)
        HonestCurator(v, o, hw, recenter, maxSpotDev)
    {
        parkOffset = parkTicks;
    }

    function poison() external {
        poisoned = true;
    }

    function act() external override returns (bool) {
        if (!poisoned) return _actHonest();
        if (!_cooldownOk() || hook.tierOf(id) == Tier.FROZEN) return false;
        int24 fairT = ScenarioMath.fairTick(oracle, id);
        int24 spotT = ScenarioMath.spotTick(pm, id);
        if (ScenarioMath.absDiff(spotT, fairT) <= maxSpotDev) return _park(fairT + parkOffset);
        return _recenter(spotT);
    }

    /// @dev Park with "inventory management": swap up to 5% of NAV toward a 50/50 value split at the fair price
    ///      (inside the 20% move cap), so the vault keeps enough of both tokens to be exploited again next round.
    function _park(int24 target) internal returns (bool) {
        Holdings memory h = vault.totalHoldings();
        (uint160 f,) = oracle.getSqrtPriceX96(id);
        uint256 v0 = PositionValue.navAt(Holdings(h.amount0, 0), f, false);
        uint256 cap = (v0 + h.amount1) / 20;
        int256 swapAmount;
        if (h.amount1 > v0) {
            uint256 sell1 = (h.amount1 - v0) / 2;
            swapAmount = -int256(sell1 < cap ? sell1 : cap);
        } else if (v0 > h.amount1) {
            uint256 sellValue = (v0 - h.amount1) / 2;
            if (sellValue > cap) sellValue = cap;
            swapAmount = int256(h.amount0 * sellValue / v0); // token0 amount worth sellValue
        }
        int24 c = ScenarioMath.floorTo(target, spacing);
        int24 tl = c - halfWidth;
        int24 tu = c + halfWidth;
        (uint160 spot,,,) = StateLibrary.getSlot0(pm, id);
        uint128 l = LiquidityAmounts.getLiquidityForAmounts(
            spot, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), h.amount0, h.amount1
        );
        l = uint128(uint256(l) * 90 / 100);
        uint160 limit = swapAmount > 0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        try vault.rebalance(CuratedVault.RebalanceParams(tl, tu, l, swapAmount, limit)) {
            ++actions;
            return true;
        } catch {
            ++refusals;
            return false;
        }
    }
}

/// @notice Attacker: pushes spot off fair right before the poisoned curator acts, then arbitrages it back,
///         trading against the vault's freshly mispriced liquidity. Profit is measured at the FAIR price.
contract Attacker {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable pm;
    MockReferencePrice public immutable oracle;
    TestSwapper public immutable swapper;
    PoolKey public key;
    PoolId public immutable id;
    Currency public immutable c0;
    Currency public immutable c1;

    constructor(IPoolManager _pm, MockReferencePrice _oracle, TestSwapper _swapper, PoolKey memory _key) {
        pm = _pm;
        oracle = _oracle;
        swapper = _swapper;
        key = _key;
        id = PoolId.wrap(keccak256(abi.encode(_key)));
        c0 = _key.currency0;
        c1 = _key.currency1;
    }

    /// @notice Push spot `ticks` away from fair (negative = below fair).
    function push(int24 ticks) external {
        int24 target = ScenarioMath.fairTick(oracle, id) + ticks;
        uint160 t = TickMath.getSqrtPriceAtTick(target);
        (uint160 cur,,,) = pm.getSlot0(id);
        if (cur != t) swapper.swapTo(key, t < cur, type(uint128).max, t);
    }

    /// @notice Arbitrage spot back to fair.
    function arbBack() external {
        (uint160 f,) = oracle.getSqrtPriceX96(id);
        (uint160 cur,,,) = pm.getSlot0(id);
        if (cur != f) swapper.swapTo(key, f < cur, type(uint128).max, f);
    }

    /// @notice Value (token1 units, at fair) of an account's two token balances.
    function valueAtFair(address who) external view returns (uint256) {
        (uint160 f,) = oracle.getSqrtPriceX96(id);
        return PositionValue.navAt(Holdings(c0.balanceOf(who), c1.balanceOf(who)), f, false);
    }
}
