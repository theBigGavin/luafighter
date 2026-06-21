
interface MarketPanelProps {
  strength: number;
  bidAmount: number;
  askAmount: number;
  symbol: string;
}

/**
 * 多空仪表盘面板
 * 显示实时多空强度、成交额对比
 */

export default function MarketPanel({ strength, bidAmount, askAmount, symbol }: MarketPanelProps) {
  const diff = bidAmount - askAmount;
  const total = bidAmount + askAmount;
  const bullPercent = total > 0 ? (bidAmount / total) * 100 : 50;
  const bearPercent = total > 0 ? (askAmount / total) * 100 : 50;

  const isBull = strength > 0.1;
  const isBear = strength < -0.1;
  const valueClass = isBull ? 'bull' : isBear ? 'bear' : 'neutral';
  const valueText = strength > 0 ? `+${strength.toFixed(3)}` : strength.toFixed(3);

  const formatAmount = (amount: number) => {
    if (amount >= 100000000) return `${(amount / 100000000).toFixed(2)}亿`;
    if (amount >= 10000) return `${(amount / 10000).toFixed(2)}万`;
    return amount.toString();
  };

  return (
    <div className="panel">
      <h3 className="panel-title">多空强度 {symbol}</h3>

      <div className="strength-gauge">
        <div className="gauge-value">
          <span className={valueClass}>{valueText}</span>
        </div>

        <div className="gauge-bar">
          {strength > 0 ? (
            <div
              className="gauge-fill bull"
              style={{ width: `${Math.abs(strength) * 50}%` }}
            />
          ) : (
            <div
              className="gauge-fill bear"
              style={{ width: `${Math.abs(strength) * 50}%` }}
            />
          )}
        </div>

        <div className="gauge-labels">
          <span style={{ color: '#ef4444' }}>空方</span>
          <span style={{ color: '#9ca3af' }}>0</span>
          <span style={{ color: '#22c55e' }}>多方</span>
        </div>
      </div>

      <div style={{ marginTop: 16 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13, marginBottom: 6 }}>
          <span style={{ color: '#22c55e' }}>
            ▲ 多方 {formatAmount(bidAmount)} ({bullPercent.toFixed(1)}%)
          </span>
          <span style={{ color: '#ef4444' }}>
            ▼ 空方 {formatAmount(askAmount)} ({bearPercent.toFixed(1)}%)
          </span>
        </div>
        <div style={{ display: 'flex', height: 6, borderRadius: 3, overflow: 'hidden' }}>
          <div style={{ width: `${bullPercent}%`, background: '#22c55e' }} />
          <div style={{ width: `${bearPercent}%`, background: '#ef4444' }} />
        </div>
      </div>

      <div style={{ marginTop: 12, fontSize: 12, color: '#6b7280' }}>
        差值: {diff > 0 ? '+' : ''}{formatAmount(diff)}
      </div>
    </div>
  );
}
