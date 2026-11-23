// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {DeltaSettler} from "./utils/TestActors.sol";
import {VaultFixture} from "./utils/VaultFixture.sol";
import {CuratedVault} from "../src/CuratedVault.sol";
import {TenureHook, PoolSettings} from "../src/TenureHook.sol";
import {Range} from "../src/libraries/PositionValue.sol";
import {Tier} from "../src/libraries/RiskBudget.sol";

/// @notice Baseline for Tenure's overhead: the SAME rebalance as CuratedVault (curator check, reentrancy guard,
///         remove old range -> swap -> add new range in one unlock, event) on a pool WITHOUT a hook. It keeps its
///         range in its own storage because there is no hook to track it.
contract PlainVault is ReentrancyGuard, IUnlockCallback {
    using DeltaSettler for IPoolManager;

    event Rebalanced(int24 tickLower, int24 tickUpper, uint128 liquidity, int256 swapAmount, uint256 recordId);

    IPoolManager public immutable pm;
    address public immutable curator;
    PoolKey internal _key;
    Range public range;

    constructor(IPoolManager _pm, PoolKey memory k, address _curator) {
        pm = _pm;
        _key = k;
        curator = _curator;
    }

    function rebalance(CuratedVault.RebalanceParams calldata p) external nonReentrant {
        require(msg.sender == curator, "not curator");
        pm.unlock(abi.encode(p));
        emit Rebalanced(p.tickLower, p.tickUpper, p.liquidity, p.swapAmount, 0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        CuratedVault.RebalanceParams memory p = abi.decode(data, (CuratedVault.RebalanceParams));
        PoolKey memory k = _key;
        Range memory old = range;
        if (old.liquidity != 0) _modify(k, old.tickLower, old.tickUpper, -int256(uint256(old.liquidity)));
        if (p.swapAmount != 0) {
            bool zeroForOne = p.swapAmount > 0;
            int256 amountIn = zeroForOne ? p.swapAmount : -p.swapAmount;
            BalanceDelta d = pm.swap(k, SwapParams(zeroForOne, -amountIn, p.sqrtPriceLimitX96), "");
            pm.settleAll(k, d, address(this));
        }
        if (p.liquidity != 0) _modify(k, p.tickLower, p.tickUpper, int256(uint256(p.liquidity)));
        range = Range(p.tickLower, p.tickUpper, p.liquidity);
        return "";
    }

    function _modify(PoolKey memory k, int24 tl, int24 tu, int256 delta) internal {
        (BalanceDelta d,) = pm.modifyLiquidity(k, ModifyLiquidityParams(tl, tu, delta, bytes32(0)), "");
        pm.settleAll(k, d, address(this));
    }
}

/// @notice CuratedVault's rebalance flow (begin -> unlock(remove, swap, add) -> end), instrumented with gasleft()
///         around each hook call so beginRebalance / endRebalance can be reported separately. Registered as the vault
///         of its own Tenure pool, so the hook does exactly the work it does for CuratedVault.
contract ProbeVault is IUnlockCallback {
    using DeltaSettler for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable pm;
    TenureHook public immutable hook;
    PoolKey internal _key;
    uint256 public gBegin;
    uint256 public gUnlock;
    uint256 public gEnd;

    constructor(IPoolManager _pm, TenureHook _hook, PoolKey memory k) {
        pm = _pm;
        hook = _hook;
        _key = k;
    }

    function rebalance(CuratedVault.RebalanceParams calldata p) external {
        PoolKey memory k = _key;
        uint256 g = gasleft();
        hook.beginRebalance(k);
        uint256 g1 = gasleft();
        pm.unlock(abi.encode(p));
        uint256 g2 = gasleft();
        hook.endRebalance(k);
        uint256 g3 = gasleft();
        (gBegin, gUnlock, gEnd) = (g - g1, g1 - g2, g2 - g3);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        CuratedVault.RebalanceParams memory p = abi.decode(data, (CuratedVault.RebalanceParams));
        PoolKey memory k = _key;
        Range memory old = hook.currentRange(k.toId());
        if (old.liquidity != 0) _modify(k, old.tickLower, old.tickUpper, -int256(uint256(old.liquidity)));
        if (p.swapAmount != 0) {
            bool zeroForOne = p.swapAmount > 0;
            int256 amountIn = zeroForOne ? p.swapAmount : -p.swapAmount;
            BalanceDelta d = pm.swap(k, SwapParams(zeroForOne, -amountIn, p.sqrtPriceLimitX96), "");
            pm.settleAll(k, d, address(this));
        }
        if (p.liquidity != 0) _modify(k, p.tickLower, p.tickUpper, int256(uint256(p.liquidity)));
        return "";
    }

    function _modify(PoolKey memory k, int24 tl, int24 tu, int256 delta) internal {
        (BalanceDelta d,) = pm.modifyLiquidity(k, ModifyLiquidityParams(tl, tu, delta, bytes32(0)), "");
        pm.settleAll(k, d, address(this));
    }
}

/// @notice M5.3 gas report. Every measured call runs as its OWN transaction (isolate = true: cold storage and
///         accounts, transient storage cleared, exactly as on-chain). Numbers land in
///         snapshots/GasReport.<FOUNDRY_PROFILE>.json and are tabulated in docs/GAS.md. Run:
///             FOUNDRY_PROFILE=deploy forge test --match-path test/GasReport.t.sol --isolate
///
///         Three pools share the same tokens, 1:1 price, deep full-range third-party liquidity and the same vault
///         position history (deposit 30k/30k, then a (-600, 600) range with a 1,000 token0 swap):
///           - `key`      : Tenure pool, real CuratedVault                    (the product)
///           - `plainKey` : hookless pool, PlainVault (same rebalance logic)  (the baseline)
///           - `probeKey` : Tenure pool, ProbeVault (gasleft() per hook call) (the begin/end breakdown)
/// forge-config: default.isolate = true
/// forge-config: deploy.isolate = true
abstract contract GasReportBase is VaultFixture {
    using PoolIdLibrary for PoolKey;
    using EasyPosm for IPositionManager;

    PoolKey plainKey;
    PoolKey probeKey;
    PoolId probeId;
    PlainVault plain;
    ProbeVault probe;

    uint256 constant DEP = 30_000 ether;
    uint256 constant SWAP_IN = 1 ether; // a typical small market swap (stays inside every range)

    /// @dev The vault pool's auto-settle setting (the probe pool uses the same settings). A storage variable set by
    ///      each concrete test contract's constructor, not a pure override: a compile-time constant here changes
    ///      via-IR inlining of setUp enough to hit "stack too deep" under the deploy profile.
    uint8 internal autoSettle;

    function _vaultSettings() internal view override returns (PoolSettings memory s) {
        s = super._vaultSettings();
        s.autoSettlePerSwap = autoSettle;
    }

    function setUp() public {
        _setUpVault();

        _fund(address(this), 2 * 1_000_000_000 ether); // two more 1e27-deep full-range positions
        _setUpPlain();
        _setUpProbe();
        _seedHistory();
    }

    /// @dev Baseline: hookless pool + mirror vault.
    function _setUpPlain() internal {
        plainKey = PoolKey(currency0, currency1, 3000, SPACING, IHooks(address(0)));
        poolManager.initialize(plainKey, Constants.SQRT_PRICE_1_1);
        _mintFullRange(plainKey);
        plain = new PlainVault(poolManager, plainKey, CURATOR);
    }

    /// @dev Probe: second Tenure pool (different fee => different PoolId), same settings, instrumented vault.
    function _setUpProbe() internal {
        probeKey = PoolKey(currency0, currency1, 500, SPACING, IHooks(address(hook)));
        probeId = probeKey.toId();
        poolManager.initialize(probeKey, Constants.SQRT_PRICE_1_1);
        oracle.setPrice(probeId, Constants.SQRT_PRICE_1_1);
        _mintFullRange(probeKey);
        probe = new ProbeVault(poolManager, hook, probeKey);
        hook.registerPool(probeKey, address(probe), oracle, _vaultSettings());
    }

    /// @dev Same funds and the same rebalance history everywhere.
    function _seedHistory() internal {
        // Same funds and the same first rebalance everywhere.
        _deposit(ALICE, DEP, DEP);
        _fundExact(address(plain));
        _fundExact(address(probe));
        _rebalanceAll(_enter());

        // Warm-up swaps both ways on every pool so no measured swap pays one-time slot initialisation
        // (fee growth 0 -> nonzero etc.).
        _warm(key);
        _warm(plainKey);
        _warm(probeKey);
        vm.roll(vm.getBlockNumber() + 20); // past the cooldown (10 blocks)

        // A first re-range everywhere, so the MEASURED rebalance is a steady-state one: the hook's pending snapshot
        // already holds nonzero values (a vault's very first re-range writes them fresh, ~100k more gas once).
        _rebalanceAll(_move());
        vm.roll(vm.getBlockNumber() + 20); // records 0 (age 40) and 1 (age 20): neither due yet (WINDOW = 50)
    }

    // ------------------------------------------------------------------------------------------------ helpers
    function _group() internal view returns (string memory) {
        return string.concat("GasReport.", vm.envOr("FOUNDRY_PROFILE", string("default")));
    }

    function _snap(string memory name) internal returns (uint256 g) {
        g = vm.snapshotGasLastCall(_group(), name);
        console2.log(name, g);
    }

    function _p(int24 tl, int24 tu, uint128 l, int256 swapAmount)
        internal
        pure
        returns (CuratedVault.RebalanceParams memory)
    {
        uint160 limit = swapAmount > 0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        return CuratedVault.RebalanceParams(tl, tu, l, swapAmount, limit);
    }

    function _rebalanceAll(CuratedVault.RebalanceParams memory p) internal {
        vm.prank(CURATOR);
        cv.rebalance(p);
        vm.prank(CURATOR);
        plain.rebalance(p);
        probe.rebalance(p);
    }

    function _warm(PoolKey memory k) internal {
        swapper.swapTo(k, true, SWAP_IN, TickMath.MIN_SQRT_PRICE + 1);
        swapper.swapTo(k, false, SWAP_IN, TickMath.MAX_SQRT_PRICE - 1);
    }

    function _mintFullRange(PoolKey memory k) internal {
        (int24 lo, int24 hi) = _fullRange();
        positionManager.mint(
            k,
            lo,
            hi,
            _thirdPartyLiquidity(),
            type(uint256).max,
            type(uint256).max,
            address(this),
            vm.getBlockTimestamp(),
            ""
        );
    }

    function _fundExact(address who) internal {
        MockERC20(Currency.unwrap(currency0)).mint(who, DEP);
        MockERC20(Currency.unwrap(currency1)).mint(who, DEP);
    }

    /// @dev Enter / return to (-600, 600) with L_RANGE/2, selling 1,000 token0. The MEASURED rebalance is this move
    ///      back from (-1200, 1200): remove old range -> swap -> add new range.
    function _enter() internal pure returns (CuratedVault.RebalanceParams memory) {
        return _p(-600, 600, L_RANGE / 2, 1_000 ether);
    }

    /// @dev Move to (-1200, 1200) with L_RANGE/4, selling 500 token1.
    function _move() internal pure returns (CuratedVault.RebalanceParams memory) {
        return _p(-1200, 1200, L_RANGE / 4, -500 ether);
    }

    /// @dev `n` more records on the vault pool: alternate the two ranges (with swaps), respecting the cooldown.
    function _makeRecords(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            vm.roll(vm.getBlockNumber() + 20);
            // even count => currently in the (-1200, 1200) range (setUp leaves 2 records there)
            bool even = hook.recordCount(poolId) % 2 == 0;
            vm.prank(CURATOR);
            if (even) cv.rebalance(_enter());
            else cv.rebalance(_move());
        }
    }
}

