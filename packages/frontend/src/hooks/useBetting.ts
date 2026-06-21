import { useState, useCallback } from 'react';

export type BetSide = 'p1' | 'p2';

export interface BetRecord {
  id: string;
  side: BetSide;
  amount: number;
  odds: number;
  round: number;
  status: 'pending' | 'win' | 'lose' | 'refund';
  profit: number;
}

export interface BettingState {
  balance: number;
  records: BetRecord[];
}

interface RoundResult {
  winner: 1 | 2;
  round: number;
}

interface GameResult {
  winner: 1 | 2;
  p1Wins: number;
  p2Wins: number;
}

/**
 * 本地模拟投注状态管理
 * - 余额从 10000 开始
 * - 赔率根据多空强度动态计算：强势方赔率更低，弱势方赔率更高
 * - roundEnd / gameEnd 时结算当前 pending 投注
 */
export function useBetting(initialBalance = 10000) {
  const [balance, setBalance] = useState(initialBalance);
  const [records, setRecords] = useState<BetRecord[]>([]);

  /**
   * 根据多空强度计算赔率
   * strengthIndex: -1 ~ 1，正值表示多方（P1）优势
   */
  const calculateOdds = useCallback((strengthIndex: number, side: BetSide): number => {
    const s = Math.max(-1, Math.min(1, strengthIndex));
    if (side === 'p1') {
      // P1 优势时赔率降低，劣势时赔率升高
      return parseFloat((1.5 + 1.5 * (1 - s) / 2).toFixed(2));
    }
    // P2 优势时赔率降低，劣势时赔率升高
    return parseFloat((1.5 + 1.5 * (1 + s) / 2).toFixed(2));
  }, []);

  const placeBet = useCallback(
    (side: BetSide, amount: number, strengthIndex: number, round: number): boolean => {
      if (amount <= 0 || amount > balance) return false;

      const odds = calculateOdds(strengthIndex, side);
      const newRecord: BetRecord = {
        id: `${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
        side,
        amount,
        odds,
        round,
        status: 'pending',
        profit: 0,
      };

      setBalance((prev) => prev - amount);
      setRecords((prev) => [newRecord, ...prev]);
      return true;
    },
    [balance, calculateOdds]
  );

  const settleRound = useCallback((result: RoundResult) => {
    setRecords((prev) =>
      prev.map((bet) => {
        if (bet.status !== 'pending' || bet.round !== result.round) return bet;
        const won = (bet.side === 'p1' && result.winner === 1) || (bet.side === 'p2' && result.winner === 2);
        if (won) {
          const profit = Math.floor(bet.amount * bet.odds);
          setBalance((b) => b + profit);
          return { ...bet, status: 'win', profit: profit - bet.amount };
        }
        return { ...bet, status: 'lose', profit: -bet.amount };
      })
    );
  }, []);

  const settleGame = useCallback((result: GameResult) => {
    setRecords((prev) =>
      prev.map((bet) => {
        if (bet.status !== 'pending') return bet;
        const won = (bet.side === 'p1' && result.winner === 1) || (bet.side === 'p2' && result.winner === 2);
        if (won) {
          const profit = Math.floor(bet.amount * bet.odds);
          setBalance((b) => b + profit);
          return { ...bet, status: 'win', profit: profit - bet.amount };
        }
        return { ...bet, status: 'lose', profit: -bet.amount };
      })
    );
  }, []);

  return {
    balance,
    records,
    placeBet,
    settleRound,
    settleGame,
    calculateOdds,
  };
}
