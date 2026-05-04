#!/usr/bin/env node
/**
 * Aplica las migraciones SQL de db/migrations en orden alfabetico.
 *
 * Uso:
 *   PGURL=postgres://postgres:pass@localhost:5432/evolution node scripts/apply_migrations.js
 *
 * O con vars sueltas:
 *   PGHOST=localhost PGPORT=5432 PGUSER=postgres PGPASSWORD=pass PGDATABASE=evolution \
 *     node scripts/apply_migrations.js
 */

const fs = require('fs');
const path = require('path');
const { Client } = require('pg');

async function main() {
  const config = process.env.PGURL
    ? { connectionString: process.env.PGURL }
    : {
        host: process.env.PGHOST || 'localhost',
        port: parseInt(process.env.PGPORT || '5432', 10),
        user: process.env.PGUSER || 'postgres',
        password: process.env.PGPASSWORD,
        database: process.env.PGDATABASE || 'evolution',
      };

  const client = new Client(config);
  await client.connect();

  const dir = path.join(__dirname, '..', 'db', 'migrations');
  const files = fs.readdirSync(dir)
    .filter((f) => f.endsWith('.sql'))
    .sort();

  console.log(`Aplicando ${files.length} migraciones desde ${dir}`);

  for (const file of files) {
    const sql = fs.readFileSync(path.join(dir, file), 'utf8');
    console.log(`  -> ${file}`);
    try {
      await client.query(sql);
      console.log(`     OK`);
    } catch (err) {
      console.error(`     FALLO: ${err.message}`);
      await client.end();
      process.exit(1);
    }
  }

  await client.end();
  console.log('Todas las migraciones aplicadas correctamente.');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
