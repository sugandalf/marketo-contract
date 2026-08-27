// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BotVault} from "../src/BotVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {VaultTestBase} from "./VaultCore.t.sol";
import {MockAsset} from "./mocks/MockAsset.sol";
import {MockOutcome6909, MockPool, MockModule, MockSettlement} from "./mocks/MockVenue.sol";

contract TradingTest is VaultTestBase {
    BotVault internal vault;

    function setUp() public {
        _deployFactory();
        vault = _createVault(SEED);
        asset.mint(address(settlement), 100 ether);
        asset.mint(address(module), 100 ether);
    }

    function test_placeThenCancelRefundsVault() public {
        uint256 price = 0.4e18;
        uint256 qty = 5 ether;
        uint256 needed = price * qty / SCALE;
        vm.prank(operator);
        uint128 id = vault.placeOrder(MARKET_ID, BotVault.Side.BUY_YES, price, qty, 1_000_000_000, 0);
        assertEq(asset.balanceOf(address(vault)), SEED - needed);
        assertEq(asset.balanceOf(operator), 0);
        assertGt(vault.totalAssets(), asset.balanceOf(address(vault)));
        assertLe(vault.maxWithdraw(creator), asset.balanceOf(address(vault)));
        vm.prank(creator);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.withdraw(SEED, creator, creator);

        vm.prank(operator);
        vault.cancelOrder(MARKET_ID, id);
        assertEq(asset.balanceOf(address(vault)), SEED);
    }

    function test_mintMerge() public {
        vm.prank(operator);
        vault.mintCompleteSet(MARKET_ID, 2 ether);
        assertEq(outcomes.balanceOf(address(vault), YES_ID), 2 ether);
        assertEq(outcomes.balanceOf(address(vault), NO_ID), 2 ether);
        vm.prank(operator);
        vault.mergeCompleteSet(MARKET_ID, 2 ether);
        assertEq(asset.balanceOf(address(vault)), SEED);
    }

    function test_redeemAfterResolved() public {
        vm.prank(operator);
        vault.mintCompleteSet(MARKET_ID, 2 ether);
        module.setMarket(MARKET_ID, address(pool), YES_ID, NO_ID, 4);
        uint256 before = asset.balanceOf(address(vault));
        vm.prank(operator);
        vault.redeem(MARKET_ID, 0, 2 ether);
        assertEq(asset.balanceOf(address(vault)), before + 2 ether);
    }

    function test_redeemVoidedHalf() public {
        vm.prank(operator);
        vault.mintCompleteSet(MARKET_ID, 2 ether);
        module.setMarket(MARKET_ID, address(pool), YES_ID, NO_ID, 5);
        uint256 before = asset.balanceOf(address(vault));
        vm.prank(operator);
        vault.redeem(MARKET_ID, 0, 2 ether);
        assertEq(asset.balanceOf(address(vault)), before + 1 ether);
    }

    function test_nonOperatorReverts() public {
        vm.prank(stranger);
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.placeOrder(MARKET_ID, BotVault.Side.BUY_YES, 0.5e18, 1 ether, 1, 0);
        vm.prank(stranger);
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.cancelOrder(MARKET_ID, 1);
        vm.prank(stranger);
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.reduceOrder(MARKET_ID, 1, 1);
        vm.prank(stranger);
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.mintCompleteSet(MARKET_ID, 1);
        vm.prank(stranger);
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.mergeCompleteSet(MARKET_ID, 1);
        vm.prank(stranger);
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.redeem(MARKET_ID, 0, 1);
    }

    function test_underfundedBuyReverts() public {
        uint256 idle = asset.balanceOf(address(vault));
        vm.prank(operator);
        vm.expectRevert(Errors.InsufficientIdle.selector);
        vault.placeOrder(MARKET_ID, BotVault.Side.BUY_YES, 1e18, idle + 1 ether, 1, 0);
        assertEq(asset.balanceOf(address(vault)), idle);
        asset.mint(operator, 100 ether);
        vm.prank(operator);
        vm.expectRevert(Errors.InsufficientIdle.selector);
        vault.placeOrder(MARKET_ID, BotVault.Side.BUY_YES, 1e18, idle + 1 ether, 1, 0);
        assertEq(asset.balanceOf(operator), 100 ether);
    }

    function test_unknownMarketReverts() public {
        vm.prank(operator);
        vm.expectRevert(Errors.InvalidMarket.selector);
        vault.placeOrder(keccak256("nope"), BotVault.Side.BUY_YES, 1e18, 1 ether, 1, 0);
    }

    function test_placeWhenNotTrading() public {
        module.setMarket(MARKET_ID, address(pool), YES_ID, NO_ID, 2);
        vm.prank(operator);
        vm.expectRevert(Errors.MarketNotTrading.selector);
        vault.placeOrder(MARKET_ID, BotVault.Side.BUY_YES, 1e18, 1 ether, 1, 0);
    }

    function test_redeemWhenNotFinalized() public {
        vm.prank(operator);
        vm.expectRevert(Errors.MarketNotFinalized.selector);
        vault.redeem(MARKET_ID, 0, 1);
    }

    function test_zeroExpiryReverts() public {
        vm.prank(operator);
        vm.expectRevert(Errors.InvalidExpiry.selector);
        vault.placeOrder(MARKET_ID, BotVault.Side.BUY_YES, 1e18, 1 ether, 0, 0);
    }

    function test_syncMarketUnknownReverts() public {
        vm.expectRevert(Errors.InvalidMarket.selector);
        vault.syncMarket(keccak256("nope"));
    }

    function test_rotateOperator() public {
        address op2 = makeAddr("op2");
        vm.prank(creator);
        vault.setTradingOperator(op2);
        vm.prank(operator);
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.placeOrder(MARKET_ID, BotVault.Side.BUY_YES, 0.4e18, 1 ether, 1, 0);
        vm.prank(op2);
        vault.placeOrder(MARKET_ID, BotVault.Side.BUY_YES, 0.4e18, 1 ether, 1, 0);
    }

    function test_strangerCannotWithdraw() public {
        vm.prank(stranger);
        vm.expectRevert();
        vault.withdraw(1, stranger, creator);
    }

    function test_setTradingOperatorZero() public {
        vm.prank(creator);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.setTradingOperator(address(0));
    }

    function test_requestRedeemWhileLockedThenClaim() public {
        vm.prank(operator);
        vault.placeOrder(MARKET_ID, BotVault.Side.BUY_YES, 1e18, 9 ether, 1, 0);
        uint256 shares = vault.balanceOf(creator);
        vm.prank(creator);
        vault.requestRedeem(shares / 2, creator, creator);
        assertGt(vault.lockedShares(creator), 0);

        vm.prank(operator);
        vault.cancelOrder(MARKET_ID, 1);
        vault.allocateIdle();
        assertGt(vault.claimableAssets(creator), 0);
        uint256 claim = vault.claimableAssets(creator);
        vm.prank(creator);
        vault.withdraw(claim, creator, creator);
    }

    function test_operatorCannotRequestRedeemOthers() public {
        uint256 shares = vault.balanceOf(creator);
        vm.prank(operator);
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.requestRedeem(shares, operator, creator);
        vm.prank(operator);
        vm.expectRevert();
        vault.redeem(shares, operator, creator);
    }

    function test_claimOperatorCanRequestRedeem() public {
        address claimOp = makeAddr("claimOp");
        vm.prank(creator);
        vault.setOperator(claimOp, true);
        uint256 shares = vault.balanceOf(creator) / 10;
        vm.prank(claimOp);
        vault.requestRedeem(shares, creator, creator);
        assertEq(vault.lockedShares(creator), shares);
        vm.prank(operator);
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.requestRedeem(shares, creator, creator);
    }

    function test_operatorCannotWithdraw() public {
        vm.prank(operator);
        vm.expectRevert();
        vault.withdraw(1 ether, operator, creator);
        vm.prank(operator);
        vm.expectRevert();
        assertFalse(vault.transferFrom(creator, operator, 1));
    }

    function test_strangerCannotSetTradingOperator() public {
        vm.prank(stranger);
        vm.expectRevert();
        vault.setTradingOperator(stranger);
        vm.prank(operator);
        vm.expectRevert();
        vault.setTradingOperator(stranger);
    }

    function test_reduceOrderRefundsVault() public {
        uint256 price = 0.4e18;
        uint256 qty = 5 ether;
        uint256 needed = price * qty / SCALE;
        vm.prank(operator);
        uint128 id = vault.placeOrder(MARKET_ID, BotVault.Side.BUY_YES, price, qty, 1_000_000_000, 0);
        assertEq(asset.allowance(address(vault), address(pool)), 0);
        uint256 afterPlace = asset.balanceOf(address(vault));
        vm.prank(operator);
        vault.reduceOrder(MARKET_ID, id, qty / 2);
        assertGt(asset.balanceOf(address(vault)), afterPlace);
        assertEq(asset.balanceOf(operator), 0);
        assertEq(asset.balanceOf(address(vault)), afterPlace + needed / 2);
    }

    function test_placeUsesModulePoolNotOtherPool() public {
        MockPool decoy = new MockPool(IERC20(address(asset)), SCALE);
        asset.mint(address(vault), 0); // no-op; decoy must not receive escrow
        uint256 decoyBefore = asset.balanceOf(address(decoy));
        uint256 poolBefore = asset.balanceOf(address(pool));
        vm.prank(operator);
        vault.placeOrder(MARKET_ID, BotVault.Side.BUY_YES, 0.5e18, 2 ether, 1, 0);
        assertEq(asset.balanceOf(address(decoy)), decoyBefore);
        assertGt(asset.balanceOf(address(pool)), poolBefore);
        assertEq(asset.balanceOf(operator), 0);
    }

    function test_trackedMarketsCapped() public {
        for (uint256 i = 1; i <= 32; ++i) {
            bytes32 id = keccak256(abi.encode("m", i));
            module.setMarket(id, address(pool), YES_ID, NO_ID, 1);
            vm.prank(operator);
            vault.syncMarket(id);
        }
        bytes32 extra = keccak256("extra");
        module.setMarket(extra, address(pool), YES_ID, NO_ID, 1);
        vm.prank(operator);
        vm.expectRevert(Errors.TrackedMarketsCapped.selector);
        vault.syncMarket(extra);
    }

    function test_forgetMarketAfterFlat() public {
        vm.prank(operator);
        vault.mintCompleteSet(MARKET_ID, 1 ether);
        vm.prank(operator);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.forgetMarket(MARKET_ID);
        vm.prank(operator);
        vault.mergeCompleteSet(MARKET_ID, 1 ether);
        vm.prank(operator);
        vault.forgetMarket(MARKET_ID);
        assertEq(vault.trackedMarketCount(), 0);
    }
}

