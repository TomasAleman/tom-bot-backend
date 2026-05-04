#!/usr/bin/env bash
#
# Sube microservice/ a la VM por rsync y reconstruye la imagen.
# Regla: ejecutar solo estando en la rama release (código = producción).
#
# Preferido en VM: git pull en release + scripts/vm_deploy_release.sh
# Este script sirve si desde tu PC (Git Bash/WSL) tenés SSH a la VM.
#
# Requiere: VM_USER, VM_HOST
# Opcional: VM_MS_DIR (default ~/tom-bot-backend/microservice), SSH_PORT (22),
#           SKIP_RSYNC, SKIP_BUILD, COMPOSE_REMOTE, ALLOW_NON_RELEASE_DEPLOY=1
#
# Ejemplo:
#   git checkout release && git pull origin release
#   VM_USER=alemanmdq VM_HOST=IP_VM ./scripts/deploy_microservice.sh

set -euo pipefail

if [ -z "${VM_USER:-}" ] || [ -z "${VM_HOST:-}" ]; then
  echo "ERROR: VM_USER y VM_HOST son obligatorios." >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -d "$ROOT_DIR/.git" ] && [ "${ALLOW_NON_RELEASE_DEPLOY:-0}" != "1" ]; then
  cd "$ROOT_DIR"
  BR=$(git rev-parse --abbrev-ref HEAD)
  if [ "$BR" != "release" ]; then
    echo "ERROR: deploy_microservice.sh solo se usa en rama release (rama actual: $BR)." >&2
    echo "  Hacé merge develop -> release, checkout release, y reintentá." >&2
    echo "  Emergencia: ALLOW_NON_RELEASE_DEPLOY=1 ..." >&2
    exit 1
  fi
fi

SSH_PORT="${SSH_PORT:-22}"
VM_MS_DIR="${VM_MS_DIR:-~/tom-bot-backend/microservice}"
COMPOSE_REMOTE="${COMPOSE_REMOTE:-~/docker-compose.prod.yml}"
IMAGE_NAME="${IMAGE_NAME:-tom-bot-microservice:latest}"

MS_DIR="$ROOT_DIR/microservice"
SSH=(ssh -p "$SSH_PORT" "$VM_USER@$VM_HOST")
RSYNC=(rsync -az -e "ssh -p $SSH_PORT")

if [ ! -f "$MS_DIR/Dockerfile" ]; then
  echo "ERROR: falta $MS_DIR/Dockerfile" >&2
  exit 1
fi

if [ -z "${SKIP_RSYNC:-}" ]; then
  echo "==> rsync -> remoto:$VM_MS_DIR"
  "${SSH[@]}" "mkdir -p $VM_MS_DIR"
  "${RSYNC[@]}" --delete --exclude node_modules --exclude .env \
    "$MS_DIR/" "$VM_USER@$VM_HOST:$VM_MS_DIR/"
  "${SSH[@]}" "ls -la $VM_MS_DIR/src/server.js"
else
  echo "==> SKIP_RSYNC"
fi

if [ -z "${SKIP_BUILD:-}" ]; then
  echo "==> docker build + compose (remoto)"
  "${SSH[@]}" "cd $VM_MS_DIR && docker build -t $IMAGE_NAME . && docker compose -f $COMPOSE_REMOTE up -d microservice --force-recreate"
else
  echo "==> SKIP_BUILD"
fi

echo "Listo. Probar: curl -sI http://127.0.0.1:3000/admin/ | head -5"
