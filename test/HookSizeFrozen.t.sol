// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

/// @notice Human decision (M4.5a/M4.5b): Reactive settlement and cross-chain freeze propagation add ZERO bytes to
///         TenureHook. The hook's runtime size is pinned per build profile at its post-M5.4 value; any change to
///         the hook fails here and must be a deliberate, reviewed update of these constants.
contract HookSizeFrozenTest is Test {
    uint256 constant DEFAULT_SIZE = 29_180; // FOUNDRY_PROFILE=default (test-only build, no via-IR)
    uint256 constant DEPLOY_SIZE = 22_528; // FOUNDRY_PROFILE=deploy (via-IR, what ships)

    function test_hookBytecodeSize_unchangedByReactiveIntegration() public view {
        uint256 size = vm.getDeployedCode("TenureHook.sol:TenureHook").length;
        bool deploy = keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("default")))) == keccak256("deploy");
        assertEq(size, deploy ? DEPLOY_SIZE : DEFAULT_SIZE, "TenureHook bytecode size changed");
    }
}
