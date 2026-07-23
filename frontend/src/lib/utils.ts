import { formatUnits } from 'viem';

export function formatAddress(address: string): string {
  return `${address.slice(0, 6)}...${address.slice(-4)}`;
}

export function formatTokenAmount(amount: bigint, decimals = 18, displayDecimals = 4): string {
  return parseFloat(formatUnits(amount, decimals)).toFixed(displayDecimals);
}

export function formatInterestRate(rate: bigint): string {
  // rate is in 1e18 precision, per second
  // annualized: rate * 365 * 24 * 3600 / 1e18 * 100
  const annualized = (Number(rate) * 365 * 24 * 3600 * 100) / 1e18;
  return annualized.toFixed(4);
}

export function formatUSD(value: number): string {
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency: 'USD',
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(value);
}

export function cn(...classes: (string | undefined | null | false)[]): string {
  return classes.filter(Boolean).join(' ');
}

export function getChainName(chainId: number): string {
  const chains: Record<number, string> = {
    11155111: 'Sepolia',
    300: 'zkSync Sepolia',
    421614: 'Arbitrum Sepolia',
  };
  return chains[chainId] ?? `Chain ${chainId}`;
}

export function getChainColor(chainId: number): string {
  const colors: Record<number, string> = {
    11155111: '#627EEA',   // Ethereum blue
    300: '8C8DFC',          // zkSync purple
    421614: '#28A0F0',      // Arbitrum blue
  };
  return colors[chainId] ?? '#6B7280';
}

export function getExplorerUrl(chainId: number, hash: string, type: 'tx' | 'address' = 'tx'): string {
  const explorers: Record<number, string> = {
    11155111: 'https://sepolia.etherscan.io',
    300: 'https://sepolia.explorer.zksync.io',
    421614: 'https://sepolia.arbiscan.io',
  };
  const base = explorers[chainId] ?? 'https://etherscan.io';
  return `${base}/${type}/${hash}`;
}
