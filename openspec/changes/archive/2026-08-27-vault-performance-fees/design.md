## Context

See `proposal.md` for motivation and `specs/bot-vault`, `specs/vault-factory` for requirements. Today `BotVault` is an ERC-4626 + ERC-7540 clone: the vault is the DreamDEX trading identity; the operator may place/cancel/reduce, mint/merge, and venue-redeem; depositors exit idle-only. `totalAssets()` marks unpaired Yes/No at `max(up, down)`. Principal (not NAV) caps third-party deposits. Fees were a non-goal; `createVault` / `initialize` have no fee fields. Implementation is EIP-1167 clones of an immutable `BotVault` — ABI changes require a new factory + implementation. Collateral scale is `asset.decimals()` (USDso 18, tUSDC 6). Venue addresses come from `BinaryMarketsModule.markets(marketId)`, never hardcoded pools.

## Goals / Non-Goals

**Goals:**
- Accrue a vault-level HWM performance fee from fee-safe NAV, paid as share mints to `creatorFeeRecipient` and `factory.treasury()`.
- Keep operator, idle, 7540 queue, principal cap, and `totalAssets()` inventory mark unchanged except crystallization hooks.
- Fail closed on missing recipients; views still MUST NOT revert.

**Non-Goals:**
- Separate `FeeSplitter` contract (split is two `_mint`s). Adapter ABI. Migrating live clones in place. Management/entry/exit fees. Per-depositor HWM.

## Decisions

### 1. Pay fees by minting shares, not transferring idle

`_accrueFees` mints vault shares. Collateral stays. Recipients `redeem` / `requestRedeem` like any LP and sit behind `reservedForClaims`.

**Why:** Matches Yearn `report`, Morpho accrue, Enzyme/dHEDGE mint. An idle transfer would compete with the 7540 queue and look like a privileged drain (operator cannot send tokens to arbitrary addresses today).

**Alternative:** Accrue an asset liability and `claimFees` from idle. Rejected: starves the queue; `totalAssets` would have to subtract a liability without reverting.

### 2. Fee-safe NAV is idle + escrow + `min(yes, no)`

Reuse `totalAssets`’s try/catch loop keyed by `marketId`, but inventory is `min(up, down)` not `max`. Unpaired residual is 0 for fees. Public `feeSafeNav()` MUST NOT revert.

**Why:** `max(up, down)` would let a bot buy Yes at 0.6, harvest 10% of phantom 1.0, then lose on resolve. Complete sets are mergeable 1:1; escrow and idle are real collateral. Directional inventory waits until sell or venue `redeem`.

**Alternative:** Mid-book mark. Rejected: operator-manipulable. Realized-idle-only. Rejected: ignores mergeable complete sets.

PPS is WAD (`1e18`) using OZ virtual shares so it is comparable across USDso 18 and tUSDC 6:

```
virtual = 10 ** _decimalsOffset()          // 1000
pps     = feeSafeNav * 1e18 / (totalSupply + virtual)
profit  = (pps - hwm) * (totalSupply + virtual) / 1e18
feeAssets = profit * performanceFeeBps / 10_000   // Floor
```

Share mint uses fee-safe NAV as the price (Enzyme-style, Floor), not inflated `totalAssets()`:

```
feeShares = feeAssets * (supply + virtual) / (feeSafeNav + 1 - feeAssets)
```

Then `protocol = feeShares * protocolFeeBps / 10_000` to `factory.treasury()`, remainder to `creatorFeeRecipient`. Recipients are storage/factory reads — harvest has no recipient argument.

After mint, `hwm = new pps` (never decreases). If `feeShares == 0` but `pps > hwm`, still set `hwm = pps`.

EIP-4626 views do **not** simulate harvest (`convert*` MUST NOT include this fee; there is no entry/exit fee). `previewDeposit` can differ slightly from the actual mint when profit is pending; the mutative path accrues first.

### 3. `feeShares[account]` overlay so fee lots are not principal

ERC-20 shares are fungible, so a mint to `owner()` would otherwise mix with seed and `_reducePrincipal` (`principal * sharesOut / balance`) would loosen the seed lock.

Track `mapping(address => uint256) feeShares`. Fee `_mint` increments `feeShares[to]` and MUST NOT call `_addPrincipal`. On `_update` (transfer/burn), move **fee lots first**, then principal-bearing remainder:

```
prinBal = balanceOf(from) - feeShares[from]
if (value <= feeShares[from]) { move fee only; principal unchanged }
else { move all fee lots, then principal * prinOut / prinBal }
```

Mint/burn to `address(0)` skips the overlay on that side. This satisfies “redeem only fee shares leaves `creatorPrincipal` unchanged” even when `creatorFeeRecipient == owner()`.

