import express, { Request, Response } from 'express';
import { Server as SocketIOServer } from 'socket.io';
import { createServer } from 'http';
import { WebSocket } from 'ws';
import path from 'path';
import {
  RoomConfig,
  RoomStatus,
  GameState,
  MARKET_WS_PORT,
  MANAGER_HTTP_PORT,
  MANAGER_SOCKET_IO_PORT,
} from '@luafighter/shared-types';
import { GameRoom } from './game-room';
import { MamePool } from './mame-pool';
import { MarketDataClient } from './market-client';
import { LuaBridge } from './lua-bridge';

/**
 * 对局管理器主入口
 * 核心调度器：HTTP API + Socket.IO + WebSocket 行情连接
 */

const app = express();
app.use(express.json());

const httpServer = createServer(app);
const io = new SocketIOServer(httpServer, {
  cors: { origin: '*' },
  path: '/socket.io',
});

// ============ 核心组件 ============

const rooms: Map<string, GameRoom> = new Map();
const marketClients: Map<string, MarketDataClient> = new Map();
const roomConfigs: Map<string, RoomConfig> = new Map();

const mamePool = new MamePool({
  poolSize: 8,
  romsDir: process.env.ROMS_DIR || './roms',
  luaScriptPath: process.env.LUA_SCRIPT_PATH || 'lua-scripts/drivers/automation.lua',
  displayBase: 99,
});

// ============ HTTP API ============

// 健康检查
app.get('/api/health', (_req: Request, res: Response) => {
  res.json({
    status: 'ok',
    service: 'match-manager',
    uptime: process.uptime(),
    activeRooms: rooms.size,
    mameInstances: mamePool.getHealthyCount(),
  });
});

// 获取房间列表
app.get('/api/rooms', (_req: Request, res: Response) => {
  const list = Array.from(rooms.values()).map((room) => room.getStatus());
  res.json({ rooms: list });
});

// 停止并清理一个房间
async function stopRoom(id: string): Promise<void> {
  const marketClient = marketClients.get(id);
  if (marketClient) {
    marketClient.disconnect();
    marketClients.delete(id);
  }

  const room = rooms.get(id);
  if (room) {
    await room.stop();
    rooms.delete(id);
  }

  await mamePool.destroyInstance(id);
  roomConfigs.delete(id);
}

// 根据配置启动一个房间
async function createRoomFromConfig(config: RoomConfig): Promise<{ success: boolean; roomId: string; config: RoomConfig }> {
  const id = config.roomId;

  // 1. 启动 MAME 实例，获取实际分配的 display 和端口
  const { manager: mameInstance, display } = await mamePool.createInstance(id, config.rom);
  config.display = display;
  config.streamId = `stream_${id}`;

  // 2. 创建并启动房间
  const room = new GameRoom(config, mamePool, mameInstance);
  rooms.set(id, room);
  roomConfigs.set(id, config);
  await room.start();

  // 3. 连接行情数据
  const marketHost = process.env.MARKET_WS_HOST || 'localhost';
  const marketClient = new MarketDataClient(
    `ws://${marketHost}:${MARKET_WS_PORT}`,
    [config.symbol],
    {
      onTick: (strength) => {
        room.onMarketData(strength);
      },
      onConnect: () => {
        console.log(`[Manager] 房间 ${id} 已连接行情服务`);
      },
      onDisconnect: () => {
        console.log(`[Manager] 房间 ${id} 行情连接断开`);
      },
      onError: (err) => {
        console.error(`[Manager] 房间 ${id} 行情错误:`, err.message);
      },
    }
  );
  marketClient.connect();
  marketClients.set(id, marketClient);

  // 4. 事件转发到前端
  room.on('ready', () => {
    io.to(id).emit('ready', { roomId: id, rom: config.rom });
  });
  room.on('stateUpdate', (gameState: GameState) => {
    io.to(id).emit('gameState', gameState);
  });
  room.on('roundEnd', (data) => {
    io.to(id).emit('roundEnd', data);
  });
  room.on('gameEnd', (data) => {
    io.to(id).emit('gameEnd', data);
  });
  room.on('phaseChange', (phase) => {
    io.to(id).emit('phaseChange', phase);
  });
  room.on('error', (err) => {
    io.to(id).emit('error', { message: typeof err === 'string' ? err : err.message || '未知错误' });
  });
  room.on('stopped', () => {
    io.to(id).emit('stopped', { roomId: id });
  });

  console.log(`[Manager] 房间 ${id} 创建成功`);
  return { success: true, roomId: id, config };
}

