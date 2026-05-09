# Test de estrés: webhook WhatsApp (Evolution-like)

POST con JSON compatible con lo que envía **Evolution API** (`messages.upsert`), apuntando a:

- **n8n** — workflow Reservas v2: `POST {BASE_URL}/webhook/whatsapp-reservas-v2` → éxito típico **HTTP 2xx**.
- **Node (Fastify)** — hot path: `POST {BASE_URL}/webhook/whatsapp-reservas-fast` → éxito **HTTP 202** (procesamiento en background).

Contrato del cuerpo alineado con [microservice/src/handlers/message.js](../../microservice/src/handlers/message.js).

## Requisitos

- [k6](https://k6.io/docs/get-started/installation/) instalado (`k6 version`).

Windows: `winget install k6 --source winget` o descarga desde la web oficial.

### Instalar k6 en Ubuntu/Debian (VM)

Si `apt` devuelve `NO_PUBKEY C780D0BDB1A69C86` aunque uses `key.gpg`, es un problema conocido del repo DEB + firma; **no pierdas tiempo**: usá **snap** o el **binario** (recomendado en servidores).

**Opción A — Snap (la más simple en Ubuntu 22.04):**

```bash
sudo snap install k6
k6 version
```

**Opción B — Binario oficial (sin apt, sin snap):** cambiá `v0.57.0` por la última versión en [releases de k6](https://github.com/grafana/k6/releases).

```bash
sudo rm -f /etc/apt/sources.list.d/k6.list
VER=v0.57.0
curl -sLO "https://github.com/grafana/k6/releases/download/${VER}/k6-${VER}-linux-amd64.tar.gz"
tar -xzf "k6-${VER}-linux-amd64.tar.gz"
sudo install -m 755 "k6-${VER}-linux-amd64/k6" /usr/local/bin/k6
rm -rf "k6-${VER}-linux-amd64" "k6-${VER}-linux-amd64.tar.gz"
k6 version
```

**Opción C — Repo apt (puede fallar según GPG):** [documentación Grafana](https://grafana.com/docs/k6/latest/set-up/install-k6/).

```bash
curl -fsSL https://dl.k6.io/key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/k6-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update && sudo apt-get install -y k6
```

**Opción D — Docker:** `docker run --rm -v "$PWD:/scripts" -w /scripts grafana/k6 run stress.js` (montá el directorio del script).

## Variables de entorno

| Variable | Obligatoria | Descripción |
|----------|-------------|-------------|
| `BASE_URL` | Sí | Origen sin barra final, ej. `https://n8n.tudominio.com` o `https://api.tudominio.com` |
| `WEBHOOK_PATH` | No | Default `/webhook/whatsapp-reservas-v2` |
| `TARGET` | No | Si vale `fastify` o `node`, el check exige **202**. Si no, se infiere: path que contenga `whatsapp-reservas-fast` → 202 |
| `INSTANCE_NAME` | No | Nombre de instancia Evolution mapeado en DB; default `stress-test-instance` (probablemente falle “tenant” si no existe) |
| `MESSAGE_TEXT` | No | Texto del mensaje simulado |
| `STAGE1_DURATION_SEC` … `STAGE3_TARGET` | No | Rampas por defecto: 30s→10 VU, 120s→40 VU, 30s→0 |
| `SLEEP_MS` | No | Espera entre requests por VU (ms). `0` = máxima presión |

Plantilla: [env.example](./env.example).

## Comandos rápidos

Desde esta carpeta (`scripts/webhook-stress/`).

**n8n (producción MVP):**

```powershell
$env:BASE_URL="https://TU-N8N"
$env:WEBHOOK_PATH="/webhook/whatsapp-reservas-v2"
$env:INSTANCE_NAME="TU_INSTANCIA_REAL"
k6 run stress.js
```

**Fastify:**

```powershell
$env:BASE_URL="https://TU-API"
$env:WEBHOOK_PATH="/webhook/whatsapp-reservas-fast"
$env:TARGET="fastify"
$env:INSTANCE_NAME="TU_INSTANCIA_REAL"
k6 run stress.js
```

**Baseline suave (1 VU, pocas iteraciones):** no está en el script; podés bajar targets:

```powershell
$env:STAGE1_TARGET="1"; $env:STAGE1_DURATION_SEC="10"
$env:STAGE2_TARGET="1"; $env:STAGE2_DURATION_SEC="5"
$env:STAGE3_TARGET="0"; $env:STAGE3_DURATION_SEC="5"
k6 run stress.js
```

**Guardar resumen JSON:**

```powershell
k6 run --summary-export=summary.json stress.js
```

**Ignorar umbrales** (solo si añadís thresholds estrictos más adelante):

```powershell
k6 run --no-thresholds stress.js
```

Bash (Linux/macOS en la VM):

```bash
export BASE_URL=https://TU-N8N
export WEBHOOK_PATH=/webhook/whatsapp-reservas-v2
export INSTANCE_NAME=TU_INSTANCIA_REAL
k6 run stress.js
```

## Qué mide k6

- Latencia del **HTTP del webhook** (tiempo hasta respuesta del servidor).
- En **Fastify**, el **202** es solo el ACK; el trabajo real ocurre después: para CPU/Postgres mirá logs y métricas del contenedor, no solo k6.

## Checklist mientras corre (dónde revienta primero)

1. **Host / Docker:** `docker stats` — CPU, RAM, red de contenedores `n8n`, `postgres`, `redis`, `evolution-api`, microservicio.
2. **n8n:** ejecuciones con error, duración de workflow, cola si usás queue mode.
3. **Postgres:** conexiones saturadas, `too many connections`, queries lentas.
4. **Evolution:** 429/5xx, timeouts en envíos.
5. **Groq:** coste y rate limits si la rama dispara IA en cada mensaje.

## Avisos importantes (MVP sin clientes igual)

- **Rate limit (Redis):** muchos mensajes al **mismo restaurante** en el mismo minuto pueden devolver “demasiados mensajes” antes de que falle n8n. Para ver el techo de infra, subí temporalmente `RateLimitMsgsPorMin` en config del tenant de prueba o repartí carga entre varias `INSTANCE_NAME` con distintos `restaurante_id`.
- **Evolution / WhatsApp:** el workflow real puede **enviar mensajes** a números ficticios o generar carga saliente; en estrés alto podés saturar Evolution.
- **Groq:** cada hit en la rama con IA puede costar API; rampas largas con muchos VU suman.

## Interpretar “a partir de cuántos se rompe”

Anotá el tramo de la rampa donde sube bruscamente el **p95** de `http_req_duration` o donde `http_req_failed` / checks fallan de forma sostenida, y cruzalo con el primer ítem de la checklist que se degrade (suele ser Postgres, Evolution o CPU de n8n, no un número mágico universal).

## Cada VU usa un `remoteJid` distinto

Así simulás muchos usuarios; el número es sintético (`549351…@s.whatsapp.net`) y no debe usarse para números reales.
