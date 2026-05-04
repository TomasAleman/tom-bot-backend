#!/usr/bin/env bash
#
# Sube microservice/ a la VM y reconstruye la imagen (sin git en la VM).
#
# Requiere: VM_USER, VM_HOST
# Opcional: VM_MS_DIR (default ~/tom-bot-microservice-src), SSH_PORT (22),
#           SKIP_RSYNC, SKIP_BUILD, COMPOSE_REMOTE (default ~/docker-compose.prod.yml)
#
# Ejemplo (Git Bash / WSL, desde la raíz del kit):
#   VM_USER=alemanmdq VM_HOST=IP_DE_LA_VM ./scripts/deploy_microservice.sh

set -euo pipefail

if [ -z "${VM_USER:-}" ] || [ -z "${VM_HOST:-}" ]; then
  echo "ERROR: VM_USER y VM_HOST son obligatorios." >&2
  echo "  VM_USER=alemanmdq VM_HOST=1.2.3.4 ./scripts/deploy_microservice.sh" >&2
  exit 1
fi

SSH_PORT="${SSH_PORT:-22}"
# Ruta remota con el Dockerfile (tilde se expande en la VM vía ssh/rsync).
VM_MS_DIR="${VM_MS_DIR:-~/tom-bot-microservice-src}"
COMPOSE_REMOTE="${COMPOSE_REMOTE:-~/docker-compose.prod.yml}"
IMAGE_NAME="${IMAGE_NAME:-tom-bot-microservice:latest}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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
  echo "==> SKIP_BUILD (en la VM: cd al directorio con Dockerfile y docker build ...)"
fi

echo "Listo. Probar: curl -sI http://127.0.0.1:3000/admin/ | head -5"
