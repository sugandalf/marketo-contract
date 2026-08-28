# Merkato Bot Vault

Per-bot ERC-4626 vaults that trade DreamDEX event contracts. The vault is the funded trader. Depositors hold shares. The operator never holds capital.

```
  Factory admin          Creator / vault owner         Depositor / LP
        |                        |                           |
        v                        v                           v
 +--------------+         createVault()              deposit / mint
 | VaultFactory | -------------------------------->  withdraw / redeem
 |  (registry,  |         seed + clone               requestRedeem
 |   caps, fees)|                |                           |
 +--------------+                v                           |
        |                 +------------+                     |
        |                 |  BotVault  | <-------------------+
        |                 |  ERC-4626  |
        |                 |  ERC-7540  |
        |                 +------------+
        |                        ^
        |         place / cancel / reduce / mint / merge / redeem
        |                        |
        |                 Trading operator
        |                        |
        v                        v
 +--------------+    +---------------------+    +------------------+
 |  Binary      |    |  EventPool (CLOB)   |    | BinarySettlement |
 |  Markets     |--->|  escrow, orders     |    |  redeem outcomes |
 |  Module      |    +---------------------+    +------------------+
 +--------------+               |                         |
        |                       v                         v
        |              collateral USDso / tUSDC     OutcomeToken6909
        +-------------------- yesId / noId ----------------+
```

---

## Roles

```
 Factory admin          Vault owner           Trading operator
 ---------------        -------------         -----------------
 setDepositCapBps       createVault           placeOrder
 setTreasury            setTradingOperator    cancelOrder
 setProtocolFeeBps      deposit (seed)        reduceOrder
 setMaxPerformanceFee   withdraw own shares   mintCompleteSet
                        (if seed still holds) mergeCompleteSet
                                              redeem (venue)
                                              forgetMarket

 Depositor / LP         Claim operator        Anyone
 ---------------        --------------        ------
 deposit / mint         requestRedeem         harvestFees
 withdraw / redeem      withdraw / redeem     allocateIdle
 requestRedeem          (for that owner)      syncMarket
 setOperator            NOT trading
 share transfer
```

Capital never leaves the vault except to allowlisted venue contracts (escrow / mint / merge / redeem) or to a depositor via ERC-4626 `withdraw` / `redeem`.

---

## 1. Factory deploy

```
 Deployer
    |
    |  new VaultFactory(module, settlement, outcomeToken, treasury)
    v
 +------------------+
 |  VaultFactory    |
 |                  |
 |  IMPLEMENTATION  |---- new BotVault()  (initializers disabled)
 |  MODULE          |---- BinaryMarketsModule
 |  SETTLEMENT      |---- BinarySettlement
 |  OUTCOME_TOKEN   |---- OutcomeToken6909
 |  treasury        |
 |                  |
 |  depositCapBps        = 50000  (5x creator seed)
 |  protocolFeeBps       = 2000   (20% of performance fee)
 |  maxPerformanceFeeBps = 2000   (20% ceiling)
 +------------------+
```

---

## 2. Create vault (seeded clone)

One vault per trading operator. Caller becomes vault owner and must fund `seedAssets`.

