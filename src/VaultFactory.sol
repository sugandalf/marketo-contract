// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BotVault} from "./BotVault.sol";
import {Errors} from "./libraries/Errors.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";

/// @title VaultFactory
/// @notice Deploys one seeded BotVault per trading operator.
contract VaultFactory is Ownable, IVaultFactory {
    using SafeERC20 for IERC20;

    uint32 public constant DEFAULT_CAP_BPS = 50_000;
    uint32 public constant MIN_CAP_BPS = 10_000;
    uint32 public constant MAX_CAP_BPS = 1_000_000;

    uint32 public override depositCapBps;
    address public immutable IMPLEMENTATION;
    address public immutable BINARY_MARKETS_MODULE;
    address public immutable BINARY_SETTLEMENT;
    address public immutable OUTCOME_TOKEN;

    mapping(address => address) public vaults;
    mapping(address => address) public operatorOf;
    address[] private _vaultList;

    event VaultCreated(
        address indexed vault, address indexed owner, address indexed operator, address asset, uint256 seed
    );
    event DepositCapBpsSet(uint32 indexed previous, uint32 indexed current);

    constructor(address module_, address settlement_, address outcomeToken_) Ownable(msg.sender) {
        if (module_ == address(0) || settlement_ == address(0) || outcomeToken_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        BINARY_MARKETS_MODULE = module_;
        BINARY_SETTLEMENT = settlement_;
        OUTCOME_TOKEN = outcomeToken_;
        depositCapBps = DEFAULT_CAP_BPS;

        BotVault impl = new BotVault();
        IMPLEMENTATION = address(impl);
    }

    function owner() public view override(Ownable, IVaultFactory) returns (address) {
        return super.owner();
    }

    function setDepositCapBps(uint32 bps) external {
        if (msg.sender != owner()) revert Errors.Unauthorized();
        if (bps < MIN_CAP_BPS || bps > MAX_CAP_BPS) revert Errors.InvalidAmount();
        uint32 prev = depositCapBps;
        depositCapBps = bps;
        emit DepositCapBpsSet(prev, bps);
    }

    function createVault(
        address operator,
        address asset,
        string calldata name_,
        string calldata symbol_,
        uint256 seedAssets
    ) external returns (address vault) {
        if (operator == address(0) || asset == address(0)) revert Errors.ZeroAddress();
        if (seedAssets == 0) revert Errors.InvalidAmount();
        if (vaults[operator] != address(0)) revert Errors.OperatorExists();

        vault = Clones.clone(IMPLEMENTATION);
        BotVault(vault)
            .initialize(
                msg.sender,
                operator,
                asset,
                address(this),
                BINARY_MARKETS_MODULE,
                BINARY_SETTLEMENT,
                OUTCOME_TOKEN,
                name_,
                symbol_
            );

        IERC20 token = IERC20(asset);
        token.safeTransferFrom(msg.sender, address(this), seedAssets);
        token.forceApprove(vault, seedAssets);
        BotVault(vault).deposit(seedAssets, msg.sender);
        token.forceApprove(vault, 0);

        vaults[operator] = vault;
        operatorOf[vault] = operator;
        _vaultList.push(vault);

        emit VaultCreated(vault, msg.sender, operator, asset, seedAssets);
    }

    function vaultCount() external view returns (uint256) {
        return _vaultList.length;
    }

    function vaultAt(uint256 index) external view returns (address) {
        if (index >= _vaultList.length) revert Errors.IndexOutOfBounds();
        return _vaultList[index];
    }
}
