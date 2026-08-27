## MODIFIED Requirements

### Requirement: Role isolation
Every state-changing function MUST name its caller role: depositor (or ERC-7540 claim-operator), trading operator, vault owner, or permissionless fee harvest. Unauthorized callers MUST revert with a named error. The trading operator MUST NOT withdraw, rescue, or transfer collateral or outcome tokens to itself or an arbitrary address, and MUST NOT set fee recipients or fee rates. The vault owner MAY rotate the trading operator to a non-zero address and MUST NOT have a path that skims depositor assets. Permissionless harvest MUST only mint fee shares to the configured creator fee recipient and the factory treasury. Value-moving functions MUST be non-reentrant and follow checks-effects-interactions.

#### Scenario: Stranger cannot trade or withdraw
- **WHEN** an address that is not owner, trading operator, or share owner calls a trading or withdrawal function
- **THEN** the call reverts with a named error

#### Scenario: Stranger can harvest fees
- **WHEN** an address that is not owner, trading operator, or share owner calls fee harvest while fee-safe share price is above the high-water mark
- **THEN** the call succeeds and fee shares are minted only to the creator fee recipient and factory treasury

#### Scenario: Operator cannot drain to self
- **WHEN** the trading operator attempts to transfer vault collateral or outcome tokens to the operator or any non-venue recipient
- **THEN** the call reverts with a named error and vault balances are unchanged

#### Scenario: Owner rotates operator
- **WHEN** the vault owner sets a new non-zero trading operator
- **THEN** the old operator's trade calls revert and the new operator's authorized trade calls succeed

## ADDED Requirements

### Requirement: Fee-safe NAV for performance fees
Performance fees MUST be computed from fee-safe NAV, not from `totalAssets()`. Fee-safe NAV MUST equal idle collateral plus tracked venue escrow plus, for each tracked market, `min(yes, no)` complete-set inventory valued 1:1 in collateral. Unpaired outcome tokens MUST contribute 0 to fee-safe NAV. Fee-safe NAV views MUST NOT revert. `totalAssets()` MUST keep its existing inventory ceiling (`max(yes, no)` per market) and MUST NOT be used as the performance-fee base.

#### Scenario: Unpaired inventory does not create fees
- **WHEN** the vault holds unpaired Yes (or No) and idle plus escrow plus complete sets are unchanged since the last high-water mark
- **THEN** fee harvest mints zero shares even if `totalAssets()` rose because unpaired inventory is marked at 1.0

#### Scenario: Complete sets count for fees
- **WHEN** the vault holds mergeable Yes and No of amount `P` and idle plus escrow are otherwise unchanged
- **THEN** fee-safe NAV includes `P` of collateral value for that market

### Requirement: High-water-mark performance fee
The vault MUST charge a performance fee only on fee-safe share-price gains above a vault-level high-water mark. Performance fee assets MUST equal `max(feeSafePps - hwm, 0) * supply / 1e18 * performanceFeeBps / 10000`, with rounding that favors remaining depositors (fees round down). The high-water mark MUST never decrease. After a crystallization that finds fee-safe PPS above the mark, the mark MUST be set to fee-safe PPS computed after fee shares are minted (or unchanged PPS when minted shares round to zero). Seed deposit at vault creation MUST initialize the high-water mark so the seed itself is not treated as profit. Management, entry, and exit fees MUST be zero. Views that report fee-safe NAV, high-water mark, and `performanceFeeBps` MUST NOT revert.

#### Scenario: Profit above the mark mints a 10% fee
- **WHEN** `performanceFeeBps` is 1000, fee-safe NAV rises from 100 to 120 with unchanged supply, and harvest runs
- **THEN** fee assets equal 2 and the high-water mark updates to the post-mint fee-safe share price

#### Scenario: Drawdown pays no fee
- **WHEN** fee-safe share price is at or below the high-water mark
- **THEN** harvest mints zero shares and the high-water mark is unchanged

#### Scenario: Recovery to the old peak pays no fee
- **WHEN** fee-safe share price fell below the high-water mark and later returns to that mark but not above it
- **THEN** harvest mints zero shares

### Requirement: Fee paid in shares without principal
Crystallized fees MUST be paid by minting vault shares, not by transferring idle collateral. Protocol shares MUST equal `feeShares * factory.protocolFeeBps() / 10000` (rounded down) minted to `factory.treasury()`; remaining fee shares MUST be minted to `creatorFeeRecipient`. Those mints MUST NOT increase any account's principal or `totalPrincipal`, MUST NOT raise the deposit cap, and MUST NOT transfer assets out of the vault. A later withdraw, redeem, or share transfer of fee-originated shares MUST NOT reduce `creatorPrincipal` or `totalPrincipal`. Fee recipients MUST exit only through IERC4626 `withdraw`/`redeem` or ERC-7540 `requestRedeem`, subject to idle-only `maxWithdraw` and the redeem queue; they MUST NOT jump `reservedForClaims`. The trading operator MUST NOT choose the mint destinations.

#### Scenario: Harvest dilutes supply and leaves idle unchanged
- **WHEN** harvest mints a non-zero fee
- **THEN** total supply increases by the minted shares, idle collateral is unchanged, and `totalPrincipal` is unchanged

#### Scenario: Protocol take is a cut of the fee
- **WHEN** fee shares are 100 and `protocolFeeBps` is 2000
- **THEN** 20 shares are minted to the factory treasury and 80 to `creatorFeeRecipient`

#### Scenario: Fee redeem does not loosen the seed lock
- **WHEN** fee shares were minted to `creatorFeeRecipient` (including when that address is the vault owner) and that holder redeems only those fee shares
- **THEN** `creatorPrincipal` and `totalPrincipal` are unchanged and the live deposit cap is unchanged

#### Scenario: Operator cannot retarget fees
- **WHEN** the trading operator calls harvest or any fee function with a recipient other than the configured creator fee recipient and factory treasury
- **THEN** the call reverts with a named error, or no such parameter exists, and no assets leave the vault

### Requirement: Crystallize on share-supply change and venue redeem
The vault MUST crystallize performance fees before IERC4626 `deposit`/`mint`/`withdraw`/`redeem`, before ERC-7540 `requestRedeem`, and after a successful venue `redeem`. Anyone MUST be able to call a state-changing harvest that crystallizes the same way. Crystallization MUST revert with a named error if `performanceFeeBps > 0` and a required recipient is the zero address. Crystallization MUST NOT revert IERC4626 views. Harvest when profit rounds to zero shares MUST succeed, mint nothing, and still update the high-water mark when fee-safe PPS is above the prior mark.

#### Scenario: Deposit crystallizes before new shares
- **WHEN** fee-safe share price is above the high-water mark and a depositor then `deposit`s
- **THEN** fee shares are minted first, then the depositor's shares are minted at the post-fee price

#### Scenario: Venue redeem crystallizes realized collateral
- **WHEN** the operator redeems a resolved market and idle collateral rises so fee-safe PPS exceeds the high-water mark
- **THEN** that transaction mints the due fee shares before completing

#### Scenario: Missing treasury reverts harvest when protocol take is on
- **WHEN** `performanceFeeBps` and `protocolFeeBps` are non-zero and factory treasury is the zero address
- **THEN** harvest and any crystallizing state-changing call revert with a named error
