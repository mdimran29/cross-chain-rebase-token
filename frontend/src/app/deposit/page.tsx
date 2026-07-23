'use client';

import { useState } from 'react';
import { useAccount, useWriteContract, useWaitForTransactionReceipt, useBalance } from 'wagmi';
import { parseEther, parseUnits, maxUint256 } from 'viem';
import { ConnectButton } from '@rainbow-me/rainbowkit';
import { useRebaseToken } from '@/hooks/useRebaseToken';
import { useToast } from '@/contexts/ToastContext';
import { VAULT_ABI, REBASE_TOKEN_ABI } from '@/lib/contracts';
import { formatTokenAmount, formatInterestRate, getExplorerUrl } from '@/lib/utils';
import { formatUnits } from 'viem';

type Mode = 'deposit' | 'redeem';

export default function DepositPage() {
  const { address, chainId, isConnected } = useAccount();
  const { data: ethBalance } = useBalance({ address });
  const {
    rebasingBalance,
    principalBalance,
    userInterestRate,
    globalInterestRate,
    isLoading,
    vaultAddress,
    tokenAddress,
    refetch,
  } = useRebaseToken();
  const { addToast } = useToast();
  const [mode, setMode] = useState<Mode>('deposit');
  const [amount, setAmount] = useState('');

  const { writeContract, data: txHash, isPending } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash: txHash });

  const handleDeposit = async () => {
    if (!amount || parseFloat(amount) <= 0) return;
    try {
      addToast({ type: 'pending', title: 'Confirm in wallet', message: `Depositing ${amount} ETH` });
      writeContract({
        address: vaultAddress,
        abi: VAULT_ABI,
        functionName: 'deposit',
        value: parseEther(amount),
      });
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : 'Transaction failed';
      addToast({ type: 'error', title: 'Deposit failed', message: msg });
    }
  };

  const handleRedeem = async () => {
    if (!amount || parseFloat(amount) <= 0) return;
    try {
      addToast({ type: 'pending', title: 'Confirm in wallet', message: `Redeeming ${amount} RBT` });
      const isMax = rebasingBalance && parseFloat(amount) >= parseFloat(formatTokenAmount(rebasingBalance, 18, 8));
      writeContract({
        address: vaultAddress,
        abi: VAULT_ABI,
        functionName: 'redeem',
        args: [isMax ? maxUint256 : parseEther(amount)],
      });
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : 'Transaction failed';
      addToast({ type: 'error', title: 'Redeem failed', message: msg });
    }
  };

  // Toast on success
  if (isSuccess && txHash) {
    addToast({
      type: 'success',
      title: mode === 'deposit' ? 'Deposit successful!' : 'Redeem successful!',
      message: `${amount} ${mode === 'deposit' ? 'ETH deposited' : 'RBT redeemed'}`,
      txHash,
      chainId,
    });
  }

  const ethBal = ethBalance ? parseFloat(formatUnits(ethBalance.value, 18)).toFixed(6) : '0';
  const rbtBal = rebasingBalance ? formatTokenAmount(rebasingBalance, 18, 6) : '0';
  const annualRate = globalInterestRate ? formatInterestRate(globalInterestRate) : '—';
  const userRate = userInterestRate ? formatInterestRate(userInterestRate) : '—';

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
        <div style={{ fontSize: '4rem' }}>🏦</div>
        <h2 style={{ fontSize: '1.8rem', fontWeight: 700, color: '#e2e8f0', textAlign: 'center' }}>
          Connect to Deposit
        </h2>
        <ConnectButton />
      </div>
    );
  }

  return (
    <div style={{ maxWidth: '900px', margin: '0 auto', padding: '40px 24px' }}>
      <h1 style={{ fontSize: '2rem', fontWeight: 800, color: '#e2e8f0', letterSpacing: '-0.03em', marginBottom: '8px' }}>
        Deposit & Redeem
      </h1>
      <p style={{ color: '#94a3b8', marginBottom: '40px' }}>
        Deposit ETH to mint RBT tokens and start earning interest. Redeem any time.
      </p>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 380px', gap: '24px', alignItems: 'start' }}>
        {/* Main Panel */}
        <div className="glass-card" style={{ padding: '32px' }}>
          {/* Tabs */}
          <div style={{
            display: 'flex',
            gap: '8px',
            background: 'rgba(4,13,26,0.8)',
            borderRadius: '12px',
            padding: '6px',
            marginBottom: '32px',
            border: '1px solid rgba(56,139,253,0.1)',
          }}>
            {(['deposit', 'redeem'] as Mode[]).map((m) => (
              <button
                key={m}
                onClick={() => { setMode(m); setAmount(''); }}
                style={{
                  flex: 1,
                  padding: '10px',
                  borderRadius: '8px',
                  border: 'none',
                  cursor: 'pointer',
                  fontWeight: 600,
                  fontSize: '0.9rem',
                  background: mode === m ? 'linear-gradient(135deg, #0ea5e9, #6366f1)' : 'transparent',
                  color: mode === m ? 'white' : '#64748b',
                  transition: 'all 0.2s',
                  textTransform: 'capitalize',
                }}
              >
                {m === 'deposit' ? '⬇ Deposit ETH' : '⬆ Redeem RBT'}
              </button>
            ))}
          </div>

          {/* Balance display */}
          <div style={{
            display: 'flex',
            justifyContent: 'space-between',
            marginBottom: '8px',
          }}>
            <span style={{ color: '#64748b', fontSize: '0.85rem' }}>
              {mode === 'deposit' ? 'ETH Balance' : 'RBT Balance'}
            </span>
            <button
              onClick={() => setAmount(mode === 'deposit' ? ethBal : rbtBal)}
              style={{
                background: 'none',
                border: 'none',
                color: '#38bdf8',
                cursor: 'pointer',
                fontSize: '0.82rem',
                fontWeight: 600,
              }}
            >
              Max: {mode === 'deposit' ? `${ethBal} ETH` : `${rbtBal} RBT`}
            </button>
          </div>

          {/* Amount Input */}
          <div style={{ position: 'relative', marginBottom: '24px' }}>
            <input
              type="number"
              className="input-field"
              placeholder="0.0"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              style={{ paddingRight: '80px', fontSize: '1.4rem', padding: '18px 80px 18px 16px' }}
            />
            <span style={{
              position: 'absolute',
              right: '16px',
              top: '50%',
              transform: 'translateY(-50%)',
              color: '#38bdf8',
              fontWeight: 700,
              fontSize: '0.9rem',
            }}>
              {mode === 'deposit' ? 'ETH' : 'RBT'}
            </span>
          </div>

          {/* Preview */}
          {amount && parseFloat(amount) > 0 && (
            <div style={{
              background: 'rgba(56,189,248,0.04)',
              border: '1px solid rgba(56,189,248,0.15)',
              borderRadius: '10px',
              padding: '16px',
              marginBottom: '24px',
            }}>
              <div style={{ color: '#64748b', fontSize: '0.78rem', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: '10px' }}>
                Preview
              </div>
              {mode === 'deposit' ? (
                <>
                  <Row label="You send" value={`${amount} ETH`} />
                  <Row label="You receive" value={`≈ ${amount} RBT`} highlight />
                  <Row label="Your interest rate" value={`${annualRate}% APY`} />
                </>
              ) : (
                <>
                  <Row label="You burn" value={`${amount} RBT`} />
                  <Row label="You receive" value={`≈ ${amount} ETH`} highlight />
                </>
              )}
            </div>
          )}

          {/* Action button */}
          <button
            className="btn-primary"
            onClick={mode === 'deposit' ? handleDeposit : handleRedeem}
            disabled={!amount || parseFloat(amount) <= 0 || isPending || isConfirming}
            style={{ width: '100%', padding: '16px', fontSize: '1rem' }}
          >
            <span>
              {isPending ? 'Confirm in wallet...' : isConfirming ? 'Confirming...' : mode === 'deposit' ? 'Deposit ETH' : 'Redeem RBT'}
            </span>
          </button>

          {txHash && (
            <div style={{ textAlign: 'center', marginTop: '12px' }}>
              <a
                href={chainId ? getExplorerUrl(chainId, txHash) : '#'}
                target="_blank"
                rel="noopener noreferrer"
                style={{ color: '#38bdf8', fontSize: '0.82rem', textDecoration: 'none' }}
              >
                View transaction ↗
              </a>
            </div>
          )}
        </div>

        {/* Side info */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: '16px' }}>
          <div className="glass-card" style={{ padding: '24px' }}>
            <h3 style={{ color: '#e2e8f0', fontWeight: 700, marginBottom: '16px', fontSize: '0.95rem' }}>Your Position</h3>
            <InfoRow label="RBT Balance" value={`${rbtBal} RBT`} loading={isLoading} />
            <InfoRow label="Principal" value={`${principalBalance ? formatTokenAmount(principalBalance, 18, 4) : '—'} RBT`} loading={isLoading} />
            <InfoRow label="Your Rate" value={`${userRate}% APY`} color="#a78bfa" loading={isLoading} />
          </div>

          <div className="glass-card" style={{ padding: '24px' }}>
            <h3 style={{ color: '#e2e8f0', fontWeight: 700, marginBottom: '16px', fontSize: '0.95rem' }}>Protocol</h3>
            <InfoRow label="Global Rate" value={`${annualRate}% APY`} loading={isLoading} />
            <InfoRow label="Model" value="Linear, per-user" />
            <InfoRow label="Rate trend" value="Only decreasing" />
          </div>

          <div className="glass-card" style={{ padding: '20px', background: 'rgba(251,191,36,0.04)', borderColor: 'rgba(251,191,36,0.15)' }}>
            <div style={{ display: 'flex', gap: '10px', alignItems: 'flex-start' }}>
              <span>⚠️</span>
              <p style={{ color: '#94a3b8', fontSize: '0.82rem', lineHeight: 1.5 }}>
                Ensure the vault has sufficient ETH liquidity before redeeming. Large redemptions
                may fail if the vault is underfunded.
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

function Row({ label, value, highlight }: { label: string; value: string; highlight?: boolean }) {
  return (
    <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '8px' }}>
      <span style={{ color: '#94a3b8', fontSize: '0.85rem' }}>{label}</span>
      <span style={{ color: highlight ? '#34d399' : '#e2e8f0', fontWeight: highlight ? 700 : 500, fontSize: '0.85rem' }}>{value}</span>
    </div>
  );
}

function InfoRow({ label, value, color = '#e2e8f0', loading = false }: { label: string; value: string; color?: string; loading?: boolean }) {
  return (
    <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '10px' }}>
      <span style={{ color: '#64748b', fontSize: '0.82rem' }}>{label}</span>
      {loading ? (
        <div className="skeleton" style={{ width: '80px', height: '16px' }} />
      ) : (
        <span style={{ color, fontWeight: 600, fontSize: '0.85rem', fontFamily: "'JetBrains Mono', monospace" }}>{value}</span>
      )}
    </div>
  );
}
