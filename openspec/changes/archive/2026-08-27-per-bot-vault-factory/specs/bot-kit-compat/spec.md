## Purpose

Makes dreamdex-bot-kit event-contract bots compatible with the vault so the operator key can trade vault capital without ever holding depositor funds.

## ADDED Requirements

### Requirement: Operator write surface matches bot actions
The vault MUST expose trading-operator functions covering every write an event-contract bot needs: place order, cancel order, reduce order, mint complete set, merge complete set, and redeem. Each function MUST take `marketId` (not a hardcoded pool), side, price, quantity, `expireTimestampNs`, and order type as required by the venue, and MUST be usable with `@somnia-chain/markets-sdk` >= 0.28.0 for reads. `expireTimestampNs` of 0 MUST revert with a named error.

#### Scenario: Bot can place via vault ABI
- **WHEN** the trading operator calls the vault place function with a valid Trading `marketId`, non-zero lot-aligned quantity, tick-aligned price, and future `expireTimestampNs`
- **THEN** the vault forwards the order to the venue as the trading identity

#### Scenario: Zero expiry reverts
- **WHEN** the operator places an order with `expireTimestampNs` equal to 0
- **THEN** the call reverts with a named error

### Requirement: Adapter treats vault as the trader
The TypeScript adapter MUST sign transactions with the trading-operator key and MUST set the vault address as the account used for balance, inventory, and open-order reads. The adapter MUST NOT pass the operator private key to the SDK as a funded `privateKey` that auto-pulls from a user wallet. The adapter MUST NOT call depositor `withdraw`/`redeem`/`requestRedeem`.

#### Scenario: Reads use vault address
- **WHEN** the adapter checks collateral or ERC-6909 outcome balances before a write
- **THEN** it queries the vault address, not the operator EOA

#### Scenario: Adapter cannot withdraw
- **WHEN** the adapter's supported methods are enumerated
- **THEN** they include only operator trade functions and exclude IERC4626 withdraw, redeem, and ERC-7540 requestRedeem

### Requirement: Idle-capital preflight is on-chain enforceable
A place or mint that needs more idle collateral than the vault holds MUST revert with a named error. A sell or merge that needs more outcome tokens than the vault holds MUST revert with a named error. The adapter MAY additionally check balances off-chain, but on-chain revert remains authoritative.

#### Scenario: Adapter-sized buy still reverts if vault is short
- **WHEN** the operator submits a buy larger than vault idle collateral, even if the operator EOA holds the asset
- **THEN** the vault reverts with a named error and the operator EOA balance is unchanged
