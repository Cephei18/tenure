// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
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

/// @title TenureHook - earned autonomy for liquidity curators
/// @notice Gates every liquidity change of a registered curated vault behind a MEASURED session, reading pool state
///         and the vault's position independently from the PoolManager. The curator (off-chain, untrusted) never
///         talks to this hook; the vault (trusted code) does.
contract TenureHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    // ------------------------------------------------------------------------------------------------ errors
    error Tenure__NotOwner();
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

    // ------------------------------------------------------------------------------------------------ types
    /// @dev Session kinds held in transient storage. REBALANCE is measured; PRORATA lets the vault scale its current
    ///      range for deposits/withdrawals (shape unchanged, nothing to score).
    uint256 internal constant SESSION_NONE = 0;
    uint256 internal constant SESSION_REBALANCE = 1;
    uint256 internal constant SESSION_PRORATA = 2;

    struct PoolConfig {
        address vault;
        IReferencePrice oracle;
        Currency currency0;
        Currency currency1;
        uint32 maxOracleAge; // seconds
    }

    /// @notice What the hook saw when the session opened (H_before inputs + fair price).
    struct Snapshot {
        Range oldRange;
        Holdings idle;
        uint160 spot;
        uint160 fair;
    }

    // ------------------------------------------------------------------------------------------------ storage
    /// @dev Transient slots: uint256(keccak256("tenure.session")) - 1 and ("tenure.newrange") - 1, then keyed by pool.
    bytes32 internal constant SESSION_SLOT = 0x4cf0626aa298570f9f11853ed284e3a77616d44640b681cd7282c06e4d6758b9;
    bytes32 internal constant NEWRANGE_SLOT = 0x91a39552ac870bd84550b1ff670fbd9576e38088668f0d566a8e0988b6a134b6;

    address public owner;
    mapping(PoolId => PoolConfig) public configs;
    /// @notice The vault's tracked position (ticks; liquidity is always re-read from the PoolManager).
    mapping(PoolId => Range) internal _currentRange;
    mapping(PoolId => Snapshot) internal _pending;

    // ------------------------------------------------------------------------------------------------ events
    event PoolRegistered(PoolId indexed poolId, address indexed vault, address oracle, uint32 maxOracleAge);
    event SessionOpened(PoolId indexed poolId, uint256 kind, uint160 spot, uint160 fair);
    event SessionClosed(PoolId indexed poolId, uint256 kind);
    event RangeUpdated(PoolId indexed poolId, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(IPoolManager _poolManager, address _owner) BaseHook(_poolManager) {
        if (_owner == address(0)) revert Tenure__ZeroAddress();
        owner = _owner;
        emit OwnershipTransferred(address(0), _owner);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Tenure__NotOwner();
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

    /// @notice Register the curated vault for a pool that uses this hook. MVP: owner-set, one vault per pool.
    /// @param key Pool key (must point at this hook).
    /// @param vault The CuratedVault contract whose liquidity is gated and measured.
    /// @param oracle Fair reference price source.
    /// @param maxOracleAge Max fair-price age in seconds.
    function registerPool(PoolKey calldata key, address vault, IReferencePrice oracle, uint32 maxOracleAge)
        external
        onlyOwner
    {
        if (address(key.hooks) != address(this)) revert Tenure__WrongHook();
        if (vault == address(0) || address(oracle) == address(0)) revert Tenure__ZeroAddress();
        PoolId id = key.toId();
        if (configs[id].vault != address(0)) revert Tenure__AlreadyRegistered();
        configs[id] = PoolConfig(vault, oracle, key.currency0, key.currency1, maxOracleAge);
        emit PoolRegistered(id, vault, address(oracle), maxOracleAge);
    }

    // ================================================================================================ sessions
    /// @notice Open a measured rebalance session. Snapshots H_before (vault position read from the PoolManager +
    ///         the vault's token balances) and the fair price. Called by the vault BEFORE poolManager.unlock, so no
    ///         flash-accounting deltas are outstanding.
    function beginRebalance(PoolKey calldata key) external onlyVault(key.toId()) {
        PoolId id = key.toId();
        if (_session(id) != SESSION_NONE) revert Tenure__SessionOpen();
        PoolConfig storage c = configs[id];
        uint160 fair = ReferencePriceLib.readFresh(c.oracle, id, c.maxOracleAge);
        (uint160 spot,,,) = poolManager.getSlot0(id);
        Range memory r = _currentRange[id];
        r.liquidity = _liquidityAt(id, c.vault, r.tickLower, r.tickUpper);
        _pending[id] = Snapshot(r, Holdings(c.currency0.balanceOf(c.vault), c.currency1.balanceOf(c.vault)), spot, fair);
        _setSession(id, SESSION_REBALANCE);
        emit SessionOpened(id, SESSION_REBALANCE, spot, fair);
    }

    /// @notice Close the measured session: read H_after independently and update the tracked range.
    /// @dev Called by the vault AFTER unlock returns (all deltas settled, balances final).
    function endRebalance(PoolKey calldata key) external onlyVault(key.toId()) {
        PoolId id = key.toId();
        if (_session(id) != SESSION_REBALANCE) revert Tenure__WrongSession();
        _closeRebalance(id);
    }

    /// @notice Open a pro-rata session (deposit/withdraw): the vault may scale its CURRENT range only.
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
            uint256 kind = _session(id);
            if (kind == SESSION_NONE) revert Tenure__NoSession();
            // Both kinds may only remove from the tracked (old) range.
            _requireCurrentRange(id, params.tickLower, params.tickUpper);
        }
        return this.beforeRemoveLiquidity.selector;
    }

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, int128)
    {
        return (this.afterSwap.selector, 0);
    }

    // ================================================================================================ internals
    function _closeRebalance(PoolId id) internal virtual {
        PoolConfig storage c = configs[id];
        Snapshot memory snap = _pending[id];
        (bool set, int24 tl, int24 tu) = _newRange(id);
        if (!set) (tl, tu) = (snap.oldRange.tickLower, snap.oldRange.tickUpper);
        Range memory newR = Range(tl, tu, _liquidityAt(id, c.vault, tl, tu));
        if (
            (tl != snap.oldRange.tickLower || tu != snap.oldRange.tickUpper)
                && _liquidityAt(id, c.vault, snap.oldRange.tickLower, snap.oldRange.tickUpper) != 0
        ) revert Tenure__OrphanedLiquidity();
        _currentRange[id] = Range(tl, tu, 0);
        _clearNewRange(id);
        _setSession(id, SESSION_NONE);
        emit RangeUpdated(id, tl, tu, newR.liquidity);
        emit SessionClosed(id, SESSION_REBALANCE);
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
