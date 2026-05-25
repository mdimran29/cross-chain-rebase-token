'use client';

import { useRebaseToken } from '@/hooks/useRebaseToken';
import { formatTokenAmount, formatInterestRate } from '@/lib/utils';
import {
  AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, LineChart, Line, BarChart, Bar,
} from 'recharts';

// Mock data for charts (replace with real historical data via events)
function generateBalanceHistory() {
  const data = [];
  let balance = 100;
  for (let i = 30; i >= 0; i--) {
    const date = new Date();
    date.setDate(date.getDate() - i);
    balance *= 1 + (5e10 * 86400) / 1e18; // linear interest daily
    data.push({
      date: date.toLocaleDateString('en', { month: 'short', day: 'numeric' }),
      balance: parseFloat(balance.toFixed(6)),
    });
  }
  return data;
}

function generateSupplyHistory() {
  const data = [];
  let supply = 1000;
  for (let i = 30; i >= 0; i--) {
    const date = new Date();
    date.setDate(date.getDate() - i);
    supply += Math.random() * 50 - 10;
    data.push({
      date: date.toLocaleDateString('en', { month: 'short', day: 'numeric' }),
      supply: Math.max(supply, 0).toFixed(2),
    });
  }
  return data;
}

function generateBridgeVolume() {
  return Array.from({ length: 7 }, (_, i) => {
    const date = new Date();
    date.setDate(date.getDate() - (6 - i));
    return {
      date: date.toLocaleDateString('en', { weekday: 'short' }),
      sepolia: Math.random() * 200,
      zkSync: Math.random() * 100,
      arbitrum: Math.random() * 150,
    };
  });
}

const balanceData = generateBalanceHistory();
const supplyData = generateSupplyHistory();
const bridgeData = generateBridgeVolume();

const tooltipStyle = {
  backgroundColor: '#071428',
  border: '1px solid rgba(56,189,248,0.2)',
  borderRadius: '8px',
  color: '#e2e8f0',
  fontSize: '0.82rem',
};

