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
Every state-changing function MUST name its caller role: depositor (or ERC-7540 claim-operator), trading operator, or vault owner. Unauthorized callers MUST revert with a named error. The trading operator MUST NOT withdraw, rescue, or transfer collateral or outcome tokens to itself or an arbitrary address. The vault owner MAY rotate the trading operator to a non-zero address and MUST NOT have a path that skims depositor assets. Value-moving functions MUST be non-reentrant and follow checks-effects-interactions.

#### Scenario: Stranger cannot trade or withdraw
- **WHEN** an address that is not owner, trading operator, or share owner calls a state-changing vault function
- **THEN** the call reverts with a named error

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
