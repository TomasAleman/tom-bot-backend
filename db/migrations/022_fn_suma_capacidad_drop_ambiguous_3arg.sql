-- =====================================================================
-- Migration 022: fn_suma_capacidad_mesas_libres — quitar sobrecarga 3-arg
-- =====================================================================
-- La 018 define fn(bigint, date, int). La 020 añade un 4.º parámetro con
-- DEFAULT NULL. En PostgreSQL ambas firmas conviven; una llamada con 3
-- argumentos matchea las dos → ERROR 42725 "function ... is not unique"
-- (p. ej. n8n: SELECT fn_suma_capacidad_mesas_libres($1,$2,$3)).
-- Solución: eliminar solo la variante de 3 argumentos. Las llamadas con 3
-- argumentos usan el DEFAULT del 4.º (NULL) en la variante de 020.
-- Requiere que la 020 ya esté aplicada (función de 4 parámetros existente).
-- =====================================================================

SET search_path TO tombot, public;

DROP FUNCTION IF EXISTS tombot.fn_suma_capacidad_mesas_libres(bigint, date, integer);
