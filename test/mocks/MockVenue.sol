// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MarketRecord} from "../../src/interfaces/IBinaryMarketsModule.sol";

contract MockOutcome6909 {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(address => mapping(address => mapping(uint256 => uint256))) public allowance;
    mapping(address => mapping(address => bool)) public isOperator;

    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[msg.sender][operator] = approved;
        return true;
    }

    function approve(address spender, uint256 id, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender][id] = amount;
        return true;
    }

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[to][id] += amount;
    }

    function burnFrom(address from, uint256 id, uint256 amount) external {
        if (!isOperator[from][msg.sender]) {
            uint256 a = allowance[from][msg.sender][id];
            require(a >= amount, "allow");
            allowance[from][msg.sender][id] = a - amount;
        }
        require(balanceOf[from][id] >= amount, "bal");
        balanceOf[from][id] -= amount;
    }
}

contract MockPool {
    IERC20 public asset;
    uint256 public scale;
    mapping(address => uint256) public escrowOf;
    mapping(uint128 => address) public orderOwner;
    mapping(uint128 => uint256) public orderEscrow;
    uint128 public nextId = 1;

    constructor(IERC20 asset_, uint256 scale_) {
        asset = asset_;
        scale = scale_;
    }

    function placeOrder(
        bool isBid,
        uint64,
        uint256 price,
        uint256 quantity,
        uint64 expireTimestampNs,
        uint8,
        uint8,
        address,
        uint96
    ) external payable returns (bool success, uint128 orderId) {
        require(expireTimestampNs != 0, "exp");
        uint256 needed = isBid ? (price * quantity) / scale : 0;
        if (isBid) {
            require(asset.transferFrom(msg.sender, address(this), needed), "pull");
            escrowOf[msg.sender] += needed;
        }
        orderId = nextId++;
        orderOwner[orderId] = msg.sender;
        orderEscrow[orderId] = needed;
        success = true;
        _afterPlace();
    }

    function _afterPlace() internal virtual {}

    function cancelOrder(uint128 orderId) external {
        address owner_ = orderOwner[orderId];
        require(owner_ == msg.sender, "own");
        uint256 amt = orderEscrow[orderId];
        orderEscrow[orderId] = 0;
        escrowOf[owner_] -= amt;
        require(asset.transfer(owner_, amt), "refund");
        delete orderOwner[orderId];
    }

    function reduceOrder(uint128 orderId, uint256) external {
        address owner_ = orderOwner[orderId];
        require(owner_ == msg.sender, "own");
        uint256 amt = orderEscrow[orderId] / 2;
        orderEscrow[orderId] -= amt;
        escrowOf[owner_] -= amt;
        require(asset.transfer(owner_, amt), "refund");
    }
}

contract MockModule {
    mapping(bytes32 => MarketRecord) internal _markets;
    IERC20 public asset;
    MockOutcome6909 public outcomes;

    constructor(IERC20 asset_, MockOutcome6909 outcomes_) {
        asset = asset_;
        outcomes = outcomes_;
    }

    function setMarket(bytes32 id, address pool, uint256 yesId, uint256 noId, uint8 status) external {
        _markets[id] = MarketRecord({market: address(this), pool: pool, yesId: yesId, noId: noId, status: status});
    }

    function markets(bytes32 marketId) external view returns (MarketRecord memory) {
        return _markets[marketId];
    }

    function mintCompleteSet(bytes32 marketId, uint256 amount) external {
        MarketRecord memory rec = _markets[marketId];
        require(rec.status == 1, "status");
        require(asset.transferFrom(msg.sender, address(this), amount), "pull");
        outcomes.mint(msg.sender, rec.yesId, amount);
        outcomes.mint(msg.sender, rec.noId, amount);
    }

    function mergeCompleteSet(bytes32 marketId, uint256 amount) external {
        MarketRecord memory rec = _markets[marketId];
        outcomes.burnFrom(msg.sender, rec.yesId, amount);
        outcomes.burnFrom(msg.sender, rec.noId, amount);
        require(asset.transfer(msg.sender, amount), "pay");
    }
}

contract MockSettlement {
    IERC20 public asset;
    MockModule public module;
    MockOutcome6909 public outcomes;

    constructor(IERC20 asset_, MockModule module_, MockOutcome6909 outcomes_) {
        asset = asset_;
        module = module_;
        outcomes = outcomes_;
    }

    function redeem(bytes32 marketId, uint8 outcomeIdx, uint256 amount) external {
        MarketRecord memory rec = module.markets(marketId);
        require(rec.status == 4 || rec.status == 5, "final");
        uint256 id = outcomeIdx == 0 ? rec.yesId : rec.noId;
        outcomes.burnFrom(msg.sender, id, amount);
        uint256 payout;
        if (rec.status == 5) {
            payout = amount / 2;
        } else {
            payout = amount;
        }
        if (payout > 0) {
            require(asset.transfer(msg.sender, payout), "pay");
        }
    }

    function fund(uint256 amount) external {
        require(asset.transferFrom(msg.sender, address(this), amount), "fund");
    }
}
