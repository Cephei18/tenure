// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {TenureSettlerRC} from "../src/reactive/TenureSettlerRC.sol";
import {TenureFreezeRC} from "../src/reactive/TenureFreezeRC.sol";

/// @notice M7.1: the Reactive Network side on Lasna (5318007), subscribed to the Unichain Sepolia deployment.
///         - TenureSettlerRC: watches the demo pool's RebalanceScored / MarkoutSettled and a Lasna CRON topic, and
///           asks TenureReactiveReceiver on Unichain Sepolia to call hook.settleMany (keeper-free markouts).
///         - TenureFreezeRC: watches TierChanged on both vaults' pools; a FROZEN on one is relayed to the other
///           vault through TenureFreezeReceiver (the relay can only freeze).
///         Inputs: deployments/config.json and the Unichain deployment file (DEPLOYMENT_FILE, default
///         deployments/1301.json, written by a real DeployUnichainSepolia broadcast).
/// @dev The SAME account must deploy this and DeployUnichainSepolia: the receivers only accept callbacks whose RVM
///      id (the RC deployer) equals their own deployer. Both RCs are funded with lREACT at deployment (they pay for
///      their reactive transactions and callbacks). On anvil (31337) the RCs detect "ReactVM mode" and skip
///      subscriptions, which makes the local run a constructor/wiring check only. Commands: docs/DEPLOY.md.
contract DeployLasna is Script {
    using stdJson for string;

    function run() external returns (TenureSettlerRC settler, TenureFreezeRC freezer) {
        string memory cfg = vm.readFile("deployments/config.json");
        bool local = block.chainid == 31337;
        require(local || block.chainid == cfg.readUint(".lasna.chainId.value"), "wrong chain");
        string memory dep = vm.readFile(vm.envOr("DEPLOYMENT_FILE", string("deployments/1301.json")));

        uint256 origin = dep.readUint(".chainId");
        address hook = dep.readAddress(".tenureHook");
        bytes32 poolA = dep.readBytes32(".demoPoolId");
        bytes32 poolB = dep.readBytes32(".chainlinkPoolId");
        address freezeReceiver = dep.readAddress(".freezeReceiver");

        vm.startBroadcast();
        require(local || msg.sender == dep.readAddress(".deployer"), "deploy with the Unichain deployer (RVM id)");
        settler = new TenureSettlerRC{value: cfg.readUint(".tenure.reactive.settlerFundingWei")}(
            origin,
            origin,
            hook,
            poolA,
            dep.readAddress(".settleReceiver"),
            cfg.readUint(".tenure.reactive.settlerDelayBlocks"),
            block.chainid, // CRON events are emitted on the Reactive chain itself
            uint256(cfg.readBytes32(".lasna.cronTopic.value"))
        );
        freezer = new TenureFreezeRC{value: cfg.readUint(".tenure.reactive.freezeRcFundingWei")}(
            TenureFreezeRC.Endpoint(origin, hook, poolA, dep.readAddress(".demoVault"), freezeReceiver),
            TenureFreezeRC.Endpoint(origin, hook, poolB, dep.readAddress(".chainlinkVault"), freezeReceiver)
        );
        vm.stopBroadcast();

        string memory o = "lasna";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "settlerRC", address(settler));
        string memory out = vm.serializeAddress(o, "freezeRC", address(freezer));
        bool live = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast);
        string memory path = string.concat("deployments/", vm.toString(block.chainid), live ? ".json" : ".dryrun.json");
        vm.writeJson(out, path);
        console2.log("TenureSettlerRC:", address(settler));
        console2.log("TenureFreezeRC :", address(freezer));
        console2.log("written        :", path);
    }
}
