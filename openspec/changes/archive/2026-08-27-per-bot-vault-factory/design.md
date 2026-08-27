## Context

See `proposal.md` for motivation. The repo is a Foundry stub (`src/Counter.sol`); OpenZeppelin is not yet a dependency. Depositors, operator, and vault roles are defined in `specs/bot-vault` and `specs/dreamdex-event-trading`.

Event-contract trading is on-chain via [BinaryMarketsModule / pool / OutcomeToken6909](https://docs.dreamdex.io/developers/event-contracts/market-structure.md). The HTTP API is spot-only. Spot `placeOrderFor` + `OperatorPermissionsRegistry` is documented for SpotPool session keys, not as the event-contract bot path ([dreamdex-bot-kit session keys](https://github.com/somnia-chain/dreamdex-bot-kit/blob/main/docs/session-keys.md) are spot). Event-contract refunds and escrow settle to the trading identity's wallet ([gotchas](https://docs.dreamdex.io/developers/event-contracts/gotchas.md)).

Collateral scale MUST be read from `asset.decimals()`: USDso 18 on mainnet, tUSDC 6 on testnet ([addresses](https://docs.dreamdex.io/developers/event-contracts/contracts-and-addresses.md)). Core CREATE3 addresses are identical on 5031 and 50312; market and pool addresses are not.

## Goals / Non-Goals

**Goals:**
- Factory clones of one implementation; 1:1 operator → vault; required creator seed.
- Global deposit cap as a multiple of creator principal (default 5x), admin-only.
- Vault is `msg.sender` on venue writes; operator key only calls the vault.
- ERC-4626 + ERC-7540 async redeem; idle-only instant exit.
- Mocked Foundry venue so tests do not need live Somnia.
- Thin viem adapter for `ec-*` bots; reads against the vault address.

**Non-Goals:**
- Strategy logic, fees, async deposit, forking dreamdex-bot-kit, depending on spot `placeOrderFor`, per-vault cap overrides.

## Decisions

### 1. Trading identity = vault `msg.sender` (not spot `placeOrderFor`)

The operator calls `BotVault.placeOrder` (etc.). The vault pulls/approves its own collateral and calls the pool / `BinaryMarketsModule`. Fills, refunds, and redemptions credit the vault.

**Why:** Event-contract docs treat the signer/wallet as the trader. Spot operators pull from an *owner wallet*; here the owner is a contract that must itself talk to the venue. This keeps the operator unable to auto-pull from any EOA.

**Alternative:** Vault approves spot-style `placeOrderFor(vault)` if event pools expose it. Rejected as the primary path: it is not the documented event-contract surface and would still require the vault to pre-approve the pool.

### 2. Factory: EIP-1167 clones, venue core immutable on the factory

`VaultFactory` is `Ownable` (factory admin) and constructed with `binaryMarketsModule`, `binarySettlement`, `outcomeToken` (CREATE3 core) plus `depositCapBps = 50000`. `createVault(operator, asset, name, symbol, seedAssets)` clones `BotVault`, `initialize`s owner=`msg.sender`, operator, asset, factory, and those core addresses, then deposits `seedAssets` from the creator into the vault (shares to creator). `seedAssets == 0` reverts. Implementation is initialized once to a dead owner so it cannot be taken over. Mapping `operator => vault` is 1:1; reverse map + array for enumeration.

**Why:** Cheap per-bot deploys; vaults cannot point at a fake module. Asset is per-vault so one factory bytecode serves testnet tUSDC and mainnet USDso. Seed in the same tx so a listed vault is never empty of creator skin.

**Alternative:** `new BotVault()` per bot (simpler, costlier). Beacon upgrades (out of scope). Optional seed after create (rejected: a listed vault could take LP deposits before the creator deposits).

### 3. Share math: OZ ERC4626 + decimal offset; ERC-7540 redeem in scope

Inherit OpenZeppelin `ERC4626` with `_decimalsOffset() = 3` (or equivalent virtual shares) so a first-depositor donation cannot round an honest deposit to zero shares. Rounding already favors the vault. `share() == address(this)`.

`totalAssets()` MUST NOT revert:

```
idle    = asset.balanceOf(vault)          // wallet collateral
escrow  = Σ tracked open-order collateral  // updated on writes + sync
inv     = Σ_markets max(up, down)          // 6909 balances; 1:1 ceiling
NAV     = idle + escrow + inv
```

Complete sets are not double-counted: `max(up, down)` equals `min(up,down)` pairs at 1 plus unpaired at 1 (ceiling). Try/catch external module/pool/6909 reads; a failed read contributes 0 for that component.

`maxWithdraw(owner) = min(convertToAssets(unlockedShares(owner)), idle - reservedForClaims)`. Escrow and inventory are not instantly withdrawable.

**ERC-7540:** `requestRedeem` locks shares and enqueues FIFO. `reservedForClaims` grows as idle appears (`allocateIdle` permissionless) so instant withdraws cannot starve the queue. Claim via 4626 `redeem`/`withdraw`. No `requestDeposit`. ERC-7540 `setOperator` ≠ trading operator.

**Alternative:** Cost-basis NAV (misses unrealized PnL). Book mid (manipulable). Offset 0 (fails inflation test).

### 4. Venue calls: resolve from `marketId`, exact-amount approvals

Operator calldata supplies `marketId` plus order fields (`side`, `price`, `quantity`, `expireTimestampNs`, `orderType`). Vault reads `module.markets(marketId)`; uses that pool and outcome ids. Unknown `marketId` → `InvalidMarket`. Place/mint/merge require on-chain status `Trading` (1); redeem requires `Resolved` or `Voided`; cancel/reduce allowed in `Locked`. `expireTimestampNs == 0` → `InvalidExpiry`.

Approvals: exact required amount to the resolved pool or module, never `type(uint256).max` to an address not in {module, that pool, settlement, outcomeToken}. ERC-6909 `setOperator`/approvals only to those addresses.

Tracked `marketId` set (cap 32). Exceeding cap reverts. Permissionless `syncMarket(marketId)` refreshes escrow from pool + 6909 balances so NAV stays honest after fills that did not go through the vault in that tx.

**Decimals:** tick/lot are venue-side; vault passes through `uint256` raw units. Adapter snaps using `token.decimals()` and SDK ≥ 0.28.0.

### 5. Principal cap is seed × bps, not NAV

Track `principal[owner]` (assets in on deposit/mint; reduced `principal * sharesOut / sharesHeld` on redeem and on ERC-20 share transfer). `totalPrincipal = Σ principal`. `creatorPrincipal = principal[vaultOwner]`. Live cap = `creatorPrincipal * IVaultFactory(factory).depositCapBps() / 10000` (read live so admin changes apply immediately).

```
maxDeposit(receiver) = receiver == vaultOwner ? type(uint256).max
                       : saturating_sub(cap, totalPrincipal)
```

Creator `deposit`/`mint` with `receiver == vaultOwner` increases `creatorPrincipal` before the cap check so they can add skin. Third-party deposits revert with `DepositCapExceeded` if `totalPrincipal + assets > cap`. Views return 0 room instead of reverting.

PnL never touches principal: a vault at 50 principal / 80 NAV still has third-party `maxDeposit == 0`. Redeem of profitable shares reduces principal by the share fraction, not by assets paid out.

Skin lock: after a creator withdraw, redeem, or share transfer, require `totalPrincipal <= newCreatorPrincipal * bps / 10000` or revert `CreatorSeedRequired`. At 10 seed + 40 LP (50 total, 5x), the creator cannot pull any seed until LPs redeem.

Admin: `setDepositCapBps` only `factory.owner()`, bps in `[10000, 1000000]`. Lowering the cap does not force exits; `maxDeposit` becomes 0 if over cap. Vault owner/operator have no cap setter.

**Why:** Seed 10 → max 50 of *deposits*, excluding profits. Capping NAV would freeze deposits after a winning streak.

**Alternative:** Cap `totalAssets` (rejected). Lifetime-gross deposits (rejected: withdrawals would not free room). Per-vault bps (rejected: admin-only global).

### 6. Adapter: viem writes to vault; SDK reads as vault

`integrations/vault-adapter`: operator `walletClient` + `VAULT_ADDRESS`. Reads: `@somnia-chain/markets-sdk` / `getOutcomeBalance(outcomeToken, vault, id)` and `asset.balanceOf(vault)`. Writes: vault ABI only. No `withdraw`/`redeem`/`requestRedeem` on the adapter. Do not pass the operator key as a funded SDK `privateKey`.

### 7. State-changing functions (caller → MUST revert)

| Function | Caller | MUST revert |
| --- | --- | --- |
| `createVault` | anyone | `ZeroAddress`; `OperatorExists`; `InvalidAmount` (zero seed); insufficient seed allowance |
| `setDepositCapBps` | factory admin | `Unauthorized`; `InvalidAmount` (bps outside `[10000, 1000000]`) |
| `deposit` / `mint` | depositor (allowance) | `InvalidAmount`; `DepositCapExceeded`; insufficient allowance/balance |
| `withdraw` / `redeem` / share `transfer` | owner or ERC-7540 claim-operator / token holder | `InvalidAmount`; exceeds `maxWithdraw`/`maxRedeem`; insufficient idle after reserves; `CreatorSeedRequired` |
| `requestRedeem` | share owner or ERC-7540 claim-operator | `Unauthorized`; `InvalidAmount`; zero shares |
| `setOperator` (7540) | share owner | `Unauthorized` |
| `setTradingOperator` | vault owner | `Unauthorized`; `ZeroAddress` |
| `placeOrder` | trading operator | `Unauthorized`; `InvalidMarket`; `MarketNotTrading`; `InvalidAmount`; `InsufficientIdle`; `InvalidExpiry`; `TrackedMarketsCapped` |
| `cancelOrder` / `reduceOrder` | trading operator | `Unauthorized`; `InvalidMarket`; `InvalidAmount` |
| `mintCompleteSet` / `mergeCompleteSet` | trading operator | `Unauthorized`; `InvalidMarket`; `MarketNotTrading`; `InsufficientIdle` / insufficient 6909 |
| `redeem` (venue) | trading operator | `Unauthorized`; `InvalidMarket`; `MarketNotFinalized`; zero claimable handled by skipping zero amount (`InvalidAmount` if amount is 0) |
| `syncMarket` / `allocateIdle` | anyone | `InvalidMarket` if unknown to module |

No rescue/sweep. `nonReentrant` on all value-moving functions. CEI: update escrow/reserves before external venue calls where state is used after; measure token deltas after the call and persist.

Layout: `src/VaultFactory.sol`, `src/BotVault.sol`, `src/interfaces/`, `src/libraries/Errors.sol`; tests under `test/`; deploy script; adapter under `integrations/vault-adapter/`. Remove `Counter`. SPDX MIT, `^0.8.24`. Named errors only.

## Risks / Trade-offs

- **[Unpaired inventory marked at 1.0]** → New depositors overpay while a position is underwater. Mitigation: document; ceiling never exceeds 1 per contract; later change can add a deposit pause.
- **[NAV lag between fills]** → Stale escrow double-counts. Mitigation: `syncMarket`; `totalAssets` try/catch live reads.
- **[totalAssets gas / cap]** → Unbounded markets would break views. Mitigation: cap 32; operator must redeem and prune.
- **[Operator malice]** → Can lose capital via bad trades; cannot withdraw. Mitigation: role isolation tests; no custom recipient.
- **[Pool recycle]** → Stale pool allowance. Mitigation: approve exact amount to module-resolved pool each write.
- **[SDK indexer lag]** → Adapter might send a locked-market tx. Mitigation: vault re-reads on-chain status and reverts.
- **[Creator share transfer]** → Dumping seed shares would drop the cap while LPs remain. Mitigation: transfers that break `totalPrincipal <= creatorPrincipal * bps / 10000` revert.
- **[Admin lowers cap]** → Vaults can be over-cap with no forced exit. Mitigation: `maxDeposit` = 0 until principal is redeemed or the creator adds seed.

## Migration Plan

1. `forge install` OpenZeppelin; drop Counter.
2. Deploy factory to Shannon (50312) with CREATE3 core + tUSDC; then mainnet with USDso.
3. Confirm core addresses on-chain before funding.
4. Rollback: factory has no upgrade; stop creating vaults. Existing vaults are immutable; depositors exit via 4626/7540.

## Open Questions

- Exact pool escrow view name (confirm against `binaryModuleReadAbi` / pool ABI at implement time; adapter and `syncMarket` bind to whatever the module returns).
- Whether event-contract pools also accept `placeOrderFor`; out of band — primary path remains vault `msg.sender`.
