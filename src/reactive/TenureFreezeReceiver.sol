// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "reactive-lib-omni/base/AbstractCallback.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";

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
///      Auth (reactive-lib-omni): `onlyServiceProvider` = the callback proxy; `onlyCallbackSender` = the address the
///      proxy injects as the first argument, which is the REACTIVE CONTRACT that requested the callback (not its
///      deployer). Fees: the proxy bills THIS contract, in ETH, from its reserves (fund with the proxy's
///      `depositTo(address)`), else through `pay()` from its balance. Any debt stops delivery until settled.
contract TenureFreezeReceiver is AbstractCallback {
    event FreezeRelayed(address indexed vault, uint256 indexed sourceChainId, bytes32 indexed sourcePoolId);

    /// @param callbackProxy Reactive callback proxy on this chain.
    /// @param freezeRC The TenureFreezeRC (on the Reactive Network) allowed to send callbacks here.
    constructor(address callbackProxy, address freezeRC)
        payable
        AbstractCallback(IPayable(payable(callbackProxy)), freezeRC)
    {}

    /// @notice Callback entry point: freeze `vault`'s curator because it was FROZEN on `sourceChainId`.
    /// @param sender Injected by the callback proxy: the requesting reactive contract; must be our TenureFreezeRC.
    function freeze(address sender, address vault, uint256 sourceChainId, bytes32 sourcePoolId)
        external
        onlyServiceProvider
        onlyCallbackSender(sender)
    {
        IRelayFreezable(vault).relayFreeze(sourceChainId, sourcePoolId);
        emit FreezeRelayed(vault, sourceChainId, sourcePoolId);
    }

    /// @notice Settle any outstanding debt to the callback proxy from this contract's balance (anyone may call).
    function coverDebt() external {
        _coverDebt();
    }
}
