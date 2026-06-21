import express, { Request, Response } from 'express';
import { WebSocketServer, WebSocket } from 'ws';
import { MarketTick, MarketStrength, MARKET_WS_PORT } from '@luafighter/shared-types';
import { MockDataGenerator } from './mock-generator';
import { StrengthCalculator } from './strength-calculator';
import { MockDataSource } from './data-source';

/**
 * 行情数据服务主入口
 * 提供 HTTP REST API + WebSocket 实时推送
 */

const app = express();
app.use(express.json());

// 核心组件
const generator = new MockDataGenerator();
const calculator = new StrengthCalculator(10); // 10秒滑动窗口
const mockSource = new MockDataSource();

// 客户端管理
interface ClientInfo {
  ws: WebSocket;
  subscribedSymbols: Set<string>;
}
const clients: Map<WebSocket, ClientInfo> = new Map();

// ============ HTTP API ============

// 健康检查
app.get('/api/health', (_req: Request, res: Response) => {
  res.json({
    status: 'ok',
    service: 'market-data',
    uptime: process.uptime(),
    activeSymbols: generator.getSymbols(),
    clientCount: clients.size,
  });
});

// 获取支持的代码列表
app.get('/api/symbols', (_req: Request, res: Response) => {
  res.json({
    symbols: generator.getSymbols().map((s) => ({
      symbol: s,
      name: getSymbolName(s),
    })),
  });
});

// 订阅行情
app.post('/api/subscribe', (req: Request, res: Response) => {
  const { symbols, scenario } = req.body;
  if (!symbols || !Array.isArray(symbols)) {
    res.status(400).json({ error: 'symbols 必须为数组' });
    return;
  }

  for (const sym of symbols) {
    if (!generator.getSymbols().includes(sym)) {
      // 动态注册新 symbol
      generator.register({
        symbol: sym,
        scenario: scenario || 'ranging',
        intervalMs: 500,
        drift: 0.02,
        volatility: 0.1,
      });
    }
    if (scenario) {
      generator.setScenario(sym, scenario);
    }
    generator.start(sym);
  }

  res.json({ success: true, started: symbols });
});

// 停止行情
app.post('/api/stop', (req: Request, res: Response) => {
  const { symbols } = req.body;
  if (symbols && Array.isArray(symbols)) {
    for (const sym of symbols) {
      generator.stop(sym);
    }
  } else {
    generator.stop();
  }
  res.json({ success: true });
});

// 获取当前强度
app.get('/api/strength/:symbol', (req: Request, res: Response) => {
  const symbol = req.params.symbol;
  // 从最新 tick 计算（简化处理，实际应缓存最新值）
  res.json({ symbol, note: '请通过 WebSocket 获取实时数据' });
});

function getSymbolName(symbol: string): string {
  const map: Record<string, string> = {
    'IF2306': '沪深300期货2306',
    'IC2306': '中证500期货2306',
    '000001.SZ': '平安银行',
  };
  return map[symbol] || symbol;
}

// ============ WebSocket 服务 ============

const wss = new WebSocketServer({ port: MARKET_WS_PORT });

wss.on('connection', (ws: WebSocket) => {
  console.log(`[MarketWS] 新客户端连接，当前总数: ${wss.clients.size}`);

  const clientInfo: ClientInfo = { ws, subscribedSymbols: new Set() };
  clients.set(ws, clientInfo);

  ws.on('message', (data: Buffer) => {
    try {
      const msg = JSON.parse(data.toString());
      handleClientMessage(ws, msg);
    } catch (err) {
      console.error('[MarketWS] 消息解析失败:', err);
      ws.send(JSON.stringify({ error: 'Invalid JSON' }));
    }
  });

  ws.on('close', () => {
    clients.delete(ws);
    console.log(`[MarketWS] 客户端断开，剩余: ${clients.size}`);
  });

  ws.on('error', (err) => {
    console.error('[MarketWS] 客户端错误:', err);
    clients.delete(ws);
  });

  // 发送欢迎消息
  ws.send(JSON.stringify({
    type: 'connected',
    service: 'luafighter-market-data',
    symbols: generator.getSymbols(),
  }));
});

function handleClientMessage(ws: WebSocket, msg: any): void {
  const client = clients.get(ws);
  if (!client) return;

  switch (msg.type) {
    case 'subscribe': {
      const symbols = msg.symbols || [];
      for (const sym of symbols) {
        client.subscribedSymbols.add(sym);
      }
      ws.send(JSON.stringify({ type: 'subscribed', symbols: Array.from(client.subscribedSymbols) }));
      // 自动启动生成器
      for (const sym of symbols) {
        generator.start(sym);
      }
      break;
    }
    case 'unsubscribe': {
      const symbols = msg.symbols || [];
      for (const sym of symbols) {
        client.subscribedSymbols.delete(sym);
      }
      ws.send(JSON.stringify({ type: 'unsubscribed', symbols: Array.from(client.subscribedSymbols) }));
      break;
    }
    default:
      ws.send(JSON.stringify({ type: 'error', message: 'Unknown message type' }));
  }
}

// ============ 数据流 ============

// 生成器 -> 计算器 -> 广播
generator.subscribe((tick: MarketTick) => {
  const result = calculator.calculate(tick);

  // 广播给订阅了该 symbol 的客户端
  const payload = JSON.stringify({
    type: 'tick',
    data: {
      tick,
      strength: result.strength,
    },
  });

  for (const [ws, client] of clients) {
    if (client.subscribedSymbols.has(tick.symbol) || client.subscribedSymbols.has('*')) {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(payload);
      }
    }
  }
});

// ============ 启动 ============

const HTTP_PORT = 9001; // HTTP 和 WS 共用端口，WS 在上面单独创建
// 实际上这里 WS 用了 9001，HTTP 用 9001+1 = 9002
// 修正：让 HTTP 也监听 9001，但 Express 和 WebSocketServer 需要共享 server
// 这里简化处理：WS 用 9001，HTTP 用 9002

const httpPort = 9002;
app.listen(httpPort, () => {
  console.log(`[MarketData] HTTP API 启动于 http://localhost:${httpPort}`);
  console.log(`[MarketData] WebSocket 启动于 ws://localhost:${MARKET_WS_PORT}`);
  console.log(`[MarketData] 可用接口: GET /api/health, /api/symbols, POST /api/subscribe`);
});

// 默认启动所有 symbol
// generator.start(); // 不自动启动，等客户端订阅
