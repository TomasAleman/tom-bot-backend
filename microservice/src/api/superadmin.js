import { z } from 'zod';
import bcrypt from 'bcryptjs';
import { authHook } from '../middleware/auth.js';
import { requireSuperadmin } from '../middleware/authz.js';

const CreateRestauranteSchema = z.object({
  slug: z.string().trim().min(2).max(60).regex(/^[a-z0-9]+(?:-[a-z0-9]+)*$/).optional(),
  nombre: z.string().trim().min(2).max(120),
  timezone: z.string().trim().min(3).max(80).optional(),
  instancia_evolution: z.string().trim().min(2).max(80).optional(),
  evolution_api_key: z.string().trim().min(10).max(512),
  admin_email: z.string().trim().toLowerCase().email().max(160),
  admin_password: z.string().min(8).max(200),
  admin_nombre: z.preprocess(
    (v) => (v === '' || v === null || v === undefined ? undefined : v),
    z.string().trim().min(1).max(120).optional()
  ),
});

const PG_STMT_RESTAURANTE_MS = parseInt(process.env.PG_STATEMENT_TIMEOUT_SUPERADMIN_MS || '45000', 10);

const CreateUsuarioSchema = z.object({
  restaurante_id: z.number().int().positive().nullable().optional(),
  email: z.string().trim().toLowerCase().email().max(160),
  password: z.string().min(8).max(200),
  nombre: z.string().trim().min(1).max(120).optional(),
  rol: z.enum(['admin_restaurante', 'recepcionista']),
});

function slugFromNombre(nombre) {
  return nombre
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60) || 'restaurante';
}

async function acquireClient(pool, log) {
  try {
    return await pool.connect();
  } catch (err) {
    log.error({ err, evt: 'superadmin_pool_connect_fail' }, 'sin conexion Postgres');
    return null;
  }
}

