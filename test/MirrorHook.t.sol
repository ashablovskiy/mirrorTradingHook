// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

// Foundry libraries
import {Test} from "forge-std/Test.sol";

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

    address public trader = address(1);

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

        // Deploy our hook
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags);
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

    function test_openPosition() external  {
        vm.startPrank(trader);
        
        // token0 = new MockERC20("Test0", "0", 18);
        // vm.etch(address(0x1111), address(token0).code);
        // token0 = MockERC20(address(0x1111));
        // token0.mint(address(this), 2 ** 128);

        MockERC20(Currency.unwrap(token0)).approve(
            address(hook),
            type(uint256).max
        );
        PoolKey[] memory allowedPools;
        allowedPools[0] = key0;
        // PoolId[] memory allowedPoolsIds;
        // allowedPoolsIds[0] = poolId0;
        hook.openPosition(1e18,allowedPools,0,0,100);
        vm.stopPrank();
    }

}