'use client';

import Link from 'next/link';
import { useAccount } from 'wagmi';
import { ConnectButton } from '@rainbow-me/rainbowkit';
import { useRebaseToken } from '@/hooks/useRebaseToken';
import { formatTokenAmount, formatInterestRate } from '@/lib/utils';
import { formatUnits } from 'viem';

const CHAINS = [
  { id: 11155111, name: 'Ethereum Sepolia', color: '#627EEA', icon: '⟠', tag: 'Live' },
  { id: 300, name: 'zkSync Sepolia', color: '#8C8DFC', icon: '⚡', tag: 'Supported' },
  { id: 421614, name: 'Arbitrum Sepolia', color: '#28A0F0', icon: '◈', tag: 'Supported' },
];

const STEPS = [
  {
    step: '01',
    title: 'Deposit ETH',
    desc: 'Send ETH to the Vault contract. Receive RBT tokens at a 1:1 ratio with your deposited amount.',
    icon: '🏦',
    color: '#38bdf8',
  },
  {
    step: '02',
    title: 'Earn Rebase Interest',
    desc: 'Your RBT balance grows automatically over time. Interest accrues linearly based on your personal rate locked at deposit.',
    icon: '📈',
    color: '#34d399',
  },
  {
    step: '03',
    title: 'Bridge via CCIP',
    desc: 'Move your RBT cross-chain using Chainlink CCIP. Your interest rate metadata travels with your tokens.',
    icon: '🌉',
    color: '#a78bfa',
  },
  {
    step: '04',
    title: 'Redeem ETH',
    desc: 'Burn your RBT tokens to receive ETH back from the vault. Redeem principal + all accrued interest.',
    icon: '💎',
    color: '#fbbf24',
  },
];

