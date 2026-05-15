-- =====================================================================
-- Migration 023: ocupación unificada con lower(trim(estado)) = 'confirmada'
-- en vista de día, suma capacidad, buscar/confirmar mesa y junte.
-- Evita huecos si el estado llega con espacios o distinta capitalización.
-- =====================================================================

SET search_path TO tombot, public;

CREATE OR REPLACE VIEW tombot.v_reservas_confirmadas_dia AS
SELECT r.restaurante_id,
       r.dia,
       r.numero_mesa,
       r.horario_hora,
       r.turno
  FROM tombot.reservas r
 WHERE lower(trim(r.estado)) = 'confirmada'
   AND NOT EXISTS (SELECT 1 FROM tombot.reserva_mesas rm WHERE rm.reserva_id = r.id)
UNION ALL
SELECT r.restaurante_id,
       r.dia,
       rm.numero_mesa,
       r.horario_hora,
       r.turno
  FROM tombot.reservas r
  JOIN tombot.reserva_mesas rm ON rm.reserva_id = r.id
 WHERE lower(trim(r.estado)) = 'confirmada';

CREATE OR REPLACE FUNCTION tombot.fn_suma_capacidad_mesas_libres(
    p_restaurante_id       BIGINT,
    p_dia                  DATE,
    p_horario_hora         INT,
    p_excluir_reserva_id   BIGINT DEFAULT NULL
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
               AND lower(trim(r.estado)) = 'confirmada'
               AND (p_excluir_reserva_id IS NULL OR r.id <> p_excluir_reserva_id)
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
               AND lower(trim(r.estado)) = 'confirmada'
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
                       AND lower(trim(r.estado)) = 'confirmada'
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
               AND lower(trim(r.estado)) = 'confirmada'
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
                   AND lower(trim(r.estado)) = 'confirmada'
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
           AND lower(trim(r.estado)) = 'confirmada'
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

CREATE OR REPLACE FUNCTION tombot.fn_modificar_reserva_junte(
    p_reserva_id      BIGINT,
    p_dia             DATE,
    p_horario_hora    INT,
    p_horario_label   TEXT,
    p_turno           TEXT,
    p_personas        INT,
    p_mesas           TEXT[],
    p_nombre          TEXT DEFAULT NULL
)
RETURNS TABLE (
    id               BIGINT,
    restaurante_id   BIGINT,
    nombre           TEXT,
    telefono         TEXT,
    dia              DATE,
    horario_hora     INT,
    horario_label    TEXT,
    turno            TEXT,
    personas         INT,
    numero_mesa      TEXT,
    estado           TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_res       tombot.reservas%ROWTYPE;
    v_mesas_ord TEXT[];
    v_primera   TEXT;
    v_sum_min   INT;
    v_sum_max   INT;
    v_n_mesas   INT;
BEGIN
    PERFORM set_config('lock_timeout', '15000', true);
    PERFORM set_config('statement_timeout', '60000', true);

    SELECT * INTO v_res
      FROM tombot.reservas rs
     WHERE rs.id = p_reserva_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF lower(trim(COALESCE(v_res.estado, ''))) <> 'confirmada' THEN
        RETURN;
    END IF;

    IF p_mesas IS NULL OR array_length(p_mesas, 1) IS NULL OR array_length(p_mesas, 1) < 2 THEN
        RETURN;
    END IF;

    IF (SELECT COUNT(DISTINCT x) FROM unnest(p_mesas) AS x) <> array_length(p_mesas, 1) THEN
        RETURN;
    END IF;

    SELECT array_agg(u.m ORDER BY u.m)
      INTO v_mesas_ord
      FROM (SELECT DISTINCT x AS m FROM unnest(p_mesas) AS x) u;

    v_primera := v_mesas_ord[1];

    PERFORM 1
      FROM tombot.mesas ml
     WHERE ml.restaurante_id = v_res.restaurante_id
       AND ml.activa = TRUE
     FOR UPDATE;

    SELECT COUNT(*)::INT
      INTO v_n_mesas
      FROM tombot.mesas m
     WHERE m.restaurante_id = v_res.restaurante_id
       AND m.activa = TRUE
       AND m.numero_mesa = ANY (p_mesas)
       AND (
            (m.horario_manana   IS NOT NULL AND tombot.fn_hora_en_turno(p_horario_hora, m.horario_manana))
         OR (m.horario_mediodia IS NOT NULL AND tombot.fn_hora_en_turno(p_horario_hora, m.horario_mediodia))
         OR (m.horario_tarde    IS NOT NULL AND tombot.fn_hora_en_turno(p_horario_hora, m.horario_tarde))
       );

    IF v_n_mesas IS NULL OR v_n_mesas <> array_length(p_mesas, 1) THEN
        RETURN;
    END IF;

    SELECT COALESCE(SUM(m.min_personas), 0), COALESCE(SUM(m.max_personas), 0)
      INTO v_sum_min, v_sum_max
      FROM tombot.mesas m
     WHERE m.restaurante_id = v_res.restaurante_id
       AND m.activa = TRUE
       AND m.numero_mesa = ANY (p_mesas)
       AND (
            (m.horario_manana   IS NOT NULL AND tombot.fn_hora_en_turno(p_horario_hora, m.horario_manana))
         OR (m.horario_mediodia IS NOT NULL AND tombot.fn_hora_en_turno(p_horario_hora, m.horario_mediodia))
         OR (m.horario_tarde    IS NOT NULL AND tombot.fn_hora_en_turno(p_horario_hora, m.horario_tarde))
       );

    IF v_sum_max = 0 OR p_personas < v_sum_min OR p_personas > v_sum_max THEN
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1
          FROM unnest(p_mesas) AS u(mesa_n)
          JOIN tombot.mesas m
            ON m.restaurante_id = v_res.restaurante_id
           AND m.numero_mesa = u.mesa_n
           AND m.activa = TRUE
          JOIN tombot.reservas r
            ON r.restaurante_id = v_res.restaurante_id
           AND r.dia = p_dia
           AND lower(trim(r.estado)) = 'confirmada'
           AND r.id <> p_reserva_id
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
        RETURN;
    END IF;

    DELETE FROM tombot.reserva_mesas WHERE reserva_id = p_reserva_id;

    UPDATE tombot.reservas r
       SET nombre          = CASE
                               WHEN p_nombre IS NOT NULL AND trim(both from p_nombre) <> '' THEN trim(both from p_nombre)
                               ELSE r.nombre
                             END,
           dia             = p_dia,
           horario_hora    = p_horario_hora,
           horario_label   = p_horario_label,
           turno           = p_turno,
           personas        = p_personas,
           numero_mesa     = v_primera,
           updated_at      = NOW()
     WHERE r.id = p_reserva_id;

    INSERT INTO tombot.reserva_mesas (reserva_id, numero_mesa)
    SELECT p_reserva_id, x
      FROM unnest(v_mesas_ord) AS x;

    RETURN QUERY
    SELECT r.id, r.restaurante_id, r.nombre, r.telefono, r.dia,
           r.horario_hora, r.horario_label, r.turno, r.personas, r.numero_mesa, r.estado
      FROM tombot.reservas r
     WHERE r.id = p_reserva_id;
END;
$$;

COMMENT ON FUNCTION tombot.fn_modificar_reserva_junte IS
  'Panel: reasigna reserva confirmada a junte de mesas (misma validación que confirmar junte, excluye la propia fila).';
