## MODIFIED Requirements

### Requirement: Market and pool validation
Operator-supplied `marketId` MUST be validated against the configured `BinaryMarketsModule`. The vault MUST read the live module market record for that id — pool, per-window market, outcome ids, origin operator id, origin venue id, collateral, and expiry — and MUST NOT use a caller-supplied pool, market, or outcome-token address. The record's collateral MUST equal the vault `asset()`. State MUST be keyed by `marketId`, never by pool address. Approvals MUST be limited to allowlisted venue contracts (module, resolved pool, settlement, outcome token) and MUST NOT be `type(uint256).max` to unknown spenders. A `marketId` unknown to the module, a zero pool, or a collateral mismatch MUST revert with a named error.

#### Scenario: Unknown marketId reverts
- **WHEN** the operator submits a write with a `marketId` that the module does not list
- **THEN** the call reverts with a named error

#### Scenario: Caller-supplied pool is ignored
- **WHEN** the operator includes a pool address that is not the module's pool for that `marketId`
- **THEN** the vault does not send the order to that pool (either it uses the module's pool or it reverts with a named error)

#### Scenario: Collateral mismatch reverts
- **WHEN** the module record's collateral for `marketId` is not the vault asset
- **THEN** the call reverts with a named error and no venue write occurs

### Requirement: On-chain status gating
Place, mint, and merge MUST execute only when the per-window market contract's live `status()` is Trading (1). The vault MUST NOT treat any field of the module `markets` record as market status. Those writes on any other status MUST revert with a named error. Cancel and reduce MAY succeed while the market is Locked. Redeem MUST execute only when the market is Resolved or Voided; redeem on a still-trading or locked market MUST revert with a named error. Views that need status MUST NOT revert the ERC-4626 view surface.

#### Scenario: Order on non-trading market reverts
- **WHEN** the operator places an order for a market whose on-chain status is not Trading
- **THEN** the call reverts with a named error

#### Scenario: Mint while market is Trading succeeds past the status gate
- **WHEN** the operator mints a complete set for a `marketId` whose market contract `status()` is Trading (1), even though the module record has no status field
- **THEN** the vault does not revert for `MarketNotTrading` and proceeds to the venue mint if idle capital is sufficient

#### Scenario: Redeem after resolution
- **WHEN** a market is Resolved or Voided and the vault holds the claimable outcome
- **THEN** the operator can redeem into the vault; on Voided both sides are redeemable at 0.5 collateral per contract

## ADDED Requirements

### Requirement: Event Contracts write surface
Place MUST be forwarded to the resolved pool as a binary order whose `kind` is the operator-supplied side (0 BUY_YES, 1 SELL_YES, 2 BUY_NO, 3 SELL_NO). The vault MUST NOT call the generic spot `placeOrder` on a binary pool. Mint and merge MUST be forwarded to the module with the record's origin operator id and venue id plus `marketId` and amount; minted Up and Down MUST be credited to the vault. Reduce MUST set the order's remaining quantity to the operator-supplied remaining size (not a delta). Redeem MUST be forwarded to the module with those origin ids, `marketId`, outcome index, and amount, and proceeds MUST return to the vault. `expireTimestampNs` MUST be non-zero and MUST NOT exceed the market's expiry; otherwise the write MUST revert with a named error.

#### Scenario: Mint pulls vault collateral and credits vault outcomes
- **WHEN** the trading operator mints a complete set of amount `A` on a Trading market with idle collateral at least `A`
- **THEN** `A` collateral leaves the vault to the venue and the vault holds `A` Up and `A` Down; the operator EOA balance is unchanged

#### Scenario: Place uses binary kind not spot placeOrder
- **WHEN** the trading operator places a buy through the vault on a Trading market with sufficient idle collateral
- **THEN** the resolved pool receives a binary place with that side as `kind` and the vault is the order owner

#### Scenario: Expiry past market expiry reverts
- **WHEN** the operator places an order with `expireTimestampNs` greater than the market expiry
- **THEN** the call reverts with a named error and no venue write occurs

### Requirement: Probability scale for buy notional
Buy collateral required MUST be `price * quantity / 1e6` using the venue's 1e6 probability units, not `asset.decimals()`. A buy whose required collateral exceeds idle vault collateral MUST revert with a named error. Approvals for that buy MUST be exact-amount to the resolved pool.

#### Scenario: tUSDC buy sizes from 1e6 price
- **WHEN** the operator places BUY_YES at price `900000` and quantity `1e6` with idle collateral of `9e5`
- **THEN** the vault allows the notional of `9e5` and does not treat the price as 18-decimal

#### Scenario: Underfunded 1e6-priced buy reverts
- **WHEN** the operator places a buy whose `price * quantity / 1e6` exceeds idle collateral
- **THEN** the call reverts with a named error and idle balances are unchanged

### Requirement: NAV does not depend on a pool escrowOf view
`totalAssets()` MUST include idle collateral, tracked escrow from successful place/cancel/reduce idle deltas, claimable pool withdrawable collateral when that view exists, and outcome inventory, and MUST NOT revert if the pool has no `escrowOf` function.

#### Scenario: Missing escrowOf does not revert NAV
- **WHEN** `totalAssets()` is read for a vault that tracks a market whose pool does not implement `escrowOf`
- **THEN** the call returns a NAV and does not revert
