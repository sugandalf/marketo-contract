export const vaultAbi = [
  {
    type: "function",
    name: "placeOrder",
    stateMutability: "nonpayable",
    inputs: [
      { name: "marketId", type: "bytes32" },
      { name: "side", type: "uint8" },
      { name: "price", type: "uint256" },
      { name: "quantity", type: "uint256" },
      { name: "expireTimestampNs", type: "uint64" },
      { name: "orderType", type: "uint8" },
    ],
    outputs: [{ name: "orderId", type: "uint128" }],
  },
  {
    type: "function",
    name: "cancelOrder",
    stateMutability: "nonpayable",
    inputs: [
      { name: "marketId", type: "bytes32" },
      { name: "orderId", type: "uint128" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "reduceOrder",
    stateMutability: "nonpayable",
    inputs: [
      { name: "marketId", type: "bytes32" },
      { name: "orderId", type: "uint128" },
      { name: "remaining", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "mintCompleteSet",
    stateMutability: "nonpayable",
    inputs: [
      { name: "marketId", type: "bytes32" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "mergeCompleteSet",
    stateMutability: "nonpayable",
    inputs: [
      { name: "marketId", type: "bytes32" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "redeem",
    stateMutability: "nonpayable",
    inputs: [
      { name: "marketId", type: "bytes32" },
      { name: "outcomeIdx", type: "uint8" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "syncMarket",
    stateMutability: "nonpayable",
    inputs: [{ name: "marketId", type: "bytes32" }],
    outputs: [],
  },
] as const;

export const operatorMethods = [
  "placeOrder",
  "cancelOrder",
  "reduceOrder",
  "mintCompleteSet",
  "mergeCompleteSet",
  "redeem",
  "syncMarket",
] as const;

export const forbiddenMethods = ["withdraw", "redeemShares", "requestRedeem", "deposit", "mint"] as const;

export type Side = 0 | 1 | 2 | 3; // BUY_YES, SELL_YES, BUY_NO, SELL_NO

export type VaultAdapterConfig = {
  vault: `0x${string}`;
  walletClient: {
    account: { address: `0x${string}` };
    writeContract: (args: unknown) => Promise<`0x${string}`>;
  };
  publicClient: {
    readContract: (args: unknown) => Promise<unknown>;
  };
  asset: `0x${string}`;
};

function snap(amount: bigint, decimals: number, grid: bigint): bigint {
  if (grid === 0n) return amount;
  return (amount / grid) * grid;
}

/**
 * Operator-key signer. Reads always use `vault` as the trader, never the operator EOA.
 * Does not wrap IERC4626 withdraw/redeem or ERC-7540 requestRedeem.
 */
export function createVaultAdapter(cfg: VaultAdapterConfig) {
  const trader = cfg.vault;

  async function assetDecimals(): Promise<number> {
    const d = await cfg.publicClient.readContract({
      address: cfg.asset,
      abi: [{ type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] }],
      functionName: "decimals",
    });
    return Number(d);
  }

  async function idleCollateral(): Promise<bigint> {
    const bal = await cfg.publicClient.readContract({
      address: cfg.asset,
      abi: [
        {
          type: "function",
          name: "balanceOf",
          stateMutability: "view",
          inputs: [{ name: "account", type: "address" }],
          outputs: [{ type: "uint256" }],
        },
      ],
      functionName: "balanceOf",
      args: [trader],
    });
    return bal as bigint;
  }

  async function outcomeBalance(token: `0x${string}`, id: bigint): Promise<bigint> {
    const bal = await cfg.publicClient.readContract({
      address: token,
      abi: [
        {
          type: "function",
          name: "balanceOf",
          stateMutability: "view",
          inputs: [
            { name: "owner", type: "address" },
            { name: "id", type: "uint256" },
          ],
          outputs: [{ type: "uint256" }],
        },
      ],
      functionName: "balanceOf",
      args: [trader, id],
    });
    return bal as bigint;
  }

  function write(functionName: (typeof operatorMethods)[number], args: readonly unknown[]) {
    return cfg.walletClient.writeContract({
      address: cfg.vault,
      abi: vaultAbi,
      functionName,
      args,
      account: cfg.walletClient.account,
    });
  }

  return {
    trader,
    operatorMethods,
    forbiddenMethods,
    snap,
    assetDecimals,
    idleCollateral,
    outcomeBalance,
    placeOrder: (
      marketId: `0x${string}`,
      side: Side,
      price: bigint,
      quantity: bigint,
      expireTimestampNs: bigint,
      orderType: number,
    ) => write("placeOrder", [marketId, side, price, quantity, expireTimestampNs, orderType]),
    cancelOrder: (marketId: `0x${string}`, orderId: bigint) => write("cancelOrder", [marketId, orderId]),
    reduceOrder: (marketId: `0x${string}`, orderId: bigint, remaining: bigint) =>
      write("reduceOrder", [marketId, orderId, remaining]),
    mintCompleteSet: (marketId: `0x${string}`, amount: bigint) => write("mintCompleteSet", [marketId, amount]),
    mergeCompleteSet: (marketId: `0x${string}`, amount: bigint) => write("mergeCompleteSet", [marketId, amount]),
    redeem: (marketId: `0x${string}`, outcomeIdx: number, amount: bigint) =>
      write("redeem", [marketId, outcomeIdx, amount]),
    syncMarket: (marketId: `0x${string}`) => write("syncMarket", [marketId]),
  };
}