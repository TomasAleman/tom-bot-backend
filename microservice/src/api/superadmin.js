import { z } from 'zod';
import bcrypt from 'bcryptjs';
import { request as undiciRequest } from 'undici';
import { authHook } from '../middleware/auth.js';
import { requireSuperadmin } from '../middleware/authz.js';

const CreateRestauranteSchema = z.object({
  slug: z.string().trim().min(2).max(60).regex(/^[a-z0-9]+(?:-[a-z0-9]+)*$/).optional(),
  nombre: z.string().trim().min(2).max(120),
  timezone: z.string().trim().min(3).max(80).optional(),
  // opcional: si querés forzar un nombre de instancia distinto al slug
  instancia_evolution: z.string().trim().min(2).max(80).optional(),
});

const CreateUsuarioSchema = z.object({
  restaurante_id: z.number().int().positive().nullable().optional(),
  email: z.string().trim().toLowerCase().email().max(160),
  password: z.string().min(8).max(200),
  nombre: z.string().trim().min(1).max(120).optional(),
  rol: z.enum(['admin_restaurante', 'recepcionista']),
});

const EVOLUTION_CONNECT_MS = 10_000;
const EVOLUTION_READ_MS = 60_000;

function isUndiciTimeoutError(err) {
  const code = err && err.code;
  return (
    code === 'UND_ERR_CONNECT_TIMEOUT' ||
    code === 'UND_ERR_HEADERS_TIMEOUT' ||
    code === 'UND_ERR_BODY_TIMEOUT'
  );
}

function slugFromNombre(nombre) {
  return nombre
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60) || 'restaurante';
}

async function createEvolutionInstance(ctx, instanceName) {
  if (!ctx.evolutionGlobalKey) {
    const err = new Error('EVOLUTION_GLOBAL_KEY no seteada');
    err.code = 'MISSING_EVOLUTION_GLOBAL_KEY';
    throw err;
  }

  const url = `${ctx.evolutionUrl.replace(/\/$/, '')}/instance/create`;
  const body = {
    instanceName,
    integration: 'WHATSAPP-BAILEYS',
    qrcode: true,
  };

  let res;
  let text;
  try {
    res = await undiciRequest(url, {
      method: 'POST',
      connectTimeout: EVOLUTION_CONNECT_MS,
      headersTimeout: EVOLUTION_READ_MS,
      bodyTimeout: EVOLUTION_READ_MS,
      headers: {
        apikey: ctx.evolutionGlobalKey,
        'content-type': 'application/json',
      },
      body: JSON.stringify(body),
    });
    text = await res.body.text();
  } catch (err) {
    if (isUndiciTimeoutError(err)) {
      const e = new Error('evolution_timeout');
      e.code = 'EVOLUTION_TIMEOUT';
      e.cause = err;
      throw e;
    }
    throw err;
  }

  let json;
  try { json = text ? JSON.parse(text) : null; } catch { json = null; }

  if (res.statusCode < 200 || res.statusCode >= 300) {
    const err = new Error(`evolution create instance fallo (${res.statusCode})`);
    err.statusCode = res.statusCode;
    err.payload = json || text;
    throw err;
  }

  const apiKey =
    json?.apikey ||
    json?.apiKey ||
    json?.instance?.apikey ||
    json?.instance?.apiKey ||
    null;
  const qrcode =
    json?.qrcode ||
    json?.qr ||
    json?.instance?.qrcode ||
    null;

  if (!apiKey) {
    const err = new Error('evolution create instance: no devolvio apiKey');
    err.payload = json;
    throw err;
  }

  return { apiKey, qrcode, raw: json };
}

