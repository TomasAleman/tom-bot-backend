#!/usr/bin/env node
/**
 * Cleanup standalone (alternativa al workflow nocturno).
 * Util para correr desde cron del host si por alguna razon n8n no esta
 * disponible.
 *
 * Uso:
 *   PGURL=postgres://... node scripts/cleanup_sesiones.js [--horas 24]
 */

const { Client } = require('pg');

async function main() {
  const horasIdx = process.argv.indexOf('--horas');
  const horas = horasIdx >= 0 ? parseInt(process.argv[horasIdx + 1], 10) : 24;

  const pg = new Client(
    process.env.PGURL
      ? { connectionString: process.env.PGURL }
      : {
          host: process.env.PGHOST || 'localhost',
          port: parseInt(process.env.PGPORT || '5432', 10),
          user: process.env.PGUSER || 'postgres',
          password: process.env.PGPASSWORD,
          database: process.env.PGDATABASE || 'evolution',
        }
  );

  await pg.connect();

  const r1 = await pg.query('SELECT * FROM tombot.fn_cleanup_sesiones($1)', [horas]);
  const r2 = await pg.query('SELECT tombot.fn_cleanup_eventos_log(30) AS borrados');

  console.log(JSON.stringify({
    sesiones_borradas: Number(r1.rows[0].sesiones_borradas),
    bloqueos_reseteados: Number(r1.rows[0].bloqueos_reseteados),
    eventos_log_borrados: Number(r2.rows[0].borrados),
  }));

  await pg.end();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
