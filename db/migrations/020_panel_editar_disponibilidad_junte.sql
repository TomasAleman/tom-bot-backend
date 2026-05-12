-- =====================================================================
-- Migration 020: disponibilidad al editar (excluir reserva) + modificar junte
-- =====================================================================
-- 1) fn_suma_capacidad_mesas_libres: parámetro opcional p_excluir_reserva_id
--    para no contar la propia reserva al listar cupo junte (panel edición).
-- 2) fn_modificar_reserva_junte: actualiza día/hora/personas/nombre con
--    varias mesas (reserva_mesas), ocupación excluyendo la fila editada.
-- =====================================================================

SET search_path TO tombot, public;

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
               AND r.estado = 'Confirmada'
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

COMMENT ON FUNCTION tombot.fn_suma_capacidad_mesas_libres(BIGINT, DATE, INT, BIGINT) IS
  'Suma max_personas de mesas libres en franja; opcionalmente ignora una reserva (edición panel).';

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
      FROM tombot.reservas
     WHERE id = p_reserva_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF v_res.estado <> 'Confirmada' THEN
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
      FROM tombot.mesas
     WHERE restaurante_id = v_res.restaurante_id
       AND activa = TRUE
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
           AND r.estado = 'Confirmada'
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
