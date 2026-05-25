import { getDefaultConfig } from '@rainbow-me/rainbowkit';
import { sepolia, zkSyncSepoliaTestnet, arbitrumSepolia } from 'wagmi/chains';

export const config = getDefaultConfig({
  appName: 'Cross-Chain Rebase Token',
  projectId: process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID ?? 'demo_project_id',
  chains: [sepolia, zkSyncSepoliaTestnet, arbitrumSepolia],
  ssr: true,
});
