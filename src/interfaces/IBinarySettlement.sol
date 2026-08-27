// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IBinarySettlement {
    function redeem(bytes32 marketId, uint8 outcomeIdx, uint256 amount) external;
}
