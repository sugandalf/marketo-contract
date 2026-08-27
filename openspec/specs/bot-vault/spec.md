# bot-vault Specification

## Purpose

Gives depositors ERC-4626 shares of one bot's venue collateral, capped by the creator's seeded principal, while isolating trading from withdrawal, with async redeem when capital is locked in the venue.

## Requirements

### Requirement: ERC-4626 depositor interface
The vault MUST implement IERC4626 with `asset()` equal to the venue collateral configured at creation and `share()` equal to `address(this)`. Views `asset`, `totalAssets`, `convertToShares`, `convertToAssets`, `previewDeposit`, `previewMint`, `previewWithdraw`, `previewRedeem`, `maxDeposit`, `maxMint`, `maxWithdraw`, and `maxRedeem` MUST NOT revert. `deposit` and `mint` MUST revert with a named error if assets or shares are zero or the full amount cannot be taken. `withdraw` and `redeem` MUST revert with a named error if the full amount cannot be paid from idle collateral and the owner's shares. Successful `deposit`/`mint` MUST emit `Deposit`. Successful `withdraw`/`redeem` MUST emit `Withdraw`. Rounding MUST favor the vault. The vault MUST report IERC4626 (and IERC7575 share when `share() == address(this)`) via ERC-165.

#### Scenario: Deposit mints shares
- **WHEN** a depositor with sufficient asset allowance calls `deposit(assets, receiver)` for a non-zero amount within `maxDeposit`
- **THEN** assets move from the depositor to the vault, shares are minted to `receiver`, and `Deposit` is emitted

#### Scenario: Zero deposit reverts
- **WHEN** a depositor calls `deposit(0, receiver)`
- **THEN** the call reverts with a named error and no shares are minted

#### Scenario: Over-withdraw reverts
- **WHEN** an owner calls `withdraw` for more assets than `maxWithdraw(owner)`
- **THEN** the call reverts with a named error and balances are unchanged

### Requirement: NAV is not raw idle balance
`totalAssets()` MUST return NAV in asset units as idle collateral plus tracked venue escrow plus outcome inventory valued in collateral, and MUST NOT revert. NAV MUST NOT equal only `asset.balanceOf(vault)` when escrow or inventory is non-zero. Unsolicited ERC-20 or ERC-6909 transfers MUST NOT mint shares. Complete-set pairs (min of Up and Down holdings for a market) MUST count at 1:1 collateral. Unpaired residual for a market MUST count at most `max(up, down)` so NAV never exceeds a 1-collateral-per-contract ceiling.

#### Scenario: Escrow is included in NAV
- **WHEN** idle collateral is `I`, tracked escrow is `E`, and inventory value is `N`
- **THEN** `totalAssets()` returns `I + E + N` and does not revert

#### Scenario: Donation does not mint shares
- **WHEN** an attacker transfers collateral or outcome tokens to the vault without calling `deposit`/`mint`
- **THEN** total supply is unchanged and the attacker holds no new shares

#### Scenario: First depositor cannot inflate shares
- **WHEN** an attacker donates a large asset amount before the first honest `deposit`
- **THEN** the honest depositor receives a non-dust share amount that is not reduced to zero

### Requirement: Instant withdraw is idle-only
`maxWithdraw(owner)` and `maxRedeem(owner)` MUST equal the instantly liquid idle collateral attributable to `owner`'s shares, and MUST NOT include capital in open orders, escrow, or unsold outcome tokens. They MUST NOT revert. A state-changing `withdraw`/`redeem` that exceeds that max MUST revert with a named error (no silent clamp, no partial fill).

#### Scenario: Escrowed capital is not instantly withdrawable
- **WHEN** the vault has idle `I` and escrowed `E` and owner is the sole shareholder
- **THEN** `maxWithdraw(owner)` is at most `I` and `withdraw(I + 1)` reverts with a named error

