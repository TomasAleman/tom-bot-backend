-- =====================================================================
-- Migration 002: cargar el restaurante actual 'tom-bot' como tenant id=1
-- =====================================================================
-- Idempotente: usa ON CONFLICT para no duplicar.
--
-- IMPORTANTE: las mesas y config de abajo son los DEFAULTS razonables.
-- Despues de correr esta migracion, hay que hacer un sync UNICO desde la
-- Sheet existente para traer la configuracion real (script:
-- scripts/import_from_sheets.js).
-- =====================================================================

SET search_path TO tombot, public;

-- ---------------------------------------------------------------------
-- 1. Insertar tenant 'tom-bot'
-- ---------------------------------------------------------------------
INSERT INTO tombot.restaurantes (
    id, slug, nombre, instancia_evolution, evolution_api_key,
    sheets_id_lectura, timezone, activo
) VALUES (
    1,
    'tom-bot',
    'Mi Restaurante',
    'tom-bot',
    'CD6AD6BACA80-4908-8EA7-51104D8A5ACB',
    '1Nz7sWHCsaV_cMyrVz3jfiglOtnQyNN1DMxv6eHmohwU',
    'America/Argentina/Buenos_Aires',
    TRUE
)
ON CONFLICT (slug) DO UPDATE
    SET nombre = EXCLUDED.nombre,
        evolution_api_key = EXCLUDED.evolution_api_key,
        sheets_id_lectura = EXCLUDED.sheets_id_lectura,
        updated_at = NOW();

-- Resetear secuencia para que los proximos tenants empiecen en 2+
SELECT setval('tombot.restaurantes_id_seq',
              GREATEST((SELECT MAX(id) FROM tombot.restaurantes), 1));

-- ---------------------------------------------------------------------
-- 2. Config default del tenant
-- ---------------------------------------------------------------------
INSERT INTO tombot.config (restaurante_id, parametro, valor, descripcion) VALUES
    (1, 'MensajesMaxSinCompletar', '10', 'Mensajes consecutivos sin reserva antes del bloqueo'),
    (1, 'BloqueoInicialMinutos',   '5',  'Duracion del primer bloqueo (minutos)'),
    (1, 'BloqueMaximoMinutos',     '60', 'Tope maximo de duracion de bloqueo (minutos)'),
    (1, 'AvisarBloqueo',           'true', 'Si se envia mensaje de aviso al usuario al bloquearlo'),
    (1, 'DiasMaxAnticipacion',     '7',  'Maximo de dias de anticipacion para aceptar reservas'),
    (1, 'NombreRestaurante',       'Mi Restaurante', 'Se usa en el mensaje de bienvenida')
ON CONFLICT (restaurante_id, parametro) DO UPDATE
    SET valor = EXCLUDED.valor,
        updated_at = NOW();

-- ---------------------------------------------------------------------
-- 3. Mesas iniciales (DEFAULTS — sobreescribir desde sync con Sheets real)
-- ---------------------------------------------------------------------
INSERT INTO tombot.mesas (
    restaurante_id, numero_mesa, min_personas, max_personas,
    horario_manana, horario_mediodia, horario_tarde
) VALUES
    (1, '1', 1, 2, '9hs - 13hs', '13hs - 17hs', '20hs - 23hs'),
    (1, '2', 2, 4, '9hs - 13hs', '13hs - 17hs', '20hs - 23hs'),
    (1, '3', 4, 6, NULL,         '13hs - 17hs', '20hs - 23hs'),
    (1, '4', 4, 8, NULL,         NULL,          '20hs - 23hs')
ON CONFLICT (restaurante_id, numero_mesa) DO NOTHING;
