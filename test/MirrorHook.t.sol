// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

// Foundry libraries
import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";
import { Vm } from "forge-std/Vm.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

// Our contracts
import {MirrorTradingHook} from "../src/MirrorHook.sol";

contract TestMirrorTradingHook is Test, Deployers {
    // Use the libraries
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    address public trader = address(31337);

    Currency token0;
    Currency token1;
    // Currency token2;

    PoolKey key0;
    PoolKey key1;
    PoolId poolId0;
    PoolId poolId1;

    MirrorTradingHook hook;

    function setUp() public {
        // Deploy v4 core contracts
        deployFreshManagerAndRouters();

        // Deploy two test tokens
        (token0, token1) = deployMintAndApprove2Currencies();

        // Deploy hook
       address hookAddress = address(uint160(Hooks.AFTER_SWAP_FLAG));
        vm.txGasPrice(10 gwei);
        deployCodeTo("MirrorHook.sol", abi.encode(manager, ""), hookAddress);
        hook = MirrorTradingHook(hookAddress);

        // Approve our hook address to spend these tokens as well
        MockERC20(Currency.unwrap(token0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(hook), type(uint256).max);

        // Initialize a pool with these two tokens
        (key0, poolId0) = initPool(
            token0,
            token1,
            hook,
            3000,
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );

        // Add initial liquidity to the pool

        // Some liquidity from -60 to +60 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key0,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        // Some liquidity from -120 to +120 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key0,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        // some liquidity for full range
        modifyLiquidityRouter.modifyLiquidity(
            key0,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_mirrorFlow() external  {
        uint256 traderAmount = 1e18;
        
        vm.startPrank(trader);
        
        MockERC20(Currency.unwrap(token0)).mint(address(trader), traderAmount);
        MockERC20(Currency.unwrap(token0)).approve(address(hook),traderAmount);

        uint256 poolNumber = 0;
        uint256 tokenNumber = 0;
        uint256 duration = 1 days;

        PoolKey[] memory allowedPools = new PoolKey[](1);
        allowedPools[0] = key0;
        
        vm.expectRevert(); // insufficient duration
        hook.openPosition(traderAmount, allowedPools, poolNumber, tokenNumber, 1);

        vm.expectRevert(); // out of rage pool
        hook.openPosition(traderAmount, allowedPools, 1, tokenNumber, duration);

        vm.expectRevert(); // amount exceed balance
        hook.openPosition(traderAmount + 1, allowedPools, poolNumber, tokenNumber, duration);

        vm.expectRevert(); // out of rage token
        hook.openPosition(traderAmount + 1, allowedPools, poolNumber, tokenNumber, duration);

        uint256 traderNonceBeforePositionOpen = hook.traderNonce(address(trader));
        uint256 traderBalanceBeforePositionOpen = MockERC20(Currency.unwrap(token0)).balanceOf(address(trader));
        uint256 hookBalanceBeforePositionOpen = MockERC20(Currency.unwrap(token0)).balanceOf(address(hook));
        vm.assertEq(traderBalanceBeforePositionOpen, traderAmount, "test_mirrorFlow: E0: incorrect balance");

        bytes memory positionId0 = hook.openPosition(traderAmount, allowedPools, poolNumber, tokenNumber, duration);
        
        uint256 traderNonceAfterPositionOpen = hook.traderNonce(address(trader));
        uint256 traderBalanceAfterPositionOpen = MockERC20(Currency.unwrap(token0)).balanceOf(address(trader));
        uint256 hookBalanceAfterPositionOpen = MockERC20(Currency.unwrap(token0)).balanceOf(address(hook));

        vm.assertEq(hookBalanceAfterPositionOpen - hookBalanceBeforePositionOpen, traderAmount, "test_mirrorFlow: E1: incorrect hook balance increase");
        vm.assertEq(traderBalanceAfterPositionOpen, 0, "test_mirrorFlow: E2: incorrect trader balance decrease");
        vm.assertTrue(traderNonceAfterPositionOpen > traderNonceBeforePositionOpen,"test_mirrorFlow: E3: nonce increase failed");

        // hook.executePositionSwap(key0,positionId0);

        vm.stopPrank;

        // mapping(bytes subscriptionId => SubscriptionInfo subscription) public subscriptionById;
        // mapping(bytes positionId => mapping(address currency => uint256 balance)) public subscribedBalance;
        // mapping(bytes positionId => address currency) public subscriptionCurrency;
        
        
    }

}