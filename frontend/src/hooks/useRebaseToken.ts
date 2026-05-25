'use client';

import { useReadContract, useReadContracts } from 'wagmi';
import { useAccount } from 'wagmi';
import { REBASE_TOKEN_ABI, REBASE_TOKEN_ADDRESS, VAULT_ABI, VAULT_ADDRESS } from '@/lib/contracts';

export function useRebaseToken() {
  const { address, chainId } = useAccount();

  const tokenAddress = chainId === 11155111
    ? REBASE_TOKEN_ADDRESS.sepolia
    : REBASE_TOKEN_ADDRESS.zkSyncSepolia;

  const vaultAddress = VAULT_ADDRESS.sepolia;

  const { data: balanceData, isLoading: balanceLoading, refetch: refetchBalance } = useReadContracts({
    contracts: [
      {
        address: tokenAddress,
        abi: REBASE_TOKEN_ABI,
        functionName: 'balanceOf',
        args: address ? [address] : undefined,
      },
      {
        address: tokenAddress,
        abi: REBASE_TOKEN_ABI,
        functionName: 'principalBalanceOf',
        args: address ? [address] : undefined,
      },
      {
        address: tokenAddress,
        abi: REBASE_TOKEN_ABI,
        functionName: 'getUserInterestRate',
        args: address ? [address] : undefined,
      },
      {
        address: tokenAddress,
        abi: REBASE_TOKEN_ABI,
        functionName: 'getInterestRate',
      },
      {
        address: tokenAddress,
        abi: REBASE_TOKEN_ABI,
        functionName: 'totalSupply',
      },
    ],
    query: { enabled: !!address },
  });

  const rebasingBalance = balanceData?.[0]?.result as bigint | undefined;
  const principalBalance = balanceData?.[1]?.result as bigint | undefined;
  const userInterestRate = balanceData?.[2]?.result as bigint | undefined;
  const globalInterestRate = balanceData?.[3]?.result as bigint | undefined;
  const totalSupply = balanceData?.[4]?.result as bigint | undefined;

  const accruedInterest =
    rebasingBalance !== undefined && principalBalance !== undefined
      ? rebasingBalance - principalBalance
      : undefined;

  return {
    rebasingBalance,
    principalBalance,
    accruedInterest,
    userInterestRate,
    globalInterestRate,
    totalSupply,
    isLoading: balanceLoading,
    tokenAddress,
    vaultAddress,
    refetch: refetchBalance,
  };
}
