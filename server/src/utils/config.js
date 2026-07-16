import dotenv from 'dotenv';
import { z } from 'zod';

dotenv.config();

const configSchema = z.object({
  PORT: z.string().default('3000'),
  JWT_SECRET: z.string().min(16),
  LOG_LEVEL: z.enum(['trace', 'debug', 'info', 'warn', 'error', 'fatal']).default('warn'),
});

const parsed = configSchema.safeParse({
  PORT: process.env.PORT,
  JWT_SECRET: process.env.JWT_SECRET,
  LOG_LEVEL: process.env.LOG_LEVEL,
});

if (!parsed.success) {
  console.error('Invalid server config:', parsed.error.flatten().fieldErrors);
  process.exit(1);
}

export const config = {
  port: Number(parsed.data.PORT),
  jwtSecret: parsed.data.JWT_SECRET,
  logLevel: parsed.data.LOG_LEVEL,
};
