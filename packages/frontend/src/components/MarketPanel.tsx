interface MarketPanelProps {
  strength: number;
  bidAmount: number;
  askAmount: number;
  bidVolume?: number;
  askVolume?: number;
  lastPrice?: number;
  priceChange?: number;
  symbol: string;
}

/**
 * 多空仪表盘面板
 * 显示最新价、多空成交额/成交量对比、多空强度
 */

export default function MarketPanel({
  strength,
  bidAmount,
  askAmount,
  bidVolume = 0,
  askVolume = 0,
  lastPrice,
  priceChange = 0,
  symbol,
}: MarketPanelProps) {
  const amountTotal = bidAmount + askAmount;
  const bullAmountPercent = amountTotal > 0 ? (bidAmount / amountTotal) * 100 : 50;
  const bearAmountPercent = amountTotal > 0 ? (askAmount / amountTotal) * 100 : 50;

  const volTotal = bidVolume + askVolume;
  const bullVolPercent = volTotal > 0 ? (bidVolume / volTotal) * 100 : 50;
  const bearVolPercent = volTotal > 0 ? (askVolume / volTotal) * 100 : 50;

  const isBull = strength > 0.1;
  const isBear = strength < -0.1;
  const valueClass = isBull ? 'bull' : isBear ? 'bear' : 'neutral';
  const valueText = strength > 0 ? `+${strength.toFixed(3)}` : strength.toFixed(3);

  const formatAmount = (amount: number) => {
    if (amount >= 100000000) return `${(amount / 100000000).toFixed(2)}亿`;
    if (amount >= 10000) return `${(amount / 10000).toFixed(2)}万`;
    return amount.toString();
  };

  const formatVolume = (vol: number) => {
    if (vol >= 10000) return `${(vol / 10000).toFixed(2)}万`;
    return vol.toString();
  };

  // 中文习惯：多方=红，空方=绿
  const BULL_COLOR = '#ef4444';
  const BEAR_COLOR = '#22c55e';

  return (
    <div className="panel market-panel">
      <div className="market-header">
        <div>
          <h3 className="panel-title" style={{ margin: '0 0 4px 0' }}>{symbol}</h3>
          <div className="market-subtitle">多空强度: <span className={valueClass}>{valueText}</span></div>
        </div>
        {lastPrice !== undefined && (
          <div className="price-block">
            <div className={`price-value ${priceChange >= 0 ? 'bull' : 'bear'}`}>
              {lastPrice.toFixed(2)}
            </div>
            <div className={`price-change ${priceChange >= 0 ? 'bull' : 'bear'}`}>
              {priceChange >= 0 ? '+' : ''}{priceChange.toFixed(2)}
            </div>
          </div>
        )}
      </div>

      <div className="market-section">
        <div className="market-labels">
          <span style={{ color: BULL_COLOR }}>▲ 多方金额 {formatAmount(bidAmount)}</span>
          <span style={{ color: BEAR_COLOR }}>▼ 空方金额 {formatAmount(askAmount)}</span>
        </div>
        <div className="market-bar">
          <div style={{ width: `${bullAmountPercent}%`, background: BULL_COLOR }} />
          <div style={{ width: `${bearAmountPercent}%`, background: BEAR_COLOR }} />
        </div>
      </div>

      <div className="market-section">
        <div className="market-labels">
          <span style={{ color: BULL_COLOR }}>▲ 多方量 {formatVolume(bidVolume)}</span>
          <span style={{ color: BEAR_COLOR }}>▼ 空方量 {formatVolume(askVolume)}</span>
        </div>
        <div className="market-bar">
          <div style={{ width: `${bullVolPercent}%`, background: BULL_COLOR }} />
          <div style={{ width: `${bearVolPercent}%`, background: BEAR_COLOR }} />
        </div>
      </div>
    </div>
  );
}
