import dotenv from 'dotenv';
import { z } from 'zod';

dotenv.config();

const configSchema = z.object({
  PORT: z.string().default('3000'),
  JWT_SECRET: z.string().min(16),
  WEBRTC_MIN_PORT: z.string().default('40000'),
  WEBRTC_MAX_PORT: z.string().default('40100'),
  LOG_LEVEL: z.enum(['trace', 'debug', 'info', 'warn', 'error', 'fatal']).default('warn'),
});

const parsed = configSchema.safeParse({
  PORT: process.env.PORT,
  JWT_SECRET: process.env.JWT_SECRET,
  WEBRTC_MIN_PORT: process.env.WEBRTC_MIN_PORT,
  WEBRTC_MAX_PORT: process.env.WEBRTC_MAX_PORT,
  LOG_LEVEL: process.env.LOG_LEVEL,
});

if (!parsed.success) {
  console.error('Invalid server config:', parsed.error.flatten().fieldErrors);
  process.exit(1);
}

export const config = {
  port: Number(parsed.data.PORT),
  jwtSecret: parsed.data.JWT_SECRET,
  rtcMinPort: Number(parsed.data.WEBRTC_MIN_PORT),
  rtcMaxPort: Number(parsed.data.WEBRTC_MAX_PORT),
  logLevel: parsed.data.LOG_LEVEL,
};
