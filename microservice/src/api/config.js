/**
 * /api/config — parametros del bot por restaurante (tombot.config).
 *
 * GET    /                  -> { config: { parametro: { valor, descripcion, updated_at } }, schema: PARAMETROS_CONFIG }
 * PATCH  /                  -> body: { parametro: valor, ... } valida cada par contra el catalogo y hace upsert
 * DELETE /:parametro        -> elimina un parametro (solo claves del catalogo)
 *
 * Los valores se persisten como TEXT por compatibilidad con n8n. La capa de
 * validacion vive en ./config-schema.js (catalogo PARAMETROS_CONFIG).
 */

import { authHook } from '../middleware/auth.js';
import { PARAMETROS_CONFIG, esParametroConocido, validarValor } from './config-schema.js';

const PARAM_REGEX = /^[A-Za-z][A-Za-z0-9_]{0,79}$/;

async function leerConfig(pgPool, restauranteId) {
  const { rows } = await pgPool.query(
    `SELECT parametro, valor, descripcion, updated_at
       FROM tombot.config
      WHERE restaurante_id = $1
      ORDER BY parametro`,
    [restauranteId]
  );
  const config = {};
  for (const r of rows) {
    config[r.parametro] = {
      valor: r.valor,
      descripcion: r.descripcion,
      updated_at: r.updated_at,
    };
  }
  return config;
}

export async function registerConfigRoutes(fastify, ctx) {
  fastify.addHook('preHandler', authHook);

  fastify.get('/', async (req) => {
    const config = await leerConfig(ctx.pgPool, req.user.restaurante_id);
    return { config, schema: PARAMETROS_CONFIG };
  });

  fastify.patch('/', async (req, reply) => {
    const body = req.body;
    if (!body || typeof body !== 'object' || Array.isArray(body)) {
      return reply.code(400).send({ error: 'bad_request', message: 'body invalido' });
    }
    const claves = Object.keys(body);
    if (claves.length === 0) {
      return reply.code(400).send({ error: 'bad_request', message: 'al menos un parametro' });
    }

    const errores = [];
    const normalizados = {};
    for (const k of claves) {
      if (!PARAM_REGEX.test(k)) {
        errores.push({ parametro: k, error: 'nombre_invalido' });
        continue;
      }
      if (!esParametroConocido(k)) {
        errores.push({ parametro: k, error: 'parametro_desconocido' });
        continue;
      }
      const r = validarValor(k, body[k]);
      if (!r.ok) {
        errores.push({ parametro: k, error: r.error });
        continue;
      }
      normalizados[k] = r.valor;
    }

    if (errores.length > 0) {
      return reply.code(400).send({ error: 'bad_request', issues: errores });
    }

    const restauranteId = req.user.restaurante_id;
    const client = await ctx.pgPool.connect();
    try {
      await client.query('BEGIN');
      for (const [parametro, valor] of Object.entries(normalizados)) {
        if (valor === null) {
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
            [restauranteId, parametro, valor]
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
        [restauranteId, JSON.stringify({ por_usuario: req.user.usuario_id, claves: Object.keys(normalizados) })]
      );
    } catch (err) {
      ctx.log.warn({ err }, 'no se pudo loguear evento panel_config_actualizada');
    }

    const config = await leerConfig(ctx.pgPool, restauranteId);
    return { config, schema: PARAMETROS_CONFIG };
  });

  fastify.delete('/:parametro', async (req, reply) => {
    const parametro = String(req.params.parametro || '');
    if (!PARAM_REGEX.test(parametro)) {
      return reply.code(400).send({ error: 'bad_request' });
    }
    if (!esParametroConocido(parametro)) {
      return reply.code(400).send({ error: 'parametro_desconocido' });
    }
    const { rowCount } = await ctx.pgPool.query(
      'DELETE FROM tombot.config WHERE restaurante_id = $1 AND parametro = $2',
      [req.user.restaurante_id, parametro]
    );
    if (rowCount === 0) return reply.code(404).send({ error: 'not_found' });
    return reply.code(204).send();
  });
}