**Alternative:** Require `creatorFeeRecipient != owner`. Rejected as the only mechanism: creators will pass their owner EOA. Overlay still works if they use a distinct payout wallet.

### 4. When to accrue

`_accrueFees` is `internal`, `nonReentrant` on public entrypoints:

| When | Why |
| --- | --- |
| Start of `deposit`/`mint`/`withdraw`/`redeem`/`requestRedeem` | New LPs must not buy uncharged profit; leavers pay dilution on gains they held. Enzyme settle-on-supply-change. |
| After venue `redeem` (operator) | Idle has just increased; that is realized event-contract PnL. |
| `harvestFees()` anyone | Keepers / frontend; no extra privilege. |

If `totalSupply() == 0` or `performanceFeeBps == 0`, return. If `highWaterMark == 0` and supply > 0, set `hwm = pps` and return (seed is not profit). Factory `createVault` deposits seed then the vault arms HWM on that first `_deposit` / `_accrueFees`.

If `performanceFeeBps > 0` and (`creatorFeeRecipient == 0` or (`protocolFeeBps > 0` and `treasury == 0`)), **revert** `ZeroAddress` (fail closed). Do not skip silently.

Venue `redeem`: effects after the settlement call (measure idle, then accrue). Exact-amount 6909 approve to `binarySettlement` unchanged. No new spenders.

### 5. Factory config; immutable per-vault fee

`VaultFactory` (admin = `Ownable` owner):

| Field | Default | Setter |
| --- | --- | --- |
| `treasury` | constructor arg (non-zero) | admin; zero allowed only if `protocolFeeBps == 0` |
| `protocolFeeBps` | 2000 | admin; `<= 10000` |
| `maxPerformanceFeeBps` | 2000 | admin; `<= 2000` |

`IVaultFactory` grows `treasury()`, `protocolFeeBps()`, `maxPerformanceFeeBps()`. Vaults read them live at accrue.

`createVault(..., uint32 performanceFeeBps, address creatorFeeRecipient)` and `BotVault.initialize` take the same two args. Stored on the vault; **no setters**. Reverts: fee > max; fee > 0 && recipient 0; fee > 0 && protocol > 0 && treasury 0.

`VaultCreated` adds `performanceFeeBps`, `creatorFeeRecipient`.

**Alternative:** Per-vault FeeSplitter clone. Rejected: extra deploy cost; two mints are enough.

### 6. State-changing functions (caller → MUST revert)

Existing venue/4626/7540 reverts stay. Additions/changes:

| Function | Caller | MUST revert (new) |
| --- | --- | --- |
| `createVault` (+ fee args) | anyone | `InvalidAmount` (fee > max); `ZeroAddress` (fee > 0 and missing recipient/treasury) |
| `setTreasury` / `setProtocolFeeBps` / `setMaxPerformanceFeeBps` | factory admin | `Unauthorized`; `ZeroAddress`; `InvalidAmount` (bps out of range) |
| `harvestFees` | anyone | `ZeroAddress` if fee on and recipient/treasury missing |
| `deposit`/`mint`/`withdraw`/`redeem`/`requestRedeem` | as today | same + accrue reverts above |
| venue `redeem` | trading operator | as today + accrue after settlement |
| `setPerformanceFee` / `setCreatorFeeRecipient` | — | **no such functions** |

`harvestFees` does not move collateral; still `nonReentrant`. No new allowances. Rounding Floor for fees.

## Risks / Trade-offs

- **[Donation raises fee-safe NAV]** → 10% of a gift can mint to creator/treasury. Same as Yearn. Unsolicited transfers still mint no shares to the attacker. Document.
- **[preview vs deposit mismatch]** → Views do not simulate harvest. Integrators should `harvestFees` before quoting size, or accept 4626 `preview` as pre-fee.
- **[feeShares overlay vs plain transfers]** → Wrong burn order would loosen the seed lock. Tests MUST redeem fee lots as owner and assert `creatorPrincipal` unchanged; fuzz `_update` mixed lots.
- **[HWM in WAD vs spec `/ 1e18`]** → Implement PPS in 1e18 so the spec formula is literal; include OZ virtual shares in the denominator.
- **[Old clones]** → Cannot grow storage/ABI. New factory only.

## Migration Plan

1. Deploy new `VaultFactory` (new implementation) with treasury set in the constructor. Do not upgrade old clones.
2. Frontend passes `performanceFeeBps` (default 1000) and `creatorFeeRecipient` on create. Old factory stays until empty if needed.
3. Rollback: stop pointing the UI at the new factory; existing new vaults keep their immutable fee bps.

## Open Questions

None. Frontend default of 1000 bps is UI-only; the contract requires the caller to pass bps.
