// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReactiveNetworkSim, CallbackResult} from "./utils/ReactiveNetworkSim.sol";
import {AbstractPayer} from "reactive-lib-omni/base/AbstractPayer.sol";
import {AbstractCallback} from "reactive-lib-omni/base/AbstractCallback.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";

import {VaultFixture} from "../utils/VaultFixture.sol";
import {TenureHook, PoolSettings} from "../../src/TenureHook.sol";
import {CuratedVault} from "../../src/CuratedVault.sol";
import {TenureReactiveReceiver, ITenureSettle} from "../../src/reactive/TenureReactiveReceiver.sol";
import {TenureSettlerRC} from "../../src/reactive/TenureSettlerRC.sol";

/// @notice M4.5a: keeper-free markout settlement through the Reactive Network, simulated with ReactiveNetworkSim (billing system contract + callback proxy, as on Lasna).
///         Real hook + real CuratedVault on the "origin" chain; TenureSettlerRC reacts to the hook's events and cron;
///         the callback proxy calls TenureReactiveReceiver, which calls the hook's permissionless settleMany.
contract ReactiveSettlementTest is VaultFixture, ReactiveNetworkSim {
    uint256 constant ORIGIN = 1301; // a label for the hook's chain (e.g. Unichain Sepolia)
    uint256 constant DELAY = 50; // = WINDOW: in the simulator the hook and the RC share one block clock
    address constant STRANGER = address(0xBAD);

    TenureReactiveReceiver receiver;
    TenureSettlerRC rc;

    /// Pools settled by Reactive opt out of afterSwap auto-settlement.
    function _vaultSettings() internal view override returns (PoolSettings memory s) {
        s = super._vaultSettings();
        s.autoSettlePerSwap = 0;
    }

    function setUp() public {
        _setUpVault();
        _deposit(ALICE, 40_000 ether, 40_000 ether);
        cv.setCurator(address(this)); // the test drives rebalances through the simulator as the curator
        _setUpReactiveNetwork();
        address rcAddr = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        receiver = new TenureReactiveReceiver(address(proxy), ITenureSettle(address(hook)), rcAddr);
        rc = new TenureSettlerRC(
            ORIGIN, ORIGIN, address(hook), PoolId.unwrap(poolId), address(receiver), DELAY, REACTIVE_CHAIN_ID, CRON_10
        );
        assertEq(address(rc), rcAddr, "predicted RC address");
        sys.depositTo{value: 1 ether}(address(rc)); // reserves, the documented way
        proxy.depositTo{value: 0.1 ether}(address(receiver));
    }

    // ------------------------------------------------------------------ happy path
    function test_eventTopics_matchTheHook() public view {
        assertEq(bytes32(rc.SCORED_TOPIC()), TenureHook.RebalanceScored.selector);
        assertEq(bytes32(rc.SETTLED_TOPIC()), TenureHook.MarkoutSettled.selector);
    }

    function test_scoredRecord_isSettledByCallback_onlyAfterTheDelay() public {
        CallbackResult[] memory r = _rebalance(-600, 600);
        assertNoCallbacks(r);
        assertEq(rc.pendingCount(), 1, "queued from RebalanceScored");

        r = advanceAndTriggerCron(DELAY - 1, CRON_10);
        assertNoCallbacks(r);
        assertFalse(hook.recordOf(poolId, 0).settled, "not before the delay");

        r = advanceAndTriggerCron(1, CRON_10);
        assertCallbackCount(r, 1);
        assertCallbackSuccess(r, 0);
        assertCallbackEmitted(r, address(receiver));
        assertEq(abi.decode(r[0].returnData, (uint256)), 1, "receiver settled one record");
        assertTrue(hook.recordOf(poolId, 0).settled, "markout settled via Reactive");
        assertEq(hook.settlePointer(poolId), 1);
    }

    function test_batch_oneCallbackSettlesAllDueRecords() public {
        _rebalance(-600, 600);
        vm.roll(vm.getBlockNumber() + 10);
        _rebalance(-1200, 1200);
        vm.roll(vm.getBlockNumber() + 10);
        _rebalance(-600, 600);
        assertEq(rc.pendingCount(), 3);

        CallbackResult[] memory r = advanceAndTriggerCron(DELAY, CRON_10);
        assertCallbackCount(r, 1);
        assertCallbackSuccess(r, 0);
        assertEq(abi.decode(r[0].returnData, (uint256)), 3);
        for (uint256 i; i < 3; ++i) {
            assertTrue(hook.recordOf(poolId, i).settled);
        }
    }

    /// Records settled by any other path (keeper, settle()) are dropped from the queue by MarkoutSettled.
    function test_settledElsewhere_isDropped() public {
        _rebalance(-600, 600);
        vm.roll(vm.getBlockNumber() + WINDOW);
        CallbackResult[] memory r =
            triggerAndReact(address(hook), abi.encodeCall(TenureHook.settle, (poolId, uint256(0))), ORIGIN);
        assertNoCallbacks(r);
        assertEq(rc.pendingCount(), 0, "dropped on MarkoutSettled");
        assertNoCallbacks(triggerCron(CRON_10));
    }

    /// A callback that reverts (stale oracle) leaves the record pending; it is re-sent after the delay.
    function test_failedCallback_isRetried() public {
        _rebalance(-600, 600);
        vm.roll(vm.getBlockNumber() + DELAY);
        vm.warp(vm.getBlockTimestamp() + MAX_ORACLE_AGE + 1); // the oracle goes stale
        CallbackResult[] memory r = triggerCron(CRON_10);
        assertCallbackCount(r, 1);
        assertCallbackFailure(r, 0);
        assertFalse(hook.recordOf(poolId, 0).settled);
        assertEq(rc.pendingCount(), 1, "still pending");

        assertNoCallbacks(advanceAndTriggerCron(DELAY - 1, CRON_10)); // no spam before the retry interval
        (uint160 fair,) = oracle.getSqrtPriceX96(poolId);
        oracle.setPrice(poolId, fair); // the feed recovers
        r = advanceAndTriggerCron(1, CRON_10);
        assertCallbackCount(r, 1);
        assertCallbackSuccess(r, 0);
        assertTrue(hook.recordOf(poolId, 0).settled);
    }

    function test_otherPoolsAndContracts_areIgnored() public {
        IReactive.LogRecord memory log;
        log.chainId = ORIGIN;
        log.contractAddress = address(hook);
        log.topic0 = rc.SCORED_TOPIC();
        log.topic1 = uint256(keccak256("another pool"));
        log.topic2 = 7;
        vm.startPrank(SYSTEM_ADDR);
        rc.react(log);
        log.topic1 = uint256(PoolId.unwrap(poolId));
        log.contractAddress = STRANGER; // same event shape from a different contract
        rc.react(log);
        log.contractAddress = address(hook);
        log.chainId = ORIGIN + 1; // right contract address, wrong chain
        rc.react(log);
        vm.stopPrank();
        assertEq(rc.pendingCount(), 0);
    }

    // ------------------------------------------------------------------ authorization
    /// Only the system contract may call react(): a forged notification cannot queue or flush anything.
    function test_react_onlySystem() public {
        IReactive.LogRecord memory log;
        log.chainId = ORIGIN;
        log.contractAddress = address(hook);
        log.topic0 = rc.SCORED_TOPIC();
        log.topic1 = uint256(PoolId.unwrap(poolId));
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, STRANGER, SYSTEM_ADDR));
        rc.react(log);
    }

    function test_receiver_rejectsDirectCalls() public {
        uint256[] memory ids = new uint256[](1);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, STRANGER, address(proxy)));
        receiver.settleMany(address(rc), poolId, ids);
    }

    function test_receiver_rejectsForeignCallbackSender() public {
        uint256[] memory ids = new uint256[](1);
        bytes memory payload = abi.encodeCall(TenureReactiveReceiver.settleMany, (address(0), poolId, ids));
        // another reactive contract requests a callback to OUR receiver
        (bool ok, bytes memory ret) = proxy.execute(STRANGER, address(receiver), payload, 1_000_000);
        assertFalse(ok, "only our RC may spend this receiver's callback fees");
        assertEq(ret, abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, STRANGER, address(rc)));

        vm.prank(STRANGER); // someone else's receiver, bound to their RC
        TenureReactiveReceiver foreign =
            new TenureReactiveReceiver(address(proxy), ITenureSettle(address(hook)), STRANGER);
        proxy.depositTo{value: 0.1 ether}(address(foreign));
        (ok,) = proxy.execute(address(rc), address(foreign), payload, 1_000_000);
        assertFalse(ok, "our RC cannot drive a receiver bound to another RC");
    }

    /// Pools settled by Reactive set autoSettlePerSwap = 0: swappers pay nothing for markouts.
    function test_swapsDoNotSettle_whenReactiveSettles() public {
        _rebalance(-600, 600);
        vm.roll(vm.getBlockNumber() + DELAY);
        swapper.swapTo(key, true, 1 ether, TickMath.getSqrtPriceAtTick(-50));
        assertFalse(hook.recordOf(poolId, 0).settled);
    }

    // ------------------------------------------------------------------ helpers
    function _rebalance(int24 tl, int24 tu) internal returns (CallbackResult[] memory) {
        return triggerAndReact(
            address(cv),
            abi.encodeCall(CuratedVault.rebalance, (CuratedVault.RebalanceParams(tl, tu, L_RANGE / 4, 0, 0))),
            ORIGIN
        );
    }
}
