/**
 * WebSocket signal server for WebRTC signaling and control commands.
 *
 * Message protocol:
 *   { type: 'JOIN_ROOM', payload: { roomId, role, token } }
 *   { type: 'OFFER', payload: { sdp, roomId, from, to } }
 *   { type: 'ANSWER', payload: { sdp, roomId, from, to } }
 *   { type: 'ICE_CANDIDATE', payload: { candidate, roomId, from, to } }
 *   { type: 'MOUSE_EVENT', payload: { action, x, y, button }, roomId, from }
 *   { type: 'KEY_EVENT', payload: { key, code, action }, roomId, from }
 *   { type: 'LEAVE_ROOM' }
 *   { type: 'AUTH_ERROR', payload: { message } }
 *   { type: 'ROOM_FULL' }
 */

import WebSocket from 'ws';
import { WebSocketServer } from 'ws';
import url from 'url';
import jwt from 'jsonwebtoken';
import { config } from './utils/config.js';
import { logger } from './utils/logger.js';
import { mediasoupHandler } from './mediasoup-handler.js';

/** @type {Map<string, Set<Peer>>} - roomId → set of peers */
const roomPeers = new Map();

/**
 * Peer connection wrapper.
 */
class Peer {
  /** @param {WebSocket} ws */
  constructor(ws) {
    this.ws = ws;
    /** @type {{ userId: string, roomId: string, role: string }} | null */
    this.user = null;
    this.sentCapabilities = false;
  }

  /**
   * Send a JSON message.
   */
  send(data) {
    if (this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(data));
    }
  }

  /**
   * Handle incoming message.
   */
  async handleMessage(raw) {
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch {
      this.send({ type: 'AUTH_ERROR', payload: { message: 'Invalid JSON' } });
      return;
    }

    logger.info(
      { type: msg.type, roomId: msg.payload?.roomId, from: msg.from, to: msg.to },
      'Received signal message');

    try {
      switch (msg.type) {
        case 'JOIN_ROOM':
          await this.handleJoinRoom(msg);
          break;
        case 'OFFER':
        case 'ANSWER':
        case 'ICE_CANDIDATE':
          await this.handleRelay(msg);
          break;
        case 'MOUSE_EVENT':
        case 'KEY_EVENT':
          await this.handleControlCommand(msg);
          break;
        case 'LEAVE_ROOM':
          this.handleLeave();
          break;
        default:
          logger.warn({ unknownType: msg.type }, 'Unknown message type');
      }
    } catch (err) {
      logger.error({ err, type: msg.type }, 'Error while handling message');
    }
  }

  /**
   * Join a room: validate token, create room, broadcast capabilities.
   */
  async handleJoinRoom(msg) {
    const { roomId, role, token } = msg.payload || {};
    if (!roomId || !role || !token) {
      this.send({ type: 'AUTH_ERROR', payload: { message: 'Missing roomId, role, or token' } });
      return;
  }

    // Validate JWT
    let decoded;
    try {
      decoded = jwt.verify(token, config.jwtSecret);
    } catch {
      this.send({ type: 'AUTH_ERROR', payload: { message: 'Invalid token' } });
      return;
    }

    if (decoded.roomId !== roomId) {
      this.send({ type: 'AUTH_ERROR', payload: { message: 'Token room mismatch' } });
      return;
    }

    this.user = decoded;
    this.user.roomId = roomId;
    this.user.role = decoded.role;

    // Setup room mapping
    if (!roomPeers.has(roomId)) {
      roomPeers.set(roomId, new Set());
    }
    roomPeers.get(roomId).add(this);

    logger.info(
      { roomId, userId: decoded.userId, role: decoded.role, peerCount: roomPeers.get(roomId).size },
      `Peer joined room`);

    const members = Array.from(roomPeers.get(roomId))
      .filter((p) => p.user)
      .map((p) => ({ userId: p.user.userId, role: p.user.role }));
    logger.info({ roomId, members }, 'Current room members');

    // Notify the other peers in the room that a new peer joined, so a
    // controller can (re)negotiate an offer to a newly arrived viewer.
    this.broadcastToRoom(roomId, {
      type: 'PEER_JOINED',
      payload: { userId: decoded.userId, role: decoded.role },
    });
    logger.info({ roomId, userId: decoded.userId, role: decoded.role }, 'Broadcast PEER_JOINED to others');

    // Initialize mediasoup router for this room
    try {
      await mediasoupHandler.getOrCreateRouter(roomId);
    } catch (err) {
      logger.error({ err, roomId }, 'Failed to create/get router');
      this.send({ type: 'AUTH_ERROR', payload: { message: 'Server media initialization failed' } });
      return;
    }

    // Send router capabilities to this peer
    if (!this.sentCapabilities) {
      try {
        // Get global mediasoup capabilities from the first router
        const firstRouter = mediasoupHandler.rooms.get(roomId)?.router;
        if (firstRouter) {
          this.send({
            type: 'ROOM_JOINED',
            payload: {
              routerRtpCapabilities: firstRouter.rtpCapabilities,
              roomId,
              role: decoded.role,
              peers: Array.from(roomPeers.get(roomId))
                .filter(p => p !== this && p.user)
                .map(p => ({ userId: p.user.userId, role: p.user.role })),
            },
          });
          this.sentCapabilities = true;
        }
      } catch (err) {
        logger.error({ err }, 'Failed to send capabilities');
      }
    }
  }

  /**
   * Relay WebRTC signaling messages between peers.
   */
  async handleRelay(msg) {
    if (!this.user) {
      this.send({ type: 'AUTH_ERROR', payload: { message: 'Not joined to room' } });
      return;
    }

    const { roomId, to } = msg;
    const target = this.findPeerInRoom(to);

    if (target) {
      // Inject sender ID so receiver can route ICE candidates back
      const enriched = { ...msg, from: this.user.userId };
      target.send(enriched);
      logger.info({ from: this.user.userId, to, type: msg.type }, 'Message relayed');
    } else {
      logger.warn({ to, roomId, type: msg.type }, 'Target peer not found — cannot relay');
      this.send({ type: 'AUTH_ERROR', payload: { message: 'Target peer not found' } });
    }
  }

  /**
   * Relay control commands (mouse/keyboard) to the controller.
   */
  async handleControlCommand(msg) {
    if (!this.user) {
      this.send({ type: 'AUTH_ERROR', payload: { message: 'Not joined to room' } });
      return;
    }

    // Only viewers can send control commands
    if (this.user.role !== 'viewer') {
      logger.warn({ userId: this.user.userId, role: this.user.role }, 'Non-viewer attempted control');
      this.send({ type: 'AUTH_ERROR', payload: { message: 'Only viewers can send control commands' } });
      return;
    }

    // Find the controller in this room and forward the command
    const controller = this.findPeerInRoom(null, 'controller');
    if (controller) {
      controller.send(msg);
      logger.debug({ from: this.user.userId, type: msg.type }, 'Control command relayed');
    }
  }

  /**
   * Leave room and clean up.
   */
  handleLeave() {
    if (this.user) {
      const { roomId, userId } = this.user;
      logger.info({ roomId, userId }, 'Peer leaving room');

      // Clean up mediasoup resources
      mediasoupHandler.leaveRoom(roomId, userId);

      // Remove from room peers
      const peers = roomPeers.get(roomId);
      peers?.delete(this);
      if (peers?.size === 0) {
        roomPeers.delete(roomId);
        mediasoupHandler.leaveRoom(roomId);
      }

      // Notify remaining peers
      this.broadcastToRoom(roomId, {
        type: 'PEER_LEFT',
        payload: { userId },
      });
    }
  }

  /**
   * Find a peer in the current room.
   */
  findPeerInRoom(targetUserId, targetRole) {
    const peers = roomPeers.get(this.user?.roomId);
    if (!peers) return null;

    for (const peer of peers) {
      if (peer === this || !peer.user) continue;
      if (targetUserId && peer.user.userId !== targetUserId) continue;
      if (targetRole && peer.user.role !== targetRole) continue;
      return peer;
    }
    return null;
  }

  /**
   * Broadcast a message to all peers in the room except sender.
   */
  broadcastToRoom(roomId, msg) {
    const peers = roomPeers.get(roomId);
    if (!peers) return;

    for (const peer of peers) {
      if (peer !== this && peer.ws.readyState === WebSocket.OPEN) {
        peer.send(msg);
      }
    }
  }
}

