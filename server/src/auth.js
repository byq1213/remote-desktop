import jwt from 'jsonwebtoken';
import { config } from '../utils/config.js';
import { logger } from '../utils/logger.js';

/**
 * Validate and decode JWT token.
 * Expects token in Authorization header: "Bearer <token>"
 * Returns decoded payload or null.
 */
export function authenticateToken(req) {
  const authHeader = req.headers.authorization || req.query?.token;
  if (!authHeader) {
    logger.warn('Missing authorization header');
    return null;
  }

  const token = authHeader.startsWith('Bearer ')
    ? authHeader.slice(7)
    : authHeader;

  try {
    const decoded = jwt.verify(token, config.jwtSecret);
    return decoded;
  } catch (err) {
    logger.warn({ err: err.message }, 'JWT verification failed');
    return null;
  }
}

/**
 * Generate a room-scoped JWT token.
 * @param {object} opts
 * @param {string} opts.userId
 * @param {string} opts.roomId
 * @param {'controller'|'viewer'} opts.role
 * @param {number} [opts.expiresIn=3600] - TTL in seconds
 * @returns {string} JWT token
 */
export function generateToken({ userId, roomId, role, expiresIn = 3600 }) {
  return jwt.sign(
    { userId, roomId, role },
    config.jwtSecret,
    { expiresIn }
  );
}