```
 Creator                         VaultFactory                      Clone
    |                                 |                              |
    |  approve(factory, seed)         |                              |
    |  createVault(                   |                              |
    |    operator, asset,             |                              |
    |    name, symbol, seed,          |                              |
    |    performanceFeeBps,           |                              |
    |    creatorFeeRecipient)         |                              |
    |-------------------------------->|                              |
    |                                 |  revert if:                  |
    |                                 |   operator/asset = 0         |
    |                                 |   seed = 0                   |
    |                                 |   operator already mapped    |
    |                                 |   fee > maxPerformanceFeeBps |
    |                                 |   fee > 0 and recipient = 0  |
    |                                 |   fee > 0, protocol > 0,     |
    |                                 |     treasury = 0             |
    |                                 |                              |
    |                                 |  Clones.clone(impl) -------->|
    |                                 |  initialize(                 |
    |                                 |    owner=creator,            |
    |                                 |    operator, asset,          |
    |                                 |    factory, venue addrs,     |
    |                                 |    fee bps + recipient)      |
    |                                 |----------------------------->|
    |                                 |                              |
    |  seed ERC-20 ------------------>|  transferFrom creator        |
    |                                 |  approve(vault, seed)        |
    |                                 |  vault.deposit(seed, creator)|
    |                                 |----------------------------->|
    |                                 |                    mint shares
    |                                 |                    to creator
    |                                 |                    principalOf[creator]
    |                                 |                      = seed
    |                                 |                    highWaterMark
    |                                 |                      = fee-safe PPS
    |                                 |                              |
    |                                 |  vaults[operator] = vault    |
    |                                 |  operatorOf[vault] = operator|
    |                                 |  emit VaultCreated           |
    |<--------------------------------|                              |
    |           vault address         |                              |
```

Live deposit cap after seed:

```
  cap = creatorPrincipal * factory.depositCapBps() / 10000

  example: seed 10, cap 50000 bps  ->  third-party principal <= 50
```

`performanceFeeBps` and `creatorFeeRecipient` are immutable after create.

---

## 3. Factory admin

Only `VaultFactory.owner()`. Vault owners and operators cannot change these.

```
 Admin
   |
   |-- setDepositCapBps(bps)          [10000 .. 1000000]
   |     live vaults read this on the next deposit
   |     lowering the cap does not force withdrawals
   |
   |-- setTreasury(addr)              zero banned while protocolFeeBps > 0
   |-- setProtocolFeeBps(bps)         [0 .. 10000]
   |-- setMaxPerformanceFeeBps(bps)   [0 .. 2000]
         does not rewrite live vaults; only new creates
```

---

## 4. Deposit / mint (ERC-4626)

Synchronous. Fees crystallize first. Principal (not NAV) consumes the cap. Creator deposits raise the cap.

```
 Depositor                    BotVault                     Asset
     |                           |                           |
     |  deposit(assets, recv)    |                           |
     |  or mint(shares, recv)    |                           |
     |-------------------------->|                           |
     |                           |  assets/shares == 0?      |
     |                           |    revert InvalidAmount   |
     |                           |                           |
     |                           |  _accrueFees()            |  (see §10)
     |                           |                           |
     |                           |  assets > maxDeposit(recv)?
     |                           |    revert DepositCapExceeded
     |                           |                           |
     |                           |  maxDeposit(owner) = max  |
     |                           |  maxDeposit(other) =      |
     |                           |    cap - totalPrincipal   |
     |                           |                           |
     |  transfer assets -------->|  measure into vault       |
     |                           |  mint shares to receiver  |
     |                           |  principalOf[recv] +=     |
     |                           |    assets                 |
     |                           |  totalPrincipal += assets |
     |                           |  emit Deposit             |
     |<--------------------------|                           |
```

```
  totalPrincipal  !=  NAV (idle + escrow + inventory)
  trading PnL does not consume or free the principal cap
```

---

## 5. Instant withdraw / redeem (idle only)

`maxWithdraw` / `maxRedeem` are idle collateral attributable to unlocked shares. Capital in orders or unsold outcomes is not instantly withdrawable. No partial fills.

```
 Owner / claim-operator          BotVault                    Asset
     |                              |                          |
     |  withdraw(assets, to, owner) |                          |
     |  or redeem(shares, to, owner)|                          |
     |----------------------------->|                          |
     |                              |  zero amount?            |
     |                              |    revert InvalidAmount  |
     |                              |  _accrueFees()           |
     |                              |                          |
     |              +---------------+---------------+          |
     |              |                               |          |
     |     claimableAssets[owner] > 0        no pending claim  |
     |     and caller authorized                               |
     |              |                               |          |
     |              v                               v          |
     |      _claimAssets()                  assets > maxWithdraw?
     |      (see §6)                          revert InvalidAmount
     |                                              |          |
     |                                              | burn shares
     |                                              | reduce principal
     |                                              | _assertCreatorSeed
     |                                              |   totalPrincipal
     |                                              |   <= live cap
     |                                              |     else revert
     |                                              |     CreatorSeedRequired
     |  collateral ---------------------------------|--------->|
     |                              |  emit Withdraw           |
```

