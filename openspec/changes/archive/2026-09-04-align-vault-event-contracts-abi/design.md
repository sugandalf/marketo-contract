## Context

See `proposal.md` for motivation and `specs/dreamdex-event-trading`, `specs/bot-kit-compat` for requirements.

Today `BotVault` is the ERC-4626 trading identity; `tradingOperator` may place/cancel/reduce, mint/merge, and redeem. It decodes `module.markets(marketId)` as `{market, pool, yesId, noId, status}` and gates on `rec.status == 1`. Live `@somnia-chain/markets-sdk` ≥ 0.28 `binaryModuleReadAbi` returns a 14-field tuple with **no status**. Extra words are ignored; `pool` decodes as `outcomeSlotCount` (non-zero) so `InvalidMarket` does not fire, and `status` decodes as `originOperatorId` → `MarketNotTrading()` even when the market contract's `status()` is Trading. It also calls spot `placeOrder` (binary pools revert `UseBinaryPlacement`), `mintCompleteSet(marketId, amount)` (live needs `operatorId, venueId, marketId, amount`), and `BinarySettlement.redeem(marketId, …)` (live trader path is module `redeem`). `escrowOf` is not on the pool. Factory clones an immutable implementation: ABI fixes need a new factory.

ERC-4626 offset, 7540 queue, fees, and principal cap stay as they are. `maxWithdraw` remains idle vault ERC-20 only.

## Goals / Non-Goals

**Goals:**

- Pin Solidity interfaces to live Event Contracts ABIs (module read/write, `placeBinaryOrder` / `mintSet` family, `IBinaryMarket.status()`).
- Keep operator calldata `marketId`-only; resolve pool, ids, and origin `(operatorId, venueId)` from the module.
- Fail closed on collateral mismatch, non-Trading mint/place/merge, over-expiry, underfunded buys, unauthorized callers.
- NAV must not revert when `escrowOf` is missing.

**Non-Goals:**

- Pool `deposit` pre-funding, CollateralRouter, Permit2, native mint.
- Proxy upgrade of existing clones.
- Changing 4626 share math or 7540.

## Decisions

### 1. Decode the live 14-field `markets` tuple; status from the market contract

Replace `MarketRecord` with the SDK layout: `oracleQuestionId, outcomeSlotCount, voidPolicy, collateral, originOperatorId, originVenueId, oracleAdapter, creator, market, pool, yesId, noId, tradingStart, expiry`. `_market(marketId)` reverts `InvalidMarket` if `pool == 0` or `collateral != asset()`. Place/mint/merge read `IBinaryMarket(rec.market).status()` and revert `MarketNotTrading` unless it is `1`. Redeem requires `4` or `5`. Do not use any module field as status.

Alternative: operator-supplied pool + `getBinaryPoolParams()`. Rejected — violates marketId-only allowlisting and lets the operator pick a pool.

Alternative: `isResolved` / `isVoided` / `finalized` only. Rejected — does not distinguish Listed vs Trading vs Locked.

### 2. Module mint/merge/redeem, pool `placeBinaryOrder`

| Vault fn | Venue call | Approval |
|---|---|---|
| `mintCompleteSet(marketId, amount)` | `module.mintCompleteSet(originOperatorId, originVenueId, marketId, amount)` | exact collateral to **module** |
| `mergeCompleteSet(marketId, amount)` | `module.mergeCompleteSet(…)` | exact 6909 yes/no to **module** |
| `placeOrder(…, side, …)` | `pool.placeBinaryOrder(uint8(side), price, qty, expiryNs, orderType, 0, address(0), 0, 0)` | buy: exact notional to **pool**; sell: pool pulls 6909 (exact approve or revert) |
| `reduceOrder(marketId, orderId, remaining)` | `pool.reduceOrder(orderId, remaining)` | none |
| `cancelOrder` | `pool.cancelOrder(orderId)` | none |
| `redeem(marketId, outcomeIdx, amount)` | `module.redeem(originOperatorId, originVenueId, marketId, outcomeIdx, amount)` | exact 6909 to **module** |

