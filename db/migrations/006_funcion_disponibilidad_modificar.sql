-- =====================================================================
-- Migration 006: disponibilidad real para el flujo "modificar reserva"
-- =====================================================================
-- Devuelve listas JSON (dias y horarios) donde existe al menos una mesa
-- libre usando la MISMA logica que fn_modificar_reserva (excluye la propia
-- reserva del chequeo de conflictos). Solo estado confirmada bloquea mesa;
-- canceladas no bloquean.
-- No modifica el flujo de creacion de reservas.
-- =====================================================================

SET search_path TO tombot, public;

CREATE OR REPLACE FUNCTION tombot.fn_disponibilidad_modificar(
    p_reserva_id BIGINT,
    p_dias_max   INT
)
RETURNS TABLE (
    dias_disponibles     JSONB,
    horarios_disponibles JSONB,
    rango_personas       JSONB
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_res         tombot.reservas%ROWTYPE;
    v_dias        JSONB := '[]'::jsonb;
    v_horas       JSONB := '[]'::jsonb;
    v_d           INT;
    v_h           INT;
    v_dia         DATE;
    v_numero_mesa TEXT;
    v_dow         INT;
    v_dow_txt     TEXT;
    v_pmin        INT;
    v_pmax        INT;
BEGIN
    IF p_dias_max IS NULL OR p_dias_max < 1 THEN
        p_dias_max := 7;
    END IF;

    SELECT * INTO v_res
      FROM tombot.reservas
     WHERE id = p_reserva_id;

    IF NOT FOUND THEN
        dias_disponibles     := '[]'::jsonb;
        horarios_disponibles := '[]'::jsonb;
        rango_personas       := '{"min":1,"max":12}'::jsonb;
        RETURN NEXT;
        RETURN;
    END IF;

    SELECT COALESCE(MIN(m.min_personas), 1), COALESCE(MAX(m.max_personas), 12)
      INTO v_pmin, v_pmax
      FROM tombot.mesas m
     WHERE m.restaurante_id = v_res.restaurante_id
       AND m.activa = TRUE;

    rango_personas := jsonb_build_object('min', v_pmin, 'max', v_pmax);

    -- Dias: mismo horario y personas que la reserva actual
    FOR v_d IN 0..(p_dias_max - 1) LOOP
        v_dia := CURRENT_DATE + v_d;

        SELECT m.numero_mesa
          INTO v_numero_mesa
          FROM tombot.mesas m
         WHERE m.restaurante_id = v_res.restaurante_id
           AND m.activa = TRUE
           AND v_res.personas BETWEEN m.min_personas AND m.max_personas
           AND (
                tombot.fn_hora_en_turno(v_res.horario_hora, m.horario_manana)
             OR tombot.fn_hora_en_turno(v_res.horario_hora, m.horario_mediodia)
             OR tombot.fn_hora_en_turno(v_res.horario_hora, m.horario_tarde)
           )
           AND NOT EXISTS (
                SELECT 1
                  FROM tombot.reservas r2
                 WHERE r2.restaurante_id = v_res.restaurante_id
                   AND r2.dia = v_dia
                   AND lower(r2.estado) = 'confirmada'
                   AND r2.numero_mesa = m.numero_mesa
                   AND r2.id <> p_reserva_id
                   AND tombot.fn_misma_franja(v_res.horario_hora, r2.horario_hora,
                                              m.horario_manana, m.horario_mediodia, m.horario_tarde)
           )
         ORDER BY (m.numero_mesa = v_res.numero_mesa) DESC,
                  (m.max_personas - v_res.personas) ASC,
                  m.numero_mesa ASC
         LIMIT 1;

        IF v_numero_mesa IS NOT NULL THEN
            v_dow := EXTRACT(DOW FROM v_dia)::INT;
            v_dow_txt := (ARRAY['Dom','Lun','Mar','Mie','Jue','Vie','Sab'])[v_dow + 1];
            v_dias := v_dias || jsonb_build_array(
                jsonb_build_object(
                    'valor', to_char(v_dia, 'YYYY-MM-DD'),
                    'label', v_dow_txt || ' ' || to_char(v_dia, 'DD/MM')
                )
            );
        END IF;
    END LOOP;

    -- Horarios: mismo dia y personas que la reserva actual
    FOR v_h IN 0..23 LOOP
        SELECT m.numero_mesa
          INTO v_numero_mesa
          FROM tombot.mesas m
         WHERE m.restaurante_id = v_res.restaurante_id
           AND m.activa = TRUE
           AND v_res.personas BETWEEN m.min_personas AND m.max_personas
           AND (
                tombot.fn_hora_en_turno(v_h, m.horario_manana)
             OR tombot.fn_hora_en_turno(v_h, m.horario_mediodia)
             OR tombot.fn_hora_en_turno(v_h, m.horario_tarde)
           )
           AND NOT EXISTS (
                SELECT 1
                  FROM tombot.reservas r2
                 WHERE r2.restaurante_id = v_res.restaurante_id
                   AND r2.dia = v_res.dia
                   AND lower(r2.estado) = 'confirmada'
                   AND r2.numero_mesa = m.numero_mesa
                   AND r2.id <> p_reserva_id
                   AND tombot.fn_misma_franja(v_h, r2.horario_hora,
                                              m.horario_manana, m.horario_mediodia, m.horario_tarde)
           )
         ORDER BY (m.numero_mesa = v_res.numero_mesa) DESC,
                  (m.max_personas - v_res.personas) ASC,
                  m.numero_mesa ASC
         LIMIT 1;

        IF v_numero_mesa IS NOT NULL THEN
            v_horas := v_horas || jsonb_build_array(
                jsonb_build_object(
                    'valor', v_h::TEXT,
                    'label', v_h::TEXT || ':00'
                )
            );
        END IF;
    END LOOP;

    dias_disponibles     := v_dias;
    horarios_disponibles := v_horas;
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION tombot.fn_disponibilidad_modificar IS
  'Para modificar reserva: lista dias (mismo horario/personas) y horarios (mismo dia/personas) con mesa libre, excluyendo la propia reserva.';
