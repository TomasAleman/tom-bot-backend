/**
 * /api/sesiones — read-only de tombot.sesiones (estado de conversaciones activas).
 *
 * GET / -> lista paginada con filtros básicos.
 */

import { z } from 'zod';
import { authHook } from '../middleware/auth.js';

const ListQuery = z.object({
  q: z.string().trim().max(120).optional(),
  bloqueadas: z.enum(['si', 'no']).optional(),
  page: z.coerce.number().int().min(1).default(1),
  page_size: z.coerce.number().int().min(1).max(200).default(50),
});

export async function registerSesionesRoutes(fastify, ctx) {
  fastify.addHook('preHandler', authHook);

  fastify.get('/', async (req, reply) => {
    const parsed = ListQuery.safeParse(req.query);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'bad_request', issues: parsed.error.issues });
    }
    const f = parsed.data;
    const restauranteId = req.user.restaurante_id;

    const where = ['s.restaurante_id = $1'];
    const params = [restauranteId];
    let i = 2;

    if (f.q) {
      where.push(`s.telefono ILIKE $${i++}`);
      params.push(`%${f.q}%`);
    }
    if (f.bloqueadas === 'si') {
      where.push('s.bloqueo_hasta IS NOT NULL AND s.bloqueo_hasta > NOW()');
    } else if (f.bloqueadas === 'no') {
      where.push('(s.bloqueo_hasta IS NULL OR s.bloqueo_hasta <= NOW())');
    }

    const whereSql = `WHERE ${where.join(' AND ')}`;
    const offset   = (f.page - 1) * f.page_size;

    const dataSql = `
      SELECT s.telefono, s.primer_contacto, s.contexto_reserva,
             s.contador_mensajes, s.bloqueo_hasta, s.bloqueo_minutos,
             s.ultimo_mensaje_at
        FROM tombot.sesiones s
        ${whereSql}
        ORDER BY s.ultimo_mensaje_at DESC
        LIMIT $${i++} OFFSET $${i++}`;
    const dataParams = params.concat([f.page_size, offset]);

    const countSql = `SELECT COUNT(*)::int AS total FROM tombot.sesiones s ${whereSql}`;

    const [data, count] = await Promise.all([
      ctx.pgPool.query(dataSql, dataParams),
      ctx.pgPool.query(countSql, params),
    ]);

    return {
      data: data.rows,
      meta: { page: f.page, page_size: f.page_size, total: count.rows[0].total },
    };
  });
}
