// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOutcomeToken6909 {
    function balanceOf(address owner, uint256 id) external view returns (uint256);

    function setOperator(address operator, bool approved) external returns (bool);

    function approve(address spender, uint256 id, uint256 amount) external returns (bool);
}
