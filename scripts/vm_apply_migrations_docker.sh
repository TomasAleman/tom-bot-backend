#!/usr/bin/env bash
#
# Ejecuta apply_migrations.js dentro de un contenedor Node en la MISMA red Docker
# que el microservicio, para que PGURL con host "postgres" (nombre del servicio
# compose) resuelva igual que dentro del API.
#
# Requisitos: Docker, docker compose v2, COMPOSE_FILE válido, servicio microservice
# levantado (o al menos un contenedor del compose para tomar la red).
#
# Variables:
#   PGURL         obligatorio (ej. salida de printenv: ...@postgres:5432/evolution)
#   COMPOSE_FILE  default ~/docker-compose.core.yml
#   REPO_ROOT     default raíz del repo
#   COMPOSE_SERVICE  default microservice (para tomar red y nombre del proyecto)
#

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
COMPOSE_FILE="${COMPOSE_FILE:-$HOME/docker-compose.core.yml}"
COMPOSE_SERVICE="${COMPOSE_SERVICE:-microservice}"

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/vm_resolve_compose.inc.sh"
vm_resolve_compose_file || exit 1

if [[ -z "${PGURL:-}" ]]; then
  echo "ERROR: definí PGURL" >&2
  exit 1
fi

CID=$(docker compose -f "$COMPOSE_FILE" ps -q "$COMPOSE_SERVICE" 2>/dev/null | head -1 || true)
if [[ -z "$CID" ]]; then
  echo "ERROR: no hay contenedor corriendo para el servicio '$COMPOSE_SERVICE'." >&2
  echo "Levantá el stack o cambiá COMPOSE_SERVICE al servicio que comparta red con Postgres." >&2
  exit 1
fi

NET=$(docker inspect "$CID" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' | awk '{print $1; exit}')
if [[ -z "$NET" ]]; then
  echo "ERROR: no pude leer la red Docker del contenedor $CID" >&2
  exit 1
fi

echo "==> Migraciones vía Docker (red: $NET, compose: $COMPOSE_FILE)"

docker run --rm \
  -v "$REPO_ROOT:/repo" \
  -w /repo \
  --network "$NET" \
  -e PGURL="$PGURL" \
  node:20-bookworm-slim \
  bash -lc 'set -euo pipefail; cd /repo/microservice && npm ci && export NODE_PATH=/repo/microservice/node_modules && node /repo/scripts/apply_migrations.js'