```
  maxWithdraw(owner) = min(
      convertToAssets(unlockedShares),
      idle - reservedForClaims
  )

  unlockedShares = balance - lockedShares   (locked by requestRedeem)
```

Creator cannot pull seed out from under LPs: any withdraw / redeem / transfer that would leave `totalPrincipal > creatorPrincipal * capBps / 10000` reverts.

---

## 6. Async redeem (ERC-7540)

Use when idle collateral is not enough. Deposits stay synchronous. `setOperator` is a depositor claim-operator, not the bot trader.

```
 Owner / claim-operator              BotVault
     |                                  |
     |  requestRedeem(shares,           |
     |    controller, owner)            |
     |--------------------------------->|
     |                                  |  not owner and not
     |                                  |    isOperator(owner, caller)?
     |                                  |      revert Unauthorized
     |                                  |  _accrueFees()
     |                                  |  shares > unlocked?
     |                                  |      revert InvalidAmount
     |                                  |  would break creator seed?
     |                                  |      revert CreatorSeedRequired
     |                                  |
     |                                  |  lockedShares[owner] += shares
     |                                  |  queue.push({controller, shares})
     |                                  |  emit RedeemRequestQueued
     |                                  |  _allocateIdle()
     |<---------------------------------|
     |           requestId              |


 Idle frees (cancel, merge, venue redeem, anyone calls allocateIdle)
     |
     v
 +------------------------------------------------------------------+
 |  _allocateIdle                                                   |
 |                                                                  |
 |  available = idle - reservedForClaims                            |
 |  FIFO from _redeemHead:                                          |
 |    want  = convertToAssets(req.shares)                           |
 |    give  = min(want, available)                                  |
 |    claimableShares[controller] += giveShares                     |
 |    claimableAssets[controller] += give                           |
 |    reservedForClaims           += give                           |
 +------------------------------------------------------------------+
     |
     v
 Owner / claim-operator
     |
     |  withdraw / redeem  (same ERC-4626 entry, claim path)
     |---------------------------------> BotVault._claimAssets
     |                                  burn locked shares
     |                                  pay reserved collateral
     |                                  _assertCreatorSeed
     |  assets ------------------------+--> receiver
```

Trading operator cannot `requestRedeem` or `withdraw` another depositor's shares unless that depositor called `setOperator(operator, true)`.

```
 Depositor ---- setOperator(addr, approved) ----> claim rights only
                                                    |
                                                    x  no trading rights
                                                    x  no idle drain
```

---

## 7. Share transfer

Principal and fee-originated shares move separately. Fee shares do not change `totalPrincipal` or the seed lock.

```
 Sender ---- transfer / transferFrom ----> Receiver
                 |
                 v
        feeMove  = min(amount, feeShares[from])
        prinMove = amount - feeMove

        feeShares[from] -= feeMove
        feeShares[to]   += feeMove     (burn: discarded)

        principal moved  = principalOf[from] * prinMove / prinShares
        principalOf[from] -= moved
        principalOf[to]   += moved     (burn: totalPrincipal -= moved)

        if from != to != 0:
          _assertCreatorSeed()         (creator cannot transfer seed
                                        out from under LPs)
```

---

## 8. Trading (operator only)

Vault is `msg.sender` on every venue write. Operator supplies `marketId` only. Pool, yes/no ids, and status come from `BinaryMarketsModule`. Approvals are exact-amount to allowlisted spenders, then cleared.

