/**
 * /api/config — parametros del bot por restaurante (tombot.config).
 *
 * GET    /                  -> { config: { parametro: { valor, descripcion, updated_at } } }
 * PATCH  /                  -> body: { parametro: valor, ... } upsert masivo (ignora valores vacíos = borra)
 * DELETE /:parametro        -> elimina un parametro
 */

import { z } from 'zod';
import { authHook } from '../middleware/auth.js';

const PARAM_REGEX = /^[A-Za-z][A-Za-z0-9_]{0,79}$/;

const PatchSchema = z.record(
  z.string().regex(PARAM_REGEX),
  z.union([z.string().max(2000), z.number(), z.boolean(), z.null()])
).refine((d) => Object.keys(d).length > 0, { message: 'al menos un parametro' });

export async function registerConfigRoutes(fastify, ctx) {
  fastify.addHook('preHandler', authHook);

  fastify.get('/', async (req) => {
    const { rows } = await ctx.pgPool.query(
      `SELECT parametro, valor, descripcion, updated_at
         FROM tombot.config
        WHERE restaurante_id = $1
        ORDER BY parametro`,
      [req.user.restaurante_id]
    );
    const config = {};
    for (const r of rows) {
      config[r.parametro] = {
        valor: r.valor,
        descripcion: r.descripcion,
        updated_at: r.updated_at,
      };
    }
    return { config };
  });

  fastify.patch('/', async (req, reply) => {
    const parsed = PatchSchema.safeParse(req.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'bad_request', issues: parsed.error.issues });
    }
    const restauranteId = req.user.restaurante_id;
    const updates = parsed.data;

    const client = await ctx.pgPool.connect();
    try {
      await client.query('BEGIN');
      for (const [parametro, valor] of Object.entries(updates)) {
        if (valor === null || valor === '') {
          await client.query(
            'DELETE FROM tombot.config WHERE restaurante_id = $1 AND parametro = $2',
            [restauranteId, parametro]
          );
        } else {
          await client.query(
            `INSERT INTO tombot.config (restaurante_id, parametro, valor, updated_at)
                 VALUES ($1, $2, $3, NOW())
            ON CONFLICT (restaurante_id, parametro) DO UPDATE
                 SET valor = EXCLUDED.valor, updated_at = NOW()`,
            [restauranteId, parametro, String(valor)]
          );
        }
      }
      await client.query('COMMIT');
    } catch (err) {
      await client.query('ROLLBACK');
      throw err;
    } finally {
      client.release();
    }

    try {
      await ctx.pgPool.query(
        `INSERT INTO tombot.eventos_log (restaurante_id, tipo_evento, payload)
         VALUES ($1, 'panel_config_actualizada', $2::jsonb)`,
        [restauranteId, JSON.stringify({ por_usuario: req.user.usuario_id, claves: Object.keys(updates) })]
      );
    } catch (err) {
      ctx.log.warn({ err }, 'no se pudo loguear evento panel_config_actualizada');
    }

    const { rows } = await ctx.pgPool.query(
      `SELECT parametro, valor, descripcion, updated_at
         FROM tombot.config WHERE restaurante_id = $1 ORDER BY parametro`,
      [restauranteId]
    );
    const config = {};
    for (const r of rows) {
      config[r.parametro] = { valor: r.valor, descripcion: r.descripcion, updated_at: r.updated_at };
    }
    return { config };
  });

  fastify.delete('/:parametro', async (req, reply) => {
    const parametro = String(req.params.parametro || '');
    if (!PARAM_REGEX.test(parametro)) {
      return reply.code(400).send({ error: 'bad_request' });
    }
    const { rowCount } = await ctx.pgPool.query(
      'DELETE FROM tombot.config WHERE restaurante_id = $1 AND parametro = $2',
      [req.user.restaurante_id, parametro]
    );
    if (rowCount === 0) return reply.code(404).send({ error: 'not_found' });
    return reply.code(204).send();
  });
}
