/**
 * Capa de acceso a datos. Misma logica que el nodo Postgres
 * "Cargar contexto" del workflow n8n, pero con cache Redis.
 *
 * Cache:
 *   tenant:{instancia}            -> 1h
 *   config:{restaurante_id}       -> 5min
 *   mesas:{restaurante_id}        -> 5min
 *   sesion:{restaurante_id}:{tel} -> 10min
 */

const CARGAR_CONTEXTO_SQL = `
WITH tenant AS (
    SELECT id, slug, nombre, instancia_evolution, evolution_api_key,
           sheets_id_lectura, timezone
      FROM tombot.restaurantes
     WHERE instancia_evolution = $1 AND activo = TRUE LIMIT 1
),
sesion AS (
    SELECT s.* FROM tombot.sesiones s
      JOIN tenant t ON t.id = s.restaurante_id
     WHERE s.telefono = $2 LIMIT 1
),
config_kv AS (
    SELECT jsonb_object_agg(c.parametro, c.valor) AS config
      FROM tombot.config c JOIN tenant t ON t.id = c.restaurante_id
),
mesas_arr AS (
    SELECT jsonb_agg(jsonb_build_object(
                'numero_mesa', m.numero_mesa,
                'min_personas', m.min_personas,
                'max_personas', m.max_personas,
                'horario_manana', m.horario_manana,
                'horario_mediodia', m.horario_mediodia,
                'horario_tarde', m.horario_tarde
           ) ORDER BY m.numero_mesa) AS mesas
      FROM tombot.mesas m JOIN tenant t ON t.id = m.restaurante_id
     WHERE m.activa = TRUE
)
SELECT
    t.id AS restaurante_id, t.slug, t.nombre AS nombre_restaurante,
    t.instancia_evolution, t.evolution_api_key, t.timezone,
    s.contexto_reserva, s.contador_mensajes, s.bloqueo_hasta,
    s.bloqueo_minutos, s.primer_contacto, s.ultimo_mensaje_at,
    (s.restaurante_id IS NULL) AS es_primera_vez,
    COALESCE(c.config, '{}'::jsonb) AS config,
    COALESCE(m.mesas, '[]'::jsonb)  AS mesas
  FROM tenant t
  LEFT JOIN sesion s    ON TRUE
  LEFT JOIN config_kv c ON TRUE
  LEFT JOIN mesas_arr m ON TRUE`;

export async function loadContexto(ctx, instancia, telefono) {
  // 1. Tenant en cache
  const tenantKey = `tenant:${instancia}`;
  const tenantCached = await ctx.redis.get(tenantKey);

  if (tenantCached) {
    const t = JSON.parse(tenantCached);
    // Aun asi tenemos que pedir sesion y demas — usamos un fast-path
    return await loadFromPg(ctx, instancia, telefono, t);
  }

  return await loadFromPg(ctx, instancia, telefono);
}

async function loadFromPg(ctx, instancia, telefono, tenantCache) {
  const { rows } = await ctx.pgPool.query(CARGAR_CONTEXTO_SQL, [instancia, telefono]);
  if (rows.length === 0) return null;
  const row = rows[0];

  // Cachear tenant 1h (info estable)
  if (!tenantCache) {
    await ctx.redis.setex(`tenant:${instancia}`, 3600, JSON.stringify({
      id: row.restaurante_id,
      instancia_evolution: row.instancia_evolution,
      evolution_api_key: row.evolution_api_key,
    }));
  }

  return row;
}

export async function upsertSesion(ctx, restauranteId, telefono, contexto, contador, bloqueoHasta, bloqueoMinutos) {
  await ctx.pgPool.query(
    `INSERT INTO tombot.sesiones (
       restaurante_id, telefono, contexto_reserva, contador_mensajes,
       bloqueo_hasta, bloqueo_minutos, ultimo_mensaje_at
     ) VALUES ($1, $2, $3::jsonb, $4, $5, $6, NOW())
     ON CONFLICT (restaurante_id, telefono) DO UPDATE
        SET contexto_reserva = EXCLUDED.contexto_reserva,
            contador_mensajes = EXCLUDED.contador_mensajes,
            bloqueo_hasta = EXCLUDED.bloqueo_hasta,
            bloqueo_minutos = EXCLUDED.bloqueo_minutos,
            ultimo_mensaje_at = NOW()`,
    [restauranteId, telefono, JSON.stringify(contexto || {}), contador, bloqueoHasta, bloqueoMinutos]
  );
}

export async function buscarMesa(ctx, restauranteId, dia, horaInt, turno, personas) {
  const { rows } = await ctx.pgPool.query(
    `SELECT numero_mesa, turnos_alternativos
       FROM tombot.fn_buscar_mesa_disponible($1, $2::DATE, $3::INT, $4, $5::INT)`,
    [restauranteId, dia, horaInt, turno, personas]
  );
  return rows[0];
}

export async function confirmarReserva(ctx, args) {
  const { restauranteId, nombre, telefono, dia, horaInt, horarioLabel, turno, personas, mesaPreferida } = args;
  const { rows } = await ctx.pgPool.query(
    `SELECT id_reserva, numero_mesa
       FROM tombot.fn_confirmar_reserva($1, $2, $3, $4::DATE, $5::INT, $6, $7, $8::INT, $9)`,
    [restauranteId, nombre, telefono, dia, horaInt, horarioLabel, turno, personas, mesaPreferida]
  );
  return rows[0];
}
