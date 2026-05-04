#!/usr/bin/env bash
# ----------------------------------------------------------------------
# restore_postgres.sh
# ----------------------------------------------------------------------
# Restaura un backup del schema 'tombot' generado por backup_postgres.sh.
#
# Uso:
#   ./scripts/restore_postgres.sh /opt/tombot/backups/tombot_20260427T030000Z.sql.gz
#
# IMPORTANTE: hace DROP SCHEMA tombot CASCADE antes de restaurar.
# Pide confirmacion.
# ----------------------------------------------------------------------

set -euo pipefail

PG_CONTAINER="${PG_CONTAINER:-postgres}"
PG_USER="${PG_USER:-postgres}"
PG_DB="${PG_DB:-evolution}"

if [[ $# -ne 1 ]]; then
  echo "Uso: $0 <archivo .sql.gz>"
  exit 1
fi

FILE="$1"
if [[ ! -f "$FILE" ]]; then
  echo "Archivo no encontrado: $FILE"
  exit 1
fi

echo "ATENCION: vas a DROP SCHEMA tombot CASCADE y restaurar desde $FILE"
read -r -p "Escribi 'restaurar' para continuar: " CONFIRM
if [[ "$CONFIRM" != "restaurar" ]]; then
  echo "Cancelado"
  exit 1
fi

echo "Drop schema..."
docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
  -c "DROP SCHEMA IF EXISTS tombot CASCADE;"

echo "Restaurando..."
gunzip -c "$FILE" | docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB"

echo "Restore OK"
