// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {TenureHook} from "../../src/TenureHook.sol";
import {CuratedVault} from "../../src/CuratedVault.sol";
import {Range} from "../../src/libraries/PositionValue.sol";
import {Tier, BudgetState} from "../../src/libraries/RiskBudget.sol";
import {MockReferencePrice} from "../../src/mocks/MockReferencePrice.sol";
import {DeltaSettler} from "../../test/utils/TestActors.sol";
import {Market, PoisonedCurator, Attacker, ScenarioMath} from "../../test/scenario/ScenarioActors.sol";

/// @notice Third-party LP for the demo pool: adds full-range liquidity from its own token balance. Not the vault,
///         so TenureHook lets it through untouched (only the registered vault is gated).
contract DemoLiquidity is IUnlockCallback {
    using DeltaSettler for IPoolManager;

    IPoolManager public immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function add(PoolKey memory key, int24 tl, int24 tu, uint128 liquidity) external {
        pm.unlock(abi.encode(key, tl, tu, liquidity));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (PoolKey memory key, int24 tl, int24 tu, uint128 liquidity) = abi.decode(data, (PoolKey, int24, int24, uint128));
        (BalanceDelta d,) = pm.modifyLiquidity(key, ModifyLiquidityParams(tl, tu, int256(uint256(liquidity)), 0), "");
        pm.settleAll(key, d, address(this));
        return "";
    }
}

/// @notice Drives scenario C (poisoned curator + Tenure) on a live chain, ONE scenario block per `tick()`
///         transaction. On anvil every transaction mines its own block, so cooldowns and the markout window are
///         measured in real blocks exactly as in test/scenario/Headline.t.sol (whose per-block loop body this
///         mirrors). Owns the vault (only to enter safe mode once FROZEN, as the vault owner does in the test).
contract DemoDirector {
    using Strings for uint256;

    TenureHook public immutable hook;
    CuratedVault public immutable vault;
    Market public immutable market;
    PoisonedCurator public immutable curator;
    Attacker public immutable attacker;
    MockReferencePrice public immutable oracle;
    PoolId public immutable id;
    uint256 public immutable poisonAt;
    int24 public constant PUSH = -400; // attacker pushes spot 400 ticks below fair

    uint256 public ticks;
    uint256 public rounds;
    uint256 public attackerProfit; // token1 wei at the fair price, summed per round
    uint256 public restrictedAt;
    uint256 public frozenAt;
    uint256 public startNav;
    Tier public lastTier;
    string public note; // what happened in the last tick (empty = routine block)

    event Tick(uint256 indexed tick, Tier tier, uint256 budgetPct10, uint256 nav, string note);

    constructor(
        CuratedVault _vault,
        Market _market,
        PoisonedCurator _curator,
        Attacker _attacker,
        MockReferencePrice _oracle,
        uint256 _poisonAt
    ) {
        vault = _vault;
        hook = _vault.hook();
        market = _market;
        curator = _curator;
        attacker = _attacker;
        oracle = _oracle;
        id = _vault.poolId();
        poisonAt = _poisonAt;
        (startNav,) = _vault.nav(false);
    }

    /// @notice Advance the scenario by one block: market step, then the curator's (and attacker's) turn.
    function tick() external {
        uint256 i = ++ticks;
        note = "";
        market.step();
        if (i == poisonAt) {
            curator.poison();
            note = "CURATOR POISONED (its context is corrupted; every action it takes stays inside the mandate)";
        }
        if (i >= poisonAt) _attackStep(i);
        else if (curator.act()) note = "honest re-center on the fair price";

        Tier t = hook.tierOf(id);
        if (t != lastTier) {
            note = string.concat(note, bytes(note).length == 0 ? "" : " | ", "TIER -> ", _tierName(t));
            if (t == Tier.RESTRICTED && restrictedAt == 0) restrictedAt = i;
            lastTier = t;
        }
        (uint256 nav,) = vault.nav(false);
        emit Tick(i, t, _budgetPct10(), nav, note);
    }

    /// @dev Mirrors HeadlineBase._attackStep.
    function _attackStep(uint256 i) internal {
        if (hook.tierOf(id) == Tier.FROZEN) {
            if (frozenAt == 0) {
                frozenAt = i;
                uint128 removed = vault.enterSafeMode();
                note = string.concat(
                    "FROZEN: curator locked out; safe mode pulled ", uint256(removed).toString(), " liquidity to idle"
                );
            }
            return;
        }
        Range memory pos = hook.currentRange(id);
        int24 center = (pos.tickLower + pos.tickUpper) / 2;
        bool parked = pos.liquidity != 0 && ScenarioMath.absDiff(center, ScenarioMath.fairTick(oracle, id)) > 600;
        if (parked) {
            if (!_curatorCanAct()) return;
            uint256 v0 = attacker.valueAtFair(address(attacker.swapper()));
            attacker.push(PUSH);
            bool followed = curator.act();
            attacker.arbBack();
            uint256 v1 = attacker.valueAtFair(address(attacker.swapper()));
            uint256 gain = v1 > v0 ? v1 - v0 : 0;
            attackerProfit += gain;
            if (followed) {
                ++rounds;
                note = string.concat(
                    "ATTACK round ",
                    rounds.toString(),
                    ": push spot -400 ticks, curator follows, arb back; attacker +",
                    (gain / 1e18).toString(),
                    " tokens"
                );
            } else {
                note = "attack attempt: curator refused to follow (mandate/tier)";
            }
        } else if (curator.act()) {
            note = "poisoned curator parks its range 1,500 ticks away from the price";
        }
    }

    function _curatorCanAct() internal view returns (bool) {
        uint256 cd = hook.settingsOf(id).mandate.cooldown;
        if (hook.tierOf(id) == Tier.RESTRICTED) cd *= 2;
        return block.number >= hook.lastRebalanceBlock(id) + cd;
    }

    /// @notice One readable status line for the demo log.
    function status() external view returns (string memory) {
        (uint256 nav,) = vault.nav(false);
        uint256 b = _budgetPct10();
        string memory delta = nav >= startNav
            ? string.concat("+", ((nav - startNav) / 1e18).toString())
            : string.concat("-", ((startNav - nav) / 1e18).toString());
        return string.concat(
            "tick ",
            ticks.toString(),
            " | blk ",
            block.number.toString(),
            " | tier ",
            _tierName(hook.tierOf(id)),
            " | budget ",
            (b / 10).toString(),
            ".",
            (b % 10).toString(),
            "% | NAV ",
            (nav / 1e18).toString(),
            " (",
            delta,
            ") | rounds ",
            rounds.toString(),
            " | attacker +",
            (attackerProfit / 1e18).toString(),
            " | records ",
            hook.recordCount(id).toString()
        );
    }

    function _budgetPct10() internal view returns (uint256) {
        BudgetState memory b = hook.budgetOf(id);
        return b.budget * 1000 / b.bMax;
    }

    function _tierName(Tier t) internal pure returns (string memory) {
        return t == Tier.FULL ? "FULL" : t == Tier.RESTRICTED ? "RESTRICTED" : "FROZEN";
    }
}
