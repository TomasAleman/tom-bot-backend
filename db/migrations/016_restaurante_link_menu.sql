-- =====================================================================
-- Migration 016: link del menú y flag "mostrar menú" por restaurante
-- =====================================================================
-- link_menu: URL del menú (PDF, web, etc.) mostrada por el bot en WhatsApp.
-- mostrar_menu: si false, el bot no ofrece la opción "Ver el menú".
--
-- Idempotente.
-- =====================================================================

SET search_path TO tombot, public;

ALTER TABLE tombot.restaurantes
    ADD COLUMN IF NOT EXISTS link_menu TEXT;

ALTER TABLE tombot.restaurantes
    ADD COLUMN IF NOT EXISTS mostrar_menu BOOLEAN NOT NULL DEFAULT TRUE;

COMMENT ON COLUMN tombot.restaurantes.link_menu IS
    'URL del menú del restaurante (WhatsApp / bot opción Ver menú).';
COMMENT ON COLUMN tombot.restaurantes.mostrar_menu IS
    'Si true, el bot puede mostrar la opción Ver el menú (requiere link_menu no vacío en la lógica del workflow).';
