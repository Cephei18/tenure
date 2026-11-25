// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib-omni/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";

/// @title TenureSettlerRC
/// @notice Reactive-Network side of keeper-free markout settlement (M4.5a). Watches one Tenure pool on the origin
///         chain and, once its rebalance records are due, asks TenureReactiveReceiver on the destination chain to
///         call the hook's permissionless `settleMany`. With this, the pool sets `autoSettlePerSwap = 0`, so swappers
///         pay no markout gas and no off-chain keeper is needed.
/// @dev Built on the CURRENT Reactive library (reactive-lib-omni): the system contract 0x8888...8888 calls `react()`
///      directly on this contract (`onlySystem`) and bills it (see TenureFreezeRC and docs/INCIDENT_REACTIVE.md).
///      Subscriptions (made in the constructor through the system contract):
///        - RebalanceScored(poolId, recordId, ...) from the hook  -> queue recordId, due after `delayBlocks`
///        - MarkoutSettled(poolId, recordId, ...) from the hook   -> drop recordId (settled by anyone, any path)
///        - a cron topic of the legacy emitter 0x...fffFfF         -> send due records (at most MAX_BATCH per callback)
///      Timing: every deadline is on THIS contract's clock, `block.number` of the Reactive Network at react() time.
///      A RebalanceScored log carries the ORIGIN chain's block number (Unichain Sepolia is near 68.8M while Lasna is
///      near 9.2M), so mixing the two would leave records never due. `delayBlocks` (Reactive blocks) must cover the
///      hook's window W (origin blocks) in wall time. Being early is harmless: the hook re-checks due-ness and skips
///      records that are not due. A record that is sent but not settled (callback reverted, e.g. stale oracle) is
///      re-sent at most once every `delayBlocks`, until a MarkoutSettled notification drops it.
///      Every cron tick is a billed reactive transaction: use the slowest cron topic the demo can live with.
contract TenureSettlerRC is AbstractReactive {
    /// @dev keccak256("RebalanceScored(bytes32,uint256,int256,uint256,uint256,uint256,uint256,uint8)")
    uint256 public constant SCORED_TOPIC =
        uint256(keccak256("RebalanceScored(bytes32,uint256,int256,uint256,uint256,uint256,uint256,uint8)"));
    /// @dev keccak256("MarkoutSettled(bytes32,uint256,int256,uint256,uint256,uint256,uint256,uint8)")
    uint256 public constant SETTLED_TOPIC =
        uint256(keccak256("MarkoutSettled(bytes32,uint256,int256,uint256,uint256,uint256,uint256,uint8)"));
    /// @dev Emitter of the Cron events (docs: the legacy system contract keeps emitting them).
    address public constant CRON_EMITTER = 0x0000000000000000000000000000000000fffFfF;
    uint256 public constant MAX_BATCH = 8; // records per callback
    uint256 public constant MAX_SCAN = 64; // pending entries inspected per cron tick
    uint64 public constant GAS_BASE = 150_000;
    uint64 public constant GAS_PER_RECORD = 300_000; // one fee-aware settlement is ~200k (M5.4)

    uint256 public immutable originChainId;
    uint256 public immutable destChainId;
    address public immutable hook;
    bytes32 public immutable poolId;
    address public immutable receiver;
    uint256 public immutable delayBlocks;
    uint256 public immutable cronTopic;
    /// @notice True if the constructor registered the subscriptions (false only where no system contract exists,
    ///         e.g. a local anvil wiring check). Deploy scripts require it on a live Reactive chain.
    bool public immutable subscribed;

    struct Pending {
        uint64 dueBlock;
        uint64 lastSent; // 0 = never sent
    }

    uint256[] internal _queue; // pending record ids (unordered)
    mapping(uint256 => uint256) internal _slotPlusOne; // record id -> index in _queue + 1
    mapping(uint256 => Pending) public pending;

    event Queued(uint256 indexed recordId, uint256 dueBlock);
    event Dropped(uint256 indexed recordId);
    event SettleRequested(uint256 count, uint256 atBlock);

    /// @param _originChainId Chain where TenureHook lives (RebalanceScored / MarkoutSettled come from there).
    /// @param _destChainId Chain of the receiver (normally the same chain as the hook).
    /// @param _delayBlocks Wait before a queued record is sent, in Reactive Network blocks.
    /// @param cronChainId Chain id the cron events are emitted on (the Reactive Network itself).
    /// @param _cronTopic Cron topic to subscribe to (e.g. the "every N blocks" topic of the deployment).
    constructor(
        uint256 _originChainId,
        uint256 _destChainId,
        address _hook,
        bytes32 _poolId,
        address _receiver,
        uint256 _delayBlocks,
        uint256 cronChainId,
        uint256 _cronTopic
    ) payable {
        originChainId = _originChainId;
        destChainId = _destChainId;
        hook = _hook;
        poolId = _poolId;
        receiver = _receiver;
        delayBlocks = _delayBlocks;
        cronTopic = _cronTopic;
        bool live = address(SYSTEM).code.length != 0;
        subscribed = live;
        if (live) {
            SYSTEM.subscribe(_originChainId, _hook, SCORED_TOPIC, uint256(_poolId), REACTIVE_IGNORE, REACTIVE_IGNORE);
            SYSTEM.subscribe(_originChainId, _hook, SETTLED_TOPIC, uint256(_poolId), REACTIVE_IGNORE, REACTIVE_IGNORE);
            SYSTEM.subscribe(cronChainId, CRON_EMITTER, _cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
    }

    /// @notice Number of records waiting for settlement.
    function pendingCount() external view returns (uint256) {
        return _queue.length;
    }

    /// @notice Settle any outstanding debt to the system contract from this contract's own balance (docs: the
    ///         library's `_coverDebt()` is internal; contracts expose it). Anyone may call: it can only pay the debt.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Reactive entry point (IReactive.react), called by the system contract for every matching notification.
    /// @dev Only the system contract may call (`onlySystem`); notifications for other contracts/pools/topics are ignored.
    function react(LogRecord calldata log) external onlySystem {
        if (log.chainId == originChainId && log.contractAddress == hook && log.topic1 == uint256(poolId)) {
            if (log.topic0 == SCORED_TOPIC) {
                _queueRecord(log.topic2, block.number);
            } else if (log.topic0 == SETTLED_TOPIC) {
                _drop(log.topic2);
            }
        } else if (log.topic0 == cronTopic && log.contractAddress == CRON_EMITTER) {
            _flush(block.number);
        }
    }

    function _queueRecord(uint256 recordId, uint256 nowBlock) internal {
        // type(uint256).max = an empty-vault rebalance: nothing was recorded, nothing to settle.
        if (recordId == type(uint256).max || _slotPlusOne[recordId] != 0) return;
        uint256 due = nowBlock + delayBlocks;
        pending[recordId] = Pending(uint64(due), 0);
        _queue.push(recordId);
        _slotPlusOne[recordId] = _queue.length;
        emit Queued(recordId, due);
    }

    function _drop(uint256 recordId) internal {
        uint256 slot = _slotPlusOne[recordId];
        if (slot == 0) return;
        uint256 last = _queue[_queue.length - 1];
        _queue[slot - 1] = last;
        _slotPlusOne[last] = slot;
        _queue.pop();
        delete _slotPlusOne[recordId];
        delete pending[recordId];
        emit Dropped(recordId);
    }

    /// @dev Send every due record not sent within the last `delayBlocks` (bounded by MAX_SCAN / MAX_BATCH).
    function _flush(uint256 nowBlock) internal {
        uint256[] memory ids = new uint256[](MAX_BATCH);
        uint256 n;
        uint256 len = _queue.length;
        for (uint256 i; i < len && i < MAX_SCAN && n < MAX_BATCH; ++i) {
            uint256 id = _queue[i];
            Pending storage p = pending[id];
            if (nowBlock < p.dueBlock) continue;
            if (p.lastSent != 0 && nowBlock < uint256(p.lastSent) + delayBlocks) continue;
            p.lastSent = uint64(nowBlock);
            ids[n++] = id;
        }
        if (n == 0) return;
        assembly ("memory-safe") {
            mstore(ids, n)
        }
        // First argument: the network overwrites it with THIS contract's address (the receiver's callback sender).
        bytes memory payload = abi.encodeWithSignature("settleMany(address,bytes32,uint256[])", address(0), poolId, ids);
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destChainId,
                recipient: receiver,
                gasLimit: GAS_BASE + GAS_PER_RECORD * uint64(n),
                payload: payload
            })
        );
        emit SettleRequested(n, nowBlock);
    }
}
