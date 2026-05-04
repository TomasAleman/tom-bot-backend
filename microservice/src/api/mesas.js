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

const HORARIO_REGEX = /^\d{1,2}-\d{1,2}$/;

const MesaShapeSchema = z.object({
  numero_mesa: z.string().trim().min(1).max(20),
  min_personas: z.number().int().min(0).max(50),
  max_personas: z.number().int().min(1).max(100),
  horario_manana: z.string().regex(HORARIO_REGEX).nullable().optional(),
  horario_mediodia: z.string().regex(HORARIO_REGEX).nullable().optional(),
  horario_tarde: z.string().regex(HORARIO_REGEX).nullable().optional(),
  activa: z.boolean().optional().default(true),
});

const MesaCreateSchema = MesaShapeSchema.refine((d) => d.max_personas >= d.min_personas, {
  message: 'max_personas debe ser >= min_personas',
});

const MesaUpdateSchema = MesaShapeSchema.partial()
  .refine((d) => Object.keys(d).length > 0, { message: 'al menos un campo es requerido' })
  .refine(
    (d) =>
      d.max_personas === undefined ||
      d.min_personas === undefined ||
      d.max_personas >= d.min_personas,
    { message: 'max_personas debe ser >= min_personas' }
  );

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

  fastify.post('/', async (req, reply) => {
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

  fastify.patch('/:id', async (req, reply) => {
    const id = Number(req.params.id);
    if (!Number.isInteger(id) || id <= 0) {
      return reply.code(400).send({ error: 'bad_request' });
    }
    const parsed = MesaUpdateSchema.safeParse(req.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'bad_request', issues: parsed.error.issues });
    }

    const fields = parsed.data;
    const sets = [];
    const params = [req.user.restaurante_id, id];
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

  fastify.delete('/:id', async (req, reply) => {
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
