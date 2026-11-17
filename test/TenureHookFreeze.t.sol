// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

import {Vm} from "forge-std/Vm.sol";
import {HookFixture} from "./utils/HookFixture.sol";
import {SessionVault} from "./utils/TestActors.sol";
import {TenureHook} from "../src/TenureHook.sol";
import {BudgetState, Tier} from "../src/libraries/RiskBudget.sol";

/// @notice M2.5: FULL -> RESTRICTED -> FROZEN -> (guardian, timelock) -> RESTRICTED. Safe mode always allowed.
contract TenureHookFreezeTest is HookFixture {
    uint128 constant L = 1e21;
    uint256 constant LEAK = 2000 ether; // ~16% of the (0.2%-of-NAV) budget per leak

    function setUp() public {
        _setUpFixture();
        _rebalance(_ops1(-600, 600, int128(L))); // vault holds a live range
    }

    function test_transitions_FULL_RESTRICTED_FROZEN_withEvents() public {
        assertEq(uint256(hook.tierOf(poolId)), uint256(Tier.FULL));
        Tier prev = Tier.FULL;
        bool sawRestricted;
        for (uint256 i; i < 20 && prev != Tier.FROZEN; ++i) {
            vm.roll(vm.getBlockNumber() + 30);
            _leakOnce(LEAK);
            Tier t = hook.tierOf(poolId);
            assertGe(uint256(t), uint256(prev), "tier only steps down while losing");
            if (t == Tier.RESTRICTED) sawRestricted = true;
            prev = t;
        }
        assertTrue(sawRestricted, "passed through RESTRICTED");
        assertEq(uint256(prev), uint256(Tier.FROZEN));
    }

    function test_tierChanged_eventsEmitted() public {
        vm.recordLogs();
        _leakUntil(Tier.FROZEN, LEAK);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool toRestricted;
        bool toFrozen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != TenureHook.TierChanged.selector) continue;
            (Tier from, Tier to) = abi.decode(logs[i].data, (Tier, Tier));
            if (from == Tier.FULL && to == Tier.RESTRICTED) toRestricted = true;
            if (from == Tier.RESTRICTED && to == Tier.FROZEN) toFrozen = true;
        }
        assertTrue(toRestricted, "TierChanged(FULL->RESTRICTED)");
        assertTrue(toFrozen, "TierChanged(RESTRICTED->FROZEN)");
    }

    function test_frozen_blocksRebalance() public {
        _leakUntil(Tier.FROZEN, LEAK);
        vm.roll(vm.getBlockNumber() + 1000);
        vm.expectRevert(TenureHook.Tenure__Frozen.selector);
        _rebalance(_ops2(-600, 600, -int128(L), -600, 600, int128(L)));
    }

    function test_frozen_isSticky_underRefill() public {
        _leakUntil(Tier.FROZEN, LEAK);
        vm.roll(vm.getBlockNumber() + 10_000_000);
        assertEq(uint256(hook.tierOf(poolId)), uint256(Tier.FROZEN));
    }

    function test_safeMode_allowedWhenFrozen_exitsToIdle() public {
        _leakUntil(Tier.FROZEN, LEAK);
        uint128 liq = hook.currentRange(poolId).liquidity;
        vm.expectEmit(true, false, false, true, address(hook));
        emit TenureHook.SafeModeEntered(poolId, liq);
        vault.safeMode(key, -600, 600, liq);
        assertEq(hook.currentRange(poolId).liquidity, 0);
    }

    function test_safeMode_mustExitFully() public {
        uint128 liq = hook.currentRange(poolId).liquidity;
        vm.expectRevert(TenureHook.Tenure__SafeModeMustExit.selector);
        vault.safeMode(key, -600, 600, liq / 2);
    }

    function test_safeMode_cannotAdd() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(TenureHook.Tenure__NoSession.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        vault.safeModeAdd(key, -600, 600, L);
    }

    function test_proRata_allowedWhenFrozen() public {
        _leakUntil(Tier.FROZEN, LEAK);
        // withdrawals must never be blocked
        vault.proRata(key, _ops1(-600, 600, -int128(L / 2)));
        assertEq(hook.currentRange(poolId).liquidity, L / 2);
    }

    function test_restore_flow() public {
        _leakUntil(Tier.FROZEN, LEAK);

        vm.expectRevert(TenureHook.Tenure__NotGuardian.selector);
        hook.requestRestore(poolId);

        vm.prank(GUARDIAN);
        vm.expectRevert(TenureHook.Tenure__NoPendingChange.selector);
        hook.restore(poolId);

        uint256 eta = vm.getBlockNumber() + RESTORE_DELAY;
        vm.prank(GUARDIAN);
        vm.expectEmit(true, false, false, true, address(hook));
        emit TenureHook.RestoreRequested(poolId, eta);
        hook.requestRestore(poolId);

        vm.roll(eta - 1);
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(TenureHook.Tenure__Timelocked.selector, eta));
        hook.restore(poolId);

        vm.roll(eta);
        BudgetState memory before = hook.budgetOf(poolId);
        vm.prank(GUARDIAN);
        hook.restore(poolId);
        BudgetState memory b = hook.budgetOf(poolId);
        assertEq(uint256(b.tier), uint256(Tier.RESTRICTED), "autonomy re-earned: lands RESTRICTED, not FULL");
        assertEq(b.budget, before.bMax * 35 / 100);

        // curator can act again, under RESTRICTED limits (cooldown doubled is satisfied by the delay)
        _rebalance(_ops2(-600, 600, -int128(L), -600, 600, int128(L)));
    }

    function test_restore_onlyWhenFrozen() public {
        vm.prank(GUARDIAN);
        vm.expectRevert(TenureHook.Tenure__NotFrozen.selector);
        hook.requestRestore(poolId);
        vm.prank(GUARDIAN);
        vm.expectRevert(TenureHook.Tenure__NotFrozen.selector);
        hook.restore(poolId);
    }

    function test_guardian_changeOnlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(TenureHook.Tenure__NotOwner.selector);
        hook.setGuardian(address(0xBAD));
        vm.expectEmit(true, true, false, false, address(hook));
        emit TenureHook.GuardianChanged(GUARDIAN, address(0xA11CE));
        hook.setGuardian(address(0xA11CE));
        assertEq(hook.guardian(), address(0xA11CE));
    }

    /// Records keep settling while frozen (losses still recorded; frozen stays frozen).
    function test_frozen_settlementsStillApply() public {
        _leakUntil(Tier.FROZEN, LEAK);
        uint256 n = hook.recordCount(poolId);
        vm.roll(vm.getBlockNumber() + WINDOW);
        for (uint256 i; i < n; ++i) {
            if (!hook.recordOf(poolId, i).settled) hook.settle(poolId, i);
        }
        assertEq(uint256(hook.tierOf(poolId)), uint256(Tier.FROZEN));
    }
}
