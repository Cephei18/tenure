// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";

import {TenureHook, PoolSettings, Mandate} from "../src/TenureHook.sol";
import {CuratedVault} from "../src/CuratedVault.sol";
import {MockReferencePrice} from "../src/mocks/MockReferencePrice.sol";
import {TenureDefaults} from "../test/utils/TenureDefaults.sol";
import {TestSwapper} from "../test/utils/TestActors.sol";
import {Market, PoisonedCurator, Attacker} from "../test/scenario/ScenarioActors.sol";
import {TenureHookDeployer} from "./base/TenureHookDeployer.sol";
import {DemoLiquidity, DemoDirector} from "./demo/DemoActors.sol";

/// @notice Local demo, part 1: deploys the whole scenario-C world on anvil (LOCAL ONLY, test keys only).
///         PoolManager, two mock tokens, TenureHook (+ linked TenureScorer), mock fair-price oracle, a 1:1 pool with
///         deep third-party liquidity, a CuratedVault with a 40k/40k deposit, and the scenario actors from
///         test/scenario (seeded Market, PoisonedCurator, Attacker) plus a DemoDirector that replays one block per
///         transaction. Same parameters as test/scenario/Headline.t.sol, except the poison comes earlier.
///         Part 2 (script/demo.sh) sends the ticks and prints the log. See docs/DEMO.md.
/// @dev Run with FOUNDRY_PROFILE=deploy (the default profile's hook is over the EIP-170 size limit).
contract Demo is TenureHookDeployer {
    uint256 constant SEED = 0x7e2a; // same market seed as the headline test
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 constant SPACING = 60;
    uint128 constant THIRD_PARTY_LIQUIDITY = 2e23; // HeadlineBase._thirdPartyLiquidity
    uint256 constant DEPOSIT = 40_000 ether; // of each token

    // Deployed contracts live in storage: keeps run() under the legacy (non-IR) stack limit.
    IPoolManager pm;
    Currency c0;
    Currency c1;
    TenureHook hook;
    PoolKey key;
    MockReferencePrice oracle;
    CuratedVault vault;

    function run() external returns (DemoDirector director) {
        require(block.chainid == 31337, "local demo only");
        uint256 poisonAt = vm.envOr("POISON_AT", uint256(20));
        vm.startBroadcast();
        _deployPool(msg.sender);
        _deployVault(msg.sender);
        director = _deployActors(poisonAt);
        vm.stopBroadcast();

        console2.log("PoolManager  :", address(pm));
        console2.log("TenureHook   :", address(hook));
        console2.log("CuratedVault :", address(vault));
        console2.log("Curator      :", vault.curator());
        console2.log("DemoDirector :", address(director));
        console2.log("poison at tick", poisonAt);
    }

    /// @dev PoolManager, tokens, hook (+ linked TenureScorer), oracle, 1:1 pool, deep third-party liquidity.
    function _deployPool(address me) internal {
        pm = IPoolManager(V4PoolManagerDeployer.deploy(me));
        (c0, c1) = _tokens();
        hook = _deployHook(pm, me, me, 2 days, 100);
        key = PoolKey(c0, c1, 3000, SPACING, IHooks(address(hook)));
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        oracle = new MockReferencePrice();
        oracle.setPrice(id, SQRT_PRICE_1_1);
        pm.initialize(key, SQRT_PRICE_1_1);
        DemoLiquidity lp = new DemoLiquidity(pm);
        _mint(address(lp), 1e30);
        lp.add(key, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), THIRD_PARTY_LIQUIDITY);
    }

    /// @dev CuratedVault registered with the hook, and the depositor's 40k + 40k deposit.
    function _deployVault(address me) internal {
        vault = new CuratedVault(pm, hook, key, me, me, 50, "Tenure Demo Vault", "tnDEMO");
        hook.registerPool(key, address(vault), oracle, _settings());
        _mint(me, DEPOSIT);
        MockERC20(Currency.unwrap(c0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(vault), type(uint256).max);
        vault.deposit(DEPOSIT, DEPOSIT, 0, me);
    }

    /// @dev Scenario actors from test/scenario, the first honest placement, and the director (vault owner).
    function _deployActors(uint256 poisonAt) internal returns (DemoDirector director) {
        TestSwapper marketSwapper = new TestSwapper(pm);
        _mint(address(marketSwapper), 1e29);
        Market market = new Market(pm, oracle, marketSwapper, key, SEED, 20, 2_000 ether);
        TestSwapper atkSwapper = new TestSwapper(pm);
        _mint(address(atkSwapper), 10_000_000 ether);
        Attacker attacker = new Attacker(pm, oracle, atkSwapper, key);
        PoisonedCurator curator = new PoisonedCurator(vault, oracle, 600, 120, 30, 1500);
        vault.setCurator(address(curator));
        curator.act(); // first (honest) placement around the fair price
        director = new DemoDirector(vault, market, curator, attacker, oracle, poisonAt);
        vault.transferOwnership(address(director)); // the director enters safe mode once FROZEN
    }

    /// @dev Headline settings: VaultFixture mandate, default budget (2% of NAV, ~1 day refill), W = 50 blocks.
    function _settings() internal pure returns (PoolSettings memory) {
        return PoolSettings({
            maxOracleAge: 1 hours,
            window: 50,
            maxSettleDev: 100,
            mandate: Mandate({minWidth: 120, maxWidth: 12_000, maxCenterDist: 3000, maxMoveWad: 0.2e18, cooldown: 10}),
            budget: TenureDefaults.budgetParams()
        });
    }

    function _tokens() internal returns (Currency, Currency) {
        address a = address(new MockERC20("Tenure Demo A", "TDA", 18));
        address b = address(new MockERC20("Tenure Demo B", "TDB", 18));
        return a < b ? (Currency.wrap(a), Currency.wrap(b)) : (Currency.wrap(b), Currency.wrap(a));
    }

    function _mint(address to, uint256 amount) internal {
        MockERC20(Currency.unwrap(c0)).mint(to, amount);
        MockERC20(Currency.unwrap(c1)).mint(to, amount);
    }
}
