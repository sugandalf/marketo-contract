## 1. Factory fee config and ABI

- [x] 1.1 Extend `IVaultFactory` with `treasury()`, `protocolFeeBps()`, `maxPerformanceFeeBps()`. Add factory storage, defaults (protocol 2000, max 2000), constructor `treasury` (non-zero), admin setters, and events. Revert `Unauthorized` / `ZeroAddress` / `InvalidAmount` as in design.md
- [x] 1.2 Extend `createVault` and `BotVault.initialize` with `performanceFeeBps` and `creatorFeeRecipient`. Validate fee ≤ max; fee > 0 requires non-zero recipient; fee > 0 and protocol > 0 requires treasury. Store both on the vault with no setters. Extend `VaultCreated`
- [x] 1.3 Update `test/VaultCore.t.sol` and `test/Trading.t.sol` helpers and every `createVault` call so existing deposit, cap, 4626, 7540, and operator tests compile. Update `script/DeployVaultFactory.s.sol` to pass treasury

## 2. Fee-safe NAV, HWM, share mint

- [x] 2.1 Add `feeSafeNav()`, `highWaterMark()`, `performanceFeeBps()`, `creatorFeeRecipient()` views (MUST NOT revert). Implement fee-safe NAV as idle + escrow + `min(yes, no)` per `marketId` with the same try/catch as `totalAssets()`. Leave `totalAssets()` on `max(yes, no)`
- [x] 2.2 Implement `_accrueFees`: WAD PPS with OZ virtual shares; skip if supply 0 or fee bps 0; if `highWaterMark == 0` set PPS and return (seed is not profit); mint Floor fee shares using fee-safe NAV; split protocol/creator; revert `ZeroAddress` if fee on and a required recipient is missing. Public `harvestFees()` `nonReentrant`
- [x] 2.3 Add `feeShares` overlay on `_update` (fee lots first). Fee `_mint` MUST NOT `_addPrincipal`. Hook `_accrueFees` at start of `deposit`/`mint`/`withdraw`/`redeem`/`requestRedeem` and after venue `redeem`

## 3. Fee unit tests

- [x] 3.1 Create with 1000 bps: seed does not mint fees; HWM equals post-seed fee-safe PPS. Zero bps vault: harvest mints nothing. `vm.expectRevert` on create with fee > max, fee > 0 and zero recipient, fee > 0 and zero treasury while protocol take is on
- [x] 3.2 Profit 100 → 120 at 1000 bps mints 2 assets of shares, 20% to treasury / 80% to creator, idle unchanged, `totalPrincipal` unchanged. Drawdown and recovery to HWM mint zero. Stranger `harvestFees` succeeds. Operator cannot retarget recipients (no param)
- [x] 3.3 Unpaired Yes/No: `totalAssets` rises, harvest mints zero. Complete-set inventory of `P` is in fee-safe NAV. Venue `redeem` that raises idle crystallizes in the same tx
- [x] 3.4 Deposit crystallizes before new shares (depositor minted at post-fee price). Owner as `creatorFeeRecipient` redeems only fee lots: `creatorPrincipal` and cap unchanged. Fee recipient `maxWithdraw` is idle-only and does not skip `reservedForClaims`
- [x] 3.5 Admin setters: treasury, protocol bps, max bps; non-admin / owner / operator `vm.expectRevert`; lowering max does not rewrite a live vault's 2000 bps. Views `feeSafeNav` / HWM / fee bps never revert. `forge fmt` and `forge test`

## 4. Regression and security audit

- [x] 4.1 Re-run existing ERC-4626, inflation, idle `maxWithdraw`, 7540, unauthorized trade, over-withdraw, invalid market, and reentrancy tests; fix any harvest-hook fallout
- [x] 4.2 Security audit of the diff: auth (who harvests vs who receives), no idle skim, no new spenders, feeShares vs seed lock, phantom inventory, missing reverts, views non-reverting, rounding Floor. Add any missing `vm.expectRevert` tests. Do not mark the change done while any of those remain
