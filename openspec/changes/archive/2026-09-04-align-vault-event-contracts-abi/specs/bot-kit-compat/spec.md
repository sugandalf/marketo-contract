## MODIFIED Requirements

### Requirement: Operator write surface matches bot actions
The vault MUST expose trading-operator functions covering every write an event-contract bot needs: place order, cancel order, reduce order, mint complete set, merge complete set, and redeem. Each function MUST take `marketId` (not a hardcoded pool) plus side, price, quantity, `expireTimestampNs`, and order type as required by the venue. The operator MUST NOT be required to pass pool, origin operator id, or venue id; the vault MUST resolve those from the module record. Reduce MUST take the order's new remaining quantity. The surface MUST be usable with `@somnia-chain/markets-sdk` >= 0.28.0 for reads. `expireTimestampNs` of 0 MUST revert with a named error.

#### Scenario: Bot can place via vault ABI
- **WHEN** the trading operator calls the vault place function with a valid Trading `marketId`, non-zero lot-aligned quantity, tick-aligned 1e6 price, and future `expireTimestampNs` at or below market expiry
- **THEN** the vault forwards the order to the venue as the trading identity

#### Scenario: Zero expiry reverts
- **WHEN** the operator places an order with `expireTimestampNs` equal to 0
- **THEN** the call reverts with a named error

#### Scenario: Mint needs only marketId
- **WHEN** the trading operator calls mint with a valid Trading `marketId` and a non-zero amount the vault can fund
- **THEN** the vault supplies origin operator id and venue id from the module record and the mint completes without extra operator calldata

## ADDED Requirements

### Requirement: Reduce uses remaining quantity
The vault reduce function MUST pass the operator-supplied size to the pool as the order's new remaining quantity. A remaining quantity of 0 MUST revert with a named error. The adapter MUST document remaining-quantity semantics, not a reduce-by delta.

#### Scenario: Reduce to remaining size
- **WHEN** the trading operator reduces a resting vault order to a non-zero remaining quantity the pool accepts
- **THEN** the pool keeps that order at the new remaining size and any freed escrow returns to the vault
