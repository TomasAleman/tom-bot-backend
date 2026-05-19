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
import { requireRestaurante, requireWriteAccess } from '../middleware/authz.js';

/** Cadenas vacías en query → undefined (URLs con `dia_desde=` etc. no rompen Zod). */
function queryStringOrUndef(v) {
  if (v === undefined || v === null) return undefined;
  if (typeof v === 'string' && v.trim() === '') return undefined;
  return v;
}

function queryTrimmedOrUndef(v) {
  if (v === undefined || v === null) return undefined;
  const s = String(v).trim();
  return s === '' ? undefined : s;
}

const ListQuery = z.object({
  dia_desde: z.preprocess(queryStringOrUndef, z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional()),
  dia_hasta: z.preprocess(queryStringOrUndef, z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional()),
  estado: z.preprocess(queryStringOrUndef, z.enum(['Confirmada', 'Cancelada', 'NoShow']).optional()),
  q: z.preprocess(queryTrimmedOrUndef, z.string().max(120).optional()),
  page: z.coerce.number().int().min(1).default(1),
  page_size: z.coerce.number().int().min(1).max(200).default(50),
  order: z.enum(['dia_asc', 'dia_desc', 'creada_desc']).default('dia_asc'),
});

const PatchSchema = z.object({
  nombre: z.string().trim().min(1).max(120).optional(),
  personas: z.number().int().min(1).max(50).optional(),
  dia: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
  /** Minutos 0-1439, o "HH:MM" 24h. Numero 0-23 = hora en punto (compat panel viejo). */
  horario: z.union([
    z.number().int().min(0).max(1439),
    z.string().regex(/^\d{1,2}:\d{2}$/),
  ]).optional(),
  /** Solo junte (≥2 mesas): una sola llamada atómica con fn_modificar_reserva_junte. */
  mesas: z.array(z.string().trim().min(1).max(20)).min(2).max(20).optional(),
  /** Una mesa explícita (ej. grupo menor al mínimo de mesas libres): requiere dia/horario/personas coherentes. */
  numero_mesa: z.string().trim().min(1).max(20).optional(),
}).refine((d) => Object.keys(d).length > 0, { message: 'al menos un campo es requerido' })
  .refine((d) => !(d.numero_mesa && d.mesas?.length), {
    message: 'no combinar numero_mesa con mesas (junte)',
  });

const DisponibilidadQuery = z.object({
  dia: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  personas: z.coerce.number().int().min(1).max(50),
  exclude_reserva_id: z.coerce.number().int().positive().optional(),
});

const CrearReservaSchema = z.object({
  nombre: z.string().trim().min(1).max(120),
  telefono: z.string().trim().min(6).max(40),
  dia: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  /** Minutos 0-1439, o "HH:MM" 24h. */
  horario: z.union([
    z.number().int().min(0).max(1439),
    z.string().regex(/^\d{1,2}:\d{2}$/),
  ]),
  personas: z.coerce.number().int().min(1).max(50),
  /** Solo admin (requireWriteAccess): junte = al menos 2 mesas. */
  mesas: z.array(z.string().trim().min(1).max(20)).min(2).max(20).optional(),
  /** Mesa explícita cuando el grupo es menor al mínimo de las mesas libres (no junte). */
  numero_mesa: z.string().trim().min(1).max(20).optional(),
}).refine((d) => !(d.numero_mesa && d.mesas?.length), {
  message: 'no combinar numero_mesa con mesas (junte)',
});

const MesasLibresQuery = z.object({
  dia: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  horario: z.union([
    z.coerce.number().int().min(0).max(1439),
    z.string().regex(/^\d{1,2}:\d{2}$/),
  ]),
  exclude_reserva_id: z.coerce.number().int().positive().optional(),
});

