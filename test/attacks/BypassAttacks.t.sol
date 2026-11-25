// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

import {VaultFixture} from "../utils/VaultFixture.sol";
import {SessionVault} from "../utils/TestActors.sol";
import {TenureHook, Mandate} from "../../src/TenureHook.sol";
import {CuratedVault} from "../../src/CuratedVault.sol";
import {Range} from "../../src/libraries/PositionValue.sol";
import {Tier} from "../../src/libraries/RiskBudget.sol";

/// M5.2 attack suite: a curator (or anyone) trying to act on the vault's liquidity OUTSIDE a measured session.
/// The curator is untrusted and off-chain: its only lever is `vault.rebalance`, which always opens a session.
contract BypassAttacksTest is VaultFixture {
    function setUp() public {
        _setUpVault();
        _deposit(ALICE, 40_000 ether, 40_000 ether);
        _curatorRebalance(-600, 600, L_RANGE, 0);
    }

    /// The hook's session entry points answer only to the registered vault, never to the curator or anyone else.
    function test_curatorCannotDriveHookSessionsDirectly() public {
        address[2] memory callers = [CURATOR, EVE];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(TenureHook.Tenure__NotVault.selector);
            hook.beginRebalance(key);
            vm.expectRevert(TenureHook.Tenure__NotVault.selector);
            hook.endRebalance(key);
            vm.expectRevert(TenureHook.Tenure__NotVault.selector);
            hook.beginProRata(key);
            vm.expectRevert(TenureHook.Tenure__NotVault.selector);
            hook.endProRata(key);
            vm.expectRevert(TenureHook.Tenure__NotVault.selector);
            hook.beginSafeMode(key);
            vm.expectRevert(TenureHook.Tenure__NotVault.selector);
            hook.endSafeMode(key, 0);
            vm.stopPrank();
        }
    }

    /// v4 keys a position by (owner, ticks, salt), and the owner is whoever called modifyLiquidity. A curator
    /// calling the PoolManager directly on the vault's exact ticks only ever touches ITS OWN position: it can add
    /// (that is just third-party liquidity) but cannot remove a single unit of the vault's.
    function test_directPoolManagerCalls_cannotTouchVaultPosition() public {
        Range memory before = hook.currentRange(poolId);
        (uint256 nav0,) = cv.nav(false);

        SessionVault rogue = new SessionVault(poolManager, hook); // the curator's own contract, not registered
        _fund(address(rogue), 1_000_000 ether);
        rogue.rawModify(key, _ops1(before.tickLower, before.tickUpper, 1e20)); // adds its own position: allowed
        // The rogue's own position holds only 1e20: removing the vault's L underflows it (v4 LiquidityMath.addDelta).
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        rogue.rawModify(key, _ops1(before.tickLower, before.tickUpper, -int256(uint256(before.liquidity))));

        Range memory afterR = hook.currentRange(poolId);
        assertEq(afterR.liquidity, before.liquidity, "vault liquidity untouched");
        (uint256 nav1,) = cv.nav(false);
        assertEq(nav1, nav0, "vault NAV untouched");
    }

    /// The vault's unlock callback (where its liquidity actually moves) answers only to the PoolManager, so no one
    /// can replay a REBALANCE/WITHDRAW payload into it from outside an unlock the vault itself started.
    function test_vaultUnlockCallback_onlyPoolManager() public {
        bytes memory payload = abi.encode(uint8(0), abi.encode(CuratedVault.RebalanceParams(-1200, 1200, 1, 0, 0)));
        vm.prank(CURATOR);
        vm.expectRevert(CuratedVault.Tenure__NotPoolManager.selector);
        cv.unlockCallback(payload);
    }

    /// Hook callbacks cannot be called directly (e.g. to fake a session-close or skip a gate).
    function test_hookCallbacks_onlyPoolManager() public {
        ModifyLiquidityParams memory p = ModifyLiquidityParams(-600, 600, -1, bytes32(0));
        vm.prank(CURATOR);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeRemoveLiquidity(address(cv), key, p, "");
    }

    /// The curator cannot rewrite its own constraints or restore itself.
    function test_curatorCannotChangeMandateOrRestore() public {
        vm.startPrank(CURATOR);
        vm.expectRevert(TenureHook.Tenure__NotOwner.selector);
        hook.proposeMandate(poolId, Mandate(60, 200_000, 100_000, 1e18, 0));
        vm.expectRevert(TenureHook.Tenure__NotGuardian.selector);
        hook.requestRestore(poolId);
        vm.expectRevert(CuratedVault.Tenure__NotOwner.selector);
        cv.setCurator(EVE);
        vm.stopPrank();
    }

    /// Once FROZEN, the only liquidity paths left are de-risking ones: rebalance reverts, safe mode and withdrawals
    /// work, and a pro-rata (withdraw) session cannot be used to re-range (TenureHook.t.sol: proRata_onlyCurrentRange).
    function test_frozenCurator_hasNoLiquidityPathExceptDeRisking() public {
        _leakUntil(Tier.FROZEN, 2_000 ether);
        vm.roll(vm.getBlockNumber() + 100);
        vm.prank(CURATOR);
        vm.expectRevert(TenureHook.Tenure__Frozen.selector);
        cv.rebalance(CuratedVault.RebalanceParams(-1200, 1200, L_RANGE / 4, 0, 0));
        vm.prank(CURATOR);
        cv.enterSafeMode();
        assertEq(hook.currentRange(poolId).liquidity, 0, "safe mode pulled everything to idle");
        (uint256 o0, uint256 o1) = _withdrawAll(ALICE);
        assertGt(o0 + o1, 0, "depositor exits");
    }
}
