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
# Si printenv PGURL devuelve host "postgres" (nombre del servicio en Docker),
# las migraciones se ejecutan DENTRO de un contenedor Node en la misma red
# (no hace falta cambiar a 127.0.0.1).
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

# Placeholders que generan ENOTFOUND (no copies literalmente "..." o "....")
if [[ "$SKIP_MIGRATE" != "1" ]]; then
  if [[ "${PGURL}" == 'postgres://...' ]] || [[ "${PGURL}" =~ @\.{3,}[:/] ]]; then
    echo "ERROR: PGURL parece un placeholder (... o .... como host)." >&2
    echo "Pegá la salida COMPLETA de: docker exec <contenedor_micro> printenv PGURL" >&2
    echo "  bash \"$REPO_ROOT/scripts/vm_print_pgurl_hint.sh\"" >&2
    exit 1
  fi
fi

cd "$REPO_ROOT"

MIGRATE_VIA_DOCKER=0
MIGRATE_HOST=""
if [[ "$SKIP_MIGRATE" != "1" ]]; then
  if ! MIGRATE_HOST="$(node -p "new URL(process.env.PGURL).hostname" 2>/dev/null)"; then
    echo "ERROR: PGURL no es una URL válida (revisá comillas y caracteres especiales en la contraseña)." >&2
    exit 1
  fi
  if [[ "$MIGRATE_HOST" =~ ^[.]+$ ]]; then
    echo "ERROR: el hostname de PGURL es solo puntos ($MIGRATE_HOST). No uses .... como host." >&2
    exit 1
  fi
  MH_LC=$(printf '%s' "$MIGRATE_HOST" | tr '[:upper:]' '[:lower:]')
  if [[ "$MH_LC" == "postgres" ]]; then
    MIGRATE_VIA_DOCKER=1
  fi
fi

# npm ci en el host solo hace falta si aplicamos migraciones con Node en el host
if [[ "$SKIP_NPM" != "1" ]]; then
  if [[ "$SKIP_MIGRATE" == "1" ]] || [[ "$MIGRATE_VIA_DOCKER" == "0" ]]; then
    echo "==> npm ci en microservice (paquete pg para apply_migrations.js)"
    (cd "$REPO_ROOT/microservice" && npm ci)
  else
    echo "==> npm ci se ejecutará dentro del contenedor de migración (host postgres=Docker)"
  fi
else
  echo "==> SKIP_NPM=1: se omite npm ci en el host"
fi

if [[ "$SKIP_MIGRATE" != "1" ]]; then
  if [[ "$MIGRATE_VIA_DOCKER" == "1" ]]; then
    echo "==> Aplicando migraciones vía Docker (host PGURL=$MIGRATE_HOST → red del compose)"
    bash "$REPO_ROOT/scripts/vm_apply_migrations_docker.sh"
  else
    echo "==> Aplicando migraciones en el host: node scripts/apply_migrations.js"
    export NODE_PATH="$REPO_ROOT/microservice/node_modules"
    node "$REPO_ROOT/scripts/apply_migrations.js"
  fi
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
