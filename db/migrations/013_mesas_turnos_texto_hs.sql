-- =====================================================================
-- Migration 013: normaliza turnos tipo "9hs - 13hs" / "9 hs - 13 hs"
-- =====================================================================
-- La migracion 012 solo convertia patrones exactos N-N (digitos solos).
-- En algunos entornos los datos ya venian como texto con "hs", por ejemplo:
--   "9hs - 13hs", "20hs - 23hs"
-- Esos no coincidian con el WHERE de 012 y quedaron sin convertir.
--
-- Esta migracion:
--   1) Convierte ese formato a HH:MM-HH:MM (minutos en :00).
--   2) Vuelve a definir fn_hora_en_turno (idempotente) por si 012 no llego
--      a aplicarse en algun servidor.
--
-- Idempotente: las filas ya en HH:MM-HH:MM no se modifican.
-- =====================================================================

SET search_path TO tombot, public;

-- ---------------------------------------------------------------------
-- 1) Normalizar "Nhs - Mhs" (variaciones de espacios / mayusculas)
-- ---------------------------------------------------------------------
UPDATE tombot.mesas
   SET horario_manana = lpad(sub.a, 2, '0') || ':00-' || lpad(sub.b, 2, '0') || ':00'
  FROM (
    SELECT id AS mid,
           (regexp_match(
             trim(horario_manana),
             '^[[:space:]]*([[:digit:]]{1,2})[[:space:]]*hs?[[:space:]]-[[:space:]]*([[:digit:]]{1,2})[[:space:]]*hs?[[:space:]]*$',
             'i'
           ))[1] AS a,
           (regexp_match(
             trim(horario_manana),
             '^[[:space:]]*([[:digit:]]{1,2})[[:space:]]*hs?[[:space:]]-[[:space:]]*([[:digit:]]{1,2})[[:space:]]*hs?[[:space:]]*$',
             'i'
           ))[2] AS b
      FROM tombot.mesas
  ) sub
 WHERE tombot.mesas.id = sub.mid
   AND sub.a IS NOT NULL
   AND sub.b IS NOT NULL
   AND tombot.mesas.horario_manana IS NOT NULL
   AND trim(tombot.mesas.horario_manana) <> ''
   AND trim(tombot.mesas.horario_manana) !~ '^[[:space:]]*[[:digit:]]{1,2}:[[:digit:]]{2}-[[:digit:]]{1,2}:[[:digit:]]{2}[[:space:]]*$';

UPDATE tombot.mesas
   SET horario_mediodia = lpad(sub.a, 2, '0') || ':00-' || lpad(sub.b, 2, '0') || ':00'
  FROM (
    SELECT id AS mid,
           (regexp_match(
             trim(horario_mediodia),
             '^[[:space:]]*([[:digit:]]{1,2})[[:space:]]*hs?[[:space:]]-[[:space:]]*([[:digit:]]{1,2})[[:space:]]*hs?[[:space:]]*$',
             'i'
           ))[1] AS a,
           (regexp_match(
             trim(horario_mediodia),
             '^[[:space:]]*([[:digit:]]{1,2})[[:space:]]*hs?[[:space:]]-[[:space:]]*([[:digit:]]{1,2})[[:space:]]*hs?[[:space:]]*$',
             'i'
           ))[2] AS b
      FROM tombot.mesas
  ) sub
 WHERE tombot.mesas.id = sub.mid
   AND sub.a IS NOT NULL
   AND sub.b IS NOT NULL
   AND tombot.mesas.horario_mediodia IS NOT NULL
   AND trim(tombot.mesas.horario_mediodia) <> ''
   AND trim(tombot.mesas.horario_mediodia) !~ '^[[:space:]]*[[:digit:]]{1,2}:[[:digit:]]{2}-[[:digit:]]{1,2}:[[:digit:]]{2}[[:space:]]*$';

UPDATE tombot.mesas
   SET horario_tarde = lpad(sub.a, 2, '0') || ':00-' || lpad(sub.b, 2, '0') || ':00'
  FROM (
    SELECT id AS mid,
           (regexp_match(
             trim(horario_tarde),
             '^[[:space:]]*([[:digit:]]{1,2})[[:space:]]*hs?[[:space:]]-[[:space:]]*([[:digit:]]{1,2})[[:space:]]*hs?[[:space:]]*$',
             'i'
           ))[1] AS a,
           (regexp_match(
             trim(horario_tarde),
             '^[[:space:]]*([[:digit:]]{1,2})[[:space:]]*hs?[[:space:]]-[[:space:]]*([[:digit:]]{1,2})[[:space:]]*hs?[[:space:]]*$',
             'i'
           ))[2] AS b
      FROM tombot.mesas
  ) sub
 WHERE tombot.mesas.id = sub.mid
   AND sub.a IS NOT NULL
   AND sub.b IS NOT NULL
   AND tombot.mesas.horario_tarde IS NOT NULL
   AND trim(tombot.mesas.horario_tarde) <> ''
   AND trim(tombot.mesas.horario_tarde) !~ '^[[:space:]]*[[:digit:]]{1,2}:[[:digit:]]{2}-[[:digit:]]{1,2}:[[:digit:]]{2}[[:space:]]*$';

-- ---------------------------------------------------------------------
-- 2) fn_hora_en_turno (misma definicion que 012; CREATE OR REPLACE)
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

    -- POSIX ([[:digit:]] etc.) para compatibilidad con todas las versiones de Postgres en VPS.
    v_match := regexp_matches(
      p_turno,
      '^[[:space:]]*([[:digit:]]{1,2}):([[:digit:]]{2})-([[:digit:]]{1,2}):([[:digit:]]{2})[[:space:]]*$'
    );
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