/// @notice Pool with afterSwap auto-settlement ON (autoSettlePerSwap = 1).
contract GasReportAutoSettleOnTest is GasReportBase {
    constructor() {
        autoSettle = 1;
    }

    // ------------------------------------------------------------------------------------------------ swaps
    function test_gas_swap_noHook() public {
        swapper.swapTo(plainKey, true, SWAP_IN, TickMath.MIN_SQRT_PRICE + 1);
        _snap("swap_noHook");
    }

    /// Hook runs afterSwap; record 0 exists but is not due, so nothing is settled.
    function test_gas_swap_tenure_nothingDue() public {
        swapper.swapTo(key, true, SWAP_IN, TickMath.MIN_SQRT_PRICE + 1);
        _snap("swap_tenure_autoSettle1_nothingDue");
        assertFalse(hook.recordOf(poolId, 0).settled);
    }

    /// The swapper's afterSwap settles the due record 0 (one fee-aware markout).
    function test_gas_swap_tenure_settlesOne() public {
        vm.roll(vm.getBlockNumber() + WINDOW);
        swapper.swapTo(key, true, SWAP_IN, TickMath.MIN_SQRT_PRICE + 1);
        _snap("swap_tenure_autoSettle1_settlesOne");
        assertTrue(hook.recordOf(poolId, 0).settled, "settled by the swap");
    }

    // ------------------------------------------------------------------------------------------------ rebalance
    /// Same liquidity moves, same swap, same starting position: Tenure pool + CuratedVault vs hookless + PlainVault.
    function test_gas_rebalance_tenureVsNoHook() public {
        vm.prank(CURATOR);
        cv.rebalance(_enter());
        uint256 gT = _snap("rebalance_tenure");
        vm.prank(CURATOR);
        plain.rebalance(_enter());
        uint256 gP = _snap("rebalance_noHook");
        assertEq(hook.recordCount(poolId), 3, "measured rebalance recorded");
        assertEq(hook.currentRange(poolId).liquidity, L_RANGE / 2);
        (int24 tl,, uint128 lPlain) = plain.range();
        assertEq(lPlain, L_RANGE / 2, "baseline did the same move");
        assertEq(tl, -600);
        assertGt(gT, gP, "Tenure adds overhead");
        vm.snapshotValue(_group(), "rebalance_tenureOverhead", gT - gP);
        console2.log("Tenure overhead per rebalance:", gT - gP);
    }

    /// beginRebalance / endRebalance as the vault pays for them (including the cold call into the hook).
    function test_gas_beginEndRebalance() public {
        probe.rebalance(_enter());
        uint256 gProbe = _snap("rebalance_probe");
        assertEq(hook.recordCount(probeId), 3);
        vm.snapshotValue(_group(), "beginRebalance", probe.gBegin());
        vm.snapshotValue(_group(), "endRebalance", probe.gEnd());
        vm.snapshotValue(_group(), "rebalance_probe_unlock", probe.gUnlock());
        console2.log("beginRebalance:", probe.gBegin());
        console2.log("endRebalance:", probe.gEnd());
        console2.log("unlock (remove+swap+add incl. hook callbacks):", probe.gUnlock());
        assertLt(probe.gBegin() + probe.gUnlock() + probe.gEnd(), gProbe, "breakdown within the call");
    }

    // ------------------------------------------------------------------------------------------------ depositors
    /// A second depositor while the vault has a live position (first-deposit dead-share minting excluded).
    function test_gas_deposit() public {
        vm.prank(BOB);
        cv.deposit(5_000 ether, 5_000 ether, 0, BOB);
        _snap("deposit");
        assertGt(cv.balanceOf(BOB), 0);
    }

    /// Full exit of a depositor while the vault has a live position (pro-rata liquidity removal in a hook session).
    function test_gas_withdraw() public {
        vm.prank(BOB);
        cv.deposit(5_000 ether, 5_000 ether, 0, BOB);
        uint256 s = cv.balanceOf(BOB);
        vm.prank(BOB);
        cv.withdraw(s, 0, 0, BOB);
        _snap("withdraw");
        assertEq(cv.balanceOf(BOB), 0);
    }

    // ------------------------------------------------------------------------------------------------ deployment
    /// Deployment gas = in-EVM CREATE/CREATE2 cost (32k + initcode words + constructor + 200 gas/byte of runtime code)
    /// + the transaction's intrinsic cost (21,000 + calldata: 16 gas per nonzero, 4 per zero initcode byte).
    /// TenureHook goes through CREATE2 at a mined flag address (as in script/DeployTenureHook.s.sol).
    function test_gas_deployment() public {
        _deployScorer();
        _deployVault();
        _deployHook();
    }

    function _deployScorer() internal {
        bytes memory scorer = vm.getCode("TenureScorer.sol:TenureScorer");
        (address a, uint256 g) = _create(scorer);
        assertTrue(a != address(0), "scorer deployed");
        vm.snapshotValue(_group(), "deploy_TenureScorer", g + _intrinsic(scorer));
    }

    function _deployVault() internal {
        bytes memory args =
            abi.encode(poolManager, hook, key, address(this), CURATOR, MAX_DEPOSIT_DEV, "Tenure Vault", "tnV");
        bytes memory vaultCode = abi.encodePacked(vm.getCode("CuratedVault.sol:CuratedVault"), args);
        (address a, uint256 g) = _create(vaultCode);
        assertTrue(a != address(0), "vault deployed");
        vm.snapshotValue(_group(), "deploy_CuratedVault", g + _intrinsic(vaultCode));
    }

    function _deployHook() internal {
        bytes memory hookCode = abi.encodePacked(
            vm.getCode("TenureHook.sol:TenureHook"),
            abi.encode(poolManager, address(this), GUARDIAN, MANDATE_DELAY, RESTORE_DELAY)
        );
        (address a, uint256 g) = _create2(hookCode, _mine(keccak256(hookCode)));
        assertTrue(a != address(0), "hook deployed");
        assertEq(uint160(a) & 0x3FFF, HOOK_FLAGS, "flag address");
        // +32 B salt in the calldata to the CREATE2 factory (counted as nonzero, i.e. an upper bound)
        vm.snapshotValue(_group(), "deploy_TenureHook", g + _intrinsic(hookCode) + 32 * 16);
        vm.snapshotValue(_group(), "size_TenureHook", a.code.length);
        // Only the deploy profile (via-IR) fits EIP-170; forge tests do not enforce the limit, so check it here.
        if (keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("default")))) == keccak256("deploy")) {
            assertLe(a.code.length, 24_576, "EIP-170");
        } else {
            assertGt(a.code.length, 24_576, "default profile is over EIP-170 (why deploys use via-IR)");
        }
    }

    function _create(bytes memory code) internal returns (address a, uint256 g) {
        g = gasleft();
        assembly {
            a := create(0, add(code, 0x20), mload(code))
        }
        g -= gasleft();
    }

    function _create2(bytes memory code, bytes32 salt) internal returns (address a, uint256 g) {
        g = gasleft();
        assembly {
            a := create2(0, add(code, 0x20), mload(code), salt)
        }
        g -= gasleft();
    }

    function _intrinsic(bytes memory data) internal pure returns (uint256 g) {
        g = 21_000;
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    /// @dev Mine a CREATE2 salt (deployer = this test) whose address carries exactly the hook's 14 flag bits.
    function _mine(bytes32 initHash) internal view returns (bytes32 salt) {
        for (uint256 s; s < 400_000; ++s) {
            address a = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), address(this), bytes32(s), initHash))))
            );
            if (uint160(a) & 0x3FFF == HOOK_FLAGS && a.code.length == 0) return bytes32(s);
        }
        revert("no salt");
    }
}

