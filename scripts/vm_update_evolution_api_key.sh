#!/usr/bin/env bash
# Actualiza tombot.restaurantes.evolution_api_key en Postgres (VM / Docker).
#
# Por qué: n8n envía WhatsApp con header apikey = esta columna. Si no coincide
# con la clave de la instancia en Evolution Manager → 401 y no llega el mensaje.
#
# 1) En Evolution Manager abrí la instancia (ej. tom-bot) y copiá la API Key.
# 2) En la VM:
#
#   export PG_DOCKER_CONTAINER=evo-postgres
#   export PGUSER=evo
#   export PGDATABASE=evolution
#   export PGPASSWORD='…'   # si tu psql dentro del contenedor la pide
#
#   EVOLUTION_API_KEY='PEGÁ_LA_CLAVE_AQUÍ' bash scripts/vm_update_evolution_api_key.sh
#
# Opcional (si el slug/instancia no es tom-bot):
#   TOMBOT_INSTANCIA_O_SLUG=mi-instancia EVOLUTION_API_KEY='…' bash scripts/vm_update_evolution_api_key.sh
#
# O por argumentos:
#   bash scripts/vm_update_evolution_api_key.sh 'PEGÁ_LA_CLAVE' 'tom-bot'

set -euo pipefail

KEY="${EVOLUTION_API_KEY:-${1:-}}"
TARGET="${TOMBOT_INSTANCIA_O_SLUG:-${2:-tom-bot}}"

if [[ -z "$KEY" ]]; then
  echo "Uso:"
  echo "  EVOLUTION_API_KEY='tu-clave-de-evolution-manager' bash scripts/vm_update_evolution_api_key.sh"
  echo "  bash scripts/vm_update_evolution_api_key.sh 'tu-clave' ['slug-o-instancia']"
  exit 1
fi

# Escapar comillas simples para SQL estándar
key_sql=${KEY//\'/''}
tgt_sql=${TARGET//\'/''}

SQL=$(cat <<EOSQL
SET search_path TO tombot, public;
UPDATE tombot.restaurantes
   SET evolution_api_key = '${key_sql}',
       updated_at = NOW()
 WHERE slug = '${tgt_sql}'
    OR instancia_evolution = '${tgt_sql}';

SELECT id, slug, instancia_evolution,
       length(evolution_api_key) AS key_len,
       substring(evolution_api_key, 1, 6) || '...' AS key_preview
  FROM tombot.restaurantes
 WHERE slug = '${tgt_sql}'
    OR instancia_evolution = '${tgt_sql}';
EOSQL
)

run_psql() {
  if command -v psql >/dev/null 2>&1 && [[ -z "${PG_DOCKER_CONTAINER:-}" ]]; then
    echo "$SQL" | psql -v ON_ERROR_STOP=1
  elif [[ -n "${PG_DOCKER_CONTAINER:-}" ]]; then
    if ! command -v docker >/dev/null 2>&1; then
      echo "PG_DOCKER_CONTAINER está definido pero 'docker' no está en PATH."
      exit 1
    fi
    if [[ -n "${PGPASSWORD:-}" ]]; then
      echo "$SQL" | docker exec -i -e PGPASSWORD="$PGPASSWORD" "$PG_DOCKER_CONTAINER" \
        psql -v ON_ERROR_STOP=1 -U "${PGUSER:?definí PGUSER}" -d "${PGDATABASE:?definí PGDATABASE}"
    else
      echo "$SQL" | docker exec -i "$PG_DOCKER_CONTAINER" \
        psql -v ON_ERROR_STOP=1 -U "${PGUSER:?definí PGUSER}" -d "${PGDATABASE:?definí PGDATABASE}"
    fi
  else
    echo "Instalá psql o definí PG_DOCKER_CONTAINER + PGUSER + PGDATABASE (como en vm_apply_016)."
    exit 1
  fi
}

run_psql

echo
echo "Listo. Probar de nuevo un 'Hola' en WhatsApp. Si sigue 401, la clave no es la de esa instancia o la URL de Evolution en n8n no apunta al mismo servidor."