/**
 * Create and attach WebSocket server to an existing HTTP server.
 * @param {import('http').Server} httpServer
 */
export function setupSignalServer(httpServer) {
  // NOTE: we deliberately do NOT pass `path: '/signal'`. Some WebSocket
  // clients (web_socket_channel on Flutter) append a `#` fragment to the
  // upgrade request URI (e.g. `ws://host:3000/signal#`), and `ws`'s exact
  // path match would then reject it with HTTP 404. This is a dedicated
  // signaling server with no other WebSocket endpoints, so accepting all
  // upgrade requests on this port is safe.
  const wss = new WebSocketServer({ server: httpServer });

  wss.on('connection', (ws, req) => {
    logger.info({ remote: req.socket.remoteAddress }, 'New WebSocket connection');
    const peer = new Peer(ws);

    ws.on('message', (raw) => {
      peer.handleMessage(raw.toString());
    });

    ws.on('close', (code, reason) => {
      logger.info(
        { code, reason: reason?.toString(), userId: peer.user?.userId },
        'WebSocket closed');
      peer.handleLeave();
    });

    ws.on('error', (err) => {
      logger.error({ err, userId: peer.user?.userId }, 'WebSocket error');
    });

    // Heartbeat / ping
    ws.isAlive = true;
    ws.on('pong', () => {
      ws.isAlive = true;
    });
  });

  // Ping/pong heartbeat (30s interval)
  const heartbeat = setInterval(() => {
    wss.clients.forEach((ws) => {
      if (ws.isAlive === false) {
        return ws.terminate();
      }
      ws.isAlive = true;
      ws.ping();
    });
  }, 30000);

  wss.on('close', () => {
    clearInterval(heartbeat);
  });

  logger.info('WebSocket signal server listening (accepts upgrades on any path)');
  return wss;
}
