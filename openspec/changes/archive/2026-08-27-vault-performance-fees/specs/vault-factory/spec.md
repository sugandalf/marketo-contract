## MODIFIED Requirements

### Requirement: Permissionless vault creation with creator seed
The factory MUST allow any caller to create a vault by supplying a non-zero trading-operator address, share name, share symbol, the venue collateral asset, a non-zero seed asset amount, a `performanceFeeBps` in `[0, maxPerformanceFeeBps]`, and a creator fee recipient. Creation MUST deploy a new vault, bind that operator to it, set the caller as the vault owner, configure that vault's `performanceFeeBps` and `creatorFeeRecipient`, pull `seedAssets` from the caller into the vault, mint the corresponding ERC-4626 shares to the caller, initialize the vault high-water mark so the seed is not profit, and emit a `VaultCreated` event that includes the vault address, owner, operator, asset, seed, `performanceFeeBps`, and `creatorFeeRecipient`. Creation MUST revert with a named error if the operator is the zero address, the asset is the zero address, `seedAssets` is zero, the caller cannot fund the seed, that operator already has a vault, `performanceFeeBps` exceeds `maxPerformanceFeeBps`, `performanceFeeBps > 0` and `creatorFeeRecipient` is the zero address, or `performanceFeeBps > 0` and `protocolFeeBps > 0` and treasury is the zero address. Vault owner and operator MUST NOT change `performanceFeeBps` or `creatorFeeRecipient` after creation.

#### Scenario: First vault for an operator
- **WHEN** a caller creates a vault for operator `O` with a non-zero collateral asset, non-zero `seedAssets` they can fund, `performanceFeeBps` of 1000, and a non-zero `creatorFeeRecipient`
- **THEN** a new vault is deployed, `vaults(O)` returns that vault, the caller is the vault owner, `O` is the trading operator, the vault holds the seed as creator principal, the caller holds the seed shares, the vault stores 1000 bps and that recipient, the high-water mark equals post-seed fee-safe share price, and `VaultCreated` is emitted

#### Scenario: Zero operator reverts
- **WHEN** a caller creates a vault with operator address zero
- **THEN** the call reverts with a named error and no vault is deployed

#### Scenario: Zero asset reverts
- **WHEN** a caller creates a vault with asset address zero
- **THEN** the call reverts with a named error and no vault is deployed

#### Scenario: Zero seed reverts
- **WHEN** a caller creates a vault with `seedAssets` equal to zero
- **THEN** the call reverts with a named error and no vault is deployed

#### Scenario: Fee above factory max reverts
- **WHEN** a caller creates a vault with `performanceFeeBps` greater than `maxPerformanceFeeBps`
- **THEN** the call reverts with a named error and no vault is deployed

#### Scenario: Missing fee recipient reverts when fee is on
- **WHEN** a caller creates a vault with `performanceFeeBps` greater than 0 and `creatorFeeRecipient` equal to the zero address
- **THEN** the call reverts with a named error and no vault is deployed

#### Scenario: Zero performance fee is allowed
- **WHEN** a caller creates a vault with `performanceFeeBps` equal to 0 and a zero or non-zero `creatorFeeRecipient`
- **THEN** the vault is deployed and later harvest mints no fee shares

## ADDED Requirements

### Requirement: Admin-only treasury and protocol take
The factory MUST store `treasury` (Merkato fee recipient) and `protocolFeeBps` (share of each vault's crystallized performance fee minted to treasury). Default `protocolFeeBps` MUST be **2000** (20% of the performance fee). Only the factory admin MUST be able to set `treasury` and `protocolFeeBps`. Setting treasury to the zero address MUST revert with a named error if `protocolFeeBps > 0`. Setting `protocolFeeBps` above **10000** MUST revert with a named error. Vault owners and trading operators MUST NOT change these values. Vaults MUST read the live factory treasury and `protocolFeeBps` at crystallization. Changing them MUST NOT rewrite already-minted fee shares.

#### Scenario: Default protocol take is 20% of the fee
- **WHEN** the factory is deployed
- **THEN** `protocolFeeBps` is 2000

#### Scenario: Admin sets treasury
- **WHEN** the factory admin sets a non-zero treasury
- **THEN** the stored treasury updates, an event is emitted, and subsequent harvests mint the protocol portion to that address

#### Scenario: Non-admin cannot set treasury or protocol take
- **WHEN** a vault owner, trading operator, or any non-admin calls the treasury or `protocolFeeBps` setter
- **THEN** the call reverts with a named error and storage is unchanged

### Requirement: Admin-only max performance fee
The factory MUST store `maxPerformanceFeeBps` used by every `createVault`, default **2000** (20%). Only the factory admin MUST be able to change it. The setter MUST revert with a named error if the caller is not the admin or if the new value is above **2000**. Lowering the max MUST NOT change already-created vaults' `performanceFeeBps`; it MUST only reject new creates above the new max. Vault owners and trading operators MUST NOT change the max.

#### Scenario: Default max is 20%
- **WHEN** the factory is deployed
- **THEN** `maxPerformanceFeeBps` is 2000 and a create with 2000 succeeds while 2001 reverts

#### Scenario: Lowering the max does not rewrite live vaults
- **WHEN** a vault was created with 2000 bps and the admin later sets `maxPerformanceFeeBps` to 1000
- **THEN** that vault still charges 2000 bps and a new create with 1500 reverts