```
 Operator                    BotVault                      Venue
    |                           |                            |
    |  onlyTradingOperator      |                            |
    |  nonReentrant             |                            |
    |                           |                            |
    |  marketId ---------------->|  module.markets(marketId) |
    |                           |  pool == 0?                |
    |                           |    revert InvalidMarket    |
    |                           |  _trackMarket (max 32)     |
```

### 8.1 Place order (Trading only)

```
 Operator ---- placeOrder(marketId, side, price, qty, expiryNs, type)
                    |
                    |  qty/price == 0  -> InvalidAmount
                    |  expiryNs == 0   -> InvalidExpiry
                    |  status != 1     -> MarketNotTrading
                    |
         BUY_YES / BUY_NO                    SELL_YES / SELL_NO
                    |                                   |
                    v                                   v
         needed = price * qty / 1eD              need outcome inventory
         idle < needed -> InsufficientIdle       (pool pulls on fill)
         approve(pool, needed)
                    |                                   |
                    +----------------+------------------+
                                     v
                         EventPool.placeOrder(...)
                         msg.sender = vault
                         order owner = vault
                                     |
                         BUY: clear approval
                         success == false -> InvalidAmount
                         orderMarket[id] = marketId
                         idle drop  -> escrowByMarket += delta
                         idle rise  -> escrowByMarket -= refund
```

### 8.2 Cancel / reduce

Allowed while the market is Locked. Refunds return to the vault, never the operator.

```
 Operator ---- cancelOrder(marketId, orderId)
           or  reduceOrder(marketId, orderId, qty)
                    |
                    v
              EventPool.cancelOrder / reduceOrder
                    |
              idle refund -> escrowByMarket -= refund
              cancel: delete orderMarket[id]
```

### 8.3 Mint complete set (Trading only)

```
 Operator ---- mintCompleteSet(marketId, amount)
                    |
                    |  status != Trading -> MarketNotTrading
                    |  idle < amount     -> InsufficientIdle
                    v
              approve(module, amount)
              BinaryMarketsModule.mintCompleteSet
                    |
              collateral -----> module
              YES + NO  -------> vault (ERC-6909)
              clear approval
```

### 8.4 Merge complete set (Trading only)

```
 Operator ---- mergeCompleteSet(marketId, amount)
                    |
                    |  status != Trading -> MarketNotTrading
                    |  yes < amount or no < amount -> InvalidAmount
                    v
              approve YES + NO to module
              BinaryMarketsModule.mergeCompleteSet
                    |
              YES + NO  -------> module (burned)
              collateral ------> vault
              clear approvals
```

### 8.5 Venue redeem (Resolved or Voided)

```
 Operator ---- redeem(marketId, outcomeIdx, amount)
                    |
                    |  status not Resolved(4) or Voided(5)
                    |    -> MarketNotFinalized
                    |  outcome balance < amount -> InvalidAmount
                    v
              approve outcome to BinarySettlement
              BinarySettlement.redeem
                    |
              winning / voided tokens -----> settlement
              collateral ------------------> vault
              clear approval
              _accrueFees()                 (realized idle can mint fees)
```

Voided markets redeem both sides at 0.5 collateral per contract.

### 8.6 Market tracking

NAV walks up to 32 tracked markets. Escrow is also refreshed from the pool when possible.

```
 anyone     ---- syncMarket(marketId)   track + refresh escrowOf(vault)
 operator   ---- forgetMarket(marketId) only if escrow, yes, no are all 0
```

---

## 9. NAV vs fee-safe NAV

Views never revert. `totalAssets()` is not `asset.balanceOf(vault)`. Donations do not mint shares (decimal offset = 3).

```
                    idle collateral
                          +
                    tracked escrow
                          +
                    inventory (per market)

  totalAssets()     inventory = max(yes, no)     depositor NAV ceiling
  feeSafeNav()      inventory = min(yes, no)     complete sets only

  unpaired Yes or No can raise totalAssets
  unpaired inventory never creates performance fees
```

```
  maxWithdraw / maxRedeem  use idle - reservedForClaims only
  escrow + inventory are not instantly liquid
```

