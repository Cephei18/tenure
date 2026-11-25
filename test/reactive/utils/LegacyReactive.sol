// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";

/// @notice The shape of the FIRST Lasna deployment (legacy reactive-lib f6990ce): subscribes through the service at
///         0x...fffFfF, guards react() with `vmOnly`, funded by a value transfer into its own balance. Used only to
///         prove that ReactiveNetworkSim reproduces the live failure (docs/INCIDENT_REACTIVE.md).
contract LegacyPatternRC is AbstractReactive {
    uint256 public hits;

    constructor(uint256 chainId, address emitter, uint256 topic0) payable {
        if (!vm) service.subscribe(chainId, emitter, topic0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function isVm() external view returns (bool) {
        return vm;
    }

    function react(LogRecord calldata) external vmOnly {
        ++hits;
    }
}
