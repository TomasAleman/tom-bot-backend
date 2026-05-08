/**
 * Microservicio del hot path del bot de reservas + API del panel web.
 *
 * - POST /webhook/whatsapp-reservas-fast  -> hot path WhatsApp (existente)
 * - POST /api/auth/login                  -> login del panel
 * - GET  /api/me                          -> info del usuario logueado
 * - GET  /api/reservas, PATCH, cancelar, no-show
 * - GET/POST/PATCH/DELETE /api/mesas
 * - GET/PATCH/DELETE /api/config
 * - GET  /api/sesiones
 * - GET  /api/metricas
 * - GET  /admin/*                         -> bundle estatico del panel React (PWA)
 *
 * Variables de entorno:
 *   PORT             default 3000
 *   PGURL            connection string Postgres
 *   REDIS_URL        connection string Redis
 *   GROQ_API_KEY     api key Groq (solo hot path WhatsApp)
 *   EVOLUTION_URL    base URL de Evolution API
 *   JWT_SECRET       secreto para firmar tokens del panel (obligatorio si se usa el panel)
 *   PANEL_PUBLIC_DIR ruta absoluta al bundle del panel (default /opt/tombot/panel-public)
 *   LOG_LEVEL        info | debug | warn | error
 */

import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { existsSync } from 'node:fs';
import Fastify from 'fastify';
import fastifyJwt from '@fastify/jwt';
import fastifyHelmet from '@fastify/helmet';
import fastifyStatic from '@fastify/static';
import { Pool } from 'pg';
import Redis from 'ioredis';
import { handleMessage } from './handlers/message.js';
import { registerApi } from './api/index.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const fastify = Fastify({
  logger: { level: process.env.LOG_LEVEL || 'info' },
  trustProxy: true,
});

const pgPool = new Pool({ connectionString: process.env.PGURL });
const redis = new Redis(process.env.REDIS_URL || 'redis://redis:6379');

const evolutionUrl = process.env.EVOLUTION_URL || 'http://evolution-api:8080';
const groqKey = process.env.GROQ_API_KEY;
const jwtSecret = process.env.JWT_SECRET;
const panelPublicDir = process.env.PANEL_PUBLIC_DIR || '/opt/tombot/panel-public';
const evolutionGlobalKey = process.env.EVOLUTION_GLOBAL_KEY;

if (!groqKey) {
  fastify.log.warn('GROQ_API_KEY no esta seteada — el hot path WhatsApp no podra parsear mensajes.');
}
if (!jwtSecret) {
  fastify.log.warn('JWT_SECRET no esta seteada — las rutas /api del panel no funcionaran.');
}

const ctx = {
  pgPool,
  redis,
  evolutionUrl,
  evolutionGlobalKey,
  groqKey,
  log: fastify.log,
};

await fastify.register(fastifyHelmet, {
  contentSecurityPolicy: false,
  crossOriginEmbedderPolicy: false,
});

if (jwtSecret) {
  await fastify.register(fastifyJwt, { secret: jwtSecret });
  await registerApi(fastify, ctx);
} else {
  fastify.log.warn('Saltando registro de /api/* porque falta JWT_SECRET');
}

const panelDirExists = existsSync(panelPublicDir);
if (panelDirExists) {
  await fastify.register(fastifyStatic, {
    root: panelPublicDir,
    prefix: '/admin/',
    index: ['index.html'],
    setHeaders: (res, filePath) => {
      if (filePath.endsWith('.html')) {
        res.setHeader('Cache-Control', 'no-cache');
      } else if (/\.(js|css|woff2?|ttf|otf|png|jpg|jpeg|svg|webp|ico|json|webmanifest)$/i.test(filePath)) {
        res.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
      }
    },
  });
  fastify.log.info(`Panel servido desde ${panelPublicDir} en /admin/`);
} else {
  fastify.log.warn(`PANEL_PUBLIC_DIR ${panelPublicDir} no existe — /admin/ no se sirve.`);
}

fastify.setNotFoundHandler((req, reply) => {
  const url = req.raw.url || '';
  if (url.split('?')[0].startsWith('/admin') && panelDirExists) {
    return reply.sendFile('index.html');
  }
  return reply.code(404).send({ error: 'not_found' });
});

fastify.get('/health', async () => {
  await pgPool.query('SELECT 1');
  await redis.ping();
  return { ok: true, ts: Date.now() };
});

fastify.post('/webhook/whatsapp-reservas-fast', async (request, reply) => {
  reply.code(202).send({ accepted: true });
  setImmediate(() => {
    handleMessage(request.body, ctx).catch((err) => {
      fastify.log.error({ err }, 'handleMessage fallo');
    });
  });
});

const port = parseInt(process.env.PORT || '3000', 10);
fastify.listen({ port, host: '0.0.0.0' }).then(() => {
  fastify.log.info(`tom-bot hot path + panel API escuchando en :${port}`);
});

process.on('SIGTERM', async () => {
  fastify.log.info('SIGTERM recibido, cerrando');
  await fastify.close();
  await pgPool.end();
  redis.disconnect();
  process.exit(0);
});
