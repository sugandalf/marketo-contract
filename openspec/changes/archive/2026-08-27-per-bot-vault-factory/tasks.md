## 1. Foundry setup

- [x] 1.1 Install OpenZeppelin Contracts via forge, set Solidity ^0.8.24 and MIT SPDX in foundry.toml, remove `src/Counter.sol`, `test/Counter.t.sol`, and `script/Counter.s.sol`
- [x] 1.2 Add named errors in `src/libraries/Errors.sol` and venue interfaces (`IBinaryMarketsModule`, `IEventPool`, `IBinarySettlement`, `IOutcomeToken6909`) keyed by `marketId` with no hardcoded pool addresses

## 2. Factory

- [x] 2.1 Implement `VaultFactory`: Ownable admin, `depositCapBps` default 50000, constructor venue core, EIP-1167 clone + `initialize`, required `seedAssets`, 1:1 operator mapping, enumerable `vaultAt` / `vaultCount`, `VaultCreated`
- [x] 2.2 Tests: create with seed success; `vm.expectRevert` on zero operator, zero asset, zero seed, duplicate operator, out-of-range index; two operators get isolated vaults
- [x] 2.3 Implement `setDepositCapBps` (admin only, `[10000, 1000000]`); tests: admin update applies to vault `maxDeposit`; non-admin, vault owner, and operator revert; out-of-range bps reverts

## 3. ERC-4626 vault core

- [x] 3.1 Implement `BotVault` initialize (owner, operator, asset, factory, venue core), OZ ERC4626 with decimal offset 3, `share() == address(this)`, ERC-165, `nonReentrant` on value moves
- [x] 3.2 Tests: `deposit`/`mint` mint shares and emit `Deposit`; `preview*` matches actual; `vm.expectRevert` on zero deposit; views never revert
- [x] 3.3 Tests: donation does not mint shares; first-depositor inflation attack still yields non-dust shares for the honest depositor
- [x] 3.4 Implement per-owner principal accounting, live factory cap, creator seed lock on withdraw/transfer; `maxDeposit` is remaining principal room
- [x] 3.5 Tests: seed 10 → third-party deposits stop at 50; NAV growth to 80 does not free room; creator extra seed raises cap; redeem frees principal not profit; creator cannot pull seed at the cap (`vm.expectRevert`); `deposit` over cap reverts (no clamp)

## 4. Liquidity, NAV, ERC-7540

- [x] 4.1 Implement `totalAssets` (idle + escrow + `max(up,down)` inventory, try/catch, cap 32 markets), idle-only `maxWithdraw`/`maxRedeem` minus `reservedForClaims`
- [x] 4.2 Tests: NAV includes escrow not just `balanceOf`; `maxWithdraw` ignores escrowed capital; `withdraw` over max reverts with named error
- [x] 4.3 Implement ERC-7540 `requestRedeem`, FIFO `allocateIdle`, claim via 4626 `redeem`/`withdraw`; ERC-7540 `setOperator` distinct from trading operator
- [x] 4.4 Tests: queue while locked; claim after idle frees; trading operator cannot `requestRedeem`/`redeem` another owner's shares (`vm.expectRevert`)

## 5. Operator venue writes

- [x] 5.1 Add mock module/pool/6909/settlement in `test/` that escrows collateral, mints/merges sets, refunds the vault, and exposes status
- [x] 5.2 Implement operator `placeOrder` / `cancelOrder` / `reduceOrder` / `mintCompleteSet` / `mergeCompleteSet` / `redeem`: resolve pool from module, exact-amount allowlisted approvals, status gates, `expireTimestampNs != 0`
- [x] 5.3 Implement `syncMarket` and tracked-market cap; measure token deltas; no custom recipient
- [x] 5.4 Tests: operator happy path place → cancel refunds vault; mint/merge; redeem after Resolved/Voided
- [x] 5.5 Negative tests (`vm.expectRevert`): non-operator trade; underfunded buy; unknown `marketId`; place when not Trading; redeem when not finalized; zero expiry; caller-supplied wrong pool unused; operator cannot send tokens to self

## 6. Roles and reentrancy

- [x] 6.1 Implement `setTradingOperator` (owner only, non-zero); confirm no rescue/sweep
- [x] 6.2 Tests: stranger cannot trade or withdraw; old operator reverts after rotation; ERC-20/6909 reentrancy on deposit, withdraw, and place (`vm.expectRevert`)

## 7. Bot adapter

- [x] 7.1 Add `integrations/vault-adapter` (viem): operator signer, vault as read account, writes only to vault ABI; exclude withdraw/redeem/requestRedeem; snap using `asset.decimals()`
- [x] 7.2 Export vault ABI and a short README: `VAULT_ADDRESS` + operator key, `@somnia-chain/markets-sdk` >= 0.28.0 for reads, do not pass operator key as funded SDK `privateKey`
- [x] 7.3 Foundry test: buy sized from operator EOA balance still reverts when vault idle is insufficient; operator EOA unchanged

## 8. Deploy script and security audit

- [x] 8.1 Add `script/DeployVaultFactory.s.sol` for Shannon (tUSDC) and mainnet (USDso) with CREATE3 core passed in; `forge fmt` and `forge test`
- [x] 8.2 Security audit of the diff: auth, token recipients, reentrancy, allowance scope, share inflation, seed/principal cap bypass (NAV vs principal, creator transfer), missing reverts; add any missing `vm.expectRevert` tests; do not mark the change done while any of those remain