// 创建房间
app.post('/api/rooms', async (req: Request, res: Response) => {
  const { rom, symbol, roomId } = req.body;

  if (!rom || !symbol) {
    res.status(400).json({ error: 'rom 和 symbol 为必填项' });
    return;
  }

  const id = roomId || `room_${Date.now()}`;

  if (rooms.has(id)) {
    res.status(409).json({ error: '房间 ID 已存在' });
    return;
  }

  try {
    const config: RoomConfig = {
      roomId: id,
      rom,
      symbol,
      display: '',
      streamId: `stream_${id}`,
    };
    const result = await createRoomFromConfig(config);
    res.json(result);
  } catch (err) {
    // 清理
    await stopRoom(id).catch(() => {});
    console.error(`[Manager] 创建房间失败:`, err);
    res.status(500).json({ error: '创建房间失败', detail: (err as Error).message });
  }
});

// 重置房间（先停止旧实例，再用相同配置重新创建）
app.post('/api/rooms/:roomId/reset', async (req: Request, res: Response) => {
  const id = req.params.roomId;
  const config = roomConfigs.get(id);

  if (!config) {
    res.status(404).json({ error: '房间不存在' });
    return;
  }

  try {
    if (rooms.has(id)) {
      await stopRoom(id);
      // 等待 MAME 端口释放，避免 display 冲突
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }
    const result = await createRoomFromConfig({ ...config });
    res.json(result);
  } catch (err) {
    await stopRoom(id).catch(() => {});
    console.error(`[Manager] 重置房间失败:`, err);
    res.status(500).json({ error: '重置房间失败', detail: (err as Error).message });
  }
});

// 获取单个房间状态
app.get('/api/rooms/:roomId', (req: Request, res: Response) => {
  const room = rooms.get(req.params.roomId);
  if (!room) {
    res.status(404).json({ error: '房间不存在' });
    return;
  }
  res.json(room.getStatus());
});

// 停止房间
app.delete('/api/rooms/:roomId', async (req: Request, res: Response) => {
  const id = req.params.roomId;

  if (!rooms.has(id) && !roomConfigs.has(id)) {
    res.status(404).json({ error: '房间不存在' });
    return;
  }

  try {
    await stopRoom(id);
    console.log(`[Manager] 房间 ${id} 已销毁`);
    res.json({ success: true });
  } catch (err) {
    console.error(`[Manager] 停止房间失败:`, err);
    res.status(500).json({ error: '停止房间失败', detail: (err as Error).message });
  }
});

// 获取房间游戏状态
app.get('/api/rooms/:roomId/state', (req: Request, res: Response) => {
  const room = rooms.get(req.params.roomId);
  if (!room) {
    res.status(404).json({ error: '房间不存在' });
    return;
  }
  res.json(room.getGameState());
});

// ============ Socket.IO ============

io.on('connection', (socket) => {
  console.log(`[SocketIO] 客户端连接: ${socket.id}`);

  socket.on('join', (roomId: string) => {
    const room = rooms.get(roomId);
    if (!room) {
      socket.emit('error', { message: '房间不存在' });
      return;
    }
    socket.join(roomId);
    socket.emit('joined', { roomId, state: room.getGameState() });
    console.log(`[SocketIO] ${socket.id} 加入房间 ${roomId}`);
  });

  socket.on('leave', (roomId: string) => {
    socket.leave(roomId);
    socket.emit('left', { roomId });
  });

  socket.on('disconnect', () => {
    console.log(`[SocketIO] 客户端断开: ${socket.id}`);
  });
});

// ============ 启动 ============

httpServer.listen(MANAGER_HTTP_PORT, () => {
  console.log(`[MatchManager] HTTP API 启动于 http://localhost:${MANAGER_HTTP_PORT}`);
  console.log(`[MatchManager] Socket.IO 启动于 ws://localhost:${MANAGER_HTTP_PORT}`);
  console.log(`[MatchManager] 可用接口:`);
  console.log(`  POST /api/rooms      - 创建房间`);
  console.log(`  GET  /api/rooms      - 获取房间列表`);
  console.log(`  GET  /api/rooms/:id  - 获取房间状态`);
  console.log(`  GET  /api/rooms/:id/state - 获取游戏状态`);
  console.log(`  POST /api/rooms/:id/reset - 重置房间`);
  console.log(`  DELETE /api/rooms/:id - 停止房间`);
});

// 定期检查 MAME 进程健康状态，发现异常则标记房间为崩溃
setInterval(() => {
  for (const [id, room] of rooms) {
    const instance = mamePool.getInstance(id);
    const stillAlive = instance ? instance.getHealth() : false;
    if (!stillAlive) {
      room.markCrashed();
    }
  }
}, 5000);

// 优雅关闭
process.on('SIGTERM', async () => {
  console.log('[MatchManager] 收到 SIGTERM，开始关闭...');
  for (const [id, room] of rooms) {
    const marketClient = marketClients.get(id);
    if (marketClient) marketClient.disconnect();
    await room.stop();
  }
  httpServer.close(() => {
    console.log('[MatchManager] 已关闭');
    process.exit(0);
  });
});
