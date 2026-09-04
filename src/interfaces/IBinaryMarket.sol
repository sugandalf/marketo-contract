// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Per-window market. Live status is here, not on the module record.
interface IBinaryMarket {
    function status() external view returns (uint8);

    function isResolved() external view returns (bool);

    function isVoided() external view returns (bool);
}
