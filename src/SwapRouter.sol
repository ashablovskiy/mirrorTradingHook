// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";


contract MirrorSwapRouter {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;
    using LPFeeLibrary for uint24;

    IPoolManager public immutable poolManager;

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.SwapParams params;
        bytes hookData;
    }

    // ============================================================================================
    // Constructor
    // ============================================================================================
    
    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }


    // ============================================================================================
    // Router functions
    // ============================================================================================

     function swap(
        PoolKey calldata key,
        IPoolManager.SwapParams memory params,
        bytes memory hookData
    ) external returns (BalanceDelta delta) {

        delta = abi.decode(poolManager.unlock(abi.encode(CallbackData(msg.sender, key, params, hookData))),(BalanceDelta));

        return delta;
    }
     
     function unlockCallback(
        bytes calldata rawData
    ) internal returns (bytes memory) {
        (CallbackData memory data) = abi.decode(rawData, (CallbackData));
        
        BalanceDelta delta = poolManager.swap(data.key, data.params, data.hookData);

        if (data.params.zeroForOne) {
            if (delta.amount0() < 0) {
                _settle(data.key.currency0, uint128(-delta.amount0()));
            }
            if (delta.amount1() > 0) {
                _take(data.key.currency1, uint128(delta.amount1()));
            }
        } else {
            if (delta.amount1() < 0) {
                _settle(data.key.currency1, uint128(-delta.amount1()));
            }
            if (delta.amount0() > 0) {
                _take(data.key.currency0, uint128(delta.amount0()));
            }
        }
        return abi.encode(delta);
    }

    function _settle(Currency currency, uint128 amount) internal {
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    function _take(Currency currency, uint128 amount) internal {
        poolManager.take(currency, address(this), amount);
    }

    error TestRevert();
}