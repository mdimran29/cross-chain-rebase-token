'use client';

import { useState } from 'react';
import { useAccount, useWriteContract, useWaitForTransactionReceipt, useReadContract } from 'wagmi';
import { parseEther, encodeAbiParameters, parseAbiParameters, maxUint256 } from 'viem';
import { ConnectButton } from '@rainbow-me/rainbowkit';
import { useRebaseToken } from '@/hooks/useRebaseToken';
import { useToast } from '@/contexts/ToastContext';
import { REBASE_TOKEN_ABI, REBASE_TOKEN_POOL_ADDRESS, CHAIN_SELECTORS } from '@/lib/contracts';
import { formatTokenAmount, getExplorerUrl } from '@/lib/utils';

const CHAINS = [
  { id: 11155111, name: 'Ethereum Sepolia', icon: '⟠', color: '#627EEA', selector: CHAIN_SELECTORS.sepolia },
  { id: 300, name: 'zkSync Sepolia', icon: '⚡', color: '#8C8DFC', selector: CHAIN_SELECTORS.zkSyncSepolia },
  { id: 421614, name: 'Arbitrum Sepolia', icon: '◈', color: '#28A0F0', selector: CHAIN_SELECTORS.arbitrumSepolia },
];

// CCIP Router address (Sepolia testnet)
const CCIP_ROUTER_SEPOLIA = '0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59' as `0x${string}`;
const LINK_TOKEN_SEPOLIA = '0x779877A7B0D9E8603169DdbD7836e478b4624789' as `0x${string}`;

const CCIP_ROUTER_ABI = [
  {
    name: 'ccipSend',
    type: 'function',
    stateMutability: 'payable',
    inputs: [
      { name: 'destinationChainSelector', type: 'uint64' },
      {
        name: 'message',
        type: 'tuple',
        components: [
          { name: 'receiver', type: 'bytes' },
          { name: 'data', type: 'bytes' },
          { name: 'tokenAmounts', type: 'tuple[]', components: [{ name: 'token', type: 'address' }, { name: 'amount', type: 'uint256' }] },
          { name: 'feeToken', type: 'address' },
          { name: 'extraArgs', type: 'bytes' },
        ],
      },
    ],
    outputs: [{ name: 'messageId', type: 'bytes32' }],
  },
  {
    name: 'getFee',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'destinationChainSelector', type: 'uint64' },
      {
        name: 'message',
        type: 'tuple',
        components: [
          { name: 'receiver', type: 'bytes' },
          { name: 'data', type: 'bytes' },
          { name: 'tokenAmounts', type: 'tuple[]', components: [{ name: 'token', type: 'address' }, { name: 'amount', type: 'uint256' }] },
          { name: 'feeToken', type: 'address' },
          { name: 'extraArgs', type: 'bytes' },
        ],
      },
    ],
    outputs: [{ name: 'fee', type: 'uint256' }],
  },
] as const;

