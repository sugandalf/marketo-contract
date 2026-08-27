## Purpose

Registers each bot by deploying an isolated vault that the creator must seed, that depositors can find and fund up to an admin-set principal cap, with a one-to-one operator-to-vault mapping for the frontend list.

## ADDED Requirements

### Requirement: Permissionless vault creation with creator seed
The factory MUST allow any caller to create a vault by supplying a non-zero trading-operator address, share name, share symbol, the venue collateral asset, and a non-zero seed asset amount. Creation MUST deploy a new vault, bind that operator to it, set the caller as the vault owner, pull `seedAssets` from the caller into the vault, mint the corresponding ERC-4626 shares to the caller, and emit a `VaultCreated` event that includes the vault address, owner, operator, asset, and seed. Creation MUST revert with a named error if the operator is the zero address, the asset is the zero address, `seedAssets` is zero, the caller cannot fund the seed, or that operator already has a vault.

#### Scenario: First vault for an operator
- **WHEN** a caller creates a vault for operator `O` with a non-zero collateral asset and non-zero `seedAssets` they can fund
- **THEN** a new vault is deployed, `vaults(O)` returns that vault, the caller is the vault owner, `O` is the trading operator, the vault holds the seed as creator principal, the caller holds the seed shares, and `VaultCreated` is emitted

#### Scenario: Zero operator reverts
- **WHEN** a caller creates a vault with operator address zero
- **THEN** the call reverts with a named error and no vault is deployed

#### Scenario: Zero asset reverts
- **WHEN** a caller creates a vault with asset address zero
- **THEN** the call reverts with a named error and no vault is deployed

#### Scenario: Zero seed reverts
- **WHEN** a caller creates a vault with `seedAssets` equal to zero
- **THEN** the call reverts with a named error and no vault is deployed

### Requirement: One vault per operator
The factory MUST enforce a 1:1 mapping from trading operator to vault. A second create for the same operator MUST revert with a named error. Distinct operators MUST receive distinct vaults. Vault capital MUST NOT be shared across operators.

#### Scenario: Duplicate operator reverts
- **WHEN** a vault already exists for operator `O` and a caller creates another vault for `O`
- **THEN** the call reverts with a named error and the original vault is unchanged

#### Scenario: Distinct operators are isolated
- **WHEN** callers create vaults for operators `O1` and `O2`
- **THEN** two different vault addresses are recorded and neither vault can move the other's assets

### Requirement: Enumerable registry
The factory MUST expose views that return the vault for an operator, the operator for a vault, the number of vaults, and the vault at a given index, without reverting for in-range indexes. Out-of-range index MUST revert with a named error. The frontend MUST be able to list every registered bot as a vault address using only these views.

#### Scenario: List after two creates
- **WHEN** two vaults have been created
- **THEN** `vaultCount()` is 2 and `vaultAt(0)` and `vaultAt(1)` return those addresses

#### Scenario: Out-of-range index reverts
- **WHEN** `vaultAt(n)` is called with `n >= vaultCount()`
- **THEN** the call reverts with a named error

### Requirement: Admin-only deposit cap
The factory MUST store a global `depositCapBps` used by every vault, default **50000** (500% of creator principal). Only the factory admin MUST be able to change it, via a state-changing setter that emits an event with the old and new values. The setter MUST revert with a named error if the caller is not the admin or if the new value is below **10000** (100%) or above **1000000** (10000%). Vault owners and trading operators MUST NOT be able to change the cap. Vaults MUST read the live factory value on deposit so an admin change applies immediately. Lowering the cap MUST NOT force withdrawals; it MUST only block new principal that would exceed the new cap.

#### Scenario: Default cap is 500%
- **WHEN** the factory is deployed and a creator seeds 10 asset units
- **THEN** `depositCapBps` is 50000 and third-party principal is accepted until total principal would exceed 50

#### Scenario: Admin updates cap
- **WHEN** the factory admin sets `depositCapBps` to a value in [10000, 1000000]
- **THEN** the stored cap updates, an event is emitted, and subsequent vault `maxDeposit` uses the new value

#### Scenario: Non-admin cannot change cap
- **WHEN** a vault owner, trading operator, or any non-admin calls the cap setter
- **THEN** the call reverts with a named error and `depositCapBps` is unchanged

#### Scenario: Out-of-range cap reverts
- **WHEN** the admin sets `depositCapBps` to 9999 or 1000001
- **THEN** the call reverts with a named error
