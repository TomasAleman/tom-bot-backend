-- =====================================================================
-- Migration 001: esquema base multi-tenant para tom-bot
-- =====================================================================
-- Crea el esquema 'tombot' aislado del esquema de Evolution API.
-- Idempotente: se puede correr varias veces sin romper.
--
-- Aplicar:
--   psql -U postgres -d evolution -f 001_init_schema.sql
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS tombot;
SET search_path TO tombot, public;

-- ---------------------------------------------------------------------
-- restaurantes: un row por tenant
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tombot.restaurantes (
    id                  BIGSERIAL PRIMARY KEY,
    slug                TEXT        NOT NULL UNIQUE,
    nombre              TEXT        NOT NULL,
    instancia_evolution TEXT        NOT NULL UNIQUE,
    evolution_api_key   TEXT        NOT NULL,
    sheets_id_lectura   TEXT,
    timezone            TEXT        NOT NULL DEFAULT 'America/Argentina/Buenos_Aires',
    activo              BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_restaurantes_activo
    ON tombot.restaurantes (activo) WHERE activo = TRUE;

-- ---------------------------------------------------------------------
-- mesas: configuracion de mesas por restaurante
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tombot.mesas (
    id                  BIGSERIAL PRIMARY KEY,
    restaurante_id      BIGINT      NOT NULL REFERENCES tombot.restaurantes(id) ON DELETE CASCADE,
    numero_mesa         TEXT        NOT NULL,
    min_personas        INT         NOT NULL CHECK (min_personas >= 0),
    max_personas        INT         NOT NULL CHECK (max_personas >= min_personas),
    horario_manana      TEXT,
    horario_mediodia    TEXT,
    horario_tarde       TEXT,
    activa              BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (restaurante_id, numero_mesa)
);

CREATE INDEX IF NOT EXISTS idx_mesas_restaurante_activa
    ON tombot.mesas (restaurante_id) WHERE activa = TRUE;

-- ---------------------------------------------------------------------
-- config: parametros configurables por restaurante
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tombot.config (
    restaurante_id      BIGINT      NOT NULL REFERENCES tombot.restaurantes(id) ON DELETE CASCADE,
    parametro           TEXT        NOT NULL,
    valor               TEXT        NOT NULL,
    descripcion         TEXT,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (restaurante_id, parametro)
);

-- ---------------------------------------------------------------------
-- sesiones: estado de conversacion por (tenant, telefono)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tombot.sesiones (
    restaurante_id      BIGINT      NOT NULL REFERENCES tombot.restaurantes(id) ON DELETE CASCADE,
    telefono            TEXT        NOT NULL,
    primer_contacto     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    contexto_reserva    JSONB       NOT NULL DEFAULT '{}'::jsonb,
    contador_mensajes   INT         NOT NULL DEFAULT 0,
    bloqueo_hasta       TIMESTAMPTZ,
    bloqueo_minutos     INT         NOT NULL DEFAULT 0,
    ultimo_mensaje_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (restaurante_id, telefono)
);

CREATE INDEX IF NOT EXISTS idx_sesiones_ultimo_mensaje
    ON tombot.sesiones (ultimo_mensaje_at);

CREATE INDEX IF NOT EXISTS idx_sesiones_bloqueo_hasta
    ON tombot.sesiones (bloqueo_hasta) WHERE bloqueo_hasta IS NOT NULL;

-- ---------------------------------------------------------------------
-- reservas: historial de reservas (multi-tenant)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tombot.reservas (
    id                  BIGSERIAL PRIMARY KEY,
    restaurante_id      BIGINT      NOT NULL REFERENCES tombot.restaurantes(id) ON DELETE RESTRICT,
    nombre              TEXT        NOT NULL,
    telefono            TEXT        NOT NULL,
    dia                 DATE        NOT NULL,
    horario_hora        INT         NOT NULL CHECK (horario_hora BETWEEN 0 AND 23),
    horario_label       TEXT        NOT NULL,
    turno               TEXT,
    personas            INT         NOT NULL CHECK (personas > 0),
    numero_mesa         TEXT        NOT NULL,
    estado              TEXT        NOT NULL DEFAULT 'Confirmada'
                                    CHECK (estado IN ('Confirmada','Cancelada','NoShow')),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_reservas_rest_dia_estado
    ON tombot.reservas (restaurante_id, dia, estado);

CREATE INDEX IF NOT EXISTS idx_reservas_rest_telefono
    ON tombot.reservas (restaurante_id, telefono, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_reservas_rest_dia_mesa
    ON tombot.reservas (restaurante_id, dia, numero_mesa)
    WHERE estado = 'Confirmada';

-- ---------------------------------------------------------------------
-- eventos_log: para observability (volumen, latencia, errores)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tombot.eventos_log (
    id                  BIGSERIAL PRIMARY KEY,
    restaurante_id      BIGINT      REFERENCES tombot.restaurantes(id) ON DELETE SET NULL,
    telefono_hash       TEXT,
    tipo_evento         TEXT        NOT NULL,
    payload             JSONB       NOT NULL DEFAULT '{}'::jsonb,
    latencia_ms         INT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_eventos_rest_created
    ON tombot.eventos_log (restaurante_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_eventos_tipo_created
    ON tombot.eventos_log (tipo_evento, created_at DESC);

-- ---------------------------------------------------------------------
-- Trigger generico para mantener updated_at actualizado
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tombot.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_restaurantes_updated_at ON tombot.restaurantes;
CREATE TRIGGER trg_restaurantes_updated_at
    BEFORE UPDATE ON tombot.restaurantes
    FOR EACH ROW EXECUTE FUNCTION tombot.set_updated_at();

DROP TRIGGER IF EXISTS trg_mesas_updated_at ON tombot.mesas;
CREATE TRIGGER trg_mesas_updated_at
    BEFORE UPDATE ON tombot.mesas
    FOR EACH ROW EXECUTE FUNCTION tombot.set_updated_at();

DROP TRIGGER IF EXISTS trg_reservas_updated_at ON tombot.reservas;
CREATE TRIGGER trg_reservas_updated_at
    BEFORE UPDATE ON tombot.reservas
    FOR EACH ROW EXECUTE FUNCTION tombot.set_updated_at();

-- ---------------------------------------------------------------------
-- Vista util: mesas ocupadas por turno y dia (calculada en runtime)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW tombot.v_reservas_confirmadas_dia AS
SELECT
    r.restaurante_id,
    r.dia,
    r.numero_mesa,
    r.horario_hora,
    r.turno
FROM tombot.reservas r
WHERE r.estado = 'Confirmada';

COMMENT ON SCHEMA tombot IS 'Datos operacionales del bot de reservas multi-tenant';
COMMENT ON TABLE tombot.restaurantes IS 'Tenants del SaaS — un row por restaurante';
COMMENT ON TABLE tombot.mesas IS 'Configuracion de mesas por tenant';
COMMENT ON TABLE tombot.sesiones IS 'Estado de conversacion (working memory persistido)';
COMMENT ON TABLE tombot.reservas IS 'Historial de reservas multi-tenant';
COMMENT ON TABLE tombot.eventos_log IS 'Logs estructurados para observability';
