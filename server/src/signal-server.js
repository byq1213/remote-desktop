/**
 * WebSocket signal server for WebRTC signaling relay and control commands.
 *
 * This server does NOT route media (no SFU). It only relays signaling
 * (SDP / ICE) and control (mouse / keyboard) messages between the two peers
 * in a room, and enforces JWT-scoped room membership.
 *
 * Protocol (shared constants live in the client at lib/signal/protocol.dart):
 *   { type: 'JOIN_ROOM',     payload: { roomId, role, token } }
 *   { type: 'OFFER',         payload: { sdp },               roomId, from, to }
 *   { type: 'ANSWER',        payload: { sdp },               roomId, from, to }
 *   { type: 'ICE_CANDIDATE', payload: { candidate, ... },    roomId, from, to }
 *   { type: 'MOUSE_EVENT',   payload: { action, x, y, ... }, roomId, from }
 *   { type: 'KEY_EVENT',     payload: { action, keyCode },   roomId, from }
 *   { type: 'LEAVE_ROOM' }
 *   { type: 'AUTH_ERROR',    payload: { message } }
 *   { type: 'PEER_JOINED',   payload: { userId, role } }
 *   { type: 'PEER_LEFT',     payload: { userId } }
 *   { type: 'ROOM_JOINED',   payload: { roomId, role, peers } }
 */

import { WebSocketServer } from 'ws';
import { WebSocket } from 'ws';
import { logger } from './utils/logger.js';
import { verifyToken } from './auth.js';

/** @type {Map<string, Set<Peer>>} - roomId -> set of peers */
const roomPeers = new Map();

/**
 * Wrapper around a single WebSocket connection.
 */
class Peer {
  /** @param {import('ws').WebSocket} ws */
  constructor(ws) {
    this.ws = ws;
    /** @type {{ userId: string, roomId: string, role: string }|null} */
    this.user = null;
    this.sentJoin = false;
  }

