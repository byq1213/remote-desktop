/**
 * Remote Desktop Server — Entry Point
 *
 * Responsibilities:
 *   - Express HTTP for the auth endpoint (/api/auth/join)
 *   - WebSocket for signaling relay (delegated to signal-server.js)
 *
 * Media is P2P WebRTC — this server only relays SDP/ICE and control messages.
 * There is deliberately no SFU; a remote-control session is 1 controller →
 * 1 viewer, so relaying signaling is all the server needs to do.
 */

import express from 'express';
import { createServer } from 'http';
import { config } from './utils/config.js';
import { logger } from './utils/logger.js';
import { setupSignalServer } from './signal-server.js';
import { generateToken } from './auth.js';

async function main() {
  const app = express();
  app.use(express.json());

  // Health check
  app.get('/health', (_req, res) => {
    res.json({ status: 'ok', uptime: process.uptime() });
  });

  // Auth endpoint — clients call this to get a room-scoped JWT.
  app.post('/api/auth/join', (req, res) => {
    const { userId, roomId, role } = req.body ?? {};

    if (!userId || !roomId || !role) {
      return res.status(400).json({ error: 'Missing userId, roomId, or role' });
    }
    if (!['controller', 'viewer'].includes(role)) {
      return res.status(400).json({ error: 'Invalid role' });
    }

    // Controllers hold a longer-lived token (they tend to stay connected);
    // viewers get a shorter one since they join for a single session.
    const expiresIn = role === 'controller' ? 3600 : 900;
    const token = generateToken({ userId, roomId, role, expiresIn });

    logger.info({ userId, roomId, role }, 'Token generated');
    res.json({ token });
  });

  // WebSocket signal server (attached to the same HTTP server).
  const httpServer = createServer(app);
  setupSignalServer(httpServer);

  httpServer.listen(config.port, () => {
    logger.info({ port: config.port }, 'Server started');
  });
}

main().catch((err) => {
  logger.error({ err }, 'Failed to start server');
  process.exit(1);
});
