// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IVaultFactory {
    function depositCapBps() external view returns (uint32);
    function owner() external view returns (address);
}
