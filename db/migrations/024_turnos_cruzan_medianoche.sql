-- =====================================================================
-- Migration 024: turnos que cruzan medianoche (ej. 19:00-00:30)
-- =====================================================================
-- Si fin_min <= inicio_min en HH:MM-HH:MM, el turno cruza medianoche:
--   p_hora >= inicio OR p_hora < fin (inicio inclusivo, fin exclusivo).
-- Si fin_min > inicio_min: comportamiento previo (mismo día calendario).
--
-- Aplicar:
--   psql -U evo -d evolution -f 024_turnos_cruzan_medianoche.sql
-- =====================================================================

SET search_path TO tombot, public;

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

    IF v_emin = v_smin THEN
        RETURN FALSE;
    END IF;

    IF v_emin < v_smin THEN
        RETURN p_hora >= v_smin OR p_hora < v_emin;
    END IF;

    RETURN p_hora >= v_smin AND p_hora < v_emin;
END;
$$;

COMMENT ON FUNCTION tombot.fn_hora_en_turno IS
  'TRUE si p_hora (minutos 0-1439) cae en turno HH:MM-HH:MM (inicio inclusivo, fin exclusivo). '
  'Si fin <= inicio en el texto del turno, cruza medianoche (OR).';
