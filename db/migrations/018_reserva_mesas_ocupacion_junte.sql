-- =====================================================================
-- Migration 018: reserva_mesas (junte), ocupación unificada, confirmar
-- junte, vista v_reservas_confirmadas_dia.
-- Actualiza fn_suma_capacidad_mesas_libres (017), buscar/confirmar,
-- modificar, disponibilidad_modificar.
-- =====================================================================

SET search_path TO tombot, public;

-- ---------------------------------------------------------------------
-- 1) Tabla puente
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tombot.reserva_mesas (
    reserva_id   BIGINT NOT NULL REFERENCES tombot.reservas(id) ON DELETE CASCADE,
    numero_mesa  TEXT   NOT NULL,
    PRIMARY KEY (reserva_id, numero_mesa)
);

CREATE INDEX IF NOT EXISTS idx_reserva_mesas_numero
    ON tombot.reserva_mesas (numero_mesa);

COMMENT ON TABLE tombot.reserva_mesas IS
  'Mesas adicionales de una misma reserva (junte). reservas.numero_mesa = mesa principal.';

-- ---------------------------------------------------------------------
-- 2) Vista: una fila por mesa ocupada (simple + junte)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW tombot.v_reservas_confirmadas_dia AS
SELECT r.restaurante_id,
       r.dia,
       r.numero_mesa,
       r.horario_hora,
       r.turno
  FROM tombot.reservas r
 WHERE r.estado = 'Confirmada'
   AND NOT EXISTS (SELECT 1 FROM tombot.reserva_mesas rm WHERE rm.reserva_id = r.id)
UNION ALL
SELECT r.restaurante_id,
       r.dia,
       rm.numero_mesa,
       r.horario_hora,
       r.turno
  FROM tombot.reservas r
  JOIN tombot.reserva_mesas rm ON rm.reserva_id = r.id
 WHERE r.estado = 'Confirmada';

-- ---------------------------------------------------------------------
-- 3) fn_suma_capacidad_mesas_libres (incluye junte en ocupación)
-- ---------------------------------------------------------------------
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
               AND tombot.fn_misma_franja(
                     p_horario_hora,
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
       );
$$;

