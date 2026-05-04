/**
 * /api/reservas
 *
 * GET    /                  -> lista paginada con filtros
 * GET    /:id               -> detalle
 * PATCH  /:id               -> editar (nombre / personas / dia / horario) usando fn_modificar_reserva
 * POST   /:id/cancelar      -> estado = 'Cancelada'
 * POST   /:id/no-show       -> estado = 'NoShow'
 *
 * Todas filtran SIEMPRE por req.user.restaurante_id.
 */

import { z } from 'zod';
import { authHook } from '../middleware/auth.js';

const ListQuery = z.object({
  dia_desde: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
  dia_hasta: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
  estado: z.enum(['Confirmada', 'Cancelada', 'NoShow']).optional(),
  q: z.string().trim().max(120).optional(),
  page: z.coerce.number().int().min(1).default(1),
  page_size: z.coerce.number().int().min(1).max(200).default(50),
  order: z.enum(['dia_asc', 'dia_desc', 'creada_desc']).default('dia_asc'),
});

const PatchSchema = z.object({
  nombre: z.string().trim().min(1).max(120).optional(),
  personas: z.number().int().min(1).max(50).optional(),
  dia: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
  horario: z.number().int().min(0).max(23).optional(),
}).refine((d) => Object.keys(d).length > 0, { message: 'al menos un campo es requerido' });

function buildOrderBy(order) {
  switch (order) {
    case 'dia_desc': return 'r.dia DESC, r.horario_hora DESC';
    case 'creada_desc': return 'r.created_at DESC';
    default: return 'r.dia ASC, r.horario_hora ASC';
  }
}

async function logEvent(ctx, restauranteId, tipo, payload) {
  try {
    await ctx.pgPool.query(
      `INSERT INTO tombot.eventos_log (restaurante_id, tipo_evento, payload)
       VALUES ($1, $2, $3::jsonb)`,
      [restauranteId, tipo, JSON.stringify(payload || {})]
    );
  } catch (err) {
    ctx.log.warn({ err, tipo }, 'no se pudo registrar evento');
  }
}

async function fetchReserva(ctx, restauranteId, id) {
  const { rows } = await ctx.pgPool.query(
    `SELECT id, restaurante_id, nombre, telefono, dia, horario_hora,
            horario_label, turno, personas, numero_mesa, estado,
            created_at, updated_at
       FROM tombot.reservas
      WHERE restaurante_id = $1 AND id = $2
      LIMIT 1`,
    [restauranteId, id]
  );
  return rows[0] || null;
}

