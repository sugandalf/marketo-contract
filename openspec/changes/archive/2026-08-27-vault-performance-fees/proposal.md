## Why

Bot vaults currently share all trading profit with depositors. Creators and Merkato need a way to earn from successful bots without taking idle collateral, jumping the ERC-7540 queue, or charging LPs who are underwater. Copy-trading analogs (Hyperliquid user vaults, Yearn, Morpho, dHEDGE) use a high-water-mark performance fee paid in shares.

## What Changes

- Each vault charges a **performance fee** on profit above a vault-level high-water mark, using **fee-safe NAV** (idle + escrow + complete sets only — not unpaired inventory at 1.0).
- Fees are paid by **minting shares** to a FeeSplitter (creator + Merkato treasury). Assets stay in the vault. Recipients exit via ERC-4626 / ERC-7540 like any LP.
- Default **10%** of profit (`1000` bps), factory cap **20%**. Merkato takes **20% of that fee** (net 8% creator / 2% treasury). **0%** management, entry, and exit fees.
- Crystallize on deposit/mint, withdraw/redeem/requestRedeem, venue `redeem`, and permissionless `harvestFees()`.
- Factory stores `treasury`, `protocolFeeBps`, `maxPerformanceFeeBps`. `createVault` takes `performanceFeeBps` and `creatorFeeRecipient`. Fee mints MUST NOT change principal or the seed cap.

**Roles:** Depositors hold shares of vault capital. The vault is the trading identity. The operator may trade idle vault capital only and MUST NOT pick fee destinations or withdraw. The creator seeds the vault and receives fee shares via a recipient that is not mixed into owner principal. Factory admin sets treasury and global fee caps.

## Non-goals

- Management, entry, or exit fees; per-trade / per-fill fees; pulling idle assets to fee wallets; per-depositor HWM; changing `totalAssets()` inventory mark; adapter trading ABI; frontend; fee increases after create; Yearn-style profit unlocking.

## Capabilities

### New Capabilities

- None. Fee behavior belongs on the existing vault and factory.

### Modified Capabilities

- `bot-vault`: HWM performance fee, fee-safe NAV, share mint without principal, crystallize points, FeeSplitter recipient, operator still cannot drain.
- `vault-factory`: Treasury, protocol take of performance shares, max performance bps, createVault fee params.

## Impact

`BotVault.sol`, `VaultFactory.sol`, `Errors.sol`, initialize/`createVault` ABI (**BREAKING** for new clones; existing clones unchanged until re-deploy). Foundry tests for harvest, HWM, phantom inventory, unauthorized recipients, principal isolation. IERC4626 remains the depositor interface; ERC-7540 is unchanged except crystallization before queue/claim. DreamDEX: unpaired Yes/No MUST NOT mint fees; harvest after venue redeem when PnL hits collateral. Threats this must not introduce: operator-chosen recipients, idle skim vs `reservedForClaims`, fee mint raising seed cap, performance on `max(yes,no)` NAV, views that revert, silent clamps.
