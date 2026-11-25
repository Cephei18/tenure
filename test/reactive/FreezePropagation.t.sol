// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReactiveNetworkSim, CallbackResult} from "./utils/ReactiveNetworkSim.sol";
import {AbstractPayer} from "reactive-lib-omni/base/AbstractPayer.sol";
import {AbstractCallback} from "reactive-lib-omni/base/AbstractCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VaultFixture} from "../utils/VaultFixture.sol";
import {TenureHook, Mandate} from "../../src/TenureHook.sol";
import {CuratedVault} from "../../src/CuratedVault.sol";
import {Tier} from "../../src/libraries/RiskBudget.sol";
import {TenureFreezeReceiver} from "../../src/reactive/TenureFreezeReceiver.sol";
import {TenureFreezeRC} from "../../src/reactive/TenureFreezeRC.sol";

/// @dev Stands in for chain B's TenureHook: emits the exact TierChanged event shape.
contract TierEmitter {
    event TierChanged(PoolId indexed poolId, Tier from, Tier to);

    function emitTier(PoolId id, Tier from, Tier to) external {
        emit TierChanged(id, from, to);
    }
}

/// @notice M4.5b: a curator FROZEN on one chain is blocked on the other, through the Reactive Network, without a
///         single byte added to TenureHook. Chain A = the fixture's real hook, pool and vault (driven to FROZEN by
///         real measured leaks). Chain B = a second real CuratedVault (second pool on the same hook binary) whose
///         tier events come from a TierEmitter standing in for chain B's hook.
///         The Reactive Network is ReactiveNetworkSim: the system contract calls react() and bills, the callback proxy
///         injects the requesting RC and bills the receiver, exactly as on Lasna / Unichain Sepolia.
contract FreezePropagationTest is VaultFixture, ReactiveNetworkSim {
    uint256 constant CHAIN_A = 1301;
    uint256 constant CHAIN_B = 84532;
    address constant STRANGER = address(0xBAD);

    PoolKey keyB;
    PoolId poolIdB;
    CuratedVault cvB;
    TierEmitter hookB;
    TenureFreezeReceiver recvA;
    TenureFreezeReceiver recvB;
    TenureFreezeRC rc;

    function setUp() public {
        _setUpVault();
        _deposit(ALICE, 40_000 ether, 40_000 ether);
        _curatorRebalance(-600, 600, L_RANGE, 0);

        // chain B: a second pool + vault for the same curator
        keyB = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        poolIdB = PoolId.wrap(keccak256(abi.encode(keyB)));
        poolManager.initialize(keyB, _sqrt(0));
        oracle.setPrice(poolIdB, _sqrt(0));
        cvB = new CuratedVault(poolManager, hook, keyB, address(this), address(this), 50, "Tenure B", "tnB");
        hook.registerPool(keyB, address(cvB), oracle, _vaultSettings());
        vm.startPrank(ALICE);
        MockERC20(Currency.unwrap(currency0)).approve(address(cvB), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(cvB), type(uint256).max);
        cvB.deposit(1_000 ether, 1_000 ether, 0, ALICE);
        vm.stopPrank();
        hookB = new TierEmitter();

        _setUpReactiveNetwork();
        // The receivers trust exactly one callback sender: the RC, deployed two creations later. (Nothing else may run
        // in between: in setUp, forge also bumps the test contract's nonce on plain external calls.)
        address rcAddr = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        recvA = new TenureFreezeReceiver(address(proxy), rcAddr);
        recvB = new TenureFreezeReceiver(address(proxy), rcAddr);
        rc = new TenureFreezeRC(
            TenureFreezeRC.Endpoint(CHAIN_A, address(hook), PoolId.unwrap(poolId), address(cv), address(recvA)),
            TenureFreezeRC.Endpoint(CHAIN_B, address(hookB), PoolId.unwrap(poolIdB), address(cvB), address(recvB))
        );
        assertEq(address(rc), rcAddr, "predicted RC address");
        cv.setFreezeReceiver(address(recvA));
        cvB.setFreezeReceiver(address(recvB));
        // Funded the documented way: reserves via depositTo (never a plain transfer to the contract).
        sys.depositTo{value: 1 ether}(address(rc));
        proxy.depositTo{value: 0.1 ether}(address(recvA));
        proxy.depositTo{value: 0.1 ether}(address(recvB));
    }

    /// Driven through the simulator so every event of the leaks (including TierChanged -> FROZEN) reaches the RC.
    function leakToFrozen() external {
        _leakUntil(Tier.FROZEN, 3_000 ether);
    }

    // ------------------------------------------------------------------ propagation
    function test_topic_matchesTheHook() public view {
        assertEq(bytes32(rc.TIER_TOPIC()), TenureHook.TierChanged.selector);
    }

    function test_frozenOnA_blocksCuratorOnB_withdrawalsStayOpen() public {
        _rebalanceB(); // works before the freeze
        CallbackResult[] memory r = triggerAndReact(address(this), abi.encodeCall(this.leakToFrozen, ()), CHAIN_A);
        assertEq(uint256(hook.tierOf(poolId)), uint256(Tier.FROZEN), "really frozen on A by measured leaks");
        assertCallbackCount(r, 1); // FULL->RESTRICTED is ignored; only the FROZEN transition is relayed
        assertCallbackSuccess(r, 0);
        assertCallbackEmitted(r, address(recvB));
        assertTrue(cvB.relayFrozen(), "B is relay-frozen");
        assertFalse(cv.relayFrozen(), "no echo back to A");

        vm.roll(vm.getBlockNumber() + 100); // past any cooldown: the block is the relay flag, not timing
        vm.expectRevert(CuratedVault.Tenure__RelayFrozen.selector);
        cvB.rebalance(CuratedVault.RebalanceParams(-200, 200, 1e20, 0, 0));

        uint256 shares = cvB.balanceOf(ALICE);
        vm.prank(ALICE);
        (uint256 o0, uint256 o1) = cvB.withdraw(shares, 0, 0, ALICE);
        assertGt(o0 + o1, 0, "withdrawals never blocked by a relayed freeze");
        cvB.enterSafeMode(); // de-risking stays allowed (owner)
    }

    function test_frozenOnB_blocksCuratorOnA() public {
        CallbackResult[] memory r = triggerAndReact(
            address(hookB), abi.encodeCall(TierEmitter.emitTier, (poolIdB, Tier.RESTRICTED, Tier.FROZEN)), CHAIN_B
        );
        assertCallbackCount(r, 1);
        assertCallbackSuccess(r, 0);
        assertCallbackEmitted(r, address(recvA));
        assertTrue(cv.relayFrozen());
        assertEq(uint256(hook.tierOf(poolId)), uint256(Tier.FULL), "A's own tier is untouched: a separate flag");
        vm.roll(vm.getBlockNumber() + 100);
        vm.prank(CURATOR);
        vm.expectRevert(CuratedVault.Tenure__RelayFrozen.selector);
        cv.rebalance(CuratedVault.RebalanceParams(-1200, 1200, L_RANGE / 2, 0, 0));
    }

    function test_nonFrozenTransitions_otherPools_otherChains_areIgnored() public {
        bytes memory toRestricted = abi.encodeCall(TierEmitter.emitTier, (poolIdB, Tier.FULL, Tier.RESTRICTED));
        assertNoCallbacks(triggerAndReact(address(hookB), toRestricted, CHAIN_B));
        bytes memory otherPool = abi.encodeCall(TierEmitter.emitTier, (poolId, Tier.RESTRICTED, Tier.FROZEN));
        assertNoCallbacks(triggerAndReact(address(hookB), otherPool, CHAIN_B));
        bytes memory frozenB = abi.encodeCall(TierEmitter.emitTier, (poolIdB, Tier.RESTRICTED, Tier.FROZEN));
        assertNoCallbacks(triggerAndReact(address(hookB), frozenB, CHAIN_A)); // right emitter, wrong chain
        assertFalse(cv.relayFrozen());
    }

    // ------------------------------------------------------------------ duplicates and replays
    function test_duplicateNotification_relaysOnce_untilANewEpisode() public {
        bytes memory frozenB = abi.encodeCall(TierEmitter.emitTier, (poolIdB, Tier.RESTRICTED, Tier.FROZEN));
        assertCallbackCount(triggerAndReact(address(hookB), frozenB, CHAIN_B), 1);
        assertNoCallbacks(triggerAndReact(address(hookB), frozenB, CHAIN_B)); // duplicate: same episode
        // B's guardian restores (FROZEN -> RESTRICTED), then B freezes again: a new episode is relayed.
        bytes memory restored = abi.encodeCall(TierEmitter.emitTier, (poolIdB, Tier.FROZEN, Tier.RESTRICTED));
        assertNoCallbacks(triggerAndReact(address(hookB), restored, CHAIN_B));
        assertCallbackCount(triggerAndReact(address(hookB), frozenB, CHAIN_B), 1);
    }

    /// A replayed callback (same payload delivered again by the proxy) can only re-set the flag: idempotent, and it
    /// can never unfreeze. The only way back is the local guardian.
    function test_replayedCallback_isIdempotent_andOnlyTheGuardianClears() public {
        bytes memory payload =
            abi.encodeCall(TenureFreezeReceiver.freeze, (address(0), address(cv), CHAIN_B, bytes32(0)));
        (bool ok,) = proxy.execute(address(rc), address(recvA), payload, 200_000);
        assertTrue(ok);
        (ok,) = proxy.execute(address(rc), address(recvA), payload, 200_000);
        assertTrue(ok, "replay does not revert");
        assertTrue(cv.relayFrozen());

        address[4] memory notGuardian = [address(this), CURATOR, address(recvA), STRANGER];
        for (uint256 i; i < 4; ++i) {
            vm.prank(notGuardian[i]);
            vm.expectRevert(CuratedVault.Tenure__NotGuardian.selector);
            cv.clearRelayFreeze();
        }
        vm.prank(GUARDIAN);
        cv.clearRelayFreeze();
        assertFalse(cv.relayFrozen());
        vm.roll(vm.getBlockNumber() + 100);
        _curatorRebalance(-1200, 1200, L_RANGE / 2, 0); // curator works again on A

        (ok,) = proxy.execute(address(rc), address(recvA), payload, 200_000); // a stale replay after the clear
        assertTrue(cv.relayFrozen(), "worst case of a replay: re-freeze (safe direction), never unfreeze");
    }

    // ------------------------------------------------------------------ SAFETY INVARIANT: the relay can only freeze
    function test_invariant_receiverCanOnlyFreeze() public {
        // (1) the receiver contract itself, as msg.sender, cannot do anything but relayFreeze on a vault or the hook
        vm.startPrank(address(recvA));
        vm.expectRevert(CuratedVault.Tenure__NotGuardian.selector);
        cv.clearRelayFreeze();
        vm.expectRevert(CuratedVault.Tenure__NotOwner.selector);
        cv.setFreezeReceiver(address(0));
        vm.expectRevert(CuratedVault.Tenure__NotOwner.selector);
        cv.setCurator(STRANGER);
        vm.expectRevert(CuratedVault.Tenure__NotOwner.selector);
        cv.transferOwnership(STRANGER);
        vm.expectRevert(CuratedVault.Tenure__NotCurator.selector);
        cv.rebalance(CuratedVault.RebalanceParams(-1200, 1200, 1, 0, 0));
        vm.expectRevert(CuratedVault.Tenure__NotSafeModeCaller.selector);
        cv.enterSafeMode();
        vm.expectRevert(TenureHook.Tenure__NotGuardian.selector);
        hook.restore(poolId);
        vm.expectRevert(TenureHook.Tenure__NotGuardian.selector);
        hook.requestRestore(poolId);
        vm.expectRevert(TenureHook.Tenure__NotOwner.selector);
        hook.proposeMandate(poolId, Mandate(120, 12_000, 3000, 0.2e18, 10));
        vm.stopPrank();

        // (2) through the callback proxy as our RC, any payload other than freeze(...) fails
        bytes[3] memory other = [
            abi.encodeWithSignature("clearRelayFreeze()"),
            abi.encodeWithSignature("unfreeze(address,address)", address(0), address(cv)),
            abi.encodeWithSignature("settleMany(address,bytes32,uint256[])", address(0), poolId, new uint256[](0))
        ];
        for (uint256 i; i < 3; ++i) {
            (bool ok,) = proxy.execute(address(rc), address(recvA), other[i], 200_000);
            assertFalse(ok, "receiver exposes no non-freeze action");
        }
        assertFalse(cv.relayFrozen());

        // (3) the vault accepts relayFreeze only from its own receiver
        vm.prank(STRANGER);
        vm.expectRevert(CuratedVault.Tenure__NotFreezeReceiver.selector);
        cv.relayFreeze(CHAIN_B, bytes32(0));
        vm.prank(address(recvB)); // chain B's receiver is not A's
        vm.expectRevert(CuratedVault.Tenure__NotFreezeReceiver.selector);
        cv.relayFreeze(CHAIN_B, bytes32(0));
    }

    function test_receiver_auth() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, STRANGER, address(proxy)));
        recvA.freeze(address(rc), address(cv), CHAIN_B, bytes32(0));

        // Through the real proxy, a callback requested by ANY other reactive contract is rejected.
        bytes memory payload =
            abi.encodeCall(TenureFreezeReceiver.freeze, (address(0), address(cv), CHAIN_B, bytes32(0)));
        (bool ok, bytes memory ret) = proxy.execute(STRANGER, address(recvA), payload, 200_000);
        assertFalse(ok, "a foreign RC cannot drive our receiver");
        assertEq(ret, abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, STRANGER, address(rc)));

        vm.prank(STRANGER);
        TenureFreezeReceiver foreign = new TenureFreezeReceiver(address(proxy), STRANGER); // bound to another RC
        cv.setFreezeReceiver(address(foreign));
        proxy.depositTo{value: 0.1 ether}(address(foreign));
        (ok,) = proxy.execute(address(rc), address(foreign), payload, 200_000);
        assertFalse(ok, "our RC cannot drive a receiver bound to another RC");
        assertFalse(cv.relayFrozen());
    }

    function test_unsetReceiver_disablesRelay() public {
        cv.setFreezeReceiver(address(0));
        bytes memory payload =
            abi.encodeCall(TenureFreezeReceiver.freeze, (address(0), address(cv), CHAIN_B, bytes32(0)));
        (bool ok,) = proxy.execute(address(rc), address(recvA), payload, 200_000);
        assertFalse(ok);
        assertFalse(cv.relayFrozen());
    }

    // ------------------------------------------------------------------ helpers
    function _rebalanceB() internal {
        cvB.rebalance(CuratedVault.RebalanceParams(-200, 200, 1e20, 0, 0));
    }

    function _sqrt(int24 t) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(t);
    }
}
