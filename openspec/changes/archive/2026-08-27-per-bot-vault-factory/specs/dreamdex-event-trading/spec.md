## Purpose

Lets the bot trade only as the vault against DreamDEX event contracts, with venue allowlisting, marketId checks, and fail-closed writes so depositor capital cannot leave except as escrow, settlement, or depositor exit.

## ADDED Requirements

### Requirement: Vault is the trading identity
The vault contract MUST be `msg.sender` on venue writes (place, cancel, reduce, mint complete set, merge complete set, redeem). Escrow MUST be pulled from vault balances. Cancel refunds, fill proceeds, merge proceeds, and redemption proceeds MUST return to the vault. The trading operator MUST NOT be the funded trader and MUST NOT mix operator-EOA funds with vault capital.

#### Scenario: Place order escrows vault collateral
- **WHEN** the trading operator successfully places a buy through the vault
- **THEN** collateral is escrowed from the vault (not the operator) and the order owner is the vault

#### Scenario: Cancel refunds the vault
- **WHEN** the trading operator cancels a resting vault bid
- **THEN** escrowed collateral returns to the vault address

### Requirement: Operator-only venue writes
Place, cancel, reduce, mint complete set, merge complete set, and redeem MUST be callable only by the current trading operator and MUST revert with a named error for any other caller. Each write MUST revert with a named error on zero size, insufficient idle vault capital or outcome inventory, or when the full venue action cannot complete. The vault MUST NOT silently clamp size.

#### Scenario: Non-operator place reverts
- **WHEN** a non-operator calls place, cancel, reduce, mint, merge, or redeem
- **THEN** the call reverts with a named error and no venue write occurs

#### Scenario: Underfunded trade reverts
- **WHEN** the operator places a buy larger than idle vault collateral
- **THEN** the call reverts with a named error and idle balances are unchanged

### Requirement: Market and pool validation
Operator-supplied `marketId` MUST be validated against the configured `BinaryMarketsModule`. The vault MUST read the market record (including pool and outcome ids) from the module and MUST NOT use a caller-supplied pool, market, or outcome-token address. State MUST be keyed by `marketId`, never by pool address. Approvals MUST be limited to allowlisted venue contracts (module, resolved pool, settlement, outcome token) and MUST NOT be `type(uint256).max` to unknown spenders. A `marketId` unknown to the module MUST revert with a named error.

#### Scenario: Unknown marketId reverts
- **WHEN** the operator submits a write with a `marketId` that the module does not list
- **THEN** the call reverts with a named error

#### Scenario: Caller-supplied pool is ignored
- **WHEN** the operator includes a pool address that is not the module's pool for that `marketId`
- **THEN** the vault does not send the order to that pool (either it uses the module's pool or it reverts with a named error)

### Requirement: On-chain status gating
Place, mint, and merge MUST execute only when the market's live on-chain status is Trading (1). Those writes on any other status MUST revert with a named error. Cancel and reduce MAY succeed while the market is Locked. Redeem MUST execute only when the market is Resolved or Voided; redeem on a still-trading or locked market MUST revert with a named error. Views that need status MUST NOT revert the ERC-4626 view surface.

#### Scenario: Order on non-trading market reverts
- **WHEN** the operator places an order for a market whose on-chain status is not Trading
- **THEN** the call reverts with a named error

#### Scenario: Redeem after resolution
- **WHEN** a market is Resolved or Voided and the vault holds the claimable outcome
- **THEN** the operator can redeem into the vault; on Voided both sides are redeemable at 0.5 collateral per contract

### Requirement: Venue-only token flow
Collateral and outcome tokens MUST leave the vault only to (a) allowlisted venue contracts for escrow/mint/merge/redeem, or (b) a depositor (or ERC-7540 claim-operator) via IERC4626 `withdraw`/`redeem`. Any other recipient MUST revert with a named error.

#### Scenario: Operator cannot set a custom recipient
- **WHEN** a venue write would send tokens to the operator or an arbitrary address
- **THEN** the call reverts with a named error
