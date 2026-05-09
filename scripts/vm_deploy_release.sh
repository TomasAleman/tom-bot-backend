#!/usr/bin/env bash
#
# Deploy en producción (VM): SOLO desde la rama release.
#
# Uso (en la VM, consola del cloud):
#   chmod +x ~/tom-bot-backend/scripts/vm_deploy_release.sh   # una vez
#   ~/tom-bot-backend/scripts/vm_deploy_release.sh
#
# Variables opcionales:
#   REPO_ROOT       default ~/tom-bot-backend
#   DEPLOY_BRANCH   default release
#   COMPOSE_FILE    ruta al compose core (panel + microservice; ver abajo)
#   IMAGE_NAME      default tom-bot-microservice:latest
#
# COMPOSE_FILE: por defecto $HOME/docker-compose.core.yml (stack core: front + back).
# n8n va aparte en docker-compose.n8n.yml — no lo uses con este script.
# Si el core no está en tu $HOME, exportá la ruta, p. ej.:
#   COMPOSE_FILE=/opt/tombot/docker-compose.core.yml bash scripts/vm_deploy_release.sh

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$HOME/tom-bot-backend}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-release}"
COMPOSE_FILE="${COMPOSE_FILE:-$HOME/docker-compose.core.yml}"
IMAGE_NAME="${IMAGE_NAME:-tom-bot-microservice:latest}"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "ERROR: no existe el archivo de compose: $COMPOSE_FILE" >&2
  echo "" >&2
  echo "Indicá la ruta del stack core (docker-compose.core.yml), por ejemplo:" >&2
  echo "  COMPOSE_FILE=/ruta/completa/docker-compose.core.yml bash scripts/vm_deploy_release.sh" >&2
  echo "" >&2
  echo "Para buscarlo en la VM:" >&2
  echo "  find \"\$HOME\" /opt -maxdepth 5 -name 'docker-compose*.yml' 2>/dev/null" >&2
  exit 1
fi

cd "$REPO_ROOT"
echo "==> Rama actual: $(git rev-parse --abbrev-ref HEAD)"
git fetch origin
git checkout "$DEPLOY_BRANCH"
git pull "origin" "$DEPLOY_BRANCH"

echo "==> docker build + compose"
cd "$REPO_ROOT/microservice"
docker build -t "$IMAGE_NAME" .
docker compose -f "$COMPOSE_FILE" up -d microservice --force-recreate

echo "==> health"
curl -sS "http://127.0.0.1:3000/health" || true
echo
curl -sI "http://127.0.0.1:3000/admin/" | head -5 || true
echo "Listo (backend desde $DEPLOY_BRANCH)."
