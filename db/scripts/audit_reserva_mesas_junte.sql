-- Auditoría: junte con reserva_mesas incompleto respecto a la mesa principal.
-- Tras un junte correcto, r.numero_mesa debería aparecer también en reserva_mesas
-- (fn_confirmar_reserva_junte inserta todas las mesas del array).
--
-- Ejecutar en psql contra la base del tenant:
--   \i db/scripts/audit_reserva_mesas_junte.sql

SET search_path TO tombot, public;

SELECT r.id,
       r.restaurante_id,
       r.dia,
       r.horario_hora,
       r.numero_mesa AS mesa_principal,
       (SELECT COUNT(*)::int FROM tombot.reserva_mesas rm WHERE rm.reserva_id = r.id) AS filas_rm
  FROM tombot.reservas r
 WHERE lower(trim(r.estado)) = 'confirmada'
   AND EXISTS (SELECT 1 FROM tombot.reserva_mesas rm WHERE rm.reserva_id = r.id)
   AND NOT EXISTS (
         SELECT 1
           FROM tombot.reserva_mesas rm
          WHERE rm.reserva_id = r.id
            AND rm.numero_mesa = r.numero_mesa
       )
 ORDER BY r.restaurante_id, r.dia, r.horario_hora, r.id;
