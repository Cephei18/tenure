// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";

import {TenureHook} from "../src/TenureHook.sol";
import {TenureHookDeployer} from "./base/TenureHookDeployer.sol";

/// @notice Deploys TenureHook at a CREATE2 address whose low bits carry its permissions (mined with HookMiner).
/// @dev TenureHook links the EXTERNAL library TenureScorer (M4.2c); forge script deploys and links it automatically.
///      For a reusable library address pass `--libraries src/libraries/TenureScorer.sol:TenureScorer:<addr>`.
///      ALWAYS run with FOUNDRY_PROFILE=deploy (via-IR): the default profile builds a hook over the EIP-170 limit.
///
///      Dry run (in-memory, deploys its own PoolManager):
///        FOUNDRY_PROFILE=deploy forge script script/DeployTenureHook.s.sol
///      Local anvil (burner/test keys only):
///        FOUNDRY_PROFILE=deploy forge script script/DeployTenureHook.s.sol --rpc-url http://127.0.0.1:8545 \
///          --private-key <anvil key> --broadcast
///      Env (optional): POOL_MANAGER (else a fresh PoolManager, local chain only), TENURE_OWNER, TENURE_GUARDIAN,
///      MANDATE_DELAY (seconds, default 1 day), RESTORE_DELAY (blocks, default 7200).
contract DeployTenureHook is TenureHookDeployer {
    function run() external returns (TenureHook hook) {
        address pm = vm.envOr("POOL_MANAGER", address(0));
        vm.startBroadcast();
        // msg.sender inside the broadcast is the broadcasting account.
        address owner = vm.envOr("TENURE_OWNER", msg.sender);
        address guardian = vm.envOr("TENURE_GUARDIAN", msg.sender);
        if (pm == address(0)) {
            require(block.chainid == 31337, "set POOL_MANAGER on non-local chains");
            pm = V4PoolManagerDeployer.deploy(msg.sender); // pinned v4 bytecode (PoolManager.sol pins solc 0.8.26)
        }
        hook = _deployHook(
            IPoolManager(pm),
            owner,
            guardian,
            vm.envOr("MANDATE_DELAY", uint256(1 days)),
            vm.envOr("RESTORE_DELAY", uint256(7200))
        );
        vm.stopBroadcast();

        console2.log("PoolManager:", pm);
        console2.log("TenureHook :", address(hook));
        console2.log("hook runtime size (B):", address(hook).code.length);
    }
}
