## 1. Venue interfaces

- [x] 1.1 Replace `MarketRecord` / `IBinaryMarketsModule` with the live 14-field `markets` tuple and writes `mintCompleteSet` / `mergeCompleteSet` / `redeem` taking `(operatorId, venueId, marketId, …)` as in SDK `binaryModuleReadAbi` / `binaryModuleWriteAbi`
- [x] 1.2 Replace `IEventPool` with `placeBinaryOrder`, `cancelOrder`, `reduceOrder(orderId, newQuantityRemaining)`, `marketExpiryNs`, `getWithdrawableBalance`, and `withdraw`; add `IBinaryMarket` with `status`, `isResolved`, `isVoided`
- [x] 1.3 Remove or stop using settlement `redeem(marketId, outcomeIdx, amount)`; do not add a `to` parameter on any vault redeem path

## 2. Vault trading and NAV

- [x] 2.1 Update `_market` to decode the live record, revert `InvalidMarket` on zero pool or `collateral != asset()`, and gate place/mint/merge on `IBinaryMarket.status() == 1` (redeem on 4 or 5)
- [x] 2.2 Wire mint/merge/redeem to the module with origin ids from the record; exact-amount approvals to the module; proceeds and 6909 mint to the vault
- [x] 2.3 Wire `placeOrder` to `placeBinaryOrder(uint8(side), …)` with buy notional `price * quantity / 1e6`, exact approve to the pool, and `expireTimestampNs` in `(0, marketExpiryNs]`
- [x] 2.4 Change `reduceOrder` to remaining quantity; drop `escrowOf`; include try/catch `getWithdrawableBalance` in `totalAssets`; `syncMarket` withdraws that balance to the vault

## 3. Mocks and unit tests

- [x] 3.1 Update `MockVenue` so `markets` returns the 14-field tuple, a `MockMarket` owns `status()`, pool implements `placeBinaryOrder` / `marketExpiryNs` / remaining `reduceOrder`, and module mint/merge/redeem use origin ids
- [x] 3.2 Update `Trading.t.sol` prices/quantities to 1e6 scale; assert mint succeeds when `status()==1` with no module status field; place/cancel refunds vault; merge and redeem after Resolved/Voided
- [x] 3.3 Add `vm.expectRevert` tests: non-operator, unknown market, collateral mismatch, `status()!=1`, expiry 0 and `> marketExpiryNs`, underfunded 1e6 buy, reduce remaining 0, redeem while Trading
- [x] 3.4 Keep existing ERC-4626 tests green: deposit/mint/withdraw/redeem, preview vs actual, inflation offset, `maxWithdraw` when capital is escrowed, unauthorized withdraw

## 4. Adapter and docs

- [x] 4.1 Document adapter reduce-as-remaining and 1e6 prices; keep `marketId`-only methods; no IERC4626/7540 on the adapter
- [x] 4.2 Update README trading section to the live module record, `status()` on the market, `placeBinaryOrder`, module mint/redeem, and the clone redeploy blocker

## 5. Verify and audit

- [x] 5.1 Run `forge fmt` and `forge test`; confirm `totalAssets()` does not revert when the pool has no `escrowOf`
- [x] 5.2 Security audit of the diff: operator auth, token recipients (vault/module/pool only), exact approvals cleared, no `to` on redeem, views do not revert, fail-closed reverts for every new invalid path
