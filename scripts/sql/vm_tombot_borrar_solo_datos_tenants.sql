-- =====================================================================
-- PELIGRO: borra reservas, sesiones, mesas, config y restaurantes de tombot.
-- NO borra usuarios_panel con restaurante_id NULL (superadmin del panel).
--
-- Usar solo si vas a recrear el tenant desde cero (Evolution + superadmin
-- o seed manual). Hacé backup antes:
--   docker exec evo-postgres pg_dump -U evo -d evolution -n tombot > backup_tombot.sql
--
-- Aplicar (VM):
--   export PG_DOCKER_CONTAINER=evo-postgres PGUSER=evo PGDATABASE=evolution
--   cat scripts/sql/vm_tombot_borrar_solo_datos_tenants.sql | docker exec -i $PG_DOCKER_CONTAINER \
--     psql -v ON_ERROR_STOP=1 -U $PGUSER -d $PGDATABASE
-- =====================================================================

SET search_path TO tombot, public;

BEGIN;

DELETE FROM tombot.reserva_mesas;
DELETE FROM tombot.reservas;
DELETE FROM tombot.eventos_log;
DELETE FROM tombot.sesiones;
DELETE FROM tombot.config;
DELETE FROM tombot.mesas;
DELETE FROM tombot.usuarios_panel WHERE restaurante_id IS NOT NULL;
DELETE FROM tombot.restaurantes;

COMMIT;

SELECT 'tombot: datos de tenants borrados. Superadmin (restaurante_id NULL) conservado.' AS estado;
