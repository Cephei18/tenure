// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VaultFixture} from "./utils/VaultFixture.sol";
import {CuratedVault} from "../src/CuratedVault.sol";
import {Tier} from "../src/libraries/RiskBudget.sol";
import {ReferencePriceLib} from "../src/libraries/ReferencePriceLib.sol";

/// M3.1: shares at NAV at FAIR price, deposit guard, reputation-driven deposit cap, withdrawals always open.
contract CuratedVaultTest is VaultFixture {
    uint256 constant LEAK = 4_000 ether;

    function setUp() public {
        _setUpVault();
    }

    // ============================================================================ deposits and share pricing
    function test_firstDeposit_mintsValueMinusDeadShares() public {
        uint256 shares = _deposit(ALICE, 10_000 ether, 10_000 ether);
        assertEq(shares, 20_000 ether - cv.DEAD_SHARES(), "1:1 with fair value (price 1), dead shares burned");
        assertEq(cv.balanceOf(cv.DEAD()), cv.DEAD_SHARES());
    }

    function test_secondDeposit_proRataAtFairNav() public {
        _deposit(ALICE, 10_000 ether, 10_000 ether);
        uint256 supply = cv.totalSupply();
        (uint256 navUp,) = cv.nav(true);
        uint256 shares = _deposit(BOB, 5_000 ether, 0);
        assertEq(shares, 5_000 ether * supply / navUp, "value * supply / NAV(rounded up)");
    }

    /// Shares are priced at the FAIR price: moving spot (within the guard) does not change what a deposit mints
    /// when the vault is idle, while moving the fair price does.
    function test_sharesPricedAtFair_notSpot() public {
        _deposit(ALICE, 10_000 ether, 10_000 ether);
        uint256 atFair = cv.previewDeposit(1_000 ether, 0);
        _pushSpotTo(40); // inside the 50-tick guard
        assertEq(cv.previewDeposit(1_000 ether, 0), atFair, "spot does not price shares");
        uint256 minted = _deposit(BOB, 1_000 ether, 0);
        assertEq(minted, atFair);
        oracle.setPrice(poolId, _sqrtAt(40));
        assertGt(cv.previewDeposit(1_000 ether, 0), atFair, "fair price does (token0 worth more)");
    }

    function test_depositAtManipulatedSpot_reverts() public {
        _deposit(ALICE, 10_000 ether, 10_000 ether);
        _pushSpotTo(-300);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(CuratedVault.Tenure__SpotDeviation.selector, 300, MAX_DEPOSIT_DEV));
        cv.deposit(1_000 ether, 0, 0, BOB);
    }

    function test_deposit_staleOracle_reverts() public {
        vm.warp(vm.getBlockTimestamp() + MAX_ORACLE_AGE + 1);
        vm.prank(ALICE);
        vm.expectPartialRevert(ReferencePriceLib.Tenure__StalePrice.selector);
        cv.deposit(1_000 ether, 0, 0, ALICE);
    }

    function test_deposit_slippage_and_zero_reverts() public {
        uint256 dead = cv.DEAD_SHARES();
        uint256 expected = 2_000 ether - dead;
        vm.startPrank(ALICE);
        vm.expectRevert(CuratedVault.Tenure__ZeroAmount.selector);
        cv.deposit(0, 0, 0, ALICE);
        vm.expectRevert(CuratedVault.Tenure__ZeroShares.selector);
        cv.deposit(0, dead, 0, ALICE); // first deposit must exceed the dead shares
        vm.expectRevert(abi.encodeWithSelector(CuratedVault.Tenure__Slippage.selector, expected, expected + 1));
        cv.deposit(1_000 ether, 1_000 ether, expected + 1, ALICE);
        vm.stopPrank();
    }

    /// First-depositor inflation attack: deposit a dust amount, donate a large amount directly to the vault so
    /// the victim's deposit rounds to (almost) no shares, then withdraw everything. Must FAIL: the victim keeps
    /// nearly all value and the attacker loses nearly all of the donation (it accrues to the dead shares).
    function test_firstDepositorInflationAttack_fails() public {
        uint256 eve0 = _bal0(EVE) + _bal1(EVE);
        // 1) attacker: smallest possible first deposit (1 share)
        uint256 eveShares = _deposit(EVE, 0, cv.DEAD_SHARES() + 1);
        assertEq(eveShares, 1);
        // 2) attacker donates directly to the vault
        vm.prank(EVE);
        MockERC20(Currency.unwrap(currency1)).transfer(address(cv), 20_000 ether);
        // 3) victim deposits
        uint256 victimIn = 10_000 ether;
        uint256 aliceShares = _deposit(ALICE, 0, victimIn);
        assertGt(aliceShares, 0, "victim always gets shares");
        // 4) both exit
        (, uint256 aliceOut) = _withdrawAll(ALICE);
        _withdrawAll(EVE);
        uint256 eve1 = _bal0(EVE) + _bal1(EVE);
        assertGe(aliceOut, victimIn * 9999 / 10_000, "victim loses < 0.01%");
        assertLt(eve1, eve0, "attack is unprofitable");
        assertGe(eve0 - eve1, 19_900 ether, "attacker loses ~all of the donation");
    }

    // ============================================================================ deposit cap (reputation)
    function test_depositCap_enforced() public {
        uint256 cap = hook.depositCap(poolId); // cap0 = 100k token1
        _deposit(ALICE, 40_000 ether, 40_000 ether);
        (uint256 navUp,) = cv.nav(true);
        uint256 room = cap - navUp;
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(CuratedVault.Tenure__DepositCapExceeded.selector, navUp + room + 1, cap));
        cv.deposit(0, room + 1, 0, BOB);
        _deposit(BOB, 0, room); // exactly at the cap is fine
    }

    function test_depositCap_growsWithProvenAlpha() public {
        _deposit(ALICE, 40_000 ether, 40_000 ether);
        uint256 cap0 = hook.depositCap(poolId);
        // Good decision: be in range, then exit to idle right before the market moves up ~5%.
        _curatorRebalance(-600, 600, L_RANGE, 0); // record 0
        vm.roll(vm.getBlockNumber() + 30);
        _curatorRebalance(0, 0, 0, 0); // record 1: exit to idle
        oracle.setPrice(poolId, _sqrtAt(500));
        _pushSpotTo(500);
        vm.roll(vm.getBlockNumber() + WINDOW);
        int256 alpha = hook.settle(poolId, 1);
        assertGt(alpha, 0, "exiting before the move beat staying in range");
        uint256 cap1 = hook.depositCap(poolId);
        assertGt(cap1, cap0, "cap grows with proven alpha");

        // A deposit that would have breached the old cap now fits.
        (uint256 navUp,) = cv.nav(true);
        assertGt(cap1, navUp + 1);
        uint256 amount1 = cap0 > navUp ? cap0 - navUp + 1 : 1;
        assertLe(navUp + amount1, cap1, "fits the new cap");
        assertGt(navUp + amount1, cap0, "would have breached the old cap");
        _deposit(BOB, 0, amount1);
    }

    // ============================================================================ withdrawals: always open
    function test_withdraw_proRata_withPosition() public {
        _deposit(ALICE, 30_000 ether, 30_000 ether);
        _deposit(BOB, 10_000 ether, 10_000 ether);
        _curatorRebalance(-600, 600, L_RANGE, 0);
        uint256 supply = cv.totalSupply();
        uint256 bobShares = cv.balanceOf(BOB);
        uint128 l0 = hook.currentRange(poolId).liquidity;
        (uint256 o0, uint256 o1) = _withdrawAll(BOB);
        assertEq(hook.currentRange(poolId).liquidity, l0 - uint128(uint256(l0) * bobShares / supply), "L scaled");
        // ~25% of 40k/40k holdings, minus rounding (rounds against the withdrawer)
        assertApproxEqRel(o0, 10_000 ether, 1e12);
        assertApproxEqRel(o1, 10_000 ether, 1e12);
        assertLe(o0 + o1, 20_000 ether, "never more than deposited at price 1 with no fees/moves");
    }

    function test_withdraw_inEveryTier() public {
        _deposit(ALICE, 40_000 ether, 40_000 ether);
        _deposit(BOB, 1_000 ether, 1_000 ether);
        _curatorRebalance(-600, 600, L_RANGE, 0);
        _withdrawSome(ALICE, "FULL");

        _leakUntil(Tier.RESTRICTED, LEAK);
        _withdrawSome(ALICE, "RESTRICTED");

        _leakUntil(Tier.FROZEN, LEAK / 2);
        _withdrawSome(ALICE, "FROZEN");
        // and a full exit while frozen
        (uint256 o0, uint256 o1) = _withdrawAll(BOB);
        assertGt(o0 + o1, 0);
        assertEq(cv.balanceOf(BOB), 0);
    }

    function test_withdraw_staleOracle_andManipulatedSpot_stillWorks() public {
        _deposit(ALICE, 40_000 ether, 40_000 ether);
        _curatorRebalance(-600, 600, L_RANGE, 0);
        vm.warp(vm.getBlockTimestamp() + 10 days); // oracle stale
        _pushSpotTo(-2000); // spot far off fair
        (uint256 o0, uint256 o1) = _withdrawAll(ALICE);
        assertGt(o0 + o1, 0, "exit needs no price");
        assertEq(cv.balanceOf(ALICE), 0);
    }

    function test_withdraw_reverts_badInput() public {
        _deposit(ALICE, 1_000 ether, 1_000 ether);
        uint256 s = cv.balanceOf(ALICE);
        vm.startPrank(ALICE);
        vm.expectRevert(CuratedVault.Tenure__ZeroAmount.selector);
        cv.withdraw(0, 0, 0, ALICE);
        vm.expectRevert(CuratedVault.Tenure__InsufficientShares.selector);
        cv.withdraw(s + 1, 0, 0, ALICE);
        vm.expectPartialRevert(CuratedVault.Tenure__Slippage.selector);
        cv.withdraw(s, 1_000 ether + 1, 0, ALICE);
        vm.stopPrank();
    }

    /// Depositing then immediately withdrawing never yields more value than was put in (at the fair price).
    function testFuzz_depositWithdraw_noFreeValue(uint256 a0, uint256 a1, bool withPosition) public {
        _deposit(ALICE, 20_000 ether, 20_000 ether);
        if (withPosition) _curatorRebalance(-600, 600, L_RANGE / 2, 0);
        a0 = bound(a0, 0, 20_000 ether);
        a1 = bound(a1, 0, 20_000 ether);
        vm.assume(a0 + a1 > 1 ether);
        uint256 before = _bal0(BOB) + _bal1(BOB);
        _deposit(BOB, a0, a1);
        _withdrawAll(BOB);
        uint256 afterBal = _bal0(BOB) + _bal1(BOB); // price 1: token0 and token1 have equal fair value
        assertLe(afterBal, before, "no free value");
        assertGe(afterBal + 2, before - (a0 + a1) / 1e9, "and almost nothing lost");
    }

    // ============================================================================ access control
    function test_rebalance_onlyCurator() public {
        vm.prank(ALICE);
        vm.expectRevert(CuratedVault.Tenure__NotCurator.selector);
        cv.rebalance(CuratedVault.RebalanceParams(-600, 600, 1, 0, 0));
    }

    function test_safeMode_authAndEffect() public {
        _deposit(ALICE, 40_000 ether, 40_000 ether);
        _curatorRebalance(-600, 600, L_RANGE, 0);
        vm.prank(ALICE);
        vm.expectRevert(CuratedVault.Tenure__NotSafeModeCaller.selector);
        cv.enterSafeMode();
        cv.enterSafeMode(); // owner
        assertEq(hook.currentRange(poolId).liquidity, 0);
    }

    function test_unlockCallback_onlyPoolManager() public {
        vm.expectRevert(CuratedVault.Tenure__NotPoolManager.selector);
        cv.unlockCallback("");
    }

    function test_setCurator_onlyOwner() public {
        vm.prank(ALICE);
        vm.expectRevert(CuratedVault.Tenure__NotOwner.selector);
        cv.setCurator(ALICE);
        cv.setCurator(BOB);
        assertEq(cv.curator(), BOB);
    }

    // ============================================================================ helpers
    function _withdrawSome(address who, string memory label) internal {
        uint256 s = cv.balanceOf(who) / 10;
        uint256 b0 = _bal0(who) + _bal1(who);
        vm.prank(who);
        (uint256 o0, uint256 o1) = cv.withdraw(s, 0, 0, who);
        assertGt(o0 + o1, 0, label);
        assertEq(_bal0(who) + _bal1(who), b0 + o0 + o1, label);
    }

    function _sqrtAt(int24 tick) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }
}
