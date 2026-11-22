// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @dev The one hook function the receiver needs (TenureHook.settleMany is permissionless).
interface ITenureSettle {
    function settleMany(PoolId id, uint256[] calldata ids) external returns (uint256 settled);
}

/// @title TenureReactiveReceiver
/// @notice Destination-chain end of Reactive settlement (M4.5a). Receives `settleMany` callbacks from the Reactive
///         Network callback proxy, sent by OUR reactive contract (TenureSettlerRC), and forwards them to the hook's
///         existing permissionless `settleMany`. Adds zero bytes to TenureHook: it is a separate contract.
/// @dev Authorization (reactive-lib AbstractCallback): `authorizedSenderOnly` = the callback proxy given at
///      construction; `rvmIdOnly` = the RVM ID the proxy injects as the first argument must equal this contract's
///      deployer (the account that deploys TenureSettlerRC on Reactive). Settlement itself needs no trust: the hook
///      re-checks due-ness, oracle freshness and spot-vs-fair, and skips records that are not due or already settled.
///      The auth exists so nobody else can spend the callback fees this contract pre-pays to the proxy.
contract TenureReactiveReceiver is AbstractCallback {
    ITenureSettle public immutable hook;

    event ReactiveSettle(PoolId indexed poolId, uint256 requested, uint256 settled);

    /// @param callbackProxy Reactive callback proxy on this chain (MockCallbackProxy in tests).
    /// @param _hook TenureHook on this chain.
    constructor(address callbackProxy, ITenureSettle _hook) payable AbstractCallback(callbackProxy) {
        hook = _hook;
    }

    /// @notice Callback entry point: settle the given records of `poolId` (those not due / already settled are skipped).
    /// @param rvmId Injected by the callback proxy; must be our RVM ID.
    /// @return settled Records actually settled.
    function settleMany(address rvmId, PoolId poolId, uint256[] calldata ids)
        external
        authorizedSenderOnly
        rvmIdOnly(rvmId)
        returns (uint256 settled)
    {
        settled = hook.settleMany(poolId, ids);
        emit ReactiveSettle(poolId, ids.length, settled);
    }
}
