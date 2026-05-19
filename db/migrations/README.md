# Migraciones Postgres — esquema `tombot`

Estas migraciones crean el storage operativo multi-tenant que reemplaza
a Google Sheets como fuente de verdad para el bot de reservas.

## Aplicar en local

Asumiendo que el contenedor de Postgres de Evolution API se llama
`postgres` y la DB es `evolution`:

```bash
cd "C:\Users\Tomas\Desktop\evolution-api"
docker compose exec -T postgres psql -U postgres -d evolution -f - < db/migrations/001_init_schema.sql
docker compose exec -T postgres psql -U postgres -d evolution -f - < db/migrations/002_seed_tom_bot_tenant.sql
docker compose exec -T postgres psql -U postgres -d evolution -f - < db/migrations/003_funcion_asignar_mesa.sql
```

O todo de una pasada con el script:

```bash
node scripts/apply_migrations.js
```

## Aplicar en produccion (VM GCP)

```bash
ssh alemanmdq@34.68.131.253
cd /opt/tombot   # o donde este el repo en la VM
docker compose -f docker-compose.core.yml exec -T postgres psql -U postgres -d evolution -f - < db/migrations/001_init_schema.sql
# repetir para 002 y 003
```

## Orden y dependencias

1. **001_init_schema.sql** — esquema, tablas, indices, triggers. Idempotente.
2. **002_seed_tom_bot_tenant.sql** — carga tenant `tom-bot` con id=1 y
   config + mesas default. Las mesas reales se traen despues con
   `scripts/import_from_sheets.js`.
3. **003_funcion_asignar_mesa.sql** — funcion concurrency-safe para
   asignar mesa. Requiere las tablas creadas.
4. **004_cleanup_y_metricas.sql** / **005_funcion_modificar_reserva.sql** —
   segun el despliegue (ver lista en `db/migrations/`).
5. **006_funcion_disponibilidad_modificar.sql** — lista dias/horarios con
   mesa libre para el flujo *modificar* (misma logica que `fn_modificar_reserva`).
6. **007_fix_modificar_dia_valor_iso.sql** — al cambiar *dia*, interpreta
   siempre los primeros 10 caracteres `YYYY-MM-DD` si el valor trae ISO
   con hora/TZ (evita que el dia se corra respecto al listado del bot).
7. **008_fn_modificar_reserva_fix_ambiguous_id.sql** — corrige
   `restaurante_id` ambiguo en el `PERFORM` de mesas (choque con columnas
   OUTPUT de `RETURNS TABLE` en PL/pgSQL). Sin esto, `fn_modificar_reserva`
   fallaba y n8n veía 0 filas como “sin disponibilidad”.
8. **009_fn_modificar_reserva_timeouts.sql** — `SET LOCAL lock_timeout` /
   `statement_timeout` al inicio de `fn_modificar_reserva` para que una
   espera por candados o una consulta anómala no deje el nodo Postgres de n8n
   colgado indefinidamente (p. ej. 15 s esperando lock, 60 s máximo por llamada).
9. **010_panel_usuarios.sql** — tabla `tombot.usuarios_panel` para login del
   panel web (1 row por usuario, atado a un `restaurante_id`). El JWT que
   emite `/api/auth/login` lleva `{ usuario_id, restaurante_id }` y todas
   las queries del panel filtran por ese `restaurante_id` (cero acceso
   cruzado entre tenants). Crear el primer usuario:
   `npm run crear-usuario-panel -- --slug X --email Y --password Z`.
10. **012_turnos_hh_mm.sql** / **013_mesas_turnos_texto_hs.sql** — turnos de
    mesas en formato `HH:MM-HH:MM`.
11. **015_horario_minutos.sql** — `reservas.horario_hora` pasa a ser **minutos
    desde medianoche** (0-1439); `fn_hora_en_turno` compara minutos; nuevas
    `fn_parse_minutos_desde_texto` y `fn_horario_label_desde_minutos`;
    `fn_modificar_reserva` parsea horarios con minutos. Quita el CHECK heredado
    de 001 (`horario_hora` 0-23), migra datos y define CHECK 0-1439.
    **Orden de despliegue:** aplicar **015 en Postgres antes** de importar el
    workflow n8n que envía `horario_minutos` (o pausar el webhook unos minutos
    entre migración e import). Idempotente en datos: solo actualiza filas con
    `horario_hora` entre 0 y 23.
12. **016_restaurante_link_menu.sql** — columnas `restaurantes.link_menu`
    (TEXT nullable) y `restaurantes.mostrar_menu` (BOOLEAN NOT NULL DEFAULT
    TRUE). El workflow n8n y el microservice leen estos campos en "Cargar
    contexto". Aplicar migración antes de importar el workflow actualizado.
13. **024_turnos_cruzan_medianoche.sql** — `fn_hora_en_turno` admite turnos con
    fin &lt; inicio (cruzan medianoche, ej. `19:00-00:30`: válido desde las 19:00
    hasta 00:15 en pasos de reserva). Misma semántica inclusivo/exclusivo; turnos
    diurnos sin cambios.
14. **019_fix_modificar_horario_label_hhmm.sql** — corrige `fn_modificar_reserva`
    (rama `horario`): deja de guardar `horario_label` como minutos + `hs`
    (ej. `1320hs`) y vuelve a `fn_parse_minutos_desde_texto` +
    `fn_horario_label_desde_minutos` en formato **HH:MM**. Actualiza etiquetas
    ya guardadas con patrón `^[0-9]+hs$`. Ajusta `fn_horario_label_desde_minutos`
    para no sufijo `hs`.

## Disponibilidad y estados de reserva

Solo las reservas **confirmadas** ocupan mesa a efectos de disponibilidad
(buscar mesa, confirmar, modificar, `fn_disponibilidad_modificar`). Las filas
en estado **Cancelada** o **NoShow** **no** participan en el cruce de
conflictos: si alguien reservó y luego canceló, el hueco cuenta como libre
igual que si nunca hubiera existido la reserva (salvo otra confirmada en el
mismo slot). En SQL esto se expresa como `lower(estado) = 'confirmada'` o
`estado = 'Confirmada'` según la función.

## Convenciones

- Schema aislado: todo bajo `tombot.*` para no chocar con el schema de
  Evolution API. Si se borra la DB de Evolution se mantiene tom-bot
  (configurable via backups separados).
- `BIGSERIAL` en PKs por si llegamos a millones de rows.
- `JSONB` para `contexto_reserva` (mas flexible que columnas fijas).
- `TIMESTAMPTZ` siempre — evita lios de timezone.

## Rollback

```sql
DROP SCHEMA tombot CASCADE;
```

Cuidado: borra TODOS los datos del bot (reservas, sesiones, configs).
Hacer `pg_dump -n tombot` antes.
