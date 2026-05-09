#!/usr/bin/env bash
# Aplica en Postgres la migración 015 (horario_hora en minutos 0–1439 + funciones).
# Ejecutar en la VM **después** de `git pull` en tom-bot-backend (rama release).
#
# Requisitos: psql instalado y acceso a la base donde está el schema `tombot`.
#
# Configurá conexión (elige una forma):
#   export PGHOST=127.0.0.1 PGPORT=5432 PGUSER=evo PGDATABASE=evolution
#   export PGPASSWORD='...'   # opcional; preferible ~/.pgpass
#
# Si el repo no está en ~/tom-bot-backend:
#   export TOMBOT_BACKEND_ROOT=/ruta/al/tom-bot-backend

set -euo pipefail

ROOT="${TOMBOT_BACKEND_ROOT:-$HOME/tom-bot-backend}"
SQL="$ROOT/db/migrations/015_horario_minutos.sql"

if [[ ! -f "$SQL" ]]; then
  echo "No se encontró: $SQL"
  echo "Ajustá TOMBOT_BACKEND_ROOT o cloná/actualizá tom-bot-backend."
  exit 1
fi

psql -v ON_ERROR_STOP=1 -f "$SQL"
echo "Listo: 015_horario_minutos.sql aplicada."
