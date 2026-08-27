// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {VaultFactory} from "../src/VaultFactory.sol";

/// @notice Deploy VaultFactory. Pass CREATE3 core addresses for the target network.
/// Shannon tUSDC: 0x70a86D8842FB63C4Ad2b7cdddF530eBf1BB25d8E
/// Mainnet USDso: 0x00000022dA000002656c64D9eA6011ea952D008A
/// Core (both chains): BinaryMarketsModule 0x3ecC694Cef705358864a646142ac17A90E29e388
///                     BinarySettlement    0xbF4a49e0Dfd092e5FBE8E5761064C49533e6Ed23
///                     OutcomeToken6909    0xB52c5934113Af5c0Bb20eb3C72290C8215f755b9
contract DeployVaultFactory is Script {
    function run(address module, address settlement, address outcomeToken, address treasury)
        external
        returns (VaultFactory factory)
    {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        factory = new VaultFactory(module, settlement, outcomeToken, treasury);
        vm.stopBroadcast();
    }
}
