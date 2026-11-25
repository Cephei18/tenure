// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VaultFixture} from "../utils/VaultFixture.sol";
import {TestSwapper} from "../utils/TestActors.sol";
import {TenureHook, PoolSettings} from "../../src/TenureHook.sol";
import {CuratedVault} from "../../src/CuratedVault.sol";
import {MockReferencePrice} from "../../src/mocks/MockReferencePrice.sol";
import {Holdings, Range} from "../../src/libraries/PositionValue.sol";
import {Tier, BudgetState, BudgetParams} from "../../src/libraries/RiskBudget.sol";

/// @dev Drives the system with random depositors, curator decisions (valid or not), swaps, fair-price moves, stale
///      oracles, settlements, safe mode and guardian restores. Properties that must hold INSIDE a transaction
///      (session closed after every vault call, withdrawals never revert, pro-rata payouts) are checked here and
///      latched into ghost flags, because forge clears transient storage between top-level calls.
contract TenureHandler is Test {
    using StateLibrary for IPoolManager;

    IPoolManager immutable pm;
    TenureHook immutable hook;
    CuratedVault immutable cv;
    MockReferencePrice immutable oracle;
    TestSwapper immutable swapper;
    PoolKey key;
    PoolId immutable id;
    address immutable curator;
    address immutable guardian;
    int24 constant SPACING = 60;

    address[3] actors = [address(0xA11CE), address(0xB0B), address(0xE5E)];
    int24[2][] public rangesUsed; // every range the curator ever asked for (orphan check)

    // ghost flags (must stay false)
    bool public sessionLeaked;
    bool public withdrawBlocked;
    bool public overpaid;
    bool public unfrozenWithoutRestore;
    bool public exitAllFailed;
    // coverage counters
    uint256 public withdrawals;
    uint256 public rebalances;
    uint256 public frozenWithdrawals;
    uint256 public staleWithdrawals;
    uint256 public restores;
    uint256 public exitAlls;
    Tier lastTier;

    constructor(
        IPoolManager _pm,
        TenureHook _hook,
        CuratedVault _cv,
        MockReferencePrice _oracle,
        TestSwapper _swapper,
        address _curator,
        address _guardian
    ) {
        pm = _pm;
        hook = _hook;
        cv = _cv;
        oracle = _oracle;
        swapper = _swapper;
        key = _cv.poolKey();
        id = _cv.poolId();
        curator = _curator;
        guardian = _guardian;
    }

    // ------------------------------------------------------------------------------------------------ actions
    function deposit(uint256 who, uint256 a0, uint256 a1) external {
        address a = actors[who % 3];
        a0 = bound(a0, 0, 5_000 ether);
        a1 = bound(a1, 1 ether, 5_000 ether);
        vm.prank(a);
        try cv.deposit(a0, a1, 0, a) {} catch {} // may revert by design (spot off fair, stale, cap)
        _after();
    }

    function withdraw(uint256 who, uint256 fracBps) external {
        address a = actors[who % 3];
        uint256 bal = cv.balanceOf(a);
        if (bal == 0) return _after();
        uint256 shares = bal * bound(fracBps, 1, 10_000) / 10_000;
        if (shares == 0) shares = 1;
        Holdings memory h = cv.totalHoldings();
        uint256 supply = cv.totalSupply();
        bool frozen = hook.tierOf(id) == Tier.FROZEN;
        bool stale = _stale();
        vm.prank(a);
        try cv.withdraw(shares, 0, 0, a) returns (uint256 o0, uint256 o1) {
            ++withdrawals;
            if (frozen) ++frozenWithdrawals;
            if (stale) ++staleWithdrawals;
            // pro-rata of what the vault holds (fees owed included), with 2 wei of v4 rounding slack
            if (o0 > h.amount0 * shares / supply + 2 || o1 > h.amount1 * shares / supply + 2) overpaid = true;
        } catch {
            withdrawBlocked = true;
        }
        _after();
    }

    function rebalance(int256 centerOff, uint256 halfWidth, uint256 liqBps, int256 swapBps) external {
        int24 fairT = _fairTick();
        int24 c = _floor(fairT + int24(bound(centerOff, -3600, 3600)));
        int24 hw = _floor(int24(int256(bound(halfWidth, 30, 7200)))) + SPACING;
        (int24 tl, int24 tu) = (c - hw, c + hw);
        Holdings memory h = cv.totalHoldings();
        int256 swapAmount = bound(swapBps, -1000, 1000) * int256(h.amount0 < h.amount1 ? h.amount0 : h.amount1) / 10_000;
        (uint160 spot,,,) = pm.getSlot0(id);
        uint128 l = LiquidityAmounts.getLiquidityForAmounts(
            spot, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), h.amount0, h.amount1
        );
        l = uint128(uint256(l) * bound(liqBps, 0, 9_000) / 10_000);
        uint160 limit = swapAmount > 0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        rangesUsed.push([tl, tu]);
        vm.prank(curator);
        try cv.rebalance(CuratedVault.RebalanceParams(tl, tu, l, swapAmount, limit)) {
            ++rebalances;
        } catch {} // mandate, tier, cooldown and oracle checks reject many random decisions by design
        _after();
    }

    function swap(int256 ticks) external {
        int24 target = _fairTick() + int24(bound(ticks, -400, 400));
        uint160 t = TickMath.getSqrtPriceAtTick(target);
        (uint160 cur,,,) = pm.getSlot0(id);
        if (t != cur) swapper.swapTo(key, t < cur, type(uint128).max, t);
        _after();
    }

    function moveFair(int256 ticks) external {
        int24 f = _fairTick() + int24(bound(ticks, -60, 60));
        if (f < -3000) f = -3000;
        if (f > 3000) f = 3000;
        oracle.setPrice(id, TickMath.getSqrtPriceAtTick(f));
        _after();
    }

    function advance(uint256 blocks, bool refresh) external {
        blocks = bound(blocks, 1, 80);
        vm.roll(vm.getBlockNumber() + blocks);
        vm.warp(vm.getBlockTimestamp() + blocks * 12);
        if (refresh) {
            (uint160 f,) = oracle.getSqrtPriceX96(id);
            oracle.setPrice(id, f);
        }
        _after();
    }

    function settleAll() external {
        uint256 n = hook.recordCount(id);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = i;
        }
        try hook.settleMany(id, ids) {} catch {} // stale oracle / spot off fair: by design
        _after();
    }

    function safeMode() external {
        vm.prank(curator);
        try cv.enterSafeMode() {}
        catch {
            sessionLeaked = sessionLeaked || hook.sessionOf(id) != 0;
        }
        _after();
    }

    function guardianRestore() external {
        if (hook.tierOf(id) != Tier.FROZEN) return _after();
        vm.startPrank(guardian);
        if (hook.restoreEta(id) == 0) {
            hook.requestRestore(id);
        } else if (vm.getBlockNumber() >= hook.restoreEta(id)) {
            hook.restore(id);
            lastTier = hook.tierOf(id); // a legitimate un-freeze
            ++restores;
        }
        vm.stopPrank();
        _after();
    }

    /// Bank-run check: every holder exits in full, in sequence; all must succeed and drain the vault to dust.
    /// Simulated on a snapshot and reverted (the result is latched AFTER the revert, which also resets our storage).
    function exitAll() external {
        uint256 snap = vm.snapshotState();
        bool failed;
        for (uint256 i; i < 3; ++i) {
            uint256 s = cv.balanceOf(actors[i]);
            if (s == 0) continue;
            vm.prank(actors[i]);
            try cv.withdraw(s, 0, 0, actors[i]) {}
            catch {
                failed = true;
            }
        }
        if (cv.totalSupply() != cv.balanceOf(cv.DEAD())) {
            failed = true; // only the burned dead shares may remain
        }
        vm.revertToState(snap);
        if (failed) exitAllFailed = true;
        ++exitAlls;
        _after();
    }

    // ------------------------------------------------------------------------------------------------ helpers
    function rangesUsedLength() external view returns (uint256) {
        return rangesUsed.length;
    }

    function _after() internal {
        if (hook.sessionOf(id) != 0) sessionLeaked = true; // same tx as the vault call: transient still visible
        Tier t = hook.tierOf(id);
        if (lastTier == Tier.FROZEN && t != Tier.FROZEN) unfrozenWithoutRestore = true;
        lastTier = t;
    }

    function _stale() internal view returns (bool) {
        (, uint256 at) = oracle.getSqrtPriceX96(id);
        return vm.getBlockTimestamp() - at > hook.settingsOf(id).maxOracleAge;
    }

    function _fairTick() internal view returns (int24) {
        (uint160 f,) = oracle.getSqrtPriceX96(id);
        return TickMath.getTickAtSqrtPrice(f);
    }

    function _floor(int24 t) internal pure returns (int24) {
        int24 r = t / SPACING * SPACING;
        if (t < 0 && r != t) r -= SPACING;
        return r;
    }
}

