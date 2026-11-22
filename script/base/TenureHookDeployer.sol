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

    /// @dev Must be called inside a broadcast: `new ... {salt}` goes through the CREATE2 factory.
    function _deployHook(IPoolManager pm, address owner, address guardian, uint256 mandateDelay, uint256 restoreDelay)
        internal
        returns (TenureHook hook)
    {
        bytes memory args = abi.encode(pm, owner, guardian, mandateDelay, restoreDelay);
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, HOOK_FLAGS, type(TenureHook).creationCode, args);
        hook = new TenureHook{salt: salt}(pm, owner, guardian, mandateDelay, restoreDelay);
        require(address(hook) == expected, "hook address mismatch (library linking?)");
    }
}
