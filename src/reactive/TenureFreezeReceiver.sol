// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";

/// @dev The single vault function the relay may reach.
interface IRelayFreezable {
    function relayFreeze(uint256 sourceChainId, bytes32 sourcePoolId) external;
}

/// @title TenureFreezeReceiver
/// @notice Destination end of cross-chain freeze propagation (M4.5b). When TenureFreezeRC sees a curator go FROZEN
///         on one chain, the callback proxy calls `freeze` here, which sets the relayed-freeze flag on that curator's
///         CuratedVault on this chain. Adds zero bytes to TenureHook (the flag lives in the vault).
/// @dev SAFETY INVARIANT: this contract can only FREEZE. Its only state-changing path to a vault is `relayFreeze`,
///      which can only set the flag; clearing it is `CuratedVault.clearRelayFreeze`, guardian-only. It has no
///      generic call/forward function. A vault accepts it only if the vault's owner chose it (`setFreezeReceiver`).
///      Auth: callback proxy (`authorizedSenderOnly`) + our RVM ID (`rvmIdOnly`), from reactive-lib.
contract TenureFreezeReceiver is AbstractCallback {
    event FreezeRelayed(address indexed vault, uint256 indexed sourceChainId, bytes32 indexed sourcePoolId);

    /// @param callbackProxy Reactive callback proxy on this chain (MockCallbackProxy in tests).
    constructor(address callbackProxy) payable AbstractCallback(callbackProxy) {}

    /// @notice Callback entry point: freeze `vault`'s curator because it was FROZEN on `sourceChainId`.
    /// @param rvmId Injected by the callback proxy; must be our RVM ID.
    function freeze(address rvmId, address vault, uint256 sourceChainId, bytes32 sourcePoolId)
        external
        authorizedSenderOnly
        rvmIdOnly(rvmId)
    {
        IRelayFreezable(vault).relayFreeze(sourceChainId, sourcePoolId);
        emit FreezeRelayed(vault, sourceChainId, sourcePoolId);
    }
}
