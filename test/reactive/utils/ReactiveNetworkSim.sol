// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";
import {IPayer} from "reactive-lib-omni/interfaces/IPayer.sol";
import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";

/// @dev Fee and limit parameters of the live network. Lasna values read on 2026-11-25 with `cast call
///      0x8888888888888888888888888888888888888888 "_gasPriceCoeffPer1000()" / "_extraGas()" / "_maxChargeGas()"`
///      (1000 / 100000 / 50000) and `cast basefee` (100 gwei). Docs (dev.reactive.network/economy):
///      fee = p_base * C * (g_used + K); reactive transactions are capped at 900,000 gas.
library SimParams {
    uint256 internal constant REACTIVE_GAS_PRICE = 100 gwei;
    uint256 internal constant EXTRA_GAS = 100_000;
    uint256 internal constant MAX_CHARGE_GAS = 50_000;
    uint256 internal constant MAX_REACT_GAS = 900_000;
    /// @dev Callback proxies are "configured at deployment and have no defaults" (docs): any positive price works.
    uint256 internal constant CALLBACK_GAS_PRICE = 1 gwei;
}

/// @notice The billing rules both the system contract and the callback proxies apply (docs: dev.reactive.network/economy).
///         - reserves are spent first; if they run out, the rest becomes debt and the service provider calls
///           `pay(debt)` on the contract (capped at MAX_CHARGE_GAS) in the same transaction;
///         - if debt remains, PaymentFailure + BlacklistContract, and the contract is not served while debt > 0;
///         - `depositTo(c)` and any plain transfer FROM c settle c's debt first, then add to c's reserves
///           ("Sending REACT directly to the system contract credits the sender's own address").
abstract contract BillingSim {
    mapping(address => uint256) public reserves;
    mapping(address => uint256) internal _debt;
    mapping(address => bool) public blacklisted;

    event BlacklistContract(address indexed contract_);
    event WhitelistContract(address indexed contract_);
    event PaymentFailure(address indexed contract_, uint256 debt);

    /// @notice IPayable.debt
    function debt(address c) external view returns (uint256) {
        return _debt[c];
    }

    /// @notice Credit `c` from the caller's funds: settles debt first, then reserves.
    function depositTo(address c) external payable {
        _credit(c, msg.value);
    }

    receive() external payable {
        _credit(msg.sender, msg.value);
    }

    function _credit(address c, uint256 v) internal {
        uint256 d = _debt[c];
        uint256 p = v < d ? v : d;
        _debt[c] = d - p;
        reserves[c] += v - p;
        if (blacklisted[c] && _debt[c] == 0) {
            blacklisted[c] = false;
            emit WhitelistContract(c);
        }
    }

    function _charge(address c, uint256 fee) internal {
        uint256 r = reserves[c];
        if (r >= fee) {
            reserves[c] = r - fee;
            return;
        }
        reserves[c] = 0;
        _debt[c] += fee - r;
        try IPayer(payable(c)).pay{gas: SimParams.MAX_CHARGE_GAS}(_debt[c]) {} catch {}
        if (_debt[c] != 0) {
            emit PaymentFailure(c, _debt[c]);
            if (!blacklisted[c]) {
                blacklisted[c] = true;
                emit BlacklistContract(c);
            }
        }
    }
}

