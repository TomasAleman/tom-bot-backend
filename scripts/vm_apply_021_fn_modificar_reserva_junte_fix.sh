#!/usr/bin/env bash
# Aplica migración 021: corrige "column reference id is ambiguous" en
# tombot.fn_modificar_reserva_junte (PATCH panel con mesas[] / junte).
#
#   export PG_DOCKER_CONTAINER=evo-postgres
#   export PGUSER=evo PGDATABASE=evolution
#   bash scripts/vm_apply_021_fn_modificar_reserva_junte_fix.sh

set -euo pipefail

ROOT="${TOMBOT_BACKEND_ROOT:-$HOME/tom-bot-backend}"
SQL="$ROOT/db/migrations/021_fn_modificar_reserva_junte_fix_ambiguous_id.sql"

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
  echo "Definí PG_DOCKER_CONTAINER + PGUSER + PGDATABASE (ver comentarios al inicio del script)."
  exit 1
fi

echo "Listo: 021_fn_modificar_reserva_junte_fix_ambiguous_id.sql aplicada."
