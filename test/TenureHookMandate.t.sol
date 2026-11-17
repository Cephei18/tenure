// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {HookFixture} from "./utils/HookFixture.sol";
import {SessionVault} from "./utils/TestActors.sol";
import {TenureHook, Mandate} from "../src/TenureHook.sol";
import {Tier} from "../src/libraries/RiskBudget.sol";
import {ReferencePriceLib} from "../src/libraries/ReferencePriceLib.sol";

/// @notice M2.3: one pass + one fail case per mandate rule, tier-dependent tightening, timelocked updates.
/// Mandate under test: minWidth 120, maxWidth 12000, maxCenterDist 3000, maxMove 20%, cooldown 10.
contract TenureHookMandateTest is HookFixture {
    uint128 constant L = 1e21;

    function setUp() public {
        _setUpFixture();
    }

    // ---------------------------------------------------------------- width
    function test_width_minOk() public {
        _rebalance(_ops1(-60, 60, int128(L))); // width 120 == min
    }

    function test_width_tooNarrow_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(TenureHook.Tenure__RangeTooNarrow.selector, 60, 120));
        _rebalance(_ops1(0, 60, int128(L)));
    }

    function test_width_maxOk() public {
        _rebalance(_ops1(-6000, 6000, int128(L))); // width 12000 == max
    }

    function test_width_tooWide_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(TenureHook.Tenure__RangeTooWide.selector, 12_120, 12_000));
        _rebalance(_ops1(-6060, 6060, int128(L)));
    }

    // ---------------------------------------------------------------- distance from FAIR (not spot)
    function test_center_withinOk() public {
        _rebalance(_ops1(2400, 3600, int128(L))); // center 3000 == max
    }

    function test_center_offFair_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(TenureHook.Tenure__RangeOffFair.selector, 3300, 3000));
        _rebalance(_ops1(2700, 3900, int128(L)));
    }

    /// The center rule is measured against the FAIR price: centering on a manipulated spot is rejected.
    function test_center_measuredAgainstFair_notSpot() public {
        _pushSpotTo(-4200); // attacker moves spot; fair stays at tick 0
        vm.expectRevert(abi.encodeWithSelector(TenureHook.Tenure__RangeOffFair.selector, 4200, 3000));
        _rebalance(_ops1(-4800, -3600, int128(L))); // centered on spot
    }

    // ---------------------------------------------------------------- max value converted between tokens
    function test_moved_withinOk() public {
        SessionVault.Op[] memory ops = new SessionVault.Op[](1);
        ops[0] = _swapOp(true, 40_000 ether); // 20% of NAV 200k
        _rebalance(ops);
    }

    function test_moved_tooMuch_reverts() public {
        SessionVault.Op[] memory ops = new SessionVault.Op[](1);
        ops[0] = _swapOp(true, 50_000 ether); // 25% of NAV: |delta token0| = 50k exactly, NAV_before = 200k exactly
        vm.expectRevert(abi.encodeWithSelector(TenureHook.Tenure__MovedTooMuch.selector, 0.25e18, 0.2e18));
        _rebalance(ops);
    }

    /// Re-ranging without swapping converts nothing: moving the whole position is not "moved".
    function test_moved_rerangeWithoutSwapIsZero() public {
        _rebalance(_ops1(-600, 600, int128(L)));
        vm.roll(block.number + 10);
        vm.recordLogs();
        _rebalance(_ops2(-600, 600, -int128(L), -1200, 0, int128(L / 2)));
        (,,,, uint256 movedW,,) = _lastScore();
        // token0 total is conserved; only curator-adverse rounding of the two position snapshots remains (1e-18).
        assertLe(movedW, 1);
    }

    // ---------------------------------------------------------------- cooldown
    function test_cooldown_reverts_thenOk() public {
        _rebalance(_ops1(-600, 600, int128(L)));
        uint256 last = block.number;
        vm.roll(block.number + 9);
        vm.expectRevert(abi.encodeWithSelector(TenureHook.Tenure__Cooldown.selector, last + 10));
        _rebalance(_ops1(-600, 600, int128(L)));
        vm.roll(block.number + 1);
        _rebalance(_ops1(-600, 600, int128(L)));
    }

    // ---------------------------------------------------------------- oracle staleness
    function test_oracle_freshAtBoundary_ok() public {
        oracle.setPriceAt(poolId, Constants.SQRT_PRICE_1_1, block.timestamp - MAX_ORACLE_AGE);
        _rebalance(_ops1(-600, 600, int128(L)));
    }

    function test_oracle_stale_reverts() public {
        uint256 at = block.timestamp - MAX_ORACLE_AGE - 1;
        oracle.setPriceAt(poolId, Constants.SQRT_PRICE_1_1, at);
        vm.expectRevert(abi.encodeWithSelector(ReferencePriceLib.Tenure__StalePrice.selector, at, MAX_ORACLE_AGE));
        _rebalance(_ops1(-600, 600, int128(L)));
    }

    // ---------------------------------------------------------------- RESTRICTED tightens
    function test_restricted_doublesMinWidth() public {
        _leakUntil(Tier.RESTRICTED, 2000 ether);
        vm.roll(block.number + 20);
        vm.expectRevert(abi.encodeWithSelector(TenureHook.Tenure__RangeTooNarrow.selector, 120, 240));
        _rebalance(_ops1(-60, 60, int128(L)));
        _rebalance(_ops1(-120, 120, int128(L))); // 240 ok
    }

    function test_restricted_halvesMaxMove() public {
        _leakUntil(Tier.RESTRICTED, 2000 ether);
        vm.roll(block.number + 20);
        SessionVault.Op[] memory ops = new SessionVault.Op[](1);
        ops[0] = _swapOp(true, 30_000 ether); // ~15% of NAV: fine in FULL (20%), too much in RESTRICTED (10%)
        vm.expectPartialRevert(TenureHook.Tenure__MovedTooMuch.selector);
        _rebalance(ops);
        ops[0] = _swapOp(true, 15_000 ether); // ~7.5%: ok
        _rebalance(ops);
    }

    function test_restricted_doublesCooldown() public {
        _leakUntil(Tier.RESTRICTED, 2000 ether);
        uint256 last = hook.lastRebalanceBlock(poolId);
        vm.roll(last + 10); // would be enough in FULL
        vm.expectRevert(abi.encodeWithSelector(TenureHook.Tenure__Cooldown.selector, last + 20));
        _rebalance(_ops1(-600, 600, int128(L)));
        vm.roll(last + 20);
        _rebalance(_ops1(-600, 600, int128(L)));
    }

    // ---------------------------------------------------------------- timelocked mandate updates
    function _newMandate() internal pure returns (Mandate memory) {
        return Mandate({minWidth: 600, maxWidth: 12_000, maxCenterDist: 3000, maxMoveWad: 0.2e18, cooldown: 10});
    }

    function test_mandate_timelock_flow() public {
        Mandate memory m = _newMandate();
        uint256 eta = block.timestamp + MANDATE_DELAY;
        vm.expectEmit(true, false, false, true, address(hook));
        emit TenureHook.MandateProposed(poolId, m, eta);
        hook.proposeMandate(poolId, m);

        vm.expectRevert(abi.encodeWithSelector(TenureHook.Tenure__Timelocked.selector, eta));
        hook.executeMandate(poolId);

        // old mandate still in force during the delay (depositors can exit)
        _rebalance(_ops1(-60, 60, int128(L)));

        vm.warp(eta);
        oracle.setPrice(poolId, Constants.SQRT_PRICE_1_1);
        vm.expectEmit(true, false, false, true, address(hook));
        emit TenureHook.MandateExecuted(poolId, m);
        hook.executeMandate(poolId); // anyone can execute
        assertEq(hook.settingsOf(poolId).mandate.minWidth, 600);

        vm.roll(block.number + 10);
        vm.expectRevert(abi.encodeWithSelector(TenureHook.Tenure__RangeTooNarrow.selector, 120, 600));
        _rebalance(_ops2(-60, 60, -int128(L), -60, 60, int128(L)));
    }

    function test_mandate_onlyOwnerProposes() public {
        Mandate memory m = _newMandate();
        vm.prank(address(0xBAD));
        vm.expectRevert(TenureHook.Tenure__NotOwner.selector);
        hook.proposeMandate(poolId, m);
    }

    function test_mandate_cancel() public {
        hook.proposeMandate(poolId, _newMandate());
        vm.expectEmit(true, false, false, true, address(hook));
        emit TenureHook.MandateCancelled(poolId);
        hook.cancelMandate(poolId);
        vm.warp(block.timestamp + MANDATE_DELAY);
        vm.expectRevert(TenureHook.Tenure__NoPendingChange.selector);
        hook.executeMandate(poolId);
    }

    function test_mandate_invalid_reverts() public {
        Mandate memory m = _newMandate();
        m.minWidth = 20_000; // > maxWidth
        vm.expectRevert(TenureHook.Tenure__InvalidMandate.selector);
        hook.proposeMandate(poolId, m);
    }

    // ---------------------------------------------------------------- helpers
    function _lastScore()
        internal
        returns (uint256 recordId, int256 leak, uint256 navBefore, uint256 lossW, uint256 movedW, uint256 b, Tier t)
    {
        bytes32 sig = TenureHook.RebalanceScored.selector;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; --i) {
            if (logs[i - 1].topics[0] == sig) {
                recordId = uint256(logs[i - 1].topics[2]);
                (leak, navBefore, lossW, movedW, b, t) =
                    abi.decode(logs[i - 1].data, (int256, uint256, uint256, uint256, uint256, Tier));
                return (recordId, leak, navBefore, lossW, movedW, b, t);
            }
        }
        revert("no RebalanceScored");
    }
}

import {Vm} from "forge-std/Vm.sol";
