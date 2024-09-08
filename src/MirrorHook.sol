// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
// import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";


//TODO: Add fee management code: trader should have reduced fee proportionally to position lock period. Hook shall recieve profit fees.

contract MirrorTradingHook is BaseHook {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;

    uint256 constant MIN_POSITION_DURATION = 86400;

    struct PositionInfo {
        address trader;
        uint256 amount;
        bytes currency; 
        // PoolId[] poolIds;
        mapping(uint => PoolKey) poolKeys; //TODO: use PoolId instead of PoolKey
        uint poolKeysize;
        bool isFrozen;
        uint256 expiry;
        uint256 lastPnlUsd; 
    }

    struct SubscriptionInfo {
        bytes positionId;
        address subscriber;
        uint256 amount;
        bytes currency; 
        uint256 expiry;
        uint256 minPnlUsdToCloseAt;
    }

    mapping(address trader => uint256 nonce) public traderNonce;
    mapping(bytes positionId => PositionInfo position) public positionById;
    mapping(bytes subscriptionId => SubscriptionInfo subscription) public subscriptionById;
    mapping(bytes positionId => mapping(address currency => uint256 balance)) public subscribedBalance;
    mapping(bytes positionId => address currency) public subscriptionCurrency;

    // ============================================================================================
    // Constructor
    // ============================================================================================
    
    constructor(IPoolManager _manager) BaseHook(_manager) {}

    // ============================================================================================
    // Hook functions
    // ============================================================================================

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata hookData
    ) external override onlyByPoolManager returns (bytes4, int128) {
        //Note: checks dublicate those implemented in executePositionSwap() in order to prevent spoofing of hookData
        if (!positionById[hookData].isFrozen && positionById[hookData].expiry > block.timestamp) revert InvalidPosition();
        if (!(positionById[hookData].trader == sender)) revert NotPositionOwner();


        uint256 mirrorAmount = subscribedBalance[hookData][subscriptionCurrency[hookData]];
        if (mirrorAmount > 0) {
            
            IPoolManager.SwapParams memory mirrorParams = IPoolManager.SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: -int256(mirrorAmount),  
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
                });

            BalanceDelta delta = _hookSwap(key, mirrorParams, "");

            int128 amount = mirrorParams.zeroForOne ? delta.amount1() : delta.amount0();
            subscribedBalance[hookData][getCurrency(hookData)] =uint128(amount);
            subscriptionCurrency[hookData] = getCurrency(hookData);

            return (this.afterSwap.selector, 0);

        } else {
            return (this.afterSwap.selector, 0);
        }
    }

    // ============================================================================================
    // Trader functions
    // ============================================================================================

    function openPosition(
        uint256 tradeAmount,
        PoolKey[] memory allowedPools,
        // PoolId[] memory allowedPoolIds,
        uint256 poolNumber, 
        uint256 tokenNumber,
        uint256 duration
    ) external returns (bytes memory positionId) {
        if (duration < MIN_POSITION_DURATION) revert InsufficientPositionDuration();
        positionId = getPositionId(msg.sender);
        traderNonce[msg.sender]++;

        PositionInfo storage position = positionById[positionId];

        position.trader = msg.sender;
        position.amount = tradeAmount;
        position.currency = abi.encode(poolNumber, tokenNumber);
        position.expiry = block.timestamp + duration;
        // position.poolIds = allowedPoolIds;

        for (uint i = 0; i < allowedPools.length; i++) {
            position.poolKeys[i] = allowedPools[i];
        }
        position.poolKeysize = allowedPools.length;
        
        IERC20(getCurrency(positionId)).transferFrom(msg.sender, address(this), tradeAmount);
    }

    function closePosition(bytes memory positionId) external {
        if (positionById[positionId].trader == msg.sender) {
        positionById[positionId].isFrozen = true;

        // TODO: Logic after position is frozen (penalties to trader applied, subscribed amounts returned back to subscribers)
        }
    }

    function executePositionSwap(
        PoolKey calldata key,
        bytes memory positionId
    ) public {
        if (!(positionById[positionId].trader == msg.sender)) revert NotPositionOwner();
        if (!positionById[positionId].isFrozen && positionById[positionId].expiry > block.timestamp) revert InvalidPosition();
        
        PositionInfo storage position = positionById[positionId];

        (uint poolNumber,uint tokenNumber) = abi.decode(position.currency, (uint, uint));
        bool zeroForOne = (tokenNumber == 0);
        int256 amountSpecified = int256(position.amount);
        if (!(amountSpecified > 0)) revert ZeroAmount();

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,  
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 
        });
        
        // TODO: check that pool is allowed

        BalanceDelta delta = _hookSwap(key, params, positionId);

        // Note: update position state (amount, currency)
        // TODO: check correctness
        int128 amount = zeroForOne ? delta.amount1() : delta.amount0(); 
        positionById[positionId].amount = uint128(amount);
        uint256 newTokenNumber = zeroForOne ? 1 : 0;
        positionById[positionId].currency = abi.encode(poolNumber, newTokenNumber);
    }

    // ============================================================================================
    // Subscriber functions
    // ============================================================================================

    function subscribe(
        bytes memory positionId,
        uint256 subscriptionAmount,
        uint256 expiry,
        uint256 minPnlUsdToCloseAt
    ) external returns (bytes memory subscriptionId) {
        if (!(expiry > block.timestamp)) revert IncorrectExpirySet();
        
        subscriptionId = getSubscriptionId(msg.sender, positionId);

        subscriptionById[subscriptionId] = SubscriptionInfo({
            positionId: positionId,
            subscriber: msg.sender,
            amount: subscriptionAmount,
            expiry: expiry,
            minPnlUsdToCloseAt: minPnlUsdToCloseAt,
            currency: positionById[positionId].currency
        });
        IERC20(getCurrency(positionId)).transferFrom(msg.sender, address(this), subscriptionAmount);

        subscribedBalance[positionId][getCurrency(positionId)] += subscriptionAmount;

        //TODO: Add logic to mint ERC4626 tokens to subscriber to represents its shares in total subscribtion amount
    }

    function terminateSubscription(bytes memory positionId) external {
        // TODO: add logic here
    }
    
    function modifySubscription(bytes memory positionId) external {
        // TODO: add logic here
    }

    // ============================================================================================
    // Helper functions
    // ============================================================================================

    function _hookSwap(
        PoolKey calldata key,
        IPoolManager.SwapParams memory params,
        bytes memory hookData
    ) internal returns (BalanceDelta) {
        
        BalanceDelta delta = poolManager.swap(key, params, hookData);

        if (params.zeroForOne) {
            if (delta.amount0() < 0) {
                _settle(key.currency0, uint128(-delta.amount0()));
            }
            if (delta.amount1() > 0) {
                _take(key.currency1, uint128(delta.amount1()));
            }
        } else {
            if (delta.amount1() < 0) {
                _settle(key.currency1, uint128(-delta.amount1()));
            }
            if (delta.amount0() > 0) {
                _take(key.currency0, uint128(delta.amount0()));
            }
        }
        return delta;
    }

    function _settle(Currency currency, uint128 amount) internal {
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    function _take(Currency currency, uint128 amount) internal {
        poolManager.take(currency, address(this), amount);
    }

    function getPositionId(address trader) public view returns (bytes memory) {
        return (abi.encode(trader, traderNonce[trader]));
    }

    function getSubscriptionId(address subscriber, bytes memory positionId) public pure returns (bytes memory) {
        return (abi.encode(subscriber, positionId));
    }

    function getCurrency(bytes memory positionId) public view returns (address currency) {
        (
            uint256 _pool,
            uint256 _token
        ) = abi.decode(positionById[positionId].currency, (uint256, uint256));
        if (_token == 0) {
            currency = Currency.unwrap(positionById[positionId].poolKeys[_pool].currency0);
        } else {
            currency = Currency.unwrap(positionById[positionId].poolKeys[_pool].currency1);
        }
        return currency;
    } 

    // ============================================================================================
    // Errors functions
    // ============================================================================================

    error NotPositionOwner();
    error InvalidPosition();
    error ZeroAmount();
    error IncorrectExpirySet(); 
    error InsufficientPositionDuration(); 
}