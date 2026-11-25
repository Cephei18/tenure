// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";

import {TenureHook, PoolSettings, Mandate} from "../src/TenureHook.sol";
import {CuratedVault} from "../src/CuratedVault.sol";
import {MockReferencePrice} from "../src/mocks/MockReferencePrice.sol";
import {ChainlinkReferencePrice} from "../src/ChainlinkReferencePrice.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {TenureReactiveReceiver, ITenureSettle} from "../src/reactive/TenureReactiveReceiver.sol";
import {TenureFreezeReceiver} from "../src/reactive/TenureFreezeReceiver.sol";
import {TenureDefaults} from "../test/utils/TenureDefaults.sol";
import {TestSwapper} from "../test/utils/TestActors.sol";
import {MockAggregator} from "../test/utils/MockAggregator.sol";
import {Market, PoisonedCurator, Attacker} from "../test/scenario/ScenarioActors.sol";
import {TenureHookDeployer} from "./base/TenureHookDeployer.sol";
import {DemoLiquidity, DemoDirector} from "./demo/DemoActors.sol";

/// @notice M7.1: the whole Unichain Sepolia (1301) deployment, every input read from deployments/config.json.
///         - TenureScorer (external library, deployed + linked by forge) and TenureHook at a mined flag address.
///         - Pool A "demo": mock tokens + MockReferencePrice + the scenario actors + DemoDirector, so
///           script/demo_testnet.sh can replay the headline scenario on-chain, one tick per tx.
///         - Pool B "chainlink": mock tWETH/tUSDC priced by the LIVE Chainlink ETH/USD and USDC/USD feeds through
///           ChainlinkReferencePrice. Same curator contract as pool A, so a freeze on A is relayed to B.
///         - TenureReactiveReceiver (keeper-free settlement) and TenureFreezeReceiver (cross-vault freeze), funded,
///           behind the official Reactive callback proxy. Both vaults accept relayed freezes from the receiver.
///         Writes every address to deployments/<chainId>.json (read by script/DeployLasna.s.sol).
/// @dev ALWAYS FOUNDRY_PROFILE=deploy (via-IR): the default profile's hook is over EIP-170. Commands: docs/DEPLOY.md.
///      Dry run against the live chain (simulation only, no key needed):
///        FOUNDRY_PROFILE=deploy forge script script/DeployUnichainSepolia.s.sol \
///          --rpc-url https://sepolia.unichain.org --sender 0xD9df64Cb859206eECF3761ec4eb5057B579438A2
///      On chain 31337 (anvil) it deploys its own PoolManager and mock Chainlink feeds instead.
contract DeployUnichainSepolia is TenureHookDeployer {
    using stdJson for string;
    using PoolIdLibrary for PoolKey;

    string internal cfg;
    bool internal local;
    address internal me;
    IPoolManager internal pm;
    TenureHook internal hook;

    // pool A (demo)
    PoolKey internal keyA;
    MockReferencePrice internal oracleA;
    CuratedVault internal vaultA;
    PoisonedCurator internal curator;
    DemoDirector internal director;
    // pool B (chainlink)
    PoolKey internal keyB;
    ChainlinkReferencePrice internal oracleB;
    CuratedVault internal vaultB;
    address internal weth;
    address internal usdc;
    // reactive receivers
    TenureReactiveReceiver internal settleReceiver;
    TenureFreezeReceiver internal freezeReceiver;

    function run() external {
        cfg = vm.readFile("deployments/config.json");
        local = block.chainid == 31337;
        require(local || block.chainid == cfg.readUint(".unichainSepolia.chainId.value"), "wrong chain");

        vm.startBroadcast();
        me = msg.sender;
        pm = local
            ? IPoolManager(V4PoolManagerDeployer.deploy(me))
            : IPoolManager(cfg.readAddress(".unichainSepolia.poolManager.value"));
        require(address(pm).code.length > 0, "no PoolManager at the configured address");
        hook = _deployHook(
            pm, me, me, cfg.readUint(".tenure.mandateDelaySeconds"), cfg.readUint(".tenure.restoreDelayBlocks")
        );
        _deployDemoPool();
        _deployChainlinkPool();
        _deployReceivers();
        vaultA.transferOwnership(address(director)); // last: the director enters safe mode once FROZEN
        vm.stopBroadcast();

        _report();
    }

    // ------------------------------------------------------------------------------------------------ pool A
    function _deployDemoPool() internal {
        string memory p = ".tenure.demoPool";
        require(keccak256(bytes(cfg.readString(string.concat(p, ".referencePrice")))) == keccak256("mock"), "A: mock");
        (Currency c0, Currency c1) = _pair(
            address(new MockERC20("Tenure Demo A", "TDA", 18)), address(new MockERC20("Tenure Demo B", "TDB", 18))
        );
        keyA = PoolKey(
            c0,
            c1,
            uint24(cfg.readUint(string.concat(p, ".fee"))),
            int24(int256(cfg.readUint(string.concat(p, ".tickSpacing")))),
            IHooks(address(hook))
        );
        uint160 one = 79228162514264337593543950336; // price 1
        oracleA = new MockReferencePrice();
        oracleA.setPrice(keyA.toId(), one);
        pm.initialize(keyA, one);
        _addFullRange(keyA, uint128(cfg.readUint(string.concat(p, ".thirdPartyLiquidity"))), 1e30, 1e30);

        vaultA = new CuratedVault(pm, hook, keyA, me, me, 50, "Tenure Demo Vault", "tnDEMO");
        hook.registerPool(keyA, address(vaultA), oracleA, _settings(p));
        uint256 dep = cfg.readUint(string.concat(p, ".depositEach"));
        _mintApprove(c0, c1, address(vaultA), dep, dep);
        vaultA.deposit(dep, dep, 0, me);

        TestSwapper marketSwapper = new TestSwapper(pm);
        _mint(c0, c1, address(marketSwapper), 1e29, 1e29);
        Market market = new Market(pm, oracleA, marketSwapper, keyA, 0x7e2a, 20, 2_000 ether);
        TestSwapper atkSwapper = new TestSwapper(pm);
        _mint(c0, c1, address(atkSwapper), 10_000_000 ether, 10_000_000 ether);
        Attacker attacker = new Attacker(pm, oracleA, atkSwapper, keyA);
        curator = new PoisonedCurator(vaultA, oracleA, 600, 120, 30, 1500);
        vaultA.setCurator(address(curator));
        curator.act(); // first, honest placement around the fair price
        director =
            new DemoDirector(vaultA, market, curator, attacker, oracleA, cfg.readUint(string.concat(p, ".poisonAt")));
    }

    // ------------------------------------------------------------------------------------------------ pool B
    function _deployChainlinkPool() internal {
        string memory p = ".tenure.chainlinkPool";
        require(keccak256(bytes(cfg.readString(string.concat(p, ".referencePrice")))) == keccak256("chainlink"), "B");
        weth = address(new MockERC20("Tenure test WETH", "tWETH", 18));
        usdc = address(new MockERC20("Tenure test USDC", "tUSDC", 6));
        (address ethUsd, address usdcUsd) = local
            ? (address(new MockAggregator(8, 3_000e8)), address(new MockAggregator(8, 1e8)))
            : (cfg.readAddress(".chainlink.ethUsd.value"), cfg.readAddress(".chainlink.usdcUsd.value"));
        bool wethIs0 = weth < usdc;
        (Currency c0, Currency c1) = _pair(weth, usdc);
        keyB = PoolKey(
            c0,
            c1,
            uint24(cfg.readUint(string.concat(p, ".fee"))),
            int24(int256(cfg.readUint(string.concat(p, ".tickSpacing")))),
            IHooks(address(hook))
        );
        PoolId idB = keyB.toId();
        oracleB = new ChainlinkReferencePrice(me);
        oracleB.setFeeds(
            idB,
            AggregatorV3Interface(wethIs0 ? ethUsd : usdcUsd),
            AggregatorV3Interface(wethIs0 ? usdcUsd : ethUsd),
            wethIs0 ? 18 : 6,
            wethIs0 ? 6 : 18
        );
        (uint160 fair,) = oracleB.getSqrtPriceX96(idB); // the live Chainlink price
        pm.initialize(keyB, fair);

        // USDC per WETH from the feeds (both 8 decimals), in tUSDC base units (6 decimals).
        uint256 usdcPerWeth = _answer(ethUsd) * 1e6 / _answer(usdcUsd);
        uint256 lpWeth = cfg.readUint(string.concat(p, ".thirdPartyLiquidityWethUnits"));
        uint256 lpUsdc = lpWeth * usdcPerWeth / 1e18;
        (uint256 a0, uint256 a1) = wethIs0 ? (lpWeth, lpUsdc) : (lpUsdc, lpWeth);
        uint128 l = LiquidityAmounts.getLiquidityForAmounts(
            fair,
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(keyB.tickSpacing)),
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(keyB.tickSpacing)),
            a0,
            a1
        );
        _addFullRange(keyB, l * 99 / 100, a0, a1);

        vaultB = new CuratedVault(pm, hook, keyB, me, address(curator), 50, "Tenure Chainlink Vault", "tnCL");
        hook.registerPool(keyB, address(vaultB), oracleB, _settings(p));
        uint256 depWeth = cfg.readUint(string.concat(p, ".depositWeth"));
        uint256 depUsdc = depWeth * usdcPerWeth / 1e18;
        (uint256 d0, uint256 d1) = wethIs0 ? (depWeth, depUsdc) : (depUsdc, depWeth);
        _mintApprove(c0, c1, address(vaultB), d0, d1);
        vaultB.deposit(d0, d1, 0, me);
    }

    // ------------------------------------------------------------------------------------------------ reactive
    function _deployReceivers() internal {
        address proxy = cfg.readAddress(".unichainSepolia.reactiveCallbackProxy.value");
        uint256 fund = cfg.readUint(".tenure.receiverFundingWei");
        settleReceiver = new TenureReactiveReceiver{value: fund}(proxy, ITenureSettle(address(hook)));
        freezeReceiver = new TenureFreezeReceiver{value: fund}(proxy);
        vaultA.setFreezeReceiver(address(freezeReceiver));
        vaultB.setFreezeReceiver(address(freezeReceiver));
    }

    // ------------------------------------------------------------------------------------------------ helpers
    function _settings(string memory p) internal view returns (PoolSettings memory) {
        return PoolSettings({
            maxOracleAge: uint32(cfg.readUint(string.concat(p, ".maxOracleAgeSeconds"))),
            window: uint32(cfg.readUint(string.concat(p, ".window"))),
            maxSettleDev: uint24(cfg.readUint(string.concat(p, ".maxSettleDev"))),
            autoSettlePerSwap: uint8(cfg.readUint(string.concat(p, ".autoSettlePerSwap"))),
            mandate: Mandate({minWidth: 120, maxWidth: 12_000, maxCenterDist: 3000, maxMoveWad: 0.2e18, cooldown: 10}),
            budget: TenureDefaults.budgetParams()
        });
    }

    function _addFullRange(PoolKey memory key, uint128 l, uint256 fund0, uint256 fund1) internal {
        DemoLiquidity lp = new DemoLiquidity(pm);
        _mint(key.currency0, key.currency1, address(lp), fund0 * 2, fund1 * 2);
        lp.add(key, TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), l);
    }

    function _answer(address feed) internal view returns (uint256) {
        (, int256 a,,,) = AggregatorV3Interface(feed).latestRoundData();
        require(a > 0, "bad feed answer");
        return uint256(a);
    }

    function _pair(address a, address b) internal pure returns (Currency, Currency) {
        return a < b ? (Currency.wrap(a), Currency.wrap(b)) : (Currency.wrap(b), Currency.wrap(a));
    }

    function _mint(Currency c0, Currency c1, address to, uint256 a0, uint256 a1) internal {
        MockERC20(Currency.unwrap(c0)).mint(to, a0);
        MockERC20(Currency.unwrap(c1)).mint(to, a1);
    }

    function _mintApprove(Currency c0, Currency c1, address spender, uint256 a0, uint256 a1) internal {
        _mint(c0, c1, me, a0, a1);
        MockERC20(Currency.unwrap(c0)).approve(spender, type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(spender, type(uint256).max);
    }

    function _report() internal {
        string memory o = "deployment";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "deployer", me);
        vm.serializeAddress(o, "poolManager", address(pm));
        vm.serializeAddress(o, "tenureHook", address(hook));
        vm.serializeAddress(o, "demoVault", address(vaultA));
        vm.serializeAddress(o, "demoOracle", address(oracleA));
        vm.serializeBytes32(o, "demoPoolId", PoolId.unwrap(keyA.toId()));
        vm.serializeAddress(o, "demoDirector", address(director));
        vm.serializeAddress(o, "curator", address(curator));
        vm.serializeAddress(o, "chainlinkVault", address(vaultB));
        vm.serializeAddress(o, "chainlinkOracle", address(oracleB));
        vm.serializeBytes32(o, "chainlinkPoolId", PoolId.unwrap(keyB.toId()));
        vm.serializeAddress(o, "tWETH", weth);
        vm.serializeAddress(o, "tUSDC", usdc);
        vm.serializeAddress(o, "settleReceiver", address(settleReceiver));
        string memory out = vm.serializeAddress(o, "freezeReceiver", address(freezeReceiver));
        // Only a real broadcast writes <chainId>.json (read by DeployLasna); a simulation never masquerades as one.
        bool live = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast);
        string memory path = string.concat("deployments/", vm.toString(block.chainid), live ? ".json" : ".dryrun.json");
        vm.writeJson(out, path);

        console2.log("TenureHook       :", address(hook));
        console2.log("hook size (B)    :", address(hook).code.length);
        console2.log("Demo vault (A)   :", address(vaultA));
        console2.log("DemoDirector     :", address(director));
        console2.log("Chainlink vault B:", address(vaultB));
        console2.log("Settle receiver  :", address(settleReceiver));
        console2.log("Freeze receiver  :", address(freezeReceiver));
        console2.log("written          :", path);
    }
}