export default function HomePage() {
  const { isConnected } = useAccount();
  const { globalInterestRate, totalSupply } = useRebaseToken();

  const annualRate = globalInterestRate ? formatInterestRate(globalInterestRate) : '5.00';
  const tvl = totalSupply ? formatTokenAmount(totalSupply, 18, 2) : '0.00';

  return (
    <div style={{ minHeight: '100vh', overflow: 'hidden' }}>
      {/* Hero Section */}
      <section style={{
        position: 'relative',
        minHeight: '100vh',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        padding: '80px 24px',
        overflow: 'hidden',
      }}>
        {/* Orbs */}
        <div className="hero-orb" style={{
          width: '600px', height: '600px',
          background: 'radial-gradient(circle, rgba(56,189,248,0.12) 0%, transparent 70%)',
          top: '-150px', left: '-200px',
        }} />
        <div className="hero-orb" style={{
          width: '500px', height: '500px',
          background: 'radial-gradient(circle, rgba(99,102,241,0.1) 0%, transparent 70%)',
          bottom: '-100px', right: '-150px',
        }} />
        <div className="hero-orb" style={{
          width: '300px', height: '300px',
          background: 'radial-gradient(circle, rgba(52,211,153,0.08) 0%, transparent 70%)',
          top: '40%', left: '60%',
        }} />

        <div style={{ textAlign: 'center', maxWidth: '900px', position: 'relative', zIndex: 2 }}>
          {/* Badge */}
          <div style={{
            display: 'inline-flex',
            alignItems: 'center',
            gap: '8px',
            background: 'rgba(56,189,248,0.08)',
            border: '1px solid rgba(56,189,248,0.25)',
            borderRadius: '24px',
            padding: '6px 16px',
            marginBottom: '32px',
            fontSize: '0.8rem',
            color: '#38bdf8',
            fontWeight: 500,
          }}>
            <span className="live-dot" />
            Powered by Chainlink CCIP · Live on Sepolia
          </div>

          {/* Headline */}
          <h1 style={{
            fontSize: 'clamp(2.5rem, 7vw, 5rem)',
            fontWeight: 900,
            lineHeight: 1.05,
            letterSpacing: '-0.04em',
            marginBottom: '24px',
            color: '#e2e8f0',
          }}>
            Cross-Chain{' '}
            <span className="gradient-text-blue">Rebasing</span>
            <br />
            Token Protocol
          </h1>

          <p style={{
            fontSize: 'clamp(1rem, 2.5vw, 1.25rem)',
            color: '#94a3b8',
            lineHeight: 1.7,
            maxWidth: '640px',
            margin: '0 auto 48px',
          }}>
            Deposit ETH, earn continuous interest via rebasing RBT tokens,
            and bridge seamlessly across chains — your yield travels with you.
          </p>

          {/* CTA Buttons */}
          <div style={{ display: 'flex', gap: '16px', justifyContent: 'center', flexWrap: 'wrap' }}>
            {isConnected ? (
              <>
                <Link href="/deposit">
                  <button className="btn-primary" style={{ padding: '14px 32px', fontSize: '1rem' }}>
                    <span>Start Earning →</span>
                  </button>
                </Link>
                <Link href="/dashboard">
                  <button className="btn-secondary" style={{ padding: '14px 32px', fontSize: '1rem' }}>
                    View Dashboard
                  </button>
                </Link>
              </>
            ) : (
              <>
                <ConnectButton.Custom>
                  {({ openConnectModal }) => (
                    <button
                      className="btn-primary"
                      onClick={openConnectModal}
                      style={{ padding: '14px 32px', fontSize: '1rem' }}
                    >
                      <span>Connect Wallet →</span>
                    </button>
                  )}
                </ConnectButton.Custom>
                <Link href="/analytics">
                  <button className="btn-secondary" style={{ padding: '14px 32px', fontSize: '1rem' }}>
                    View Analytics
                  </button>
                </Link>
              </>
            )}
          </div>

          {/* Live Stats */}
          <div style={{
            display: 'flex',
            gap: '32px',
            justifyContent: 'center',
            flexWrap: 'wrap',
            marginTop: '64px',
          }}>
            {[
              { label: 'Annual Interest Rate', value: `${annualRate}%`, color: '#34d399' },
              { label: 'RBT Total Supply', value: `${tvl} RBT`, color: '#38bdf8' },
              { label: 'Supported Chains', value: '3 Chains', color: '#a78bfa' },
              { label: 'Bridge Protocol', value: 'Chainlink CCIP', color: '#fbbf24' },
            ].map(({ label, value, color }) => (
              <div key={label} style={{ textAlign: 'center' }}>
                <div style={{
                  fontSize: '1.5rem',
                  fontWeight: 800,
                  color,
                  fontFamily: "'JetBrains Mono', monospace",
                  letterSpacing: '-0.02em',
                }}>
                  {value}
                </div>
                <div style={{ fontSize: '0.78rem', color: '#64748b', marginTop: '4px', fontWeight: 500 }}>
                  {label}
                </div>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* How it Works */}
      <section style={{
        padding: '100px 24px',
        maxWidth: '1200px',
        margin: '0 auto',
      }}>
        <div style={{ textAlign: 'center', marginBottom: '64px' }}>
          <h2 style={{ fontSize: '2.2rem', fontWeight: 800, color: '#e2e8f0', letterSpacing: '-0.03em', marginBottom: '12px' }}>
            How it <span className="gradient-text-blue">Works</span>
          </h2>
          <p style={{ color: '#94a3b8', fontSize: '1.05rem' }}>
            Four simple steps to earn yield across chains
          </p>
        </div>

        <div style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fit, minmax(240px, 1fr))',
          gap: '24px',
        }}>
          {STEPS.map(({ step, title, desc, icon, color }) => (
            <div key={step} className="glass-card" style={{ padding: '32px 24px' }}>
              <div style={{
                display: 'flex',
                alignItems: 'center',
                gap: '12px',
                marginBottom: '20px',
              }}>
                <span style={{ fontSize: '2rem' }}>{icon}</span>
                <span style={{
                  fontSize: '0.75rem',
                  fontWeight: 700,
                  color,
                  fontFamily: "'JetBrains Mono', monospace",
                  letterSpacing: '0.1em',
                }}>
                  STEP {step}
                </span>
              </div>
              <h3 style={{
                fontSize: '1.1rem',
                fontWeight: 700,
                color: '#e2e8f0',
                marginBottom: '12px',
              }}>
                {title}
              </h3>
              <p style={{ color: '#94a3b8', fontSize: '0.9rem', lineHeight: 1.65 }}>
                {desc}
              </p>
              <div style={{
                marginTop: '20px',
                height: '2px',
                background: `linear-gradient(90deg, ${color}60, transparent)`,
                borderRadius: '1px',
              }} />
            </div>
          ))}
        </div>
      </section>

      {/* Supported Chains */}
      <section style={{ padding: '80px 24px', maxWidth: '900px', margin: '0 auto' }}>
        <div style={{ textAlign: 'center', marginBottom: '48px' }}>
          <h2 style={{ fontSize: '2rem', fontWeight: 800, color: '#e2e8f0', letterSpacing: '-0.03em', marginBottom: '12px' }}>
            Supported <span className="gradient-text-green">Networks</span>
          </h2>
        </div>

        <div style={{ display: 'flex', gap: '20px', justifyContent: 'center', flexWrap: 'wrap' }}>
          {CHAINS.map((chain) => (
            <div key={chain.id} className="glass-card" style={{
              padding: '24px 32px',
              display: 'flex',
              alignItems: 'center',
              gap: '16px',
              minWidth: '220px',
            }}>
              <div style={{
                width: '48px',
                height: '48px',
                borderRadius: '12px',
                background: `${chain.color}15`,
                border: `1px solid ${chain.color}30`,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                fontSize: '22px',
              }}>
                {chain.icon}
              </div>
              <div>
                <div style={{ fontWeight: 700, color: '#e2e8f0', marginBottom: '4px' }}>
                  {chain.name}
                </div>
                <span className={chain.tag === 'Live' ? 'badge-success' : 'badge-info'}>
                  {chain.tag}
                </span>
              </div>
            </div>
          ))}
        </div>
      </section>

      {/* Cross-chain section */}
      <section style={{ padding: '80px 24px', maxWidth: '900px', margin: '0 auto 60px' }}>
        <div className="glass-card" style={{ padding: '48px', textAlign: 'center', position: 'relative', overflow: 'hidden' }}>
          <div style={{
            position: 'absolute', inset: 0,
            background: 'radial-gradient(ellipse at 50% 0%, rgba(56,189,248,0.06) 0%, transparent 60%)',
            pointerEvents: 'none',
          }} />
          <h2 style={{ fontSize: '1.8rem', fontWeight: 800, color: '#e2e8f0', letterSpacing: '-0.03em', marginBottom: '16px' }}>
            Interest Metadata <span className="gradient-text-blue">Travels With You</span>
          </h2>
          <p style={{ color: '#94a3b8', maxWidth: '580px', margin: '0 auto 32px', lineHeight: 1.7 }}>
            When you bridge RBT via Chainlink CCIP, your personal interest rate is encoded
            into the cross-chain message. On the destination chain, your tokens are minted
            at your original rate — no yield is lost during bridging.
          </p>
          <div style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            gap: '16px',
            flexWrap: 'wrap',
          }}>
            {['Sepolia', '→', 'CCIP Router', '→', 'zkSync / Arbitrum'].map((item, i) => (
              <div key={i} style={{
                padding: item === '→' ? '0' : '8px 20px',
                borderRadius: '10px',
                background: item === '→' ? 'transparent' : 'rgba(56,189,248,0.08)',
                border: item === '→' ? 'none' : '1px solid rgba(56,189,248,0.2)',
                color: item === '→' ? '#38bdf8' : '#e2e8f0',
                fontSize: item === '→' ? '1.5rem' : '0.9rem',
                fontWeight: 600,
              }}>
                {item}
              </div>
            ))}
          </div>
          <div style={{ marginTop: '32px' }}>
            <span className="badge-success" style={{ fontSize: '0.85rem', padding: '6px 16px' }}>
              ✓ Interest rate metadata preserved
            </span>
          </div>
        </div>
      </section>
    </div>
  );
}
