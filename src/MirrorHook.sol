// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

//
//                            __  __ ___ ____  ____   ___  ____    _   _  ___   ___  _  __
//                            |  \/  |_ _|  _ \|  _ \ / _ \|  _ \  | | | |/ _ \ / _ \| |/ /
//                            | |\/| || || |_) | |_) | | | | |_) | | |_| | | | | | | | ' /
//                            | |  | || ||  _ <|  _ <| |_| |  _ <  |  _  | |_| | |_| | . \
//                            |_|  |_|___|_| \_\_| \_\\___/|_| \_\ |_| |_|\___/ \___/|_|\_\
//
// =================================================================================================================
// ============================== https://github.com/ashablovskiy/mirrorTradingHook  ===============================
// =================================================================================================================

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";

/// @title Mirror Hook
/// @author Hadi https://github.com/hadiesna
/// @author Dybbuk https://github.com/ashablovskiy
/// @notice This contract holds all funds and facilitates all Copy-Trading interactions
contract MirrorTradingHook is BaseHook, ERC721 {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;
    using LPFeeLibrary for uint24;

    uint256 constant MIN_POSITION_DURATION = 86_400;
    uint24 public constant BASE_FEE = 5_000; // 0.5%
    uint24 public constant MAX_PENALTY = 200_000; // 20%
    bytes constant ZERO_BYTES = hex"00";
    bytes constant DONATE_FLAG = hex"01";
    bytes constant SWAP_FLAG = hex"02";

    struct PositionInfo {
        address trader;
        uint256 amount;
        bytes currency;
        mapping(uint256 => PoolKey) poolKeys;
        uint256 poolKeysize;
        bool isFrozen;
        uint256 startTime;
        uint256 endTime;
        uint256 lastPnlUsd;
    }

    struct SubscriptionInfo {
        bytes positionId;
        uint256 shareAmount;
        uint256 startTime;
        uint256 endTime;
        uint256 minPnlUsdToCloseAt;
    }

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.SwapParams params;
        bytes hookData;
        uint256 donationAmount0;
        uint256 donationAmount1;
    }

    mapping(address trader => uint256 nonce) public traderNonce;
    mapping(bytes positionId => PositionInfo position) public positionById;
    mapping(bytes positionId => bool) public positionIdExists;
    mapping(uint256 subscriptionId => SubscriptionInfo subscription) public subscriptionById;
    mapping(bytes positionId => uint256 balance) public subscribedBalance;
    mapping(bytes positionId => address currency) public subscriptionCurrency;
    mapping(bytes positionId => uint256 totalSupply) public totalSupply;

    uint256 public tokenIdCounter;

    // ============================================================================================
    // Constructor
    // ============================================================================================

    constructor(IPoolManager _manager) BaseHook(_manager) ERC721("MirrorPositionManager", "MirrorNFT") {}

    // ============================================================================================
    // Hook functions
    // ============================================================================================

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert DynamicFeeOnly();
        return this.beforeInitialize.selector;
    }

    event FeeApplied(address swapper, bytes positionId, uint24 fee);

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        poolManager.updateDynamicLPFee(key, BASE_FEE);

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _beforeSwap(address, PoolKey memory key, IPoolManager.SwapParams memory, bytes memory hookData)
        internal
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 fee = _getFee(hookData);
        poolManager.updateDynamicLPFee(key, fee);

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        return _afterSwap(sender, key, params, delta, hookData);
    }

    function _afterSwap(
        address,
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        BalanceDelta delta,
        bytes memory hookData
    ) internal returns (bytes4, int128) {
        if (!positionIdExists[hookData]) return (this.afterSwap.selector, 0);

        PositionInfo storage position = positionById[hookData];
        if (position.isFrozen && position.endTime > block.timestamp) revert InvalidPosition();

        // check that pool is allowed:
        bool allowed;
        uint256 poolNumber;
        for (uint256 i = 0; i < position.poolKeysize; i++) {
            if (PoolId.unwrap(position.poolKeys[i].toId()) == PoolId.unwrap(key.toId())) {
                allowed = true;
                poolNumber = i;
                break;
            }
        }
        if (!allowed) revert PoolNotAllowed();

        // check that entire trader's position is swapped
        if (!(params.amountSpecified == -int256(position.amount))) revert AmountIncorrect();

        // update PositionInfo state after swap
        positionById[hookData].amount = params.zeroForOne ? uint128(delta.amount1()) : uint128(delta.amount0());
        positionById[hookData].currency = abi.encode(poolNumber, (params.zeroForOne ? 1 : 0));

        // if fee was modified for trader's swap return it back to BASE_FEE
        poolManager.updateDynamicLPFee(key, BASE_FEE);

        // Subscriber's data modification
        uint256 mirrorAmount = subscribedBalance[hookData];
        subscribedBalance[hookData] = 0;

        if (mirrorAmount == 0) return (this.afterSwap.selector, 0);

        IPoolManager.SwapParams memory mirrorParams = IPoolManager.SwapParams({
            zeroForOne: params.zeroForOne,
            amountSpecified: -int256(mirrorAmount),
            sqrtPriceLimitX96: params.sqrtPriceLimitX96
        });

        BalanceDelta mirrorSwapDelta = poolManager.swap(key, mirrorParams, ZERO_BYTES);

        if (mirrorSwapDelta.amount0() < 0) {
            _settle(key.currency0, uint128(-mirrorSwapDelta.amount0()));
        }
        if (mirrorSwapDelta.amount1() < 0) {
            _settle(key.currency1, uint128(-mirrorSwapDelta.amount1()));
        }
        if (mirrorSwapDelta.amount0() > 0) {
            _take(key.currency0, uint128(mirrorSwapDelta.amount0()));
        }
        if (mirrorSwapDelta.amount1() > 0) {
            _take(key.currency1, uint128(mirrorSwapDelta.amount1()));
        }
        subscriptionCurrency[hookData] = getCurrency(hookData);
        subscribedBalance[hookData] =
            mirrorParams.zeroForOne ? uint128(mirrorSwapDelta.amount1()) : uint128(mirrorSwapDelta.amount0());

        return (this.afterSwap.selector, 0);
    }

    // ============================================================================================
    // Trader functions
    // ============================================================================================

    function openPosition(
        uint256 tradeAmount,
        PoolKey[] calldata allowedPools,
        uint256 poolNumber,
        uint256 tokenNumber,
        uint256 duration
    ) external returns (bytes memory positionId) {
        if (duration < MIN_POSITION_DURATION) revert InsufficientPositionDuration();
        positionId = _getPositionId(msg.sender);
        traderNonce[msg.sender]++;

        PositionInfo storage position = positionById[positionId];

        position.trader = msg.sender;
        position.amount = tradeAmount;
        position.currency = abi.encode(poolNumber, tokenNumber);
        position.startTime = block.timestamp;
        position.endTime = block.timestamp + duration;
        position.poolKeysize = allowedPools.length;
        for (uint256 i = 0; i < position.poolKeysize; i++) {
            position.poolKeys[i] = allowedPools[i];
        }

        positionIdExists[positionId] = true;

        IERC20(getCurrency(positionId)).transferFrom(msg.sender, address(this), tradeAmount);
    }

    function closePosition(bytes memory positionId) external {
        if (!positionIdExists[positionId]) revert PositionNotExists();
        if (!(positionById[positionId].trader == msg.sender)) revert NotPositionOwner();
        uint256 returnAmount;
        PositionInfo storage position = positionById[positionId];
        if (positionById[positionId].endTime < block.timestamp) {
            returnAmount = position.amount;
        } else {
            position.isFrozen = true;

            // Calculate the linear early position close penalty based on time remaining
            uint256 totalDuration = position.endTime - position.startTime;
            uint256 timeElapsed = block.timestamp - position.startTime;
            uint256 penaltyAmount =
                (position.amount * (totalDuration - timeElapsed) * MAX_PENALTY) / (totalDuration * 1_000_000);
            returnAmount = position.amount - penaltyAmount;

            // donate penalty to pool (LPs)
            (uint256 _pool, uint256 _token) = abi.decode(position.currency, (uint256, uint256));
            uint256 amount0 = (_token == 0) ? penaltyAmount : 0;
            uint256 amount1 = (_token == 1) ? penaltyAmount : 0;

            poolManager.unlock(
                abi.encode(
                    CallbackData(
                        msg.sender,
                        position.poolKeys[_pool],
                        IPoolManager.SwapParams(false, 0, 0),
                        ZERO_BYTES,
                        amount0,
                        amount1
                    ),
                    DONATE_FLAG
                )
            );
        }

        IERC20(getCurrency(positionId)).transfer(msg.sender, returnAmount);
        position.amount = 0;
    }

    function hookSwap(PoolKey calldata key, IPoolManager.SwapParams memory params, bytes memory hookData)
        external
        returns (BalanceDelta delta)
    {
        if (positionIdExists[hookData] && !(positionById[hookData].trader == msg.sender)) revert NotPositionOwner();

        return abi.decode(
            poolManager.unlock(abi.encode(CallbackData(msg.sender, key, params, hookData, 0, 0), SWAP_FLAG)),
            (BalanceDelta)
        );
    }

    // ============================================================================================
    // Subscriber functions
    // ============================================================================================
    event Subscription(
        uint256 subscriptionId,
        bytes positionId,
        uint256 shareAmount,
        uint256 startTime,
        uint256 endTime,
        uint256 totalSupply,
        uint256 subscribedBalance
    );

    function subscribe(bytes memory positionId, uint256 subscriptionAmount, uint256 endTime, uint256 minPnlUsdToCloseAt)
        external
        returns (uint256 subscriptionId)
    {
        if (!positionIdExists[positionId]) revert PositionNotExists();
        if (!(endTime > block.timestamp)) revert IncorrectEndTime();
        if (subscriptionAmount == 0) revert ZeroAmount();

        address currency = getCurrency(positionId);

        IERC20(currency).transferFrom(msg.sender, address(this), subscriptionAmount);

        subscriptionCurrency[positionId] = currency;
        uint256 shares = previewDeposit(positionId, subscriptionAmount);
        subscriptionId = tokenIdCounter;
        subscriptionById[subscriptionId] = SubscriptionInfo({
            positionId: positionId,
            shareAmount: shares,
            startTime: block.timestamp,
            endTime: endTime,
            minPnlUsdToCloseAt: minPnlUsdToCloseAt
        });

        _mint(msg.sender, tokenIdCounter);
        tokenIdCounter++;

        subscribedBalance[positionId] += subscriptionAmount;
<<<<<<< HEAD
        emit Subscription(
            subscriptionId,
            positionId,
            shares,
            block.timestamp,
            endTime,
            totalSupply[positionId],
            subscribedBalance[positionId]
        );
=======
        totalSupply[positionId] += shares;
        
>>>>>>> db0f4c74bd4bcac9495cd0b30d26ffce9648f7b2

        return subscriptionId;
    }

    function claimSubscription(uint256 subscriptionId) external {
        SubscriptionInfo storage subscription = subscriptionById[subscriptionId];
        if ((subscription.endTime > block.timestamp) && (ownerOf(subscriptionId) != msg.sender)) {
            revert IncorrectEndTime();
        }
        uint256 amount = convertSharesToCurrency(subscription.positionId, subscription.shareAmount);
        subscription.shareAmount = 0;
        address owner = ownerOf(subscriptionId);
        _burn(subscriptionId);
        IERC20(subscriptionCurrency[subscription.positionId]).transfer(owner, amount);
    }

    // ============================================================================================
    // Internal functions
    // ============================================================================================

    function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
        (CallbackData memory data, bytes memory _flag) = abi.decode(rawData, (CallbackData, bytes));

        if (keccak256(_flag) == keccak256(DONATE_FLAG)) {
            poolManager.donate(data.key, data.donationAmount0, data.donationAmount1, ZERO_BYTES);

            if (data.donationAmount0 > 0) {
                _settle(data.key.currency0, uint128(data.donationAmount0));
            }
            if (data.donationAmount1 > 0) {
                _settle(data.key.currency1, uint128(data.donationAmount1));
            }
            return ZERO_BYTES;
        } else if (keccak256(_flag) == keccak256(SWAP_FLAG)) {
            _beforeSwap(msg.sender, data.key, data.params, data.hookData);

            BalanceDelta delta = poolManager.swap(data.key, data.params, data.hookData);

            _afterSwap(msg.sender, data.key, data.params, delta, data.hookData);

            if (delta.amount0() > 0) {
                _take(data.key.currency0, uint128(delta.amount0()));
            }
            if (delta.amount1() > 0) {
                _take(data.key.currency1, uint128(delta.amount1()));
            }
            if (delta.amount0() < 0) {
                _settle(data.key.currency0, uint128(-delta.amount0()));
            }
            if (delta.amount1() < 0) {
                _settle(data.key.currency1, uint128(-delta.amount1()));
            }
            return abi.encode(delta);
        } else {
            return ZERO_BYTES;
        }
    }

    function _settle(Currency currency, uint128 amount) internal {
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    function _take(Currency currency, uint128 amount) internal {
        poolManager.take(currency, address(this), amount);
    }

    function _getPositionId(address trader) internal view returns (bytes memory) {
        return (abi.encode(trader, traderNonce[trader]));
    }

    function _getFee(bytes memory positionId) internal view returns (uint24) {
        PositionInfo storage position = positionById[positionId];
        if (!positionIdExists[positionId] || position.isFrozen || block.timestamp >= position.endTime) {
            return BASE_FEE;
        }
        uint256 lockTime = position.endTime - position.startTime;
        uint256 tresholdLockTime = 30 days;

        if (lockTime >= tresholdLockTime) {
            return 0;
        }
        uint256 feeReduction = (BASE_FEE * lockTime) / tresholdLockTime;
        return uint24(BASE_FEE - feeReduction);
    }

    // ============================================================================================
    // Helper functions
    // ============================================================================================

    function previewDeposit(bytes memory positionId, uint256 assets) public view virtual returns (uint256) {
        return (assets * (totalSupply[positionId] + 1)) / (subscribedBalance[positionId] + 1);
    }
    return (assets * supply + 1) / (subscribedBalance[positionId] + 1);
}
    function convertSharesToCurrency(bytes memory positionId, uint256 shares) public view virtual returns (uint256) {
        return (shares * (subscribedBalance[positionId] - 1)) / totalSupply[positionId] - 1;
    }

    function getSubscribedBalance(bytes calldata positionId) public view returns (uint256) {
        return subscribedBalance[positionId];
    }

    function getPositionInfo(bytes calldata positionId)
        external
        view
        returns (
            address trader,
            uint256 amount,
            bytes memory currency,
            bool isFrozen,
            uint256 startTime,
            uint256 endTime,
            uint256 lastPnlUsd
        )
    {
        PositionInfo storage position = positionById[positionId];
        return (
            position.trader,
            position.amount,
            position.currency,
            position.isFrozen,
            position.startTime,
            position.endTime,
            position.lastPnlUsd
        );
    }

    function getSubscriptionInfo(uint256 subscriptionId)
        external
        view
        returns (
            bytes memory positionId,
            address subscriber,
            uint256 amount,
            uint256 startTime,
            uint256 endTime,
            uint256 minPnlUsdToCloseAt
        )
    {
        SubscriptionInfo storage subscription = subscriptionById[subscriptionId];
        return (
            subscription.positionId,
            ownerOf(subscriptionId),
            subscription.shareAmount,
            subscription.startTime,
            subscription.endTime,
            subscription.minPnlUsdToCloseAt
        );
    }

    function getCurrency(bytes memory positionId) public view returns (address currency) {
        PositionInfo storage position = positionById[positionId];
        (uint256 _pool, uint256 _token) = abi.decode(position.currency, (uint256, uint256));
        PoolKey storage poolKey = position.poolKeys[_pool];
        currency = (_token == 0) ? Currency.unwrap(poolKey.currency0) : Currency.unwrap(poolKey.currency1);
        return currency;
    }

    // ============================================================================================
    // Errors
    // ============================================================================================

    error NotPositionOwner();
    error InvalidPosition();
    error ZeroAmount();
    error IncorrectEndTime();
    error InsufficientPositionDuration();
    error PoolNotAllowed();
    error DynamicFeeOnly();
    error PositionNotExists();
    error AmountIncorrect();
}
