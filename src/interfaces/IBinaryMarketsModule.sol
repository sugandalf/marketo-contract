// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Market record from BinaryMarketsModule. Pool is resolved here; never caller-supplied.
struct MarketRecord {
    address market;
    address pool;
    uint256 yesId;
    uint256 noId;
    uint8 status;
}

interface IBinaryMarketsModule {
    function markets(bytes32 marketId) external view returns (MarketRecord memory);

    function mintCompleteSet(bytes32 marketId, uint256 amount) external;

    function mergeCompleteSet(bytes32 marketId, uint256 amount) external;
}
