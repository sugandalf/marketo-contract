// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockAsset is ERC20 {
    constructor() ERC20("Mock USDso", "mUSDso") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