function buildOrderBy(order) {
  switch (order) {
    case 'dia_desc': return 'r.dia DESC, r.horario_hora DESC, r.id DESC';
    case 'creada_desc': return 'r.created_at DESC, r.id DESC';
    default: return 'r.dia ASC, r.horario_hora ASC, r.id ASC';
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
    `SELECT r.id, r.restaurante_id, r.nombre, r.telefono, r.dia, r.horario_hora,
            r.horario_label, r.turno, r.personas, r.numero_mesa, r.estado,
            r.created_at, r.updated_at,
            COALESCE(
              (SELECT array_agg(rm.numero_mesa ORDER BY rm.numero_mesa)
                 FROM tombot.reserva_mesas rm
                WHERE rm.reserva_id = r.id),
              ARRAY[r.numero_mesa]::text[]
            ) AS mesas
       FROM tombot.reservas r
      WHERE r.restaurante_id = $1 AND r.id = $2
      LIMIT 1`,
    [restauranteId, id]
  );
  return rows[0] || null;
}

function parseTurnoBounds(turnoStr) {
  if (!turnoStr) return null;
  const mm = String(turnoStr).match(/^\s*(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})\s*$/);
  if (!mm) return null;
  const sh = parseInt(mm[1], 10);
  const sm = parseInt(mm[2], 10);
  const eh = parseInt(mm[3], 10);
  const em = parseInt(mm[4], 10);
  if (sh < 0 || sh > 23 || eh < 0 || eh > 23) return null;
  if (sm < 0 || sm > 59 || em < 0 || em > 59) return null;
  const start = sh * 60 + sm;
  const end = eh * 60 + em;
  if (end === start) return null;
  return { start, end, crossesMidnight: end < start };
}

/** Misma semántica que tombot.fn_hora_en_turno (inicio inclusivo, fin exclusivo). */
function horaEnTurno(horarioMin, start, end) {
  if (end > start) return horarioMin >= start && horarioMin < end;
  return horarioMin >= start || horarioMin < end;
}

function enumerateTurnoMinutes(bounds) {
  const out = [];
  if (!bounds) return out;
  const { start, end, crossesMidnight } = bounds;
  if (!crossesMidnight) {
    for (let v = start; v < end; v += 15) out.push(v);
    return out;
  }
  for (let v = start; v < 1440; v += 15) out.push(v);
  for (let v = 0; v < end; v += 15) out.push(v);
  return out;
}

function hhmmToMin(raw) {
  const m = String(raw || '').trim().match(/^(\d{1,2}):(\d{2})$/);
  if (!m) return null;
  const h = parseInt(m[1], 10);
  const mi = parseInt(m[2], 10);
  if (h < 0 || h > 23 || mi < 0 || mi > 59) return null;
  return h * 60 + mi;
}

/** Fecha YYYY-MM-DD desde valor PG (Date o string). */
function diaIsoFromRow(d) {
  if (d == null) return null;
  const s = String(d);
  return s.length >= 10 ? s.slice(0, 10) : s;
}

/** Minutos 0–1439 desde body (POST/PATCH): número 0–23 = hora en punto. */
function horarioBodyToMinutos(raw) {
  if (typeof raw === 'number') return raw <= 23 ? raw * 60 : raw;
  return hhmmToMin(raw);
}

/** Mesas libres: mismo criterio que GET /disponibilidad/mesas-libres. */
async function fetchMesasLibresInternal(pool, restauranteId, diaIso, horarioMin, excludeReservaId) {
  const { rows } = await pool.query(
    `SELECT m.numero_mesa, m.min_personas, m.max_personas
       FROM tombot.mesas m
      WHERE m.restaurante_id = $1
        AND m.activa = TRUE
        AND (
             (m.horario_manana   IS NOT NULL AND tombot.fn_hora_en_turno($3::INT, m.horario_manana))
          OR (m.horario_mediodia IS NOT NULL AND tombot.fn_hora_en_turno($3::INT, m.horario_mediodia))
          OR (m.horario_tarde    IS NOT NULL AND tombot.fn_hora_en_turno($3::INT, m.horario_tarde))
        )
        AND NOT EXISTS (
             SELECT 1
               FROM tombot.reservas r
              WHERE r.restaurante_id = $1
                AND r.dia = $2::DATE
                AND lower(trim(r.estado)) = 'confirmada'
                AND ($4::bigint IS NULL OR r.id <> $4::bigint)
                AND tombot.fn_misma_franja(
                      $3::INT,
                      r.horario_hora,
                      m.horario_manana,
                      m.horario_mediodia,
                      m.horario_tarde
                    )
                AND (
                     r.numero_mesa = m.numero_mesa
                  OR EXISTS (
                         SELECT 1
                           FROM tombot.reserva_mesas rm
                          WHERE rm.reserva_id = r.id
                            AND rm.numero_mesa = m.numero_mesa
                     )
                )
        )
      ORDER BY m.numero_mesa ASC`,
    [restauranteId, diaIso, horarioMin, excludeReservaId ?? null]
  );
  return rows;
}

