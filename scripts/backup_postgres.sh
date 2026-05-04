#!/usr/bin/env bash
# ----------------------------------------------------------------------
# backup_postgres.sh
# ----------------------------------------------------------------------
# Hace pg_dump del schema 'tombot' (sin tocar el de Evolution API),
# lo comprime con gzip y opcionalmente sube a Google Cloud Storage.
#
# Uso (cron del host, recomendado 03:00 AM diario):
#   0 3 * * * /opt/tombot/scripts/backup_postgres.sh >> /var/log/tombot-backup.log 2>&1
#
# Variables de entorno:
#   PG_CONTAINER       (nombre del container Postgres, default 'postgres')
#   PG_USER            (default 'postgres')
#   PG_DB              (default 'evolution')
#   BACKUP_DIR         (default '/opt/tombot/backups')
#   GCS_BUCKET         (opcional, ej 'gs://tom-bot-backups')
#   RETENCION_DIAS     (default 14)
# ----------------------------------------------------------------------

set -euo pipefail

PG_CONTAINER="${PG_CONTAINER:-postgres}"
PG_USER="${PG_USER:-postgres}"
PG_DB="${PG_DB:-evolution}"
BACKUP_DIR="${BACKUP_DIR:-/opt/tombot/backups}"
GCS_BUCKET="${GCS_BUCKET:-}"
RETENCION_DIAS="${RETENCION_DIAS:-14}"

mkdir -p "$BACKUP_DIR"

TS=$(date -u +'%Y%m%dT%H%M%SZ')
OUT_FILE="$BACKUP_DIR/tombot_${TS}.sql.gz"

echo "[$(date -Iseconds)] Iniciando pg_dump schema=tombot -> $OUT_FILE"

docker exec -t "$PG_CONTAINER" \
    pg_dump -U "$PG_USER" -d "$PG_DB" \
            --schema=tombot \
            --no-owner --no-acl \
            --format=plain \
  | gzip -9 > "$OUT_FILE"

SIZE=$(stat -c%s "$OUT_FILE" 2>/dev/null || stat -f%z "$OUT_FILE")
echo "[$(date -Iseconds)] Dump completo: $OUT_FILE (${SIZE} bytes)"

if [[ -n "$GCS_BUCKET" ]]; then
  echo "[$(date -Iseconds)] Subiendo a $GCS_BUCKET"
  gsutil cp "$OUT_FILE" "$GCS_BUCKET/$(basename "$OUT_FILE")"

  if [[ "$RETENCION_DIAS" -gt 0 ]]; then
    LIMITE=$(date -u -d "$RETENCION_DIAS days ago" +'%Y%m%d')
    gsutil ls "$GCS_BUCKET/tombot_*.sql.gz" 2>/dev/null \
      | awk -v lim="$LIMITE" 'match($0, /tombot_([0-9]{8})/, a) { if (a[1] < lim) print $0 }' \
      | xargs -r -n 1 gsutil rm
  fi
fi

if [[ "$RETENCION_DIAS" -gt 0 ]]; then
  echo "[$(date -Iseconds)] Limpiando backups locales > $RETENCION_DIAS dias"
  find "$BACKUP_DIR" -name 'tombot_*.sql.gz' -mtime +"$RETENCION_DIAS" -print -delete
fi

echo "[$(date -Iseconds)] Backup OK"
