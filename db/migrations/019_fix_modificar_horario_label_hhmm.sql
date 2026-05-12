-- =====================================================================
-- Migration 019: etiqueta HH:MM al modificar horario (no "1320hs")
-- =====================================================================
-- La 018 reintrodujo `horario_label := v_target_hora::TEXT || 'hs'`, que
-- muestra minutos crudos (ej. 1320hs) en vez de 22:00.
-- Restauramos parse + fn_horario_label_desde_minutos y dejamos el label
-- como HH:MM (sin sufijo "hs") para alinear con panel (fmtHora) y WhatsApp.
-- =====================================================================

SET search_path TO tombot, public;

CREATE OR REPLACE FUNCTION tombot.fn_horario_label_desde_minutos(p_min INT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_min IS NULL OR p_min < 0 OR p_min > 1439 THEN NULL
    ELSE lpad(((p_min / 60) % 24)::text, 2, '0') || ':' ||
         lpad((p_min % 60)::text, 2, '0')
  END;
$$;

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
    PERFORM set_config('lock_timeout', '15000', true);
    PERFORM set_config('statement_timeout', '60000', true);

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
            v_target_hora := tombot.fn_parse_minutos_desde_texto(p_valor);
            IF v_target_hora IS NULL THEN
                RETURN;
            END IF;
            IF v_target_hora < 0 OR v_target_hora > 1439 THEN
                RETURN;
            END IF;
            v_target_label := tombot.fn_horario_label_desde_minutos(v_target_hora);
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
                   AND r.id <> p_reserva_id
                   AND tombot.fn_misma_franja(v_target_hora, r.horario_hora,
                                              m.horario_manana, m.horario_mediodia, m.horario_tarde)
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
         ORDER BY (m.numero_mesa = v_res.numero_mesa) DESC,
                  (m.max_personas - v_target_pers) ASC,
                  m.numero_mesa ASC
         LIMIT 1;

        IF v_numero_mesa IS NULL THEN
            RETURN;
        END IF;

        DELETE FROM tombot.reserva_mesas WHERE reserva_id = p_reserva_id;

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

UPDATE tombot.reservas r
   SET horario_label = tombot.fn_horario_label_desde_minutos(r.horario_hora)
 WHERE r.horario_hora BETWEEN 0 AND 1439
   AND r.horario_label IS NOT NULL
   AND r.horario_label ~ '^[0-9]+hs$';

COMMENT ON FUNCTION tombot.fn_horario_label_desde_minutos(INT) IS
  'Etiqueta HH:MM (24 h) desde minutos 0-1439; sin sufijo hs.';
