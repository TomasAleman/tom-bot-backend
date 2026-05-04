#!/usr/bin/env node
/**
 * Crea (o actualiza la contraseña de) un usuario para el panel web.
 *
 * Uso interactivo:
 *   PGURL=postgres://postgres:pass@localhost:5432/evolution \
 *     node scripts/crear_usuario_panel.js
 *
 * Uso con flags (en PowerShell conviene --clave=valor para evitar cortes):
 *   PGURL=... node scripts/crear_usuario_panel.js \
 *     --slug=tom-bot --email=dueno@resto.com --password=Secreta123 [--nombre=Juan] [--rol=admin]
 *
 * Si el email ya existe, actualiza el hash de password y reactiva la cuenta.
 */

const readline = require('readline');
const { Client } = require('pg');
const bcrypt = require('bcryptjs');

const BCRYPT_COST = 12;

function parseArgs(argv) {
  const out = {};
  for (let i = 2; i < argv.length; i += 1) {
    const a = argv[i];
    if (!a || !a.startsWith('--')) continue;
    const eq = a.indexOf('=');
    if (eq !== -1) {
      out[a.slice(2, eq)] = a.slice(eq + 1);
      continue;
    }
    const key = a.replace(/^--/, '');
    const val = argv[i + 1];
    if (val && !val.startsWith('--')) {
      out[key] = val;
      i += 1;
    } else {
      out[key] = 'true';
    }
  }
  return out;
}

function ask(question, { mask = false } = {}) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  if (!mask) {
    return new Promise((resolve) => rl.question(question, (a) => { rl.close(); resolve(a.trim()); }));
  }
  return new Promise((resolve) => {
    process.stdout.write(question);
    const stdin = process.stdin;
    if (typeof stdin.setRawMode === 'function') stdin.setRawMode(true);
    stdin.resume();
    stdin.setEncoding('utf8');
    let buf = '';
    const onData = (ch) => {
      const c = ch.toString('utf8');
      if (c === '\n' || c === '\r' || c === '\u0004') {
        if (typeof stdin.setRawMode === 'function') stdin.setRawMode(false);
        stdin.pause();
        stdin.removeListener('data', onData);
        process.stdout.write('\n');
        rl.close();
        resolve(buf);
      } else if (c === '\u0003') {
        process.exit(130);
      } else if (c === '\u007f' || c === '\b') {
        if (buf.length > 0) {
          buf = buf.slice(0, -1);
          process.stdout.write('\b \b');
        }
      } else {
        buf += c;
        process.stdout.write('*');
      }
    };
    stdin.on('data', onData);
  });
}

async function main() {
  const args = parseArgs(process.argv);

  const slug = args.slug || await ask('Slug del restaurante: ');
  if (!slug) {
    console.error('slug es obligatorio');
    process.exit(1);
  }

  const email = (args.email || await ask('Email del usuario: ')).toLowerCase();
  if (!email || !email.includes('@')) {
    console.error('email invalido');
    process.exit(1);
  }

  const password = args.password || await ask('Contraseña (no se muestra): ', { mask: true });
  if (!password || password.length < 8) {
    console.error('contraseña minima 8 caracteres');
    process.exit(1);
  }

  const nombre = args.nombre || await ask('Nombre (opcional): ') || null;
  const rol = (args.rol || 'admin').toLowerCase();
  if (!['admin', 'staff'].includes(rol)) {
    console.error('rol debe ser admin o staff');
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

  const client = new Client(pgConfig);
  await client.connect();

  try {
    const { rows: rRows } = await client.query(
      'SELECT id, nombre FROM tombot.restaurantes WHERE slug = $1 AND activo = TRUE',
      [slug]
    );
    if (rRows.length === 0) {
      throw new Error(`No existe el restaurante activo con slug "${slug}"`);
    }
    const restauranteId = rRows[0].id;

    const passwordHash = await bcrypt.hash(password, BCRYPT_COST);

    const { rows: upserted } = await client.query(
      `INSERT INTO tombot.usuarios_panel (restaurante_id, email, password_hash, nombre, rol, activo)
            VALUES ($1, $2, $3, $4, $5, TRUE)
       ON CONFLICT (email) DO UPDATE
          SET password_hash = EXCLUDED.password_hash,
              nombre        = COALESCE(EXCLUDED.nombre, tombot.usuarios_panel.nombre),
              rol           = EXCLUDED.rol,
              activo        = TRUE,
              updated_at    = NOW()
       RETURNING id, restaurante_id, email, nombre, rol, activo, created_at`,
      [restauranteId, email, passwordHash, nombre, rol]
    );

    console.log('\nUsuario creado/actualizado:');
    console.log(JSON.stringify(upserted[0], null, 2));
    console.log(`\nRestaurante: ${rRows[0].nombre} (id=${restauranteId})`);
  } finally {
    await client.end();
  }
}

main().catch((err) => {
  const msg = err && typeof err.message === 'string' && err.message ? err.message : String(err);
  console.error('ERROR:', msg);
  if (err && err.stack) console.error(err.stack);
  process.exit(1);
});
