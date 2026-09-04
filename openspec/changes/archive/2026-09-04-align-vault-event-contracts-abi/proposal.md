## Why

Operator `mintCompleteSet` never leaves simulation: the vault ABI-decodes `BinaryMarketsModule.markets(marketId)` as `{market, pool, yesId, noId, status}` and reverts `MarketNotTrading()` (`0x3a67d481`) before any venue write or tUSDC pull. The live module record has **no status field**; on-chain `status() == Trading (1)` lives on the market contract. Place and auto-redeem cannot run until mint works. Align the vault with the verified Event Contracts ABI ([DreamDEX Solidity path](https://github.com/IronicDeGawd/ec-dreamdex-hackathon-template/tree/main/solidity) and `@somnia-chain/markets-sdk` ≥ 0.28).

Depositors hold ERC-4626 shares of vault collateral. The vault is the trading identity. The bot is only `tradingOperator` and must not withdraw or retarget funds.

## What Changes

- Decode the live `markets(marketId)` 14-field tuple (pool, market, yes/no ids, origin operator/venue, collateral, expiry). Unknown or zero pool, or collateral ≠ `asset()`, reverts `InvalidMarket`.
- Gate place/mint/merge on `IBinaryMarket.status() == Trading (1)`, not a module `status` field. Redeem on Resolved (4) or Voided (5). Views still must not revert.
- **BREAKING (venue internals):** mint/merge via `mintCompleteSet`/`mergeCompleteSet(operatorId, venueId, marketId, amount)` using origin ids from the module record (operator still passes `marketId` only). Place via `placeBinaryOrder` (`kind` = vault `Side`). Reduce via `reduceOrder(orderId, newQuantityRemaining)`. Redeem via module `redeem(operatorId, venueId, marketId, outcomeIdx, amount)`.
- Buy notional uses venue probability scale **1e6**, not `asset.decimals()`. Approvals remain exact-amount to allowlisted pool/module/settlement/outcome token.
- NAV escrow: stop calling non-existent `escrowOf`; keep idle-delta accounting; treat `getWithdrawableBalance` as vault capital without reverting views.
- Mocks, Foundry trading tests, vault adapter, and README match the live ABI.

## Non-goals

- No ERC-4626/7540, fee, or factory-mapping changes.
- No `pool.deposit` pre-funding (auto-pull from vault idle). No CollateralRouter/Permit2/native mint.
- No in-place upgrade of existing EIP-1167 clones (new implementation + factory required).
- No bot strategy or indexer work.

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `dreamdex-event-trading`: live module record, market-contract status, Event Contracts write surface, 1e6 price scale, NAV without `escrowOf`.
- `bot-kit-compat`: reduce remaining-quantity semantics; adapter still marketId-only; reads stay on the vault.

## Impact

`src/interfaces/*`, `BotVault` trading/NAV, `test/mocks/MockVenue.sol`, `test/Trading.t.sol`, `integrations/vault-adapter`, README §8. Capital threats this must not introduce: operator-supplied pool drain, unbounded approvals, mint/place without Trading, redeem to a non-vault recipient, views that revert. **Blocker:** already-deployed clones keep the broken ABI until creators redeploy through a new factory.
