/**
 * /api/metricas — KPIs para el dashboard.
 *
 * GET / -> {
 *   hoy:         { confirmadas, canceladas, no_show, personas },
 *   semana:      { confirmadas, canceladas, no_show, personas },
 *   mes:         { confirmadas, canceladas, no_show, personas },
 *   por_dia:     [{ dia, confirmadas, canceladas, no_show }, ...]   (ultimos 14 dias)
 *   proximas:    [{ ... }, ...]   (primeras 5 reservas Confirmadas futuras)
 * }
 *
 * Todo filtrado por req.user.restaurante_id, en la zona horaria del restaurante.
 */

import { authHook } from '../middleware/auth.js';

const SQL = `
WITH params AS (
  SELECT $1::bigint AS rid, COALESCE($2::text, 'UTC') AS tz
),
hoy_range AS (
  SELECT (NOW() AT TIME ZONE p.tz)::date AS hoy FROM params p
),
agg AS (
  SELECT
    SUM(CASE WHEN r.dia = h.hoy AND r.estado = 'Confirmada' THEN 1 ELSE 0 END)::int AS hoy_confirmadas,
    SUM(CASE WHEN r.dia = h.hoy AND r.estado = 'Cancelada'  THEN 1 ELSE 0 END)::int AS hoy_canceladas,
    SUM(CASE WHEN r.dia = h.hoy AND r.estado = 'NoShow'     THEN 1 ELSE 0 END)::int AS hoy_no_show,
    SUM(CASE WHEN r.dia = h.hoy AND r.estado = 'Confirmada' THEN r.personas ELSE 0 END)::int AS hoy_personas,

    SUM(CASE WHEN r.dia BETWEEN h.hoy AND h.hoy + INTERVAL '6 day' AND r.estado = 'Confirmada' THEN 1 ELSE 0 END)::int AS sem_confirmadas,
    SUM(CASE WHEN r.dia BETWEEN h.hoy AND h.hoy + INTERVAL '6 day' AND r.estado = 'Cancelada'  THEN 1 ELSE 0 END)::int AS sem_canceladas,
    SUM(CASE WHEN r.dia BETWEEN h.hoy AND h.hoy + INTERVAL '6 day' AND r.estado = 'NoShow'     THEN 1 ELSE 0 END)::int AS sem_no_show,
    SUM(CASE WHEN r.dia BETWEEN h.hoy AND h.hoy + INTERVAL '6 day' AND r.estado = 'Confirmada' THEN r.personas ELSE 0 END)::int AS sem_personas,

    SUM(CASE WHEN date_trunc('month', r.dia) = date_trunc('month', h.hoy) AND r.estado = 'Confirmada' THEN 1 ELSE 0 END)::int AS mes_confirmadas,
    SUM(CASE WHEN date_trunc('month', r.dia) = date_trunc('month', h.hoy) AND r.estado = 'Cancelada'  THEN 1 ELSE 0 END)::int AS mes_canceladas,
    SUM(CASE WHEN date_trunc('month', r.dia) = date_trunc('month', h.hoy) AND r.estado = 'NoShow'     THEN 1 ELSE 0 END)::int AS mes_no_show,
    SUM(CASE WHEN date_trunc('month', r.dia) = date_trunc('month', h.hoy) AND r.estado = 'Confirmada' THEN r.personas ELSE 0 END)::int AS mes_personas
  FROM tombot.reservas r, hoy_range h, params p
  WHERE r.restaurante_id = p.rid
)
SELECT * FROM agg`;

const SQL_POR_DIA = `
WITH params AS (SELECT $1::bigint AS rid, COALESCE($2::text, 'UTC') AS tz),
hoy_range AS (SELECT (NOW() AT TIME ZONE p.tz)::date AS hoy FROM params p),
serie AS (
  SELECT generate_series(h.hoy - INTERVAL '13 day', h.hoy, '1 day')::date AS dia
    FROM hoy_range h
)
SELECT s.dia,
       COALESCE(SUM(CASE WHEN r.estado = 'Confirmada' THEN 1 ELSE 0 END), 0)::int AS confirmadas,
       COALESCE(SUM(CASE WHEN r.estado = 'Cancelada'  THEN 1 ELSE 0 END), 0)::int AS canceladas,
       COALESCE(SUM(CASE WHEN r.estado = 'NoShow'     THEN 1 ELSE 0 END), 0)::int AS no_show
  FROM serie s
  LEFT JOIN tombot.reservas r
         ON r.dia = s.dia AND r.restaurante_id = (SELECT rid FROM params)
 GROUP BY s.dia
 ORDER BY s.dia`;

const SQL_PROXIMAS = `
WITH params AS (SELECT $1::bigint AS rid, COALESCE($2::text, 'UTC') AS tz),
hoy_range AS (SELECT (NOW() AT TIME ZONE p.tz)::date AS hoy FROM params p)
SELECT r.id, r.nombre, r.telefono, r.dia, r.horario_hora, r.horario_label,
       r.turno, r.personas, r.numero_mesa, r.estado
  FROM tombot.reservas r, hoy_range h, params p
 WHERE r.restaurante_id = p.rid
   AND r.estado = 'Confirmada'
   AND r.dia >= h.hoy
 ORDER BY r.dia ASC, r.horario_hora ASC
 LIMIT 5`;

export async function registerMetricasRoutes(fastify, ctx) {
  fastify.addHook('preHandler', authHook);

  fastify.get('/', async (req) => {
    const restauranteId = req.user.restaurante_id;

    const { rows: tzRows } = await ctx.pgPool.query(
      'SELECT timezone FROM tombot.restaurantes WHERE id = $1',
      [restauranteId]
    );
    const tz = tzRows[0]?.timezone || 'UTC';

    const [agg, porDia, proximas] = await Promise.all([
      ctx.pgPool.query(SQL, [restauranteId, tz]),
      ctx.pgPool.query(SQL_POR_DIA, [restauranteId, tz]),
      ctx.pgPool.query(SQL_PROXIMAS, [restauranteId, tz]),
    ]);

    const a = agg.rows[0] || {};
    return {
      hoy: {
        confirmadas: a.hoy_confirmadas || 0,
        canceladas:  a.hoy_canceladas  || 0,
        no_show:     a.hoy_no_show     || 0,
        personas:    a.hoy_personas    || 0,
      },
      semana: {
        confirmadas: a.sem_confirmadas || 0,
        canceladas:  a.sem_canceladas  || 0,
        no_show:     a.sem_no_show     || 0,
        personas:    a.sem_personas    || 0,
      },
      mes: {
        confirmadas: a.mes_confirmadas || 0,
        canceladas:  a.mes_canceladas  || 0,
        no_show:     a.mes_no_show     || 0,
        personas:    a.mes_personas    || 0,
      },
      por_dia: porDia.rows,
      proximas: proximas.rows.map((r) => ({ ...r, id: Number(r.id) })),
      timezone: tz,
    };
  });
}
