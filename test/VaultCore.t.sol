// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {VaultFactory} from "../src/VaultFactory.sol";
import {BotVault} from "../src/BotVault.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {MockAsset} from "./mocks/MockAsset.sol";
import {MockOutcome6909, MockPool, MockModule, MockSettlement} from "./mocks/MockVenue.sol";

contract VaultTestBase is Test {
    MockAsset internal asset;
    MockOutcome6909 internal outcomes;
    MockModule internal module;
    MockPool internal pool;
    MockSettlement internal settlement;
    VaultFactory internal factory;

    address internal admin = makeAddr("admin");
    address internal creator = makeAddr("creator");
    address internal operator = makeAddr("operator");
    address internal lp = makeAddr("lp");
    address internal stranger = makeAddr("stranger");
    address internal treasury = makeAddr("treasury");

    bytes32 internal constant MARKET_ID = keccak256("m1");
    uint256 internal constant YES_ID = 1;
    uint256 internal constant NO_ID = 2;
    uint256 internal constant SEED = 10 ether;
    uint256 internal constant SCALE = 1e18;
    uint32 internal constant FEE_BPS = 1_000;

    function _deployFactory() internal {
        asset = new MockAsset();
        outcomes = new MockOutcome6909();
        module = new MockModule(IERC20(address(asset)), outcomes);
        pool = new MockPool(IERC20(address(asset)), SCALE);
        settlement = new MockSettlement(IERC20(address(asset)), module, outcomes);
        module.setMarket(MARKET_ID, address(pool), YES_ID, NO_ID, 1);

        vm.prank(admin);
        factory = new VaultFactory(address(module), address(settlement), address(outcomes), treasury);
    }

    function _createVault(uint256 seed) internal returns (BotVault vault) {
        return _createVault(seed, FEE_BPS, creator);
    }

    function _createVault(uint256 seed, uint32 feeBps, address feeRecipient) internal returns (BotVault vault) {
        asset.mint(creator, seed * 10);
        vm.startPrank(creator);
        asset.approve(address(factory), type(uint256).max);
        vault =
            BotVault(factory.createVault(operator, address(asset), "Bot Vault", "bVAULT", seed, feeBps, feeRecipient));
        vm.stopPrank();
    }

    function _createVaultFor(address op, uint256 seed, uint32 feeBps, address feeRecipient)
        internal
        returns (BotVault vault)
    {
        asset.mint(creator, seed * 10);
        vm.startPrank(creator);
        asset.approve(address(factory), type(uint256).max);
        vault = BotVault(factory.createVault(op, address(asset), "Bot Vault", "bVAULT", seed, feeBps, feeRecipient));
        vm.stopPrank();
    }
}

contract VaultFactoryTest is VaultTestBase {
    function setUp() public {
        _deployFactory();
    }

    function test_createWithSeed() public {
        BotVault vault = _createVault(SEED);
        assertEq(factory.vaults(operator), address(vault));
        assertEq(factory.operatorOf(address(vault)), operator);
        assertEq(vault.owner(), creator);
        assertEq(vault.tradingOperator(), operator);
        assertEq(vault.asset(), address(asset));
        assertEq(vault.principalOf(creator), SEED);
        assertEq(asset.balanceOf(address(vault)), SEED);
        assertEq(factory.vaultCount(), 1);
        assertEq(factory.vaultAt(0), address(vault));
        assertEq(factory.depositCapBps(), 50_000);
        assertEq(factory.protocolFeeBps(), 2_000);
        assertEq(factory.maxPerformanceFeeBps(), 2_000);
        assertEq(factory.treasury(), treasury);
        assertEq(vault.performanceFeeBps(), FEE_BPS);
        assertEq(vault.creatorFeeRecipient(), creator);
    }

    function test_revertZeroOperator() public {
        asset.mint(creator, SEED);
        vm.startPrank(creator);
        asset.approve(address(factory), SEED);
        vm.expectRevert(Errors.ZeroAddress.selector);
        factory.createVault(address(0), address(asset), "n", "s", SEED, FEE_BPS, creator);
        vm.stopPrank();
    }

    function test_revertZeroAsset() public {
        vm.prank(creator);
        vm.expectRevert(Errors.ZeroAddress.selector);
        factory.createVault(operator, address(0), "n", "s", SEED, FEE_BPS, creator);
    }

    function test_revertZeroSeed() public {
        vm.prank(creator);
        vm.expectRevert(Errors.InvalidAmount.selector);
        factory.createVault(operator, address(asset), "n", "s", 0, FEE_BPS, creator);
    }

    function test_revertDuplicateOperator() public {
        _createVault(SEED);
        asset.mint(creator, SEED);
        vm.startPrank(creator);
        asset.approve(address(factory), SEED);
        vm.expectRevert(Errors.OperatorExists.selector);
        factory.createVault(operator, address(asset), "n", "s", SEED, FEE_BPS, creator);
        vm.stopPrank();
    }

    function test_revertVaultAtOOB() public {
        vm.expectRevert(Errors.IndexOutOfBounds.selector);
        factory.vaultAt(0);
    }

    function test_twoOperatorsIsolated() public {
        BotVault v1 = _createVault(SEED);
        address op2 = makeAddr("op2");
        address creator2 = makeAddr("creator2");
        asset.mint(creator2, SEED);
        vm.startPrank(creator2);
        asset.approve(address(factory), SEED);
        BotVault v2 = BotVault(factory.createVault(op2, address(asset), "v2", "v2", SEED, FEE_BPS, creator2));
        vm.stopPrank();
        assertTrue(address(v1) != address(v2));
        assertEq(factory.vaultCount(), 2);
        assertEq(asset.balanceOf(address(v1)), SEED);
        assertEq(asset.balanceOf(address(v2)), SEED);
    }

    function test_setDepositCapBps() public {
        BotVault vault = _createVault(SEED);
        vm.prank(admin);
        factory.setDepositCapBps(20_000);
        assertEq(factory.depositCapBps(), 20_000);
        assertEq(vault.maxDeposit(lp), 10 ether); // 10 * 2 - 10
    }

    function test_nonAdminCannotSetCap() public {
        _createVault(SEED);
        vm.prank(creator);
        vm.expectRevert(Errors.Unauthorized.selector);
        factory.setDepositCapBps(20_000);
        vm.prank(operator);
        vm.expectRevert(Errors.Unauthorized.selector);
        factory.setDepositCapBps(20_000);
        vm.prank(stranger);
        vm.expectRevert(Errors.Unauthorized.selector);
        factory.setDepositCapBps(20_000);
    }

    function test_capOutOfRange() public {
        vm.prank(admin);
        vm.expectRevert(Errors.InvalidAmount.selector);
        factory.setDepositCapBps(9_999);
        vm.prank(admin);
        vm.expectRevert(Errors.InvalidAmount.selector);
        factory.setDepositCapBps(1_000_001);
    }
}

