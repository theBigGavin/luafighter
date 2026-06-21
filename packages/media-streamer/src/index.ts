import { StreamManager } from './stream-manager';
import express, { Request, Response } from 'express';
import { MEDIA_HTTP_PORT } from '@luafighter/shared-types';

/**
 * 媒体推流服务 HTTP API
 * 管理流生命周期和提供播放地址
 */

const app = express();
app.use(express.json());

const streamManager = new StreamManager();

// 健康检查
app.get('/api/health', (_req: Request, res: Response) => {
  res.json({ status: 'ok', service: 'media-streamer' });
});

// 启动房间推流
app.post('/api/streams/:roomId/start', async (req: Request, res: Response) => {
  const { roomId } = req.params;
  const { display } = req.body;
  
  try {
    const rtmpUrl = await streamManager.startStream(roomId, display || ':99');
    res.json({
      success: true,
      roomId,
      rtmpUrl,
      webrtcUrl: streamManager.getWebRTCUrl(roomId),
    });
  } catch (err) {
    res.status(500).json({ error: '启动推流失败', detail: (err as Error).message });
  }
});

// 停止房间推流
app.post('/api/streams/:roomId/stop', async (req: Request, res: Response) => {
  const { roomId } = req.params;
  await streamManager.stopStream(roomId);
  res.json({ success: true, roomId });
});

// 获取流信息
app.get('/api/streams/:roomId', (req: Request, res: Response) => {
  const { roomId } = req.params;
  res.json(streamManager.getStreamInfo(roomId));
});

app.listen(MEDIA_HTTP_PORT, () => {
  console.log(`[MediaStreamer] HTTP API 启动于 http://localhost:${MEDIA_HTTP_PORT}`);
});
