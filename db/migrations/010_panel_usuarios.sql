-- =====================================================================
-- Migration 010: tabla `usuarios_panel` para login del panel web
-- =====================================================================
-- Cada restaurante puede tener uno o varios usuarios para acceder al
-- panel administrativo (ver/editar/cancelar reservas, ver mesas, etc).
-- El JWT emitido en /api/auth/login lleva { usuario_id, restaurante_id }
-- y todas las queries del panel filtran por restaurante_id derivado del
-- token (cero acceso cruzado entre tenants).
--
-- Aplicar:
--   psql -U postgres -d evolution -f 010_panel_usuarios.sql
-- =====================================================================

SET search_path TO tombot, public;

CREATE TABLE IF NOT EXISTS tombot.usuarios_panel (
    id              BIGSERIAL PRIMARY KEY,
    restaurante_id  BIGINT      NOT NULL REFERENCES tombot.restaurantes(id) ON DELETE CASCADE,
    email           TEXT        NOT NULL UNIQUE,
    password_hash   TEXT        NOT NULL,
    nombre          TEXT,
    rol             TEXT        NOT NULL DEFAULT 'admin'
                                CHECK (rol IN ('admin','staff')),
    activo          BOOLEAN     NOT NULL DEFAULT TRUE,
    ultimo_login_at TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_usuarios_panel_rest
    ON tombot.usuarios_panel (restaurante_id) WHERE activo = TRUE;

CREATE INDEX IF NOT EXISTS idx_usuarios_panel_email_lower
    ON tombot.usuarios_panel (lower(email));

DROP TRIGGER IF EXISTS trg_usuarios_panel_updated_at ON tombot.usuarios_panel;
CREATE TRIGGER trg_usuarios_panel_updated_at
    BEFORE UPDATE ON tombot.usuarios_panel
    FOR EACH ROW EXECUTE FUNCTION tombot.set_updated_at();

COMMENT ON TABLE tombot.usuarios_panel IS
    'Usuarios con acceso al panel web administrativo, vinculados a un restaurante (tenant)';
