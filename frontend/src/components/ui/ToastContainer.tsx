'use client';

import { useToast } from '@/contexts/ToastContext';
import { getExplorerUrl } from '@/lib/utils';
import { useEffect } from 'react';

const icons: Record<string, string> = {
  success: '✓',
  error: '✕',
  pending: '⟳',
  info: 'ℹ',
};

const colors: Record<string, string> = {
  success: '#34d399',
  error: '#f87171',
  pending: '#fbbf24',
  info: '#38bdf8',
};

export function ToastContainer() {
  const { toasts, removeToast } = useToast();

  return (
    <div style={{
      position: 'fixed',
      bottom: '24px',
      right: '24px',
      zIndex: 9999,
      display: 'flex',
      flexDirection: 'column',
      gap: '12px',
      maxWidth: '380px',
    }}>
      {toasts.map((toast) => (
        <div
          key={toast.id}
          style={{
            background: 'rgba(8, 26, 58, 0.95)',
            border: `1px solid ${colors[toast.type]}30`,
            borderLeft: `3px solid ${colors[toast.type]}`,
            borderRadius: '12px',
            padding: '14px 16px',
            backdropFilter: 'blur(20px)',
            boxShadow: `0 8px 32px rgba(0,0,0,0.4), 0 0 0 1px rgba(255,255,255,0.04)`,
            animation: 'slideIn 0.3s ease',
            display: 'flex',
            gap: '12px',
            alignItems: 'flex-start',
          }}
        >
          <div style={{
            width: '28px',
            height: '28px',
            borderRadius: '50%',
            background: `${colors[toast.type]}18`,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            color: colors[toast.type],
            fontSize: '14px',
            fontWeight: 'bold',
            flexShrink: 0,
            animation: toast.type === 'pending' ? 'spin 1s linear infinite' : undefined,
          }}>
            {icons[toast.type]}
          </div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ color: '#e2e8f0', fontWeight: 600, fontSize: '0.875rem', marginBottom: '2px' }}>
              {toast.title}
            </div>
            {toast.message && (
              <div style={{ color: '#94a3b8', fontSize: '0.8rem', lineHeight: 1.4 }}>
                {toast.message}
              </div>
            )}
            {toast.txHash && toast.chainId && (
              <a
                href={getExplorerUrl(toast.chainId, toast.txHash)}
                target="_blank"
                rel="noopener noreferrer"
                style={{
                  color: '#38bdf8',
                  fontSize: '0.78rem',
                  textDecoration: 'none',
                  display: 'inline-block',
                  marginTop: '4px',
                }}
              >
                View on Explorer ↗
              </a>
            )}
          </div>
          <button
            onClick={() => removeToast(toast.id)}
            style={{
              background: 'none',
              border: 'none',
              color: '#475569',
              cursor: 'pointer',
              fontSize: '16px',
              padding: '2px',
              lineHeight: 1,
              flexShrink: 0,
            }}
          >
            ×
          </button>
        </div>
      ))}
      <style>{`
        @keyframes slideIn {
          from { transform: translateX(100%); opacity: 0; }
          to { transform: translateX(0); opacity: 1; }
        }
        @keyframes spin {
          from { transform: rotate(0deg); }
          to { transform: rotate(360deg); }
        }
      `}</style>
    </div>
  );
}
