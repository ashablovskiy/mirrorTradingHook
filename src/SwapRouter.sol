// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

// import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
// import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
// import {TickMath} from "v4-core/libraries/TickMath.sol";
// import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
// import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
// import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";

//========
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";

import {IMirrorTradingHook} from "src/Interfaces/IMirrorTradingHook.sol";


contract MirrorSwapRouter {

    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    IMirrorTradingHook public immutable hook;
    // address public hook;

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.SwapParams params;
        bytes hookData;
    }

    // ============================================================================================
    // Constructor
    // ============================================================================================
    
    constructor(IPoolManager _poolManager, IMirrorTradingHook _hook) {
        poolManager = _poolManager;
        hook = _hook;
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
    ) external returns (bytes memory) {
        (CallbackData memory data) = abi.decode(rawData, (CallbackData));
        
        BalanceDelta delta = poolManager.swap(data.key, data.params, data.hookData);

        if (data.params.zeroForOne) {
            if (delta.amount0() < 0) {
                hook.settle(data.key.currency0, uint128(-delta.amount0()));
            }
            if (delta.amount1() > 0) {
                hook.take(data.key.currency1, uint128(delta.amount1()));
            }
        } else {
            if (delta.amount1() < 0) {
                hook.settle(data.key.currency1, uint128(-delta.amount1()));
            }
            if (delta.amount0() > 0) {
                hook.take(data.key.currency0, uint128(delta.amount0()));
            }
        }
        return abi.encode(delta);
    }
}