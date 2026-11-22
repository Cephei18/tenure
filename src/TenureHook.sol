// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IReferencePrice} from "./interfaces/IReferencePrice.sol";
import {ReferencePriceLib} from "./libraries/ReferencePriceLib.sol";
import {Holdings, Range} from "./libraries/PositionValue.sol";
import {TenureScorer} from "./libraries/TenureScorer.sol";
import {FeesOwed} from "./libraries/FeesOwed.sol";
import {RiskBudget, BudgetParams, BudgetState, Tier} from "./libraries/RiskBudget.sol";

/// @notice Depositor-agreed bounds on what the curator may do. Tick-denominated so they are price-scale free.
struct Mandate {
    uint24 minWidth; // min tickUpper - tickLower of a non-empty range (doubled in RESTRICTED)
    uint24 maxWidth; // max width
    uint24 maxCenterDist; // max |range center - fair tick|
    uint64 maxMoveWad; // max value converted between tokens per rebalance, WAD of NAV (halved in RESTRICTED)
    uint32 cooldown; // min blocks between rebalances (doubled in RESTRICTED)
}

/// @notice Everything fixed at registration except the (timelocked) mandate.
struct PoolSettings {
    uint32 maxOracleAge; // seconds
    uint32 window; // markout window W, blocks
    uint24 maxSettleDev; // settlement requires |spot tick - fair tick| <= this (anti window-gaming)
    Mandate mandate;
    BudgetParams budget;
}

/// @notice One scored curator decision.
struct RebalanceRecord {
    Range oldRange;
    Range newRange;
    Holdings idleOld;
    Holdings idleNew;
    uint256 navBefore; // denominator for loss/gain fractions
    uint64 blockNumber;
    bool settled;
}

