// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

// Foundry libraries
import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";

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
    address public alice = 0x84d47aD884f5e44b6807AB05A27a32B19Cb48040;
    address public bob = address(0x65215Cced09ee9eBFD156984B9Fa640260C82DdC);
    address public eve = address(0x803179BC06Ad7F72Ebe7e90a839e85Cc641c2f36);

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
        deployCodeTo("MirrorHook.sol", abi.encode(manager, ""), hookAddress);
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

    /**
     * @dev Tests the general flow of a mirror trading scenario:
     * - Trader opens a position.
     * - Alice subscribes to the position.
     * - Bob subscribes to the same position.
     * - The trader performs a series of swaps:
     *   1. Selling Currency_0 for Currency_1 in Pool_0
     *   2. Selling Currency_1 for Currency_2 in Pool_1
     *   3. Selling Currency_2 for Currency_1 in Pool_1
     *   4. Selling Currency_1 for Currency_0 in Pool_0
     */
    function test_generalFlow(uint256 subscriptionAmount) external {
        vm.assume(subscriptionAmount > 0.1 ether && subscriptionAmount < 10 ether);
        uint256 traderAmount = 5 ether;

        // Trader opens position
        vm.startPrank(trader);
        MockERC20(Currency.unwrap(token0)).mint(address(trader), traderAmount);
        MockERC20(Currency.unwrap(token0)).approve(address(hook), traderAmount);

        bytes memory positionId = _openPosition(traderAmount, 0, 0, 10 days);
        vm.stopPrank();

        // Alice subscribes to position
        vm.startPrank(alice);
        uint256 aliceAmount = subscriptionAmount * 3 / 4;
        MockERC20(Currency.unwrap(token0)).mint(alice, aliceAmount);
        MockERC20(Currency.unwrap(token0)).approve(address(hook), aliceAmount);

        _subscribe(aliceAmount, positionId, 5 days);
        vm.stopPrank();

        // Bob subscribes to position
        vm.startPrank(bob);
        uint256 bobAmount = subscriptionAmount * 1 / 4;
        MockERC20(Currency.unwrap(token0)).mint(bob, bobAmount);
        MockERC20(Currency.unwrap(token0)).approve(address(hook), bobAmount);

        _subscribe(bobAmount, positionId, 4 days);
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

    /**
     * @dev Tests the dynamic fee calculation for a trader based on different position lock durations.
     */
    function test_dynamicFee(uint256 subscriptionAmount) external {
        vm.assume(subscriptionAmount > 0.1 ether && subscriptionAmount < 10 ether);
        // uint256 subscriptionAmount = 1 ether;
        uint256 traderAmount = 5 ether;

        vm.startPrank(trader);
        MockERC20(Currency.unwrap(token0)).mint(address(trader), traderAmount * 3);
        MockERC20(Currency.unwrap(token0)).approve(address(hook), traderAmount * 3);

        bytes memory positionId0 = _openPosition(traderAmount, 0, 0, 1 days);
        bytes memory positionId1 = _openPosition(traderAmount, 0, 0, 15 days);
        bytes memory positionId2 = _openPosition(traderAmount, 0, 0, 30 days);

        vm.stopPrank();

        vm.startPrank(alice);
        MockERC20(Currency.unwrap(token0)).mint(alice, subscriptionAmount * 3);
        MockERC20(Currency.unwrap(token0)).approve(address(hook), subscriptionAmount * 3);

        _subscribe(subscriptionAmount, positionId0, 1 days);
        _subscribe(subscriptionAmount, positionId1, 15 days);
        _subscribe(subscriptionAmount, positionId2, 30 days);
        vm.stopPrank();

        vm.startPrank(trader);

        vm.recordLogs();
        _swapPosition(key0, positionId0, true); // 1 day position lock
        Vm.Log[] memory entries0 = vm.getRecordedLogs();
        (,,,,, uint24 feeTrader0) = abi.decode(entries0[0].data, (int128, int128, uint160, uint128, int24, uint24));
        (,,,,, uint24 feeSubscribers0) = abi.decode(entries0[1].data, (int128, int128, uint160, uint128, int24, uint24));
        assertEq(feeTrader0, 4834, "test_dynamicFee: E0"); // Trader fee - 0.048%
        assertEq(feeSubscribers0, 5000, "test_dynamicFee: E0"); // Subscribers fee - 0.05%

        vm.recordLogs();
        _swapPosition(key0, positionId1, true); // 15 days position lock
        Vm.Log[] memory entries1 = vm.getRecordedLogs();
        (,,,,, uint24 feeTrader1) = abi.decode(entries1[0].data, (int128, int128, uint160, uint128, int24, uint24));
        (,,,,, uint24 feeSubscribers1) = abi.decode(entries1[1].data, (int128, int128, uint160, uint128, int24, uint24));
        assertEq(feeTrader1, 2500, "test_dynamicFee: E0"); // Trader fee - 0.025%
        assertEq(feeSubscribers1, 5000, "test_dynamicFee: E0"); // Subscribers fee - 0.05%

        vm.recordLogs();
        _swapPosition(key0, positionId2, true);
        Vm.Log[] memory entries2 = vm.getRecordedLogs(); // 30 days position lock
        (,,,,, uint24 feeTrader2) = abi.decode(entries2[0].data, (int128, int128, uint160, uint128, int24, uint24));
        (,,,,, uint24 feeSubscribers2) = abi.decode(entries2[1].data, (int128, int128, uint160, uint128, int24, uint24));
        assertEq(feeTrader2, 0, "test_dynamicFee: E0"); // Trader fee - 0.00%
        assertEq(feeSubscribers2, 5000, "test_dynamicFee: E0"); // Subscribers fee - 0.05%

        vm.stopPrank();
    }

    /**
     * @dev Tests the penalties paid by Trader in case of position closure before expiry deadline.
     */
    function test_earlyPositionClose(uint256 duration) external {
        vm.assume(duration > 1 days && duration < 15 days);
        uint256 traderAmount = 5 ether;
        uint256 subscriptionAmount = 1 ether;

        vm.startPrank(trader);
        MockERC20(Currency.unwrap(token0)).mint(address(trader), traderAmount);
        MockERC20(Currency.unwrap(token0)).approve(address(hook), traderAmount);

        bytes memory positionId = _openPosition(traderAmount, 0, 0, 15 days);

        vm.startPrank(alice);
        MockERC20(Currency.unwrap(token0)).mint(alice, subscriptionAmount);
        MockERC20(Currency.unwrap(token0)).approve(address(hook), subscriptionAmount);

        _subscribe(subscriptionAmount, positionId, 5 days);
        vm.stopPrank();

        // fastforward 'duration' time
        vm.warp(block.timestamp + duration);

        uint256 traderBalanceToken0BeforeClose = IERC20(Currency.unwrap(token0)).balanceOf(trader);
        uint256 hookBalanceToken0BeforeClose = IERC20(Currency.unwrap(token0)).balanceOf(address(hook));

        assertEq(traderBalanceToken0BeforeClose, 0, "test_earlyPositionClose: E0");

        vm.startPrank(trader);

        vm.recordLogs();
        hook.closePosition(positionId);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        uint256 penalty = abi.decode(entries[0].data, (uint256));

        uint256 traderBalanceToken0AfterClose = IERC20(Currency.unwrap(token0)).balanceOf(trader);
        uint256 hookBalanceToken0AfterClose = IERC20(Currency.unwrap(token0)).balanceOf(address(hook));

        assertEq(
            hookBalanceToken0BeforeClose, hookBalanceToken0AfterClose + traderAmount, "test_earlyPositionClose: E1"
        );
        assertEq(
            traderBalanceToken0AfterClose,
            traderBalanceToken0BeforeClose + traderAmount - penalty,
            "test_earlyPositionClose: E2"
        );

        vm.stopPrank();
    }

    /**
     * @dev Tests that trader can open multiple positions
     */
    function test_traderOpensTwoPositions(uint256 traderAmount) external {
        vm.assume(traderAmount > 0.1 ether && traderAmount < 10 ether);
        uint256 position0 = traderAmount * 3 / 4;
        uint256 position1 = traderAmount * 1 / 4;

        vm.startPrank(trader);
        MockERC20(Currency.unwrap(token0)).mint(address(trader), traderAmount);
        MockERC20(Currency.unwrap(token0)).approve(address(hook), traderAmount);

        bytes memory positionId0 = _openPosition(position0, 0, 0, 10 days);
        bytes memory positionId1 = _openPosition(position1, 0, 0, 15 days);

        assertTrue(keccak256(positionId0) != keccak256(positionId1), "test_openTwoPositions: E0");

        vm.stopPrank();
    }

    /**
     * @dev Tests that only position owner can perform swap operations under the position
     */
    function test_revert_unauthorizedSwap(uint256 traderAmount) external {
        vm.assume(traderAmount > 0.1 ether && traderAmount < 10 ether);

        vm.startPrank(trader);
        MockERC20(Currency.unwrap(token0)).mint(address(trader), traderAmount);
        MockERC20(Currency.unwrap(token0)).approve(address(hook), traderAmount);

        bytes memory positionId = _openPosition(traderAmount, 0, 0, 10 days);
        vm.stopPrank();

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(traderAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        vm.startPrank(eve);

        vm.expectRevert();
        hook.hookSwap(key, params, positionId);
    }

    /**
     * @dev Tests that hook restricts opening position with duration less than specified
     */
    function test_revert_insufficientDuration(uint256 traderAmount) external {
        vm.assume(traderAmount > 0.1 ether && traderAmount < 10 ether);

        vm.startPrank(trader);
        MockERC20(Currency.unwrap(token0)).mint(address(trader), traderAmount);
        MockERC20(Currency.unwrap(token0)).approve(address(hook), traderAmount);

        PoolKey[] memory allowedPools = new PoolKey[](2);
        allowedPools[0] = key0;
        allowedPools[1] = key1;

        vm.expectRevert();
        hook.openPosition(traderAmount, allowedPools, 0, 0, 1);
    }

    /**
     * @dev Tests passing out-of-range values arguments passing when open position
     */
    function test_revert_valuesOutOfRange(uint256 traderAmount) external {
        vm.assume(traderAmount > 0.1 ether && traderAmount < 10 ether);

        vm.startPrank(trader);
        MockERC20(Currency.unwrap(token0)).mint(address(trader), traderAmount);
        MockERC20(Currency.unwrap(token0)).approve(address(hook), traderAmount);

        PoolKey[] memory allowedPools = new PoolKey[](2);
        allowedPools[0] = key0;
        allowedPools[1] = key1;

        vm.expectRevert();
        hook.openPosition(traderAmount + 1, allowedPools, 0, 0, 10 days);

        vm.expectRevert();
        hook.openPosition(traderAmount, allowedPools, 0, 2, 10 days);

        vm.expectRevert();
        hook.openPosition(traderAmount, allowedPools, 2, 0, 10 days);
    }

    // ============================================================================================
    // Internal functions
    // ============================================================================================

    function _swapPosition(PoolKey memory key, bytes memory positionId, bool zeroForOne) internal {
        console.log("=== SWAP POSITION ===");
        address subscriptionCurrencyBeforeSwap = hook.subscriptionCurrency(positionId);
        address positionCurrencyBeforeSwap = hook.getCurrency(positionId);
        assertEq(subscriptionCurrencyBeforeSwap, positionCurrencyBeforeSwap, "_swapPosition: E0");
        Currency t0 = key.currency0;
        Currency t1 = key.currency1;

        console.log("subscriptionCurrencyBeforeSwap", subscriptionCurrencyBeforeSwap);
        console.log("positionCurrencyBeforeSwap", positionCurrencyBeforeSwap);
        console.log("Currency.unwrap(t0)", Currency.unwrap(t0));
        console.log("Currency.unwrap(t1)", Currency.unwrap(t1));

        if (zeroForOne) {
            assertEq(positionCurrencyBeforeSwap, Currency.unwrap(t0), "_swapPosition: E1");
        } else {
            assertEq(positionCurrencyBeforeSwap, Currency.unwrap(t1), "_swapPosition: E2");
        }
        uint256 hookBalanceToken0BeforeSwap = IERC20(Currency.unwrap(t0)).balanceOf(address(hook));
        uint256 hookBalanceToken1BeforeSwap = IERC20(Currency.unwrap(t1)).balanceOf(address(hook));

        uint256 subscriptionBalanceToken0BeforeSwap = hook.subscribedBalance(positionId);
        uint256 subscriptionBalanceToken1BeforeSwap = hook.subscribedBalance(positionId);
        (, uint256 positionAmountBefore,,,,,) = hook.getPositionInfo(positionId);

        console.log("hookBalanceToken0BeforeSwap", hookBalanceToken0BeforeSwap);
        console.log("hookBalanceToken1BeforeSwap", hookBalanceToken1BeforeSwap);
        console.log("subscriptionBalanceToken0BeforeSwap", subscriptionBalanceToken0BeforeSwap);
        console.log("subscriptionBalanceToken1BeforeSwap", subscriptionBalanceToken1BeforeSwap);
        console.log("positionAmountBefore", positionAmountBefore);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(positionAmountBefore),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        hook.hookSwap(key, params, positionId);

        address subscriptionCurrencyAfterSwap = hook.subscriptionCurrency(positionId);
        address positionCurrencyAfterSwap = hook.getCurrency(positionId);
        assertEq(subscriptionCurrencyAfterSwap, positionCurrencyAfterSwap, "_swapPosition: E3");
        if (zeroForOne) {
            assertEq(positionCurrencyAfterSwap, Currency.unwrap(t1), "_swapPosition: E4");
        } else {
            assertEq(positionCurrencyAfterSwap, Currency.unwrap(t0), "_swapPosition: E5");
        }
        uint256 hookBalanceToken0AfterSwap = IERC20(Currency.unwrap(t0)).balanceOf(address(hook));
        uint256 hookBalanceToken1AfterSwap = IERC20(Currency.unwrap(t1)).balanceOf(address(hook));

        uint256 subscriptionBalanceToken0AfterSwap = hook.subscribedBalance(positionId);
        uint256 subscriptionBalanceToken1AfterSwap = hook.subscribedBalance(positionId);
        (, uint256 positionAmountAfter,,,,,) = hook.getPositionInfo(positionId);

        console.log("subscriptionCurrencyAfterSwap", subscriptionCurrencyAfterSwap);
        console.log("positionCurrencyAfterSwap", positionCurrencyAfterSwap);
        console.log("hookBalanceToken0AfterSwap", hookBalanceToken0AfterSwap);
        console.log("hookBalanceToken1AfterSwap", hookBalanceToken1AfterSwap);
        console.log("subscriptionBalanceToken0AfterSwap", subscriptionBalanceToken0AfterSwap);
        console.log("subscriptionBalanceToken1AfterSwap", subscriptionBalanceToken1AfterSwap);
        console.log("positionAmountAfter", positionAmountAfter);

        if (zeroForOne) {
            assertEq(
                hookBalanceToken0BeforeSwap - positionAmountBefore - subscriptionBalanceToken0BeforeSwap,
                hookBalanceToken0AfterSwap,
                "_swapPosition: E6"
            );
            assertEq(
                hookBalanceToken1AfterSwap,
                hookBalanceToken1BeforeSwap + positionAmountAfter + subscriptionBalanceToken1AfterSwap,
                "_swapPosition: E7"
            );
        } else {
            assertEq(
                hookBalanceToken1BeforeSwap - positionAmountBefore - subscriptionBalanceToken1BeforeSwap,
                hookBalanceToken1AfterSwap,
                "_swapPosition: E8"
            );
            assertEq(
                hookBalanceToken0AfterSwap,
                hookBalanceToken0BeforeSwap + positionAmountAfter + subscriptionBalanceToken0AfterSwap,
                "_swapPosition: E9"
            );
        }
    }

    function _subscribe(uint256 subscriptionAmount, bytes memory positionId, uint256 expiry)
        internal
        returns (uint256 subscriptionId)
    {
        address currency = hook.subscriptionCurrency(positionId);
        uint256 balanceBeforeSubscription = hook.subscribedBalance(positionId);
        if (balanceBeforeSubscription == 0) {
            assertTrue(currency == address(0), "_subscribe: E0");
            assertEq(balanceBeforeSubscription, 0, "_subscribe: E1");
        }
        subscriptionId = hook.subscribe(positionId, subscriptionAmount, expiry, 0);

        currency = hook.subscriptionCurrency(positionId);
        uint256 balanceAfterSubscription = hook.subscribedBalance(positionId);
        assertTrue(currency == Currency.unwrap(token0), "_subscribe: E2");
        assertEq(balanceAfterSubscription - balanceBeforeSubscription, subscriptionAmount, "_subscribe: E3");

        return subscriptionId;
    }

    function _openPosition(uint256 traderAmount, uint256 poolNumber, uint256 tokenNumber, uint256 duration)
        internal
        returns (bytes memory positionId)
    {
        PoolKey[] memory allowedPools = new PoolKey[](2);
        allowedPools[0] = key0;
        allowedPools[1] = key1;

        uint256 traderNonceBeforePositionOpen = hook.traderNonce(address(trader));
        uint256 traderBalanceBeforePositionOpen = MockERC20(Currency.unwrap(token0)).balanceOf(address(trader));
        uint256 hookBalanceBeforePositionOpen = MockERC20(Currency.unwrap(token0)).balanceOf(address(hook));

        positionId = hook.openPosition(traderAmount, allowedPools, poolNumber, tokenNumber, duration);

        uint256 traderNonceAfterPositionOpen = hook.traderNonce(address(trader));
        uint256 traderBalanceAfterPositionOpen = MockERC20(Currency.unwrap(token0)).balanceOf(address(trader));
        uint256 hookBalanceAfterPositionOpen = MockERC20(Currency.unwrap(token0)).balanceOf(address(hook));

        vm.assertEq(hookBalanceAfterPositionOpen - hookBalanceBeforePositionOpen, traderAmount, "_openPosition: E0");
        vm.assertEq(traderBalanceAfterPositionOpen, traderBalanceBeforePositionOpen - traderAmount, "_openPosition: E1");
        vm.assertTrue(traderNonceAfterPositionOpen > traderNonceBeforePositionOpen, "_openPosition: E2");

        return positionId;
    }
}
