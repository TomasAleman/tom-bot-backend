-- =====================================================================
-- Migration 012: turnos en formato HH:MM-HH:MM (granularidad 15 min)
-- =====================================================================
-- Cambios:
--  1) Normaliza datos existentes en tombot.mesas que tengan formato viejo
--     ("8-11", "12-15", "20-23") al nuevo formato HH:MM-HH:MM ("08:00-11:00").
--  2) Reescribe tombot.fn_hora_en_turno para parsear HH:MM-HH:MM y comparar
--     en minutos. Mantiene la firma (p_hora INT, p_turno TEXT) y la semantica
--     end-exclusiva (>= start AND < end), por lo que fn_misma_franja,
--     fn_buscar_mesa_disponible y fn_confirmar_reserva siguen funcionando
--     sin cambios.
--
-- Idempotente: la normalizacion solo toca filas con formato viejo y la
-- funcion se redefine con CREATE OR REPLACE.
--
-- Aplicar:
--   psql -U evo -d evolution -f 012_turnos_hh_mm.sql
-- =====================================================================

SET search_path TO tombot, public;

-- ---------------------------------------------------------------------
-- 1) Normalizar datos viejos en tombot.mesas
-- ---------------------------------------------------------------------
-- "8-11"  -> "08:00-11:00"
-- "12-15" -> "12:00-15:00"
-- "20-23" -> "20:00-23:00"
UPDATE tombot.mesas
   SET horario_manana = lpad(split_part(horario_manana, '-', 1), 2, '0') || ':00-' ||
                        lpad(split_part(horario_manana, '-', 2), 2, '0') || ':00'
 WHERE horario_manana ~ '^\d{1,2}-\d{1,2}$';

UPDATE tombot.mesas
   SET horario_mediodia = lpad(split_part(horario_mediodia, '-', 1), 2, '0') || ':00-' ||
                          lpad(split_part(horario_mediodia, '-', 2), 2, '0') || ':00'
 WHERE horario_mediodia ~ '^\d{1,2}-\d{1,2}$';

UPDATE tombot.mesas
   SET horario_tarde = lpad(split_part(horario_tarde, '-', 1), 2, '0') || ':00-' ||
                       lpad(split_part(horario_tarde, '-', 2), 2, '0') || ':00'
 WHERE horario_tarde ~ '^\d{1,2}-\d{1,2}$';

-- ---------------------------------------------------------------------
-- 2) Nueva fn_hora_en_turno: parsea HH:MM-HH:MM y compara en minutos
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
    v_sh     INT;
    v_sm     INT;
    v_eh     INT;
    v_em     INT;
    v_smin   INT;
    v_emin   INT;
    v_hmin   INT;
BEGIN
    IF p_turno IS NULL OR p_hora IS NULL THEN
        RETURN FALSE;
    END IF;

    v_match := regexp_matches(p_turno, '^\s*(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})\s*$');
    IF v_match IS NULL THEN
        RETURN FALSE;
    END IF;

    v_sh := v_match[1]::INT;
    v_sm := v_match[2]::INT;
    v_eh := v_match[3]::INT;
    v_em := v_match[4]::INT;

    v_smin := v_sh * 60 + v_sm;
    v_emin := v_eh * 60 + v_em;
    v_hmin := p_hora * 60;

    RETURN v_hmin >= v_smin AND v_hmin < v_emin;
END;
$$;

COMMENT ON FUNCTION tombot.fn_hora_en_turno IS
  'Devuelve TRUE si la hora entera (en horas) cae dentro del turno HH:MM-HH:MM (inicio inclusivo, fin exclusivo).';
