/**
 * /api/mesas — CRUD de tombot.mesas, siempre filtrado por restaurante_id del JWT.
 *
 * Reglas:
 * - No se permite cambiar el restaurante_id (se ignora si llega del cliente).
 * - El borrado no es físico: se hace UPDATE activa = FALSE para mantener historial.
 *   Para reactivar, se vuelve a hacer PATCH con activa: true.
 */

import { z } from 'zod';
import { authHook } from '../middleware/auth.js';
import { requireWriteAccess } from '../middleware/authz.js';

// Formato HH:MM-HH:MM (inicio inclusivo, fin exclusivo). El panel restringe a
// pasos de 15 min en la UI, pero la API acepta cualquier minuto valido.
const HORARIO_REGEX = /^([01]?\d|2[0-3]):[0-5]\d-([01]?\d|2[0-3]):[0-5]\d$/;

function turnoToMinutos(s) {
  if (!s) return null;
  if (!HORARIO_REGEX.test(s)) return null;
  const [ini, fin] = s.split('-');
  const [sh, sm] = ini.split(':').map((n) => parseInt(n, 10));
  const [eh, em] = fin.split(':').map((n) => parseInt(n, 10));
  return { startMin: sh * 60 + sm, endMin: eh * 60 + em };
}

function turnoValido(s) {
  if (s === null || s === undefined) return true;
  const r = turnoToMinutos(s);
  return Boolean(r) && r.endMin > r.startMin;
}

const MesaShapeBase = z.object({
  numero_mesa: z.string().trim().min(1).max(20),
  min_personas: z.number().int().min(0).max(50),
  max_personas: z.number().int().min(1).max(100),
  horario_manana: z.string().regex(HORARIO_REGEX).nullable().optional(),
  horario_mediodia: z.string().regex(HORARIO_REGEX).nullable().optional(),
  horario_tarde: z.string().regex(HORARIO_REGEX).nullable().optional(),
  activa: z.boolean().optional().default(true),
});

function tieneAlMenosUnTurno(d) {
  return Boolean(d?.horario_manana || d?.horario_mediodia || d?.horario_tarde);
}

const MesaCreateSchema = MesaShapeBase
  .refine((d) => d.max_personas >= d.min_personas, {
    message: 'max_personas debe ser >= min_personas',
  })
  .refine(tieneAlMenosUnTurno, {
    message: 'debe tener al menos un turno configurado',
  })
  .refine(
    (d) =>
      turnoValido(d.horario_manana) &&
      turnoValido(d.horario_mediodia) &&
      turnoValido(d.horario_tarde),
    { message: 'el fin de cada turno debe ser posterior al inicio' }
  );

const MesaUpdateSchema = MesaShapeBase.partial()
  .refine((d) => Object.keys(d).length > 0, { message: 'al menos un campo es requerido' })
  .refine(
    (d) =>
      d.max_personas === undefined ||
      d.min_personas === undefined ||
      d.max_personas >= d.min_personas,
    { message: 'max_personas debe ser >= min_personas' }
  )
  .refine(
    (d) =>
      turnoValido(d.horario_manana) &&
      turnoValido(d.horario_mediodia) &&
      turnoValido(d.horario_tarde),
    { message: 'el fin de cada turno debe ser posterior al inicio' }
  );

async function fetchMesa(ctx, restauranteId, id) {
  const { rows } = await ctx.pgPool.query(
    `SELECT id, restaurante_id, numero_mesa, min_personas, max_personas,
            horario_manana, horario_mediodia, horario_tarde,
            activa, created_at, updated_at
       FROM tombot.mesas
      WHERE restaurante_id = $1 AND id = $2
      LIMIT 1`,
    [restauranteId, id]
  );
  return rows[0] || null;
}

