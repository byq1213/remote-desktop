import pino from 'pino';
import { config } from './config.js';

export const logger = pino({
  level: config.logLevel,
  // Development: log to stdout with pretty-print
  transport:
    process.env.NODE_ENV !== 'production'
      ? {
          target: 'pino-pretty',
          options: { colorize: true },
        }
      : undefined,
});
