// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";

/// @title TenureFreezeRC
/// @notice Reactive-Network side of cross-chain freeze propagation (M4.5b). One curator runs a Tenure-gated vault on
///         chain A and on chain B. When TenureHook moves that curator to FROZEN on one chain, this contract calls
///         TenureFreezeReceiver on the OTHER chain, which blocks the curator's rebalances in that vault too: a
///         poisoned agent caught on one chain does not keep trading on the other.
/// @dev Subscribes to TierChanged(poolId, from, to) of each side's hook and pool. Only a transition INTO FROZEN
///      triggers a callback, once per FROZEN episode (a duplicate or replayed notification is ignored until that
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
    /// @notice Side index (0 = A, 1 = B) -> already relayed for the current FROZEN episode.
    mapping(uint256 => bool) public relayed;

    event FreezeRelayRequested(uint256 indexed fromChainId, uint256 indexed toChainId, address vault);

    constructor(Endpoint memory a, Endpoint memory b) payable {
        _a = a;
        _b = b;
        if (!vm) {
            service.subscribe(a.chainId, a.hook, TIER_TOPIC, uint256(a.poolId), REACTIVE_IGNORE, REACTIVE_IGNORE);
            service.subscribe(b.chainId, b.hook, TIER_TOPIC, uint256(b.poolId), REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
    }

    /// @notice The two linked endpoints.
    function endpoints() external view returns (Endpoint memory a, Endpoint memory b) {
        return (_a, _b);
    }

    /// @notice Reactive entry point (IReactive.react), called by the ReactVM for every matching notification.
    function react(LogRecord calldata log) external vmOnly {
        if (log.topic_0 != TIER_TOPIC) return;
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
        bytes memory payload = abi.encodeWithSignature(
            "freeze(address,address,uint256,bytes32)", address(0), to_.vault, from.chainId, from.poolId
        );
        emit Callback(to_.chainId, to_.receiver, CALLBACK_GAS, payload);
        emit FreezeRelayRequested(from.chainId, to_.chainId, to_.vault);
    }

    function _is(Endpoint storage e, LogRecord calldata log) internal view returns (bool) {
        return log.chain_id == e.chainId && log._contract == e.hook && log.topic_1 == uint256(e.poolId);
    }
}
