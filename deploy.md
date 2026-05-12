# Despliegue y configuración operativa

## `TelefonoReservas` (WhatsApp / n8n)

El bot usa la clave **`TelefonoReservas`** en `tombot.config` (por `restaurante_id`) para indicar en qué número debe llamar el cliente cuando la reserva supera la capacidad de una sola mesa o requiere coordinación humana (junte de mesas).

- Tras aplicar las migraciones que insertan el parámetro por tenant, actualizá el valor con el número en formato que quieras mostrar al usuario (ej. `+54 9 11 1234-5678`).
- Si el valor está vacío, el flujo de n8n usa el texto genérico *«al teléfono del restaurante»* para no cortar el mensaje.

Ejemplo (ajustá `restaurante_id` y el teléfono):

```sql
UPDATE tombot.config
   SET valor = '+54 9 11 1234-5678'
 WHERE restaurante_id = 1
   AND parametro = 'TelefonoReservas';
```

El panel puede gestionar otras claves de `tombot.config` según el microservicio; si no hay UI para esta clave, el `UPDATE` anterior alcanza.

## En la VM: migrar Postgres y deploy Docker

Orden recomendado: **código en `release` en GitHub** → **pull en la VM** → **migraciones** → **rebuild/restart del microservicio** → **config post** (`TelefonoReservas`, n8n).

### 1. En tu PC

Ver comandos sugeridos (merge `develop` → `release` y push):

```bash
bash scripts/pc_release_push.sh
```

### 2. En la VM: variables

- **`PGURL`**: la **cadena completa** que usa el contenedor `microservice` (usuario, contraseña, host IP o nombre DNS, puerto, base de datos). Debe ser una URL real; si copiás literalmente `postgres://...` o un host `...`, Node fallará con `getaddrinfo ENOTFOUND ...`.
- **`COMPOSE_FILE`**: ruta al `docker-compose.core.yml` del stack si no está en `~/docker-compose.core.yml` (ver `vm_deploy_release.sh`).

Para ver comandos útiles y dónde buscar el valor:

```bash
bash scripts/vm_print_pgurl_hint.sh
# opcional: COMPOSE_FILE=/opt/tombot/docker-compose.core.yml bash scripts/vm_print_pgurl_hint.sh
```

Ejemplos de **host válido**: `127.0.0.1`, la IP privada del contenedor Postgres en la red Docker, o el nombre del servicio compose **solo si** Node resuelve ese nombre desde el host donde corrés `apply_migrations.js` (en muchas VM conviene `127.0.0.1` o la IP del servidor, no el nombre interno `postgres` del compose, salvo que uses `docker compose run` desde la misma red).

### 3. En la VM: pull, migrar y deploy (todo en uno)

**Orden:** primero `git pull` (así existen los scripts en disco) y **después** `chmod`.

```bash
cd ~/tom-bot-backend   # o la ruta real del repo en la VM
git fetch origin && git checkout release && git pull origin release

chmod +x scripts/vm_migrate_then_deploy.sh scripts/vm_deploy_release.sh scripts/vm_print_pgurl_hint.sh   # una vez

# Reemplazá por la URL real (ver vm_print_pgurl_hint.sh). Ejemplo ilustrativo:
export PGURL='postgres://mi_usuario:mi_clave@127.0.0.1:5432/evolution'
export COMPOSE_FILE=/ruta/a/docker-compose.core.yml   # solo si no usás ~/docker-compose.core.yml

bash scripts/vm_migrate_then_deploy.sh
```

El script ejecuta `npm ci` en `microservice/`, corre [`scripts/apply_migrations.js`](scripts/apply_migrations.js) con `NODE_PATH` apuntando al `pg` del microservicio, y luego [`scripts/vm_deploy_release.sh`](scripts/vm_deploy_release.sh).

Opciones útiles:

| Variable | Efecto |
|----------|--------|
| `SKIP_NPM=1` | No ejecuta `npm ci` |
| `SKIP_MIGRATE=1` | Solo deploy (sin tocar la DB) |
| `SKIP_DEPLOY=1` | Solo migraciones |

### 4. Después del deploy

1. Ejecutá el `UPDATE` de **TelefonoReservas** (arriba en este archivo).
2. **n8n**: confirmá que el workflow de reservas esté actualizado y **activo** (los cambios de nodos no vienen del `git pull` del backend).
3. `curl -sS http://127.0.0.1:3000/health` (o el puerto que uses).
