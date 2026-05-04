#!/usr/bin/env node
/**
 * Importa el estado actual de la Google Sheet a Postgres para un tenant.
 *
 * Lee:
 *   - Hoja Mesas    -> tombot.mesas
 *   - Hoja Config   -> tombot.config
 *   - Hoja Reservas -> tombot.reservas (historico)
 *   - Hoja Sesiones -> tombot.sesiones (estado actual)
 *
 * Es idempotente: si volves a correrlo, hace UPSERT donde corresponde.
 *
 * Uso:
 *   GOOGLE_API_KEY=xxx \
 *   SHEET_ID=1Nz7sWHCsaV_cMyrVz3jfiglOtnQyNN1DMxv6eHmohwU \
 *   RESTAURANTE_ID=1 \
 *   PGURL=postgres://... \
 *   node scripts/import_from_sheets.js
 *
 * Alternativa: pasar credenciales OAuth si la sheet no es publica.
 * Por simplicidad este script asume que la sheet esta compartida
 * publicamente con read access (read-only).
 */

const { Client } = require('pg');
const https = require('https');

function fetchJson(url) {
  return new Promise((resolve, reject) => {
    https.get(url, (res) => {
      let data = '';
      res.on('data', (chunk) => (data += chunk));
      res.on('end', () => {
        try {
          resolve(JSON.parse(data));
        } catch (e) {
          reject(new Error(`Respuesta no-JSON: ${data.slice(0, 200)}`));
        }
      });
    }).on('error', reject);
  });
}

async function readSheet(sheetId, sheetName, apiKey) {
  const url = `https://sheets.googleapis.com/v4/spreadsheets/${sheetId}/values/${encodeURIComponent(sheetName)}?key=${apiKey}`;
  const json = await fetchJson(url);
  if (!json.values || json.values.length === 0) return [];
  const [headers, ...rows] = json.values;
  return rows.map((row) => {
    const obj = {};
    headers.forEach((h, i) => (obj[h] = row[i] !== undefined ? row[i] : ''));
    return obj;
  });
}

