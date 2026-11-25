// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";
import {AbstractPayer} from "reactive-lib-omni/base/AbstractPayer.sol";

import {ReactiveNetworkSim, CallbackResult, SystemContractSim, BillingSim} from "./utils/ReactiveNetworkSim.sol";
import {LegacyPatternRC} from "./utils/LegacyReactive.sol";
import {TenureFreezeRC} from "../../src/reactive/TenureFreezeRC.sol";
import {TenureFreezeReceiver} from "../../src/reactive/TenureFreezeReceiver.sol";
import {TenureSettlerRC} from "../../src/reactive/TenureSettlerRC.sol";

/// @dev Origin-chain stand-ins.
contract VaultSink {
    uint256 public frozenFrom;

    function relayFreeze(uint256 sourceChainId, bytes32) external {
        frozenFrom = sourceChainId;
    }
}

contract TierSource {
    event TierChanged(bytes32 indexed poolId, uint8 from, uint8 to);

    function tier(bytes32 id, uint8 from, uint8 to) external {
        emit TierChanged(id, from, to);
    }
}

/// @notice Network conformance: the reactive contracts are exercised against a Reactive Network that behaves like
///         LIVE Lasna / Unichain Sepolia (system contract 0x8888 calls react() and bills; pay() requests; blacklisting
///         on unpaid debt; callback proxy injects the requesting RC and bills the receiver). The first test replays
///         the 2026-11-25 incident (docs/INCIDENT_REACTIVE.md) with the legacy library pattern: had this suite
///         existed, the first deployment would never have been broadcast.
contract ReactiveConformanceTest is ReactiveNetworkSim {
    uint256 constant ORIGIN = 1301;
    bytes32 constant POOL_A = keccak256("pool A");
    bytes32 constant POOL_B = keccak256("pool B");
    uint256 constant TIER_TOPIC = uint256(keccak256("TierChanged(bytes32,uint8,uint8)"));

    event BlacklistContract(address indexed contract_);
    event PaymentFailure(address indexed contract_, uint256 debt);
    event ReactiveContractReverted(address indexed contract_, bytes reason);

    TierSource src;
    VaultSink vaultA;
    VaultSink vaultB;

    function setUp() public {
        _setUpReactiveNetwork();
        src = new TierSource();
        vaultA = new VaultSink();
        vaultB = new VaultSink();
    }

    // ------------------------------------------------------------------ the incident, reproduced
    /// Live evidence (Lasna block 9229757, tx 0x40840f4f1ccb8cb9820485aa130b91c62bc7e9dd1a5e44ec07ae2e83f7fda0e6): the
    /// FreezeRC received the FROZEN TierChanged, react() reverted "VM only", the system contract's pay() request failed ("Authorized sender
    /// only"), the contract was blacklisted with 0.0123 lREACT debt, and its 2 lREACT balance cannot be applied.
    function test_legacyPattern_isBlacklistedOnFirstEvent_andItsBalanceIsStranded() public {
        LegacyPatternRC legacy = new LegacyPatternRC{value: 2 ether}(ORIGIN, address(src), TIER_TOPIC);
        assertFalse(legacy.isVm(), "0x...fffFfF has code on Lasna, so the legacy lib never runs in 'VM mode'");
        assertEq(sys.subscriptionCount(address(legacy)), 1, "its subscription is delivered (as on Lasna)");

        IReactive.LogRecord memory frozen; // TierChanged(POOL_A, RESTRICTED, FROZEN) from the origin chain
        frozen.chainId = ORIGIN;
        frozen.contractAddress = address(src);
        frozen.topic0 = TIER_TOPIC;
        frozen.topic1 = uint256(POOL_A);
        frozen.data = abi.encode(uint8(1), uint8(2));
        vm.expectEmit(true, false, false, true, SYSTEM_ADDR);
        emit ReactiveContractReverted(address(legacy), abi.encodeWithSignature("Error(string)", "VM only"));
        vm.expectEmit(true, false, false, false, SYSTEM_ADDR);
        emit PaymentFailure(address(legacy), 0);
        vm.expectEmit(true, false, false, false, SYSTEM_ADDR);
        emit BlacklistContract(address(legacy));
        sys.deliver(frozen);

        assertEq(legacy.hits(), 0, "never reacted");
        uint256 owed = sys.debt(address(legacy));
        assertGt(owed, 0, "in debt");
        assertTrue(sys.blacklisted(address(legacy)), "INACTIVE");
        assertEq(address(legacy).balance, 2 ether, "funded balance untouched: the wrong funding path");

        legacy.coverDebt(); // pays the debt its vendor (0x...fffFfF) reports: 0
        assertEq(sys.debt(address(legacy)), owed, "coverDebt cannot help: wrong vendor");
        vm.prank(SYSTEM_ADDR);
        vm.expectRevert(bytes("Authorized sender only"));
        legacy.pay(owed);

        // Clearing the debt from outside reactivates it, but every reaction still reverts and is billed.
        sys.depositTo{value: 1 ether}(address(legacy));
        assertFalse(sys.blacklisted(address(legacy)));
        uint256 before = sys.reserves(address(legacy));
        triggerAndReact(address(src), abi.encodeCall(TierSource.tier, (POOL_A, 1, 2)), ORIGIN);
        assertEq(legacy.hits(), 0, "still dead after a deposit: the legacy contracts must be replaced");
        assertLt(sys.reserves(address(legacy)), before, "and each dead reaction is billed");
    }

    // ------------------------------------------------------------------ the fixed contracts
    function test_freezeRC_subscribesThroughTheSystemContract() public {
        (TenureFreezeRC rc,,) = _freezeStack();
        assertTrue(rc.subscribed());
        assertEq(sys.subscriptionCount(address(rc)), 2);
        assertEq(address(rc._SERVICE_PROVIDER()), SYSTEM_ADDR);
    }

    function test_freezeRC_fundedViaReserves_relaysAndStaysActive() public {
        (TenureFreezeRC rc, TenureFreezeReceiver rA, TenureFreezeReceiver rB) = _freezeStack();
        sys.depositTo{value: 0.3 ether}(address(rc));
        proxy.depositTo{value: 0.002 ether}(address(rA));
        proxy.depositTo{value: 0.002 ether}(address(rB));

        CallbackResult[] memory r =
            triggerAndReact(address(src), abi.encodeCall(TierSource.tier, (POOL_A, 1, 2)), ORIGIN);
        assertCallbackCount(r, 1);
        assertCallbackSuccess(r, 0);
        assertEq(vaultB.frozenFrom(), ORIGIN, "B frozen through the receiver");
        assertEq(sys.debt(address(rc)), 0);
        assertFalse(sys.blacklisted(address(rc)));
        assertLt(sys.reserves(address(rc)), 0.3 ether, "billed from reserves");
        assertEq(proxy.debt(address(rB)), 0);
        assertLt(proxy.reserves(address(rB)), 0.002 ether, "the receiver pays for the callback, in ETH");
    }

    /// The same contract funded only through its balance also survives: pay() now accepts the real system contract.
    function test_freezeRC_fundedViaBalance_paysInTheSameTx() public {
        (TenureFreezeRC rc,, TenureFreezeReceiver rB) = _freezeStack();
        vm.deal(address(rc), 0.3 ether);
        vm.deal(address(rB), 0.002 ether);
        CallbackResult[] memory r =
            triggerAndReact(address(src), abi.encodeCall(TierSource.tier, (POOL_A, 1, 2)), ORIGIN);
        assertCallbackSuccess(r, 0);
        assertEq(sys.debt(address(rc)), 0);
        assertFalse(sys.blacklisted(address(rc)));
        assertLt(address(rc).balance, 0.3 ether, "paid via pay()");
        assertEq(proxy.debt(address(rB)), 0);
    }

    /// Unfunded = blacklisted after its first event, and a later deposit restores service without re-subscribing.
    function test_unfundedRC_isBlacklisted_untilADeposit_noResubscribe() public {
        (TenureFreezeRC rc,, TenureFreezeReceiver rB) = _freezeStack();
        proxy.depositTo{value: 0.002 ether}(address(rB));
        CallbackResult[] memory r =
            triggerAndReact(address(src), abi.encodeCall(TierSource.tier, (POOL_A, 1, 2)), ORIGIN);
        assertTrue(sys.blacklisted(address(rc)));
        assertCallbackCount(r, 1); // its own reaction succeeded; billing failed afterwards
        uint256 owed = sys.debt(address(rc));
        assertGt(owed, 0);

        r = triggerAndReact(address(src), abi.encodeCall(TierSource.tier, (POOL_B, 1, 2)), ORIGIN);
        assertNoCallbacks(r); // skipped while in debt
        assertEq(sys.debt(address(rc)), owed, "a skipped delivery is not billed");

        sys.depositTo{value: 0.3 ether}(address(rc)); // settles the debt first, then reserves
        assertFalse(sys.blacklisted(address(rc)));
        assertEq(sys.reserves(address(rc)), 0.3 ether - owed);
        r = triggerAndReact(address(src), abi.encodeCall(TierSource.tier, (POOL_B, 1, 2)), ORIGIN);
        assertCallbackCount(r, 1);
    }

    /// An unfunded receiver: the first callback is delivered, then the receiver is in debt and the proxy refuses
    /// the next one until it is funded.
    function test_unfundedReceiver_blocksTheNextCallback() public {
        (TenureFreezeRC rc, TenureFreezeReceiver rA, TenureFreezeReceiver rB) = _freezeStack();
        sys.depositTo{value: 0.3 ether}(address(rc));
        proxy.depositTo{value: 0.002 ether}(address(rB));
        triggerAndReact(address(src), abi.encodeCall(TierSource.tier, (POOL_B, 1, 2)), ORIGIN); // B frozen -> A
        assertGt(proxy.debt(address(rA)), 0, "unfunded receiver went into debt");
        triggerAndReact(address(src), abi.encodeCall(TierSource.tier, (POOL_B, 2, 1)), ORIGIN); // restore
        CallbackResult[] memory r =
            triggerAndReact(address(src), abi.encodeCall(TierSource.tier, (POOL_B, 1, 2)), ORIGIN);
        assertCallbackFailure(r, 0);
        proxy.depositTo{value: 0.002 ether}(address(rA));
        assertEq(proxy.debt(address(rA)), 0);
    }

    function test_coverDebt_paysTheRealSystemContract() public {
        (TenureFreezeRC rc,,) = _freezeStack();
        triggerAndReact(address(src), abi.encodeCall(TierSource.tier, (POOL_A, 1, 2)), ORIGIN); // unfunded
        assertTrue(sys.blacklisted(address(rc)));
        vm.deal(address(rc), 1 ether);
        rc.coverDebt();
        assertEq(sys.debt(address(rc)), 0);
        assertFalse(sys.blacklisted(address(rc)));
    }

    /// The settler's deadlines run on the Reactive chain's clock: an origin block number far ahead of it (Unichain
    /// Sepolia ~68.8M vs Lasna ~9.2M) must not make records never due.
    function test_settler_usesItsOwnClock_notTheOriginBlockNumber() public {
        address recv = address(0xDEAD);
        TenureSettlerRC rc =
            new TenureSettlerRC(ORIGIN, ORIGIN, address(src), POOL_A, recv, 60, REACTIVE_CHAIN_ID, CRON_1000);
        sys.depositTo{value: 1 ether}(address(rc));
        assertEq(sys.subscriptionCount(address(rc)), 3);
        IReactive.LogRecord memory log;
        log.chainId = ORIGIN;
        log.contractAddress = address(src);
        log.topic0 = rc.SCORED_TOPIC();
        log.topic1 = uint256(POOL_A);
        log.topic2 = 0;
        log.blockNumber = 68_778_770; // the origin's height
        deliverLog(log);
        (uint64 due,) = rc.pending(0);
        assertEq(due, vm.getBlockNumber() + 60);
        vm.roll(vm.getBlockNumber() + 60);
        vm.etch(recv, hex"00"); // any code: the proxy only delivers to contracts
        CallbackResult[] memory r = triggerCron(CRON_1000);
        assertCallbackCount(r, 1);
        assertEq(r[0].target, recv);
    }

    // ------------------------------------------------------------------ helpers
    function _freezeStack() internal returns (TenureFreezeRC rc, TenureFreezeReceiver rA, TenureFreezeReceiver rB) {
        address rcAddr = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        rA = new TenureFreezeReceiver(address(proxy), rcAddr);
        rB = new TenureFreezeReceiver(address(proxy), rcAddr);
        rc = new TenureFreezeRC(
            TenureFreezeRC.Endpoint(ORIGIN, address(src), POOL_A, address(vaultA), address(rA)),
            TenureFreezeRC.Endpoint(ORIGIN, address(src), POOL_B, address(vaultB), address(rB))
        );
        assertEq(address(rc), rcAddr);
    }
}
