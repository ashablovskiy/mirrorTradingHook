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
    address public alice = address(alice);
    address public bob = address(bob);

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
       address hookAddress = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG));
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

    function test_subscribeFlow(uint256 subscriptionAmount) external  {
        vm.assume(subscriptionAmount > 0.1 ether && subscriptionAmount < 10 ether);

        uint256 traderAmount = 5 ether;

        bytes memory positionId = _openPosition(traderAmount);
        
        bytes memory subscriptionId = _subscribe(subscriptionAmount, positionId, alice ,5 days);

        vm.startPrank(trader);
        hook.executePositionSwap(key0,positionId);

    }

    function test_openPositionAndSwap(uint256 traderAmount) external  {
        vm.assume(traderAmount > 0.1 ether && traderAmount < 10 ether);

        bytes memory positionId = _openPosition(traderAmount);
        
        uint256 hookBalanceToken0BeforeSwap = MockERC20(Currency.unwrap(token0)).balanceOf(address(hook));
        uint256 hookBalanceToken1BeforeSwap = MockERC20(Currency.unwrap(token1)).balanceOf(address(hook));

        hook.executePositionSwap(key0,positionId);

        uint256 hookBalanceToken0AfterSwap = MockERC20(Currency.unwrap(token0)).balanceOf(address(hook));
        uint256 hookBalanceToken1AfterSwap = MockERC20(Currency.unwrap(token1)).balanceOf(address(hook));
        vm.assertTrue(hookBalanceToken1AfterSwap > hookBalanceToken1BeforeSwap,"test_openPositionAndSwap: E0");
        vm.assertTrue(hookBalanceToken0BeforeSwap > hookBalanceToken0AfterSwap,"test_openPositionAndSwap: E1");

    }
    
    // ============================================================================================
    // Internal functions
    // ============================================================================================

    function _subscribe(uint256 subscriptionAmount, bytes memory positionId, address subscriber ,uint256 expiry) internal returns (bytes memory subscriptionId) {
        vm.startPrank(subscriber);

        MockERC20(Currency.unwrap(token0)).mint(address(subscriber), subscriptionAmount);
        MockERC20(Currency.unwrap(token0)).approve(address(hook),subscriptionAmount);

        address currency = hook.subscriptionCurrency(positionId);
        assertTrue(currency == address(0), "E0");
        
        subscriptionId = hook.subscribe(positionId, subscriptionAmount, expiry, 0);

        currency = hook.subscriptionCurrency(positionId);
        assertTrue(currency == Currency.unwrap(token0), "E1");

        // mapping(bytes subscriptionId => SubscriptionInfo subscription) public subscriptionById;
        // mapping(bytes positionId => mapping(address currency => uint256 balance)) public subscribedBalance;
        // mapping(bytes positionId => address currency) public subscriptionCurrency;
        
        vm.stopPrank;

        return subscriptionId;
        
        }

    function _openPosition(uint256 traderAmount) internal returns (bytes memory positionId)  {
        
        vm.startPrank(trader);
        
        MockERC20(Currency.unwrap(token0)).mint(address(trader), traderAmount);
        MockERC20(Currency.unwrap(token0)).approve(address(hook),traderAmount);

        uint256 poolNumber = 0;
        uint256 tokenNumber = 0;
        uint256 duration = 1 days;

        PoolKey[] memory allowedPools = new PoolKey[](1);
        allowedPools[0] = key0;
        
        // === REVERT CASES =====
        vm.expectRevert(); // insufficient duration
        hook.openPosition(traderAmount, allowedPools, poolNumber, tokenNumber, 1);

        vm.expectRevert(); // out of rage pool
        hook.openPosition(traderAmount, allowedPools, 1, tokenNumber, duration);

        vm.expectRevert(); // amount exceed balance
        hook.openPosition(traderAmount + 1, allowedPools, poolNumber, tokenNumber, duration);

        vm.expectRevert(); // out of rage token
        hook.openPosition(traderAmount + 1, allowedPools, poolNumber, tokenNumber, duration);
        // =======================

        uint256 traderNonceBeforePositionOpen = hook.traderNonce(address(trader));
        uint256 traderBalanceBeforePositionOpen = MockERC20(Currency.unwrap(token0)).balanceOf(address(trader));
        uint256 hookBalanceBeforePositionOpen = MockERC20(Currency.unwrap(token0)).balanceOf(address(hook));
        vm.assertEq(traderBalanceBeforePositionOpen, traderAmount, "_openPosition: E0: incorrect balance");

        positionId = hook.openPosition(traderAmount, allowedPools, poolNumber, tokenNumber, duration);

        uint256 traderNonceAfterPositionOpen = hook.traderNonce(address(trader));
        uint256 traderBalanceAfterPositionOpen = MockERC20(Currency.unwrap(token0)).balanceOf(address(trader));
        uint256 hookBalanceAfterPositionOpen = MockERC20(Currency.unwrap(token0)).balanceOf(address(hook));

        vm.assertEq(hookBalanceAfterPositionOpen - hookBalanceBeforePositionOpen, traderAmount, "_openPosition: E1: incorrect hook balance increase");
        vm.assertEq(traderBalanceAfterPositionOpen, 0, "_openPosition: E2: incorrect trader balance decrease");
        vm.assertTrue(traderNonceAfterPositionOpen > traderNonceBeforePositionOpen,"_openPosition: E3: nonce increase failed");

        vm.stopPrank;

        return positionId;
    }

}