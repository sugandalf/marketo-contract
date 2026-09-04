// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VaultFactory} from "../src/VaultFactory.sol";
import {BotVault} from "../src/BotVault.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {VaultTestBase} from "./VaultCore.t.sol";

contract VaultFeeCreateTest is VaultTestBase {
    function setUp() public {
        _deployFactory();
    }

    function test_seedDoesNotMintFeesAndArmsHwm() public {
        address feeTo = makeAddr("feeTo");
        BotVault vault = _createVault(SEED, FEE_BPS, feeTo);
        assertEq(vault.balanceOf(feeTo), 0);
        assertEq(vault.balanceOf(treasury), 0);
        assertEq(vault.feeShares(feeTo), 0);
        uint256 hwm = vault.highWaterMark();
        assertGt(hwm, 0);
        uint256 virt = 10 ** 3;
        uint256 expected = vault.feeSafeNav() * 1e18 / (vault.totalSupply() + virt);
        assertEq(hwm, expected);
    }

    function test_zeroFeeHarvestMintsNothing() public {
        BotVault vault = _createVault(SEED, 0, address(0));
        asset.mint(address(vault), 20 ether);
        uint256 supply = vault.totalSupply();
        vault.harvestFees();
        assertEq(vault.totalSupply(), supply);
        assertEq(vault.balanceOf(treasury), 0);
    }

    function test_revertFeeAboveMax() public {
        asset.mint(creator, SEED);
        vm.startPrank(creator);
        asset.approve(address(factory), SEED);
        vm.expectRevert(Errors.InvalidAmount.selector);
        factory.createVault(operator, address(asset), "n", "s", SEED, 2_001, creator);
        vm.stopPrank();
    }

    function test_revertZeroRecipientWhenFeeOn() public {
        asset.mint(creator, SEED);
        vm.startPrank(creator);
        asset.approve(address(factory), SEED);
        vm.expectRevert(Errors.ZeroAddress.selector);
        factory.createVault(operator, address(asset), "n", "s", SEED, FEE_BPS, address(0));
        vm.stopPrank();
    }

    function test_createWithFeeAllowedWhenProtocolOffAndTreasuryZero() public {
        vm.prank(admin);
        factory.setProtocolFeeBps(0);
        vm.prank(admin);
        factory.setTreasury(address(0));
        BotVault vault = _createVault(SEED, FEE_BPS, creator);
        asset.mint(address(vault), 5 ether);
        vault.harvestFees();
        assertGt(vault.feeShares(creator), 0);
        assertEq(vault.balanceOf(address(0)), 0);
    }

    function test_constructorZeroTreasuryReverts() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        new VaultFactory(address(module), address(settlement), address(outcomes), address(0));
    }
}