contract BotVault4626Test is VaultTestBase {
    BotVault internal vault;

    function setUp() public {
        _deployFactory();
        vault = _createVault(SEED);
    }

    function test_depositMintsShares() public {
        uint256 assets = 5 ether;
        asset.mint(lp, assets);
        vm.startPrank(lp);
        asset.approve(address(vault), assets);
        uint256 preview = vault.previewDeposit(assets);
        vm.expectEmit(true, true, false, true);
        emit IERC4626.Deposit(lp, lp, assets, preview);
        uint256 shares = vault.deposit(assets, lp);
        vm.stopPrank();
        assertEq(shares, preview);
        assertEq(vault.balanceOf(lp), shares);
        assertEq(vault.principalOf(lp), assets);
    }

    function test_mintMatchesPreview() public {
        uint256 shares = 1 ether;
        uint256 assets = vault.previewMint(shares);
        asset.mint(lp, assets);
        vm.startPrank(lp);
        asset.approve(address(vault), assets);
        uint256 paid = vault.mint(shares, lp);
        vm.stopPrank();
        assertEq(paid, assets);
    }

    function test_zeroDepositReverts() public {
        vm.prank(lp);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.deposit(0, lp);
    }

    function test_viewsDoNotRevert() public view {
        vault.asset();
        vault.totalAssets();
        vault.convertToShares(1);
        vault.convertToAssets(1);
        vault.previewDeposit(1);
        vault.previewMint(1);
        vault.previewWithdraw(1);
        vault.previewRedeem(1);
        vault.maxDeposit(lp);
        vault.maxMint(lp);
        vault.maxWithdraw(creator);
        vault.maxRedeem(creator);
        vault.share();
        vault.feeSafeNav();
        vault.highWaterMark();
        vault.performanceFeeBps();
    }

    function test_donationDoesNotMintShares() public {
        uint256 supply = vault.totalSupply();
        asset.mint(stranger, 100 ether);
        vm.prank(stranger);
        assertTrue(asset.transfer(address(vault), 100 ether));
        assertEq(vault.totalSupply(), supply);
        assertEq(vault.balanceOf(stranger), 0);
    }

    function test_inflationAttackNonDust() public {
        // Direct-init vault with no seed so first honest deposit is after a donation.
        BotVault impl = BotVault(factory.IMPLEMENTATION());
        // Use a fresh clone-like deploy via factory with tiny seed then donate — offset still protects LPs.
        asset.mint(stranger, 10_000 ether);
        vm.prank(stranger);
        assertTrue(asset.transfer(address(vault), 10_000 ether));
        uint256 lpIn = 10 ether;
        asset.mint(lp, lpIn);
        vm.startPrank(lp);
        asset.approve(address(vault), lpIn);
        uint256 shares = vault.deposit(lpIn, lp);
        vm.stopPrank();
        assertGt(shares, 0);
        assertGt(vault.convertToAssets(shares), 0);
        impl; // silence
    }

    function test_supports4626() public view {
        assertTrue(vault.supportsInterface(type(IERC4626).interfaceId));
        assertEq(vault.share(), address(vault));
    }
}