/// @title TenureHook - earned autonomy for liquidity curators
/// @notice Gates every liquidity change of a registered curated vault behind a MEASURED session, reading pool state
///         and the vault's position independently from the PoolManager. Each rebalance is scored at a fair price
///         (immediate leakage now, markout alpha after W blocks); losses drain a risk budget whose level sets the
///         curator's autonomy tier. The curator (off-chain, untrusted) never talks to this hook; the vault does.
contract TenureHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    // ------------------------------------------------------------------------------------------------ errors
    error Tenure__NotOwner();
    error Tenure__NotGuardian();
    error Tenure__NotVault();
    error Tenure__NotRegistered();
    error Tenure__AlreadyRegistered();
    error Tenure__WrongHook();
    error Tenure__ZeroAddress();
    error Tenure__NoSession();
    error Tenure__SessionOpen();
    error Tenure__WrongSession();
    error Tenure__NotCurrentRange();
    error Tenure__MultipleRanges();
    error Tenure__BadSalt();
    error Tenure__OrphanedLiquidity();
    error Tenure__InvalidMandate();
    error Tenure__Frozen();
    error Tenure__NotFrozen();
    error Tenure__Cooldown(uint256 readyAt);
    error Tenure__RangeTooNarrow(uint256 width, uint256 minWidth);
    error Tenure__RangeTooWide(uint256 width, uint256 maxWidth);
    error Tenure__RangeOffFair(uint256 dist, uint256 maxDist);
    error Tenure__MovedTooMuch(uint256 movedWad, uint256 maxWad);
    error Tenure__SafeModeMustExit();
    error Tenure__NoPendingChange();
    error Tenure__Timelocked(uint256 readyAt);
    error Tenure__UnknownRecord();
    error Tenure__AlreadySettled();
    error Tenure__TooEarly(uint256 dueBlock);
    error Tenure__SpotOffFair(uint256 dev, uint256 maxDev);

    // ------------------------------------------------------------------------------------------------ constants
    /// @dev Session kinds held in transient storage. REBALANCE is measured; PRORATA lets the vault scale its current
    ///      range for deposits/withdrawals (shape unchanged, nothing to score); SAFE only de-risks (remove to idle).
    uint256 internal constant SESSION_NONE = 0;
    uint256 internal constant SESSION_REBALANCE = 1;
    uint256 internal constant SESSION_PRORATA = 2;
    uint256 internal constant SESSION_SAFE = 3;

    /// @dev uint256(keccak256("tenure.session")) - 1 and uint256(keccak256("tenure.newrange")) - 1, keyed by pool.
    bytes32 internal constant SESSION_SLOT = 0x4cf0626aa298570f9f11853ed284e3a77616d44640b681cd7282c06e4d6758b9;
    bytes32 internal constant NEWRANGE_SLOT = 0x91a39552ac870bd84550b1ff670fbd9576e38088668f0d566a8e0988b6a134b6;

    /// @notice Max records settled opportunistically per swap, and max records inspected (bounded afterSwap gas).
    uint256 public constant MAX_AUTO_SETTLE = 3;
    uint256 public constant MAX_AUTO_SCAN = 6;

    /// @notice Delay before a proposed mandate takes effect: depositors can exit first.
    uint256 public immutable mandateDelay; // seconds
    /// @notice Delay (blocks) between a guardian restore request and its execution.
    uint256 public immutable restoreDelay;

    // ------------------------------------------------------------------------------------------------ storage
    struct PoolConfig {
        address vault;
        IReferencePrice oracle;
        Currency currency0;
        Currency currency1;
    }

    /// @notice What the hook saw when the session opened (H_before inputs + fair price).
    struct Snapshot {
        Range oldRange;
        Holdings idle; // vault token balances + fees owed on the old position (H_before must include them)
        uint160 spot;
        uint160 fair;
        uint256 fgOld0; // fee growth inside the old range at t (only meaningful if oldRange.liquidity > 0)
        uint256 fgOld1;
        uint256 global0; // global fee growth at the snapshot (the exit point of the range being left)
        uint256 global1;
    }

    /// @dev Fee-growth accumulators at record time t, for fee-aware markouts (M3.3).
    struct FeeSnap {
        uint256 global0;
        uint256 global1;
        uint256 old0; // inside the old range (counterfactual)
        uint256 old1;
        uint256 new0; // inside the new range
        uint256 new1;
        // Set when the vault abandons the new range before settlement: fee growth at that moment (the ticks were
        // still initialized, so it is exact). Both sides are then compared over the observed interval [t, exit].
        bool exited;
        uint256 exitGlobal0;
        uint256 exitGlobal1;
        uint256 exitNew0;
        uint256 exitNew1;
    }

    struct PendingMandate {
        Mandate mandate;
        uint64 eta; // timestamp; 0 = none
    }

    address public owner;
    address public guardian;
    mapping(PoolId => PoolConfig) public configs;
    mapping(PoolId => PoolSettings) internal _settings;
    mapping(PoolId => BudgetState) internal _budget;
    mapping(PoolId => Range) internal _currentRange; // ticks only; liquidity always re-read from the PoolManager
    mapping(PoolId => Snapshot) internal _pending;
    mapping(PoolId => PendingMandate) internal _pendingMandate;
    mapping(PoolId => RebalanceRecord[]) internal _records;
    mapping(PoolId => mapping(uint256 => FeeSnap)) internal _feeSnaps;
    mapping(PoolId => uint256) public settlePointer; // all records below are settled
    mapping(PoolId => uint256) public lastRebalanceBlock;
    mapping(PoolId => uint256) public restoreEta; // block; 0 = none requested

    // ------------------------------------------------------------------------------------------------ events
    event PoolRegistered(PoolId indexed poolId, address indexed vault, address oracle);
    event SessionOpened(PoolId indexed poolId, uint256 kind, uint160 spot, uint160 fair);
    event SessionClosed(PoolId indexed poolId, uint256 kind);
    event RangeUpdated(PoolId indexed poolId, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event RebalanceScored(
        PoolId indexed poolId,
        uint256 indexed recordId,
        int256 leakage,
        uint256 navBefore,
        uint256 lossWad,
        uint256 movedWad,
        uint256 budget,
        Tier tier
    );
    event MarkoutSettled(
        PoolId indexed poolId,
        uint256 indexed recordId,
        int256 alpha,
        uint256 lossWad,
        uint256 gainWad,
        uint256 budget,
        uint256 bMax,
        Tier tier
    );
    event TierChanged(PoolId indexed poolId, Tier from, Tier to);
    event MandateProposed(PoolId indexed poolId, Mandate mandate, uint256 eta);
    event MandateExecuted(PoolId indexed poolId, Mandate mandate);
    event MandateCancelled(PoolId indexed poolId);
    event SafeModeEntered(PoolId indexed poolId, uint256 liquidityRemoved);
    event RestoreRequested(PoolId indexed poolId, uint256 eta);
    event Restored(PoolId indexed poolId, uint256 budget, Tier tier);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event GuardianChanged(address indexed previousGuardian, address indexed newGuardian);

    constructor(
        IPoolManager _poolManager,
        address _owner,
        address _guardian,
        uint256 _mandateDelay,
        uint256 _restoreDelay
    ) BaseHook(_poolManager) {
        if (_owner == address(0) || _guardian == address(0)) revert Tenure__ZeroAddress();
        owner = _owner;
        guardian = _guardian;
        mandateDelay = _mandateDelay;
        restoreDelay = _restoreDelay;
        emit OwnershipTransferred(address(0), _owner);
        emit GuardianChanged(address(0), _guardian);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Tenure__NotOwner();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert Tenure__NotGuardian();
        _;
    }

    modifier onlyVault(PoolId id) {
        address v = configs[id].vault;
        if (v == address(0)) revert Tenure__NotRegistered();
        if (msg.sender != v) revert Tenure__NotVault();
        _;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ================================================================================================ admin
    /// @notice Hand over ownership (registration and mandate proposals).
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert Tenure__ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Replace the guardian (the only party that can lift FROZEN).
    function setGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert Tenure__ZeroAddress();
        emit GuardianChanged(guardian, newGuardian);
        guardian = newGuardian;
    }

    /// @notice Register the curated vault for a pool that uses this hook. MVP: owner-set, one vault per pool.
    /// @param key Pool key (must point at this hook).
    /// @param vault The CuratedVault whose liquidity is gated and measured.
    /// @param oracle Fair reference price source.
    /// @param s Oracle age, markout window, settlement deviation, initial mandate, budget params.
    function registerPool(PoolKey calldata key, address vault, IReferencePrice oracle, PoolSettings calldata s)
        external
        onlyOwner
    {
        if (address(key.hooks) != address(this)) revert Tenure__WrongHook();
        if (vault == address(0) || address(oracle) == address(0)) revert Tenure__ZeroAddress();
        PoolId id = key.toId();
        if (configs[id].vault != address(0)) revert Tenure__AlreadyRegistered();
        _validateMandate(s.mandate);
        RiskBudget.validate(s.budget);
        configs[id] = PoolConfig(vault, oracle, key.currency0, key.currency1);
        _settings[id] = s;
        _budget[id] = RiskBudget.init(s.budget, block.number);
        emit PoolRegistered(id, vault, address(oracle));
    }

    /// @notice Propose a new mandate. Takes effect only after `mandateDelay`, so depositors can exit first.
    function proposeMandate(PoolId id, Mandate calldata m) external onlyOwner {
        if (configs[id].vault == address(0)) revert Tenure__NotRegistered();
        _validateMandate(m);
        uint256 eta = block.timestamp + mandateDelay;
        _pendingMandate[id] = PendingMandate(m, uint64(eta));
        emit MandateProposed(id, m, eta);
    }

    /// @notice Apply a proposed mandate after its timelock. Anyone may call.
    function executeMandate(PoolId id) external {
        PendingMandate memory p = _pendingMandate[id];
        if (p.eta == 0) revert Tenure__NoPendingChange();
        if (block.timestamp < p.eta) revert Tenure__Timelocked(p.eta);
        _settings[id].mandate = p.mandate;
        delete _pendingMandate[id];
        emit MandateExecuted(id, p.mandate);
    }

    /// @notice Cancel a pending mandate change.
    function cancelMandate(PoolId id) external onlyOwner {
        if (_pendingMandate[id].eta == 0) revert Tenure__NoPendingChange();
        delete _pendingMandate[id];
        emit MandateCancelled(id);
    }

    /// @notice Guardian starts the timelock to lift FROZEN.
    function requestRestore(PoolId id) external onlyGuardian {
        if (_budget[id].tier != Tier.FROZEN) revert Tenure__NotFrozen();
        uint256 eta = block.number + restoreDelay;
        restoreEta[id] = eta;
        emit RestoreRequested(id, eta);
    }

    /// @notice Guardian lifts FROZEN after the timelock. Autonomy is re-earned: lands in RESTRICTED, not FULL.
    function restore(PoolId id) external onlyGuardian {
        BudgetState memory b = _budget[id];
        if (b.tier != Tier.FROZEN) revert Tenure__NotFrozen();
        uint256 eta = restoreEta[id];
        if (eta == 0) revert Tenure__NoPendingChange();
        if (block.number < eta) revert Tenure__Timelocked(eta);
        RiskBudget.restore(b, _settings[id].budget, block.number);
        _storeBudget(id, b, Tier.FROZEN);
        delete restoreEta[id];
        emit Restored(id, b.budget, b.tier);
    }

    // ================================================================================================ sessions
    /// @notice Open a measured rebalance session. Refills the budget, enforces tier + cooldown + oracle freshness,
    ///         and snapshots H_before (vault position read from the PoolManager + the vault's token balances), pool
    ///         spot and the fair price. Called by the vault BEFORE poolManager.unlock (no outstanding deltas).
    function beginRebalance(PoolKey calldata key) external onlyVault(key.toId()) {
        PoolId id = key.toId();
        if (_session(id) != SESSION_NONE) revert Tenure__SessionOpen();
        BudgetState memory b = _refilled(id);
        if (b.tier == Tier.FROZEN) revert Tenure__Frozen();
        uint256 cd = _settings[id].mandate.cooldown;
        if (b.tier == Tier.RESTRICTED) cd *= 2;
        uint256 last = lastRebalanceBlock[id];
        if (last != 0 && block.number < last + cd) revert Tenure__Cooldown(last + cd);
        _snapshot(id);
        _setSession(id, SESSION_REBALANCE);
        emit SessionOpened(id, SESSION_REBALANCE, _pending[id].spot, _pending[id].fair);
    }

    /// @notice Close the measured session: read H_after independently, enforce the mandate, score immediate leakage,
    ///         charge the budget and store a RebalanceRecord for markout settlement.
    /// @dev Called by the vault AFTER unlock returns (all deltas settled, balances final).
    function endRebalance(PoolKey calldata key) external onlyVault(key.toId()) returns (uint256 recordId) {
        PoolId id = key.toId();
        if (_session(id) != SESSION_REBALANCE) revert Tenure__WrongSession();
        recordId = _closeRebalance(id);
    }

    /// @notice Open a pro-rata session (deposit/withdraw): the vault may scale its CURRENT range only.
    /// @dev Allowed in every tier: withdrawals must never be blocked.
    function beginProRata(PoolKey calldata key) external onlyVault(key.toId()) {
        PoolId id = key.toId();
        if (_session(id) != SESSION_NONE) revert Tenure__SessionOpen();
        _setSession(id, SESSION_PRORATA);
        emit SessionOpened(id, SESSION_PRORATA, 0, 0);
    }

    /// @notice Close the pro-rata session.
    function endProRata(PoolKey calldata key) external onlyVault(key.toId()) {
        PoolId id = key.toId();
        if (_session(id) != SESSION_PRORATA) revert Tenure__WrongSession();
        _setSession(id, SESSION_NONE);
        emit SessionClosed(id, SESSION_PRORATA);
    }

    /// @notice Open a safe-mode session: only removal from the current range is allowed, ending fully idle.
    /// @dev Allowed in every tier (de-risking is always permitted); the vault decides who may trigger it.
    function beginSafeMode(PoolKey calldata key) external onlyVault(key.toId()) {
        PoolId id = key.toId();
        if (_session(id) != SESSION_NONE) revert Tenure__SessionOpen();
        Range memory r = _currentRange[id];
        r.liquidity = _liquidityAt(id, configs[id].vault, r.tickLower, r.tickUpper);
        if (r.liquidity != 0) {
            Snapshot storage p = _pending[id];
            p.oldRange = r;
            (p.fgOld0, p.fgOld1) = poolManager.getFeeGrowthInside(id, r.tickLower, r.tickUpper);
            (p.global0, p.global1) = poolManager.getFeeGrowthGlobals(id);
        }
        _setSession(id, SESSION_SAFE);
        emit SessionOpened(id, SESSION_SAFE, 0, 0);
    }

    /// @notice Close safe mode; reverts unless the vault's position is now empty.
    function endSafeMode(PoolKey calldata key, uint256 liquidityRemoved) external onlyVault(key.toId()) {
        PoolId id = key.toId();
        if (_session(id) != SESSION_SAFE) revert Tenure__WrongSession();
        Range memory r = _currentRange[id];
        if (_liquidityAt(id, configs[id].vault, r.tickLower, r.tickUpper) != 0) revert Tenure__SafeModeMustExit();
        if (liquidityRemoved != 0) _markExit(id, _pending[id]);
        _setSession(id, SESSION_NONE);
        emit SafeModeEntered(id, liquidityRemoved);
        emit SessionClosed(id, SESSION_SAFE);
    }

    // ================================================================================================ markouts
    /// @notice Settle a record's markout after W blocks. Anyone may call (keeper-free; afterSwap also does it).
    /// @dev alpha < 0 drains the budget and decays reputation; alpha > 0 grows reputation only (never refills).
    ///      Requires spot near fair so a manipulated spot cannot game the markout.
    function settle(PoolId id, uint256 recordId) external returns (int256 alpha) {
        if (configs[id].vault == address(0)) revert Tenure__NotRegistered();
        if (recordId >= _records[id].length) revert Tenure__UnknownRecord();
        RebalanceRecord storage r = _records[id][recordId];
        if (r.settled) revert Tenure__AlreadySettled();
        uint256 due = uint256(r.blockNumber) + _settings[id].window;
        if (block.number < due) revert Tenure__TooEarly(due);
        PoolSettings storage s = _settings[id];
        uint160 fair = ReferencePriceLib.readFresh(configs[id].oracle, id, s.maxOracleAge);
        (uint160 spot,,,) = poolManager.getSlot0(id);
        uint256 dev = TenureScorer.tickDistance(spot, fair);
        if (dev > s.maxSettleDev) revert Tenure__SpotOffFair(dev, s.maxSettleDev);
        alpha = _settle(id, recordId, spot, fair);
        _advancePointer(id);
    }

    // ================================================================================================ views
    /// @notice The vault's tracked range with liquidity read live from the PoolManager.
    function currentRange(PoolId id) public view returns (Range memory r) {
        r = _currentRange[id];
        r.liquidity = _liquidityAt(id, configs[id].vault, r.tickLower, r.tickUpper);
    }

    /// @notice Open session kind for a pool in the current transaction (0 = none).
    function sessionOf(PoolId id) external view returns (uint256) {
        return _session(id);
    }

    /// @notice Budget state as of now (refill applied in memory).
    function budgetOf(PoolId id) external view returns (BudgetState memory b) {
        b = _budget[id];
        RiskBudget.refill(b, _settings[id].budget, block.number);
    }

    /// @notice Current autonomy tier (refill applied).
    function tierOf(PoolId id) external view returns (Tier) {
        BudgetState memory b = _budget[id];
        RiskBudget.refill(b, _settings[id].budget, block.number);
        return b.tier;
    }

    /// @notice Vault deposit cap, grown only by measured positive alpha (pool-native reputation).
    function depositCap(PoolId id) external view returns (uint256) {
        return RiskBudget.depositCap(_budget[id], _settings[id].budget);
    }

    /// @notice Registration settings (window, mandate, budget params...).
    function settingsOf(PoolId id) external view returns (PoolSettings memory) {
        return _settings[id];
    }

    /// @notice Pending mandate change, if any.
    function pendingMandate(PoolId id) external view returns (Mandate memory m, uint256 eta) {
        PendingMandate memory p = _pendingMandate[id];
        return (p.mandate, p.eta);
    }

    /// @notice A stored rebalance record.
    function recordOf(PoolId id, uint256 recordId) external view returns (RebalanceRecord memory) {
        return _records[id][recordId];
    }

    /// @notice Number of rebalance records for a pool.
    function recordCount(PoolId id) external view returns (uint256) {
        return _records[id].length;
    }

    // ================================================================================================ callbacks
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        PoolId id = key.toId();
        if (sender == configs[id].vault) {
            if (params.salt != bytes32(0)) revert Tenure__BadSalt();
            uint256 kind = _session(id);
            if (kind == SESSION_REBALANCE) {
                _recordNewRange(id, params.tickLower, params.tickUpper);
            } else if (kind == SESSION_PRORATA) {
                _requireCurrentRange(id, params.tickLower, params.tickUpper);
            } else {
                // NONE, or SAFE (safe mode may only remove)
                revert Tenure__NoSession();
            }
        }
        return this.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        PoolId id = key.toId();
        if (sender == configs[id].vault) {
            if (params.salt != bytes32(0)) revert Tenure__BadSalt();
            if (_session(id) == SESSION_NONE) revert Tenure__NoSession();
            // Every session kind may only remove from the tracked (old) range.
            _requireCurrentRange(id, params.tickLower, params.tickUpper);
        }
        return this.beforeRemoveLiquidity.selector;
    }

    /// @dev Keeper-free markouts: piggyback on swap flow and settle up to MAX_AUTO_SETTLE due records. Never
    ///      reverts the swap: skips silently if the oracle is stale/broken, spot is off fair, or a vault session is
    ///      open. Bounded by MAX_AUTO_SCAN iterations.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        if (configs[id].vault != address(0) && _session(id) == SESSION_NONE) _autoSettle(id);
        return (this.afterSwap.selector, 0);
    }

    // ================================================================================================ internals
    function _autoSettle(PoolId id) internal {
        uint256 ptr = settlePointer[id];
        uint256 len = _records[id].length;
        if (ptr >= len) return;
        PoolSettings storage s = _settings[id];
        if (block.number < uint256(_records[id][ptr].blockNumber) + s.window) return;

        uint160 fair;
        try configs[id].oracle.getSqrtPriceX96(id) returns (uint160 f, uint256 updatedAt) {
            if (f < TickMath.MIN_SQRT_PRICE || f >= TickMath.MAX_SQRT_PRICE) return;
            if (updatedAt > block.timestamp || block.timestamp - updatedAt > s.maxOracleAge) return;
            fair = f;
        } catch {
            return;
        }
        (uint160 spot,,,) = poolManager.getSlot0(id);
        if (TenureScorer.tickDistance(spot, fair) > s.maxSettleDev) return;

        uint256 settled;
        for (uint256 scanned; scanned < MAX_AUTO_SCAN && ptr < len && settled < MAX_AUTO_SETTLE; ++scanned) {
            RebalanceRecord storage r = _records[id][ptr];
            if (!r.settled) {
                if (block.number < uint256(r.blockNumber) + s.window) break; // records are chronological
                _settle(id, ptr, spot, fair);
                ++settled;
            }
            ++ptr;
        }
        settlePointer[id] = ptr;
    }

    function _settle(PoolId id, uint256 recordId, uint160 spot, uint160 fair) internal returns (int256 alpha) {
        RebalanceRecord storage r = _records[id][recordId];
        r.settled = true;
        alpha = _alphaWithFees(id, recordId, r, spot, fair);
        BudgetState memory b = _refilled(id);
        Tier before = b.tier;
        uint256 lossW;
        uint256 gainW;
        (b, lossW, gainW) = TenureScorer.applyMarkout(b, _settings[id].budget, alpha, r.navBefore);
        _storeBudget(id, b, before);
        emit MarkoutSettled(id, recordId, alpha, lossW, gainW, b.budget, b.bMax, b.tier);
    }

    /// @dev Markout alpha with LP fees (M3.3): H_new and H_cf each get the fees their range earned over the window.
    function _alphaWithFees(PoolId id, uint256 recordId, RebalanceRecord storage r, uint160 spot, uint160 fair)
        internal
        view
        returns (int256)
    {
        Holdings[2] memory fees = _windowFees(id, recordId, r); // [counterfactual, new]
        return TenureScorer.alphaWithFees(r.oldRange, r.idleOld, fees[0], r.newRange, r.idleNew, fees[1], spot, fair);
    }

    /// @notice Fees credited to a record's counterfactual (old range) and new range as of now (tenure-math 4b).
    /// @return feesCf Fees the old range would have earned since the record (curator-adverse estimate).
    /// @return feesNew Fees the new range earned since the record (curator-adverse estimate).
    function windowFees(PoolId id, uint256 recordId)
        external
        view
        returns (Holdings memory feesCf, Holdings memory feesNew)
    {
        Holdings[2] memory f = _windowFees(id, recordId, _records[id][recordId]);
        return (f[0], f[1]);
    }

    /// @dev Reads slot0 + globals once and each tick's info once (gross liquidity + fee growth outside in one call),
    ///      then derives fee growth inside exactly like v4's StateLibrary.getFeeGrowthInside.
    function _windowFees(PoolId id, uint256 recordId, RebalanceRecord storage r)
        internal
        view
        returns (Holdings[2] memory fees)
    {
        FeeSnap storage f = _feeSnaps[id][recordId];
        if (f.exited) return _exitedFees(f, r);
        uint256[4] memory g; // [globalNow0, globalNow1, globalThen0, globalThen1]
        (g[0], g[1]) = poolManager.getFeeGrowthGlobals(id);
        (g[2], g[3]) = (f.global0, f.global1);
        (, int24 tick,,) = poolManager.getSlot0(id);
        fees[0] = _fees(id, r.oldRange, f.old0, f.old1, g, tick, true);
        fees[1] = _fees(id, r.newRange, f.new0, f.new1, g, tick, false);
    }

    /// @dev The new range was abandoned before settlement: compare both sides over [t, exit]. The new range's fees
    ///      are exact; the old range shares them only if it is the same range, else gets the global upper bound.
    function _exitedFees(FeeSnap storage f, RebalanceRecord storage r) internal view returns (Holdings[2] memory fees) {
        uint256[4] memory g = [f.exitGlobal0, f.exitGlobal1, f.global0, f.global1];
        uint256[4] memory inside = [f.exitNew0, f.exitNew1, f.new0, f.new1];
        bool same = r.oldRange.tickLower == r.newRange.tickLower && r.oldRange.tickUpper == r.newRange.tickUpper;
        fees[0] = TenureScorer.windowFees(g, inside, r.oldRange.liquidity, same, true);
        fees[1] = TenureScorer.windowFees(g, inside, r.newRange.liquidity, true, false);
    }

    /// @dev Fees the hypothetical position `r` earned since record time. Trust the range's fee-growth-inside only if
    ///      both ticks are initialized now; DecisionScore.estimateFees (via TenureScorer.windowFees) also rejects an
    ///      inside delta above the global one and applies the curator-adverse fallback.
    function _fees(PoolId id, Range memory r, uint256 then0, uint256 then1, uint256[4] memory g, int24 tick, bool cf)
        internal
        view
        returns (Holdings memory)
    {
        if (r.liquidity == 0) return Holdings(0, 0);
        (uint256 in0, uint256 in1, bool initialized) = _insideGrowth(id, r, tick, g[0], g[1]);
        return TenureScorer.windowFees(g, [in0, in1, then0, then1], r.liquidity, initialized, cf);
    }

    /// @dev v4's fee-growth-inside formula from one getTickInfo per tick; `initialized` = both ticks have liquidity.
    function _insideGrowth(PoolId id, Range memory r, int24 tick, uint256 global0, uint256 global1)
        internal
        view
        returns (uint256 in0, uint256 in1, bool initialized)
    {
        (uint128 gL,, uint256 lo0, uint256 lo1) = poolManager.getTickInfo(id, r.tickLower);
        (uint128 gU,, uint256 up0, uint256 up1) = poolManager.getTickInfo(id, r.tickUpper);
        initialized = gL != 0 && gU != 0;
        unchecked {
            if (tick < r.tickLower) {
                (in0, in1) = (lo0 - up0, lo1 - up1);
            } else if (tick >= r.tickUpper) {
                (in0, in1) = (up0 - lo0, up1 - lo1);
            } else {
                (in0, in1) = (global0 - lo0 - up0, global1 - lo1 - up1);
            }
        }
    }

    function _advancePointer(PoolId id) internal {
        uint256 ptr = settlePointer[id];
        uint256 len = _records[id].length;
        for (uint256 i; i < MAX_AUTO_SCAN && ptr < len && _records[id][ptr].settled; ++i) {
            ++ptr;
        }
        settlePointer[id] = ptr;
    }

    function _snapshot(PoolId id) internal {
        PoolConfig storage c = configs[id];
        uint160 fair = ReferencePriceLib.readFresh(c.oracle, id, _settings[id].maxOracleAge);
        (uint160 spot,,,) = poolManager.getSlot0(id);
        Range memory r = _currentRange[id];
        r.liquidity = _liquidityAt(id, c.vault, r.tickLower, r.tickUpper);
        Holdings memory idle = _idleWithFees(id, c, r);
        (uint256 fg0, uint256 fg1) =
            r.liquidity == 0 ? (0, 0) : poolManager.getFeeGrowthInside(id, r.tickLower, r.tickUpper);
        (uint256 g0, uint256 g1) = poolManager.getFeeGrowthGlobals(id);
        _pending[id] = Snapshot(r, idle, spot, fair, fg0, fg1, g0, g1);
    }

    /// @dev The vault is abandoning range `snap.oldRange` (re-range, exit to idle, safe mode). If the latest record
    ///      placed that range, store its exact fee growth at this exit point (tenure-math 4b): after the vault
    ///      leaves, the ticks are cleared and the range's fees could no longer be read at settlement.
    function _markExit(PoolId id, Snapshot memory snap) internal {
        uint256 n = _records[id].length;
        if (n == 0 || snap.oldRange.liquidity == 0) return;
        RebalanceRecord storage last = _records[id][n - 1];
        if (
            last.settled || last.newRange.liquidity == 0 || last.newRange.tickLower != snap.oldRange.tickLower
                || last.newRange.tickUpper != snap.oldRange.tickUpper
        ) return;
        FeeSnap storage f = _feeSnaps[id][n - 1];
        f.exited = true;
        (f.exitGlobal0, f.exitGlobal1) = (snap.global0, snap.global1);
        (f.exitNew0, f.exitNew1) = (snap.fgOld0, snap.fgOld1);
    }

    /// @dev Vault token balances + fees owed on `r` (exactly what v4 would pay on the next modify of that position).
    ///      Why: removing a position collects its fees into idle. If H_before excluded them, a rebalance could leak
    ///      up to the accrued fees without any leakage being measured.
    function _idleWithFees(PoolId id, PoolConfig storage c, Range memory r) internal view returns (Holdings memory h) {
        h = FeesOwed.owed(poolManager, id, c.vault, r);
        h.amount0 += c.currency0.balanceOf(c.vault);
        h.amount1 += c.currency1.balanceOf(c.vault);
    }

    /// @dev Results of scoring one rebalance (memory struct keeps the stack shallow).
    struct Score {
        int256 leak;
        uint256 navBefore;
        uint256 lossW;
        uint256 movedW;
        uint256 recordId;
    }

    function _closeRebalance(PoolId id) internal returns (uint256) {
        PoolConfig storage c = configs[id];
        Snapshot memory snap = _pending[id];
        Range memory newR = _resolveNewRange(id, c.vault, snap.oldRange);
        Holdings memory idleNew = _idleWithFees(id, c, newR);
        (uint160 spotAfter,,,) = poolManager.getSlot0(id);

        if (
            newR.liquidity == 0 || newR.tickLower != snap.oldRange.tickLower
                || newR.tickUpper != snap.oldRange.tickUpper
        ) _markExit(id, snap);
        Score memory sc = _score(id, snap, newR, idleNew, spotAfter);

        _currentRange[id] = Range(newR.tickLower, newR.tickUpper, 0);
        lastRebalanceBlock[id] = block.number;
        _clearNewRange(id);
        _setSession(id, SESSION_NONE);
        emit RangeUpdated(id, newR.tickLower, newR.tickUpper, newR.liquidity);
        emit SessionClosed(id, SESSION_REBALANCE);
        return sc.recordId;
    }

    /// @dev Immediate leakage (tenure-math section 3) -> mandate -> charge budget -> store record.
    function _score(PoolId id, Snapshot memory snap, Range memory newR, Holdings memory idleNew, uint160 spotAfter)
        internal
        returns (Score memory sc)
    {
        (sc.leak, sc.navBefore, sc.movedW) =
            TenureScorer.scoreRebalance(snap.oldRange, snap.idle, snap.spot, newR, idleNew, spotAfter, snap.fair);
        BudgetState memory b = _refilled(id);
        Tier before = b.tier;
        _checkMandate(id, b.tier, snap.fair, newR, sc.movedW);
        if (sc.navBefore != 0) {
            (b, sc.lossW) = TenureScorer.chargeLeak(b, _settings[id].budget, sc.leak, sc.navBefore);
            sc.recordId = _records[id].length;
            _records[id].push(
                RebalanceRecord(snap.oldRange, newR, snap.idle, idleNew, sc.navBefore, uint64(block.number), false)
            );
            _snapFees(id, sc.recordId, snap, newR);
        } else {
            sc.recordId = type(uint256).max; // empty vault: nothing at stake, nothing to mark out
        }
        _storeBudget(id, b, before);
        emit RebalanceScored(id, sc.recordId, sc.leak, sc.navBefore, sc.lossW, sc.movedW, b.budget, b.tier);
    }

    function _snapFees(PoolId id, uint256 recordId, Snapshot memory snap, Range memory newR) internal {
        FeeSnap storage f = _feeSnaps[id][recordId];
        (f.global0, f.global1) = poolManager.getFeeGrowthGlobals(id);
        (f.old0, f.old1) = (snap.fgOld0, snap.fgOld1);
        if (newR.liquidity != 0) (f.new0, f.new1) = poolManager.getFeeGrowthInside(id, newR.tickLower, newR.tickUpper);
    }

    /// @dev New range = the one range added to in this session, else the old ticks. Old liquidity must be fully
    ///      removed when the range changed, or it would sit untracked.
    function _resolveNewRange(PoolId id, address vault, Range memory oldR) internal view returns (Range memory) {
        (bool set, int24 tl, int24 tu) = _newRange(id);
        if (!set) (tl, tu) = (oldR.tickLower, oldR.tickUpper);
        if (
            (tl != oldR.tickLower || tu != oldR.tickUpper)
                && _liquidityAt(id, vault, oldR.tickLower, oldR.tickUpper) != 0
        ) {
            revert Tenure__OrphanedLiquidity();
        }
        return Range(tl, tu, _liquidityAt(id, vault, tl, tu));
    }

    /// @dev Mandate rules (tier-dependent). `movedW` (from TenureScorer.scoreRebalance) = value converted between
    ///      tokens as WAD of NAV_before; re-ranging without a swap converts nothing, so it is never "moved".
    function _checkMandate(PoolId id, Tier tier, uint160 fair, Range memory newR, uint256 movedW) internal view {
        Mandate memory m = _settings[id].mandate;
        bool restricted = tier == Tier.RESTRICTED;
        if (newR.liquidity != 0) {
            uint256 width = uint256(int256(newR.tickUpper) - int256(newR.tickLower));
            uint256 minW = restricted ? uint256(m.minWidth) * 2 : m.minWidth;
            if (width < minW) revert Tenure__RangeTooNarrow(width, minW);
            if (width > m.maxWidth) revert Tenure__RangeTooWide(width, m.maxWidth);
            int256 center = (int256(newR.tickLower) + int256(newR.tickUpper)) / 2;
            int256 fairTick = int256(TenureScorer.tickAt(fair));
            uint256 dist = uint256(center > fairTick ? center - fairTick : fairTick - center);
            if (dist > m.maxCenterDist) revert Tenure__RangeOffFair(dist, m.maxCenterDist);
        }
        uint256 maxW = restricted ? uint256(m.maxMoveWad) / 2 : m.maxMoveWad;
        if (movedW > maxW) revert Tenure__MovedTooMuch(movedW, maxW);
    }

    function _refilled(PoolId id) internal returns (BudgetState memory b) {
        b = _budget[id];
        Tier before = b.tier;
        RiskBudget.refill(b, _settings[id].budget, block.number);
        _storeBudget(id, b, before);
    }

    function _storeBudget(PoolId id, BudgetState memory b, Tier before) internal {
        _budget[id] = b;
        if (b.tier != before) emit TierChanged(id, before, b.tier);
    }

    function _validateMandate(Mandate memory m) internal pure {
        if (m.minWidth == 0 || m.minWidth > m.maxWidth || m.maxMoveWad > 1e18) revert Tenure__InvalidMandate();
    }

    function _liquidityAt(PoolId id, address vault, int24 tl, int24 tu) internal view returns (uint128) {
        if (tl == tu) return 0; // never set
        return poolManager.getPositionLiquidity(id, Position.calculatePositionKey(vault, tl, tu, bytes32(0)));
    }

    function _requireCurrentRange(PoolId id, int24 tl, int24 tu) internal view {
        Range storage r = _currentRange[id];
        if (r.tickLower != tl || r.tickUpper != tu) revert Tenure__NotCurrentRange();
    }

    /// @dev MVP: one position per vault, so a rebalance may add to exactly one range.
    function _recordNewRange(PoolId id, int24 tl, int24 tu) internal {
        (bool set, int24 ptl, int24 ptu) = _newRange(id);
        if (set && (ptl != tl || ptu != tu)) revert Tenure__MultipleRanges();
        uint256 packed = (uint256(1) << 48) | (uint256(uint24(tl)) << 24) | uint256(uint24(tu));
        bytes32 slot = _slot(NEWRANGE_SLOT, id);
        assembly ("memory-safe") {
            tstore(slot, packed)
        }
    }

    function _newRange(PoolId id) internal view returns (bool set, int24 tl, int24 tu) {
        bytes32 slot = _slot(NEWRANGE_SLOT, id);
        uint256 packed;
        assembly ("memory-safe") {
            packed := tload(slot)
        }
        set = packed >> 48 != 0;
        tl = int24(uint24(packed >> 24));
        tu = int24(uint24(packed));
    }

    function _clearNewRange(PoolId id) internal {
        bytes32 slot = _slot(NEWRANGE_SLOT, id);
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    function _session(PoolId id) internal view returns (uint256 kind) {
        bytes32 slot = _slot(SESSION_SLOT, id);
        assembly ("memory-safe") {
            kind := tload(slot)
        }
    }

    function _setSession(PoolId id, uint256 kind) internal {
        bytes32 slot = _slot(SESSION_SLOT, id);
        assembly ("memory-safe") {
            tstore(slot, kind)
        }
    }

    function _slot(bytes32 base, PoolId id) internal pure returns (bytes32) {
        return keccak256(abi.encode(base, id));
    }
}