export async function registerReservasRoutes(fastify, ctx) {
  fastify.addHook('preHandler', authHook);

  fastify.get('/', async (req, reply) => {
    const parsed = ListQuery.safeParse(req.query);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'bad_request', issues: parsed.error.issues });
    }
    const f = parsed.data;
    const restauranteId = req.user.restaurante_id;

    const where = ['r.restaurante_id = $1'];
    const params = [restauranteId];
    let i = 2;

    if (f.dia_desde) { where.push(`r.dia >= $${i++}::date`); params.push(f.dia_desde); }
    if (f.dia_hasta) { where.push(`r.dia <= $${i++}::date`); params.push(f.dia_hasta); }
    if (f.estado)    { where.push(`r.estado = $${i++}`);     params.push(f.estado); }
    if (f.q) {
      where.push(`(r.nombre ILIKE $${i} OR r.telefono ILIKE $${i})`);
      params.push(`%${f.q}%`);
      i++;
    }

    const whereSql = `WHERE ${where.join(' AND ')}`;
    const orderBy  = buildOrderBy(f.order);
    const offset   = (f.page - 1) * f.page_size;

    const dataSql = `
      SELECT r.id, r.nombre, r.telefono, r.dia, r.horario_hora, r.horario_label,
             r.turno, r.personas, r.numero_mesa, r.estado, r.created_at, r.updated_at
        FROM tombot.reservas r
        ${whereSql}
        ORDER BY ${orderBy}
        LIMIT $${i++} OFFSET $${i++}`;
    const dataParams = params.concat([f.page_size, offset]);

    const countSql = `SELECT COUNT(*)::int AS total FROM tombot.reservas r ${whereSql}`;

    const [data, count] = await Promise.all([
      ctx.pgPool.query(dataSql, dataParams),
      ctx.pgPool.query(countSql, params),
    ]);

    return {
      data: data.rows.map((r) => ({ ...r, id: Number(r.id) })),
      meta: {
        page: f.page,
        page_size: f.page_size,
        total: count.rows[0].total,
      },
    };
  });

  fastify.get('/:id', async (req, reply) => {
    const id = Number(req.params.id);
    if (!Number.isInteger(id) || id <= 0) {
      return reply.code(400).send({ error: 'bad_request' });
    }
    const r = await fetchReserva(ctx, req.user.restaurante_id, id);
    if (!r) return reply.code(404).send({ error: 'not_found' });
    return { ...r, id: Number(r.id) };
  });

  fastify.patch('/:id', async (req, reply) => {
    const id = Number(req.params.id);
    if (!Number.isInteger(id) || id <= 0) {
      return reply.code(400).send({ error: 'bad_request' });
    }
    const parsed = PatchSchema.safeParse(req.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'bad_request', issues: parsed.error.issues });
    }

    const restauranteId = req.user.restaurante_id;
    const existing = await fetchReserva(ctx, restauranteId, id);
    if (!existing) return reply.code(404).send({ error: 'not_found' });
    if (existing.estado !== 'Confirmada') {
      return reply.code(409).send({ error: 'estado_invalido', message: 'solo se pueden editar reservas Confirmadas' });
    }

    const updates = parsed.data;
    let last = null;

    for (const [campo, valor] of Object.entries(updates)) {
      const valorTxt = String(valor);
      const { rows } = await ctx.pgPool.query(
        `SELECT id, restaurante_id, nombre, telefono, dia, horario_hora,
                horario_label, turno, personas, numero_mesa, estado
           FROM tombot.fn_modificar_reserva($1::bigint, $2::text, $3::text)`,
        [id, campo, valorTxt]
      );
      if (rows.length === 0) {
        return reply.code(409).send({
          error: 'sin_disponibilidad',
          message: `no fue posible aplicar el cambio "${campo}=${valorTxt}" (sin mesa disponible o reserva inexistente)`,
          campo,
          valor: valorTxt,
        });
      }
      const row = rows[0];
      if (Number(row.restaurante_id) !== Number(restauranteId)) {
        return reply.code(403).send({ error: 'forbidden' });
      }
      last = row;
    }

    await logEvent(ctx, restauranteId, 'panel_reserva_editada', {
      reserva_id: id,
      cambios: updates,
      por_usuario: req.user.usuario_id,
    });

    return { reserva: { ...last, id: Number(last.id) } };
  });

  fastify.post('/:id/cancelar', async (req, reply) => {
    const id = Number(req.params.id);
    if (!Number.isInteger(id) || id <= 0) {
      return reply.code(400).send({ error: 'bad_request' });
    }
    const restauranteId = req.user.restaurante_id;

    const { rows, rowCount } = await ctx.pgPool.query(
      `UPDATE tombot.reservas
          SET estado = 'Cancelada'
        WHERE restaurante_id = $1 AND id = $2 AND estado = 'Confirmada'
        RETURNING id, restaurante_id, nombre, telefono, dia, horario_hora,
                  horario_label, turno, personas, numero_mesa, estado, updated_at`,
      [restauranteId, id]
    );
    if (rowCount === 0) {
      const exists = await fetchReserva(ctx, restauranteId, id);
      if (!exists) return reply.code(404).send({ error: 'not_found' });
      return reply.code(409).send({ error: 'estado_invalido', message: 'la reserva no esta Confirmada' });
    }

    await logEvent(ctx, restauranteId, 'panel_reserva_cancelada', {
      reserva_id: id,
      por_usuario: req.user.usuario_id,
    });

    return { reserva: { ...rows[0], id: Number(rows[0].id) } };
  });

  fastify.post('/:id/no-show', async (req, reply) => {
    const id = Number(req.params.id);
    if (!Number.isInteger(id) || id <= 0) {
      return reply.code(400).send({ error: 'bad_request' });
    }
    const restauranteId = req.user.restaurante_id;

    const { rows, rowCount } = await ctx.pgPool.query(
      `UPDATE tombot.reservas
          SET estado = 'NoShow'
        WHERE restaurante_id = $1 AND id = $2 AND estado = 'Confirmada'
        RETURNING id, restaurante_id, nombre, telefono, dia, horario_hora,
                  horario_label, turno, personas, numero_mesa, estado, updated_at`,
      [restauranteId, id]
    );
    if (rowCount === 0) {
      const exists = await fetchReserva(ctx, restauranteId, id);
      if (!exists) return reply.code(404).send({ error: 'not_found' });
      return reply.code(409).send({ error: 'estado_invalido', message: 'la reserva no esta Confirmada' });
    }

    await logEvent(ctx, restauranteId, 'panel_reserva_noshow', {
      reserva_id: id,
      por_usuario: req.user.usuario_id,
    });

    return { reserva: { ...rows[0], id: Number(rows[0].id) } };
  });
}
