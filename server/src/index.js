/**
 * Remote Desktop Server — Entry Point
 *
 * Express HTTP for auth endpoints + WebSocket for signaling
 */

import express from 'express';
import { createServer } from 'http';
import jwt from 'jsonwebtoken';
import { config } from './utils/config.js';
import { logger } from './utils/logger.js';
import { mediasoupHandler } from './mediasoup-handler.js';
import { setupSignalServer } from './signal-server.js';

async function main() {
  // Initialize mediasoup worker
  await mediasoupHandler.init();
  logger.info('Mediasoup worker initialized');

  // Express app
  const app = express();
  app.use(express.json());

  // Health check
  app.get('/health', (_req, res) => {
    res.json({ status: 'ok', uptime: process.uptime() });
  });

  // Auth endpoint — clients call this to get a room-scoped JWT
  app.post('/api/auth/join', (req, res) => {
    const { userId, roomId, role } = req.body;

    if (!userId || !roomId || !role) {
      return res.status(400).json({ error: 'Missing userId, roomId, or role' });
    }

    if (!['controller', 'viewer'].includes(role)) {
      return res.status(400).json({ error: 'Invalid role' });
    }

    const expiresIn = role === 'controller' ? 3600 : 900; // 1h / 15min
    const token = jwt.sign(
      { userId, roomId, role },
      config.jwtSecret,
      { expiresIn }
    );

    logger.info({ userId, roomId, role }, 'Token generated');
    res.json({ token });
  });

  // Get router capabilities (for new peers joining)
  app.get('/api/rooms/:roomId/info', async (req, res) => {
    const { roomId } = req.params;
    try {
      const router = await mediasoupHandler.getOrCreateRouter(roomId);
      res.json({
        routerRtpCapabilities: router.rtpCapabilities,
      });
    } catch (err) {
      res.status(500).json({ error: err.message });
    }
  });

  // Create server
  const httpServer = createServer(app);

  // Setup WebSocket signal server
  setupSignalServer(httpServer);

  // Start listening
  httpServer.listen(config.port, () => {
    logger.info({ port: config.port }, 'Server started');
  });
}

main().catch((err) => {
  logger.error({ err }, 'Failed to start server');
  process.exit(1);
});