contract PrincipalCapTest is VaultTestBase {
    BotVault internal vault;

    function setUp() public {
        _deployFactory();
        vault = _createVault(SEED);
    }

    function test_thirdPartyStopsAt5x() public {
        uint256 room = 40 ether;
        asset.mint(lp, room + 1 ether);
        vm.startPrank(lp);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(room, lp);
        assertEq(vault.maxDeposit(lp), 0);
        vm.expectRevert(Errors.DepositCapExceeded.selector);
        vault.deposit(1, lp);
        vm.stopPrank();
    }

    function test_profitsDoNotFreeRoom() public {
        asset.mint(lp, 40 ether);
        vm.startPrank(lp);
        asset.approve(address(vault), 40 ether);
        vault.deposit(40 ether, lp);
        vm.stopPrank();
        // Simulate trading profit: donate extra assets (NAV up, principal unchanged).
        asset.mint(address(vault), 30 ether);
        assertEq(vault.totalPrincipal(), 50 ether);
        assertEq(vault.maxDeposit(lp), 0);
    }

    function test_creatorSeedRaisesCap() public {
        asset.mint(lp, 40 ether);
        vm.startPrank(lp);
        asset.approve(address(vault), 40 ether);
        vault.deposit(40 ether, lp);
        vm.stopPrank();
        vm.startPrank(creator);
        asset.approve(address(vault), 10 ether);
        vault.deposit(10 ether, creator);
        vm.stopPrank();
        assertEq(vault.creatorPrincipal(), 20 ether);
        assertEq(vault.maxDeposit(lp), 40 ether);
    }

    function test_redeemFreesPrincipalNotProfit() public {
        asset.mint(lp, 40 ether);
        vm.startPrank(lp);
        asset.approve(address(vault), 40 ether);
        uint256 shares = vault.deposit(40 ether, lp);
        vm.stopPrank();
        asset.mint(address(vault), 40 ether); // double NAV
        uint256 assetsOut = vault.previewRedeem(shares);
        assertGt(assetsOut, 40 ether);
        vm.prank(lp);
        vault.redeem(shares, lp, lp);
        assertEq(vault.principalOf(lp), 0);
        assertEq(vault.totalPrincipal(), SEED);
        assertEq(vault.maxDeposit(lp), 40 ether);
    }

    function test_creatorCannotPullSeedAtCap() public {
        asset.mint(lp, 40 ether);
        vm.startPrank(lp);
        asset.approve(address(vault), 40 ether);
        vault.deposit(40 ether, lp);
        vm.stopPrank();
        vm.prank(creator);
        vm.expectRevert(Errors.CreatorSeedRequired.selector);
        vault.withdraw(1 ether, creator, creator);

        uint256 creatorShares = vault.balanceOf(creator);
        uint256 redeemShares = creatorShares / 10;
        vm.prank(creator);
        vm.expectRevert(Errors.CreatorSeedRequired.selector);
        vault.redeem(redeemShares, creator, creator);

        vm.prank(creator);
        vm.expectRevert(Errors.CreatorSeedRequired.selector);
        assertFalse(vault.transfer(lp, creatorShares));

        vm.prank(creator);
        vault.approve(lp, creatorShares);
        vm.prank(lp);
        vm.expectRevert(Errors.CreatorSeedRequired.selector);
        assertFalse(vault.transferFrom(creator, lp, creatorShares));
    }

    function test_creatorCanTrimAfterLpRedeem() public {
        asset.mint(lp, 40 ether);
        vm.startPrank(lp);
        asset.approve(address(vault), 40 ether);
        uint256 shares = vault.deposit(40 ether, lp);
        uint256 tenth = shares / 4; // redeem 10 of 40 principal
        vault.redeem(tenth, lp, lp);
        vm.stopPrank();
        // total principal 40, creator 10, cap 50, creator can withdraw 2 principal
        vm.prank(creator);
        vault.withdraw(2 ether, creator, creator);
        vm.prank(creator);
        vm.expectRevert(Errors.CreatorSeedRequired.selector);
        vault.withdraw(1 ether, creator, creator);
    }

    function test_creatorCannotQueueRedeemAtCap() public {
        asset.mint(lp, 40 ether);
        vm.startPrank(lp);
        asset.approve(address(vault), 40 ether);
        vault.deposit(40 ether, lp);
        vm.stopPrank();
        uint256 shares = vault.balanceOf(creator) / 2;
        vm.prank(creator);
        vm.expectRevert(Errors.CreatorSeedRequired.selector);
        vault.requestRedeem(shares, creator, creator);
    }

    function test_depositOverCapNoClamp() public {
        asset.mint(lp, 41 ether);
        vm.startPrank(lp);
        asset.approve(address(vault), 41 ether);
        vm.expectRevert(Errors.DepositCapExceeded.selector);
        vault.deposit(41 ether, lp);
        vm.stopPrank();
        assertEq(vault.principalOf(lp), 0);
    }
}
