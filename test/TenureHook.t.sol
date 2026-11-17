// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {TenureTestBase} from "./utils/TenureTestBase.sol";
import {SessionVault} from "./utils/TestActors.sol";
import {TenureHook} from "../src/TenureHook.sol";
import {Range} from "../src/libraries/PositionValue.sol";
import {IReferencePrice} from "../src/interfaces/IReferencePrice.sol";
import {ReferencePriceLib} from "../src/libraries/ReferencePriceLib.sol";

contract TenureHookTest is TenureTestBase {
    using EasyPosm for IPositionManager;

    SessionVault vault;

    function setUp() public {
        _deployTenureBase();
        vault = new SessionVault(poolManager, hook);
        _fund(address(vault), 1_000_000 ether);
        hook.registerPool(key, address(vault), oracle, _settings());
    }

    function _wrapped(bytes4 hookSelector, bytes4 err) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            hookSelector,
            abi.encodeWithSelector(err),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    // ============================================================================ M2.1 permissions FIRST
    function test_00_permissionsMatchAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        IHooks h = IHooks(address(hook));
        assertTrue(p.beforeAddLiquidity && Hooks.hasPermission(h, Hooks.BEFORE_ADD_LIQUIDITY_FLAG));
        assertTrue(p.beforeRemoveLiquidity && Hooks.hasPermission(h, Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG));
        assertTrue(p.afterSwap && Hooks.hasPermission(h, Hooks.AFTER_SWAP_FLAG));
        // everything else off, in particular no return-delta permissions
        assertFalse(Hooks.hasPermission(h, Hooks.BEFORE_SWAP_FLAG));
        assertFalse(Hooks.hasPermission(h, Hooks.AFTER_ADD_LIQUIDITY_FLAG));
        assertFalse(Hooks.hasPermission(h, Hooks.AFTER_REMOVE_LIQUIDITY_FLAG));
        assertFalse(Hooks.hasPermission(h, Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG));
        assertFalse(Hooks.hasPermission(h, Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG));
        assertFalse(Hooks.hasPermission(h, Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG));
        assertFalse(Hooks.hasPermission(h, Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG));
        assertFalse(Hooks.hasPermission(h, Hooks.BEFORE_INITIALIZE_FLAG));
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS);
    }

    function test_00_callbacksFire() public {
        // beforeAddLiquidity fires: the registered vault is rejected outside a session
        vm.expectRevert(_wrapped(IHooks.beforeAddLiquidity.selector, TenureHook.Tenure__NoSession.selector));
        vault.rawModify(key, _ops1(-600, 600, 1e18));
        // afterSwap fires (no-op in M2.1): a swap through the pool succeeds with the hook attached
        _thirdPartyLiquidity();
        swapper.swapTo(key, true, 1 ether, TickMathLimits.MIN_PLUS_ONE);
    }

    // ============================================================================ M2.1 registration
    function test_register_onlyOwner() public {
        PoolKey memory k2 = key;
        k2.fee = 500;
        vm.prank(address(0xBEEF));
        vm.expectRevert(TenureHook.Tenure__NotOwner.selector);
        hook.registerPool(k2, address(vault), oracle, _settings());
    }

    function test_register_twice_reverts() public {
        vm.expectRevert(TenureHook.Tenure__AlreadyRegistered.selector);
        hook.registerPool(key, address(vault), oracle, _settings());
    }

    function test_register_wrongHook_reverts() public {
        PoolKey memory k2 = key;
        k2.hooks = IHooks(address(0));
        vm.expectRevert(TenureHook.Tenure__WrongHook.selector);
        hook.registerPool(k2, address(vault), oracle, _settings());
    }

    function test_register_emits() public {
        PoolKey memory k2 = key;
        k2.fee = 500;
        PoolId id2 = PoolId.wrap(keccak256(abi.encode(k2)));
        vm.expectEmit(true, true, false, true, address(hook));
        emit TenureHook.PoolRegistered(id2, address(0xCAFE), address(oracle));
        hook.registerPool(k2, address(0xCAFE), oracle, _settings());
    }

    // ============================================================================ M2.2 sessions
    function test_vaultModifyOutsideSession_reverts() public {
        vm.expectRevert(_wrapped(IHooks.beforeAddLiquidity.selector, TenureHook.Tenure__NoSession.selector));
        vault.rawModify(key, _ops1(-600, 600, 1e18));
    }

    function test_vaultRemoveOutsideSession_reverts() public {
        vault.rebalance(key, _ops1(-600, 600, 1e18));
        vm.expectRevert(_wrapped(IHooks.beforeRemoveLiquidity.selector, TenureHook.Tenure__NoSession.selector));
        vault.rawModify(key, _ops1(-600, 600, -1e18));
    }

    function test_vaultModifyInsideSession_succeeds_andTracksRange() public {
        vm.expectEmit(true, false, false, true, address(hook));
        emit TenureHook.RangeUpdated(poolId, -600, 600, 1e18);
        vault.rebalance(key, _ops1(-600, 600, 1e18));
        Range memory r = hook.currentRange(poolId);
        assertEq(r.tickLower, -600);
        assertEq(r.tickUpper, 600);
        assertEq(r.liquidity, 1e18);

        // move: remove all of old, add new
        vault.rebalance(key, _ops2(-600, 600, -1e18, -1200, 0, 5e17));
        r = hook.currentRange(poolId);
        assertEq(r.tickLower, -1200);
        assertEq(r.tickUpper, 0);
        assertEq(r.liquidity, 5e17);
    }

    function test_rebalance_cannotOrphanOldRange() public {
        vault.rebalance(key, _ops1(-600, 600, 1e18));
        vm.expectRevert(TenureHook.Tenure__OrphanedLiquidity.selector);
        vault.rebalance(key, _ops1(-1200, 0, 1e17)); // adds new range without removing the old
    }

    function test_rebalance_singleRangeOnly() public {
        vm.expectRevert(_wrapped(IHooks.beforeAddLiquidity.selector, TenureHook.Tenure__MultipleRanges.selector));
        vault.rebalance(key, _ops2(-600, 600, 1e18, -1200, 0, 1e18));
    }

    function test_rebalance_removeOnlyFromTrackedRange() public {
        vault.rebalance(key, _ops1(-600, 600, 1e18));
        vm.expectRevert(_wrapped(IHooks.beforeRemoveLiquidity.selector, TenureHook.Tenure__NotCurrentRange.selector));
        vault.rebalance(key, _ops2(-1200, 0, 1e17, -1200, 0, -1e17));
    }

    function test_proRata_onlyCurrentRange() public {
        vault.rebalance(key, _ops1(-600, 600, 1e18));
        vault.proRata(key, _ops1(-600, 600, 1e17)); // scale up current range: ok
        vault.proRata(key, _ops1(-600, 600, -2e17)); // scale down: ok
        assertEq(hook.currentRange(poolId).liquidity, 9e17);
        vm.expectRevert(_wrapped(IHooks.beforeAddLiquidity.selector, TenureHook.Tenure__NotCurrentRange.selector));
        vault.proRata(key, _ops1(-1200, 0, 1e17));
    }

    function test_thirdPartyLP_unaffected() public {
        // a normal LP (sender = PositionManager) adds and removes freely with no session
        (uint256 tokenId,) = _thirdPartyLiquidity();
        positionManager.decreaseLiquidity(tokenId, 1e18, 0, 0, address(this), block.timestamp, "");
    }

    function test_onlyVaultCanOpenSessions() public {
        vm.expectRevert(TenureHook.Tenure__NotVault.selector);
        hook.beginRebalance(key);
        vm.expectRevert(TenureHook.Tenure__NotVault.selector);
        hook.beginProRata(key);
        vm.expectRevert(TenureHook.Tenure__NotVault.selector);
        hook.endRebalance(key);
    }

    function test_unregisteredPool_reverts() public {
        PoolKey memory k2 = key;
        k2.fee = 500;
        vm.expectRevert(TenureHook.Tenure__NotRegistered.selector);
        hook.beginRebalance(k2);
    }

    function test_cannotNestSessions() public {
        vm.expectRevert(TenureHook.Tenure__SessionOpen.selector);
        vault.beginThen(key, 0);
        vm.expectRevert(TenureHook.Tenure__SessionOpen.selector);
        vault.beginThen(key, 1);
        vm.expectRevert(TenureHook.Tenure__WrongSession.selector);
        vault.beginThen(key, 2);
    }

    function test_endWithoutBegin_reverts() public {
        vm.expectRevert(TenureHook.Tenure__WrongSession.selector);
        vault.endOnly(key);
    }

    /// The session flag lives in transient storage, so it cannot outlive the transaction that opened it.
    /// isolate=true makes every top-level call below its own transaction, exactly as on-chain.
    /// forge-config: default.isolate = true
    function test_sessionDoesNotLeakAcrossTransactions() public {
        vault.beginOnly(key); // tx 1: open and abandon the session
        assertEq(hook.sessionOf(poolId), 0, "flag cleared after tx"); // tx 2
        vm.expectRevert(_wrapped(IHooks.beforeAddLiquidity.selector, TenureHook.Tenure__NoSession.selector));
        vault.rawModify(key, _ops1(-600, 600, 1e18)); // tx 3: no session to piggyback on
    }

    /// Within a single transaction the flag IS visible (control for the test above).
    function test_sessionVisibleWithinTransaction() public {
        assertEq(vault.beginAndRead(key), 1);
    }

    function test_staleOracle_blocksSession() public {
        oracle.setPriceAt(poolId, Constants.SQRT_PRICE_1_1, block.timestamp - MAX_ORACLE_AGE - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReferencePriceLib.Tenure__StalePrice.selector, block.timestamp - MAX_ORACLE_AGE - 1, MAX_ORACLE_AGE
            )
        );
        vault.rebalance(key, _ops1(-600, 600, 1e18));
    }

    function test_badSalt_reverts() public {
        // SessionVault always uses salt 0; prove the hook checks by calling the callback as the PoolManager
        vm.prank(address(poolManager));
        vm.expectRevert(TenureHook.Tenure__BadSalt.selector);
        hook.beforeAddLiquidity(address(vault), key, ModifyLiquidityParams(-600, 600, 1e18, bytes32(uint256(1))), "");
    }

    // ---------------------------------------------------------------------------- helpers
    function _thirdPartyLiquidity() internal returns (uint256 tokenId, uint128 liq) {
        liq = 100e18;
        (tokenId,) = positionManager.mint(
            key, -6000, 6000, liq, type(uint256).max, type(uint256).max, address(this), block.timestamp, ""
        );
    }
}

library TickMathLimits {
    uint160 constant MIN_PLUS_ONE = 4295128739 + 1;
}