/// @notice Pool with afterSwap auto-settlement OFF (autoSettlePerSwap = 0): keepers settle with settleMany.
contract GasReportAutoSettleOffTest is GasReportBase {
    using PoolIdLibrary for PoolKey;

    constructor() {
        autoSettle = 0;
    }

    /// Record 0 is due but the swapper pays nothing for it.
    function test_gas_swap_tenure_autoSettleOff_recordsDue() public {
        vm.roll(vm.getBlockNumber() + WINDOW);
        swapper.swapTo(key, true, SWAP_IN, TickMath.MIN_SQRT_PRICE + 1);
        _snap("swap_tenure_autoSettle0_recordsDue");
        assertFalse(hook.recordOf(poolId, 0).settled, "swap settled nothing");
    }

    /// Keeper batch of 1 record (records alternate ranges, each with a swap).
    function test_gas_settleMany_1() public {
        _makeRecords(3); // records 0..4
        vm.roll(vm.getBlockNumber() + WINDOW);
        uint256[] memory ids = new uint256[](1);
        uint256 settled = hook.settleMany(poolId, ids);
        _snap("settleMany_1");
        assertEq(settled, 1);
    }

    /// Keeper batch of 5 records (same history as above).
    function test_gas_settleMany_5() public {
        _makeRecords(3); // records 0..4
        vm.roll(vm.getBlockNumber() + WINDOW);
        uint256[] memory ids = new uint256[](5);
        (ids[1], ids[2], ids[3], ids[4]) = (1, 2, 3, 4);
        uint256 settled = hook.settleMany(poolId, ids);
        _snap("settleMany_5");
        assertEq(settled, 5);
        assertEq(uint256(hook.tierOf(poolId)), uint256(Tier.FULL), "honest records keep FULL");
    }
}
