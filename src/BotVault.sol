// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {Errors} from "./libraries/Errors.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IBinaryMarketsModule, MarketRecord} from "./interfaces/IBinaryMarketsModule.sol";
import {IEventPool} from "./interfaces/IEventPool.sol";
import {IBinarySettlement} from "./interfaces/IBinarySettlement.sol";
import {IOutcomeToken6909} from "./interfaces/IOutcomeToken6909.sol";

/// @title BotVault
/// @notice ERC-4626 vault that is the DreamDEX event-contract trading identity for one bot.
contract BotVault is
    Initializable,
    ERC4626Upgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC165Upgradeable
{
    using SafeERC20 for IERC20;

    uint8 private constant _DECIMALS_OFFSET = 3;
    uint8 public constant STATUS_TRADING = 1;
    uint8 public constant STATUS_LOCKED = 2;
    uint8 public constant STATUS_RESOLVED = 4;
    uint8 public constant STATUS_VOIDED = 5;
    uint256 public constant MAX_TRACKED_MARKETS = 32;
    bytes4 public constant IERC7575_SHARE_ID = 0x9f40b779; // share()
    bytes4 public constant IERC7540_OPERATOR_ID = 0xe3bc4e4c; // setOperator + isOperator

    enum Side {
        BUY_YES,
        SELL_YES,
        BUY_NO,
        SELL_NO
    }

    struct RedeemRequest {
        address controller;
        uint256 shares;
    }

    IVaultFactory public factory;
    address public tradingOperator;
    address public binaryMarketsModule;
    address public binarySettlement;
    address public outcomeToken;

    mapping(address => uint256) public principalOf;
    uint256 public totalPrincipal;

    mapping(address => uint256) public lockedShares;
    mapping(address => uint256) public claimableAssets;
    mapping(address => uint256) public claimableShares;
    mapping(address => mapping(address => bool)) private _claimOperator;
    RedeemRequest[] private _redeemQueue;
    uint256 private _redeemHead;
    uint256 public reservedForClaims;

    bytes32[] private _trackedMarkets;
    mapping(bytes32 => uint256) private _trackedIndex; // 1-based
    mapping(bytes32 => uint256) public escrowByMarket;
    mapping(uint128 => bytes32) public orderMarket;

    event TradingOperatorSet(address indexed previous, address indexed current);
    event OperatorSet(address indexed controller, address indexed operator, bool approved);
    event RedeemRequestQueued(address indexed controller, address indexed owner, uint256 shares);

    modifier onlyTradingOperator() {
        _onlyTradingOperator();
        _;
    }

    function _onlyTradingOperator() internal view {
        if (msg.sender != tradingOperator) revert Errors.Unauthorized();
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address operator_,
        address asset_,
        address factory_,
        address module_,
        address settlement_,
        address outcomeToken_,
        string memory name_,
        string memory symbol_
    ) external initializer {
        if (
            owner_ == address(0) || operator_ == address(0) || asset_ == address(0) || factory_ == address(0)
                || module_ == address(0) || settlement_ == address(0) || outcomeToken_ == address(0)
        ) {
            revert Errors.ZeroAddress();
        }
        __ERC20_init(name_, symbol_);
        __ERC4626_init(IERC20(asset_));
        __Ownable_init(owner_);
        __ReentrancyGuard_init();
        __ERC165_init();
        factory = IVaultFactory(factory_);
        tradingOperator = operator_;
        binaryMarketsModule = module_;
        binarySettlement = settlement_;
        outcomeToken = outcomeToken_;
        emit TradingOperatorSet(address(0), operator_);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return _DECIMALS_OFFSET;
    }

    function share() external view returns (address) {
        return address(this);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165Upgradeable) returns (bool) {
        return interfaceId == type(IERC4626).interfaceId || interfaceId == IERC7575_SHARE_ID
            || interfaceId == IERC7540_OPERATOR_ID || super.supportsInterface(interfaceId);
    }

    function creatorPrincipal() public view returns (uint256) {
        return principalOf[owner()];
    }

    function _depositCap() internal view returns (uint256) {
        uint256 seed = principalOf[owner()];
        return seed * uint256(factory.depositCapBps()) / 10_000;
    }

    function _idle() internal view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function _availableIdle() internal view returns (uint256) {
        uint256 idle = _idle();
        uint256 reserved = reservedForClaims;
        return idle > reserved ? idle - reserved : 0;
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        if (receiver == owner()) return type(uint256).max;
        uint256 cap = _depositCap();
        uint256 tot = totalPrincipal;
        return tot >= cap ? 0 : cap - tot;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (maxAssets == type(uint256).max) return type(uint256).max;
        return convertToShares(maxAssets);
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        uint256 unlocked = _unlockedShares(owner_);
        uint256 byShares = convertToAssets(unlocked);
        uint256 idle = _availableIdle();
        return byShares < idle ? byShares : idle;
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        uint256 unlocked = _unlockedShares(owner_);
        uint256 byIdle = convertToShares(_availableIdle());
        return unlocked < byIdle ? unlocked : byIdle;
    }

    function totalAssets() public view override returns (uint256) {
        uint256 idle = _idle();
        uint256 escrow;
        uint256 inventory;
        uint256 n = _trackedMarkets.length;
        IBinaryMarketsModule module = IBinaryMarketsModule(binaryMarketsModule);
        IOutcomeToken6909 tok = IOutcomeToken6909(outcomeToken);
        for (uint256 i; i < n; ++i) {
            bytes32 id = _trackedMarkets[i];
            uint256 liveEscrow = escrowByMarket[id];
            try module.markets(id) returns (MarketRecord memory rec) {
                if (rec.pool != address(0)) {
                    try IEventPool(rec.pool).escrowOf(address(this)) returns (uint256 e) {
                        liveEscrow = e;
                    } catch {}
                }
                uint256 up;
                uint256 down;
                try tok.balanceOf(address(this), rec.yesId) returns (uint256 u) {
                    up = u;
                } catch {}
                try tok.balanceOf(address(this), rec.noId) returns (uint256 d) {
                    down = d;
                } catch {}
                inventory += up > down ? up : down;
            } catch {}
            escrow += liveEscrow;
        }
        return idle + escrow + inventory;
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        if (assets == 0) revert Errors.InvalidAmount();
        if (assets > maxDeposit(receiver)) revert Errors.DepositCapExceeded();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        if (shares == 0) revert Errors.InvalidAmount();
        uint256 assets = previewMint(shares);
        if (assets > maxDeposit(receiver)) revert Errors.DepositCapExceeded();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner_) public override nonReentrant returns (uint256) {
        if (assets == 0) revert Errors.InvalidAmount();
        if (_canClaim(owner_)) {
            return _claimAssets(assets, receiver, owner_);
        }
        if (assets > maxWithdraw(owner_)) revert Errors.InvalidAmount();
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_) public override nonReentrant returns (uint256) {
        if (shares == 0) revert Errors.InvalidAmount();
        if (_canClaim(owner_)) {
            uint256 assets = previewRedeem(shares);
            return _claimAssets(assets, receiver, owner_);
        }
        if (shares > maxRedeem(owner_)) revert Errors.InvalidAmount();
        return super.redeem(shares, receiver, owner_);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        _addPrincipal(receiver, assets);
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
    {
        super._withdraw(caller, receiver, owner_, assets, shares);
        _reducePrincipal(owner_, shares, balanceOf(owner_) + shares);
        _assertCreatorSeed();
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && from != to && value != 0) {
            uint256 fromBal = balanceOf(from);
            uint256 moved = fromBal == 0 ? 0 : principalOf[from] * value / fromBal;
            principalOf[from] -= moved;
            principalOf[to] += moved;
        }
        super._update(from, to, value);
        if (from != address(0) && to != address(0) && from != to) {
            _assertCreatorSeed();
        }
    }

    function _addPrincipal(address account, uint256 assets) internal {
        principalOf[account] += assets;
        totalPrincipal += assets;
    }

    function _reducePrincipal(address account, uint256 sharesOut, uint256 sharesBefore) internal {
        if (sharesBefore == 0) return;
        uint256 p = principalOf[account];
        uint256 out = p * sharesOut / sharesBefore;
        principalOf[account] = p - out;
        totalPrincipal -= out;
    }

    function _assertCreatorSeed() internal view {
        uint256 cap = _depositCap();
        if (totalPrincipal > cap) revert Errors.CreatorSeedRequired();
    }

    /// @dev True if burning `sharesOut` from `account` would leave outstanding principal above the live cap.
    function _wouldBreakCreatorSeed(address account, uint256 sharesOut) internal view returns (bool) {
        uint256 bal = balanceOf(account);
        if (bal == 0 || sharesOut == 0) return false;
        uint256 out = principalOf[account] * sharesOut / bal;
        uint256 newCreator = principalOf[owner()];
        if (account == owner()) newCreator -= out;
        uint256 newTotal = totalPrincipal - out;
        return newTotal > newCreator * uint256(factory.depositCapBps()) / 10_000;
    }

    function _unlockedShares(address owner_) internal view returns (uint256) {
        uint256 bal = balanceOf(owner_);
        uint256 locked = lockedShares[owner_];
        return bal > locked ? bal - locked : 0;
    }

    function setTradingOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert Errors.ZeroAddress();
        address prev = tradingOperator;
        tradingOperator = newOperator;
        emit TradingOperatorSet(prev, newOperator);
    }

    function setOperator(address operator, bool approved) external returns (bool) {
        if (operator == address(0)) revert Errors.ZeroAddress();
        _claimOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    function isOperator(address controller, address operator) public view returns (bool) {
        return _claimOperator[controller][operator];
    }

    function _isAuthorized(address owner_) internal view returns (bool) {
        return msg.sender == owner_ || isOperator(owner_, msg.sender);
    }

    function requestRedeem(uint256 shares, address controller, address owner_)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        if (shares == 0) revert Errors.InvalidAmount();
        if (controller == address(0) || owner_ == address(0)) revert Errors.ZeroAddress();
        if (!_isAuthorized(owner_)) revert Errors.Unauthorized();
        if (shares > _unlockedShares(owner_)) revert Errors.InvalidAmount();
        if (_wouldBreakCreatorSeed(owner_, shares)) revert Errors.CreatorSeedRequired();
        lockedShares[owner_] += shares;
        _redeemQueue.push(RedeemRequest({controller: controller, shares: shares}));
        emit RedeemRequestQueued(controller, owner_, shares);
        _allocateIdle();
        return _redeemQueue.length;
    }

    function pendingRedeemRequest(uint256, address controller) external view returns (uint256 pending) {
        uint256 n = _redeemQueue.length;
        for (uint256 i = _redeemHead; i < n; ++i) {
            if (_redeemQueue[i].controller == controller) pending += _redeemQueue[i].shares;
        }
    }

    function claimableRedeemRequest(uint256, address controller) external view returns (uint256) {
        return claimableShares[controller];
    }

    function allocateIdle() external nonReentrant {
        _allocateIdle();
    }

    function _allocateIdle() internal {
        uint256 available = _availableIdle();
        uint256 n = _redeemQueue.length;
        while (_redeemHead < n && available > 0) {
            RedeemRequest storage req = _redeemQueue[_redeemHead];
            if (req.shares == 0) {
                ++_redeemHead;
                continue;
            }
            uint256 want = convertToAssets(req.shares);
            uint256 give = want < available ? want : available;
            uint256 giveShares = convertToShares(give);
            if (giveShares > req.shares) giveShares = req.shares;
            if (giveShares == 0 || give == 0) break;
            req.shares -= giveShares;
            claimableShares[req.controller] += giveShares;
            claimableAssets[req.controller] += give;
            reservedForClaims += give;
            available -= give;
            if (req.shares == 0) ++_redeemHead;
        }
    }

    function _canClaim(address owner_) internal view returns (bool) {
        return claimableAssets[owner_] > 0 && _isAuthorized(owner_);
    }

    function _claimAssets(uint256 assets, address receiver, address owner_) internal returns (uint256 shares) {
        uint256 claimable = claimableAssets[owner_];
        if (assets > claimable) revert Errors.InvalidAmount();
        shares = claimableShares[owner_] * assets / claimable;
        if (shares == 0) revert Errors.InvalidAmount();
        claimableAssets[owner_] -= assets;
        claimableShares[owner_] -= shares;
        lockedShares[owner_] -= shares;
        reservedForClaims -= assets;
        super._withdraw(msg.sender, receiver, owner_, assets, shares);
        _reducePrincipal(owner_, shares, balanceOf(owner_) + shares);
        _assertCreatorSeed();
    }

    function _market(bytes32 marketId) internal view returns (MarketRecord memory rec) {
        rec = IBinaryMarketsModule(binaryMarketsModule).markets(marketId);
        if (rec.pool == address(0)) revert Errors.InvalidMarket();
    }

    function _trackMarket(bytes32 marketId) internal {
        if (_trackedIndex[marketId] != 0) return;
        if (_trackedMarkets.length >= MAX_TRACKED_MARKETS) revert Errors.TrackedMarketsCapped();
        _trackedMarkets.push(marketId);
        _trackedIndex[marketId] = _trackedMarkets.length;
    }

    function forgetMarket(bytes32 marketId) external onlyTradingOperator {
        MarketRecord memory rec = _market(marketId);
        uint256 up = IOutcomeToken6909(outcomeToken).balanceOf(address(this), rec.yesId);
        uint256 down = IOutcomeToken6909(outcomeToken).balanceOf(address(this), rec.noId);
        if (escrowByMarket[marketId] != 0 || up != 0 || down != 0) revert Errors.InvalidAmount();
        uint256 idx = _trackedIndex[marketId];
        if (idx == 0) return;
        uint256 last = _trackedMarkets.length;
        bytes32 lastId = _trackedMarkets[last - 1];
        _trackedMarkets[idx - 1] = lastId;
        _trackedIndex[lastId] = idx;
        _trackedMarkets.pop();
        delete _trackedIndex[marketId];
    }

    function syncMarket(bytes32 marketId) external {
        MarketRecord memory rec = _market(marketId);
        _trackMarket(marketId);
        try IEventPool(rec.pool).escrowOf(address(this)) returns (uint256 e) {
            escrowByMarket[marketId] = e;
        } catch {}
    }

    function _approveExact(address spender, uint256 amount) internal {
        if (
            spender != binaryMarketsModule && spender != binarySettlement && spender != outcomeToken
                && !_isResolvedPool(spender)
        ) {
            revert Errors.Unauthorized();
        }
        IERC20 token = IERC20(asset());
        token.forceApprove(spender, 0);
        if (amount != 0) token.forceApprove(spender, amount);
    }

    function _isResolvedPool(address pool) internal view returns (bool) {
        uint256 n = _trackedMarkets.length;
        IBinaryMarketsModule module = IBinaryMarketsModule(binaryMarketsModule);
        for (uint256 i; i < n; ++i) {
            try module.markets(_trackedMarkets[i]) returns (MarketRecord memory rec) {
                if (rec.pool == pool) return true;
            } catch {}
        }
        return false;
    }

    function _isBuy(Side side) internal pure returns (bool) {
        return side == Side.BUY_YES || side == Side.BUY_NO;
    }

    function _buyNotional(uint256 price, uint256 quantity) internal view returns (uint256) {
        uint256 scale = 10 ** IERC20Metadata(asset()).decimals();
        return (price * quantity) / scale;
    }

    function placeOrder(
        bytes32 marketId,
        Side side,
        uint256 price,
        uint256 quantity,
        uint64 expireTimestampNs,
        uint8 orderType
    ) external onlyTradingOperator nonReentrant returns (uint128 orderId) {
        if (quantity == 0 || price == 0) revert Errors.InvalidAmount();
        if (expireTimestampNs == 0) revert Errors.InvalidExpiry();
        MarketRecord memory rec = _market(marketId);
        if (rec.status != STATUS_TRADING) revert Errors.MarketNotTrading();
        _trackMarket(marketId);

        uint256 before = _idle();
        if (_isBuy(side)) {
            uint256 needed = _buyNotional(price, quantity);
            if (needed == 0 || before < needed) revert Errors.InsufficientIdle();
            _approveExact(rec.pool, needed);
        }

        bool isBid = _isBuy(side);
        (bool success, uint128 id) =
            IEventPool(rec.pool).placeOrder(isBid, 0, price, quantity, expireTimestampNs, orderType, 0, address(0), 0);
        if (_isBuy(side)) _approveExact(rec.pool, 0);
        if (!success) revert Errors.InvalidAmount();
        orderId = id;
        orderMarket[id] = marketId;

        uint256 afterBal = _idle();
        if (before > afterBal) {
            escrowByMarket[marketId] += before - afterBal;
        } else if (afterBal > before) {
            uint256 refund = afterBal - before;
            escrowByMarket[marketId] = escrowByMarket[marketId] > refund ? escrowByMarket[marketId] - refund : 0;
        }
    }

    function cancelOrder(bytes32 marketId, uint128 orderId) external onlyTradingOperator nonReentrant {
        MarketRecord memory rec = _market(marketId);
        uint256 before = _idle();
        IEventPool(rec.pool).cancelOrder(orderId);
        uint256 afterBal = _idle();
        if (afterBal > before) {
            uint256 refund = afterBal - before;
            escrowByMarket[marketId] = escrowByMarket[marketId] > refund ? escrowByMarket[marketId] - refund : 0;
        }
        delete orderMarket[orderId];
    }

    function reduceOrder(bytes32 marketId, uint128 orderId, uint256 quantity)
        external
        onlyTradingOperator
        nonReentrant
    {
        if (quantity == 0) revert Errors.InvalidAmount();
        MarketRecord memory rec = _market(marketId);
        uint256 before = _idle();
        IEventPool(rec.pool).reduceOrder(orderId, quantity);
        uint256 afterBal = _idle();
        if (afterBal > before) {
            uint256 refund = afterBal - before;
            escrowByMarket[marketId] = escrowByMarket[marketId] > refund ? escrowByMarket[marketId] - refund : 0;
        }
    }

    function mintCompleteSet(bytes32 marketId, uint256 amount) external onlyTradingOperator nonReentrant {
        if (amount == 0) revert Errors.InvalidAmount();
        MarketRecord memory rec = _market(marketId);
        if (rec.status != STATUS_TRADING) revert Errors.MarketNotTrading();
        if (_idle() < amount) revert Errors.InsufficientIdle();
        _trackMarket(marketId);
        _approveExact(binaryMarketsModule, amount);
        IBinaryMarketsModule(binaryMarketsModule).mintCompleteSet(marketId, amount);
        _approveExact(binaryMarketsModule, 0);
    }

    function mergeCompleteSet(bytes32 marketId, uint256 amount) external onlyTradingOperator nonReentrant {
        if (amount == 0) revert Errors.InvalidAmount();
        MarketRecord memory rec = _market(marketId);
        if (rec.status != STATUS_TRADING) revert Errors.MarketNotTrading();
        IOutcomeToken6909 tok = IOutcomeToken6909(outcomeToken);
        if (tok.balanceOf(address(this), rec.yesId) < amount || tok.balanceOf(address(this), rec.noId) < amount) {
            revert Errors.InvalidAmount();
        }
        tok.approve(binaryMarketsModule, rec.yesId, amount);
        tok.approve(binaryMarketsModule, rec.noId, amount);
        IBinaryMarketsModule(binaryMarketsModule).mergeCompleteSet(marketId, amount);
        tok.approve(binaryMarketsModule, rec.yesId, 0);
        tok.approve(binaryMarketsModule, rec.noId, 0);
    }

    function redeem(bytes32 marketId, uint8 outcomeIdx, uint256 amount) external onlyTradingOperator nonReentrant {
        if (amount == 0) revert Errors.InvalidAmount();
        MarketRecord memory rec = _market(marketId);
        if (rec.status != STATUS_RESOLVED && rec.status != STATUS_VOIDED) {
            revert Errors.MarketNotFinalized();
        }
        uint256 id = outcomeIdx == 0 ? rec.yesId : rec.noId;
        IOutcomeToken6909 tok = IOutcomeToken6909(outcomeToken);
        if (tok.balanceOf(address(this), id) < amount) revert Errors.InvalidAmount();
        tok.approve(binarySettlement, id, amount);
        IBinarySettlement(binarySettlement).redeem(marketId, outcomeIdx, amount);
        tok.approve(binarySettlement, id, 0);
    }

    function trackedMarketCount() external view returns (uint256) {
        return _trackedMarkets.length;
    }
}
