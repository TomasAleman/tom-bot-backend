#!/usr/bin/env bash
# Aplica migración 022: elimina la sobrecarga (bigint,date,int) duplicada de
# fn_suma_capacidad_mesas_libres para corregir "function ... is not unique"
# en n8n / Postgres al llamar con 3 argumentos.
#
#   export PG_DOCKER_CONTAINER=evo-postgres
#   export PGUSER=evo PGDATABASE=evolution
#   bash scripts/vm_apply_022_fn_suma_capacidad_drop_ambiguous_3arg.sh

set -euo pipefail

ROOT="${TOMBOT_BACKEND_ROOT:-$HOME/tom-bot-backend}"
SQL="$ROOT/db/migrations/022_fn_suma_capacidad_drop_ambiguous_3arg.sql"

if [[ ! -f "$SQL" ]]; then
  echo "No se encontró: $SQL"
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
  echo "Definí PG_DOCKER_CONTAINER + PGUSER + PGDATABASE o instalá psql."
  exit 1
fi

echo "Listo: 022_fn_suma_capacidad_drop_ambiguous_3arg.sql aplicada."
