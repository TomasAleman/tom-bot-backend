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

- **`PGURL`**: misma cadena `postgres://...` que usa el contenedor `microservice` (esquema `tombot` en esa base).
- **`COMPOSE_FILE`**: ruta al `docker-compose.core.yml` del stack si no está en `~/docker-compose.core.yml` (ver `vm_deploy_release.sh`).

### 3. En la VM: pull, migrar y deploy (todo en uno)

```bash
cd ~/tom-bot-backend   # o la ruta real del repo en la VM
chmod +x scripts/vm_migrate_then_deploy.sh scripts/vm_deploy_release.sh   # una vez
git fetch origin && git checkout release && git pull origin release

export PGURL='postgres://USUARIO:PASSWORD@HOST:5432/NOMBRE_DB'
export COMPOSE_FILE=/ruta/a/docker-compose.core.yml   # si aplica

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
