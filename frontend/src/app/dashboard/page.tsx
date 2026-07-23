'use client';

import { useAccount, useBalance } from 'wagmi';
import { ConnectButton } from '@rainbow-me/rainbowkit';
import { useRebaseToken } from '@/hooks/useRebaseToken';
import { formatAddress, formatTokenAmount, formatInterestRate, getChainName, getExplorerUrl } from '@/lib/utils';
import Link from 'next/link';
import { formatUnits } from 'viem';

function StatCard({
  label,
  value,
  subValue,
  color = '#38bdf8',
  loading = false,
  icon,
}: {
  label: string;
  value: string;
  subValue?: string;
  color?: string;
  loading?: boolean;
  icon: string;
}) {
  return (
    <div className="glass-card" style={{ padding: '24px' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: '12px' }}>
        <span style={{ color: '#64748b', fontSize: '0.82rem', fontWeight: 500, letterSpacing: '0.04em', textTransform: 'uppercase' }}>
          {label}
        </span>
        <span style={{ fontSize: '1.4rem' }}>{icon}</span>
      </div>
      {loading ? (
        <div className="skeleton" style={{ height: '36px', width: '70%', marginBottom: '8px' }} />
      ) : (
        <div className="stat-number" style={{ color, marginBottom: '6px' }}>{value}</div>
      )}
      {subValue && !loading && (
        <div style={{ color: '#94a3b8', fontSize: '0.8rem' }}>{subValue}</div>
      )}
    </div>
  );
}

