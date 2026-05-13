#!/usr/bin/env node
/**
 * Crea o actualiza la contraseña de un usuario superadmin del panel (restaurante_id NULL).
 * No se puede crear superadmin por API (solo por base).
 *
 * Ejecutar desde la carpeta microservice (para resolver pg y bcryptjs):
 *   cd microservice
 *   $env:PGURL="postgres://evo:evo@localhost:5432/evolution"
 *   node ../scripts/crear_superadmin_panel.js --email=admin@local.dev --password=TuClaveSegura8
 *
 * Linux/mac:
 *   cd microservice && PGURL=postgres://evo:evo@localhost:5432/evolution \
 *     node ../scripts/crear_superadmin_panel.js --email=admin@local.dev --password=TuClaveSegura8
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

  const email = (args.email || (await ask('Email del superadmin: '))).toLowerCase();
  if (!email || !email.includes('@')) {
    console.error('email invalido');
    process.exit(1);
  }

  const password = args.password || (await ask('Contraseña (min 8, no se muestra): ', { mask: true }));
  if (!password || password.length < 8) {
    console.error('contraseña mínima 8 caracteres');
    process.exit(1);
  }

  const nombre = args.nombre || (await ask('Nombre (opcional): ')) || null;

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
    const { rows: existing } = await client.query(
      `SELECT id, rol, restaurante_id FROM tombot.usuarios_panel WHERE lower(email) = lower($1) LIMIT 1`,
      [email]
    );

    if (existing.length > 0 && existing[0].rol !== 'superadmin') {
      throw new Error(
        `El email ya existe con rol "${existing[0].rol}". No se convierte automáticamente a superadmin; usá otro email o borrá/ajustá la fila en BD.`
      );
    }

    const passwordHash = await bcrypt.hash(password, BCRYPT_COST);

    const { rows } = await client.query(
      `INSERT INTO tombot.usuarios_panel (restaurante_id, email, password_hash, nombre, rol, activo)
            VALUES (NULL, $1, $2, $3, 'superadmin', TRUE)
       ON CONFLICT (email) DO UPDATE
          SET password_hash = EXCLUDED.password_hash,
              nombre        = COALESCE(EXCLUDED.nombre, tombot.usuarios_panel.nombre),
              rol           = 'superadmin',
              restaurante_id = NULL,
              activo        = TRUE,
              updated_at    = NOW()
       RETURNING id, email, nombre, rol, restaurante_id, activo, created_at`,
      [email, passwordHash, nombre]
    );

    console.log('\nSuperadmin listo (login en el panel con este email y contraseña):');
    console.log(JSON.stringify(rows[0], null, 2));
    console.log('\nEn el front: /admin/ → login. Rutas de alta de restaurantes: rol superadmin.');
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
