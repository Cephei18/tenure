// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "reactive-lib-omni/base/AbstractCallback.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @dev The one hook function the receiver needs (TenureHook.settleMany is permissionless).
interface ITenureSettle {
    function settleMany(PoolId id, uint256[] calldata ids) external returns (uint256 settled);
}

/// @title TenureReactiveReceiver
/// @notice Destination-chain end of Reactive settlement (M4.5a). Receives `settleMany` callbacks from the Reactive
///         Network callback proxy, requested by OUR reactive contract (TenureSettlerRC), and forwards them to the
///         hook's existing permissionless `settleMany`. Adds zero bytes to TenureHook: it is a separate contract.
/// @dev Authorization (reactive-lib-omni AbstractCallback): `onlyServiceProvider` = the callback proxy given at
///      construction; `onlyCallbackSender` = the first argument, which the proxy overwrites with the address of the
///      reactive contract that requested the callback, must equal our TenureSettlerRC. Settlement itself needs no
///      trust: the hook re-checks due-ness, oracle freshness and spot-vs-fair, and skips records that are not due or
///      already settled. The auth exists so nobody else can spend the callback fees this contract is billed for.
contract TenureReactiveReceiver is AbstractCallback {
    ITenureSettle public immutable hook;

    event ReactiveSettle(PoolId indexed poolId, uint256 requested, uint256 settled);

    /// @param callbackProxy Reactive callback proxy on this chain.
    /// @param _hook TenureHook on this chain.
    /// @param settlerRC The TenureSettlerRC (on the Reactive Network) allowed to send callbacks here.
    constructor(address callbackProxy, ITenureSettle _hook, address settlerRC)
        payable
        AbstractCallback(IPayable(payable(callbackProxy)), settlerRC)
    {
        hook = _hook;
    }

    /// @notice Callback entry point: settle the given records of `poolId` (those not due / already settled are skipped).
    /// @param sender Injected by the callback proxy: the requesting reactive contract; must be our TenureSettlerRC.
    /// @return settled Records actually settled.
    function settleMany(address sender, PoolId poolId, uint256[] calldata ids)
        external
        onlyServiceProvider
        onlyCallbackSender(sender)
        returns (uint256 settled)
    {
        settled = hook.settleMany(poolId, ids);
        emit ReactiveSettle(poolId, ids.length, settled);
    }

    /// @notice Settle any outstanding debt to the callback proxy from this contract's balance (anyone may call).
    function coverDebt() external {
        _coverDebt();
    }
}
