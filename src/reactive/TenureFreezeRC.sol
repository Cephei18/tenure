// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib-omni/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";

/// @title TenureFreezeRC
/// @notice Reactive-Network side of cross-chain freeze propagation (M4.5b). One curator runs a Tenure-gated vault on
///         chain A and on chain B. When TenureHook moves that curator to FROZEN on one chain, this contract asks the
///         Reactive Network to call TenureFreezeReceiver on the OTHER chain, which blocks the curator's rebalances in
///         that vault too: a poisoned agent caught on one chain does not keep trading on the other.
/// @dev Built on the CURRENT Reactive library (reactive-lib-omni): the system contract 0x8888...8888 calls `react()`
///      directly on this contract (`onlySystem`), bills it, and calls `pay()` when its reserves are empty. The legacy
///      reactive-lib (ReactVM copy, `vmOnly`, service 0x...fffFfF) is NOT served correctly on Lasna any more: its
///      `react()` reverts "VM only" and its `pay()` rejects 0x8888, so the first event blacklists it (docs/INCIDENT_REACTIVE.md).
///      Subscribes to TierChanged(poolId, from, to) of each side's hook and pool. Only a transition INTO FROZEN
///      requests a callback, once per FROZEN episode (a duplicate or replayed notification is ignored until that
///      side leaves FROZEN again). The relay can only freeze; restoring is the local guardian's job on each chain.
///      No echo: a relayed freeze sets a vault flag and emits no TierChanged.
contract TenureFreezeRC is AbstractReactive {
    /// @dev keccak256("TierChanged(bytes32,uint8,uint8)")
    uint256 public constant TIER_TOPIC = uint256(keccak256("TierChanged(bytes32,uint8,uint8)"));
    uint8 internal constant FROZEN = 2; // Tier.FROZEN
    uint64 public constant CALLBACK_GAS = 200_000;

    struct Endpoint {
        uint256 chainId;
        address hook;
        bytes32 poolId;
        address vault; // CuratedVault of this curator on that chain
        address receiver; // TenureFreezeReceiver on that chain
    }

    Endpoint internal _a;
    Endpoint internal _b;
    /// @notice True if the constructor registered the subscriptions (false only where no system contract exists,
    ///         e.g. a local anvil wiring check). Deploy scripts require it on a live Reactive chain.
    bool public immutable subscribed;
    /// @notice Side index (0 = A, 1 = B) -> already relayed for the current FROZEN episode.
    mapping(uint256 => bool) public relayed;

    event FreezeRelayRequested(uint256 indexed fromChainId, uint256 indexed toChainId, address vault);

    constructor(Endpoint memory a, Endpoint memory b) payable {
        _a = a;
        _b = b;
        subscribed = address(SYSTEM).code.length != 0;
        if (subscribed) {
            SYSTEM.subscribe(a.chainId, a.hook, TIER_TOPIC, uint256(a.poolId), REACTIVE_IGNORE, REACTIVE_IGNORE);
            SYSTEM.subscribe(b.chainId, b.hook, TIER_TOPIC, uint256(b.poolId), REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
    }

    /// @notice The two linked endpoints.
    function endpoints() external view returns (Endpoint memory a, Endpoint memory b) {
        return (_a, _b);
    }

    /// @notice Settle any outstanding debt to the system contract from this contract's own balance (docs: the
    ///         library's `_coverDebt()` is internal; contracts expose it). Anyone may call: it can only pay the debt.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Reactive entry point (IReactive.react), called by the system contract for every matching notification.
    function react(LogRecord calldata log) external onlySystem {
        if (log.topic0 != TIER_TOPIC) return;
        uint256 side;
        if (_is(_a, log)) side = 0;
        else if (_is(_b, log)) side = 1;
        else return;
        (, uint8 to) = abi.decode(log.data, (uint8, uint8));
        if (to != FROZEN) {
            relayed[side] = false; // left FROZEN (guardian restore): a future FROZEN is a new episode
            return;
        }
        if (relayed[side]) return; // duplicate / replay of the same episode
        relayed[side] = true;
        Endpoint memory from = side == 0 ? _a : _b;
        Endpoint memory to_ = side == 0 ? _b : _a;
        // First argument: the network overwrites it with THIS contract's address (the receiver's callback sender).
        bytes memory payload = abi.encodeWithSignature(
            "freeze(address,address,uint256,bytes32)", address(0), to_.vault, from.chainId, from.poolId
        );
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: to_.chainId, recipient: to_.receiver, gasLimit: CALLBACK_GAS, payload: payload
            })
        );
        emit FreezeRelayRequested(from.chainId, to_.chainId, to_.vault);
    }

    function _is(Endpoint storage e, LogRecord calldata log) internal view returns (bool) {
        return log.chainId == e.chainId && log.contractAddress == e.hook && log.topic1 == uint256(e.poolId);
    }
}
