// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {HookFixture} from "./utils/HookFixture.sol";
import {TenureHook, PoolSettings} from "../src/TenureHook.sol";
import {BudgetState} from "../src/libraries/RiskBudget.sol";
import {ReferencePriceLib} from "../src/libraries/ReferencePriceLib.sol";

/// @notice M5.4: a pool can opt out of afterSwap auto-settlement (`autoSettlePerSwap = 0`): swappers then pay no
///         markout gas, and keepers settle with the permissionless `settleMany`.
contract TenureHookKeepersTest is HookFixture {
    uint128 constant L = 1e22;
    address constant KEEPER = address(0x6EE9);

    function _fixtureSettings() internal pure override returns (PoolSettings memory s) {
        s = super._fixtureSettings();
        s.autoSettlePerSwap = 0;
    }

    function setUp() public {
        _setUpFixture();
    }

    // ---------------------------------------------------------------- opt-out
    function test_autoSettleOff_swapSettlesNothing() public {
        _makeRecords(2);
        vm.roll(vm.getBlockNumber() + WINDOW);
        _smallSwap();
        _smallSwap();
        assertFalse(hook.recordOf(poolId, 0).settled);
        assertFalse(hook.recordOf(poolId, 1).settled);
        assertEq(hook.settlePointer(poolId), 0);
    }

    function test_registerPool_rejectsAutoSettleAboveOne() public {
        PoolKey memory other = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        PoolSettings memory s = _fixtureSettings();
        s.autoSettlePerSwap = 2;
        vm.expectRevert(TenureHook.Tenure__InvalidSettings.selector);
        hook.registerPool(other, address(vault), oracle, s);
    }

    // ---------------------------------------------------------------- settleMany
    function test_settleMany_settlesDueOnly_skipsTheRest_permissionless() public {
        _makeRecords(2); // records 0, 1
        vm.roll(vm.getBlockNumber() + WINDOW);
        _makeRecords(1); // record 2: not due yet
        hook.settle(poolId, 0); // a keeper race: already settled

        uint256[] memory ids = new uint256[](4);
        (ids[0], ids[1], ids[2], ids[3]) = (0, 1, 2, 99); // settled, due, not due, unknown
        vm.prank(KEEPER);
        uint256 n = hook.settleMany(poolId, ids);
        assertEq(n, 1, "only the due, unsettled record");
        assertTrue(hook.recordOf(poolId, 1).settled);
        assertFalse(hook.recordOf(poolId, 2).settled);
        assertEq(hook.settlePointer(poolId), 2, "pointer advances past settled records");

        vm.roll(vm.getBlockNumber() + WINDOW);
        vm.prank(KEEPER);
        assertEq(hook.settleMany(poolId, ids), 1, "record 2 once due");
        assertEq(hook.settlePointer(poolId), 3);
        vm.prank(KEEPER);
        assertEq(hook.settleMany(poolId, ids), 0, "idempotent");
    }

    /// settleMany applies exactly what individual settle() calls would (same alpha, same budget state).
    function test_settleMany_equalsIndividualSettles() public {
        _makeRecords(3);
        vm.roll(vm.getBlockNumber() + WINDOW);
        uint256 clean = vm.snapshotState();
        for (uint256 i; i < 3; ++i) {
            hook.settle(poolId, i);
        }
        BudgetState memory one = hook.budgetOf(poolId);
        vm.revertToState(clean);
        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (0, 1, 2);
        assertEq(hook.settleMany(poolId, ids), 3);
        BudgetState memory many = hook.budgetOf(poolId);
        assertEq(keccak256(abi.encode(one)), keccak256(abi.encode(many)));
    }

    function test_settleMany_staleOracle_reverts() public {
        _makeRecords(1);
        vm.roll(vm.getBlockNumber() + WINDOW);
        (, uint256 updatedAt) = oracle.getSqrtPriceX96(poolId);
        vm.warp(vm.getBlockTimestamp() + MAX_ORACLE_AGE + 1);
        uint256[] memory ids = new uint256[](1);
        vm.expectRevert(
            abi.encodeWithSelector(ReferencePriceLib.Tenure__StalePrice.selector, updatedAt, MAX_ORACLE_AGE)
        );
        hook.settleMany(poolId, ids);
    }

    function test_settleMany_spotOffFair_reverts() public {
        _makeRecords(1);
        vm.roll(vm.getBlockNumber() + WINDOW);
        _pushSpotTo(-300);
        uint256[] memory ids = new uint256[](1);
        vm.expectRevert(abi.encodeWithSelector(TenureHook.Tenure__SpotOffFair.selector, uint256(300), uint256(100)));
        hook.settleMany(poolId, ids);
    }

    function test_settleMany_unregistered_reverts() public {
        PoolKey memory other = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        uint256[] memory ids = new uint256[](1);
        vm.expectRevert(TenureHook.Tenure__NotRegistered.selector);
        hook.settleMany(PoolId.wrap(_id(other)), ids);
    }

    // ---------------------------------------------------------------- gas
    /// With auto-settle off, a swap with due records costs the same as one with nothing due: no settlement overhead.
    function test_gas_afterSwap_autoSettleOff() public {
        _smallSwap();
        swapper.swapTo(key, false, 1 ether, _sqrt(100));
        uint256 g0 = _gasOfSmallSwap("afterSwap_autoOff_0_due");
        _makeRecords(3);
        vm.roll(vm.getBlockNumber() + WINDOW);
        uint256 gDue = _gasOfSmallSwap("afterSwap_autoOff_3_due");
        console2.log("auto-settle OFF: swap gas, 0 due:", g0);
        console2.log("auto-settle OFF: swap gas, 3 due:", gDue);
        assertFalse(hook.recordOf(poolId, 0).settled);
        assertLt(gDue > g0 ? gDue - g0 : 0, 2_500, "no settlement overhead for swappers");
    }

    // ---------------------------------------------------------------- helpers
    function _smallSwap() internal {
        swapper.swapTo(key, true, 1 ether, _sqrt(-100));
    }

    function _gasOfSmallSwap(string memory name) internal returns (uint256 g) {
        bool zf1 = (vm.getBlockNumber() % 2) == 0;
        swapper.swapTo(key, zf1, 1 ether, zf1 ? _sqrt(-100) : _sqrt(100));
        g = vm.snapshotGasLastCall(string.concat("TenureHook.", vm.envOr("FOUNDRY_PROFILE", string("default"))), name);
    }

    function _id(PoolKey memory k) internal pure returns (bytes32) {
        return keccak256(abi.encode(k));
    }

    /// n cheap re-ranges at fair, alternating ranges, respecting the cooldown (as in TenureHookScoring).
    function _makeRecords(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            vm.roll(vm.getBlockNumber() + 10);
            uint256 c = hook.recordCount(poolId);
            if (c % 2 == 0) {
                if (hook.currentRange(poolId).liquidity == 0) _rebalance(_ops1(-600, 600, int128(L)));
                else _rebalance(_ops2(-1200, 1200, -int128(L), -600, 600, int128(L)));
            } else {
                _rebalance(_ops2(-600, 600, -int128(L), -1200, 1200, int128(L)));
            }
        }
    }
}