export default function AnalyticsPage() {
  const { globalInterestRate, totalSupply, isLoading } = useRebaseToken();

  const annualRate = globalInterestRate ? formatInterestRate(globalInterestRate) : '—';
  const supply = totalSupply ? formatTokenAmount(totalSupply, 18, 2) : '—';

  return (
    <div style={{ maxWidth: '1200px', margin: '0 auto', padding: '40px 24px' }}>
      <h1 style={{ fontSize: '2rem', fontWeight: 800, color: '#e2e8f0', letterSpacing: '-0.03em', marginBottom: '8px' }}>
        Analytics
      </h1>
      <p style={{ color: '#94a3b8', marginBottom: '40px' }}>
        Protocol metrics and growth data. Charts use simulated historical data for demonstration.
      </p>

      {/* KPI cards */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))', gap: '16px', marginBottom: '40px' }}>
        {[
          { label: 'Total RBT Supply', value: `${supply} RBT`, color: '#38bdf8', icon: '🪙' },
          { label: 'Annual Interest Rate', value: `${annualRate}% APY`, color: '#34d399', icon: '📈' },
          { label: 'Supported Chains', value: '3 Chains', color: '#a78bfa', icon: '🌐' },
          { label: 'Bridge Protocol', value: 'Chainlink CCIP', color: '#fbbf24', icon: '🔗' },
        ].map(({ label, value, color, icon }) => (
          <div key={label} className="glass-card" style={{ padding: '20px' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '8px' }}>
              <span style={{ color: '#64748b', fontSize: '0.75rem', textTransform: 'uppercase', letterSpacing: '0.06em' }}>{label}</span>
              <span>{icon}</span>
            </div>
            {isLoading ? (
              <div className="skeleton" style={{ height: '28px', width: '70%' }} />
            ) : (
              <div style={{ color, fontWeight: 800, fontSize: '1.2rem', fontFamily: "'JetBrains Mono', monospace" }}>{value}</div>
            )}
          </div>
        ))}
      </div>

      {/* Balance growth chart */}
      <div className="glass-card" style={{ padding: '28px', marginBottom: '24px' }}>
        <div style={{ marginBottom: '20px' }}>
          <h3 style={{ color: '#e2e8f0', fontWeight: 700, fontSize: '1rem', marginBottom: '4px' }}>
            User Balance Growth
          </h3>
          <p style={{ color: '#64748b', fontSize: '0.82rem' }}>Simulated 100 RBT deposit growing at {annualRate}% APY (30 days)</p>
        </div>
        <ResponsiveContainer width="100%" height={220}>
          <AreaChart data={balanceData}>
            <defs>
              <linearGradient id="balGrad" x1="0" y1="0" x2="0" y2="1">
                <stop offset="5%" stopColor="#38bdf8" stopOpacity={0.15} />
                <stop offset="95%" stopColor="#38bdf8" stopOpacity={0} />
              </linearGradient>
            </defs>
            <CartesianGrid stroke="rgba(56,139,253,0.08)" vertical={false} />
            <XAxis dataKey="date" tick={{ fill: '#64748b', fontSize: 11 }} tickLine={false} axisLine={false} interval={6} />
            <YAxis tick={{ fill: '#64748b', fontSize: 11 }} tickLine={false} axisLine={false} width={70} />
            <Tooltip contentStyle={tooltipStyle} />
            <Area type="monotone" dataKey="balance" stroke="#38bdf8" strokeWidth={2} fill="url(#balGrad)" dot={false} />
          </AreaChart>
        </ResponsiveContainer>
      </div>

      {/* Supply and bridge charts */}
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '24px', marginBottom: '24px' }}>
        <div className="glass-card" style={{ padding: '28px' }}>
          <h3 style={{ color: '#e2e8f0', fontWeight: 700, fontSize: '1rem', marginBottom: '4px' }}>RBT Supply Over Time</h3>
          <p style={{ color: '#64748b', fontSize: '0.82rem', marginBottom: '16px' }}>Total token supply (simulated)</p>
          <ResponsiveContainer width="100%" height={180}>
            <LineChart data={supplyData}>
              <CartesianGrid stroke="rgba(56,139,253,0.08)" vertical={false} />
              <XAxis dataKey="date" tick={{ fill: '#64748b', fontSize: 10 }} tickLine={false} axisLine={false} interval={9} />
              <YAxis tick={{ fill: '#64748b', fontSize: 10 }} tickLine={false} axisLine={false} width={60} />
              <Tooltip contentStyle={tooltipStyle} />
              <Line type="monotone" dataKey="supply" stroke="#34d399" strokeWidth={2} dot={false} />
            </LineChart>
          </ResponsiveContainer>
        </div>

        <div className="glass-card" style={{ padding: '28px' }}>
          <h3 style={{ color: '#e2e8f0', fontWeight: 700, fontSize: '1rem', marginBottom: '4px' }}>Weekly Bridge Volume</h3>
          <p style={{ color: '#64748b', fontSize: '0.82rem', marginBottom: '16px' }}>RBT bridged per chain (simulated)</p>
          <ResponsiveContainer width="100%" height={180}>
            <BarChart data={bridgeData} barSize={10}>
              <CartesianGrid stroke="rgba(56,139,253,0.08)" vertical={false} />
              <XAxis dataKey="date" tick={{ fill: '#64748b', fontSize: 10 }} tickLine={false} axisLine={false} />
              <YAxis tick={{ fill: '#64748b', fontSize: 10 }} tickLine={false} axisLine={false} width={50} />
              <Tooltip contentStyle={tooltipStyle} />
              <Bar dataKey="sepolia" fill="#627EEA" radius={[4, 4, 0, 0]} />
              <Bar dataKey="zkSync" fill="#8C8DFC" radius={[4, 4, 0, 0]} />
              <Bar dataKey="arbitrum" fill="#28A0F0" radius={[4, 4, 0, 0]} />
            </BarChart>
          </ResponsiveContainer>
          <div style={{ display: 'flex', gap: '16px', marginTop: '8px', justifyContent: 'center' }}>
            {[['#627EEA', 'Sepolia'], ['#8C8DFC', 'zkSync'], ['#28A0F0', 'Arbitrum']].map(([color, label]) => (
              <div key={label} style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
                <div style={{ width: '10px', height: '10px', borderRadius: '2px', background: color }} />
                <span style={{ color: '#64748b', fontSize: '0.75rem' }}>{label}</span>
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* Interest rate info */}
      <div className="glass-card" style={{ padding: '28px' }}>
        <h3 style={{ color: '#e2e8f0', fontWeight: 700, fontSize: '1rem', marginBottom: '16px' }}>
          Interest Rate Model
        </h3>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: '16px' }}>
          {[
            { label: 'Current Global Rate', value: `${annualRate}% APY`, color: '#34d399' },
            { label: 'Rate Direction', value: 'Monotonically decreasing', color: '#fbbf24' },
            { label: 'Per-User Rate', value: 'Locked at deposit', color: '#a78bfa' },
            { label: 'Precision', value: '1e18 (18 decimals)', color: '#38bdf8' },
          ].map(({ label, value, color }) => (
            <div key={label}>
              <div style={{ color: '#64748b', fontSize: '0.75rem', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: '6px' }}>
                {label}
              </div>
              <div style={{ color, fontWeight: 700, fontSize: '0.95rem' }}>{value}</div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
