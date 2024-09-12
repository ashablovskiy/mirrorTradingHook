// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;
import {Currency} from "v4-core/types/Currency.sol";


interface IMirrorTradingHook {
    
    function settle(Currency currency, uint128 amount) external;
    function take(Currency currency, uint128 amount) external;
}