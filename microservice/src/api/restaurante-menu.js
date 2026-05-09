/**
 * GET/PATCH /api/restaurante/menu
 * link_menu y mostrar_menu en tombot.restaurantes (por tenant del JWT).
 */

import { authHook } from '../middleware/auth.js';
import { requireWriteAccess } from '../middleware/authz.js';

function parseMostrarMenu(v) {
  if (typeof v === 'boolean') return { ok: true, value: v };
  if (v === 'true' || v === '1') return { ok: true, value: true };
  if (v === 'false' || v === '0') return { ok: true, value: false };
  return { ok: false, error: 'mostrar_menu_invalido' };
}

function parseLinkMenu(v) {
  if (v === null || v === undefined) return { ok: true, value: null };
  const t = String(v).trim();
  if (t === '') return { ok: true, value: null };
  try {
    const u = new URL(t);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') {
      return { ok: false, error: 'url_solo_http_https' };
    }
    return { ok: true, value: t };
  } catch {
    return { ok: false, error: 'url_invalida' };
  }
}

export async function registerRestauranteMenuRoutes(fastify, ctx) {
  fastify.addHook('preHandler', authHook);

  fastify.get('/', async (req) => {
    const rid = req.user.restaurante_id;
    if (!rid) {
      return { link_menu: null, mostrar_menu: true };
    }
    const { rows } = await ctx.pgPool.query(
      `SELECT link_menu, mostrar_menu
         FROM tombot.restaurantes
        WHERE id = $1`,
      [rid]
    );
    const r = rows[0];
    if (!r) return { link_menu: null, mostrar_menu: true };
    return { link_menu: r.link_menu, mostrar_menu: r.mostrar_menu };
  });

  fastify.patch('/', { preHandler: requireWriteAccess }, async (req, reply) => {
    const rid = req.user.restaurante_id;
    if (!rid) {
      return reply.code(400).send({ error: 'bad_request', message: 'sin restaurante en el token' });
    }
    const body = req.body;
    if (!body || typeof body !== 'object' || Array.isArray(body)) {
      return reply.code(400).send({ error: 'bad_request', message: 'body invalido' });
    }

    const sets = [];
    const vals = [];
    let p = 1;

    if (Object.prototype.hasOwnProperty.call(body, 'link_menu')) {
      const r = parseLinkMenu(body.link_menu);
      if (!r.ok) {
        return reply.code(400).send({ error: 'bad_request', message: r.error });
      }
      sets.push(`link_menu = $${p++}`);
      vals.push(r.value);
    }
    if (Object.prototype.hasOwnProperty.call(body, 'mostrar_menu')) {
      const r = parseMostrarMenu(body.mostrar_menu);
      if (!r.ok) {
        return reply.code(400).send({ error: 'bad_request', message: r.error });
      }
      sets.push(`mostrar_menu = $${p++}`);
      vals.push(r.value);
    }

    if (sets.length === 0) {
      return reply.code(400).send({ error: 'bad_request', message: 'ningun campo para actualizar' });
    }

    vals.push(rid);
    await ctx.pgPool.query(
      `UPDATE tombot.restaurantes
          SET ${sets.join(', ')}, updated_at = NOW()
        WHERE id = $${p}`,
      vals
    );

    const { rows } = await ctx.pgPool.query(
      `SELECT link_menu, mostrar_menu FROM tombot.restaurantes WHERE id = $1`,
      [rid]
    );
    const out = rows[0] || { link_menu: null, mostrar_menu: true };
    return { link_menu: out.link_menu, mostrar_menu: out.mostrar_menu };
  });
}