export default function DashboardPage() {
  const { address, chainId, isConnected } = useAccount();
  const { data: ethBalance } = useBalance({ address });
  const {
    rebasingBalance,
    principalBalance,
    accruedInterest,
    userInterestRate,
    globalInterestRate,
    totalSupply,
    isLoading,
    tokenAddress,
    vaultAddress,
  } = useRebaseToken();

  if (!isConnected) {
    return (
      <div style={{
        minHeight: '80vh',
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        gap: '24px',
        padding: '24px',
      }}>
        <div style={{ fontSize: '4rem' }}>🔗</div>
        <h2 style={{ fontSize: '1.8rem', fontWeight: 700, color: '#e2e8f0', textAlign: 'center' }}>
          Connect Your Wallet
        </h2>
        <p style={{ color: '#94a3b8', textAlign: 'center', maxWidth: '400px' }}>
          Connect to see your RBT balance, accrued interest, and manage your positions.
        </p>
        <ConnectButton />
      </div>
    );
  }

  const rbtBalance = rebasingBalance ? formatTokenAmount(rebasingBalance, 18, 6) : '0.000000';
  const principal = principalBalance ? formatTokenAmount(principalBalance, 18, 6) : '0.000000';
  const interest = accruedInterest ? formatTokenAmount(accruedInterest, 18, 8) : '0.00000000';
  const userRate = userInterestRate ? formatInterestRate(userInterestRate) : '—';
  const globalRate = globalInterestRate ? formatInterestRate(globalInterestRate) : '—';
  const supply = totalSupply ? formatTokenAmount(totalSupply, 18, 2) : '—';
  const ethBal = ethBalance ? parseFloat(formatUnits(ethBalance.value, 18)).toFixed(4) : '—';

  return (
    <div style={{ maxWidth: '1200px', margin: '0 auto', padding: '40px 24px' }}>
      {/* Header */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', flexWrap: 'wrap', gap: '16px', marginBottom: '40px' }}>
        <div>
          <h1 style={{ fontSize: '2rem', fontWeight: 800, color: '#e2e8f0', letterSpacing: '-0.03em', marginBottom: '6px' }}>
            Dashboard
          </h1>
          <div style={{ display: 'flex', alignItems: 'center', gap: '10px', flexWrap: 'wrap' }}>
            <code style={{
              color: '#94a3b8',
              fontSize: '0.85rem',
              background: 'rgba(56,139,253,0.08)',
              padding: '4px 12px',
              borderRadius: '8px',
              border: '1px solid rgba(56,139,253,0.15)',
            }}>
              {address ? formatAddress(address) : '...'}
            </code>
            <span style={{
              background: chainId === 11155111 ? 'rgba(98,126,234,0.15)' : 'rgba(56,189,248,0.1)',
              border: `1px solid ${chainId === 11155111 ? 'rgba(98,126,234,0.3)' : 'rgba(56,189,248,0.2)'}`,
              color: chainId === 11155111 ? '#627EEA' : '#38bdf8',
              borderRadius: '20px',
              padding: '4px 12px',
              fontSize: '0.78rem',
              fontWeight: 600,
            }}>
              {chainId ? getChainName(chainId) : 'Unknown'}
            </span>
            <span className="live-dot" />
          </div>
        </div>
        <div style={{ display: 'flex', gap: '12px' }}>
          <Link href="/deposit">
            <button className="btn-primary" style={{ padding: '10px 20px' }}>
              <span>Deposit ETH</span>
            </button>
          </Link>
          <Link href="/bridge">
            <button className="btn-secondary" style={{ padding: '10px 20px' }}>
              Bridge
            </button>
          </Link>
        </div>
      </div>

      {/* Stats grid */}
      <div style={{
        display: 'grid',
        gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))',
        gap: '16px',
        marginBottom: '32px',
      }}>
        <StatCard label="RBT Balance" value={rbtBalance} subValue="Rebasing (with interest)" color="#38bdf8" loading={isLoading} icon="🪙" />
        <StatCard label="Principal Balance" value={principal} subValue="Deposited amount" color="#e2e8f0" loading={isLoading} icon="🏦" />
        <StatCard label="Accrued Interest" value={interest} subValue="Earned since deposit" color="#34d399" loading={isLoading} icon="📈" />
        <StatCard label="Your Interest Rate" value={userRate ? `${userRate}% APY` : '—'} subValue="Locked at deposit" color="#a78bfa" loading={isLoading} icon="📊" />
        <StatCard label="ETH Balance" value={`${ethBal} ETH`} subValue="Native balance" color="#fbbf24" loading={false} icon="⟠" />
        <StatCard label="Global Rate" value={globalRate ? `${globalRate}% APY` : '—'} subValue="For new deposits" color="#f97316" loading={isLoading} icon="🌐" />
      </div>

      {/* Contract Addresses */}
      <div className="glass-card" style={{ padding: '28px', marginBottom: '24px' }}>
        <h3 style={{ color: '#e2e8f0', fontWeight: 700, marginBottom: '20px', fontSize: '1rem' }}>
          Contract Addresses
        </h3>
        <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
          {[
            { label: 'RebaseToken', addr: tokenAddress },
            { label: 'Vault', addr: vaultAddress },
          ].map(({ label, addr }) => (
            <div key={label} style={{
              display: 'flex',
              justifyContent: 'space-between',
              alignItems: 'center',
              padding: '12px 16px',
              background: 'rgba(4,13,26,0.6)',
              borderRadius: '10px',
              border: '1px solid rgba(56,139,253,0.1)',
              flexWrap: 'wrap',
              gap: '8px',
            }}>
              <span style={{ color: '#64748b', fontSize: '0.82rem', fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.04em' }}>
                {label}
              </span>
              <div style={{ display: 'flex', alignItems: 'center', gap: '10px' }}>
                <code style={{ color: '#94a3b8', fontSize: '0.82rem' }}>{addr}</code>
                <button
                  onClick={() => navigator.clipboard.writeText(addr)}
                  style={{ background: 'none', border: 'none', cursor: 'pointer', color: '#38bdf8', fontSize: '0.8rem' }}
                >
                  Copy
                </button>
                {chainId && (
                  <a
                    href={getExplorerUrl(chainId, addr, 'address')}
                    target="_blank"
                    rel="noopener noreferrer"
                    style={{ color: '#38bdf8', fontSize: '0.8rem', textDecoration: 'none' }}
                  >
                    ↗
                  </a>
                )}
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* Protocol info */}
      <div className="glass-card" style={{ padding: '28px' }}>
        <h3 style={{ color: '#e2e8f0', fontWeight: 700, marginBottom: '16px', fontSize: '1rem' }}>
          Protocol Stats
        </h3>
        <div style={{ display: 'flex', gap: '32px', flexWrap: 'wrap' }}>
          <div>
            <div style={{ color: '#64748b', fontSize: '0.78rem', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: '4px' }}>Total RBT Supply</div>
            <div style={{ color: '#38bdf8', fontFamily: "'JetBrains Mono'", fontWeight: 700, fontSize: '1.1rem' }}>{supply} RBT</div>
          </div>
          <div>
            <div style={{ color: '#64748b', fontSize: '0.78rem', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: '4px' }}>Current Network</div>
            <div style={{ color: '#e2e8f0', fontWeight: 600 }}>{chainId ? getChainName(chainId) : '—'}</div>
          </div>
          <div>
            <div style={{ color: '#64748b', fontSize: '0.78rem', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: '4px' }}>Interest Model</div>
            <div style={{ color: '#34d399', fontWeight: 600 }}>Linear, Per-User Rate</div>
          </div>
        </div>
      </div>
    </div>
  );
}