contract VaultFeeHarvestTest is VaultTestBase {
    address internal feeTo = makeAddr("feeTo");
    BotVault internal vault;

    function setUp() public {
        _deployFactory();
        vault = _createVault(100 ether, FEE_BPS, feeTo);
    }

    function test_operatorHarvestPaysConfiguredRecipients() public {
        asset.mint(address(vault), 20 ether);
        vm.prank(operator);
        vault.harvestFees();
        assertEq(vault.balanceOf(operator), 0);
        assertGt(vault.balanceOf(feeTo), 0);
        assertGt(vault.balanceOf(treasury), 0);
        assertEq(asset.balanceOf(operator), 0);
    }

    function test_profitMintsTenPercentSplit() public {
        uint256 idleBefore = asset.balanceOf(address(vault));
        uint256 prin = vault.totalPrincipal();
        asset.mint(address(vault), 20 ether);
        vm.prank(stranger);
        vault.harvestFees();

        assertEq(asset.balanceOf(address(vault)), idleBefore + 20 ether);
        assertEq(vault.totalPrincipal(), prin);

        uint256 tShares = vault.balanceOf(treasury);
        uint256 fShares = vault.balanceOf(feeTo);
        uint256 minted = tShares + fShares;
        assertGt(minted, 0);
        assertEq(tShares, minted * 2_000 / 10_000);
        assertEq(fShares, minted - tShares);
        assertEq(vault.feeShares(treasury), tShares);
        assertEq(vault.feeShares(feeTo), fShares);
        assertEq(vault.principalOf(feeTo), 0);
        assertEq(vault.principalOf(treasury), 0);

        uint256 feeValue = vault.convertToAssets(minted);
        assertApproxEqAbs(feeValue, 2 ether, 0.02 ether);
    }

    function test_drawdownAndRecoveryMintZero() public {
        asset.mint(address(vault), 20 ether);
        vault.harvestFees();
        uint256 hwm = vault.highWaterMark();
        uint256 supply = vault.totalSupply();

        vm.prank(address(vault));
        assertTrue(asset.transfer(stranger, 30 ether));
        vault.harvestFees();
        assertEq(vault.totalSupply(), supply);
        assertEq(vault.highWaterMark(), hwm);

        asset.mint(address(vault), 30 ether);
        vault.harvestFees();
        assertEq(vault.totalSupply(), supply);
        assertEq(vault.highWaterMark(), hwm);
    }

    function test_unpairedInventoryDoesNotCreateFees() public {
        vault.syncMarket(MARKET_ID);
        uint256 hwm = vault.highWaterMark();
        uint256 supply = vault.totalSupply();
        uint256 feeNav = vault.feeSafeNav();
        outcomes.mint(address(vault), YES_ID, 5 ether);
        assertGt(vault.totalAssets(), feeNav);
        assertEq(vault.feeSafeNav(), feeNav);
        vault.harvestFees();
        assertEq(vault.totalSupply(), supply);
        assertEq(vault.highWaterMark(), hwm);
    }

    function test_completeSetsInFeeSafeNav() public {
        uint256 before = vault.feeSafeNav();
        outcomes.mint(address(vault), YES_ID, 3 ether);
        outcomes.mint(address(vault), NO_ID, 3 ether);
        vault.syncMarket(MARKET_ID);
        assertEq(vault.feeSafeNav(), before + 3 ether);
    }

    function test_venueRedeemCrystallizes() public {
        vault.syncMarket(MARKET_ID);
        outcomes.mint(address(vault), YES_ID, 5 ether);
        module.setMarket(MARKET_ID, address(pool), YES_ID, NO_ID, 4);
        asset.mint(address(module), 5 ether);
        uint256 supply = vault.totalSupply();
        vm.prank(operator);
        vault.redeem(MARKET_ID, 0, 5 ether);
        assertGt(vault.totalSupply(), supply);
        assertGt(vault.balanceOf(feeTo) + vault.balanceOf(treasury), 0);
    }

    function test_depositCrystallizesBeforeNewShares() public {
        asset.mint(address(vault), 20 ether);
        uint256 previewBefore = vault.previewDeposit(10 ether);
        asset.mint(lp, 10 ether);
        vm.startPrank(lp);
        asset.approve(address(vault), 10 ether);
        uint256 got = vault.deposit(10 ether, lp);
        vm.stopPrank();
        assertGt(vault.balanceOf(feeTo) + vault.balanceOf(treasury), 0);
        assertGt(got, previewBefore);
        assertEq(vault.principalOf(lp), 10 ether);
    }

    function test_ownerFeeRedeemDoesNotLoosenSeed() public {
        BotVault owned = _createVaultFor(makeAddr("opFee"), 100 ether, FEE_BPS, creator);
        asset.mint(lp, 400 ether);
        vm.startPrank(lp);
        asset.approve(address(owned), 400 ether);
        owned.deposit(400 ether, lp);
        vm.stopPrank();
        uint256 prin = owned.creatorPrincipal();
        uint256 tot = owned.totalPrincipal();
        asset.mint(address(owned), 50 ether);
        owned.harvestFees();
        uint256 feeLot = owned.feeShares(creator);
        assertGt(feeLot, 0);
        vm.prank(creator);
        owned.redeem(feeLot, creator, creator);
        assertEq(owned.creatorPrincipal(), prin);
        assertEq(owned.totalPrincipal(), tot);
        assertEq(owned.feeShares(creator), 0);
    }

    function test_feeRecipientMaxWithdrawIdleOnly() public {
        asset.mint(address(vault), 20 ether);
        vault.harvestFees();
        vm.prank(operator);
        vault.placeOrder(MARKET_ID, BotVault.Side.BUY_YES, 1_000_000, 90 ether, 1, 0);
        uint256 idle = asset.balanceOf(address(vault));
        assertLe(vault.maxWithdraw(feeTo), idle);

        uint256 lpIn = 10 ether;
        asset.mint(lp, lpIn);
        vm.startPrank(lp);
        asset.approve(address(vault), lpIn);
        uint256 lpShares = vault.deposit(lpIn, lp);
        vault.requestRedeem(lpShares, lp, lp);
        vm.stopPrank();
        vault.allocateIdle();
        uint256 reserved = vault.reservedForClaims();
        if (reserved > 0) {
            uint256 avail = idle > reserved ? idle - reserved : 0;
            assertLe(vault.maxWithdraw(feeTo), avail);
        }
    }
}