async function resolverTurnoYLabel(pool, restauranteId, horarioMin) {
  const { rows: mesasRows } = await pool.query(
    `SELECT horario_manana, horario_mediodia, horario_tarde
       FROM tombot.mesas
      WHERE restaurante_id = $1 AND activa = TRUE`,
    [restauranteId]
  );
  const turnosSet = new Set();
  for (const m of mesasRows) {
    if (m.horario_manana) turnosSet.add(m.horario_manana);
    if (m.horario_mediodia) turnosSet.add(m.horario_mediodia);
    if (m.horario_tarde) turnosSet.add(m.horario_tarde);
  }
  const turnos = [...turnosSet].sort();
  const turno = turnos.find((t) => {
    const b = parseTurnoBounds(t);
    return b && horaEnTurno(horarioMin, b.start, b.end);
  }) || null;
  if (!turno) return { turno: null, horarioLabel: null };
  const { rows: labelRows } = await pool.query(
    `SELECT regexp_replace(tombot.fn_horario_label_desde_minutos($1::int), 'hs$', '') AS label`,
    [horarioMin]
  );
  return {
    turno,
    horarioLabel: labelRows?.[0]?.label ?? null,
  };
}

export async function registerReservasRoutes(fastify, ctx) {
  fastify.addHook('preHandler', authHook);

  fastify.get('/disponibilidad', { preHandler: requireRestaurante }, async (req, reply) => {
    const parsed = DisponibilidadQuery.safeParse(req.query);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'bad_request', issues: parsed.error.issues });
    }
    const { dia, personas, exclude_reserva_id: excludeReservaId } = parsed.data;
    const restauranteId = req.user.restaurante_id;

    const { rows: mesasRows } = await ctx.pgPool.query(
      `SELECT horario_manana, horario_mediodia, horario_tarde
         FROM tombot.mesas
        WHERE restaurante_id = $1 AND activa = TRUE`,
      [restauranteId]
    );

    const turnosSet = new Set();
    for (const m of mesasRows) {
      if (m.horario_manana) turnosSet.add(m.horario_manana);
      if (m.horario_mediodia) turnosSet.add(m.horario_mediodia);
      if (m.horario_tarde) turnosSet.add(m.horario_tarde);
    }
    const turnos = [...turnosSet].sort();

    const minutesSet = new Set();
    for (const t of turnos) {
      const b = parseTurnoBounds(t);
      if (!b) continue;
      for (const v of enumerateTurnoMinutes(b)) minutesSet.add(v);
    }
    const minutes = [...minutesSet].sort((a, b) => a - b);

    if (minutes.length === 0) {
      return { horarios: [], turnos };
    }

    const { rows } = await ctx.pgPool.query(
      `
      WITH mins AS (
        SELECT unnest($1::int[]) AS min
      )
      SELECT
        mins.min AS valor,
        regexp_replace(tombot.fn_horario_label_desde_minutos(mins.min), 'hs$', '') AS label
      FROM mins
      WHERE (
        EXISTS (
        SELECT 1
          FROM tombot.mesas m
         WHERE m.restaurante_id = $2
           AND m.activa = TRUE
           AND $3 BETWEEN m.min_personas AND m.max_personas
           AND (
                (m.horario_manana   IS NOT NULL AND tombot.fn_hora_en_turno(mins.min, m.horario_manana))
             OR (m.horario_mediodia IS NOT NULL AND tombot.fn_hora_en_turno(mins.min, m.horario_mediodia))
             OR (m.horario_tarde    IS NOT NULL AND tombot.fn_hora_en_turno(mins.min, m.horario_tarde))
           )
           AND NOT EXISTS (
            SELECT 1
              FROM tombot.reservas r2
             WHERE r2.restaurante_id = $2
               AND r2.dia = $4::date
               AND lower(r2.estado) = 'confirmada'
               AND ($5::bigint IS NULL OR r2.id <> $5::bigint)
               AND tombot.fn_misma_franja(
                     mins.min,
                     r2.horario_hora,
                     m.horario_manana,
                     m.horario_mediodia,
                     m.horario_tarde
                   )
               AND (
                    r2.numero_mesa = m.numero_mesa
                 OR EXISTS (
                        SELECT 1
                          FROM tombot.reserva_mesas rm
                         WHERE rm.reserva_id = r2.id
                           AND rm.numero_mesa = m.numero_mesa
                    )
               )
           )
         LIMIT 1
      )
        OR tombot.fn_suma_capacidad_mesas_libres($2, $4::date, mins.min, $5::bigint) >= $3
      )
      ORDER BY mins.min ASC
      `,
      [minutes, restauranteId, personas, dia, excludeReservaId ?? null]
    );

    return { horarios: rows.map((r) => ({ valor: Number(r.valor), label: r.label })), turnos };
  });

  fastify.get('/disponibilidad/mesas-libres', { preHandler: [requireWriteAccess, requireRestaurante] }, async (req, reply) => {
    const parsed = MesasLibresQuery.safeParse(req.query);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'bad_request', issues: parsed.error.issues });
    }
    const { dia, exclude_reserva_id: excludeReservaId } = parsed.data;
    let horarioMin = null;
    if (typeof parsed.data.horario === 'number') horarioMin = parsed.data.horario;
    else horarioMin = hhmmToMin(parsed.data.horario);
    if (horarioMin == null || !Number.isFinite(horarioMin) || horarioMin < 0 || horarioMin > 1439) {
      return reply.code(400).send({ error: 'bad_request', message: 'horario invalido' });
    }
    const restauranteId = req.user.restaurante_id;

    const rows = await fetchMesasLibresInternal(ctx.pgPool, restauranteId, dia, horarioMin, excludeReservaId);

    return { mesas: rows };
  });

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
             r.turno, r.personas, r.numero_mesa, r.estado, r.created_at, r.updated_at,
             COALESCE(
               (SELECT array_agg(rm.numero_mesa ORDER BY rm.numero_mesa)
                  FROM tombot.reserva_mesas rm
                 WHERE rm.reserva_id = r.id),
               ARRAY[r.numero_mesa]::text[]
             ) AS mesas
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

  fastify.patch('/:id', { preHandler: requireWriteAccess }, async (req, reply) => {
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
    const mesasJunte = updates.mesas;

    if (mesasJunte && mesasJunte.length >= 2) {
      const diaIso = updates.dia ?? diaIsoFromRow(existing.dia);
      if (!diaIso) {
        return reply.code(400).send({ error: 'bad_request', message: 'dia requerido o inválido' });
      }
      const personas = updates.personas ?? Number(existing.personas);

      let horarioMin = null;
      if (updates.horario !== undefined) {
        if (typeof updates.horario === 'number') {
          horarioMin = updates.horario <= 23 ? updates.horario * 60 : updates.horario;
        } else {
          horarioMin = hhmmToMin(updates.horario);
        }
      } else {
        horarioMin = Number(existing.horario_hora);
      }
      if (horarioMin == null || !Number.isFinite(horarioMin) || horarioMin < 0 || horarioMin > 1439) {
        return reply.code(400).send({ error: 'bad_request', message: 'horario invalido' });
      }

      const { rows: mesasRows } = await ctx.pgPool.query(
        `SELECT horario_manana, horario_mediodia, horario_tarde
           FROM tombot.mesas
          WHERE restaurante_id = $1 AND activa = TRUE`,
        [restauranteId]
      );
      const turnosSet = new Set();
      for (const m of mesasRows) {
        if (m.horario_manana) turnosSet.add(m.horario_manana);
        if (m.horario_mediodia) turnosSet.add(m.horario_mediodia);
        if (m.horario_tarde) turnosSet.add(m.horario_tarde);
      }
      const turnos = [...turnosSet].sort();
      const turno = turnos.find((t) => {
        const b = parseTurnoBounds(t);
        return b && horaEnTurno(horarioMin, b.start, b.end);
      }) || null;

      if (!turno) {
        return reply.code(400).send({ error: 'bad_request', message: 'horario fuera de los turnos configurados' });
      }

      const { rows: labelRows } = await ctx.pgPool.query(
        `SELECT regexp_replace(tombot.fn_horario_label_desde_minutos($1::int), 'hs$', '') AS label`,
        [horarioMin]
      );
      const horarioLabel = labelRows?.[0]?.label || null;

      const nombreSql = updates.nombre !== undefined ? String(updates.nombre).trim() : null;

      const { rows } = await ctx.pgPool.query(
        `SELECT id, restaurante_id, nombre, telefono, dia, horario_hora,
                horario_label, turno, personas, numero_mesa, estado
           FROM tombot.fn_modificar_reserva_junte($1::bigint, $2::date, $3::int, $4::text, $5::text, $6::int, $7::text[], $8::text)`,
        [id, diaIso, horarioMin, horarioLabel, turno, personas, mesasJunte, nombreSql]
      );
      if (rows.length === 0) {
        return reply.code(409).send({
          error: 'sin_disponibilidad',
          message: 'no fue posible aplicar el junte de mesas (cupos, horario o mesas inválidas)',
        });
      }
      const row = rows[0];
      if (Number(row.restaurante_id) !== Number(restauranteId)) {
        return reply.code(403).send({ error: 'forbidden' });
      }

      await logEvent(ctx, restauranteId, 'panel_reserva_editada_junte', {
        reserva_id: id,
        cambios: updates,
        por_usuario: req.user.usuario_id,
      });

      const full = await fetchReserva(ctx, restauranteId, id);
      return { reserva: { ...full, id: Number(full.id) } };
    }

    if (updates.numero_mesa !== undefined) {
      const numeroMesa = String(updates.numero_mesa || '').trim();
      if (!numeroMesa) {
        return reply.code(400).send({ error: 'bad_request', message: 'numero_mesa invalido' });
      }
      const diaIso = updates.dia ?? diaIsoFromRow(existing.dia);
      if (!diaIso) {
        return reply.code(400).send({ error: 'bad_request', message: 'dia requerido o inválido' });
      }

      let horarioMin;
      if (updates.horario !== undefined) {
        horarioMin = horarioBodyToMinutos(updates.horario);
      } else {
        horarioMin = Number(existing.horario_hora);
      }
      if (horarioMin == null || !Number.isFinite(horarioMin) || horarioMin < 0 || horarioMin > 1439) {
        return reply.code(400).send({ error: 'bad_request', message: 'horario invalido' });
      }

      const personas = updates.personas !== undefined ? Number(updates.personas) : Number(existing.personas);
      const nombreFinal = updates.nombre !== undefined
        ? String(updates.nombre).trim()
        : String(existing.nombre || '').trim();

      const { turno, horarioLabel } = await resolverTurnoYLabel(ctx.pgPool, restauranteId, horarioMin);
      if (!turno) {
        return reply.code(400).send({ error: 'bad_request', message: 'horario fuera de los turnos configurados' });
      }

      const libres = await fetchMesasLibresInternal(ctx.pgPool, restauranteId, diaIso, horarioMin, id);
      const elegida = libres.find((m) => String(m.numero_mesa) === numeroMesa);
      if (!elegida) {
        return reply.code(409).send({
          error: 'sin_disponibilidad',
          message: 'esa mesa no está libre en el horario elegido o no existe',
        });
      }
      if (personas > Number(elegida.max_personas)) {
        return reply.code(400).send({
          error: 'bad_request',
          message: `el máximo de la mesa ${numeroMesa} es ${elegida.max_personas} personas`,
        });
      }

      const client = await ctx.pgPool.connect();
      try {
        await client.query('BEGIN');
        await client.query('DELETE FROM tombot.reserva_mesas WHERE reserva_id = $1', [id]);
        const { rows: upRows } = await client.query(
          `UPDATE tombot.reservas r
              SET dia = $3::DATE,
                  horario_hora = $4::INT,
                  horario_label = $5,
                  turno = $6,
                  personas = $7::INT,
                  numero_mesa = $8,
                  nombre = $9,
                  updated_at = now()
             FROM tombot.mesas mt
            WHERE r.id = $1
              AND r.restaurante_id = $2
              AND r.estado = 'Confirmada'
              AND mt.restaurante_id = r.restaurante_id
              AND mt.numero_mesa = $8
              AND mt.activa = TRUE
              AND NOT EXISTS (
                SELECT 1
                  FROM tombot.reservas r2
                 WHERE r2.restaurante_id = r.restaurante_id
                   AND r2.dia = $3::DATE
                   AND lower(trim(r2.estado)) = 'confirmada'
                   AND r2.id <> r.id
                   AND tombot.fn_misma_franja(
                     $4::INT,
                     r2.horario_hora,
                     mt.horario_manana,
                     mt.horario_mediodia,
                     mt.horario_tarde
                   )
                   AND (
                     r2.numero_mesa = $8
                     OR EXISTS (
                       SELECT 1
                         FROM tombot.reserva_mesas rm
                        WHERE rm.reserva_id = r2.id
                          AND rm.numero_mesa = $8
                     )
                   )
              )
            RETURNING r.id`,
          [id, restauranteId, diaIso, horarioMin, horarioLabel, turno, personas, numeroMesa, nombreFinal]
        );
        if (upRows.length === 0) {
          await client.query('ROLLBACK');
          return reply.code(409).send({
            error: 'sin_disponibilidad',
            message: 'no se pudo asignar la mesa (ocupada o conflicto de concurrencia)',
          });
        }
        await client.query('COMMIT');
      } catch (e) {
        try { await client.query('ROLLBACK'); } catch (_) { /* ignore */ }
        throw e;
      } finally {
        client.release();
      }

      await logEvent(ctx, restauranteId, 'panel_reserva_editada_mesa_explicita', {
        reserva_id: id,
        cambios: updates,
        por_usuario: req.user.usuario_id,
      });

      const full = await fetchReserva(ctx, restauranteId, id);
      return { reserva: { ...full, id: Number(full.id) } };
    }

    let last = null;

    for (const [campo, valor] of Object.entries(updates)) {
      let valorTxt = String(valor);
      if (campo === 'horario') {
        if (typeof valor === 'number') {
          valorTxt = valor <= 23 ? String(valor * 60) : String(valor);
        } else {
          const parts = String(valor).split(':');
          const h = parseInt(parts[0], 10);
          const mi = parseInt(parts[1], 10);
          valorTxt = String(h * 60 + mi);
        }
      }
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

  fastify.post('/', { preHandler: [requireWriteAccess, requireRestaurante] }, async (req, reply) => {
    const parsed = CrearReservaSchema.safeParse(req.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'bad_request', issues: parsed.error.issues });
    }

    const restauranteId = req.user.restaurante_id;
    const body = parsed.data;
    const personas = Number(body.personas);
    const telefono = String(body.telefono || '').trim();
    const nombre = String(body.nombre || '').trim();
    const mesasJunte = Array.isArray(body.mesas) && body.mesas.length >= 2 ? body.mesas : null;
    const numeroMesaPref = body.numero_mesa ? String(body.numero_mesa).trim() : null;

    const horarioMin = horarioBodyToMinutos(body.horario);
    if (horarioMin == null || !Number.isFinite(horarioMin) || horarioMin < 0 || horarioMin > 1439) {
      return reply.code(400).send({ error: 'bad_request', message: 'horario invalido' });
    }

    const { turno, horarioLabel } = await resolverTurnoYLabel(ctx.pgPool, restauranteId, horarioMin);
    if (!turno) {
      return reply.code(400).send({ error: 'bad_request', message: 'horario fuera de los turnos configurados' });
    }

    if (mesasJunte) {
      const { rows: jRows } = await ctx.pgPool.query(
        `SELECT id_reserva, numero_mesa
           FROM tombot.fn_confirmar_reserva_junte($1, $2, $3, $4::DATE, $5::INT, $6, $7, $8::INT, $9::text[])`,
        [restauranteId, nombre, telefono, body.dia, horarioMin, horarioLabel, turno, personas, mesasJunte]
      );
      const idReserva = jRows?.[0]?.id_reserva ? Number(jRows[0].id_reserva) : null;
      if (!idReserva) {
        return reply.code(409).send({
          error: 'sin_disponibilidad',
          message: 'no se pudo confirmar el junte de mesas (cupos u horario)',
        });
      }
      const reserva = await fetchReserva(ctx, restauranteId, idReserva);
      await logEvent(ctx, restauranteId, 'panel_reserva_creada_junte', {
        reserva_id: idReserva,
        mesas: mesasJunte,
        por_usuario: req.user.usuario_id,
      });
      return reply.code(201).send({ reserva: { ...reserva, id: Number(reserva.id) } });
    }

    if (numeroMesaPref) {
      const libres = await fetchMesasLibresInternal(ctx.pgPool, restauranteId, body.dia, horarioMin, null);
      const elegida = libres.find((m) => String(m.numero_mesa) === numeroMesaPref);
      if (!elegida) {
        return reply.code(409).send({
          error: 'sin_disponibilidad',
          message: 'esa mesa no está libre en el horario elegido o no existe',
        });
      }
      if (personas > Number(elegida.max_personas)) {
        return reply.code(400).send({
          error: 'bad_request',
          message: `el máximo de la mesa ${numeroMesaPref} es ${elegida.max_personas} personas`,
        });
      }

      const { rows: confRows } = await ctx.pgPool.query(
        `SELECT id_reserva, numero_mesa
           FROM tombot.fn_confirmar_reserva($1, $2, $3, $4::DATE, $5::INT, $6, $7, $8::INT, $9)`,
        [restauranteId, nombre, telefono, body.dia, horarioMin, horarioLabel, turno, personas, numeroMesaPref]
      );
      const idReserva = confRows?.[0]?.id_reserva ? Number(confRows[0].id_reserva) : null;
      if (!idReserva) {
        return reply.code(409).send({
          error: 'sin_disponibilidad',
          message: 'no hay mesa disponible (conflicto de concurrencia)',
        });
      }
      const reserva = await fetchReserva(ctx, restauranteId, idReserva);
      await logEvent(ctx, restauranteId, 'panel_reserva_creada_mesa_explicita', {
        reserva_id: idReserva,
        numero_mesa: numeroMesaPref,
        por_usuario: req.user.usuario_id,
      });
      return reply.code(201).send({ reserva: { ...reserva, id: Number(reserva.id) } });
    }

    const { rows: mesaRows } = await ctx.pgPool.query(
      `SELECT numero_mesa, turnos_alternativos
         FROM tombot.fn_buscar_mesa_disponible($1, $2::DATE, $3::INT, $4, $5::INT)`,
      [restauranteId, body.dia, horarioMin, turno, personas]
    );
    const mesaCand = mesaRows?.[0]?.numero_mesa || null;
    const turnosAlt = mesaRows?.[0]?.turnos_alternativos || [];

    if (!mesaCand) {
      return reply.code(409).send({
        error: 'sin_disponibilidad',
        message: 'no hay mesa disponible para ese día/horario/personas',
        turnos_alternativos: turnosAlt,
      });
    }

    const { rows: confRows } = await ctx.pgPool.query(
      `SELECT id_reserva, numero_mesa
         FROM tombot.fn_confirmar_reserva($1, $2, $3, $4::DATE, $5::INT, $6, $7, $8::INT, $9)`,
      [restauranteId, nombre, telefono, body.dia, horarioMin, horarioLabel, turno, personas, mesaCand]
    );
    const idReserva = confRows?.[0]?.id_reserva ? Number(confRows[0].id_reserva) : null;
    if (!idReserva) {
      return reply.code(409).send({
        error: 'sin_disponibilidad',
        message: 'no hay mesa disponible (conflicto de concurrencia)',
      });
    }

    const reserva = await fetchReserva(ctx, restauranteId, idReserva);
    await logEvent(ctx, restauranteId, 'panel_reserva_creada', {
      reserva_id: idReserva,
      por_usuario: req.user.usuario_id,
    });

    return reply.code(201).send({ reserva: { ...reserva, id: Number(reserva.id) } });
  });

  fastify.post('/:id/cancelar', { preHandler: requireWriteAccess }, async (req, reply) => {
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

  // Recepcionista puede marcar inasistencia; editar/cancelar siguen con requireWriteAccess.
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
