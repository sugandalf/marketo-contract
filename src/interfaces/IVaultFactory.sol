// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IVaultFactory {
    function depositCapBps() external view returns (uint32);
    function owner() external view returns (address);
    function treasury() external view returns (address);
    function protocolFeeBps() external view returns (uint32);
    function maxPerformanceFeeBps() external view returns (uint32);
}