/// M5.1: handler-based invariants over the whole system (hook + vault + pool + oracle).
/// Depth 100 keeps a run at ~2 min per profile; one full-depth run (256 x 500 = 128,000 calls) also passed (M5.1).
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 100
/// forge-config: deploy.invariant.runs = 256
/// forge-config: deploy.invariant.depth = 100
contract TenureInvariantsTest is VaultFixture {
    using StateLibrary for IPoolManager;

    TenureHandler handler;

    function _thirdPartyLiquidity() internal pure override returns (uint128) {
        return 2e23; // the vault's liquidity matters, so random decisions really move its NAV
    }

    function setUp() public {
        _setUpVault();
        _deposit(ALICE, 20_000 ether, 20_000 ether);
        _deposit(BOB, 10_000 ether, 10_000 ether);
        handler = new TenureHandler(poolManager, hook, cv, oracle, swapper, CURATOR, GUARDIAN);
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](10);
        sel[0] = TenureHandler.deposit.selector;
        sel[1] = TenureHandler.withdraw.selector;
        sel[2] = TenureHandler.rebalance.selector;
        sel[3] = TenureHandler.rebalance.selector; // weight curator decisions x2
        sel[4] = TenureHandler.swap.selector;
        sel[5] = TenureHandler.moveFair.selector;
        sel[6] = TenureHandler.advance.selector;
        sel[7] = TenureHandler.settleAll.selector;
        sel[8] = TenureHandler.safeMode.selector;
        sel[9] = TenureHandler.guardianRestore.selector;
        targetSelector(FuzzSelector(address(handler), sel));
        bytes4[] memory bankRun = new bytes4[](1);
        bankRun[0] = TenureHandler.exitAll.selector;
        targetSelector(FuzzSelector(address(handler), bankRun));
    }

    /// Vault solvency 1: a full bank run always succeeds and leaves only the burned dead shares.
    function invariant_bankRunAlwaysSucceeds() public view {
        assertFalse(handler.exitAllFailed(), "a full exit failed");
    }

    /// Vault solvency 2: no withdrawal ever pays more than its pro-rata share of what the vault holds.
    function invariant_withdrawPaysAtMostProRata() public view {
        assertFalse(handler.overpaid(), "withdrawal overpaid");
    }

    /// Vault solvency 3: the vault's liquidity lives in exactly the hook-tracked range: nothing orphaned elsewhere.
    function invariant_noOrphanedVaultLiquidity() public view {
        Range memory cur = hook.currentRange(poolId);
        uint256 n = handler.rangesUsedLength();
        for (uint256 i; i < n; ++i) {
            (int24 tl, int24 tu) = (handler.rangesUsed(i, 0), handler.rangesUsed(i, 1));
            if (tl == cur.tickLower && tu == cur.tickUpper) continue;
            (uint128 l,,) = poolManager.getPositionInfo(poolId, address(cv), tl, tu, bytes32(0));
            assertEq(l, 0, "vault liquidity outside the tracked range");
        }
    }

    /// Budget bounds: 0 <= budget <= bMax, bMax0 <= bMax <= bMaxCap, cap0 <= depositCap <= capMax.
    function invariant_budgetBounds() public view {
        BudgetState memory b = hook.budgetOf(poolId);
        BudgetParams memory p = hook.settingsOf(poolId).budget;
        assertLe(b.budget, b.bMax, "budget > bMax");
        assertGe(b.bMax, p.bMax0, "bMax < bMax0");
        assertLe(b.bMax, p.bMaxCap, "bMax > cap");
        uint256 cap = hook.depositCap(poolId);
        assertGe(cap, p.cap0, "deposit cap < cap0");
        assertLe(cap, p.capMax, "deposit cap > capMax");
    }

    /// FROZEN is sticky: only the guardian's timelocked restore lifts it.
    function invariant_frozenOnlyLiftedByGuardian() public view {
        assertFalse(handler.unfrozenWithoutRestore(), "left FROZEN without a guardian restore");
    }

    /// A session is never left open at the end of a vault call (checked inside the same transaction).
    function invariant_sessionNeverLeftOpen() public view {
        assertFalse(handler.sessionLeaked(), "session left open");
    }

    /// Withdrawals are never blocked: not by tier, a stale oracle, a manipulated spot or a failed rebalance.
    function invariant_withdrawalsNeverBlocked() public view {
        assertFalse(handler.withdrawBlocked(), "a withdrawal reverted");
    }

    /// Deterministic smoke run of the handler through the states the invariants care about (FROZEN, stale oracle,
    /// restore, bank run), so the invariant campaign is known to reach them.
    function test_invariantHandler_reachesKeyStates() public {
        handler.rebalance(0, 600, 8_000, 0);
        for (uint256 i; i < 40 && hook.tierOf(poolId) != Tier.FROZEN; ++i) {
            handler.advance(15, true);
            handler.swap(-300);
            handler.rebalance(-300, 600, 8_000, 900); // follow the pushed spot with a swap: leaks
            handler.swap(0);
        }
        assertEq(uint256(hook.tierOf(poolId)), uint256(Tier.FROZEN), "reaches FROZEN");
        handler.withdraw(0, 1_000);
        for (uint256 i; i < 5; ++i) {
            handler.advance(80, false); // 5 x 80 blocks x 12 s = 80 min > 1 h: stale
        }
        handler.withdraw(1, 1_000);
        handler.guardianRestore();
        handler.advance(80, true);
        handler.advance(80, true);
        handler.guardianRestore();
        handler.exitAll();
        assertGt(handler.frozenWithdrawals(), 0, "withdrew while FROZEN");
        assertGt(handler.staleWithdrawals(), 0, "withdrew with a stale oracle");
        assertEq(handler.restores(), 1, "guardian restored");
        assertEq(handler.exitAlls(), 1);
        invariant_bankRunAlwaysSucceeds();
        invariant_withdrawPaysAtMostProRata();
        invariant_noOrphanedVaultLiquidity();
        invariant_budgetBounds();
        invariant_frozenOnlyLiftedByGuardian();
        invariant_sessionNeverLeftOpen();
        invariant_withdrawalsNeverBlocked();
    }
}
