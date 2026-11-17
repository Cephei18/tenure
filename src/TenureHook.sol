// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IReferencePrice} from "./interfaces/IReferencePrice.sol";
import {ReferencePriceLib} from "./libraries/ReferencePriceLib.sol";
import {PositionValue, Holdings, Range} from "./libraries/PositionValue.sol";
import {DecisionScore} from "./libraries/DecisionScore.sol";
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
        Holdings idle;
        uint160 spot;
        uint160 fair;
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
        _setSession(id, SESSION_SAFE);
        emit SessionOpened(id, SESSION_SAFE, 0, 0);
    }

    /// @notice Close safe mode; reverts unless the vault's position is now empty.
    function endSafeMode(PoolKey calldata key, uint256 liquidityRemoved) external onlyVault(key.toId()) {
        PoolId id = key.toId();
        if (_session(id) != SESSION_SAFE) revert Tenure__WrongSession();
        Range memory r = _currentRange[id];
        if (_liquidityAt(id, configs[id].vault, r.tickLower, r.tickUpper) != 0) revert Tenure__SafeModeMustExit();
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
        uint256 dev = _tickDistance(spot, fair);
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

    /// @notice Vault NAV in token1 units at the FAIR price (position at spot, rounded down + idle balances).
    /// @dev Used by the vault to price shares. Never values at spot.
    function navOf(PoolId id) external view returns (uint256 nav, uint160 fair) {
        PoolConfig storage c = configs[id];
        fair = ReferencePriceLib.readFresh(c.oracle, id, _settings[id].maxOracleAge);
        (uint160 spot,,,) = poolManager.getSlot0(id);
        Holdings memory h = PositionValue.holdings(
            currentRange(id), c.currency0.balanceOf(c.vault), c.currency1.balanceOf(c.vault), spot, false
        );
        nav = PositionValue.navAt(h, fair, false);
    }

    /// @notice |spot tick - fair tick| for the pool, using a fresh fair price.
    function spotFairDeviation(PoolId id) external view returns (uint256) {
        uint160 fair = ReferencePriceLib.readFresh(configs[id].oracle, id, _settings[id].maxOracleAge);
        (uint160 spot,,,) = poolManager.getSlot0(id);
        return _tickDistance(spot, fair);
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
        if (_tickDistance(spot, fair) > s.maxSettleDev) return;

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
        alpha = DecisionScore.markoutAlpha(r.oldRange, r.idleOld, r.newRange, r.idleNew, spot, fair);
        BudgetState memory b = _refilled(id);
        Tier before = b.tier;
        BudgetParams memory p = _settings[id].budget;
        uint256 lossW;
        uint256 gainW;
        if (alpha < 0) {
            lossW = DecisionScore.lossWad(-alpha, r.navBefore);
            RiskBudget.charge(b, p, lossW, uint256(-alpha));
        } else {
            gainW = DecisionScore.gainWad(alpha, r.navBefore);
            RiskBudget.credit(b, p, gainW, uint256(alpha));
        }
        _storeBudget(id, b, before);
        emit MarkoutSettled(id, recordId, alpha, lossW, gainW, b.budget, b.bMax, b.tier);
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
        _pending[id] = Snapshot(r, Holdings(c.currency0.balanceOf(c.vault), c.currency1.balanceOf(c.vault)), spot, fair);
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
        Holdings memory idleNew = Holdings(c.currency0.balanceOf(c.vault), c.currency1.balanceOf(c.vault));
        (uint160 spotAfter,,,) = poolManager.getSlot0(id);

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
        (sc.leak, sc.navBefore) =
            DecisionScore.immediateLeakage(snap.oldRange, snap.idle, snap.spot, newR, idleNew, spotAfter, snap.fair);
        BudgetState memory b = _refilled(id);
        Tier before = b.tier;
        sc.movedW = _checkMandate(id, b.tier, snap, newR, idleNew, spotAfter, sc.navBefore);
        if (sc.navBefore != 0) {
            sc.lossW = DecisionScore.lossWad(sc.leak, sc.navBefore);
            if (sc.lossW != 0) RiskBudget.charge(b, _settings[id].budget, sc.lossW, uint256(sc.leak));
            sc.recordId = _records[id].length;
            _records[id].push(
                RebalanceRecord(snap.oldRange, newR, snap.idle, idleNew, sc.navBefore, uint64(block.number), false)
            );
        } else {
            sc.recordId = type(uint256).max; // empty vault: nothing at stake, nothing to mark out
        }
        _storeBudget(id, b, before);
        emit RebalanceScored(id, sc.recordId, sc.leak, sc.navBefore, sc.lossW, sc.movedW, b.budget, b.tier);
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

    /// @dev Mandate rules (tier-dependent). Returns the moved fraction for the event.
    ///      "Moved" = value converted between tokens = |change in total token0 holdings| at the fair price. Re-ranging
    ///      without a swap converts nothing (tokens just move between position and idle), so it is never "moved".
    function _checkMandate(
        PoolId id,
        Tier tier,
        Snapshot memory snap,
        Range memory newR,
        Holdings memory idleNew,
        uint160 spotAfter,
        uint256 navBefore
    ) internal view returns (uint256 movedW) {
        Mandate memory m = _settings[id].mandate;
        bool restricted = tier == Tier.RESTRICTED;
        if (newR.liquidity != 0) {
            uint256 width = uint256(int256(newR.tickUpper) - int256(newR.tickLower));
            uint256 minW = restricted ? uint256(m.minWidth) * 2 : m.minWidth;
            if (width < minW) revert Tenure__RangeTooNarrow(width, minW);
            if (width > m.maxWidth) revert Tenure__RangeTooWide(width, m.maxWidth);
            int256 center = (int256(newR.tickLower) + int256(newR.tickUpper)) / 2;
            int256 fairTick = int256(TickMath.getTickAtSqrtPrice(snap.fair));
            uint256 dist = uint256(center > fairTick ? center - fairTick : fairTick - center);
            if (dist > m.maxCenterDist) revert Tenure__RangeOffFair(dist, m.maxCenterDist);
        }
        if (navBefore == 0) return 0;
        Holdings memory hB = PositionValue.holdings(snap.oldRange, snap.idle.amount0, 0, snap.spot, true);
        Holdings memory hA = PositionValue.holdings(newR, idleNew.amount0, 0, spotAfter, false);
        uint256 d0 = hA.amount0 > hB.amount0 ? hA.amount0 - hB.amount0 : hB.amount0 - hA.amount0;
        uint256 movedValue = PositionValue.navAt(Holdings(d0, 0), snap.fair, true);
        movedW = FullMath.mulDivRoundingUp(movedValue, 1e18, navBefore);
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

    function _tickDistance(uint160 a, uint160 b) internal pure returns (uint256) {
        int256 ta = TickMath.getTickAtSqrtPrice(a);
        int256 tb = TickMath.getTickAtSqrtPrice(b);
        return uint256(ta > tb ? ta - tb : tb - ta);
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