export async function registerSuperadminRoutes(fastify, ctx) {
  fastify.addHook('preHandler', authHook);
  fastify.addHook('preHandler', requireSuperadmin);

  fastify.get('/restaurantes', async () => {
    const { rows } = await ctx.pgPool.query(
      `SELECT id, slug, nombre, timezone, instancia_evolution, activo, created_at, updated_at
         FROM tombot.restaurantes
        ORDER BY id DESC`
    );
    return {
      data: rows.map((r) => ({ ...r, id: Number(r.id) })),
    };
  });

  fastify.post('/restaurantes', async (req, reply) => {
    const parsed = CreateRestauranteSchema.safeParse(req.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'bad_request', issues: parsed.error.issues });
    }

    const input = parsed.data;
    const slug = input.slug || slugFromNombre(input.nombre);
    const timezone = input.timezone || 'America/Argentina/Buenos_Aires';
    const instanciaEvolution = input.instancia_evolution || slug;

    let evo;
    try {
      evo = await createEvolutionInstance(ctx, instanciaEvolution);
    } catch (err) {
      if (err && err.code === 'MISSING_EVOLUTION_GLOBAL_KEY') {
        return reply.code(503).send({
          error: 'evolution_not_configured',
          message: 'EVOLUTION_GLOBAL_KEY no está configurada en el servidor',
        });
      }
      if (err && err.code === 'EVOLUTION_TIMEOUT') {
        return reply.code(504).send({
          error: 'evolution_timeout',
          message: 'Evolution no respondió a tiempo al crear la instancia. Revisá conectividad y EVOLUTION_URL.',
        });
      }
      if (isUndiciTimeoutError(err)) {
        return reply.code(504).send({
          error: 'evolution_timeout',
          message: 'Evolution no respondió a tiempo al crear la instancia. Revisá conectividad y EVOLUTION_URL.',
        });
      }
      if (err && err.statusCode) {
        return reply.code(502).send({
          error: 'evolution_error',
          message: `Evolution respondió con error (${err.statusCode})`,
          details: err.payload,
        });
      }
      throw err;
    }

    const client = await ctx.pgPool.connect();
    try {
      await client.query('BEGIN');

      const { rows } = await client.query(
        `INSERT INTO tombot.restaurantes
            (slug, nombre, instancia_evolution, evolution_api_key, timezone, activo)
         VALUES ($1, $2, $3, $4, $5, TRUE)
         RETURNING id, slug, nombre, timezone, instancia_evolution, activo, created_at, updated_at`,
        [slug, input.nombre, instanciaEvolution, evo.apiKey, timezone]
      );

      const rest = rows[0];

      // Config mínima para que el bot/panel muestre el nombre correcto
      await client.query(
        `INSERT INTO tombot.config (restaurante_id, parametro, valor, updated_at)
             VALUES ($1, 'NombreRestaurante', $2, NOW())
        ON CONFLICT (restaurante_id, parametro) DO UPDATE
             SET valor = EXCLUDED.valor, updated_at = NOW()`,
        [rest.id, input.nombre]
      );

      await client.query('COMMIT');

      return reply.code(201).send({
        restaurante: { ...rest, id: Number(rest.id) },
        evolution: { instanceName: instanciaEvolution, apiKey: evo.apiKey, qrcode: evo.qrcode || null },
      });
    } catch (err) {
      await client.query('ROLLBACK');
      if (err && err.code === '23505') {
        return reply.code(409).send({ error: 'duplicado', message: 'slug o instancia ya existe' });
      }
      throw err;
    } finally {
      client.release();
    }
  });

  fastify.post('/usuarios', async (req, reply) => {
    const body = req.body && typeof req.body === 'object' ? req.body : {};
    if (body.rol === 'superadmin') {
      return reply.code(403).send({
        error: 'forbidden',
        message: 'No se puede crear superadmin por API; solo por base de datos.',
      });
    }

    const parsed = CreateUsuarioSchema.safeParse(req.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'bad_request', issues: parsed.error.issues });
    }
    const input = parsed.data;

    const restauranteId = Number(input.restaurante_id);

    if (!restauranteId) {
      return reply.code(400).send({ error: 'bad_request', message: 'restaurante_id requerido' });
    }

    const passwordHash = await bcrypt.hash(input.password, 12);

    const { rows } = await ctx.pgPool.query(
      `INSERT INTO tombot.usuarios_panel (restaurante_id, email, password_hash, nombre, rol, activo)
            VALUES ($1, $2, $3, $4, $5, TRUE)
       ON CONFLICT (email) DO UPDATE
          SET restaurante_id = EXCLUDED.restaurante_id,
              password_hash  = EXCLUDED.password_hash,
              nombre         = COALESCE(EXCLUDED.nombre, tombot.usuarios_panel.nombre),
              rol            = EXCLUDED.rol,
              activo         = TRUE,
              updated_at     = NOW()
       RETURNING id, restaurante_id, email, nombre, rol, activo, created_at, updated_at`,
      [restauranteId, input.email, passwordHash, input.nombre || null, input.rol]
    );

    const u = rows[0];
    return reply.code(201).send({
      usuario: {
        id: Number(u.id),
        email: u.email,
        nombre: u.nombre,
        rol: u.rol,
        restaurante_id: u.restaurante_id ? Number(u.restaurante_id) : null,
        activo: u.activo,
        created_at: u.created_at,
        updated_at: u.updated_at,
      },
    });
  });

  // “Entrar” a un restaurante: emite token scoping con restaurante_id.
  fastify.post('/restaurantes/:id/entrar', async (req, reply) => {
    const rid = Number(req.params.id);
    if (!Number.isFinite(rid) || rid <= 0) {
      return reply.code(400).send({ error: 'bad_request' });
    }

    const { rows } = await ctx.pgPool.query(
      `SELECT id, slug, nombre, timezone
         FROM tombot.restaurantes
        WHERE id = $1 AND activo = TRUE
        LIMIT 1`,
      [rid]
    );
    const r = rows[0];
    if (!r) return reply.code(404).send({ error: 'not_found' });

    const token = await reply.jwtSign(
      {
        usuario_id: req.user.usuario_id,
        restaurante_id: Number(r.id),
        rol: req.user.rol,
        email: req.user.email,
      },
      { expiresIn: '8h' }
    );

    return {
      token,
      restaurante: {
        id: Number(r.id),
        slug: r.slug,
        nombre: r.nombre,
        timezone: r.timezone,
      },
    };
  });
}