  /** Send a JSON message if the socket is open. */
  send(data) {
    if (this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(data));
    }
  }

  /** Parse and dispatch an incoming raw message. */
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
      'Received signal message',
    );

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

  /** Validate the token, register the peer in its room, and reply. */
  async handleJoinRoom(msg) {
    const { roomId, role, token } = msg.payload || {};
    if (!roomId || !role || !token) {
      this.send({ type: 'AUTH_ERROR', payload: { message: 'Missing roomId, role, or token' } });
      return;
    }

    const decoded = verifyToken(token);
    if (!decoded) {
      this.send({ type: 'AUTH_ERROR', payload: { message: 'Invalid token' } });
      return;
    }
    if (decoded.roomId !== roomId) {
      this.send({ type: 'AUTH_ERROR', payload: { message: 'Token room mismatch' } });
      return;
    }

    this.user = { userId: decoded.userId, roomId, role: decoded.role };

    if (!roomPeers.has(roomId)) {
      roomPeers.set(roomId, new Set());
    }
    roomPeers.get(roomId).add(this);

    logger.info(
      { roomId, userId: decoded.email ?? decoded.userId, role: decoded.role, peerCount: roomPeers.get(roomId).size },
      'Peer joined room',
    );

    // Tell the other peers a new one arrived so a controller can
    // (re)negotiate an offer to a newly joined viewer.
    this.broadcastToRoom(roomId, {
      type: 'PEER_JOINED',
      payload: { userId: decoded.userId, role: decoded.role },
    });

    if (!this.sentJoin) {
      this.send({
        type: 'ROOM_JOINED',
        payload: {
          roomId,
          role: decoded.role,
          peers: Array.from(roomPeers.get(roomId))
            .filter((p) => p !== this && p.user)
            .map((p) => ({ userId: p.user.userId, role: p.user.role })),
        },
      });
      this.sentJoin = true;
    }
  }

  /** Relay WebRTC signaling (offer/answer/ICE) to the addressed peer. */
  async handleRelay(msg) {
    if (!this.user) {
      this.send({ type: 'AUTH_ERROR', payload: { message: 'Not joined to room' } });
      return;
    }
    // A peer may only relay within its own (token-scoped) room.
    if (msg.roomId && msg.roomId !== this.user.roomId) {
      this.send({ type: 'AUTH_ERROR', payload: { message: 'Room mismatch' } });
      return;
    }

    const target = this.findPeerInRoom(msg.to);
    if (target) {
      // Inject the sender id so the receiver can route ICE back.
      target.send({ ...msg, from: this.user.userId });
      logger.info({ from: this.user.userId, to: msg.to, type: msg.type }, 'Message relayed');
    } else {
      logger.warn({ to: msg.to, type: msg.type }, 'Target peer not found — cannot relay');
      this.send({ type: 'AUTH_ERROR', payload: { message: 'Target peer not found' } });
    }
  }

  /** Relay control commands (mouse/keyboard) to the room's controller. */
  async handleControlCommand(msg) {
    if (!this.user) {
      this.send({ type: 'AUTH_ERROR', payload: { message: 'Not joined to room' } });
      return;
    }
    if (this.user.role !== 'viewer') {
      logger.warn({ userId: this.user.userId, role: this.user.role }, 'Non-viewer attempted control');
      this.send({ type: 'AUTH_ERROR', payload: { message: 'Only viewers can send control commands' } });
      return;
    }
    if (msg.roomId && msg.roomId !== this.user.roomId) {
      this.send({ type: 'AUTH_ERROR', payload: { message: 'Room mismatch' } });
      return;
    }

    const controller = this.findPeerInRoom(null, 'controller');
    if (controller) {
      controller.send(msg);
      logger.debug({ from: this.user.userId, type: msg.type }, 'Control command relayed');
    }
  }

  /** Leave the room and notify the remaining peers. */
  handleLeave() {
    if (!this.user) return;
    const { roomId, userId } = this.user;
    logger.info({ roomId, userId }, 'Peer leaving room');

    const peers = roomPeers.get(roomId);
    peers?.delete(this);
    if (peers?.size === 0) {
      roomPeers.delete(roomId);
    }
    this.broadcastToRoom(roomId, { type: 'PEER_LEFT', payload: { userId } });
    this.user = null;
  }

  /** Find a peer in the current room by id and/or role. */
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

  /** Broadcast to every other peer in the room. */
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
 * Attach the WebSocket signal server to an existing HTTP server.
 * @param {import('http').Server} httpServer
 */
export function setupSignalServer(httpServer) {
  // NOTE: we deliberately do NOT pin `path: '/signal'`. Some clients append a
  // fragment/hash to the upgrade URI and an exact path match would 404. This
  // is a dedicated signaling port, so accepting all upgrades is safe.
  const wss = new WebSocketServer({ server: httpServer });

  wss.on('connection', (ws, req) => {
    logger.info({ remote: req.socket.remoteAddress }, 'New WebSocket connection');
    const peer = new Peer(ws);

    ws.on('message', (raw) => peer.handleMessage(raw.toString()));
    ws.on('close', (code, reason) => {
      logger.info(
        { code, reason: reason?.toString(), userId: peer.user?.userId },
        'WebSocket closed',
      );
      peer.handleLeave();
    });
    ws.on('error', (err) => {
      logger.error({ err, userId: peer.user?.userId }, 'WebSocket error');
    });

    // Heartbeat: terminate sockets that stop responding to pings.
    ws.isAlive = true;
    ws.on('pong', () => { ws.isAlive = true; });
  });

  const heartbeat = setInterval(() => {
    wss.clients.forEach((ws) => {
      if (ws.isAlive === false) return ws.terminate();
      ws.isAlive = true;
      ws.ping();
    });
  }, 30000);

  wss.on('close', () => clearInterval(heartbeat));

  logger.info('WebSocket signal server listening (accepts upgrades on any path)');
  return wss;
}
