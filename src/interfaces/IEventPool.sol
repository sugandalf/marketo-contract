// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Event-contract pool (same CLOB family as spot). Vault is msg.sender / order owner.
interface IEventPool {
    function placeOrder(
        bool isBid,
        uint64 userData,
        uint256 price,
        uint256 quantity,
        uint64 expireTimestampNs,
        uint8 orderType,
        uint8 selfMatchingOption,
        address builder,
        uint96 builderFeeBpsTimes1k
    ) external payable returns (bool success, uint128 orderId);

    function cancelOrder(uint128 orderId) external;

    function reduceOrder(uint128 orderId, uint256 quantity) external;

    function escrowOf(address trader) external view returns (uint256);
}
