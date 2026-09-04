// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Settlement singleton address is still factory-wired. Trader redeem is
///      `IBinaryMarketsModule.redeem(operatorId, venueId, marketId, outcomeIdx, amount)`
///      with proceeds to `msg.sender` (the vault). Do not expose a `to` parameter.
interface IBinarySettlement {}
