-- =====================================================================
-- Migration 005: funcion para modificar una reserva existente
-- =====================================================================
-- Soporta cambiar: nombre, personas, dia, horario.
-- Cuando el cambio afecta disponibilidad (personas/dia/horario) re-busca
-- una mesa valida excluyendo la reserva actual del calculo de conflictos.
-- Si no hay mesa disponible, devuelve 0 filas y la reserva queda como
-- estaba.
-- Solo cuentan reservas confirmadas al cruzar mesas; Cancelada/NoShow
-- liberan el slot (reserva hecha y luego cancelada no bloquea).
--
-- Parametros:
--   p_reserva_id  -> id de la reserva a modificar
--   p_campo       -> 'nombre' | 'personas' | 'dia' | 'horario'
--   p_valor       -> valor nuevo como TEXT (se castea segun campo)
--
-- Retorna la fila actualizada (o nada si no se pudo aplicar).
-- =====================================================================

SET search_path TO tombot, public;

CREATE OR REPLACE FUNCTION tombot.fn_modificar_reserva(
    p_reserva_id  BIGINT,
    p_campo       TEXT,
    p_valor       TEXT
)
RETURNS TABLE (
    id              BIGINT,
    restaurante_id  BIGINT,
    nombre          TEXT,
    telefono        TEXT,
    dia             DATE,
    horario_hora    INT,
    horario_label   TEXT,
    turno           TEXT,
    personas        INT,
    numero_mesa     TEXT,
    estado          TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_res          tombot.reservas%ROWTYPE;
    v_target_dia   DATE;
    v_target_hora  INT;
    v_target_pers  INT;
    v_target_label TEXT;
    v_target_turno TEXT;
    v_numero_mesa  TEXT;
    v_val_trim     TEXT;
BEGIN
    SELECT * INTO v_res
      FROM tombot.reservas
     WHERE tombot.reservas.id = p_reserva_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    v_target_dia   := v_res.dia;
    v_target_hora  := v_res.horario_hora;
    v_target_pers  := v_res.personas;
    v_target_label := v_res.horario_label;
    v_target_turno := v_res.turno;

    IF p_campo = 'nombre' THEN
        UPDATE tombot.reservas r
           SET nombre = p_valor
         WHERE r.id = p_reserva_id;

    ELSIF p_campo IN ('personas', 'dia', 'horario') THEN
        IF p_campo = 'personas' THEN
            v_target_pers := p_valor::INT;
        ELSIF p_campo = 'dia' THEN
            v_val_trim := trim(both from p_valor);
            IF length(v_val_trim) >= 10
               AND substring(v_val_trim, 5, 1) = '-'
               AND substring(v_val_trim, 8, 1) = '-'
            THEN
                v_target_dia := substring(v_val_trim from 1 for 10)::DATE;
            ELSE
                v_target_dia := v_val_trim::DATE;
            END IF;
        ELSIF p_campo = 'horario' THEN
            v_target_hora  := p_valor::INT;
            v_target_label := v_target_hora::TEXT || 'hs';
        END IF;

        PERFORM 1
          FROM tombot.mesas ml
         WHERE ml.restaurante_id = v_res.restaurante_id
           AND ml.activa = TRUE
         FOR UPDATE;

        SELECT m.numero_mesa,
               COALESCE(
                 CASE WHEN tombot.fn_hora_en_turno(v_target_hora, m.horario_manana)   THEN m.horario_manana   END,
                 CASE WHEN tombot.fn_hora_en_turno(v_target_hora, m.horario_mediodia) THEN m.horario_mediodia END,
                 CASE WHEN tombot.fn_hora_en_turno(v_target_hora, m.horario_tarde)    THEN m.horario_tarde    END
               )
          INTO v_numero_mesa, v_target_turno
          FROM tombot.mesas m
         WHERE m.restaurante_id = v_res.restaurante_id
           AND m.activa = TRUE
           AND v_target_pers BETWEEN m.min_personas AND m.max_personas
           AND (
                tombot.fn_hora_en_turno(v_target_hora, m.horario_manana)
             OR tombot.fn_hora_en_turno(v_target_hora, m.horario_mediodia)
             OR tombot.fn_hora_en_turno(v_target_hora, m.horario_tarde)
           )
           AND NOT EXISTS (
                SELECT 1
                  FROM tombot.reservas r
                 WHERE r.restaurante_id = v_res.restaurante_id
                   AND r.dia = v_target_dia
                   AND lower(r.estado) = 'confirmada'
                   AND r.numero_mesa = m.numero_mesa
                   AND r.id <> p_reserva_id
                   AND tombot.fn_misma_franja(v_target_hora, r.horario_hora,
                                              m.horario_manana, m.horario_mediodia, m.horario_tarde)
           )
         ORDER BY (m.numero_mesa = v_res.numero_mesa) DESC,
                  (m.max_personas - v_target_pers) ASC,
                  m.numero_mesa ASC
         LIMIT 1;

        IF v_numero_mesa IS NULL THEN
            RETURN;
        END IF;

        UPDATE tombot.reservas r
           SET personas      = v_target_pers,
               dia           = v_target_dia,
               horario_hora  = v_target_hora,
               horario_label = v_target_label,
               turno         = v_target_turno,
               numero_mesa   = v_numero_mesa
         WHERE r.id = p_reserva_id;

    ELSE
        RAISE EXCEPTION 'Campo no soportado: %', p_campo;
    END IF;

    RETURN QUERY
    SELECT r.id, r.restaurante_id, r.nombre, r.telefono, r.dia,
           r.horario_hora, r.horario_label, r.turno, r.personas, r.numero_mesa, r.estado
      FROM tombot.reservas r
     WHERE r.id = p_reserva_id;
END;
$$;

COMMENT ON FUNCTION tombot.fn_modificar_reserva IS
  'Modifica una reserva: nombre / personas / dia / horario. Revalida disponibilidad excluyendo la propia reserva del check de conflictos. Devuelve 0 filas si el cambio no se puede aplicar.';
