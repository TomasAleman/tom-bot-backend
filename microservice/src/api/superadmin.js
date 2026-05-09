import { z } from 'zod';
import bcrypt from 'bcryptjs';
import { authHook } from '../middleware/auth.js';
import { requireSuperadmin } from '../middleware/authz.js';

const CreateRestauranteSchema = z.object({
  slug: z.string().trim().min(2).max(60).regex(/^[a-z0-9]+(?:-[a-z0-9]+)*$/).optional(),
  nombre: z.string().trim().min(2).max(120),
  timezone: z.string().trim().min(3).max(80).optional(),
  /** Nombre de instancia en Evolution (debe coincidir con la creada en Evolution Manager). Default: slug derivado del nombre. */
  instancia_evolution: z.string().trim().min(2).max(80).optional(),
  /** API key de la instancia (copiála desde Evolution); no se llama a /instance/create desde el backend. */
  evolution_api_key: z.string().trim().min(10).max(512),
});

const PG_STMT_RESTAURANTE_MS = parseInt(process.env.PG_STATEMENT_TIMEOUT_SUPERADMIN_MS || '20000', 10);

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
    const evolutionApiKey = input.evolution_api_key.trim();

    const t0 = Date.now();
    ctx.log.info(
      { evt: 'superadmin_resto_start', slug, instanciaEvolution },
      'POST /superadmin/restaurantes: inicio (solo DB; Evolution fuera del backend)'
    );

    let client;
    try {
      client = await ctx.pgPool.connect();
    } catch (err) {
      ctx.log.error({ err, evt: 'superadmin_resto_pool_connect_fail' }, 'POST /superadmin/restaurantes: sin conexion Postgres');
      return reply.code(503).send({
        error: 'database_unavailable',
        message:
          'No hay conexion disponible con la base de datos (pool agotado o Postgres inalcanzable). Revisa PGURL, Postgres y logs del contenedor.',
      });
    }

    try {
      await client.query('BEGIN');
      const stmtMs = Number.isFinite(PG_STMT_RESTAURANTE_MS) && PG_STMT_RESTAURANTE_MS > 0 ? PG_STMT_RESTAURANTE_MS : 20000;
      await client.query(`SET LOCAL statement_timeout = ${stmtMs}`);

      const { rows } = await client.query(
        `INSERT INTO tombot.restaurantes
            (slug, nombre, instancia_evolution, evolution_api_key, timezone, activo)
         VALUES ($1, $2, $3, $4, $5, TRUE)
         RETURNING id, slug, nombre, timezone, instancia_evolution, activo, created_at, updated_at`,
        [slug, input.nombre, instanciaEvolution, evolutionApiKey, timezone]
      );

      const rest = rows[0];

      await client.query(
        `INSERT INTO tombot.config (restaurante_id, parametro, valor, updated_at)
             VALUES ($1, 'NombreRestaurante', $2, NOW())
        ON CONFLICT (restaurante_id, parametro) DO UPDATE
             SET valor = EXCLUDED.valor, updated_at = NOW()`,
        [rest.id, input.nombre]
      );

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
      });
    } catch (err) {
      try {
        await client.query('ROLLBACK');
      } catch {
        /* noop */
      }
      if (err && err.code === '23505') {
        return reply.code(409).send({ error: 'duplicado', message: 'slug o instancia ya existe' });
      }
      if (err && err.code === '57014') {
        return reply.code(504).send({
          error: 'database_timeout',
          message: 'La base de datos tardó demasiado (statement_timeout). Revisa locks o carga en Postgres.',
        });
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
