-- =====================================================================
-- Migration 014: RBAC roles (superadmin/admin_restaurante/recepcionista)
-- =====================================================================
-- - Permite usuarios superadmin sin restaurante_id (NULL)
-- - Migra roles legacy: admin -> admin_restaurante, staff -> recepcionista
-- - Agrega checks de consistencia rol/restaurante_id
-- =====================================================================

SET search_path TO tombot, public;

-- 1) Permitir restaurante_id NULL para soportar superadmin.
ALTER TABLE IF EXISTS tombot.usuarios_panel
  ALTER COLUMN restaurante_id DROP NOT NULL;

-- 2) Migrar roles legacy (idempotente).
UPDATE tombot.usuarios_panel
   SET rol = 'admin_restaurante'
 WHERE rol = 'admin';

UPDATE tombot.usuarios_panel
   SET rol = 'recepcionista'
 WHERE rol = 'staff';

-- 3) Dropear CHECK viejo de rol (nombre desconocido) y recrearlo con nombre estable.
DO $$
DECLARE
  c RECORD;
BEGIN
  FOR c IN
    SELECT conname
      FROM pg_constraint
     WHERE contype = 'c'
       AND conrelid = 'tombot.usuarios_panel'::regclass
       AND pg_get_constraintdef(oid) ILIKE '%rol%'
       AND pg_get_constraintdef(oid) ILIKE '%IN%'
  LOOP
    EXECUTE format('ALTER TABLE tombot.usuarios_panel DROP CONSTRAINT IF EXISTS %I', c.conname);
  END LOOP;
END $$;

ALTER TABLE tombot.usuarios_panel
  ADD CONSTRAINT chk_usuarios_panel_rol
  CHECK (rol IN ('superadmin','admin_restaurante','recepcionista'));

-- 4) Consistencia: superadmin -> restaurante_id NULL; resto -> NOT NULL.
ALTER TABLE tombot.usuarios_panel
  DROP CONSTRAINT IF EXISTS chk_usuarios_panel_tenant_consistente;

ALTER TABLE tombot.usuarios_panel
  ADD CONSTRAINT chk_usuarios_panel_tenant_consistente
  CHECK (
    (rol = 'superadmin' AND restaurante_id IS NULL)
    OR
    (rol <> 'superadmin' AND restaurante_id IS NOT NULL)
  );