contract VaultFeeAdminTest is VaultTestBase {
    function setUp() public {
        _deployFactory();
    }

    function test_adminSetters() public {
        address t2 = makeAddr("t2");
        vm.prank(admin);
        factory.setTreasury(t2);
        assertEq(factory.treasury(), t2);
        vm.prank(admin);
        factory.setProtocolFeeBps(1_000);
        assertEq(factory.protocolFeeBps(), 1_000);
        vm.prank(admin);
        factory.setMaxPerformanceFeeBps(1_500);
        assertEq(factory.maxPerformanceFeeBps(), 1_500);
    }

    function test_nonAdminCannotSetFeeConfig() public {
        _createVault(SEED);
        address[] memory bad = new address[](3);
        bad[0] = creator;
        bad[1] = operator;
        bad[2] = stranger;
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(bad[i]);
            vm.expectRevert(Errors.Unauthorized.selector);
            factory.setTreasury(bad[i]);
            vm.prank(bad[i]);
            vm.expectRevert(Errors.Unauthorized.selector);
            factory.setProtocolFeeBps(1);
            vm.prank(bad[i]);
            vm.expectRevert(Errors.Unauthorized.selector);
            factory.setMaxPerformanceFeeBps(1);
        }
    }

    function test_maxBpsOutOfRange() public {
        vm.prank(admin);
        vm.expectRevert(Errors.InvalidAmount.selector);
        factory.setMaxPerformanceFeeBps(2_001);
        vm.prank(admin);
        vm.expectRevert(Errors.InvalidAmount.selector);
        factory.setProtocolFeeBps(10_001);
    }

    function test_loweringMaxDoesNotRewriteLiveVault() public {
        BotVault vault = _createVault(SEED, 2_000, creator);
        vm.prank(admin);
        factory.setMaxPerformanceFeeBps(1_000);
        assertEq(vault.performanceFeeBps(), 2_000);
        asset.mint(creator, SEED);
        vm.startPrank(creator);
        asset.approve(address(factory), SEED);
        vm.expectRevert(Errors.InvalidAmount.selector);
        factory.createVault(makeAddr("opNew"), address(asset), "n", "s", SEED, 1_500, creator);
        vm.stopPrank();
    }

    function test_feeViewsNeverRevert() public {
        BotVault vault = _createVault(SEED);
        vault.feeSafeNav();
        vault.highWaterMark();
        vault.performanceFeeBps();
        vault.creatorFeeRecipient();
        vault.feeShares(creator);
    }

    function test_setProtocolOnWithZeroTreasuryReverts() public {
        vm.prank(admin);
        factory.setProtocolFeeBps(0);
        vm.prank(admin);
        factory.setTreasury(address(0));
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        factory.setProtocolFeeBps(2_000);
    }

    function test_setTreasuryZeroWhileProtocolOnReverts() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        factory.setTreasury(address(0));
    }

    function test_zeroFeeCreateAllowed() public {
        BotVault vault = _createVault(SEED, 0, address(0));
        assertEq(vault.performanceFeeBps(), 0);
        vault.harvestFees();
    }
}
