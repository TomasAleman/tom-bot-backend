#!/usr/bin/env bash
#
# En tu PC: checklist para publicar a producción (rama release).
# No modifica el repo; solo imprime los comandos habituales.
#
# Flujo documentado en README.md: merge develop → release → push.
#

set -euo pipefail

cat <<'EOF'
=== En tu PC (antes de la VM) ===

1) Commits en develop (o en la rama donde trabajes):
   git checkout develop
   git pull origin develop
   # ... desarrollo ...
   git push origin develop

2) Publicar a release (solo desde PC, con revisión):
   git checkout release
   git pull origin release
   git merge develop
   # Resolver conflictos si aparecen, luego:
   git push origin release

3) Si también cambió el panel:
   cd ../tom-bot-frontend   # ajustá ruta
   git checkout release && git pull && git merge develop && git push origin release

4) En la VM, seguí deploy.md sección "En la VM" o ejecutá:
   bash ~/tom-bot-backend/scripts/vm_migrate_then_deploy.sh
   (con PGURL y opcionalmente COMPOSE_FILE exportados)

EOF
