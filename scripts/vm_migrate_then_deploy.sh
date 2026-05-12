#!/usr/bin/env bash
#
# En la VM: aplica todas las migraciones SQL (db/migrations) y luego el deploy
# del microservicio (mismo flujo que vm_deploy_release.sh).
#
# Requisitos:
#   - PGURL apuntando al Postgres donde existe el esquema tombot (misma cadena
#     que usa el contenedor microservice).
#   - Node.js + npm en la VM (para npm ci y apply_migrations.js).
#   - Docker + compose del stack core (COMPOSE_FILE).
#
# Uso:
#   export PGURL='postgres://USER:PASS@HOST:5432/DATABASE'
#   export COMPOSE_FILE=/ruta/docker-compose.core.yml   # opcional
#   bash ~/tom-bot-backend/scripts/vm_migrate_then_deploy.sh
#
# Variables:
#   REPO_ROOT     default: directorio padre de este script (raíz del repo)
#   SKIP_NPM      si es 1, no ejecuta npm ci (asumís node_modules al día)
#   SKIP_MIGRATE  si es 1, solo deploy (emergencia)
#   SKIP_DEPLOY   si es 1, solo migraciones
#

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SKIP_NPM="${SKIP_NPM:-0}"
SKIP_MIGRATE="${SKIP_MIGRATE:-0}"
SKIP_DEPLOY="${SKIP_DEPLOY:-0}"

if [[ -z "${PGURL:-}" && "$SKIP_MIGRATE" != "1" ]]; then
  echo "ERROR: definí PGURL (cadena postgres://... igual que en el microservicio)." >&2
  echo "Ejemplo: export PGURL='postgres://postgres:SECRET@127.0.0.1:5432/evolution'" >&2
  echo "Ayuda: bash \"$REPO_ROOT/scripts/vm_print_pgurl_hint.sh\"" >&2
  exit 1
fi

# Placeholder típico de la documentación: produce getaddrinfo ENOTFOUND ...
if [[ "$SKIP_MIGRATE" != "1" ]]; then
  if [[ "${PGURL}" == 'postgres://...' ]] || [[ "${PGURL}" =~ @\.\.\.[:/] ]]; then
    echo "ERROR: PGURL usa el host literal '...' (placeholder). No es una URL real." >&2
    echo "Obtené la cadena del contenedor microservice o del docker-compose (variable PGURL)." >&2
    echo "  bash \"$REPO_ROOT/scripts/vm_print_pgurl_hint.sh\"" >&2
    exit 1
  fi
fi

cd "$REPO_ROOT"

if [[ "$SKIP_NPM" != "1" ]]; then
  echo "==> npm ci en microservice (paquete pg para apply_migrations.js)"
  (cd "$REPO_ROOT/microservice" && npm ci)
else
  echo "==> SKIP_NPM=1: se omite npm ci"
fi

if [[ "$SKIP_MIGRATE" != "1" ]]; then
  echo "==> Aplicando migraciones: node scripts/apply_migrations.js"
  export NODE_PATH="$REPO_ROOT/microservice/node_modules"
  node "$REPO_ROOT/scripts/apply_migrations.js"
else
  echo "==> SKIP_MIGRATE=1: se omiten migraciones"
fi

if [[ "$SKIP_DEPLOY" != "1" ]]; then
  echo "==> Deploy microservicio: vm_deploy_release.sh"
  bash "$REPO_ROOT/scripts/vm_deploy_release.sh"
else
  echo "==> SKIP_DEPLOY=1: se omite vm_deploy_release.sh"
fi

echo "Listo. Recordatorio: UPDATE TelefonoReservas en tombot.config, n8n activo, curl /health."
