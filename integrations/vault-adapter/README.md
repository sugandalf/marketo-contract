# Vault adapter

Thin viem wrapper so [dreamdex-bot-kit](https://github.com/somnia-chain/dreamdex-bot-kit) `ec-*` strategies trade **as the vault**, not as a funded EOA.

## Setup

```bash
VAULT_ADDRESS=0x...          # trading identity (reads + escrow)
OPERATOR_PRIVATE_KEY=0x...   # hot key; must be the vault's tradingOperator
```

Use `@somnia-chain/markets-sdk` **>= 0.28.0** for market data and book reads. Point inventory and collateral reads at `VAULT_ADDRESS`.

**Do not** pass the operator key as the SDK `privateKey` for auto-pull from a user wallet. The operator only calls vault write functions.

## Writes (operator only)

`placeOrder`, `cancelOrder`, `reduceOrder`, `mintCompleteSet`, `mergeCompleteSet`, `redeem(marketId, outcomeIdx, amount)`, `syncMarket`.

Prices and sizes are raw `uint256` in asset decimals (`asset.decimals()` — 18 on USDso, 6 on tUSDC). Snap to the venue tick/lot grid before sending.

## Not on this adapter

IERC4626 `deposit` / `mint` / `withdraw` / `redeem(shares, …)` and ERC-7540 `requestRedeem`. Those belong to depositors.

`expireTimestampNs == 0` reverts on-chain (`InvalidExpiry`). An underfunded buy reverts even if the operator EOA holds collateral (`InsufficientIdle`).
