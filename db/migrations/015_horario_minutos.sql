-- =====================================================================
-- Migration 015: horario_hora en minutos desde medianoche (0-1439)
-- =====================================================================
-- Antes: horario_hora era hora entera 0-23; fn_hora_en_turno hacia p_hora*60.
-- Ahora: horario_hora almacena minutos (21:30 -> 1290). fn_hora_en_turno
-- compara p_hora directamente con el rango del turno HH:MM-HH:MM.
--
-- Idempotencia datos: solo filas con horario_hora entre 0 y 23 inclusive.
-- =====================================================================

SET search_path TO tombot, public;

-- ---------------------------------------------------------------------
-- 1) Helpers nuevos (sin depender de fn_hora_en_turno)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tombot.fn_horario_label_desde_minutos(p_min INT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_min IS NULL OR p_min < 0 OR p_min > 1439 THEN NULL
    ELSE lpad(((p_min / 60) % 24)::text, 2, '0') || ':' ||
         lpad((p_min % 60)::text, 2, '0') || 'hs'
  END;
$$;

CREATE OR REPLACE FUNCTION tombot.fn_parse_minutos_desde_texto(p_valor TEXT)
RETURNS INT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v      TEXT;
    v_h    INT;
    v_m    INT;
    v_all  INT;
    v_pair TEXT[];
BEGIN
    IF p_valor IS NULL THEN
        RETURN NULL;
    END IF;

    v := trim(both from p_valor);
    IF v = '' THEN
        RETURN NULL;
    END IF;

    IF v ~ '^\d+$' THEN
        v_all := v::INT;
        IF v_all >= 0 AND v_all <= 23 THEN
            RETURN v_all * 60;
        END IF;
        IF v_all >= 24 AND v_all <= 1439 THEN
            RETURN v_all;
        END IF;
        RETURN NULL;
    END IF;

    v_pair := regexp_matches(v, '^(\d{1,2})[:.,](\d{2})$');
    IF v_pair IS NOT NULL THEN
        v_h := v_pair[1]::INT;
        v_m := v_pair[2]::INT;
        IF v_h < 0 OR v_h > 23 OR v_m < 0 OR v_m > 59 THEN
            RETURN NULL;
        END IF;
        RETURN v_h * 60 + v_m;
    END IF;

    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION tombot.fn_parse_minutos_desde_texto IS
  'Convierte texto de hora a minutos 0-1439 (n8n/modificar/panel).';

-- ---------------------------------------------------------------------
-- 2) Migrar filas que aun guardaban hora 0-23 (minutos = hora*60)
-- ---------------------------------------------------------------------
UPDATE tombot.reservas
   SET horario_hora = horario_hora * 60,
       horario_label = tombot.fn_horario_label_desde_minutos(horario_hora * 60)
 WHERE horario_hora IS NOT NULL
   AND horario_hora BETWEEN 0 AND 23;

-- ---------------------------------------------------------------------
-- 3) fn_hora_en_turno: p_hora = minutos desde medianoche
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

    RETURN p_hora >= v_smin AND p_hora < v_emin;
END;
$$;

COMMENT ON FUNCTION tombot.fn_hora_en_turno IS
  'TRUE si p_hora (minutos desde medianoche 0-1439) cae en turno HH:MM-HH:MM (inicio inclusivo, fin exclusivo).';

-- ---------------------------------------------------------------------
-- 4) fn_modificar_reserva: rama horario usa parse + label
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
            v_target_hora  := tombot.fn_parse_minutos_desde_texto(p_valor);
            IF v_target_hora IS NULL THEN
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
  'Modifica reserva; horario en p_valor como HH:MM, minutos 0-1439, o hora 0-23 (legacy).';
