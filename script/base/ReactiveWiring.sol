// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

/// @dev Funding surface shared by the Reactive system contract (0x8888...8888 on Lasna) and the callback proxies
///      (docs: dev.reactive.network/economy, "Deposit to Reserves via the System Contract" / "Funding Callback
///      Contracts"). `depositTo` settles the target's debt first, then adds the rest to its reserves.
interface IReactiveFunding {
    function depositTo(address target) external payable;
    function reserves(address target) external view returns (uint256);
    function debt(address target) external view returns (uint256);
}

/// @notice Wiring rules for the Reactive part of the deployment, shared by the deploy and re-wire scripts.
/// @dev WHY address prediction: a callback receiver (reactive-lib-omni AbstractCallback) trusts exactly ONE callback
///      sender, fixed at construction: the reactive contract that requests the callbacks (the proxy injects that
///      contract's address as the first argument). The receivers live on Unichain and the RCs on Lasna, and each
///      needs the other's address, so the receivers are built for the RC addresses that the deployer's next two
///      Lasna CREATEs will produce: freezeRC at nonce N, settlerRC at nonce N+1 (N = LASNA_NONCE, read with
///      `cast nonce <deployer> --rpc-url https://lasna-rpc.rnk.dev/`). DeployLasna refuses to broadcast if the
///      addresses it would create differ from the ones recorded here (e.g. a Lasna tx was sent in between).
///      WHY depositTo: a plain transfer only raises a contract's own balance; it "settles nothing on its own"
///      (economy docs). Reserves held by the system contract / proxy are what the network bills first.
abstract contract ReactiveWiring is Script {
    address internal constant REACTIVE_SYSTEM = 0x8888888888888888888888888888888888888888;

    /// @notice The Lasna addresses of (freezeRC, settlerRC) for a deployer whose Lasna nonce is `lasnaNonce`.
    function _predictRCs(address deployer, uint256 lasnaNonce)
        internal
        pure
        returns (address freezeRC, address settlerRC)
    {
        freezeRC = vm.computeCreateAddress(deployer, lasnaNonce);
        settlerRC = vm.computeCreateAddress(deployer, lasnaNonce + 1);
    }

    /// @notice Put `amount` into `target`'s reserves at `provider` (system contract or callback proxy), then check it
    ///         landed there. Skipped (logged) where no provider exists, i.e. a local anvil wiring check.
    function _fundReserves(address provider, address target, uint256 amount) internal {
        if (provider.code.length == 0) {
            console2.log("no service provider here (local run): reserves NOT funded for", target);
            return;
        }
        uint256 before = IReactiveFunding(provider).reserves(target);
        IReactiveFunding(provider).depositTo{value: amount}(target);
        require(IReactiveFunding(provider).debt(target) == 0, "still in debt after depositTo");
        require(IReactiveFunding(provider).reserves(target) >= before + amount, "depositTo did not reach reserves");
    }
}
