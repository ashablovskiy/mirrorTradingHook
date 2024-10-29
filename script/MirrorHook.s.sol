// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "v4-core/test/PoolDonateTest.sol";
import {PoolTakeTest} from "v4-core/test/PoolTakeTest.sol";
import {PoolClaimsTest} from "v4-core/test/PoolClaimsTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {HookMiner} from "../test/utils/HookMiner.sol";
import {MirrorTradingHook} from "../src/MirrorHook.sol";
// import {SwapHelper} from "../src/SwapHelper.sol";

import "forge-std/console.sol";
import "@uniswap/v4-core/src/libraries/Hooks.sol";

contract MirrorHooknDeployScript is Script {
    PoolManager manager = PoolManager(0xCa6DBBe730e31fDaACaA096821199EEED5AD84aE);
    PoolSwapTest swapRouter = PoolSwapTest(0xEc9537B6D66c14E872365AB0EAE50dF7b254D4Fc);
    PoolModifyLiquidityTest modifyLiquidityRouter = PoolModifyLiquidityTest(0x1f03f235e371202e49194F63C7096F5697848822);

    Currency token0;
    Currency token1;

    PoolKey key;

    function setUp() public {
        vm.startBroadcast();

        console.log("Wallet / msg.sender is: %s", msg.sender);
        console.log("Self: %s", address(this));

        MockERC20 tokenA = new MockERC20("Test Mirror 0", "MirrorToken0", 18);
        MockERC20 tokenB = new MockERC20("Test Mirror 1", "MirrorToken1", 18);

        if (address(tokenA) > address(tokenB)) {
            (token0, token1) = (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));
        } else {
            (token0, token1) = (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)));
        }

        console.log("token0: %s", address(Currency.unwrap(token0)));
        console.log("token1: %s", address(Currency.unwrap(token1)));
        console.log("Manager: %s", address(manager));
        console.log("swapRouter: %s", address(swapRouter));
        console.log("modifyLiquidityRouter: %s", address(modifyLiquidityRouter));

        tokenA.mint(msg.sender, 1000 * 10 ** 18);
        tokenB.mint(msg.sender, 1000 * 10 ** 18);

        // Mine for hook address
        vm.stopBroadcast();

        uint160 flags = (uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG));
        address CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, flags, type(MirrorTradingHook).creationCode, abi.encode(address(manager))
        );

        vm.startBroadcast();
        MirrorTradingHook hook = new MirrorTradingHook{salt: salt}(IPoolManager(manager));
        require(address(hook) == hookAddress, "hook address mismatch");
        console.log("MirrorHook address: %s", address(hook));

        tokenA.approve(address(modifyLiquidityRouter), type(uint256).max);
        tokenB.approve(address(modifyLiquidityRouter), type(uint256).max);
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);
        tokenA.approve(address(hook), type(uint256).max);
        tokenB.approve(address(hook), type(uint256).max);

        tokenA.mint(address(this), 2 ** 255);
        tokenB.mint(address(this), 2 ** 255);

        key = PoolKey({currency0: token0, currency1: token1, fee: 3000, tickSpacing: 120, hooks: IHooks(address(hook))});
        // SwapHelper swapHelper = new SwapHelper(tokenA, tokenB, address(hook));
        // console.log("SwapHelper address: %s", address(swapHelper));

        // initPoolAndAddLiquidity
        // the second argument here is MAX_SQRT_PRICE - 1
        manager.initialize(key, 1461446703485210103287273052203988822378723970342 - 1, new bytes(0));
        // modifyLiquidityRouter.modifyLiquidity(
        //     key,
        //     IPoolManager.ModifyLiquidityParams({
        //         tickLower: -120,
        //         tickUpper: 120,
        //         liquidityDelta: 10e18,
        //         salt: 0
        //     }),
        //     new bytes(0)
        // );
        vm.stopBroadcast();
    }

    function run() public {
        // moved to setUp()
        vm.startBroadcast();
        // modifyLiquidityRouter.modifyLiquidity(
        //     key,
        //     IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 10e18, salt: 0}),
        //     new bytes(0)
        // );
        vm.stopBroadcast();
    }
}