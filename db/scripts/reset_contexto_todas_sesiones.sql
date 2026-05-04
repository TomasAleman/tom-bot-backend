-- ----------------------------------------------------------------------
-- Reset de contexto de TODAS las sesiones (todos los teléfonos / tenants)
-- ----------------------------------------------------------------------
-- Deja contexto vacío, contador de mensajes en 0 y sin bloqueo.
-- NO borra reservas ni mesas.
-- Ejecutar contra la misma base que usa n8n (ej. evolution, schema tombot).
-- ----------------------------------------------------------------------

SET search_path TO tombot, public;

UPDATE tombot.sesiones
   SET contexto_reserva  = '{}'::jsonb,
       contador_mensajes = 0,
       bloqueo_hasta     = NULL,
       bloqueo_minutos   = 0,
       ultimo_mensaje_at = NOW();

SELECT count(*)::bigint AS sesiones_reseteadas
  FROM tombot.sesiones;
