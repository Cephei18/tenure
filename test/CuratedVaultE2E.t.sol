// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {stdError} from "forge-std/StdError.sol";

import {VaultFixture} from "./utils/VaultFixture.sol";
import {CuratedVault} from "../src/CuratedVault.sol";
import {TenureHook, RebalanceRecord} from "../src/TenureHook.sol";
import {Tier} from "../src/libraries/RiskBudget.sol";

/// M3.2: end-to-end deposit -> rebalance -> market swaps -> settle -> withdraw, with every token reconciled to the
/// wei. Ledger per token: the vault's idle balance must always equal
///     sum(deposits) - sum(withdrawals) + sum(net flows from the PoolManager during vault operations)
/// and the PoolManager flows are measured independently (PoolManager token balance before/after each vault call).
contract CuratedVaultE2ETest is VaultFixture {
    int256 dep0;
    int256 dep1;
    int256 wd0;
    int256 wd1;
    int256 pm0; // net tokens the vault received from the PoolManager
    int256 pm1;

    function setUp() public {
        _setUpVault();
    }

    function test_e2e_reconcilesToTheWei() public {
        // ---- deposits
        _dep(ALICE, 30_000 ether, 25_000 ether);
        _dep(BOB, 5_000 ether, 12_345 ether);
        _checkLedger("after deposits");

        // ---- curator rebalance: enter a range and swap a little token0 -> token1 at fair spot
        _pm(abi.encodeCall(CuratedVault.rebalance, (_p(-600, 600, L_RANGE / 2, 1_000 ether))), CURATOR);
        _checkLedger("after rebalance 0");
        assertEq(hook.currentRange(poolId).liquidity, L_RANGE / 2);

        // ---- market: third-party swaps both ways through the vault's range (fees accrue to the vault)
        swapper.swapTo(key, true, 3_000 ether, TickMath.MIN_SQRT_PRICE + 1);
        swapper.swapTo(key, false, 3_000 ether, TickMath.MAX_SQRT_PRICE - 1);
        _pushSpotTo(0);

        // ---- second rebalance after the cooldown: move the range
        vm.roll(vm.getBlockNumber() + 20);
        _pm(abi.encodeCall(CuratedVault.rebalance, (_p(-1200, 1200, L_RANGE / 4, -500 ether))), CURATOR);
        _checkLedger("after rebalance 1");

        // ---- settle record 0 permissionlessly after W blocks; record 1 via afterSwap auto-settle
        vm.roll(vm.getBlockNumber() + WINDOW + 1);
        hook.settle(poolId, 0);
        swapper.swapTo(key, true, 1 ether, TickMath.MIN_SQRT_PRICE + 1); // triggers afterSwap
        RebalanceRecord memory r1 = hook.recordOf(poolId, 1);
        assertTrue(hook.recordOf(poolId, 0).settled && r1.settled, "both records settled");
        assertEq(uint256(hook.tierOf(poolId)), uint256(Tier.FULL), "honest flow stays FULL");

        // ---- partial withdrawal with a live position (pro-rata session)
        uint256 bobHalf = cv.balanceOf(BOB) / 2;
        _wd(BOB, bobHalf);
        _checkLedger("after partial withdraw");

        // ---- safe mode, then exact pro-rata withdrawals from idle
        _pm(abi.encodeCall(CuratedVault.enterSafeMode, ()), CURATOR);
        assertEq(hook.currentRange(poolId).liquidity, 0);
        _checkLedger("after safe mode");

        uint256 supply = cv.totalSupply();
        uint256 idle0 = _bal0(address(cv));
        uint256 idle1 = _bal1(address(cv));
        uint256 aliceShares = cv.balanceOf(ALICE);
        (uint256 a0, uint256 a1) = _wd(ALICE, aliceShares);
        assertEq(a0, idle0 * aliceShares / supply, "exact floor pro-rata token0");
        assertEq(a1, idle1 * aliceShares / supply, "exact floor pro-rata token1");
        _wd(BOB, cv.balanceOf(BOB));
        _checkLedger("after full exit");

        // Only the dead shares remain; what is left in the vault is exactly their pro-rata claim plus rounding dust.
        assertEq(cv.totalSupply(), cv.DEAD_SHARES());
        assertEq(int256(_bal0(address(cv))), dep0 - wd0 + pm0);
        assertEq(int256(_bal1(address(cv))), dep1 - wd1 + pm1);
        assertLt(_bal0(address(cv)) + _bal1(address(cv)), 1e6 * 4, "residue ~ dead shares' tiny claim");
    }

    /// A FROZEN curator cannot rebalance through the vault; safe mode and withdrawals still work.
    function test_frozenCurator_rebalanceReverts_exitStillWorks() public {
        _deposit(ALICE, 40_000 ether, 40_000 ether);
        _curatorRebalance(-600, 600, L_RANGE, 0);
        _leakUntil(Tier.FROZEN, 4_000 ether);
        vm.roll(vm.getBlockNumber() + 100);
        vm.prank(CURATOR);
        vm.expectRevert(TenureHook.Tenure__Frozen.selector);
        cv.rebalance(_p(-600, 600, L_RANGE / 2, 0));
        vm.prank(CURATOR);
        cv.enterSafeMode();
        _withdrawAll(ALICE);
        assertEq(cv.balanceOf(ALICE), 0);
    }

    /// A rebalance the vault cannot fund reverts as a whole: no half-applied position, no open session.
    function test_unfundableRebalance_revertsAtomically() public {
        _deposit(ALICE, 1_000 ether, 1_000 ether);
        _curatorRebalance(-600, 600, 1e22, 0);
        uint128 l0 = hook.currentRange(poolId).liquidity;
        uint256 i0 = _bal0(address(cv));
        uint256 n0 = hook.recordCount(poolId);
        vm.roll(vm.getBlockNumber() + 20);
        vm.prank(CURATOR);
        vm.expectRevert(stdError.arithmeticError); // the token's balance underflow while settling
        cv.rebalance(_p(-600, 600, L_RANGE, 0)); // needs ~30k of each token; the vault has ~1k
        assertEq(hook.currentRange(poolId).liquidity, l0);
        assertEq(_bal0(address(cv)), i0);
        assertEq(hook.recordCount(poolId), n0);
        assertEq(hook.sessionOf(poolId), 0);
    }

    // ---------------------------------------------------------------------------------------------- helpers
    function _p(int24 tl, int24 tu, uint128 l, int256 swapAmount)
        internal
        pure
        returns (CuratedVault.RebalanceParams memory)
    {
        uint160 limit = swapAmount > 0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        return CuratedVault.RebalanceParams(tl, tu, l, swapAmount, limit);
    }

    function _dep(address who, uint256 a0, uint256 a1) internal {
        uint256 u0 = _bal0(who);
        uint256 u1 = _bal1(who);
        _deposit(who, a0, a1);
        assertEq(u0 - _bal0(who), a0, "user paid exactly a0");
        assertEq(u1 - _bal1(who), a1, "user paid exactly a1");
        dep0 += int256(a0);
        dep1 += int256(a1);
    }

    function _wd(address who, uint256 shares) internal returns (uint256 o0, uint256 o1) {
        uint256 u0 = _bal0(who);
        uint256 u1 = _bal1(who);
        uint256 p0 = _bal0(address(poolManager));
        uint256 p1 = _bal1(address(poolManager));
        vm.prank(who);
        (o0, o1) = cv.withdraw(shares, 0, 0, who);
        assertEq(_bal0(who) - u0, o0, "user received exactly o0");
        assertEq(_bal1(who) - u1, o1, "user received exactly o1");
        pm0 += int256(p0) - int256(_bal0(address(poolManager)));
        pm1 += int256(p1) - int256(_bal1(address(poolManager)));
        wd0 += int256(o0);
        wd1 += int256(o1);
    }

    /// Call the vault as `who` and record the PoolManager's token flow to/from the vault during the call.
    function _pm(bytes memory data, address who) internal {
        uint256 p0 = _bal0(address(poolManager));
        uint256 p1 = _bal1(address(poolManager));
        vm.prank(who);
        (bool ok, bytes memory ret) = address(cv).call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        pm0 += int256(p0) - int256(_bal0(address(poolManager)));
        pm1 += int256(p1) - int256(_bal1(address(poolManager)));
    }

    function _checkLedger(string memory label) internal view {
        assertEq(int256(_bal0(address(cv))), dep0 - wd0 + pm0, label);
        assertEq(int256(_bal1(address(cv))), dep1 - wd1 + pm1, label);
    }
}
