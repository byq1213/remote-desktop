import jwt from 'jsonwebtoken';
import { config } from './utils/config.js';
import { logger } from './utils/logger.js';

/**
 * Generate a room-scoped JWT.
 * @param {object} opts
 * @param {string} opts.userId
 * @param {string} opts.roomId
 * @param {'controller'|'viewer'} opts.role
 * @param {number} [opts.expiresIn=3600] - TTL in seconds
 * @returns {string} JWT token
 */
export function generateToken({ userId, roomId, role, expiresIn = 3600 }) {
  return jwt.sign({ userId, roomId, role }, config.jwtSecret, { expiresIn });
}

/**
 * Verify a JWT and return its decoded payload, or null if invalid/missing.
 * Centralizes all JWT verification so the signal server and any future REST
 * endpoints share one code path.
 * @param {string|undefined} token
 * @returns {object|null}
 */
export function verifyToken(token) {
  if (!token) return null;
  try {
    return jwt.verify(token, config.jwtSecret);
  } catch (err) {
    logger.warn({ err: err.message }, 'JWT verification failed');
    return null;
  }
}
