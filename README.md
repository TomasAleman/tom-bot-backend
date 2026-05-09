# tom-bot-backend

Microservicio Fastify (hot path WhatsApp + API del panel) y migraciones SQL del bot de reservas.

## Ramas (flujo de trabajo)

| Rama | Uso |
|------|-----|
| **`main`** | Historial estable inicial; podés alinearla con `release` cuando quieras. |
| **`develop`** | Rama donde trabajás día a día: features, fixes, `git push`. |
| **`release`** | **Única rama desde la que se despliega a producción.** Cuando algo está listo, mergeás `develop` → `release` y subís `release`. |

**Regla:** en la VM **nunca** hagas deploy desde `develop`. Siempre `checkout release` + `git pull` (o el script `vm_deploy_release.sh`).

### Crear `develop` y `release` la primera vez (en tu PC)

```bash
cd ~/ruta/al/clon/tom-bot-backend   # o C:\proyectos\tom-bot-backend
git checkout main
git pull origin main
git checkout -b develop
git push -u origin develop
git checkout -b release
git push -u origin release
```

### Publicar a producción (en tu PC)

```bash
git checkout develop
# ... commits, push ...
git checkout release
git merge develop
git push origin release
```

Luego en la **VM**: deploy con `vm_deploy_release.sh` o los comandos manuales de abajo.

## Estructura

```
microservice/   API + hot path (Node.js + Fastify, contenedor Docker)
db/             Migraciones SQL (idempotentes) + scripts puntuales
scripts/        Utilidades operativas + deploy
```

## Variables de entorno

El microservicio lee estas variables (definidas en `docker-compose.core.yml` del stack core en la VM, o en `.env` local). **n8n** corre en otro archivo: `docker-compose.n8n.yml`.

| Variable | Para qué |
|----------|----------|
| `PGURL` | Connection string Postgres |
| `REDIS_URL` | Connection string Redis |
| `EVOLUTION_URL` | Base URL de Evolution API |
| `GROQ_API_KEY` | API key Groq (parser hot path WhatsApp) |
| `JWT_SECRET` | Secreto para firmar tokens del panel (`openssl rand -hex 48`) |
| `PANEL_PUBLIC_DIR` | Directorio del bundle del panel (default `/opt/tombot/panel-public`) |
| `PORT` | Default `3000` |
| `LOG_LEVEL` | `info` \| `debug` \| `warn` \| `error` |

Plantilla en [microservice/.env.example](microservice/.env.example). **Nunca** comitear `.env`.

## Build local (sin Docker)

```
cd microservice
npm ci
npm start
```

## Deploy en la VM (solo rama `release`)

### Opción A — Script recomendado (en la VM)

```bash
chmod +x ~/tom-bot-backend/scripts/vm_deploy_release.sh   # una vez
~/tom-bot-backend/scripts/vm_deploy_release.sh
```

Equivale a: `git fetch`, `checkout release`, `pull`, `docker build` en `microservice/`, `docker compose up --force-recreate`.

Variables opcionales: `REPO_ROOT`, `DEPLOY_BRANCH` (default `release`), `COMPOSE_FILE`, `IMAGE_NAME`.

El script asume el compose core en `~/docker-compose.core.yml`. Si está en otra ruta, exportá `COMPOSE_FILE` antes de ejecutar (si no, falla con *no such file*):

`COMPOSE_FILE=/ruta/a/docker-compose.core.yml ~/tom-bot-backend/scripts/vm_deploy_release.sh`

### Opción B — Comandos manuales (misma regla: rama `release`)

```bash
cd ~/tom-bot-backend
git fetch origin
git checkout release
git pull origin release
cd microservice
docker build -t tom-bot-microservice:latest .
docker compose -f ~/docker-compose.core.yml up -d microservice --force-recreate
curl -sI http://127.0.0.1:3000/admin/ | head -3
```

### Opción C — Desde tu PC con SSH + rsync

Solo con **`git checkout release`** y código al día:

```bash
VM_USER=alemanmdq VM_HOST=IP_VM ./scripts/deploy_microservice.sh
```

Emergencia (no recomendado): `ALLOW_NON_RELEASE_DEPLOY=1 VM_USER=... VM_HOST=... ./scripts/deploy_microservice.sh`

### Primera vez (clone inicial)

```bash
sudo apt update && sudo apt install -y git
cd ~
git clone https://github.com/TomasAleman/tom-bot-backend.git
cd tom-bot-backend
git checkout release   # después de crear la rama en GitHub
git pull origin release
cd microservice
docker build -t tom-bot-microservice:latest .
docker compose -f ~/docker-compose.core.yml up -d microservice --force-recreate
```

## Migraciones DB

```
PGURL='postgres://...' node scripts/apply_migrations.js
```

Crear usuario inicial del panel:

```
PGURL='postgres://...' node scripts/crear_usuario_panel.js \
  --slug tom-bot --email vos@tu-resto.com --password una-segura
```

## Scripts incluidos

- **`scripts/vm_deploy_release.sh`** — deploy en VM desde `release` (docker).
- **`scripts/deploy_microservice.sh`** — rsync desde PC + build remoto (solo rama `release`).
- `scripts/apply_migrations.js`, `scripts/crear_usuario_panel.js`, backup/restore, etc.

## Troubleshooting

### Reservas duplicadas en el panel

Si en la pestaña **Reservas** ves filas repetidas, primero descartá que sean
duplicados reales en la BD. Conectate al Postgres del contenedor y corré
(reemplazá `1` por el `restaurante_id` correspondiente):

```sql
SELECT id, restaurante_id, telefono, dia, horario_hora, estado,
       count(*) OVER (PARTITION BY id) AS dup
  FROM tombot.reservas
 WHERE restaurante_id = 1
 ORDER BY id DESC
 LIMIT 50;
```

Interpretación:

- Si `dup` siempre vale `1`, no hay duplicados reales: el panel ya los
  filtra del lado cliente (deduplicación por `id`) y el `ORDER BY` del
  backend incluye `r.id` como tiebreaker, por lo que la paginación no
  debería repetir filas. El bug está cerrado.
- Si aparece `dup > 1`, hay reservas verdaderamente repetidas en la base.
  Borralas a mano (`DELETE … WHERE id IN (…)`) e investigá el origen
  (insert duplicado en el flujo de WhatsApp / n8n).

Para abrir un `psql` rápido en la VM:

```bash
docker exec -it evo-postgres psql -U postgres -d postgres
```

