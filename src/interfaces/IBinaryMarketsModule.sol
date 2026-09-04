// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Live BinaryMarketsModule `markets(marketId)` tuple (SDK binaryModuleReadAbi).
///      No status field — read `IBinaryMarket.status()` on `market`.
struct MarketRecord {
    uint256 oracleQuestionId;
    uint8 outcomeSlotCount;
    uint8 voidPolicy;
    address collateral;
    uint32 originOperatorId;
    bytes32 originVenueId;
    address oracleAdapter;
    address creator;
    address market;
    address pool;
    uint256 yesId;
    uint256 noId;
    uint64 tradingStart;
    uint64 expiry;
}

interface IBinaryMarketsModule {
    function markets(bytes32 marketId) external view returns (MarketRecord memory);

    function mintCompleteSet(uint32 operatorId, bytes32 venueId, bytes32 marketId, uint256 amount) external;

    function mergeCompleteSet(uint32 operatorId, bytes32 venueId, bytes32 marketId, uint256 amount) external;

    function redeem(uint32 operatorId, bytes32 venueId, bytes32 marketId, uint8 outcomeIdx, uint256 amount) external;
}
