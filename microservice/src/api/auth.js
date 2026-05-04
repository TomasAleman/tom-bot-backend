/**
 * POST /api/auth/login    -> { token, usuario }
 * GET  /api/me            -> { usuario }   (requiere auth)
 *
 * Rate limit: 5 intentos por minuto por IP, controlado por Redis para
 * que sea coherente entre múltiples instancias.
 */

import bcrypt from 'bcryptjs';
import { z } from 'zod';
import { authHook } from '../middleware/auth.js';

const LoginSchema = z.object({
  email: z.string().trim().toLowerCase().email().max(160),
  password: z.string().min(1).max(200),
});

const LOGIN_RATE_LIMIT = 5;
const LOGIN_RATE_WINDOW_SECONDS = 60;

async function checkLoginRateLimit(ctx, ip) {
  const key = `ratelimit:login:${ip || 'unknown'}`;
  const count = await ctx.redis.incr(key);
  if (count === 1) await ctx.redis.expire(key, LOGIN_RATE_WINDOW_SECONDS);
  return count <= LOGIN_RATE_LIMIT;
}

export async function registerAuthRoutes(fastify, ctx) {
  fastify.post('/auth/login', async (req, reply) => {
    const parsed = LoginSchema.safeParse(req.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'bad_request', issues: parsed.error.issues });
    }
    const { email, password } = parsed.data;

    const ok = await checkLoginRateLimit(ctx, req.ip);
    if (!ok) {
      return reply.code(429).send({ error: 'too_many_requests', message: 'demasiados intentos, esperá un minuto' });
    }

    const { rows } = await ctx.pgPool.query(
      `SELECT u.id, u.restaurante_id, u.email, u.password_hash, u.nombre, u.rol, u.activo,
              r.nombre AS restaurante_nombre, r.slug AS restaurante_slug, r.timezone AS restaurante_tz
         FROM tombot.usuarios_panel u
         JOIN tombot.restaurantes   r ON r.id = u.restaurante_id
        WHERE lower(u.email) = $1
        LIMIT 1`,
      [email]
    );

    const user = rows[0];
    if (!user || !user.activo) {
      await bcrypt.compare(password, '$2a$12$dummyhashdummyhashdummyhashdummyhashdummyhash');
      return reply.code(401).send({ error: 'invalid_credentials' });
    }

    const valid = await bcrypt.compare(password, user.password_hash);
    if (!valid) {
      return reply.code(401).send({ error: 'invalid_credentials' });
    }

    await ctx.pgPool.query(
      'UPDATE tombot.usuarios_panel SET ultimo_login_at = NOW() WHERE id = $1',
      [user.id]
    );

    const token = await reply.jwtSign(
      {
        usuario_id: Number(user.id),
        restaurante_id: Number(user.restaurante_id),
        rol: user.rol,
        email: user.email,
      },
      { expiresIn: '8h' }
    );

    try {
      await ctx.pgPool.query(
        `INSERT INTO tombot.eventos_log (restaurante_id, tipo_evento, payload)
         VALUES ($1, 'panel_login', $2::jsonb)`,
        [user.restaurante_id, JSON.stringify({ usuario_id: Number(user.id), ip: req.ip })]
      );
    } catch (err) {
      ctx.log.warn({ err }, 'no se pudo loguear evento panel_login');
    }

    return {
      token,
      usuario: {
        id: Number(user.id),
        email: user.email,
        nombre: user.nombre,
        rol: user.rol,
        restaurante: {
          id: Number(user.restaurante_id),
          nombre: user.restaurante_nombre,
          slug: user.restaurante_slug,
          timezone: user.restaurante_tz,
        },
      },
    };
  });

  fastify.get('/me', { preHandler: authHook }, async (req) => {
    const { rows } = await ctx.pgPool.query(
      `SELECT u.id, u.email, u.nombre, u.rol, u.ultimo_login_at,
              r.id AS restaurante_id, r.nombre AS restaurante_nombre,
              r.slug AS restaurante_slug, r.timezone AS restaurante_tz
         FROM tombot.usuarios_panel u
         JOIN tombot.restaurantes   r ON r.id = u.restaurante_id
        WHERE u.id = $1 AND u.activo = TRUE
        LIMIT 1`,
      [req.user.usuario_id]
    );
    const u = rows[0];
    if (!u) return { usuario: null };
    return {
      usuario: {
        id: Number(u.id),
        email: u.email,
        nombre: u.nombre,
        rol: u.rol,
        ultimo_login_at: u.ultimo_login_at,
        restaurante: {
          id: Number(u.restaurante_id),
          nombre: u.restaurante_nombre,
          slug: u.restaurante_slug,
          timezone: u.restaurante_tz,
        },
      },
    };
  });
}
