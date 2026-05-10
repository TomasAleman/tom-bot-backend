#!/usr/bin/env bash
# ----------------------------------------------------------------------
# Borra (o resetea) todas las sesiones del bot — pensado para correr en la VM.
#
# Requisitos: psql en PATH; opcional redis-cli si querés limpiar caché.
#
# Uso:
#   export PGURL='postgres://USUARIO:PASS@HOST:5432/evolution'
#   ./borrar_sesiones_vm.sh              # borra filas (por defecto)
#   MODE=reset ./borrar_sesiones_vm.sh   # solo vacía contexto (como reset_contexto_todas_sesiones.sql)
#   SKIP_REDIS=1 ./borrar_sesiones_vm.sh # no toca Redis
#
# Redis (opcional): misma URL que el microservicio, ej.
#   export REDIS_URL='redis://127.0.0.1:6379'
# ----------------------------------------------------------------------

set -euo pipefail

MODE="${MODE:-delete}"   # delete | reset
SKIP_REDIS="${SKIP_REDIS:-0}"

if [[ -z "${PGURL:-}" ]]; then
  echo "Falta PGURL (connection string a la misma DB que usa n8n / tombot)." >&2
  echo "Ejemplo: export PGURL='postgres://evo:****@localhost:5432/evolution'" >&2
  exit 1
fi

echo "== Postgres (${MODE}) =="

if [[ "$MODE" == "reset" ]]; then
  psql "$PGURL" -v ON_ERROR_STOP=1 <<'SQL'
SET search_path TO tombot, public;
UPDATE tombot.sesiones
   SET contexto_reserva  = '{}'::jsonb,
       contador_mensajes = 0,
       bloqueo_hasta     = NULL,
       bloqueo_minutos   = 0,
       ultimo_mensaje_at = NOW();
SELECT count(*)::bigint AS filas_actualizadas FROM tombot.sesiones;
SQL
else
  psql "$PGURL" -v ON_ERROR_STOP=1 <<'SQL'
SET search_path TO tombot, public;
DELETE FROM tombot.sesiones;
SELECT 'sesiones_borradas' AS ok;
SQL
fi

if [[ "$SKIP_REDIS" != "1" && -n "${REDIS_URL:-}" ]]; then
  if ! command -v redis-cli >/dev/null 2>&1; then
    echo "Aviso: REDIS_URL está definido pero no hay redis-cli; saltando Redis." >&2
  else
    echo "== Redis (claves sesion:*) =="
    # Borra en lotes para no saturar argv
    redis-cli -u "$REDIS_URL" --scan --pattern 'sesion:*' \
      | xargs -r -n 500 redis-cli -u "$REDIS_URL" del \
      || true
    echo "Listo (si no había claves, es normal que no muestre nada)."
  fi
else
  echo "Redis omitido (SKIP_REDIS=1 o REDIS_URL vacío)."
fi

echo "Hecho."
