// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library Errors {
    error ZeroAddress();
    error OperatorExists();
    error IndexOutOfBounds();
    error InvalidAmount();
    error Unauthorized();
    error DepositCapExceeded();
    error CreatorSeedRequired();
    error InsufficientIdle();
    error InvalidMarket();
    error MarketNotTrading();
    error MarketNotFinalized();
    error InvalidExpiry();
    error TrackedMarketsCapped();
}
