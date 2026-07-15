import mediasoupPkg from 'mediasoup';
const { createWorker, getSupportedRtpCapabilities } = mediasoupPkg;
import { config } from './utils/config.js';
import { logger } from './utils/logger.js';

/**
 * Manage mediasoup Router and Rooms.
 *
 * Architecture:
 *   Worker (one per CPU core) → Router (one per room)
 *   Controller creates Producer on Router
 *   Viewer creates Consumer on same Router
 */
class MediasoupHandler {
  constructor() {
    /** @type {Map<string, Room>} */
    this.rooms = new Map();
    this.worker = null;
  }

  /**
   * Initialize mediasoup worker.
   * Loads the router extension that handles actual media routing.
   */
  async init() {
    this.worker = await createWorker({
      rtcMinPort: config.rtcMinPort,
      rtcMaxPort: config.rtcMaxPort,
      logTag: ['info', 'ice', 'dtls', 'rtp', 'srtp', 'rtcp'],
    });

    this.worker.on('died', () => {
      logger.error('mediasoup Worker died, exiting...');
      process.exit(1);
    });

    logger.info(
      { rtpCapabilities: getSupportedRtpCapabilities() },
      'mediasoup Worker started'
    );
  }

  /**
   * Get router capabilities for creating new peers.
   */
  getRouterCapabilities() {
    return this.worker.router?.rk_getNative()?.rk_getRtpCapabilities?.();
  }

  /**
   * Create or get existing room's router.
   * @param {string} roomId
   * @returns {Promise<mediasoup.types.Router>}
   */
  async getOrCreateRouter(roomId) {
    let room = this.rooms.get(roomId);
    if (room) return room.router;

    const router = await this.worker.createRouter({
      mediaCodecs: [
        {
          id: 96,
          kind: 'video',
          mimeType: 'video/VP8',
          clockRate: 90000,
          channels: 1,
          parameters: {
            'x-google-start-bitrate': 1000,
            'x-google-max-bitrate': 5000,
          },
        },
      ],
    });

    room = { router, producers: new Map(), consumers: new Map() };
    this.rooms.set(roomId, room);

    logger.info({ roomId }, 'New room created');
    return router;
  }

  /**
   * Leave and cleanup room.
   * @param {string} roomId
   * @param {string} [peerId] - Optional: only cleanup one peer
   */
  leaveRoom(roomId, peerId) {
    const room = this.rooms.get(roomId);
    if (!room) return;

    if (peerId) {
      // Clean up one peer's producer/consumers
      room.producers.delete(peerId);
      for (const [consumerId, consumer] of room.consumers) {
        if (consumerId.startsWith(peerId)) {
          consumer.close();
          room.consumers.delete(consumerId);
        }
      }

      // Remove room if no peers left
      if (room.producers.size === 0 && room.consumers.size === 0) {
        this.rooms.delete(roomId);
        logger.info({ roomId }, 'Room cleaned up');
      }
    } else {
      // Clean up entire room
      for (const producer of room.producers.values()) producer.close();
      for (const consumer of room.consumers.values()) consumer.close();
      this.rooms.delete(roomId);
      logger.info({ roomId }, 'Entire room destroyed');
    }
  }

  /**
   * Register a producer for a room.
   * @param {string} roomId
   * @param {string} peerId
   * @param {mediasoup.types.ProducerOptions} options
   * @returns {Promise<mediasoup.types.Producer>}
   */
  async createProducer(roomId, peerId, options) {
    const router = await this.getOrCreateRouter(roomId);
    const producer = await router.createProducer(options);
    const room = this.rooms.get(roomId);
    room.producers.set(peerId, producer);
    logger.info({ roomId, peerId, producerId: producer.id }, 'Producer created');

    return producer;
  }

  /**
   * Consume a producer from a room.
   * @param {string} roomId
   * @param {string} consumerId
   * @param {string} producerId
   * @param {mediasoup.types.ConsumerOptions} options
   * @returns {Promise<mediasoup.types.Consumer>}
   */
  async createConsumer(roomId, consumerId, producerId, options) {
    const router = await this.getOrCreateRouter(roomId);
    const consumer = await router.createConsumer(options);
    const key = `${consumerId}:${producerId}`;
    const room = this.rooms.get(roomId);
    room.consumers.set(key, consumer);
    logger.info({ roomId, consumerId, producerId }, 'Consumer created');

    return consumer;
  }

  /**
   * List all producers in a room (for debugging).
   */
  listProducers(roomId) {
    const room = this.rooms.get(roomId);
    if (!room) return [];
    return Array.from(room.producers.entries()).map(([id, p]) => ({
      id,
      paused: p.paused,
      type: p.kind,
    }));
  }
}

/**
 * @typedef {object} Room
 * @property {mediasoup.types.Router} router
 * @property {Map<string, mediasoup.types.Producer>} producers
 * @property {Map<string, mediasoup.types.Consumer>} consumers
 */

export const mediasoupHandler = new MediasoupHandler();
