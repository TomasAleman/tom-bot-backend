# tom-bot hot path microservice (Fase 5 — opcional)

Servicio Node/Fastify que reemplaza el workflow n8n `Reservas v2` para
el hot path. Comparte el mismo schema Postgres y el mismo formato de
Redis, asi que puede correr en paralelo con n8n durante el cutover.

## Cuando activarlo

- Throughput sostenido > 500 mensajes/min en n8n
- Latencia p95 > 500ms en `tombot.v_metricas_5min`
- Picos de uso de CPU del container n8n > 80% sostenido

Hasta entonces, el workflow n8n es suficiente y mas facil de mantener.

## Estructura

```
microservice/
  src/
    server.js                -- Fastify entry point (webhook + /api + /admin)
    api/                     -- Rutas REST del panel (reservas, mesas, config…)
    middleware/
      auth.js                -- JWT para /api/* (excepto /api/auth/login)
    handlers/
      message.js             -- Logica del webhook (ver TODO)
      data.js                -- Capa de datos: Postgres + Redis cache
  Dockerfile
  package.json
```

## Estado actual

Version stub funcional:

- Acepta webhooks de Evolution API en `POST /webhook/whatsapp-reservas-fast`
- **Panel web:** si `JWT_SECRET` está definido, expone `/api/*` (login JWT,
  reservas, mesas, config, sesiones, métricas). Si existe `PANEL_PUBLIC_DIR`
  (default `/opt/tombot/panel-public`), sirve el bundle React en `/admin/*`
  con fallback SPA a `index.html`.
- Carga contexto desde Postgres (con cache Redis)
- Aplica rate limit por tenant
- TODO: portear handlers de bloqueo, primera vez, parser AI, asignacion
  de mesa desde `workflows/code-nodes/01-06.js`. Esos archivos tienen
  la logica idiomatica que se puede traducir 1:1 a JS plano.

## Como correrlo

```bash
cd microservice
npm install
PGURL=postgres://postgres:****@localhost:5432/evolution \
REDIS_URL=redis://localhost:6379 \
GROQ_API_KEY=*** \
EVOLUTION_URL=http://localhost:8080 \
JWT_SECRET="generar-con-openssl-rand-hex-48" \
PANEL_PUBLIC_DIR=../panel/dist \
PORT=3000 \
  node src/server.js
```

Sin `JWT_SECRET` el servicio arranca igual pero **no registra** las rutas
`/api/*` (solo webhook + health). Sin `PANEL_PUBLIC_DIR` existente en disco,
no sirve `/admin/` (404 en rutas SPA hasta que exista el directorio).

O con Docker:

```bash
docker build -t tom-bot-hot-path .
docker run --rm -p 3000:3000 \
  -e PGURL=... -e REDIS_URL=... -e GROQ_API_KEY=... -e EVOLUTION_URL=... \
  tom-bot-hot-path
```

## Cutover desde n8n

1. Levantar el microservicio en paralelo (puerto distinto).
2. Configurar Evolution API para apuntar a:
   `https://n8n.tbotapp.uk/webhook/whatsapp-reservas-fast` (proxy a este
   servicio via Caddy/nginx) o exponerlo directo en `https://api.tbotapp.uk`.
3. Validar 24h con shadow testing (mismo enfoque que `docs/rollout-fase1.md`).
4. Cortar el webhook de n8n. n8n queda solo para Sync Sheets, Onboarding,
   Cleanup, Backup.

## Performance esperada

- Latencia p95 < 50ms (vs 200-500ms n8n)
- Throughput: 5.000-10.000 msg/min en una VM de 2 vCPU
- Memoria: ~150 MB residente
- Escalamiento horizontal: trivial detras de un load balancer
