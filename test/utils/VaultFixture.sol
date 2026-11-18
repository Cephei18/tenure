// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {TenureTestBase} from "./TenureTestBase.sol";
import {PoolSettings, Mandate} from "../../src/TenureHook.sol";
import {Tier} from "../../src/libraries/RiskBudget.sol";
import {CuratedVault} from "../../src/CuratedVault.sol";

/// @dev Hook + a real CuratedVault registered for the pool + deep third-party liquidity + funded actors.
abstract contract VaultFixture is TenureTestBase {
    using StateLibrary for IPoolManager;

    CuratedVault cv;
    address constant CURATOR = address(0xC0A7);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant EVE = address(0xE5E);
    uint24 constant MAX_DEPOSIT_DEV = 50; // ticks (~0.5%)
    uint128 constant L_RANGE = 1e24; // fits in a 40k/40k vault for a +-600 tick range at price 1

    /// @dev Real mandate rules and a small budget (0.2% of NAV) so a few measured leaks walk the tiers.
    function _vaultSettings() internal view virtual returns (PoolSettings memory s) {
        s = _settings();
        s.mandate = Mandate({minWidth: 120, maxWidth: 12_000, maxCenterDist: 3000, maxMoveWad: 0.2e18, cooldown: 10});
        s.budget.bMax0 = 2e15;
        s.budget.bMaxCap = 1e16;
        s.budget.refillRate = uint256(2e15) / 7200;
    }

    /// @dev Full-range third-party liquidity. Scenarios override it with a shallower pool so the vault's
    ///      concentrated liquidity matters (and an attack against it can pay).
    function _thirdPartyLiquidity() internal pure virtual returns (uint128) {
        return 1e27;
    }

    function _setUpVault() internal {
        _deployTenureBase();
        cv = new CuratedVault(poolManager, hook, key, address(this), CURATOR, MAX_DEPOSIT_DEV, "Tenure Vault", "tnV");
        hook.registerPool(key, address(cv), oracle, _vaultSettings());
        _fund(address(swapper), 1e29);
        _fund(address(this), 1_000_000_000 ether);
        _deepLiquidity(_thirdPartyLiquidity());
        address[3] memory users = [ALICE, BOB, EVE];
        for (uint256 i; i < 3; ++i) {
            _fund(users[i], 1_000_000 ether);
            vm.startPrank(users[i]);
            MockERC20(Currency.unwrap(currency0)).approve(address(cv), type(uint256).max);
            MockERC20(Currency.unwrap(currency1)).approve(address(cv), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------------------------------------------ actions
    function _deposit(address who, uint256 a0, uint256 a1) internal returns (uint256 shares) {
        vm.prank(who);
        shares = cv.deposit(a0, a1, 0, who);
    }

    function _withdrawAll(address who) internal returns (uint256 out0, uint256 out1) {
        uint256 s = cv.balanceOf(who);
        vm.prank(who);
        (out0, out1) = cv.withdraw(s, 0, 0, who);
    }

    function _curatorRebalance(int24 tl, int24 tu, uint128 l, int256 swapAmount) internal returns (uint256 id) {
        uint160 limit = swapAmount > 0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.prank(CURATOR);
        id = cv.rebalance(CuratedVault.RebalanceParams(tl, tu, l, swapAmount, limit));
    }

    /// @dev Push pool spot to `tick` with a third-party swap (fair price unchanged).
    function _pushSpotTo(int24 tick) internal {
        uint160 target = TickMath.getSqrtPriceAtTick(tick);
        (uint160 cur,,,) = poolManager.getSlot0(poolId);
        if (target == cur) return;
        swapper.swapTo(key, target < cur, 1e29, target);
    }

    /// @dev One measured, individually "valid" bad decision: spot pushed ~3% below fair, the curator sells
    ///      `amountIn` token0 at that price inside a measured rebalance (re-adding L_RANGE/2 to the same range so the
    ///      vault can fund it at the pushed spot), spot restored.
    function _leakOnce(uint256 amountIn) internal {
        vm.roll(vm.getBlockNumber() + 30);
        _pushSpotTo(-300);
        _curatorRebalance(-600, 600, L_RANGE / 2, int256(amountIn));
        _pushSpotTo(0);
    }

    function _leakUntil(Tier target, uint256 amountIn) internal {
        for (uint256 i; i < 40 && uint256(hook.tierOf(poolId)) < uint256(target); ++i) {
            _leakOnce(amountIn);
        }
        assertEq(uint256(hook.tierOf(poolId)), uint256(target), "reached target tier");
    }

    function _bal0(address who) internal view returns (uint256) {
        return currency0.balanceOf(who);
    }

    function _bal1(address who) internal view returns (uint256) {
        return currency1.balanceOf(who);
    }
}
