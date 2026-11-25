// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {IReactiveFunding} from "./base/ReactiveWiring.sol";

interface IRC {
    function _SERVICE_PROVIDER() external view returns (address);
    function subscribed() external view returns (bool);
}

interface IFreezeRC {
    struct Endpoint {
        uint256 chainId;
        address hook;
        bytes32 poolId;
        address vault;
        address receiver;
    }

    function endpoints() external view returns (Endpoint memory a, Endpoint memory b);
}

interface IReceiver {
    function _SERVICE_PROVIDER() external view returns (address);
    function _CALLBACK_SENDER() external view returns (address);
}

interface IVault {
    function freezeReceiver() external view returns (address);
}

/// @notice READ-ONLY post-deploy verification of the Reactive wiring (no key, nothing broadcast):
///           forge script script/CheckReactive.s.sol
///         Lasna, for each RC in deployments/5318007.json: built on the current library (`_SERVICE_PROVIDER()` is
///         the system contract 0x8888; a legacy-lib RC has no such getter), subscribed in its constructor, debt == 0
///         (= ACTIVE: "Status follows debt automatically", docs/economy), reserves > 0.
///         Unichain Sepolia, for each receiver in deployments/1301.json: proxy is the configured callback proxy, its
///         callback sender is the matching RC, debt == 0, reserves > 0; vault B points at the freeze receiver; the
///         freeze RC's endpoints point at that receiver.
///         Subscription status itself is not exposed over the public Lasna RPC (`rnk_getSubscribers` is not
///         served): `subscribed()` proves the constructor's subscribe calls succeeded, debt == 0 proves the network
///         still serves the contract. Reactscan shows the subscriptions as ACTIVE/INACTIVE.
/// @dev Exits non-zero if anything fails (set CHECK_SOFT=true to only print).
contract CheckReactive is Script {
    using stdJson for string;

    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 internal failures;

    function run() external {
        string memory cfg = vm.readFile("deployments/config.json");
        string memory lasna = vm.readFile("deployments/5318007.json");
        string memory uni = vm.readFile("deployments/1301.json");
        address freezeRC = lasna.readAddress(".freezeRC");
        address settlerRC = lasna.readAddress(".settlerRC");
        address freezeRecv = uni.readAddress(".freezeReceiver");
        address settleRecv = uni.readAddress(".settleReceiver");
        address proxy = cfg.readAddress(".unichainSepolia.reactiveCallbackProxy.value");

        vm.createSelectFork(vm.envOr("LASNA_RPC", cfg.readString(".lasna.rpc.value")));
        console2.log("== Lasna (system contract 0x8888...8888)");
        _checkRC("TenureFreezeRC ", freezeRC);
        if (settlerRC != address(0)) _checkRC("TenureSettlerRC", settlerRC);
        else console2.log("TenureSettlerRC: not deployed (DEPLOY_SETTLER=false)");
        (bool ok, bytes memory ret) = freezeRC.staticcall(abi.encodeCall(IFreezeRC.endpoints, ()));
        if (ok) {
            (IFreezeRC.Endpoint memory a, IFreezeRC.Endpoint memory b) =
                abi.decode(ret, (IFreezeRC.Endpoint, IFreezeRC.Endpoint));
            _expect(b.receiver == freezeRecv, "  freezeRC side B relays to deployments/1301.json freezeReceiver");
            console2.log("  side A receiver:", a.receiver, "(vault A is director-owned; see DeployReceivers)");
        }

        vm.createSelectFork(vm.envOr("UNICHAIN_RPC", cfg.readString(".unichainSepolia.rpc.value")));
        console2.log("== Unichain Sepolia (callback proxy)", proxy);
        _checkReceiver("TenureFreezeReceiver  ", freezeRecv, proxy, freezeRC);
        _checkReceiver("TenureReactiveReceiver", settleRecv, proxy, settlerRC);
        address vaultB = uni.readAddress(".chainlinkVault");
        _expect(IVault(vaultB).freezeReceiver() == freezeRecv, "vault B freezeReceiver == freezeReceiver");

        console2.log(failures == 0 ? "ALL CHECKS PASSED" : "CHECKS FAILED:", failures);
        if (!vm.envOr("CHECK_SOFT", false)) require(failures == 0, "reactive wiring is broken");
    }

    function _checkRC(string memory name, address rc) internal {
        console2.log(name, rc);
        _expect(rc.code.length != 0, "  has code");
        (bool ok, bytes memory ret) = rc.staticcall(abi.encodeCall(IRC._SERVICE_PROVIDER, ()));
        _expect(ok && abi.decode(ret, (address)) == SYSTEM, "  current library: _SERVICE_PROVIDER() == 0x8888");
        (ok, ret) = rc.staticcall(abi.encodeCall(IRC.subscribed, ()));
        _expect(ok && abi.decode(ret, (bool)), "  subscribed in constructor");
        uint256 d = IReactiveFunding(SYSTEM).debt(rc);
        uint256 r = IReactiveFunding(SYSTEM).reserves(rc);
        console2.log("  balance (wei) :", rc.balance);
        console2.log("  reserves (wei):", r);
        console2.log("  debt (wei)    :", d);
        _expect(d == 0, "  debt == 0 (ACTIVE)");
        _expect(r > 0, "  reserves > 0");
    }

    function _checkReceiver(string memory name, address recv, address proxy, address rc) internal {
        console2.log(name, recv);
        if (rc == address(0)) {
            console2.log("  (no matching RC deployed; skipped)");
            return;
        }
        (bool ok, bytes memory ret) = recv.staticcall(abi.encodeCall(IReceiver._SERVICE_PROVIDER, ()));
        _expect(ok && abi.decode(ret, (address)) == proxy, "  _SERVICE_PROVIDER() == callback proxy");
        (ok, ret) = recv.staticcall(abi.encodeCall(IReceiver._CALLBACK_SENDER, ()));
        _expect(ok && abi.decode(ret, (address)) == rc, "  _CALLBACK_SENDER() == its Lasna RC");
        uint256 d = IReactiveFunding(proxy).debt(recv);
        uint256 r = IReactiveFunding(proxy).reserves(recv);
        console2.log("  balance (wei) :", recv.balance);
        console2.log("  reserves (wei):", r);
        console2.log("  debt (wei)    :", d);
        _expect(d == 0, "  debt == 0");
        _expect(r > 0, "  reserves > 0");
    }

    function _expect(bool cond, string memory what) internal {
        console2.log(cond ? "  [ok]  " : "  [FAIL]", what);
        if (!cond) ++failures;
    }
}
