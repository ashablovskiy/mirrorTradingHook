// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";


interface ISwapRouter {
    
    function swap(PoolKey calldata key, IPoolManager.SwapParams memory params, bytes memory hookData) external returns (BalanceDelta delta);
}