-- =====================================================================
-- Migration 004: helpers para cleanup nocturno y vistas de metricas
-- =====================================================================
-- Idempotente.
-- =====================================================================

SET search_path TO tombot, public;

-- ---------------------------------------------------------------------
-- Function: cleanup_sesiones_inactivas
-- Borra sesiones sin actividad por mas de N horas y resetea bloqueos
-- vencidos hace mas de 24 hs.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tombot.fn_cleanup_sesiones(
    p_horas_inactividad INT DEFAULT 24
)
RETURNS TABLE (
    sesiones_borradas BIGINT,
    bloqueos_reseteados BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borradas BIGINT;
    v_reset    BIGINT;
BEGIN
    DELETE FROM tombot.sesiones
     WHERE ultimo_mensaje_at < NOW() - (p_horas_inactividad || ' hours')::INTERVAL
       AND (bloqueo_hasta IS NULL OR bloqueo_hasta < NOW() - INTERVAL '24 hours');
    GET DIAGNOSTICS v_borradas = ROW_COUNT;

    UPDATE tombot.sesiones
       SET bloqueo_hasta = NULL,
           bloqueo_minutos = 0,
           contador_mensajes = 0
     WHERE bloqueo_hasta IS NOT NULL
       AND bloqueo_hasta < NOW() - INTERVAL '1 hour';
    GET DIAGNOSTICS v_reset = ROW_COUNT;

    RETURN QUERY SELECT v_borradas, v_reset;
END;
$$;

-- ---------------------------------------------------------------------
-- Function: cleanup_eventos_log_viejos (retencion 30 dias)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tombot.fn_cleanup_eventos_log(
    p_dias_retencion INT DEFAULT 30
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrados BIGINT;
BEGIN
    DELETE FROM tombot.eventos_log
     WHERE created_at < NOW() - (p_dias_retencion || ' days')::INTERVAL;
    GET DIAGNOSTICS v_borrados = ROW_COUNT;
    RETURN v_borrados;
END;
$$;

-- ---------------------------------------------------------------------
-- Vista: metricas_5min — uso reciente por tenant
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW tombot.v_metricas_5min AS
SELECT
    e.restaurante_id,
    r.slug,
    count(*) FILTER (WHERE e.created_at > NOW() - INTERVAL '5 minutes')                    AS mensajes_5min,
    count(*) FILTER (WHERE e.created_at > NOW() - INTERVAL '1 hour')                       AS mensajes_1h,
    count(*) FILTER (WHERE e.tipo_evento = 'reserva_ok' AND e.created_at > NOW() - INTERVAL '1 day') AS reservas_24h,
    count(*) FILTER (WHERE e.tipo_evento = 'rate_limited' AND e.created_at > NOW() - INTERVAL '1 hour') AS rate_limits_1h,
    percentile_cont(0.5)  WITHIN GROUP (ORDER BY e.latencia_ms) FILTER (WHERE e.latencia_ms IS NOT NULL AND e.created_at > NOW() - INTERVAL '5 minutes') AS p50_latencia_ms_5min,
    percentile_cont(0.95) WITHIN GROUP (ORDER BY e.latencia_ms) FILTER (WHERE e.latencia_ms IS NOT NULL AND e.created_at > NOW() - INTERVAL '5 minutes') AS p95_latencia_ms_5min
  FROM tombot.eventos_log e
  LEFT JOIN tombot.restaurantes r ON r.id = e.restaurante_id
 GROUP BY e.restaurante_id, r.slug;

-- ---------------------------------------------------------------------
-- Vista: ocupacion_dia — % de mesas usadas por dia
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW tombot.v_ocupacion_dia AS
SELECT
    rs.id            AS restaurante_id,
    rs.slug,
    r.dia,
    count(DISTINCT r.numero_mesa)                              AS mesas_ocupadas,
    (SELECT count(*) FROM tombot.mesas m
      WHERE m.restaurante_id = rs.id AND m.activa = TRUE)      AS mesas_totales,
    sum(r.personas)                                            AS comensales_totales
  FROM tombot.reservas r
  JOIN tombot.restaurantes rs ON rs.id = r.restaurante_id
 WHERE r.estado = 'Confirmada'
   AND r.dia >= CURRENT_DATE - INTERVAL '7 days'
 GROUP BY rs.id, rs.slug, r.dia
 ORDER BY r.dia DESC, rs.id;
