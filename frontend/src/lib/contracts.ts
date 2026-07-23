// Contract ABIs and addresses

export const REBASE_TOKEN_ADDRESS = {
  sepolia: '0x46948AC074C0a9E9734F8AEe55a41d542CdD3b19' as `0x${string}`,
  zkSyncSepolia: '0x0000000000000000000000000000000000000000' as `0x${string}`, // update after deployment
} as const;

export const VAULT_ADDRESS = {
  sepolia: '0x27748128Ec88727FCc40e5d49B237c5A8c84E1ea' as `0x${string}`,
} as const;

export const REBASE_TOKEN_POOL_ADDRESS = {
  sepolia: '0x088659FB202C501095850b3EcBD6A3a205030E69' as `0x${string}`,
} as const;

// CCIP chain selectors
export const CHAIN_SELECTORS = {
  sepolia: '16015286601757825753',
  zkSyncSepolia: '6898391096552792247',
  arbitrumSepolia: '3478487238524512106',
} as const;

export const REBASE_TOKEN_ABI = [
  {
    name: 'balanceOf',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: '_user', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'principalBalanceOf',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: '_user', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'getInterestRate',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'getUserInterestRate',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: '_user', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'totalSupply',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'approve',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'spender', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    name: 'allowance',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'owner', type: 'address' },
      { name: 'spender', type: 'address' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'InterestRateSet',
    type: 'event',
    inputs: [{ name: 'newInterestRate', type: 'uint256', indexed: false }],
  },
] as const;

export const VAULT_ABI = [
  {
    name: 'deposit',
    type: 'function',
    stateMutability: 'payable',
    inputs: [],
    outputs: [],
  },
  {
    name: 'redeem',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [{ name: '_amount', type: 'uint256' }],
    outputs: [],
  },
  {
    name: 'i_rebaseToken',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'address' }],
  },
  {
    name: 'Deposit',
    type: 'event',
    inputs: [
      { name: 'user', type: 'address', indexed: true },
      { name: 'amount', type: 'uint256', indexed: false },
    ],
  },
  {
    name: 'Redeem',
    type: 'event',
    inputs: [
      { name: 'user', type: 'address', indexed: true },
      { name: 'amount', type: 'uint256', indexed: false },
    ],
  },
] as const;
