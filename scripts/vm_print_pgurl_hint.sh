#!/usr/bin/env bash
#
# Ayuda para copiar PGURL en la VM (misma cadena que usa el microservicio).
# No imprime secretos en logs masivos: solo muestra comandos a ejecutar vos.
#
# Uso:
#   bash scripts/vm_print_pgurl_hint.sh
#   COMPOSE_FILE=/ruta/docker-compose.core.yml bash scripts/vm_print_pgurl_hint.sh
#

set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-$HOME/docker-compose.core.yml}"

echo "=== Cómo obtener PGURL en la VM ==="
echo ""
echo "1) Si el contenedor del API ya está corriendo, el valor suele estar en su entorno:"
echo "   docker ps --format 'table {{.Names}}\t{{.Image}}' | grep -i micro"
echo "   docker exec <NOMBRE_CONTENEDOR> printenv PGURL"
echo ""
echo "2) Si tenés el compose del stack core, buscá la variable en el servicio microservice:"
if [[ -f "$COMPOSE_FILE" ]]; then
  echo "   (encontrado: $COMPOSE_FILE)"
  echo "   grep -n 'PGURL' \"$COMPOSE_FILE\" | head -20"
else
  echo "   (no existe $COMPOSE_FILE — exportá COMPOSE_FILE con la ruta real)"
  echo "   grep -n 'PGURL' /ruta/a/docker-compose.core.yml"
fi
echo ""
echo "3) Copiá el valor COMPLETO (usuario, contraseña, host, puerto, base) y exportalo:"
echo "   export PGURL='postgres://USUARIO:CONTRASENA@IP_O_HOST:5432/NOMBRE_DB'"
echo ""
echo "No uses el texto literal '...' como host: eso produce ENOTFOUND."