-- ---------------------------------------------------------------------
-- 4) fn_buscar_mesa_disponible
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tombot.fn_buscar_mesa_disponible(
    p_restaurante_id BIGINT,
    p_dia            DATE,
    p_horario_hora   INT,
    p_turno          TEXT,
    p_personas       INT
)
RETURNS TABLE (
    numero_mesa          TEXT,
    turnos_alternativos  JSONB
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_numero_mesa  TEXT;
    v_alt          JSONB;
BEGIN
    SELECT m.numero_mesa
      INTO v_numero_mesa
      FROM tombot.mesas m
     WHERE m.restaurante_id = p_restaurante_id
       AND m.activa = TRUE
       AND p_personas BETWEEN m.min_personas AND m.max_personas
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
               AND tombot.fn_misma_franja(p_horario_hora, r.horario_hora,
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
     ORDER BY (m.max_personas - p_personas) ASC,
              m.numero_mesa ASC
     LIMIT 1;

    IF v_numero_mesa IS NOT NULL THEN
        RETURN QUERY SELECT v_numero_mesa, '[]'::jsonb;
        RETURN;
    END IF;

    WITH turnos AS (
        SELECT DISTINCT t.turno_label
          FROM tombot.mesas m,
               LATERAL (VALUES
                   (m.horario_manana),
                   (m.horario_mediodia),
                   (m.horario_tarde)
               ) AS t(turno_label)
         WHERE m.restaurante_id = p_restaurante_id
           AND m.activa = TRUE
           AND t.turno_label IS NOT NULL
           AND t.turno_label <> p_turno
    ),
    disponibles AS (
        SELECT t.turno_label
          FROM turnos t
         WHERE EXISTS (
            SELECT 1
              FROM tombot.mesas m
             WHERE m.restaurante_id = p_restaurante_id
               AND m.activa = TRUE
               AND p_personas BETWEEN m.min_personas AND m.max_personas
               AND (
                    m.horario_manana   = t.turno_label OR
                    m.horario_mediodia = t.turno_label OR
                    m.horario_tarde    = t.turno_label
               )
               AND NOT EXISTS (
                    SELECT 1
                      FROM tombot.reservas r
                     WHERE r.restaurante_id = p_restaurante_id
                       AND r.dia = p_dia
                       AND r.estado = 'Confirmada'
                       AND tombot.fn_hora_en_turno(r.horario_hora, t.turno_label)
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
         )
    )
    SELECT COALESCE(jsonb_agg(d.turno_label ORDER BY d.turno_label), '[]'::jsonb)
      INTO v_alt
      FROM disponibles d;

    RETURN QUERY SELECT NULL::TEXT, v_alt;
END;
$$;

-- ---------------------------------------------------------------------
-- 5) fn_confirmar_reserva
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tombot.fn_confirmar_reserva(
    p_restaurante_id BIGINT,
    p_nombre         TEXT,
    p_telefono       TEXT,
    p_dia            DATE,
    p_horario_hora   INT,
    p_horario_label  TEXT,
    p_turno          TEXT,
    p_personas       INT,
    p_mesa_preferida TEXT
)
RETURNS TABLE (
    id_reserva   BIGINT,
    numero_mesa  TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_numero_mesa  TEXT;
    v_id_reserva   BIGINT;
    v_disponible   BOOLEAN;
BEGIN
    PERFORM 1
      FROM tombot.mesas
     WHERE restaurante_id = p_restaurante_id
       AND activa = TRUE
     FOR UPDATE;

    IF p_mesa_preferida IS NOT NULL THEN
        SELECT NOT EXISTS (
            SELECT 1
              FROM tombot.reservas r
              JOIN tombot.mesas m
                ON m.restaurante_id = r.restaurante_id
               AND m.numero_mesa = r.numero_mesa
             WHERE r.restaurante_id = p_restaurante_id
               AND r.dia = p_dia
               AND r.estado = 'Confirmada'
               AND tombot.fn_misma_franja(p_horario_hora, r.horario_hora,
                                          m.horario_manana, m.horario_mediodia, m.horario_tarde)
               AND (
                    r.numero_mesa = p_mesa_preferida
                 OR EXISTS (
                        SELECT 1
                          FROM tombot.reserva_mesas rm
                         WHERE rm.reserva_id = r.id
                           AND rm.numero_mesa = p_mesa_preferida
                    )
               )
        )
        INTO v_disponible;

        IF v_disponible THEN
            v_numero_mesa := p_mesa_preferida;
        END IF;
    END IF;

    IF v_numero_mesa IS NULL THEN
        SELECT m.numero_mesa
          INTO v_numero_mesa
          FROM tombot.mesas m
         WHERE m.restaurante_id = p_restaurante_id
           AND m.activa = TRUE
           AND p_personas BETWEEN m.min_personas AND m.max_personas
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
                   AND tombot.fn_misma_franja(p_horario_hora, r.horario_hora,
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
         ORDER BY (m.max_personas - p_personas) ASC,
                  m.numero_mesa ASC
         LIMIT 1;
    END IF;

    IF v_numero_mesa IS NOT NULL THEN
        INSERT INTO tombot.reservas (
            restaurante_id, nombre, telefono, dia,
            horario_hora, horario_label, turno, personas, numero_mesa, estado
        )
        VALUES (
            p_restaurante_id, p_nombre, p_telefono, p_dia,
            p_horario_hora, p_horario_label, p_turno, p_personas, v_numero_mesa, 'Confirmada'
        )
        RETURNING id INTO v_id_reserva;

        RETURN QUERY SELECT v_id_reserva, v_numero_mesa;
    ELSE
        RETURN QUERY SELECT NULL::BIGINT, NULL::TEXT;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- 6) fn_confirmar_reserva_junte (panel admin: varias mesas)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tombot.fn_confirmar_reserva_junte(
    p_restaurante_id BIGINT,
    p_nombre         TEXT,
    p_telefono       TEXT,
    p_dia            DATE,
    p_horario_hora   INT,
    p_horario_label  TEXT,
    p_turno          TEXT,
    p_personas       INT,
    p_mesas          TEXT[]
)
RETURNS TABLE (
    id_reserva   BIGINT,
    numero_mesa  TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_reserva BIGINT;
    v_primera    TEXT;
    v_sum_min    INT;
    v_sum_max    INT;
    v_n_mesas    INT;
BEGIN
    IF p_mesas IS NULL OR array_length(p_mesas, 1) IS NULL OR array_length(p_mesas, 1) < 1 THEN
        RETURN QUERY SELECT NULL::BIGINT, NULL::TEXT;
        RETURN;
    END IF;

    IF (SELECT COUNT(DISTINCT x) FROM unnest(p_mesas) AS x) <> array_length(p_mesas, 1) THEN
        RETURN QUERY SELECT NULL::BIGINT, NULL::TEXT;
        RETURN;
    END IF;

    PERFORM 1
      FROM tombot.mesas
     WHERE restaurante_id = p_restaurante_id
       AND activa = TRUE
     FOR UPDATE;

    SELECT COUNT(*)::INT
      INTO v_n_mesas
      FROM tombot.mesas m
     WHERE m.restaurante_id = p_restaurante_id
       AND m.activa = TRUE
       AND m.numero_mesa = ANY (p_mesas)
       AND (
            (m.horario_manana   IS NOT NULL AND tombot.fn_hora_en_turno(p_horario_hora, m.horario_manana))
         OR (m.horario_mediodia IS NOT NULL AND tombot.fn_hora_en_turno(p_horario_hora, m.horario_mediodia))
         OR (m.horario_tarde    IS NOT NULL AND tombot.fn_hora_en_turno(p_horario_hora, m.horario_tarde))
       );

    IF v_n_mesas IS NULL OR v_n_mesas <> array_length(p_mesas, 1) THEN
        RETURN QUERY SELECT NULL::BIGINT, NULL::TEXT;
        RETURN;
    END IF;

    SELECT COALESCE(SUM(m.min_personas), 0), COALESCE(SUM(m.max_personas), 0)
      INTO v_sum_min, v_sum_max
      FROM tombot.mesas m
     WHERE m.restaurante_id = p_restaurante_id
       AND m.activa = TRUE
       AND m.numero_mesa = ANY (p_mesas)
       AND (
            (m.horario_manana   IS NOT NULL AND tombot.fn_hora_en_turno(p_horario_hora, m.horario_manana))
         OR (m.horario_mediodia IS NOT NULL AND tombot.fn_hora_en_turno(p_horario_hora, m.horario_mediodia))
         OR (m.horario_tarde    IS NOT NULL AND tombot.fn_hora_en_turno(p_horario_hora, m.horario_tarde))
       );

    IF v_sum_max = 0 OR p_personas < v_sum_min OR p_personas > v_sum_max THEN
        RETURN QUERY SELECT NULL::BIGINT, NULL::TEXT;
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1
          FROM unnest(p_mesas) AS u(mesa_n)
          JOIN tombot.mesas m
            ON m.restaurante_id = p_restaurante_id
           AND m.numero_mesa = u.mesa_n
           AND m.activa = TRUE
          JOIN tombot.reservas r
            ON r.restaurante_id = p_restaurante_id
           AND r.dia = p_dia
           AND r.estado = 'Confirmada'
           AND tombot.fn_misma_franja(
                 p_horario_hora,
                 r.horario_hora,
                 m.horario_manana,
                 m.horario_mediodia,
                 m.horario_tarde
               )
         WHERE (
                r.numero_mesa = u.mesa_n
             OR EXISTS (
                    SELECT 1
                      FROM tombot.reserva_mesas rm
                     WHERE rm.reserva_id = r.id
                       AND rm.numero_mesa = u.mesa_n
                )
           )
    ) THEN
        RETURN QUERY SELECT NULL::BIGINT, NULL::TEXT;
        RETURN;
    END IF;

    v_primera := p_mesas[1];

    INSERT INTO tombot.reservas (
        restaurante_id, nombre, telefono, dia,
        horario_hora, horario_label, turno, personas, numero_mesa, estado
    )
    VALUES (
        p_restaurante_id, p_nombre, p_telefono, p_dia,
        p_horario_hora, p_horario_label, p_turno, p_personas, v_primera, 'Confirmada'
    )
    RETURNING id INTO v_id_reserva;

    INSERT INTO tombot.reserva_mesas (reserva_id, numero_mesa)
    SELECT v_id_reserva, x
      FROM unnest(p_mesas) AS x;

    RETURN QUERY SELECT v_id_reserva, v_primera;
END;
$$;

COMMENT ON FUNCTION tombot.fn_confirmar_reserva_junte IS
  'Inserta reserva confirmada con N mesas (reserva_mesas). numero_mesa = primera del array.';

-- ---------------------------------------------------------------------
-- 7) fn_modificar_reserva (ocupación + limpiar reserva_mesas al cambiar mesa)
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 8) fn_disponibilidad_modificar — mismos NOT EXISTS extendidos
-- ---------------------------------------------------------------------
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
                   AND r2.id <> p_reserva_id
                   AND tombot.fn_misma_franja(v_res.horario_hora, r2.horario_hora,
                                              m.horario_manana, m.horario_mediodia, m.horario_tarde)
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
                   AND r2.id <> p_reserva_id
                   AND tombot.fn_misma_franja(v_h, r2.horario_hora,
                                              m.horario_manana, m.horario_mediodia, m.horario_tarde)
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
