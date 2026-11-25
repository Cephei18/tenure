// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {TenureHook} from "../../src/TenureHook.sol";

/// @notice Shared CREATE2 deployment of TenureHook at an address whose low bits carry its permissions.
/// @dev TenureHook links the EXTERNAL library TenureScorer (M4.2c). `forge script` deploys the library first and
///      links it into `type(TenureHook).creationCode`, so the mined address matches the deployed one (asserted).
abstract contract TenureHookDeployer is Script {
    uint160 internal constant HOOK_FLAGS =
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG;

    /// @dev Must be called inside a broadcast. Calls the CREATE2 factory EXPLICITLY (calldata = salt ++ initcode)
    ///      instead of relying on forge rewriting `new X{salt}` into a factory call: forge 1.8.5 skips that rewrite
    ///      when the script runs against a forked live chain (M7.1: the hook landed at a script-derived address and
    ///      reverted HookAddressNotValid), while an explicit call lands at the mined address in every mode.
    function _deployHook(IPoolManager pm, address owner, address guardian, uint256 mandateDelay, uint256 restoreDelay)
        internal
        returns (TenureHook hook)
    {
        bytes memory args = abi.encode(pm, owner, guardian, mandateDelay, restoreDelay);
        bytes memory initCode = abi.encodePacked(type(TenureHook).creationCode, args);
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, HOOK_FLAGS, type(TenureHook).creationCode, args);
        (bool ok, bytes memory ret) = CREATE2_FACTORY.call(abi.encodePacked(salt, initCode));
        require(ok && ret.length == 20, "CREATE2 factory deployment failed");
        hook = TenureHook(address(bytes20(ret)));
        require(address(hook) == expected && address(hook).code.length != 0, "hook address mismatch");
    }
}
