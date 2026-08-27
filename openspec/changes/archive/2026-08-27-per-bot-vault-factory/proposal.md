## Why

Marketo needs one isolated vault per registered bot so depositors can copy-trade DreamDEX event contracts without handing keys to the bot. Creators must seed capital so they have skin in the game, and third-party deposits must be capped as a multiple of that seed. The repo is still a Foundry stub (`Counter`).

## What Changes

- **VaultFactory:** one vault per bot; creator MUST seed a non-zero deposit in the same tx.
- **Skin in the game:** outstanding *principal* (assets in via `deposit`/`mint`, reduced pro-rata on exit — not NAV) cannot exceed `creatorPrincipal × depositCapBps / 10000`. Default **500%** (seed 10 → max 50 principal). Profits do not consume or expand the cap. Only factory **admin** can change `depositCapBps`.
- **ERC-4626** vault (OZ, decimal offset); `asset()` is USDso / tUSDC. `maxDeposit` is remaining principal room.
- **ERC-7540 `requestRedeem`** for exit while capital is locked. Deposits stay sync. ERC-7540 `setOperator` is a claim-operator, not the bot.
- The **vault is the trading identity**. The bot is a trading operator (place/cancel/reduce, mint/merge, redeem) and cannot withdraw to itself.
- Resolve `pool` from `BinaryMarketsModule.markets(marketId)`; gate writes on on-chain `Trading`.
- Thin **TypeScript adapter** so dreamdex-bot-kit `ec-*` bots (`@somnia-chain/markets-sdk` ≥ 0.28.0) sign as operator and route writes through the vault.

## Capabilities

### New Capabilities

- `vault-factory`: Seeded registration; 1:1 operator→vault; enumerable list; admin-only cap bps.
- `bot-vault`: ERC-4626, principal cap vs seed, NAV, idle `maxWithdraw`, ERC-7540, roles.
- `dreamdex-event-trading`: Operator-only venue writes against the allowlisted core.
- `bot-kit-compat`: Vault ABI + TS adapter so `ec-*` bots trade vault capital without holding it.

### Modified Capabilities

- None (no main specs yet).

## Impact

Replaces `Counter` with Foundry contracts + OpenZeppelin. Somnia 50312 / 5031. Venue core is CREATE3-stable ([addresses](https://docs.dreamdex.io/developers/event-contracts/contracts-and-addresses.md)); do not hardcode pools.

**Roles:** Depositors hold shares; the vault holds capital; the operator trades it; the creator must keep seed so the cap still covers LPs; factory admin sets the global cap.

**Venue bounds:** HTTP API is spot-only. Key state by `marketId`. Collateral decimals 18 vs 6.

**Threats this must not introduce:** unauthorized withdraw, operator drain, unbounded approvals, share inflation, silent clamps, reentrancy, rogue pool ids, creator pulling seed while LPs remain, cap keyed off NAV.

## Non-goals

- Bot alpha; spot vaults; fees; ERC-7540 async deposit; ERC-7575; forking dreamdex-bot-kit; a frontend; per-vault cap overrides.
