# shellcheck shell=bash
# Cargar con: source "$(dirname "${BASH_SOURCE[0]}")/vm_resolve_compose.inc.sh"
# Requiere: REPO_ROOT (raíz del repo tom-bot-backend). Opcional: COMPOSE_FILE entrante.
#
# Si COMPOSE_FILE no existe, es un placeholder (..., ....) o está vacío, intenta
# rutas habituales en la VM. Actualiza la variable COMPOSE_FILE en el shell actual.

vm_resolve_compose_file() {
  local f="${COMPOSE_FILE:-}"
  if [[ -n "$f" && "$f" != "..." && ! "$f" =~ ^\.+$ && -f "$f" ]]; then
    echo "==> COMPOSE_FILE=$f" >&2
    COMPOSE_FILE="$f"
    return 0
  fi

  if [[ "$f" == "..." ]] || [[ "$f" =~ ^\.+$ ]]; then
    echo "ADVERTENCIA: COMPOSE_FILE era un placeholder ($f); buscando docker-compose…" >&2
  elif [[ -n "$f" ]]; then
    echo "ADVERTENCIA: no existe el archivo ($f); buscando docker-compose…" >&2
  fi

  local root="${REPO_ROOT:-$HOME/tom-bot-backend}"
  local guess
  for guess in \
    "$HOME/docker-compose.core.yml" \
    "/opt/tombot/docker-compose.core.yml" \
    "/opt/tombot/docker-compose.yml" \
    "$(dirname "$root")/docker-compose.core.yml" \
    "$root/docker-compose.core.yml"; do
    [[ -f "$guess" ]] || continue
    echo "==> COMPOSE_FILE autodetectado: $guess" >&2
    COMPOSE_FILE="$guess"
    return 0
  done

  echo "ERROR: no encontré docker-compose.core.yml." >&2
  echo "Exportá la ruta absoluta real, por ejemplo:" >&2
  echo "  export COMPOSE_FILE=/opt/tombot/docker-compose.core.yml" >&2
  echo "  find \"\$HOME\" /opt -maxdepth 5 -name 'docker-compose*.yml' 2>/dev/null" >&2
  return 1
}