export async function registerSuperadminRoutes(fastify, ctx) {
  const preSuperadmin = { preHandler: [authHook, requireSuperadmin] };

  const superadminSelf = async (req) => ({
    ok: true,
    rol: req.user?.rol ?? null,
    usuario_id: req.user?.usuario_id ?? null,
    restaurante_id: req.user?.restaurante_id ?? null,
  });

  /** Diagnóstico (misma respuesta en ambas rutas; algunos proxies bloquean “ping”). */
  fastify.get('/ping', preSuperadmin, superadminSelf);
  fastify.get('/whoami', preSuperadmin, superadminSelf);

  fastify.get('/restaurantes', preSuperadmin, async () => {
    const { rows } = await ctx.pgPool.query(
      `SELECT id, slug, nombre, timezone, instancia_evolution, activo, created_at, updated_at
         FROM tombot.restaurantes
        ORDER BY id DESC`
    );
    return {
      data: rows.map((r) => ({ ...r, id: Number(r.id) })),
    };
  });

  /**
   * Alta restaurante + usuario admin en una transacción (admin_email / admin_password obligatorios).
   * bcrypt se calcula ANTES del BEGIN para no mantener locks innecesarios.
   */
  fastify.post('/restaurantes', preSuperadmin, async (req, reply) => {
    const parsed = CreateRestauranteSchema.safeParse(req.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'bad_request', issues: parsed.error.issues });
    }

    const input = parsed.data;
    const slug = input.slug || slugFromNombre(input.nombre);
    const timezone = input.timezone || 'America/Argentina/Buenos_Aires';
    const instanciaEvolution = input.instancia_evolution || slug;
    const evolutionApiKey = input.evolution_api_key.trim();

    let passwordHash;
    try {
      passwordHash = await bcrypt.hash(input.admin_password, 12);
    } catch (err) {
      ctx.log.error({ err, evt: 'superadmin_bcrypt_fail' }, 'bcrypt hash fallo');
      return reply.code(500).send({ error: 'internal_error', message: 'No se pudo procesar la contraseña' });
    }

    const t0 = Date.now();
    ctx.log.info(
      { evt: 'superadmin_resto_start', slug, instanciaEvolution },
      'POST /superadmin/restaurantes'
    );

    const client = await acquireClient(ctx.pgPool, ctx.log);
    if (!client) {
      return reply.code(503).send({
        error: 'database_unavailable',
        message:
          'No hay conexion disponible con la base de datos (pool agotado o Postgres inalcanzable). Revisa PGURL y logs.',
      });
    }

    try {
      await client.query('BEGIN');
      const stmtMs = Number.isFinite(PG_STMT_RESTAURANTE_MS) && PG_STMT_RESTAURANTE_MS > 0 ? PG_STMT_RESTAURANTE_MS : 45000;
      await client.query(`SET LOCAL statement_timeout = ${stmtMs}`);

      const { rows: restRows } = await client.query(
        `INSERT INTO tombot.restaurantes
            (slug, nombre, instancia_evolution, evolution_api_key, timezone, activo)
         VALUES ($1, $2, $3, $4, $5, TRUE)
         RETURNING id, slug, nombre, timezone, instancia_evolution, activo, created_at, updated_at`,
        [slug, input.nombre, instanciaEvolution, evolutionApiKey, timezone]
      );

      const rest = restRows[0];

      await client.query(
        `INSERT INTO tombot.config (restaurante_id, parametro, valor, updated_at)
             VALUES ($1, 'NombreRestaurante', $2, NOW())
        ON CONFLICT (restaurante_id, parametro) DO UPDATE
             SET valor = EXCLUDED.valor, updated_at = NOW()`,
        [rest.id, input.nombre]
      );

      const { rows: uRows } = await client.query(
        `INSERT INTO tombot.usuarios_panel (restaurante_id, email, password_hash, nombre, rol, activo)
              VALUES ($1, $2, $3, $4, 'admin_restaurante', TRUE)
         RETURNING id, restaurante_id, email, nombre, rol, activo, created_at, updated_at`,
        [rest.id, input.admin_email, passwordHash, input.admin_nombre || null]
      );
      const u = uRows[0];
      const usuarioPayload = {
        id: Number(u.id),
        email: u.email,
        nombre: u.nombre,
        rol: u.rol,
        restaurante_id: u.restaurante_id ? Number(u.restaurante_id) : null,
        activo: u.activo,
        created_at: u.created_at,
        updated_at: u.updated_at,
      };

      await client.query('COMMIT');

      ctx.log.info(
        {
          evt: 'superadmin_resto_commit',
          ms: Date.now() - t0,
          restauranteId: Number(rest.id),
          slug: rest.slug,
          instanciaEvolution,
        },
        'POST /superadmin/restaurantes: COMMIT OK'
      );

      return reply.code(201).send({
        restaurante: { ...rest, id: Number(rest.id) },
        evolution: { instanceName: instanciaEvolution },
        usuario: usuarioPayload,
      });
    } catch (err) {
      try {
        await client.query('ROLLBACK');
      } catch {
        /* noop */
      }
      if (err && err.code === '23505') {
        return reply.code(409).send({
          error: 'duplicado',
          message:
            'Ya existe ese slug, instancia Evolution o email de usuario. Probá otro slug o otro email.',
        });
      }
      if (err && err.code === '57014') {
        return reply.code(504).send({
          error: 'database_timeout',
          message: 'La base de datos tardó demasiado. Revisa locks o subí PG_STATEMENT_TIMEOUT_SUPERADMIN_MS.',
        });
      }
      ctx.log.error(
        { err, evt: 'superadmin_resto_unexpected', code: err?.code, detail: err?.detail },
        'POST /superadmin/restaurantes: error inesperado'
      );
      return reply.code(500).send({
        error: 'internal_error',
        message: err?.detail || err?.message || 'Error al guardar en la base de datos',
        code: err?.code || undefined,
      });
    } finally {
      client.release();
    }
  });

  fastify.post('/usuarios', preSuperadmin, async (req, reply) => {
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

  fastify.post('/restaurantes/:id/entrar', preSuperadmin, async (req, reply) => {
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