contract ReentrantAsset is MockAsset {
    address public target;
    bool public attackDeposit;

    function setTarget(address t, bool dep) external {
        target = t;
        attackDeposit = dep;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        if (target != address(0) && attackDeposit) {
            BotVault(target).deposit(1, from);
        }
        return ok;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        if (target != address(0) && !attackDeposit) {
            BotVault(target).withdraw(1, to, to);
        }
        return ok;
    }
}

contract ReentrancyTest is VaultTestBase {
    function test_reentrancyOnDepositAndWithdraw() public {
        ReentrantAsset tok = new ReentrantAsset();
        outcomes = new MockOutcome6909();
        module = new MockModule(IERC20(address(tok)), outcomes);
        pool = new MockPool(IERC20(address(tok)), SCALE);
        settlement = new MockSettlement(IERC20(address(tok)), module, outcomes);
        module.setMarket(MARKET_ID, address(pool), YES_ID, NO_ID, 1);
        vm.prank(admin);
        factory = new VaultFactory(address(module), address(settlement), address(outcomes));

        tok.mint(creator, 50 ether);
        vm.startPrank(creator);
        tok.approve(address(factory), SEED);
        BotVault vault = BotVault(factory.createVault(operator, address(tok), "v", "v", SEED));
        vm.stopPrank();

        tok.setTarget(address(vault), true);
        tok.mint(lp, 5 ether);
        vm.startPrank(lp);
        tok.approve(address(vault), 5 ether);
        vm.expectRevert();
        vault.deposit(5 ether, lp);
        vm.stopPrank();

        tok.setTarget(address(vault), false);
        vm.prank(creator);
        vm.expectRevert();
        vault.withdraw(1 ether, creator, creator);
    }

    function test_reentrancyOnPlace() public {
        _deployFactory();
        ReentrantPool rpool = new ReentrantPool(IERC20(address(asset)), SCALE);
        module.setMarket(MARKET_ID, address(rpool), YES_ID, NO_ID, 1);
        BotVault vault = _createVault(SEED);
        rpool.setAttack(address(vault));
        vm.prank(operator);
        vm.expectRevert();
        vault.placeOrder(MARKET_ID, BotVault.Side.BUY_YES, 0.4e18, 1 ether, 1, 0);
    }
}

contract ReentrantPool is MockPool {
    address public vaultTarget;
    bool public attack;

    constructor(IERC20 asset_, uint256 scale_) MockPool(asset_, scale_) {}

    function setAttack(address vault_) external {
        vaultTarget = vault_;
        attack = true;
    }

    function _afterPlace() internal override {
        if (attack && vaultTarget != address(0)) {
            BotVault(vaultTarget).allocateIdle();
        }
    }
}
