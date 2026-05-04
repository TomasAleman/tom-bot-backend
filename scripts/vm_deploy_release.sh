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
#   COMPOSE_FILE    default ~/docker-compose.prod.yml
#   IMAGE_NAME      default tom-bot-microservice:latest

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$HOME/tom-bot-backend}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-release}"
COMPOSE_FILE="${COMPOSE_FILE:-$HOME/docker-compose.prod.yml}"
IMAGE_NAME="${IMAGE_NAME:-tom-bot-microservice:latest}"

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