### Requirement: ERC-7540 async redeem
The vault MUST implement ERC-7540 `requestRedeem` so a share owner (or that owner's ERC-7540 claim-operator) can queue an exit when idle collateral is insufficient. Deposits MUST remain synchronous ERC-4626; `requestDeposit` MUST NOT be implemented as a required path. After a request, the owner MUST claim via IERC4626 `redeem`/`withdraw` only when sufficient idle collateral exists. ERC-7540 `setOperator` MUST control depositor claim rights only and MUST NOT grant trading rights. The trading operator MUST NOT be able to `requestRedeem` or `withdraw` another depositor's shares unless that depositor set them as an ERC-7540 claim-operator.

#### Scenario: Queue redeem while capital is locked
- **WHEN** a share owner calls `requestRedeem` for shares whose assets exceed idle collateral
- **THEN** a pending redeem request is recorded and shares are locked for that request

#### Scenario: Claim after capital frees
- **WHEN** a pending request exists and idle collateral later covers the claimable amount
- **THEN** the owner (or their ERC-7540 claim-operator) can complete `redeem`/`withdraw` for that amount

#### Scenario: Trading operator cannot claim depositor shares
- **WHEN** the trading operator, who is not the share owner and not an ERC-7540 claim-operator, calls `requestRedeem` or `redeem` for that owner
- **THEN** the call reverts with a named error

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

### Requirement: Principal cap versus creator seed
The vault MUST track *principal* per share owner: assets credited on `deposit`/`mint`, reduced pro-rata by shares on `withdraw`/`redeem` and on share transfer. Principal MUST NOT include trading profit or loss (`totalAssets` / NAV). `creatorPrincipal` MUST equal principal of the vault owner. Live cap MUST be `creatorPrincipal * factory.depositCapBps() / 10000`. For a receiver other than the vault owner, `maxDeposit` and `maxMint` MUST return remaining room under that cap (`0` if already at or over) and MUST NOT revert. For a receiver equal to the vault owner, those views MUST NOT be limited by the third-party cap. `deposit`/`mint` that would make `totalPrincipal` exceed the cap MUST revert with a named error (no silent clamp), except when shares are minted to the vault owner. A deposit that mints shares to the vault owner MUST increase `creatorPrincipal` first so the creator can add seed and raise the cap. Trading PnL MUST NOT change `totalPrincipal` or the remaining deposit room.

#### Scenario: Third-party deposits stop at 5x seed
- **WHEN** the creator seeded 10 and `depositCapBps` is 50000 and total principal is 50
- **THEN** `maxDeposit` for a third party is 0 and a further third-party `deposit` reverts with a named error

#### Scenario: Profits do not consume the cap
- **WHEN** total principal is 50, the cap is 50, and `totalAssets` has grown to 80 from trades
- **THEN** `maxDeposit` for a third party is still 0

#### Scenario: Creator can raise the cap by depositing more seed
- **WHEN** the creator deposits an additional 10 as shares to the vault owner while at the old cap
- **THEN** `creatorPrincipal` becomes 20, the cap becomes 100, and third-party deposits are accepted again up to the new room

#### Scenario: Withdrawal frees principal room not profit
- **WHEN** a third party redeems shares after NAV has risen
- **THEN** `totalPrincipal` decreases by that owner's principal share, not by the full asset payout, and `maxDeposit` increases by that principal amount

### Requirement: Creator cannot pull seed out from under LPs
A withdraw, redeem, or share transfer that would leave `totalPrincipal > creatorPrincipal * depositCapBps / 10000` MUST revert with a named error. The creator MAY exit as LPs redeem and `totalPrincipal` falls. Vault owner and operator MUST NOT have a setter for `depositCapBps`.

#### Scenario: Creator cannot exit while at the cap
- **WHEN** creator principal is 10, total principal is 50, and the cap is 500%
- **THEN** any creator `withdraw` or share transfer that reduces creator principal reverts with a named error

#### Scenario: Creator can trim seed after LPs redeem
- **WHEN** creator principal is 10, total principal is 40, and the cap is 500%
- **THEN** the creator can reduce creator principal down to 8 and a further reduction reverts

#### Scenario: Creator can exit after LPs leave
- **WHEN** third-party principal is 0 and the creator holds idle seed
- **THEN** the creator can `withdraw` their remaining principal subject to idle-only `maxWithdraw`

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
