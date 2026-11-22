// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {TenureHook} from "./TenureHook.sol";
import {IReferencePrice} from "./interfaces/IReferencePrice.sol";
import {ReferencePriceLib} from "./libraries/ReferencePriceLib.sol";
import {PositionValue, Holdings, Range} from "./libraries/PositionValue.sol";
import {FeesOwed} from "./libraries/FeesOwed.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title CuratedVault - a two-token vault whose single LP position is managed by an untrusted curator
/// @notice Depositors hold shares priced at NAV at the FAIR price (never pool spot). The curator can only touch the
///         position through `rebalance`, which the TenureHook measures and scores. Withdrawals are pro-rata in kind
///         and ALWAYS open, in every tier including FROZEN, and need no price at all.
/// @dev Trusted code; the curator is not. One curated position per pool (MVP). ERC20 tokens only (no native ETH).
contract CuratedVault is ERC20, ReentrancyGuard, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    // ------------------------------------------------------------------------------------------------ errors
    error Tenure__NotCurator();
    error Tenure__NotOwner();
    error Tenure__NotSafeModeCaller();
    error Tenure__NotPoolManager();
    error Tenure__ZeroAddress();
    error Tenure__NativeNotSupported();
    error Tenure__WrongHook();
    error Tenure__ZeroAmount();
    error Tenure__ZeroShares();
    error Tenure__Slippage(uint256 got, uint256 min);
    error Tenure__SpotDeviation(uint256 dev, uint256 maxDev);
    error Tenure__DepositCapExceeded(uint256 navAfter, uint256 cap);
    error Tenure__InsufficientShares();
    error Tenure__NotFreezeReceiver();
    error Tenure__NotGuardian();
    error Tenure__RelayFrozen();

    // ------------------------------------------------------------------------------------------------ types
    /// @notice A curator decision. Removes ALL liquidity from the current range, optionally swaps, then adds
    ///         `liquidity` at [tickLower, tickUpper). `swapAmount > 0` sells token0 exact-in, `< 0` sells token1.
    struct RebalanceParams {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        int256 swapAmount;
        uint160 sqrtPriceLimitX96;
    }

    enum Action {
        REBALANCE,
        WITHDRAW,
        SAFE
    }

    // ------------------------------------------------------------------------------------------------ constants
    /// @notice Shares minted to a dead address on the first deposit. Makes the first-depositor donation
    ///         ("inflation") attack cost ~DEAD_SHARES/(DEAD_SHARES+1) of everything the attacker donates.
    uint256 public constant DEAD_SHARES = 1e6;
    address public constant DEAD = address(0xdEaD);

    // ------------------------------------------------------------------------------------------------ immutables
    IPoolManager public immutable poolManager;
    TenureHook public immutable hook;
    Currency public immutable currency0;
    Currency public immutable currency1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    PoolId public immutable poolId;
    /// @notice Deposits revert if |spot tick - fair tick| exceeds this (deposits at a manipulated spot).
    uint24 public immutable maxDepositDeviation;

    // ------------------------------------------------------------------------------------------------ state
    address public owner;
    address public curator;
    /// @notice Contract allowed to set `relayFrozen` (TenureFreezeReceiver; M4.5b). address(0) = none.
    address public freezeReceiver;
    /// @notice Set when the same curator was FROZEN on another chain (relayed). Blocks curator rebalances only.
    ///         Only the hook's guardian can clear it; deposits, withdrawals and safe mode are unaffected.
    bool public relayFrozen;

    // ------------------------------------------------------------------------------------------------ events
    event Deposit(address indexed sender, address indexed receiver, uint256 amount0, uint256 amount1, uint256 shares);
    event Withdraw(address indexed owner, address indexed receiver, uint256 shares, uint256 amount0, uint256 amount1);
    event Rebalanced(int24 tickLower, int24 tickUpper, uint128 liquidity, int256 swapAmount, uint256 recordId);
    event SafeMode(address indexed caller, uint128 liquidityRemoved);
    event CuratorChanged(address indexed previous, address indexed next);
    event OwnershipTransferred(address indexed previous, address indexed next);
    event FreezeReceiverSet(address indexed previous, address indexed next);
    event RelayedFreeze(uint256 indexed sourceChainId, bytes32 indexed sourcePoolId, bool wasFrozen);
    event RelayFreezeCleared(address indexed guardian);

    constructor(
        IPoolManager _poolManager,
        TenureHook _hook,
        PoolKey memory _key,
        address _owner,
        address _curator,
        uint24 _maxDepositDeviation,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        if (_owner == address(0) || _curator == address(0)) revert Tenure__ZeroAddress();
        if (_key.currency0.isAddressZero()) revert Tenure__NativeNotSupported();
        if (address(_key.hooks) != address(_hook)) revert Tenure__WrongHook();
        poolManager = _poolManager;
        hook = _hook;
        currency0 = _key.currency0;
        currency1 = _key.currency1;
        fee = _key.fee;
        tickSpacing = _key.tickSpacing;
        poolId = _key.toId();
        maxDepositDeviation = _maxDepositDeviation;
        owner = _owner;
        curator = _curator;
        emit OwnershipTransferred(address(0), _owner);
        emit CuratorChanged(address(0), _curator);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Tenure__NotOwner();
        _;
    }

    modifier onlyCurator() {
        if (msg.sender != curator) revert Tenure__NotCurator();
        _;
    }

    // ================================================================================================ admin
    /// @notice Replace the curator (e.g. a poisoned agent). Owner only.
    function setCurator(address next) external onlyOwner {
        if (next == address(0)) revert Tenure__ZeroAddress();
        emit CuratorChanged(curator, next);
        curator = next;
    }

    /// @notice Choose the contract that may relay a FROZEN tier from another chain (M4.5b). It can only ever
    ///         freeze: clearing stays with the local guardian. address(0) disables relayed freezes.
    function setFreezeReceiver(address next) external onlyOwner {
        emit FreezeReceiverSet(freezeReceiver, next);
        freezeReceiver = next;
    }

    /// @notice Relay entry point: the curator of this vault was FROZEN elsewhere, so block its rebalances here too.
    /// @dev SAFETY INVARIANT: the relay path can only set the flag. Idempotent: a duplicate or replayed relay is a
    ///      no-op beyond the event.
    function relayFreeze(uint256 sourceChainId, bytes32 sourcePoolId) external {
        if (msg.sender != freezeReceiver) revert Tenure__NotFreezeReceiver(); // never address(0): unset = disabled
        emit RelayedFreeze(sourceChainId, sourcePoolId, relayFrozen);
        relayFrozen = true;
    }

    /// @notice Lift a relayed freeze. Only the hook's guardian (the same party that restores a FROZEN tier).
    function clearRelayFreeze() external {
        if (msg.sender != hook.guardian()) revert Tenure__NotGuardian();
        relayFrozen = false;
        emit RelayFreezeCleared(msg.sender);
    }

    /// @notice Transfer vault ownership.
    function transferOwnership(address next) external onlyOwner {
        if (next == address(0)) revert Tenure__ZeroAddress();
        emit OwnershipTransferred(owner, next);
        owner = next;
    }

    // ================================================================================================ views
    /// @notice The pool key this vault curates.
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(currency0, currency1, fee, tickSpacing, hook);
    }

    /// @notice Total holdings in kind: the position's amounts at current spot (rounded down), idle balances, and the
    ///         position's uncollected fees (which belong to shareholders and are collected on the next modify).
    function totalHoldings() public view returns (Holdings memory) {
        return _holdings(false);
    }

    /// @notice NAV in token1 units at the FAIR price. `roundUp` selects the rounding direction of both the position
    ///         amounts and the valuation, so callers can always round against whoever is being priced.
    function nav(bool roundUp) public view returns (uint256 value, uint160 fair) {
        fair = _fair();
        value = PositionValue.navAt(_holdings(roundUp), fair, roundUp);
    }

    function _holdings(bool roundUp) internal view returns (Holdings memory) {
        Range memory r = hook.currentRange(poolId);
        Holdings memory owed = FeesOwed.owed(poolManager, poolId, address(this), r);
        return PositionValue.holdings(
            r,
            currency0.balanceOf(address(this)) + owed.amount0,
            currency1.balanceOf(address(this)) + owed.amount1,
            _spot(),
            roundUp
        );
    }

    /// @notice Uncollected LP fees owed to the vault on its current position (part of NAV).
    function feesOwed() external view returns (Holdings memory) {
        return FeesOwed.owed(poolManager, poolId, address(this), hook.currentRange(poolId));
    }

    /// @notice |spot tick - fair tick| using a fresh fair price (the deposit guard).
    function spotFairDeviation() public view returns (uint256) {
        int256 s = TickMath.getTickAtSqrtPrice(_spot());
        int256 f = TickMath.getTickAtSqrtPrice(_fair());
        return uint256(s > f ? s - f : f - s);
    }

    /// @notice Value of a deposit at the fair price (rounded down), in token1 units.
    function depositValue(uint256 amount0, uint256 amount1) public view returns (uint256) {
        return PositionValue.navAt(Holdings(amount0, amount1), _fair(), false);
    }

    /// @notice Shares a deposit would mint right now (0 if it would revert for value reasons).
    function previewDeposit(uint256 amount0, uint256 amount1) public view returns (uint256) {
        uint256 value = depositValue(amount0, amount1);
        uint256 supply = totalSupply();
        if (supply == 0) return value > DEAD_SHARES ? value - DEAD_SHARES : 0;
        (uint256 navBefore,) = nav(true);
        return FullMath.mulDiv(value, supply, navBefore);
    }

    // ================================================================================================ depositors
    /// @notice Deposit tokens (any mix) for shares priced at NAV at the fair price. Deposited tokens stay idle until
    ///         the curator's next measured rebalance.
    /// @dev Rounds against the depositor: deposit value down, existing NAV up. Reverts if pool spot deviates from
    ///      fair (a manipulated spot would misvalue the position), or if NAV would exceed the hook's deposit cap,
    ///      which grows only with the curator's proven alpha.
    /// @param minShares Slippage guard.
    function deposit(uint256 amount0, uint256 amount1, uint256 minShares, address receiver)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (receiver == address(0)) revert Tenure__ZeroAddress();
        if (amount0 == 0 && amount1 == 0) revert Tenure__ZeroAmount();
        uint256 dev = spotFairDeviation();
        if (dev > maxDepositDeviation) revert Tenure__SpotDeviation(dev, maxDepositDeviation);

        (uint256 navBefore, uint160 fair) = nav(true);
        uint256 value = PositionValue.navAt(Holdings(amount0, amount1), fair, false);
        uint256 cap = hook.depositCap(poolId);
        if (navBefore + value > cap) revert Tenure__DepositCapExceeded(navBefore + value, cap);

        uint256 supply = totalSupply();
        if (supply == 0) {
            // First deposit: shares are 1:1 with token1-value; DEAD_SHARES are burned to a dead address forever.
            if (value <= DEAD_SHARES) revert Tenure__ZeroShares();
            shares = value - DEAD_SHARES;
            _mint(DEAD, DEAD_SHARES);
        } else {
            // navBefore > 0 here unless everything was lost; then mulDiv reverts (no free shares out of nothing).
            shares = FullMath.mulDiv(value, supply, navBefore);
        }
        if (shares == 0) revert Tenure__ZeroShares();
        if (shares < minShares) revert Tenure__Slippage(shares, minShares);

        if (amount0 != 0) {
            IERC20(Currency.unwrap(currency0)).safeTransferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 != 0) {
            IERC20(Currency.unwrap(currency1)).safeTransferFrom(msg.sender, address(this), amount1);
        }
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, amount0, amount1, shares);
    }

    /// @notice Burn `shares` for a pro-rata slice of everything the vault holds, in kind.
    /// @dev ALWAYS open: no tier check, no oracle read, no price at all, so a frozen curator, a stale oracle or a
    ///      manipulated spot can never trap depositors. Removes floor(L * shares / supply) from the position inside
    ///      a hook pro-rata session; fees collected by that removal are shared pro-rata like idle balances.
    /// @param min0 Slippage guard on token0 out.
    /// @param min1 Slippage guard on token1 out.
    function withdraw(uint256 shares, uint256 min0, uint256 min1, address receiver)
        external
        nonReentrant
        returns (uint256 out0, uint256 out1)
    {
        if (receiver == address(0)) revert Tenure__ZeroAddress();
        if (shares == 0) revert Tenure__ZeroAmount();
        if (shares > balanceOf(msg.sender)) revert Tenure__InsufficientShares();
        uint256 supply = totalSupply();

        Range memory r = hook.currentRange(poolId);
        uint128 lRemove = uint128(FullMath.mulDiv(r.liquidity, shares, supply));
        uint256 principal0;
        uint256 principal1;
        if (lRemove != 0) {
            PoolKey memory key = poolKey();
            hook.beginProRata(key);
            (principal0, principal1) = abi.decode(
                poolManager.unlock(abi.encode(Action.WITHDRAW, abi.encode(r.tickLower, r.tickUpper, lRemove))),
                (uint256, uint256)
            );
            hook.endProRata(key);
        }
        // Idle now includes the removed principal and any fees the removal collected; the withdrawer gets all of
        // their principal plus a floor pro-rata share of the rest (idle + fees).
        out0 = principal0 + FullMath.mulDiv(currency0.balanceOf(address(this)) - principal0, shares, supply);
        out1 = principal1 + FullMath.mulDiv(currency1.balanceOf(address(this)) - principal1, shares, supply);
        if (out0 < min0) revert Tenure__Slippage(out0, min0);
        if (out1 < min1) revert Tenure__Slippage(out1, min1);

        _burn(msg.sender, shares);
        if (out0 != 0) IERC20(Currency.unwrap(currency0)).safeTransfer(receiver, out0);
        if (out1 != 0) IERC20(Currency.unwrap(currency1)).safeTransfer(receiver, out1);
        emit Withdraw(msg.sender, receiver, shares, out0, out1);
    }

    // ================================================================================================ curator
    /// @notice A measured curator decision: hook.beginRebalance -> unlock(remove old, swap, add new) ->
    ///         hook.endRebalance. The hook snapshots holdings before/after, enforces mandate + tier, and scores it.
    /// @return recordId The hook's RebalanceRecord id for markout settlement.
    function rebalance(RebalanceParams calldata p) external onlyCurator nonReentrant returns (uint256 recordId) {
        if (relayFrozen) revert Tenure__RelayFrozen();
        PoolKey memory key = poolKey();
        hook.beginRebalance(key);
        poolManager.unlock(abi.encode(Action.REBALANCE, abi.encode(p)));
        recordId = hook.endRebalance(key);
        emit Rebalanced(p.tickLower, p.tickUpper, p.liquidity, p.swapAmount, recordId);
    }

    /// @notice Pull all liquidity to idle. Allowed in every tier (de-risking is always permitted). Callable by the
    ///         curator (e.g. when FROZEN) or the owner (e.g. an emergency while replacing a poisoned curator).
    function enterSafeMode() external nonReentrant returns (uint128 removed) {
        if (msg.sender != curator && msg.sender != owner) revert Tenure__NotSafeModeCaller();
        PoolKey memory key = poolKey();
        Range memory r = hook.currentRange(poolId);
        removed = r.liquidity;
        hook.beginSafeMode(key);
        if (removed != 0) {
            poolManager.unlock(abi.encode(Action.SAFE, abi.encode(r.tickLower, r.tickUpper, removed)));
        }
        hook.endSafeMode(key, removed);
        emit SafeMode(msg.sender, removed);
    }

    // ================================================================================================ unlock
    /// @inheritdoc IUnlockCallback
    /// @dev Only the PoolManager can call, and it only calls back the contract that called unlock (this vault).
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Tenure__NotPoolManager();
        (Action action, bytes memory inner) = abi.decode(data, (Action, bytes));
        PoolKey memory key = poolKey();
        if (action == Action.REBALANCE) {
            _doRebalance(key, abi.decode(inner, (RebalanceParams)));
            return "";
        }
        (int24 tl, int24 tu, uint128 l) = abi.decode(inner, (int24, int24, uint128));
        (BalanceDelta callerDelta, BalanceDelta fees) = _modify(key, tl, tu, -int256(uint256(l)));
        // principal = callerDelta - fees (both positive on removal)
        BalanceDelta principal = callerDelta - fees;
        return abi.encode(uint256(uint128(principal.amount0())), uint256(uint128(principal.amount1())));
    }

    function _doRebalance(PoolKey memory key, RebalanceParams memory p) internal {
        Range memory old = hook.currentRange(poolId);
        if (old.liquidity != 0) _modify(key, old.tickLower, old.tickUpper, -int256(uint256(old.liquidity)));
        if (p.swapAmount != 0) {
            bool zeroForOne = p.swapAmount > 0;
            int256 amountIn = zeroForOne ? p.swapAmount : -p.swapAmount;
            BalanceDelta d = poolManager.swap(key, SwapParams(zeroForOne, -amountIn, p.sqrtPriceLimitX96), "");
            _settle(key, d);
        }
        if (p.liquidity != 0) _modify(key, p.tickLower, p.tickUpper, int256(uint256(p.liquidity)));
    }

    function _modify(PoolKey memory key, int24 tl, int24 tu, int256 delta)
        internal
        returns (BalanceDelta callerDelta, BalanceDelta fees)
    {
        (callerDelta, fees) = poolManager.modifyLiquidity(key, ModifyLiquidityParams(tl, tu, delta, bytes32(0)), "");
        _settle(key, callerDelta);
    }

    function _settle(PoolKey memory key, BalanceDelta d) internal {
        _settleOne(key.currency0, d.amount0());
        _settleOne(key.currency1, d.amount1());
    }

    function _settleOne(Currency c, int128 amt) internal {
        if (amt < 0) c.settle(poolManager, address(this), uint256(uint128(-amt)), false);
        else if (amt > 0) c.take(poolManager, address(this), uint256(uint128(amt)), false);
    }

    // ================================================================================================ internals
    function _spot() internal view returns (uint160 s) {
        (s,,,) = poolManager.getSlot0(poolId);
    }

    function _fair() internal view returns (uint160) {
        (, IReferencePrice oracle,,) = hook.configs(poolId);
        return ReferencePriceLib.readFresh(oracle, poolId, hook.settingsOf(poolId).maxOracleAge);
    }
}
