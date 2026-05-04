-- =====================================================================
-- Migration 003: funciones para buscar y confirmar mesa con concurrency-safe lock
-- =====================================================================
-- El flujo del bot tiene 2 pasos:
--   1. fn_buscar_mesa_disponible() -> read-only, devuelve mesa candidata
--      o turnos alternativos. Se usa cuando el usuario completa los 4
--      datos pero aun no confirmo.
--   2. fn_confirmar_reserva() -> INSERT en reservas con FOR UPDATE.
--      Re-verifica que la mesa siga libre (puede haber cambiado entre
--      el "preguntar confirmacion" y el "si"). Si ya no esta libre,
--      busca otra mesa equivalente.
--
-- Ambos previenen doble booking gracias al lock pesimista en mesas
-- + reservas dentro de la transaccion implicita.
-- Solo r.estado = 'Confirmada' cuenta como ocupacion; Cancelada/NoShow
-- no bloquean (historial cancelado libera la mesa para nuevas reservas).
-- =====================================================================

SET search_path TO tombot, public;

-- ---------------------------------------------------------------------
-- Helper: chequea si una hora cae dentro de un turno con formato "9hs - 13hs"
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tombot.fn_hora_en_turno(
    p_hora    INT,
    p_turno   TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_match  TEXT[];
    v_start  INT;
    v_end    INT;
BEGIN
    IF p_turno IS NULL OR p_hora IS NULL THEN
        RETURN FALSE;
    END IF;

    v_match := regexp_matches(p_turno, '(\d{1,2})\s*hs?\s*-\s*(\d{1,2})\s*hs?', 'i');
    IF v_match IS NULL THEN
        RETURN FALSE;
    END IF;

    v_start := v_match[1]::INT;
    v_end   := v_match[2]::INT;

    RETURN p_hora >= v_start AND p_hora < v_end;
END;
$$;

-- ---------------------------------------------------------------------
-- Helper: dos horas caen en la misma franja (alguno de los 3 turnos de la mesa)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tombot.fn_misma_franja(
    p_hora_a            INT,
    p_hora_b            INT,
    p_turno_manana      TEXT,
    p_turno_mediodia    TEXT,
    p_turno_tarde       TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    RETURN
        (p_turno_manana   IS NOT NULL AND
         tombot.fn_hora_en_turno(p_hora_a, p_turno_manana) AND
         tombot.fn_hora_en_turno(p_hora_b, p_turno_manana))
     OR (p_turno_mediodia IS NOT NULL AND
         tombot.fn_hora_en_turno(p_hora_a, p_turno_mediodia) AND
         tombot.fn_hora_en_turno(p_hora_b, p_turno_mediodia))
     OR (p_turno_tarde    IS NOT NULL AND
         tombot.fn_hora_en_turno(p_hora_a, p_turno_tarde) AND
         tombot.fn_hora_en_turno(p_hora_b, p_turno_tarde));
END;
$$;

-- ---------------------------------------------------------------------
-- fn_buscar_mesa_disponible: read-only, sin INSERT
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
               AND r.numero_mesa = m.numero_mesa
               AND tombot.fn_misma_franja(p_horario_hora, r.horario_hora,
                                          m.horario_manana, m.horario_mediodia, m.horario_tarde)
       )
     ORDER BY (m.max_personas - p_personas) ASC,
              m.numero_mesa ASC
     LIMIT 1;

    IF v_numero_mesa IS NOT NULL THEN
        RETURN QUERY SELECT v_numero_mesa, '[]'::jsonb;
        RETURN;
    END IF;

    -- Sin mesa: calcular turnos alternativos del mismo dia
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
                       AND r.numero_mesa = m.numero_mesa
                       AND tombot.fn_hora_en_turno(r.horario_hora, t.turno_label)
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
-- fn_confirmar_reserva: lock + verify + INSERT
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
    p_mesa_preferida TEXT  -- la mesa que ya se le ofrecio al usuario
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
    -- Lock pesimista: serializar contra otras asignaciones del tenant
    PERFORM 1
      FROM tombot.mesas
     WHERE restaurante_id = p_restaurante_id
       AND activa = TRUE
     FOR UPDATE;

    -- 1) Probar la mesa preferida (la que se le ofrecio al usuario)
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
               AND r.numero_mesa = p_mesa_preferida
               AND tombot.fn_misma_franja(p_horario_hora, r.horario_hora,
                                          m.horario_manana, m.horario_mediodia, m.horario_tarde)
        )
        INTO v_disponible;

        IF v_disponible THEN
            v_numero_mesa := p_mesa_preferida;
        END IF;
    END IF;

    -- 2) Si la preferida ya no esta libre, buscar otra equivalente
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
                   AND r.numero_mesa = m.numero_mesa
                   AND tombot.fn_misma_franja(p_horario_hora, r.horario_hora,
                                              m.horario_manana, m.horario_mediodia, m.horario_tarde)
           )
         ORDER BY (m.max_personas - p_personas) ASC,
                  m.numero_mesa ASC
         LIMIT 1;
    END IF;

    -- 3) Si todavia hay mesa, insertar
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

COMMENT ON FUNCTION tombot.fn_buscar_mesa_disponible IS 'Read-only: busca mesa libre o devuelve turnos alternativos del dia.';
COMMENT ON FUNCTION tombot.fn_confirmar_reserva     IS 'Lock + INSERT atomico. Re-verifica disponibilidad antes de persistir.';
