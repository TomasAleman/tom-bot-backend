-- =====================================================================
-- Migration 002: cargar el restaurante actual 'tom-bot' como tenant id=1
-- =====================================================================
-- Idempotente: ON CONFLICT en restaurantes/config/mesas. Config y mesas usan el
-- id del restaurante con slug 'tom-bot' (no asumen id=1: si el slug ya existía
-- con otro id, el INSERT ... ON CONFLICT (slug) DO UPDATE no cambia el PK).
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
-- 2. Config default del tenant (usa el id real del slug tom-bot, no asume id=1)
-- ---------------------------------------------------------------------
INSERT INTO tombot.config (restaurante_id, parametro, valor, descripcion)
SELECT r.id, v.parametro, v.valor, v.descripcion
FROM tombot.restaurantes r
CROSS JOIN (
    VALUES
        ('MensajesMaxSinCompletar', '10', 'Mensajes consecutivos sin reserva antes del bloqueo'),
        ('BloqueoInicialMinutos',   '5',  'Duracion del primer bloqueo (minutos)'),
        ('BloqueMaximoMinutos',     '60', 'Tope maximo de duracion de bloqueo (minutos)'),
        ('AvisarBloqueo',           'true', 'Si se envia mensaje de aviso al usuario al bloquearlo'),
        ('DiasMaxAnticipacion',     '7',  'Maximo de dias de anticipacion para aceptar reservas'),
        ('NombreRestaurante',       'Mi Restaurante', 'Se usa en el mensaje de bienvenida')
) AS v(parametro, valor, descripcion)
WHERE r.slug = 'tom-bot'
ON CONFLICT (restaurante_id, parametro) DO UPDATE
    SET valor = EXCLUDED.valor,
        updated_at = NOW();

-- ---------------------------------------------------------------------
-- 3. Mesas iniciales (DEFAULTS — sobreescribir desde sync con Sheets real)
-- ---------------------------------------------------------------------
INSERT INTO tombot.mesas (
    restaurante_id, numero_mesa, min_personas, max_personas,
    horario_manana, horario_mediodia, horario_tarde
)
SELECT r.id, m.numero_mesa, m.min_personas, m.max_personas,
       m.horario_manana, m.horario_mediodia, m.horario_tarde
FROM tombot.restaurantes r
CROSS JOIN (
    VALUES
        ('1'::text, 1::int, 2::int, '9hs - 13hs'::text, '13hs - 17hs'::text, '20hs - 23hs'::text),
        ('2', 2, 4, '9hs - 13hs', '13hs - 17hs', '20hs - 23hs'),
        ('3', 4, 6, NULL::text, '13hs - 17hs', '20hs - 23hs'),
        ('4', 4, 8, NULL::text, NULL::text, '20hs - 23hs')
) AS m(numero_mesa, min_personas, max_personas, horario_manana, horario_mediodia, horario_tarde)
WHERE r.slug = 'tom-bot'
ON CONFLICT (restaurante_id, numero_mesa) DO NOTHING;