export async function registerMesasRoutes(fastify, ctx) {
  fastify.addHook('preHandler', authHook);

  fastify.get('/', async (req) => {
    const { rows } = await ctx.pgPool.query(
      `SELECT id, numero_mesa, min_personas, max_personas,
              horario_manana, horario_mediodia, horario_tarde,
              activa, created_at, updated_at
         FROM tombot.mesas
        WHERE restaurante_id = $1
        ORDER BY activa DESC, numero_mesa ASC`,
      [req.user.restaurante_id]
    );
    return { data: rows.map((m) => ({ ...m, id: Number(m.id) })) };
  });

  fastify.post('/', { preHandler: requireWriteAccess }, async (req, reply) => {
    const parsed = MesaCreateSchema.safeParse(req.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'bad_request', issues: parsed.error.issues });
    }
    const m = parsed.data;
    try {
      const { rows } = await ctx.pgPool.query(
        `INSERT INTO tombot.mesas
            (restaurante_id, numero_mesa, min_personas, max_personas,
             horario_manana, horario_mediodia, horario_tarde, activa)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
         RETURNING id, numero_mesa, min_personas, max_personas,
                   horario_manana, horario_mediodia, horario_tarde,
                   activa, created_at, updated_at`,
        [
          req.user.restaurante_id,
          m.numero_mesa,
          m.min_personas,
          m.max_personas,
          m.horario_manana || null,
          m.horario_mediodia || null,
          m.horario_tarde || null,
          m.activa,
        ]
      );
      return reply.code(201).send({ mesa: { ...rows[0], id: Number(rows[0].id) } });
    } catch (err) {
      if (err && err.code === '23505') {
        return reply.code(409).send({ error: 'duplicado', message: 'ya existe una mesa con ese numero' });
      }
      throw err;
    }
  });

  fastify.patch('/:id', { preHandler: requireWriteAccess }, async (req, reply) => {
    const id = Number(req.params.id);
    if (!Number.isInteger(id) || id <= 0) {
      return reply.code(400).send({ error: 'bad_request' });
    }
    const parsed = MesaUpdateSchema.safeParse(req.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'bad_request', issues: parsed.error.issues });
    }

    const fields = parsed.data;
    const restauranteId = req.user.restaurante_id;

    // Regla: una mesa debe tener al menos 1 turno. Como PATCH es parcial, necesitamos
    // validar el estado final (merge entre DB actual + fields).
    const quiereTocarTurnos = (
      Object.prototype.hasOwnProperty.call(fields, 'horario_manana') ||
      Object.prototype.hasOwnProperty.call(fields, 'horario_mediodia') ||
      Object.prototype.hasOwnProperty.call(fields, 'horario_tarde')
    );
    if (quiereTocarTurnos) {
      const existing = await fetchMesa(ctx, restauranteId, id);
      if (!existing) return reply.code(404).send({ error: 'not_found' });
      const merged = {
        horario_manana: Object.prototype.hasOwnProperty.call(fields, 'horario_manana')
          ? fields.horario_manana
          : existing.horario_manana,
        horario_mediodia: Object.prototype.hasOwnProperty.call(fields, 'horario_mediodia')
          ? fields.horario_mediodia
          : existing.horario_mediodia,
        horario_tarde: Object.prototype.hasOwnProperty.call(fields, 'horario_tarde')
          ? fields.horario_tarde
          : existing.horario_tarde,
      };
      if (!tieneAlMenosUnTurno(merged)) {
        return reply.code(400).send({
          error: 'bad_request',
          message: 'debe tener al menos un turno configurado',
        });
      }
    }

    const sets = [];
    const params = [restauranteId, id];
    let i = 3;
    for (const [k, v] of Object.entries(fields)) {
      sets.push(`${k} = $${i++}`);
      params.push(v === undefined ? null : v);
    }

    const { rows, rowCount } = await ctx.pgPool.query(
      `UPDATE tombot.mesas
          SET ${sets.join(', ')}
        WHERE restaurante_id = $1 AND id = $2
        RETURNING id, numero_mesa, min_personas, max_personas,
                  horario_manana, horario_mediodia, horario_tarde,
                  activa, created_at, updated_at`,
      params
    );
    if (rowCount === 0) return reply.code(404).send({ error: 'not_found' });
    return { mesa: { ...rows[0], id: Number(rows[0].id) } };
  });

  fastify.delete('/:id', { preHandler: requireWriteAccess }, async (req, reply) => {
    const id = Number(req.params.id);
    if (!Number.isInteger(id) || id <= 0) {
      return reply.code(400).send({ error: 'bad_request' });
    }
    const { rowCount } = await ctx.pgPool.query(
      `UPDATE tombot.mesas SET activa = FALSE
        WHERE restaurante_id = $1 AND id = $2`,
      [req.user.restaurante_id, id]
    );
    if (rowCount === 0) return reply.code(404).send({ error: 'not_found' });
    return reply.code(204).send();
  });
}
