// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {TenureSettlerRC} from "../src/reactive/TenureSettlerRC.sol";
import {TenureFreezeRC} from "../src/reactive/TenureFreezeRC.sol";
import {ReactiveWiring} from "./base/ReactiveWiring.sol";

/// @notice M7.1: the Reactive Network side on Lasna (5318007), subscribed to the Unichain Sepolia deployment.
///         - TenureFreezeRC (created FIRST, at the deployer's nonce N): watches TierChanged on both vaults' pools; a
///           FROZEN on one is relayed to the other vault through TenureFreezeReceiver (the relay can only freeze).
///         - TenureSettlerRC (nonce N+1, skipped with DEPLOY_SETTLER=false, which BURNS nonce N+1 on a deposit tx:
///           the settle receiver then trusts an address nobody can deploy to): watches the demo pool's RebalanceScored /
///           MarkoutSettled and a Lasna CRON topic, and asks TenureReactiveReceiver on Unichain Sepolia to call
///           hook.settleMany (keeper-free markouts).
///         Inputs: deployments/config.json and the Unichain deployment file (DEPLOYMENT_FILE, default
///         deployments/1301.json, written by DeployUnichainSepolia or re-wired by DeployReceivers).
/// @dev Funding (docs: dev.reactive.network/economy): each RC gets RESERVES through the system contract's
///      `depositTo(address)`, never a value transfer into the RC (a balance "settles nothing on its own"). The first
///      Lasna deployment was funded the wrong way AND built on the retired library (docs/INCIDENT_REACTIVE.md).
///      Refuses to broadcast if: the created addresses differ from the ones the Unichain receivers trust
///      (`expectedFreezeRC` / `expectedSettlerRC`), an RC did not subscribe, or its reserves/debt are wrong after
///      funding. On anvil (31337) there is no system contract: a constructor/wiring check only, nothing subscribed.
///      Verify a live deployment afterwards with script/CheckReactive.s.sol. Commands: docs/DEPLOY.md.
contract DeployLasna is ReactiveWiring {
    using stdJson for string;

    function run() external returns (TenureFreezeRC freezer, TenureSettlerRC settler) {
        string memory cfg = vm.readFile("deployments/config.json");
        bool local = block.chainid == 31337;
        require(local || block.chainid == cfg.readUint(".lasna.chainId.value"), "wrong chain");
        string memory dep = vm.readFile(vm.envOr("DEPLOYMENT_FILE", string("deployments/1301.json")));
        bool withSettler = vm.envOr("DEPLOY_SETTLER", true);

        vm.startBroadcast();
        if (!local) _requireWiring(dep, msg.sender);
        freezer = _freezer(dep);
        if (withSettler) settler = _settler(cfg, dep);
        if (!local) {
            require(freezer.subscribed() && (!withSettler || settler.subscribed()), "RC did not subscribe");
            _fundReserves(REACTIVE_SYSTEM, address(freezer), cfg.readUint(".tenure.reactive.freezeRcReservesWei"));
            if (withSettler) {
                _fundReserves(REACTIVE_SYSTEM, address(settler), cfg.readUint(".tenure.reactive.settlerReservesWei"));
            }
        }
        vm.stopBroadcast();
        _write(freezer, settler);
    }

    /// @dev The RCs must land exactly where the Unichain receivers expect their callback sender.
    function _requireWiring(string memory dep, address me) internal view {
        require(me == dep.readAddress(".deployer"), "deploy with the Unichain deployer");
        require(vm.keyExistsJson(dep, ".expectedFreezeRC"), "receivers predate the fix: run DeployReceivers first");
        (address predictedFreeze, address predictedSettler) = _predictRCs(me, vm.getNonce(me));
        require(predictedFreeze == dep.readAddress(".expectedFreezeRC"), "freezeRC address != receiver's sender");
        require(predictedSettler == dep.readAddress(".expectedSettlerRC"), "settlerRC address != receiver's sender");
    }

    function _freezer(string memory dep) internal returns (TenureFreezeRC) {
        uint256 origin = dep.readUint(".chainId");
        address hook = dep.readAddress(".tenureHook");
        address recv = dep.readAddress(".freezeReceiver");
        return new TenureFreezeRC(
            TenureFreezeRC.Endpoint(origin, hook, dep.readBytes32(".demoPoolId"), dep.readAddress(".demoVault"), recv),
            TenureFreezeRC.Endpoint(
                origin, hook, dep.readBytes32(".chainlinkPoolId"), dep.readAddress(".chainlinkVault"), recv
            )
        );
    }

    function _write(TenureFreezeRC freezer, TenureSettlerRC settler) internal {
        string memory o = "lasna";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "settlerRC", address(settler));
        string memory out = vm.serializeAddress(o, "freezeRC", address(freezer));
        bool live = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast);
        string memory path = string.concat("deployments/", vm.toString(block.chainid), live ? ".json" : ".dryrun.json");
        vm.writeJson(out, path);
        console2.log("TenureFreezeRC :", address(freezer));
        console2.log("TenureSettlerRC:", address(settler));
        console2.log("written        :", path);
    }

    function _settler(string memory cfg, string memory dep) internal returns (TenureSettlerRC) {
        uint256 origin = dep.readUint(".chainId");
        return new TenureSettlerRC(
            origin,
            origin,
            dep.readAddress(".tenureHook"),
            dep.readBytes32(".demoPoolId"),
            dep.readAddress(".settleReceiver"),
            cfg.readUint(".tenure.reactive.settlerDelayBlocks"),
            block.chainid, // CRON events are emitted on the Reactive chain itself
            uint256(cfg.readBytes32(".lasna.cronTopic.value"))
        );
    }
}
