// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Binary event-contract pool. Vault is msg.sender / order owner.
///      Generic spot `placeOrder` reverts `UseBinaryPlacement` on this surface.
interface IEventPool {
    function placeBinaryOrder(
        uint8 kind,
        uint256 price,
        uint256 quantity,
        uint64 expireTimestampNs,
        uint8 orderType,
        uint8 selfMatchingOption,
        address builder,
        uint96 builderFeeBpsTimes1k,
        uint64 userData
    ) external payable returns (bool success, uint128 orderId);

    function cancelOrder(uint128 orderId) external;

    function reduceOrder(uint128 orderId, uint256 newQuantityRemaining) external;

    function marketExpiryNs() external view returns (uint64);

    function getWithdrawableBalance(address owner, address token) external view returns (uint256);

    function withdraw(address token, uint256 amount) external;
}
