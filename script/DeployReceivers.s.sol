// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {CuratedVault} from "../src/CuratedVault.sol";
import {TenureReactiveReceiver, ITenureSettle} from "../src/reactive/TenureReactiveReceiver.sol";
import {TenureFreezeReceiver} from "../src/reactive/TenureFreezeReceiver.sol";
import {ReactiveWiring} from "./base/ReactiveWiring.sol";

/// @notice Re-wire an EXISTING Unichain Sepolia deployment for new Lasna RCs (docs/INCIDENT_REACTIVE.md), without
///         touching the hook, the pools or the vaults' funds: deploys a TenureReactiveReceiver and a
///         TenureFreezeReceiver bound to the RC addresses DeployLasna will create next (LASNA_NONCE), funds their
///         reserves at the callback proxy (depositTo), points every vault the deployer owns at the new freeze
///         receiver, and records the new addresses in deployments/1301.json (keeping the old ones as *Legacy).
/// @dev The demo vault A is owned by the DemoDirector (it only enters safe mode), so its freeze receiver cannot be
///      changed: A can still SEND freezes (its TierChanged events come from the hook), but cannot RECEIVE one.
///      Vault B (owned by the deployer) receives them. Run DeployLasna right after, with no other Lasna tx between.
///        LASNA_NONCE=$(cast nonce 0xD9df64Cb859206eECF3761ec4eb5057B579438A2 --rpc-url https://lasna-rpc.rnk.dev/) \
///        FOUNDRY_PROFILE=deploy forge script script/DeployReceivers.s.sol --rpc-url https://sepolia.unichain.org \
///          --account tenure-burner --sender 0xD9df64Cb859206eECF3761ec4eb5057B579438A2 --broadcast --slow
contract DeployReceivers is ReactiveWiring {
    using stdJson for string;

    string internal constant PATH = "deployments/1301.json";

    function run() external returns (TenureReactiveReceiver settleReceiver, TenureFreezeReceiver freezeReceiver) {
        string memory cfg = vm.readFile("deployments/config.json");
        string memory dep = vm.readFile(PATH);
        require(block.chainid == dep.readUint(".chainId"), "wrong chain");
        uint256 lasnaNonce = vm.envUint("LASNA_NONCE");

        vm.startBroadcast();
        require(msg.sender == dep.readAddress(".deployer"), "run as the deployer");
        (address freezeRC, address settlerRC) = _predictRCs(msg.sender, lasnaNonce);
        (settleReceiver, freezeReceiver) = _receivers(cfg, dep, freezeRC, settlerRC);
        bool aRewired = _rewire(CuratedVault(dep.readAddress(".demoVault")), address(freezeReceiver));
        require(_rewire(CuratedVault(dep.readAddress(".chainlinkVault")), address(freezeReceiver)), "vault B not owned");
        vm.stopBroadcast();

        console2.log("expected freezeRC  (Lasna nonce N)  :", freezeRC);
        console2.log("expected settlerRC (Lasna nonce N+1):", settlerRC);
        console2.log("settle receiver                     :", address(settleReceiver));
        console2.log("freeze receiver                     :", address(freezeReceiver));
        console2.log("vault A re-wired (false = director-owned):", aRewired);
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            console2.log("simulation: deployments/1301.json NOT updated");
            return (settleReceiver, freezeReceiver);
        }
        _record(dep, address(settleReceiver), address(freezeReceiver), freezeRC, settlerRC, lasnaNonce);
    }

    function _receivers(string memory cfg, string memory dep, address freezeRC, address settlerRC)
        internal
        returns (TenureReactiveReceiver settleReceiver, TenureFreezeReceiver freezeReceiver)
    {
        address proxy = cfg.readAddress(".unichainSepolia.reactiveCallbackProxy.value");
        uint256 fund = cfg.readUint(".tenure.receiverFundingWei");
        settleReceiver = new TenureReactiveReceiver(proxy, ITenureSettle(dep.readAddress(".tenureHook")), settlerRC);
        freezeReceiver = new TenureFreezeReceiver(proxy, freezeRC);
        _fundReserves(proxy, address(settleReceiver), fund);
        _fundReserves(proxy, address(freezeReceiver), fund);
    }

    function _record(
        string memory dep,
        address settleReceiver,
        address freezeReceiver,
        address freezeRC,
        address settlerRC,
        uint256 lasnaNonce
    ) internal {
        string memory o = "rewire";
        vm.serializeJson(o, dep); // keep every existing key
        vm.serializeAddress(o, "settleReceiverLegacy", dep.readAddress(".settleReceiver"));
        vm.serializeAddress(o, "freezeReceiverLegacy", dep.readAddress(".freezeReceiver"));
        vm.serializeAddress(o, "settleReceiver", settleReceiver);
        vm.serializeAddress(o, "freezeReceiver", freezeReceiver);
        vm.serializeAddress(o, "expectedFreezeRC", freezeRC);
        vm.serializeAddress(o, "expectedSettlerRC", settlerRC);
        vm.writeJson(vm.serializeUint(o, "lasnaNonce", lasnaNonce), PATH);
    }

    /// @dev Inside the broadcast, msg.sender is the broadcasting deployer.
    function _rewire(CuratedVault v, address receiver) internal returns (bool) {
        if (v.owner() != msg.sender) return false;
        v.setFreezeReceiver(receiver);
        return true;
    }
}
