// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {VaultFixture} from "../utils/VaultFixture.sol";
import {TenureHook} from "../../src/TenureHook.sol";
import {CuratedVault} from "../../src/CuratedVault.sol";

/// @dev ERC20 that calls out on every transfer (the ERC777 / fee-on-transfer-hook shape). Etched over the pool's
///      currency0 so balances, approvals and the pool all stay in place. One-shot: disarms before calling.
contract ReentrantToken is MockERC20 {
    address public target;
    bytes public payload;
    bool public lastOk;
    bytes public lastRet;
    uint256 public fired;

    constructor() MockERC20("Reentrant", "RE", 18) {}

    function arm(address t, bytes calldata p) external {
        target = t;
        payload = p;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _fire();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _fire();
        return super.transferFrom(from, to, amount);
    }

    function _fire() internal {
        address t = target;
        if (t == address(0)) return;
        target = address(0);
        (lastOk, lastRet) = t.call(payload);
        ++fired;
    }
}

/// @dev Malicious curator that is also a depositor: from inside its own rebalance (via the token callback) it tries
///      every way back into the vault, the hook and the PoolManager.
contract ReentryCurator {
    CuratedVault public immutable vault;
    TenureHook public immutable hook;
    IPoolManager public immutable pm;
    PoolKey public key;
    PoolId public immutable id;

    constructor(CuratedVault v) {
        vault = v;
        hook = v.hook();
        pm = v.poolManager();
        key = v.poolKey();
        id = v.poolId();
        MockERC20(Currency.unwrap(key.currency0)).approve(address(v), type(uint256).max);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(v), type(uint256).max);
    }

    function rebalance(CuratedVault.RebalanceParams calldata p) external {
        vault.rebalance(p);
    }

    function reenter(uint8 kind) external {
        if (kind == 0) vault.deposit(1 ether, 1 ether, 0, address(this));
        else if (kind == 1) vault.withdraw(1, 0, 0, address(this));
        else if (kind == 2) vault.rebalance(CuratedVault.RebalanceParams(-1200, 1200, 1e20, 0, 0));
        else if (kind == 3) vault.enterSafeMode();
        else if (kind == 4) hook.beginRebalance(key);
        else if (kind == 5) hook.endRebalance(key);
        else if (kind == 6) hook.settle(id, 0);
        else if (kind == 7) pm.unlock("");
    }
}

/// M5.2 attack suite: reentrancy. Tenure's own contracts make no untrusted external calls (the hook calls only the
/// PoolManager and the owner-set oracle). The realistic vector is a token with transfer callbacks, which fires
/// INSIDE a measured rebalance (the vault pays/takes tokens mid-unlock while the hook's session is open).
contract ReentrancyTest is VaultFixture {
    ReentrantToken token;
    ReentryCurator rc;
    uint256 snap;

    function setUp() public {
        _setUpVault();
        address t0 = Currency.unwrap(currency0);
        vm.etch(t0, address(new ReentrantToken()).code);
        token = ReentrantToken(t0);

        rc = new ReentryCurator(cv);
        _fund(address(rc), 1_000_000 ether);
        cv.setCurator(address(rc));
        vm.prank(address(rc));
        cv.deposit(40_000 ether, 40_000 ether, 0, address(rc)); // the curator holds shares too
        rc.rebalance(CuratedVault.RebalanceParams(-600, 600, L_RANGE, 0, 0)); // record 0
        for (uint256 i; i < 3; ++i) {
            _pushSpotTo(-120); // flow through the vault's range: record 0 earns fees over its window
            _pushSpotTo(0);
        }
        vm.roll(vm.getBlockNumber() + WINDOW + 1); // record 0 is due
        snap = vm.snapshotState();
    }

    /// From inside a live rebalance session, every re-entry is refused with the exact guard, and the outer
    /// rebalance still completes and is scored normally.
    function test_reentryFromTokenCallback_duringRebalance_allRefused() public {
        bytes4[8] memory expected = [
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector, // deposit
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector, // withdraw
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector, // nested rebalance
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector, // safe mode mid-session
            TenureHook.Tenure__NotVault.selector, // open a second hook session directly
            TenureHook.Tenure__NotVault.selector, // close the session early, before H_after is measured
            bytes4(0), // settle mid-session: see below
            IPoolManager.AlreadyUnlocked.selector // nested unlock
        ];
        for (uint8 k; k < 8; ++k) {
            vm.revertToState(snap);
            uint256 records = hook.recordCount(poolId);
            token.arm(address(rc), abi.encodeCall(ReentryCurator.reenter, (k)));
            rc.rebalance(CuratedVault.RebalanceParams(-1200, 1200, L_RANGE / 2, 0, 0));

            assertEq(token.fired(), 1, "callback fired inside the rebalance");
            assertEq(hook.recordCount(poolId), records + 1, "outer rebalance still measured");
            assertEq(hook.sessionOf(poolId), 0, "no session left open");
            if (k == 6) {
                // settle is permissionless and has no session check, so it runs mid-session.
                // test_midSessionSettle_neverFavorsCurator shows it can only grade the curator worse.
                assertTrue(token.lastOk(), "settle runs mid-session");
                assertTrue(hook.recordOf(poolId, 0).settled);
                continue;
            }
            assertFalse(token.lastOk(), "re-entry refused");
            assertEq(_sel(token.lastRet()), expected[k], "exact guard");
        }
    }

    /// The hook's own callbacks never score mid-session: a swap inside the curator's rebalance does not settle a
    /// due record (afterSwap skips settlement while a session is open), so the curator cannot choose its grading
    /// moment with its own swap.
    function test_afterSwapInsideSession_doesNotSettle() public {
        assertFalse(hook.recordOf(poolId, 0).settled);
        rc.rebalance(CuratedVault.RebalanceParams(-1200, 1200, L_RANGE / 4, 10 ether, TickMath.MIN_SQRT_PRICE + 1)); // with a swap
        assertFalse(hook.recordOf(poolId, 0).settled, "not graded from inside the session");
    }

    /// settle() mid-session (only reachable through a callback token) grades record 0 at the same prices as settling
    /// just before the rebalance, but with the vault's range already removed: its ticks are cleared, so the fee
    /// estimator falls back curator-adversely. The curator can never improve its grade this way.
    function test_midSessionSettle_neverFavorsCurator() public {
        vm.recordLogs();
        hook.settle(poolId, 0);
        int256 normal = _settledAlpha();
        vm.revertToState(snap);

        vm.recordLogs();
        token.arm(address(rc), abi.encodeCall(ReentryCurator.reenter, (uint8(6))));
        rc.rebalance(CuratedVault.RebalanceParams(-1200, 1200, L_RANGE / 2, 0, 0));
        int256 mid = _settledAlpha();
        console2.log("alpha settled normally / mid-session:");
        console2.logInt(normal);
        console2.logInt(mid);
        assertGt(normal, 0, "fees earned in the window make the normal grade positive (non-vacuous check)");
        assertLe(mid, normal, "mid-session grading is never better for the curator");
    }

    function _settledAlpha() internal returns (int256 alpha) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == TenureHook.MarkoutSettled.selector) {
                (alpha,,,,,) = abi.decode(logs[i].data, (int256, uint256, uint256, uint256, uint256, uint8));
                return alpha;
            }
        }
        revert("no MarkoutSettled");
    }

    function _sel(bytes memory r) internal pure returns (bytes4 s) {
        if (r.length < 4) return bytes4(0);
        assembly {
            s := mload(add(r, 32))
        }
    }
}