`yesTo`/`noTo` on `pool.mintSet` would also credit the vault, but the module path matches venue docs (attribution ids, orchestrated mint) and needs no extra operator args. Do not call `placeOrder(bool isBid, …)` on a binary pool. Do not call settlement `redeem(outcomeId, amount, to)` — `to` would be a drain vector; module redeem pays `msg.sender` (the vault).

Expiry cap: `expireTimestampNs != 0` and `<= IBinaryPool(pool).marketExpiryNs()`; else `InvalidExpiry`. Module `expiry` is seconds; orders are nanoseconds — use the pool's ns view.

Buy notional: `(price * quantity) / 1e6` (venue probability scale). This is correct for both tUSDC (6) and USDso (18) because price is always 1e6, not `10 ** decimals()`.

### 3. Auto-pull; no `pool.deposit`

Keep idle as `asset.balanceOf(vault) - reservedForClaims`. Exact approve then venue pull. Pre-deposit would hide idle in the pool and break `maxWithdraw` unless every depositor path could withdraw it.

`syncMarket` (permissionless): refresh tracked escrow from idle deltas; if `getWithdrawableBalance(vault, asset) > 0`, `withdraw` that token to the vault (msg.sender is the vault). Include that withdrawable amount in `totalAssets` via try/catch; do not count it in `maxWithdraw` until swept. Drop `escrowOf`.

### 4. Mocks and tests mirror the live ABI

`MockModule.markets` returns the 14-field tuple. Separate `MockMarket.status()`. `MockPool.placeBinaryOrder` / `reduceOrder(remaining)`. Mint/merge/redeem take origin ids. Trading tests: mint succeeds when `status()==1` with a module record that has no status; wrong 5-field decode is not used. `vm.expectRevert` on collateral mismatch, `status()!=1`, expiry `> marketExpiryNs`, generic-place unused, non-operator, underfunded 1e6 buy.

Adapter: document 1e6 prices and reduce-as-remaining; keep `marketId`-only writes.

## State-changing trade surface

All below: `onlyTradingOperator` except `syncMarket` (anyone). `nonReentrant`. CEI: checks → effects (track market, escrow deltas) → venue interaction → clear approval.

| Function | MUST revert |
|---|---|
| `placeOrder` | `Unauthorized`; `InvalidAmount` (0 price/qty or place returns false); `InvalidExpiry`; `InvalidMarket`; `MarketNotTrading`; `InsufficientIdle` |
| `cancelOrder` / `reduceOrder` | `Unauthorized`; `InvalidMarket`; reduce: `InvalidAmount` if remaining == 0 |
| `mintCompleteSet` / `mergeCompleteSet` | `Unauthorized`; `InvalidAmount`; `InvalidMarket`; `MarketNotTrading`; mint: `InsufficientIdle`; merge: insufficient 6909 |
| `redeem` (venue) | `Unauthorized`; `InvalidAmount`; `InvalidMarket`; `MarketNotFinalized`; insufficient 6909 |
| `syncMarket` | `InvalidMarket` |

Operator cannot withdraw, rescue, or set `to`. IERC4626 / 7540 unchanged (depositor / claim-operator).

## Risks / Trade-offs

- [Existing clones stay broken] → New factory + new vaults; document; no silent “upgrade” of old addresses.
- [Wrong `markets` decode again if venue rolls the tuple] → Pin comments to SDK `binaryModuleReadAbi`; unknown id / zero pool / collateral mismatch still fail closed.
- [Reduce remaining vs delta] → Adapter README + tests; remaining 0 reverts.
- [Module mint vs `mintSet`] → If module mint reverts on testnet, fall back is a follow-up; first implementation is module (spec).
- [Withdrawable stuck in pool] → NAV includes it; `maxWithdraw` does not until `syncMarket` withdraws to the vault.

## Migration Plan

1. Ship interfaces + vault + mocks + tests in this repo.
2. Deploy new `VaultFactory` (constructor still module, settlement, outcome token, treasury).
3. Creators `createVault` again and move deposits; old clones are abandoned.
4. Point the bot adapter at the new vault.

Rollback: keep the old factory for existing vaults; they still cannot trade.

## Open Questions

None that block this design. Confirm on apply by calling Shannon `markets(marketId)` and `status()` against a live BTC window before broadcasting.