/// @notice Stand-in for the Reactive system contract at 0x8888...8888 (etched there by ReactiveNetworkSim).
contract SystemContractSim is BillingSim {
    struct Sub {
        uint256 chainId;
        address contract_;
        uint256 t0;
        uint256 t1;
        uint256 t2;
        uint256 t3;
        address subscriber;
    }

    struct Request {
        address requester;
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    uint256 internal constant IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    address internal constant LEGACY = 0x0000000000000000000000000000000000fffFfF;

    Sub[] internal _subs;
    Request[] internal _requests;

    event ReactiveContractReverted(address indexed contract_, bytes reason);
    event SkippedInDebt(address indexed contract_);

    function subscribe(uint256 chainId, address c, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        _subs.push(Sub(chainId, c, t0, t1, t2, t3, msg.sender));
    }

    /// @dev Used by LegacySystemSim: on live Lasna, subscriptions made through 0x...fffFfF were delivered (the
    ///      legacy RCs received a Cron100 and a TierChanged notification), so the legacy address forwards them.
    function subscribeFor(
        address subscriber,
        uint256 chainId,
        address c,
        uint256 t0,
        uint256 t1,
        uint256 t2,
        uint256 t3
    ) external {
        require(msg.sender == LEGACY, "legacy only");
        _subs.push(Sub(chainId, c, t0, t1, t2, t3, subscriber));
    }

    function subscriptionCount(address subscriber) external view returns (uint256 n) {
        for (uint256 i; i < _subs.length; ++i) {
            if (_subs[i].subscriber == subscriber) ++n;
        }
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory c) external {
        _requests.push(Request(msg.sender, c.chainId, c.recipient, c.gasLimit, c.payload));
    }

    /// @notice Deliver one log to every matching subscriber, exactly as the network does: skip indebted contracts,
    ///         call react() from this address with the 900k cap, bill the gas used + surcharge, catch reverts.
    function deliver(IReactive.LogRecord calldata log) external returns (uint256 delivered) {
        uint256 n = _subs.length;
        for (uint256 i; i < n; ++i) {
            Sub memory s = _subs[i];
            if (!_matches(s, log)) continue;
            if (_debt[s.subscriber] != 0) {
                emit SkippedInDebt(s.subscriber);
                continue;
            }
            uint256 g = gasleft();
            (bool ok, bytes memory ret) =
                s.subscriber.call{gas: SimParams.MAX_REACT_GAS}(abi.encodeCall(IReactive.react, (log)));
            uint256 used = g - gasleft();
            if (!ok) emit ReactiveContractReverted(s.subscriber, ret);
            _charge(s.subscriber, SimParams.REACTIVE_GAS_PRICE * (used + SimParams.EXTRA_GAS));
            ++delivered;
        }
    }

    /// @notice Callback requests made by successful reactions since the last call.
    function takeRequests() external returns (Request[] memory out) {
        out = _requests;
        delete _requests;
    }

    function _matches(Sub memory s, IReactive.LogRecord calldata l) internal pure returns (bool) {
        return (s.chainId == 0 || s.chainId == l.chainId)
            && (s.contract_ == address(0) || s.contract_ == l.contractAddress) && (s.t0 == IGNORE || s.t0 == l.topic0)
            && (s.t1 == IGNORE || s.t1 == l.topic1) && (s.t2 == IGNORE || s.t2 == l.topic2)
            && (s.t3 == IGNORE || s.t3 == l.topic3);
    }
}

/// @notice Stand-in for the legacy system contract at 0x...fffFfF. On live Lasna it HAS code (22,151 bytes), which is
///         why the legacy reactive-lib's `detectVm()` concludes "not a VM" everywhere. Its own debt ledger reads 0.
contract LegacySystemSim {
    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;

    function subscribe(uint256 chainId, address c, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        SystemContractSim(payable(SYSTEM)).subscribeFor(msg.sender, chainId, c, t0, t1, t2, t3);
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

/// @notice Stand-in for a destination chain's callback proxy (docs: dev.reactive.network/callback-contracts).
contract CallbackProxySim is BillingSim {
    error NotAContract();
    error InDebt();

    /// @notice Deliver a callback: reject codeless targets and indebted recipients before any charge, overwrite the
    ///         first argument with the requesting reactive contract, call with the requested gas, bill the recipient.
    /// @dev Never reverts at the top level, so tests can assert on failures.
    function execute(address requester, address recipient, bytes memory payload, uint64 gasLimit)
        external
        returns (bool ok, bytes memory ret)
    {
        if (recipient.code.length == 0) return (false, abi.encodeWithSelector(NotAContract.selector));
        if (_debt[recipient] != 0) return (false, abi.encodeWithSelector(InDebt.selector));
        if (payload.length >= 36) {
            assembly ("memory-safe") {
                mstore(add(payload, 0x24), requester)
            }
        }
        uint256 g = gasleft();
        (ok, ret) = recipient.call{gas: gasLimit}(payload);
        uint256 used = g - gasleft();
        _charge(recipient, SimParams.CALLBACK_GAS_PRICE * used);
    }
}

/// @notice Result of one callback delivery.
struct CallbackResult {
    uint256 chainId;
    address target;
    uint64 gasLimit;
    bytes payload;
    bool success;
    bytes returnData;
}

/// @notice Test base: a Reactive Network that behaves like the live one (system contract 0x8888 calls react() and
///         bills; legacy 0x...fffFfF has code; callback proxy injects the requesting RC and bills the recipient).
///         Replaces reactive-test-lib, which models the retired ReactVM flow and never bills, so it could not see
///         the failure in docs/INCIDENT_REACTIVE.md.
abstract contract ReactiveNetworkSim is Test {
    uint256 internal constant REACTIVE_CHAIN_ID = 5318007; // Lasna
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address internal constant LEGACY_ADDR = 0x0000000000000000000000000000000000fffFfF;
    /// @dev Cron topics (docs: dev.reactive.network/reactive-contracts, Cron section).
    uint256 internal constant CRON_10 = 0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687;
    uint256 internal constant CRON_1000 = 0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4;

    SystemContractSim internal sys;
    CallbackProxySim internal proxy;

    function _setUpReactiveNetwork() internal {
        vm.etch(LEGACY_ADDR, address(new LegacySystemSim()).code);
        vm.etch(SYSTEM_ADDR, address(new SystemContractSim()).code);
        sys = SystemContractSim(payable(SYSTEM_ADDR));
        proxy = new CallbackProxySim();
    }

    /// @notice Call `origin` with `callData`, deliver every log it emits (tagged `chainId`) to the subscribers, then
    ///         deliver the callbacks those reactions requested.
    function triggerAndReact(address origin, bytes memory callData, uint256 chainId)
        internal
        returns (CallbackResult[] memory)
    {
        vm.recordLogs();
        (bool ok, bytes memory ret) = origin.call(callData);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            sys.deliver(_record(logs[i], chainId));
        }
        return _executeRequests();
    }

    /// @notice Deliver one synthetic log (e.g. a cron tick) and then its callbacks.
    function deliverLog(IReactive.LogRecord memory log) internal returns (CallbackResult[] memory) {
        sys.deliver(log);
        return _executeRequests();
    }

    function triggerCron(uint256 cronTopic) internal returns (CallbackResult[] memory) {
        IReactive.LogRecord memory log;
        log.chainId = REACTIVE_CHAIN_ID;
        log.contractAddress = LEGACY_ADDR;
        log.topic0 = cronTopic;
        log.data = abi.encode(vm.getBlockNumber());
        log.blockNumber = vm.getBlockNumber();
        return deliverLog(log);
    }

    function advanceAndTriggerCron(uint256 blocks, uint256 cronTopic) internal returns (CallbackResult[] memory) {
        vm.roll(vm.getBlockNumber() + blocks);
        vm.warp(vm.getBlockTimestamp() + blocks * 12);
        return triggerCron(cronTopic);
    }

    // ------------------------------------------------------------------ assertions
    function assertCallbackEmitted(CallbackResult[] memory r, address target) internal pure {
        for (uint256 i; i < r.length; ++i) {
            if (r[i].target == target) return;
        }
        revert("no callback to the expected target");
    }

    function assertCallbackCount(CallbackResult[] memory r, uint256 n) internal pure {
        assertEq(r.length, n, "callback count");
    }

    function assertNoCallbacks(CallbackResult[] memory r) internal pure {
        assertEq(r.length, 0, "expected no callbacks");
    }

    function assertCallbackSuccess(CallbackResult[] memory r, uint256 i) internal pure {
        assertTrue(r[i].success, "callback should succeed");
    }

    function assertCallbackFailure(CallbackResult[] memory r, uint256 i) internal pure {
        assertFalse(r[i].success, "callback should fail");
    }

    // ------------------------------------------------------------------ internals
    function _executeRequests() internal returns (CallbackResult[] memory out) {
        SystemContractSim.Request[] memory q = sys.takeRequests();
        out = new CallbackResult[](q.length);
        for (uint256 i; i < q.length; ++i) {
            (bool ok, bytes memory ret) = proxy.execute(q[i].requester, q[i].recipient, q[i].payload, q[i].gasLimit);
            out[i] = CallbackResult(q[i].chainId, q[i].recipient, q[i].gasLimit, q[i].payload, ok, ret);
        }
    }

    function _record(Vm.Log memory l, uint256 chainId) internal view returns (IReactive.LogRecord memory r) {
        r.chainId = chainId;
        r.contractAddress = l.emitter;
        if (l.topics.length > 0) r.topic0 = uint256(l.topics[0]);
        if (l.topics.length > 1) r.topic1 = uint256(l.topics[1]);
        if (l.topics.length > 2) r.topic2 = uint256(l.topics[2]);
        if (l.topics.length > 3) r.topic3 = uint256(l.topics[3]);
        r.data = l.data;
        r.blockNumber = vm.getBlockNumber();
    }
}
