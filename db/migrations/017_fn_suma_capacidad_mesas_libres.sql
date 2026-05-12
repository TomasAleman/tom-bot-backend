-- =====================================================================
-- Migration 017: suma de capacidad (max_personas) de mesas libres en un
-- slot + config TelefonoReservas (WhatsApp / n8n).
-- La ocupación considera solo reservas.numero_mesa; 018 añade reserva_mesas.
-- =====================================================================

SET search_path TO tombot, public;

CREATE OR REPLACE FUNCTION tombot.fn_suma_capacidad_mesas_libres(
    p_restaurante_id BIGINT,
    p_dia            DATE,
    p_horario_hora   INT
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(SUM(m.max_personas)::BIGINT, 0::BIGINT)
      FROM tombot.mesas m
     WHERE m.restaurante_id = p_restaurante_id
       AND m.activa = TRUE
       AND (
            (m.horario_manana   IS NOT NULL AND tombot.fn_hora_en_turno(p_horario_hora, m.horario_manana))
         OR (m.horario_mediodia IS NOT NULL AND tombot.fn_hora_en_turno(p_horario_hora, m.horario_mediodia))
         OR (m.horario_tarde    IS NOT NULL AND tombot.fn_hora_en_turno(p_horario_hora, m.horario_tarde))
       )
       AND NOT EXISTS (
            SELECT 1
              FROM tombot.reservas r
             WHERE r.restaurante_id = p_restaurante_id
               AND r.dia = p_dia
               AND r.estado = 'Confirmada'
               AND r.numero_mesa = m.numero_mesa
               AND tombot.fn_misma_franja(
                     p_horario_hora,
                     r.horario_hora,
                     m.horario_manana,
                     m.horario_mediodia,
                     m.horario_tarde
                   )
       );
$$;

COMMENT ON FUNCTION tombot.fn_suma_capacidad_mesas_libres IS
  'Suma max_personas de mesas activas libres en dia/hora (solo bloqueo por reservas.numero_mesa; 018 amplía a reserva_mesas).';

INSERT INTO tombot.config (restaurante_id, parametro, valor, descripcion)
SELECT r.id,
       'TelefonoReservas',
       '',
       'Teléfono para reservas grandes / junte (mensaje WhatsApp).'
  FROM tombot.restaurantes r
 WHERE r.activo = TRUE
   AND NOT EXISTS (
         SELECT 1 FROM tombot.config c
          WHERE c.restaurante_id = r.id
            AND c.parametro = 'TelefonoReservas'
       );
