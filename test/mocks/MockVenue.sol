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

contract MockMarket {
    uint8 public status = 1;

    function setStatus(uint8 s) external {
        status = s;
    }

    function isResolved() external view returns (bool) {
        return status == 4;
    }

    function isVoided() external view returns (bool) {
        return status == 5;
    }
}

contract MockPool {
    IERC20 public asset;
    uint256 public scale;
    uint64 public marketExpiryNs = type(uint64).max;
    mapping(address => uint256) public escrowOfUser;
    mapping(address => mapping(address => uint256)) internal _withdrawable;
    mapping(uint128 => address) public orderOwner;
    mapping(uint128 => uint256) public orderEscrow;
    mapping(uint128 => uint256) public orderQty;
    mapping(uint128 => uint256) public orderPrice;
    uint128 public nextId = 1;

    constructor(IERC20 asset_, uint256 scale_) {
        asset = asset_;
        scale = scale_;
    }

    function setMarketExpiryNs(uint64 ns) external {
        marketExpiryNs = ns;
    }

    function placeBinaryOrder(
        uint8 kind,
        uint256 price,
        uint256 quantity,
        uint64 expireTimestampNs,
        uint8,
        uint8,
        address,
        uint96,
        uint64
    ) external payable returns (bool success, uint128 orderId) {
        require(expireTimestampNs != 0 && expireTimestampNs <= marketExpiryNs, "exp");
        bool isBuy = kind == 0 || kind == 2;
        uint256 needed = isBuy ? (price * quantity) / scale : 0;
        if (isBuy) {
            require(asset.transferFrom(msg.sender, address(this), needed), "pull");
            escrowOfUser[msg.sender] += needed;
        }
        orderId = nextId++;
        orderOwner[orderId] = msg.sender;
        orderEscrow[orderId] = needed;
        orderQty[orderId] = quantity;
        orderPrice[orderId] = price;
        success = true;
        _afterPlace();
    }

    function _afterPlace() internal virtual {}

    function cancelOrder(uint128 orderId) external {
        address owner_ = orderOwner[orderId];
        require(owner_ == msg.sender, "own");
        uint256 amt = orderEscrow[orderId];
        orderEscrow[orderId] = 0;
        orderQty[orderId] = 0;
        escrowOfUser[owner_] -= amt;
        require(asset.transfer(owner_, amt), "refund");
        delete orderOwner[orderId];
    }

    function reduceOrder(uint128 orderId, uint256 newQuantityRemaining) external {
        address owner_ = orderOwner[orderId];
        require(owner_ == msg.sender, "own");
        require(newQuantityRemaining != 0 && newQuantityRemaining < orderQty[orderId], "qty");
        uint256 oldEscrow = orderEscrow[orderId];
        uint256 newEscrow = (orderPrice[orderId] * newQuantityRemaining) / scale;
        uint256 refund = oldEscrow > newEscrow ? oldEscrow - newEscrow : 0;
        orderQty[orderId] = newQuantityRemaining;
        orderEscrow[orderId] = newEscrow;
        escrowOfUser[owner_] -= refund;
        require(asset.transfer(owner_, refund), "refund");
    }

    function getWithdrawableBalance(address owner_, address token) external view returns (uint256) {
        return _withdrawable[owner_][token];
    }

    function setWithdrawable(address owner_, address token, uint256 amount) external {
        _withdrawable[owner_][token] = amount;
    }

    function withdraw(address token, uint256 amount) external {
        uint256 bal = _withdrawable[msg.sender][token];
        require(bal >= amount, "wd");
        _withdrawable[msg.sender][token] = bal - amount;
        require(IERC20(token).transfer(msg.sender, amount), "pay");
    }
}

contract MockModule {
    mapping(bytes32 => MarketRecord) internal _markets;
    mapping(bytes32 => MockMarket) public mockMarkets;
    IERC20 public asset;
    MockOutcome6909 public outcomes;
    uint32 public originOperatorId = 1;
    bytes32 public originVenueId = bytes32(uint256(1));

    constructor(IERC20 asset_, MockOutcome6909 outcomes_) {
        asset = asset_;
        outcomes = outcomes_;
    }

    function setMarket(bytes32 id, address pool, uint256 yesId, uint256 noId, uint8 status) external {
        MockMarket m = mockMarkets[id];
        if (address(m) == address(0)) {
            m = new MockMarket();
            mockMarkets[id] = m;
        }
        m.setStatus(status);
        _markets[id] = MarketRecord({
            oracleQuestionId: 1,
            outcomeSlotCount: 2,
            voidPolicy: 0,
            collateral: address(asset),
            originOperatorId: originOperatorId,
            originVenueId: originVenueId,
            oracleAdapter: address(0),
            creator: address(this),
            market: address(m),
            pool: pool,
            yesId: yesId,
            noId: noId,
            tradingStart: 0,
            expiry: type(uint64).max
        });
    }

    function setCollateral(bytes32 id, address collateral) external {
        _markets[id].collateral = collateral;
    }

    function markets(bytes32 marketId) external view returns (MarketRecord memory) {
        return _markets[marketId];
    }

    function mintCompleteSet(uint32, bytes32, bytes32 marketId, uint256 amount) external {
        MarketRecord memory rec = _markets[marketId];
        require(MockMarket(rec.market).status() == 1, "status");
        require(asset.transferFrom(msg.sender, address(this), amount), "pull");
        outcomes.mint(msg.sender, rec.yesId, amount);
        outcomes.mint(msg.sender, rec.noId, amount);
    }

    function mergeCompleteSet(uint32, bytes32, bytes32 marketId, uint256 amount) external {
        MarketRecord memory rec = _markets[marketId];
        outcomes.burnFrom(msg.sender, rec.yesId, amount);
        outcomes.burnFrom(msg.sender, rec.noId, amount);
        require(asset.transfer(msg.sender, amount), "pay");
    }

    function redeem(uint32, bytes32, bytes32 marketId, uint8 outcomeIdx, uint256 amount) external {
        MarketRecord memory rec = _markets[marketId];
        uint8 st = MockMarket(rec.market).status();
        require(st == 4 || st == 5, "final");
        uint256 id = outcomeIdx == 0 ? rec.yesId : rec.noId;
        outcomes.burnFrom(msg.sender, id, amount);
        uint256 payout = st == 5 ? amount / 2 : amount;
        if (payout > 0) {
            require(asset.transfer(msg.sender, payout), "pay");
        }
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

    function fund(uint256 amount) external {
        require(asset.transferFrom(msg.sender, address(this), amount), "fund");
    }
}