---

## 10. Performance fees

High-water mark on fee-safe share price. Fees mint shares (dilution), they do not pull idle collateral. Management / entry / exit fees are zero.

Crystallizes on `deposit`, `mint`, `withdraw`, `redeem`, `requestRedeem`, after venue `redeem`, and on permissionless `harvestFees()`.

```
 _accrueFees
      |
      |  performanceFeeBps == 0 or supply == 0  -> return
      |  creatorFeeRecipient == 0               -> revert ZeroAddress
      |  protocolFeeBps > 0 and treasury == 0   -> revert ZeroAddress
      |
      |  pps = feeSafeNav * 1e18 / (supply + virtualShares)
      |
      |  pps <= highWaterMark  -> return (drawdown / recovery: no fee)
      |
      |  profit    = (pps - hwm) * virtualSupply / 1e18
      |  feeAssets = profit * performanceFeeBps / 10000     (round down)
      |
      |  mint shares against remaining fee-safe NAV
      |       protocolMint = minted * protocolFeeBps / 10000
      |       creatorMint  = minted - protocolMint
      |
      |       _mint(treasury, protocolMint)         feeShares +=
      |       _mint(creatorFeeRecipient, creatorMint)
      |
      |  highWaterMark = max(hwm, post-mint fee-safe PPS)   never decreases
      |  emit FeesHarvested
```

```
 example: fee-safe NAV 100 -> 120, supply unchanged, 1000 bps, 2000 protocol
          fee assets = 2
          20% of fee shares -> factory.treasury
          80% of fee shares -> creatorFeeRecipient
          idle unchanged, totalPrincipal unchanged
```

Fee recipients exit only through ERC-4626 / ERC-7540. Redeeming fee shares does not reduce `creatorPrincipal` or loosen the seed lock.

---

## 11. Operator rotation

```
 Vault owner ---- setTradingOperator(newAddr != 0)
                        |
                        |  old operator trade calls -> Unauthorized
                        |  new operator trade calls -> ok
                        |
                        x  cannot set fee recipient / fee bps
                        x  cannot withdraw depositor capital
                        x  cannot skim to self
```

---

## 12. Fail-closed writes

```
  views (asset, totalAssets, convert*, preview*, max*, feeSafeNav)
      MUST NOT revert   ->  return 0 / limited max

  state-changing deposit / mint / withdraw / redeem / trade
      MUST revert if the full amount cannot complete
      no silent clamp, no partial fill

  unauthorized caller           -> Unauthorized
  zero / over-size amount       -> InvalidAmount
  third-party over cap          -> DepositCapExceeded
  creator seed would break      -> CreatorSeedRequired
  buy/mint > idle               -> InsufficientIdle
  unknown marketId              -> InvalidMarket
  place/mint/merge not Trading  -> MarketNotTrading
  venue redeem not final        -> MarketNotFinalized
  expiryNs == 0                 -> InvalidExpiry
  tracked markets == 32         -> TrackedMarketsCapped
```

---

## Contracts

| Contract | Path | Role |
|---|---|---|
| `VaultFactory` | `src/VaultFactory.sol` | Clone factory, registry, global caps and protocol fee |
| `BotVault` | `src/BotVault.sol` | ERC-4626 + ERC-7540 + operator trading identity |
| `Errors` | `src/libraries/Errors.sol` | Named reverts |
| `IVaultFactory` | `src/interfaces/IVaultFactory.sol` | Live cap / treasury / fee reads |
| `IBinaryMarketsModule` | `src/interfaces/IBinaryMarketsModule.sol` | Market record, mint / merge |
| `IEventPool` | `src/interfaces/IEventPool.sol` | Place / cancel / reduce / escrow |
| `IBinarySettlement` | `src/interfaces/IBinarySettlement.sol` | Redeem resolved / voided outcomes |
| `IOutcomeToken6909` | `src/interfaces/IOutcomeToken6909.sol` | Yes / No ERC-6909 inventory |
