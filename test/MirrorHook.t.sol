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
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {MirrorTradingHook} from "../src/MirrorHook.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TestMirrorTradingHook is Test, Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    address public trader = address(1337);
    address public alice = address(alice);
    address public bob = address(bob);

    Currency token0;
    Currency token1;
    Currency token2;

    PoolKey key0;
    PoolKey key1;
    PoolId poolId0;
    PoolId poolId1;

    MirrorTradingHook hook;

    function setUp() public {
        deployFreshManagerAndRouters();

        (token0, token1) = deployMintAndApprove2Currencies();
        (token1, token2) = deployMintAndApprove2Currencies();
        
        address hookAddress = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG));
        vm.txGasPrice(10 gwei);
        deployCodeTo("MirrorHook.sol", abi.encode(manager,""), hookAddress);
        hook = MirrorTradingHook(hookAddress);

        MockERC20(Currency.unwrap(token0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(token2)).approve(address(hook), type(uint256).max);
        
        // console.log("Currency0:",Currency.unwrap(token0));
        // console.log("Currency1:",Currency.unwrap(token1));
        // console.log("Currency2:",Currency.unwrap(token2));

        (key0, poolId0) = initPool(
            token0,
            token1,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG, //3000
            SQRT_PRICE_1_1, 
            ZERO_BYTES
        );

        (key1, poolId1) = initPool(
            token1,
            token2,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG, //3000
            SQRT_PRICE_1_1, 
            ZERO_BYTES
        );

        modifyLiquidityRouter.modifyLiquidity(
            key0,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        modifyLiquidityRouter.modifyLiquidity(
            key0,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        modifyLiquidityRouter.modifyLiquidity(
            key0,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        modifyLiquidityRouter.modifyLiquidity(
            key1,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_subscribeFlow(uint256 subscriptionAmount) external  {
        vm.assume(subscriptionAmount > 0.1 ether && subscriptionAmount < 10 ether);
        // uint256 subscriptionAmount = 10 ether;
        uint256 traderAmount = 5 ether;

        // Trader opens position
        vm.startPrank(trader);
        MockERC20(Currency.unwrap(token0)).mint(address(trader), traderAmount);
        MockERC20(Currency.unwrap(token0)).approve(address(hook),traderAmount);

        bytes memory positionId = _openPosition(traderAmount);
        vm.stopPrank();
        
        // Alice subscribes to position
         vm.startPrank(alice);
        uint256 aliceAmount = subscriptionAmount * 3 / 4;
        MockERC20(Currency.unwrap(token0)).mint(alice, aliceAmount);
        MockERC20(Currency.unwrap(token0)).approve(address(hook),aliceAmount);
        
        bytes memory subscriptionIdAlice = _subscribe(aliceAmount, positionId ,5 days);
        vm.stopPrank();

        // Bob subscribes to position
        vm.startPrank(bob);
        uint256 bobAmount = subscriptionAmount * 1 / 4;
        MockERC20(Currency.unwrap(token0)).mint(alice, bobAmount);
        MockERC20(Currency.unwrap(token0)).approve(address(hook),bobAmount);
        
        bytes memory subscriptionIdBob = _subscribe(bobAmount, positionId ,4 days);
        vm.stopPrank();

        console.log("==== Trader swaps postion: token_0 -> token_1 (Pool_0) ====");
        vm.startPrank(trader);
        _swapPosition(key0, positionId, true);

        console.log("==== Trader swaps postion: token_1 -> token_2 (Pool_1) ====");
        vm.startPrank(trader);
        _swapPosition(key1, positionId, true);

        console.log("==== Trader swaps postion: token_2 -> token_1 (Pool_1) ====");
        vm.startPrank(trader);
        _swapPosition(key1, positionId, false);

        console.log("==== Trader swaps postion: token_1 -> token_0 (Pool_0) ====");
        vm.startPrank(trader);
        _swapPosition(key0, positionId, false);
    }
    
    // ============================================================================================
    // Internal functions
    // ============================================================================================

    function _swapPosition(PoolKey memory key, bytes memory positionId, bool zeroForOne) internal {
        console.log("=== SWAP POSITION ===");
        address subscriptionCurrencyBeforeSwap = hook.subscriptionCurrency(positionId);
        address positionCurrencyBeforeSwap = hook.getCurrency(positionId);
        assertEq(subscriptionCurrencyBeforeSwap,positionCurrencyBeforeSwap,"_swapPosition: E0");
        Currency t0 = key.currency0;
        Currency t1 = key.currency1;

        console.log("subscriptionCurrencyBeforeSwap",subscriptionCurrencyBeforeSwap);
        console.log("positionCurrencyBeforeSwap",positionCurrencyBeforeSwap);
        console.log("Currency.unwrap(t0)",Currency.unwrap(t0));
        console.log("Currency.unwrap(t1)",Currency.unwrap(t1));

        if (zeroForOne) {
            assertEq(positionCurrencyBeforeSwap, Currency.unwrap(t0),"_swapPosition: E1");
        } else {
            assertEq(positionCurrencyBeforeSwap, Currency.unwrap(t1),"_swapPosition: E2");
        }
        uint256 hookBalanceToken0BeforeSwap = IERC20(Currency.unwrap(t0)).balanceOf(address(hook));
        uint256 hookBalanceToken1BeforeSwap = IERC20(Currency.unwrap(t1)).balanceOf(address(hook));

        uint256 subscriptionBalanceToken0BeforeSwap = hook.subscribedBalance(positionId,Currency.unwrap(t0));
        uint256 subscriptionBalanceToken1BeforeSwap = hook.subscribedBalance(positionId,Currency.unwrap(t1));
        (,uint256 positionAmountBefore,,,,,) = hook.getPositionInfo(positionId);
        
        console.log("hookBalanceToken0BeforeSwap",hookBalanceToken0BeforeSwap);
        console.log("hookBalanceToken1BeforeSwap",hookBalanceToken1BeforeSwap);
        console.log("subscriptionBalanceToken0BeforeSwap",subscriptionBalanceToken0BeforeSwap);
        console.log("subscriptionBalanceToken1BeforeSwap",subscriptionBalanceToken1BeforeSwap);
        console.log("positionAmountBefore",positionAmountBefore);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(positionAmountBefore),  
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                });
        
        hook.hookSwap(key, params, positionId);

        address subscriptionCurrencyAfterSwap = hook.subscriptionCurrency(positionId);
        address positionCurrencyAfterSwap = hook.getCurrency(positionId);
        assertEq(subscriptionCurrencyAfterSwap,positionCurrencyAfterSwap,"_swapPosition: E3");
        if (zeroForOne) {
            assertEq(positionCurrencyAfterSwap,Currency.unwrap(t1),"_swapPosition: E4");
        } else {
            assertEq(positionCurrencyAfterSwap,Currency.unwrap(t0),"_swapPosition: E5");
        }
        uint256 hookBalanceToken0AfterSwap = IERC20(Currency.unwrap(t0)).balanceOf(address(hook));
        uint256 hookBalanceToken1AfterSwap = IERC20(Currency.unwrap(t1)).balanceOf(address(hook));

        uint256 subscriptionBalanceToken0AfterSwap = hook.subscribedBalance(positionId,Currency.unwrap(t0));
        uint256 subscriptionBalanceToken1AfterSwap = hook.subscribedBalance(positionId,Currency.unwrap(t1));
        (,uint256 positionAmountAfter,,,,,) = hook.getPositionInfo(positionId);
        
        console.log("subscriptionCurrencyAfterSwap",subscriptionCurrencyAfterSwap);
        console.log("positionCurrencyAfterSwap",positionCurrencyAfterSwap);
        console.log("hookBalanceToken0AfterSwap",hookBalanceToken0AfterSwap);
        console.log("hookBalanceToken1AfterSwap",hookBalanceToken1AfterSwap);
        console.log("subscriptionBalanceToken0AfterSwap",subscriptionBalanceToken0AfterSwap);
        console.log("subscriptionBalanceToken1AfterSwap",subscriptionBalanceToken1AfterSwap);
        console.log("positionAmountAfter",positionAmountAfter);

        if (zeroForOne) {
            assertEq(hookBalanceToken0BeforeSwap - positionAmountBefore - subscriptionBalanceToken0BeforeSwap, hookBalanceToken0AfterSwap,"_swapPosition: E6");
            assertEq(hookBalanceToken1AfterSwap, hookBalanceToken1BeforeSwap + positionAmountAfter + subscriptionBalanceToken1AfterSwap,"_swapPosition: E7");
        } else {
            assertEq(hookBalanceToken1BeforeSwap - positionAmountBefore - subscriptionBalanceToken1BeforeSwap, hookBalanceToken1AfterSwap,"_swapPosition: E8");
            assertEq(hookBalanceToken0AfterSwap, hookBalanceToken0BeforeSwap + positionAmountAfter + subscriptionBalanceToken0AfterSwap,"_swapPosition: E9");
        }
    }

    function _subscribe(uint256 subscriptionAmount, bytes memory positionId, uint256 expiry) internal returns (bytes memory subscriptionId) {

        address currency = hook.subscriptionCurrency(positionId);
        uint256 balanceBeforeSubscription = hook.subscribedBalance(positionId,Currency.unwrap(token0));
        if (balanceBeforeSubscription == 0) {
        assertTrue(currency == address(0), "_subscribe: E0");
        assertEq(balanceBeforeSubscription,0,"_subscribe: E1");
        }
        subscriptionId = hook.subscribe(positionId, subscriptionAmount, expiry, 0);

        currency = hook.subscriptionCurrency(positionId);
        uint256 balanceAfterSubscription = hook.subscribedBalance(positionId,Currency.unwrap(token0));
        assertTrue(currency == Currency.unwrap(token0), "_subscribe: E2");
        assertEq(balanceAfterSubscription - balanceBeforeSubscription, subscriptionAmount, "_subscribe: E3");

        return subscriptionId;
    }

    function _openPosition(uint256 traderAmount) internal returns (bytes memory positionId)  {
    
        uint256 poolNumber = 0;
        uint256 tokenNumber = 0;
        uint256 duration = 1 days;

        PoolKey[] memory allowedPools = new PoolKey[](2);
        allowedPools[0] = key0;
        allowedPools[1] = key1;
        
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

        return positionId;
    }

}