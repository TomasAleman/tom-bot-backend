#!/usr/bin/env bash
# Aplica en Postgres la migración 015 (horario_hora en minutos 0–1439 + funciones).
# Ejecutar en la VM **después** de `git pull` en tom-bot-backend (rama release).
#
# Conexión (host):
#   export PGHOST=127.0.0.1 PGPORT=5432 PGUSER=evo PGDATABASE=evolution
#   export PGPASSWORD='...'   # opcional; preferible ~/.pgpass
#
# Si Postgres corre en Docker y la VM no tiene psql:
#   export PG_DOCKER_CONTAINER=nombre_del_contenedor   # ver: docker ps
#   export PGUSER=evo PGDATABASE=evolution
#   bash scripts/vm_apply_015_horario_minutos.sh
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

if command -v psql >/dev/null 2>&1; then
  psql -v ON_ERROR_STOP=1 -f "$SQL"
elif [[ -n "${PG_DOCKER_CONTAINER:-}" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "PG_DOCKER_CONTAINER está definido pero 'docker' no está en PATH."
    exit 1
  fi
  if [[ -n "${PGPASSWORD:-}" ]]; then
    cat "$SQL" | docker exec -i -e PGPASSWORD="$PGPASSWORD" "$PG_DOCKER_CONTAINER" \
      psql -v ON_ERROR_STOP=1 -U "${PGUSER:?definí PGUSER}" -d "${PGDATABASE:?definí PGDATABASE}"
  else
    cat "$SQL" | docker exec -i "$PG_DOCKER_CONTAINER" \
      psql -v ON_ERROR_STOP=1 -U "${PGUSER:?definí PGUSER}" -d "${PGDATABASE:?definí PGDATABASE}"
  fi
else
  echo "No se encontró el cliente 'psql' en esta máquina."
  echo ""
  echo "Opción A — instalar cliente (Ubuntu/Debian):"
  echo "  sudo apt-get update && sudo apt-get install -y postgresql-client"
  echo "  luego volvé a ejecutar este script."
  echo ""
  echo "Opción B — Postgres solo en Docker (sin psql en el host):"
  echo "  docker ps    # buscá el contenedor de Postgres (evolution, postgres, etc.)"
  echo "  export PG_DOCKER_CONTAINER=nombre_del_contenedor"
  echo "  export PGUSER=evo PGDATABASE=evolution"
  echo "  bash scripts/vm_apply_015_horario_minutos.sh"
  exit 1
fi

echo "Listo: 015_horario_minutos.sql aplicada."
