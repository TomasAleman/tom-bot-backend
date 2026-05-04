# tom-bot-backend

Microservicio Fastify (hot path WhatsApp + API del panel) y migraciones SQL del bot de reservas.

## Estructura

```
microservice/   API + hot path (Node.js + Fastify, contenedor Docker)
db/             Migraciones SQL (idempotentes) + scripts puntuales
scripts/        Utilidades operativas (migrar, backup, alta de usuarios, deploy)
```

## Variables de entorno

El microservicio lee estas variables (definidas en `~/docker-compose.prod.yml` en la VM o en `.env` local):

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

## Deploy en la VM (git pull + docker compose)

Una vez que la VM tiene el repo clonado en `~/tom-bot-backend`:

```
cd ~/tom-bot-backend && git pull
cd microservice
docker build -t tom-bot-microservice:latest .
docker compose -f ~/docker-compose.prod.yml up -d microservice --force-recreate
curl -sI http://127.0.0.1:3000/admin/ | head -3
```

### Primera vez (clone inicial)

```
sudo apt update && sudo apt install -y git
cd ~
git clone https://github.com/TomasAleman/tom-bot-backend.git
cd tom-bot-backend/microservice
docker build -t tom-bot-microservice:latest .
docker compose -f ~/docker-compose.prod.yml up -d microservice --force-recreate
```

## Migraciones DB

Las migraciones viven en `db/migrations/` y son idempotentes. Aplicarlas con:

```
PGURL='postgres://...' node scripts/apply_migrations.js
```

Crear usuario inicial del panel:

```
PGURL='postgres://...' node scripts/crear_usuario_panel.js \
  --slug tom-bot --email vos@tu-resto.com --password una-segura
```

## Scripts incluidos

- `scripts/apply_migrations.js` aplica migraciones SQL de `db/migrations/`.
- `scripts/crear_usuario_panel.js` crea/upserta usuarios en `tombot.usuarios_panel` (bcrypt).
- `scripts/deploy_microservice.sh` rsync + build remoto (alternativa al flujo `git pull`).
- `scripts/backup_postgres.sh`, `scripts/restore_postgres.sh` operaciones DB.
- `scripts/cleanup_sesiones.js`, `scripts/metrics_exporter.js`, `scripts/import_from_sheets.js` utilidades runtime.
