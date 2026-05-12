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

Ejemplos de **host válido**: `127.0.0.1` (desde la VM, con el puerto de Postgres publicado) o el nombre `postgres` **solo** cuando las migraciones corren dentro de Docker en la misma red que el stack (`vm_migrate_then_deploy.sh` lo hace solo si detecta host `postgres`).

### 3. En la VM: pull, migrar y deploy (todo en uno)

**Orden:** primero `git pull` (así existen los scripts en disco) y **después** `chmod`.

```bash
cd ~/tom-bot-backend   # o la ruta real del repo en la VM
git fetch origin && git checkout release && git pull origin release

chmod +x scripts/vm_migrate_then_deploy.sh scripts/vm_deploy_release.sh scripts/vm_print_pgurl_hint.sh scripts/vm_apply_migrations_docker.sh   # una vez

# Pegá la salida EXACTA de: docker exec <contenedor> printenv PGURL
# (si el host es "postgres", el script migra vía Docker en la misma red del compose)
export PGURL='postgres://evo:CONTRASENA_REAL@postgres:5432/evolution'
export COMPOSE_FILE=/ruta/a/docker-compose.core.yml   # solo si no usás ~/docker-compose.core.yml ni /opt/tombot/... (no pegues ... como ruta)

bash scripts/vm_migrate_then_deploy.sh
```

Si `PGURL` usa el host `postgres`, hace falta que exista **`COMPOSE_FILE`** (ruta al `docker-compose.core.yml`) para adjuntar el contenedor efímero a la red del stack. Si solo usás `~/docker-compose.core.yml`, no hace falta exportar nada extra.

**No pegues** `....` ni `...` como host: son placeholders; la URL tiene que ser la de `printenv` o equivalente con `127.0.0.1` y puerto publicado.

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