async function main() {
  const apiKey = process.env.GOOGLE_API_KEY;
  const sheetId = process.env.SHEET_ID;
  const restauranteId = parseInt(process.env.RESTAURANTE_ID || '1', 10);

  if (!apiKey || !sheetId) {
    console.error('Faltan GOOGLE_API_KEY o SHEET_ID en el entorno.');
    process.exit(1);
  }

  const pgConfig = process.env.PGURL
    ? { connectionString: process.env.PGURL }
    : {
        host: process.env.PGHOST || 'localhost',
        port: parseInt(process.env.PGPORT || '5432', 10),
        user: process.env.PGUSER || 'postgres',
        password: process.env.PGPASSWORD,
        database: process.env.PGDATABASE || 'evolution',
      };

  const pg = new Client(pgConfig);
  await pg.connect();

  console.log(`Importando Sheet ${sheetId} -> tenant ${restauranteId}`);

  // -------- Mesas --------
  const mesas = await readSheet(sheetId, 'Mesas', apiKey);
  console.log(`  Mesas:     ${mesas.length} filas`);
  for (const m of mesas) {
    if (!m.Numero_Mesa) continue;
    await pg.query(
      `INSERT INTO tombot.mesas (
         restaurante_id, numero_mesa, min_personas, max_personas,
         horario_manana, horario_mediodia, horario_tarde
       ) VALUES ($1,$2,$3,$4,$5,$6,$7)
       ON CONFLICT (restaurante_id, numero_mesa) DO UPDATE
         SET min_personas     = EXCLUDED.min_personas,
             max_personas     = EXCLUDED.max_personas,
             horario_manana   = EXCLUDED.horario_manana,
             horario_mediodia = EXCLUDED.horario_mediodia,
             horario_tarde    = EXCLUDED.horario_tarde,
             updated_at       = NOW()`,
      [
        restauranteId,
        String(m.Numero_Mesa),
        parseInt(m.Min_Personas, 10) || 0,
        parseInt(m.Max_Personas, 10) || 0,
        m.Horario_Manana || null,
        m.Horario_Mediodia || null,
        m.Horario_Tarde || null,
      ]
    );
  }

  // -------- Config --------
  const config = await readSheet(sheetId, 'Config', apiKey);
  console.log(`  Config:    ${config.length} filas`);
  for (const c of config) {
    if (!c.Parametro) continue;
    await pg.query(
      `INSERT INTO tombot.config (restaurante_id, parametro, valor, descripcion)
       VALUES ($1,$2,$3,$4)
       ON CONFLICT (restaurante_id, parametro) DO UPDATE
         SET valor       = EXCLUDED.valor,
             descripcion = EXCLUDED.descripcion,
             updated_at  = NOW()`,
      [restauranteId, c.Parametro, c.Valor || '', c.Descripcion || null]
    );
  }

  // -------- Reservas --------
  const reservas = await readSheet(sheetId, 'Reservas', apiKey);
  console.log(`  Reservas:  ${reservas.length} filas`);
  for (const r of reservas) {
    if (!r.Telefono || !r.Dia) continue;
    const partes = r.Dia.split('/');
    if (partes.length !== 3) continue;
    const dia = `${partes[2]}-${partes[1].padStart(2, '0')}-${partes[0].padStart(2, '0')}`;
    const horaMatch = (r.Horario || '').match(/^(\d{1,2})/);
    const hora = horaMatch ? parseInt(horaMatch[1], 10) : 0;
    await pg.query(
      `INSERT INTO tombot.reservas (
         restaurante_id, nombre, telefono, dia,
         horario_hora, horario_label, turno, personas, numero_mesa, estado, created_at
       ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
       ON CONFLICT DO NOTHING`,
      [
        restauranteId,
        r.Nombre || '',
        r.Telefono,
        dia,
        hora,
        r.Horario || `${hora}hs`,
        null,
        parseInt(r.Personas, 10) || 1,
        String(r.Numero_Mesa || ''),
        r.Estado || 'Confirmada',
        r.Timestamp ? new Date(r.Timestamp).toISOString() : new Date().toISOString(),
      ]
    );
  }

  // -------- Sesiones --------
  const sesiones = await readSheet(sheetId, 'Sesiones', apiKey);
  console.log(`  Sesiones:  ${sesiones.length} filas`);
  for (const s of sesiones) {
    if (!s.Telefono) continue;
    let contexto = {};
    try {
      contexto = s.ContextoReserva ? JSON.parse(s.ContextoReserva) : {};
    } catch (_) {}
    await pg.query(
      `INSERT INTO tombot.sesiones (
         restaurante_id, telefono, primer_contacto, contexto_reserva,
         contador_mensajes, bloqueo_hasta, bloqueo_minutos
       ) VALUES ($1,$2,$3,$4,$5,$6,$7)
       ON CONFLICT (restaurante_id, telefono) DO UPDATE
         SET contexto_reserva  = EXCLUDED.contexto_reserva,
             contador_mensajes = EXCLUDED.contador_mensajes,
             bloqueo_hasta     = EXCLUDED.bloqueo_hasta,
             bloqueo_minutos   = EXCLUDED.bloqueo_minutos,
             ultimo_mensaje_at = NOW()`,
      [
        restauranteId,
        s.Telefono,
        s.PrimerContacto ? new Date(s.PrimerContacto).toISOString() : new Date().toISOString(),
        JSON.stringify(contexto),
        parseInt(s.ContadorMensajes, 10) || 0,
        s.BloqueoHasta ? new Date(s.BloqueoHasta).toISOString() : null,
        parseInt(s.BloqueoMinutos, 10) || 0,
      ]
    );
  }

  await pg.end();
  console.log('Import OK.');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
