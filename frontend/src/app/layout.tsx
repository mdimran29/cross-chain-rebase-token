import type { Metadata } from 'next';
import './globals.css';
import { Providers } from './providers';
import { Navbar } from '@/components/layout/Navbar';
import { ToastContainer } from '@/components/ui/ToastContainer';

export const metadata: Metadata = {
  title: 'Cross-Chain Rebase Token | RBT',
  description:
    'Deposit ETH, earn rebasing interest, and bridge across chains with Chainlink CCIP. A premium cross-chain yield protocol.',
  keywords: ['DeFi', 'cross-chain', 'rebase token', 'Chainlink CCIP', 'yield', 'Ethereum'],
  openGraph: {
    title: 'Cross-Chain Rebase Token',
    description: 'Earn yield on ETH deposits and bridge seamlessly across chains.',
    type: 'website',
  },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body>
        <Providers>
          <Navbar />
          <main style={{ paddingTop: '72px', position: 'relative', zIndex: 1 }}>
            {children}
          </main>
          <ToastContainer />
        </Providers>
      </body>
    </html>
  );
}