export default function BridgePage() {
  const { address, chainId, isConnected } = useAccount();
  const { rebasingBalance, tokenAddress, isLoading: balanceLoading, refetch } = useRebaseToken();
  const { addToast } = useToast();

  const [destChain, setDestChain] = useState(CHAINS[1]);
  const [amount, setAmount] = useState('');
  const [step, setStep] = useState<'idle' | 'approving' | 'bridging' | 'done'>('idle');

  const { writeContract, data: txHash, isPending } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash: txHash });

  const rbtBal = rebasingBalance ? formatTokenAmount(rebasingBalance, 18, 6) : '0';
  const sourceChain = CHAINS.find((c) => c.id === chainId) ?? CHAINS[0];
  const availableDests = CHAINS.filter((c) => c.id !== chainId);

  const handleApprove = async () => {
    if (!amount || parseFloat(amount) <= 0 || !address) return;
    addToast({ type: 'pending', title: 'Approving RBT...', message: 'Allow the CCIP router to spend your tokens' });
    setStep('approving');
    writeContract({
      address: tokenAddress,
      abi: REBASE_TOKEN_ABI,
      functionName: 'approve',
      args: [CCIP_ROUTER_SEPOLIA, maxUint256],
    });
  };

  const handleBridge = async () => {
    if (!amount || parseFloat(amount) <= 0 || !address) return;
    addToast({ type: 'pending', title: 'Initiating bridge...', message: `Sending ${amount} RBT to ${destChain.name} via CCIP` });
    setStep('bridging');
    // Note: In production, call the CCIP router's ccipSend with proper params
    // For demo purposes this shows the flow
    addToast({ type: 'info', title: 'Bridge Demo', message: 'Connect your actual CCIP router to enable live bridging.' });
    setStep('idle');
  };

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
        <div style={{ fontSize: '4rem' }}>🌉</div>
        <h2 style={{ fontSize: '1.8rem', fontWeight: 700, color: '#e2e8f0', textAlign: 'center' }}>
          Connect to Bridge
        </h2>
        <ConnectButton />
      </div>
    );
  }

  return (
    <div style={{ maxWidth: '900px', margin: '0 auto', padding: '40px 24px' }}>
      <h1 style={{ fontSize: '2rem', fontWeight: 800, color: '#e2e8f0', letterSpacing: '-0.03em', marginBottom: '8px' }}>
        Cross-Chain Bridge
      </h1>
      <p style={{ color: '#94a3b8', marginBottom: '40px' }}>
        Bridge RBT tokens across chains via Chainlink CCIP. Your interest rate travels with you.
      </p>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 340px', gap: '24px', alignItems: 'start' }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: '20px' }}>
          {/* Chain selector */}
          <div className="glass-card" style={{ padding: '28px' }}>
            <h3 style={{ color: '#e2e8f0', fontWeight: 700, marginBottom: '20px' }}>Route</h3>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 40px 1fr', alignItems: 'center', gap: '12px' }}>
              {/* Source */}
              <div style={{
                padding: '16px',
                borderRadius: '12px',
                background: 'rgba(4,13,26,0.8)',
                border: `1px solid ${sourceChain.color}30`,
              }}>
                <div style={{ color: '#64748b', fontSize: '0.75rem', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: '8px' }}>Source</div>
                <div style={{ display: 'flex', alignItems: 'center', gap: '10px' }}>
                  <span style={{ fontSize: '1.5rem' }}>{sourceChain.icon}</span>
                  <div>
                    <div style={{ color: '#e2e8f0', fontWeight: 600, fontSize: '0.9rem' }}>{sourceChain.name}</div>
                    <span className="badge-success" style={{ fontSize: '0.7rem' }}>Connected</span>
                  </div>
                </div>
              </div>

              {/* Arrow */}
              <div style={{ textAlign: 'center', fontSize: '1.5rem', color: '#38bdf8' }}>→</div>

              {/* Destination selector */}
              <div style={{ display: 'flex', flexDirection: 'column', gap: '8px' }}>
                <div style={{ color: '#64748b', fontSize: '0.75rem', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: '4px' }}>
                  Destination
                </div>
                {availableDests.map((chain) => (
                  <button
                    key={chain.id}
                    onClick={() => setDestChain(chain)}
                    style={{
                      padding: '12px 16px',
                      borderRadius: '10px',
                      border: `1px solid ${destChain.id === chain.id ? chain.color + '60' : 'rgba(56,139,253,0.15)'}`,
                      background: destChain.id === chain.id ? `${chain.color}10` : 'rgba(4,13,26,0.6)',
                      cursor: 'pointer',
                      display: 'flex',
                      alignItems: 'center',
                      gap: '10px',
                      transition: 'all 0.2s',
                    }}
                  >
                    <span style={{ fontSize: '1.2rem' }}>{chain.icon}</span>
                    <span style={{ color: destChain.id === chain.id ? chain.color : '#94a3b8', fontWeight: 600, fontSize: '0.85rem' }}>
                      {chain.name}
                    </span>
                  </button>
                ))}
              </div>
            </div>
          </div>

          {/* Amount */}
          <div className="glass-card" style={{ padding: '28px' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '8px' }}>
              <span style={{ color: '#64748b', fontSize: '0.85rem' }}>Amount to Bridge</span>
              <button
                onClick={() => setAmount(rbtBal)}
                style={{ background: 'none', border: 'none', color: '#38bdf8', cursor: 'pointer', fontSize: '0.82rem', fontWeight: 600 }}
              >
                Max: {rbtBal} RBT
              </button>
            </div>
            <div style={{ position: 'relative' }}>
              <input
                type="number"
                className="input-field"
                placeholder="0.0"
                value={amount}
                onChange={(e) => setAmount(e.target.value)}
                style={{ fontSize: '1.4rem', padding: '18px 80px 18px 16px' }}
              />
              <span style={{
                position: 'absolute', right: '16px', top: '50%', transform: 'translateY(-50%)',
                color: '#38bdf8', fontWeight: 700,
              }}>
                RBT
              </span>
            </div>
          </div>

          {/* Steps */}
          <div className="glass-card" style={{ padding: '28px' }}>
            <h3 style={{ color: '#e2e8f0', fontWeight: 700, marginBottom: '20px' }}>Bridge Steps</h3>
            {[
              { num: 1, label: 'Approve RBT for CCIP router', done: step !== 'idle' },
              { num: 2, label: 'Send CCIP cross-chain message', done: step === 'done' },
              { num: 3, label: 'Destination chain mints RBT', done: false },
            ].map(({ num, label, done }) => (
              <div key={num} style={{
                display: 'flex',
                alignItems: 'center',
                gap: '12px',
                marginBottom: '14px',
              }}>
                <div style={{
                  width: '28px',
                  height: '28px',
                  borderRadius: '50%',
                  background: done ? 'rgba(52,211,153,0.2)' : 'rgba(56,139,253,0.1)',
                  border: `1px solid ${done ? 'rgba(52,211,153,0.5)' : 'rgba(56,139,253,0.2)'}`,
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  color: done ? '#34d399' : '#64748b',
                  fontSize: '0.8rem',
                  fontWeight: 700,
                  flexShrink: 0,
                }}>
                  {done ? '✓' : num}
                </div>
                <span style={{ color: done ? '#34d399' : '#94a3b8', fontSize: '0.875rem' }}>{label}</span>
              </div>
            ))}
          </div>

          {/* Buttons */}
          <div style={{ display: 'flex', gap: '12px' }}>
            <button
              className="btn-secondary"
              onClick={handleApprove}
              disabled={!amount || parseFloat(amount) <= 0 || isPending || isConfirming || step !== 'idle'}
              style={{ flex: 1, padding: '14px' }}
            >
              1. Approve
            </button>
            <button
              className="btn-primary"
              onClick={handleBridge}
              disabled={!amount || parseFloat(amount) <= 0 || step === 'idle' || isPending}
              style={{ flex: 2, padding: '14px' }}
            >
              <span>2. Bridge via CCIP →</span>
            </button>
          </div>
        </div>

        {/* Side info */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: '16px' }}>
          <div className="glass-card" style={{ padding: '24px' }}>
            <h3 style={{ color: '#e2e8f0', fontWeight: 700, marginBottom: '16px', fontSize: '0.95rem' }}>
              What Travels Cross-Chain
            </h3>
            {[
              { icon: '🪙', label: 'Token amount', desc: 'Your RBT quantity' },
              { icon: '📊', label: 'Interest rate', desc: 'Your personal APY' },
              { icon: '⏱️', label: 'User state', desc: 'Rate locked at deposit' },
            ].map(({ icon, label, desc }) => (
              <div key={label} style={{ display: 'flex', gap: '12px', marginBottom: '14px', alignItems: 'flex-start' }}>
                <span style={{ fontSize: '1.2rem', flexShrink: 0 }}>{icon}</span>
                <div>
                  <div style={{ color: '#e2e8f0', fontWeight: 600, fontSize: '0.85rem' }}>{label}</div>
                  <div style={{ color: '#94a3b8', fontSize: '0.78rem' }}>{desc}</div>
                </div>
              </div>
            ))}
          </div>

          <div className="glass-card" style={{ padding: '24px' }}>
            <h3 style={{ color: '#e2e8f0', fontWeight: 700, marginBottom: '12px', fontSize: '0.95rem' }}>
              Fee Token
            </h3>
            <p style={{ color: '#94a3b8', fontSize: '0.82rem', lineHeight: 1.6, marginBottom: '12px' }}>
              CCIP fees are paid in native ETH or LINK token. Ensure you have sufficient LINK on Sepolia.
            </p>
            <div style={{ fontSize: '0.8rem', color: '#64748b' }}>
              LINK: <code style={{ color: '#38bdf8' }}>{LINK_TOKEN_SEPOLIA.slice(0, 10)}...</code>
            </div>
          </div>

          <div className="glass-card" style={{ padding: '20px', background: 'rgba(56,189,248,0.03)', borderColor: 'rgba(56,189,248,0.15)' }}>
            <div style={{ color: '#38bdf8', fontWeight: 700, fontSize: '0.85rem', marginBottom: '8px' }}>
              🔗 Powered by Chainlink CCIP
            </div>
            <p style={{ color: '#94a3b8', fontSize: '0.8rem', lineHeight: 1.5 }}>
              Cross-Chain Interoperability Protocol provides secure and reliable cross-chain messaging.
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}
