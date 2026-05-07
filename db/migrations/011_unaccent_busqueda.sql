-- =====================================================================
-- Migration 011: extensión `unaccent` para búsqueda insensible a tildes
-- =====================================================================
-- El panel web busca reservas por nombre (`/api/reservas?q=...`). Con
-- ILIKE ya cubrimos may/min, pero "Tomas" no matchea "Tomás" porque el
-- acento cuenta como otro carácter. La extensión `unaccent` viene en
-- contrib de Postgres y permite normalizar los acentos del lado server.
--
-- Idempotente: se puede correr varias veces sin romper.
--
-- Aplicar:
--   psql -U postgres -d evolution -f 011_unaccent_busqueda.sql
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS unaccent;
