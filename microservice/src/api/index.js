/**
 * Registra todas las rutas /api/* del panel web sobre la instancia Fastify.
 *
 * - /api/auth/login y /api/me: definidas en auth.js
 * - /api/reservas, /api/mesas, /api/config, /api/sesiones, /api/metricas:
 *   protegidas por authHook como preHandler.
 */

import { registerAuthRoutes } from './auth.js';
import { registerReservasRoutes } from './reservas.js';
import { registerMesasRoutes } from './mesas.js';
import { registerConfigRoutes } from './config.js';
import { registerSesionesRoutes } from './sesiones.js';
import { registerMetricasRoutes } from './metricas.js';
import { registerSuperadminRoutes } from './superadmin.js';

export async function registerApi(fastify, ctx) {
  await fastify.register(async (api) => {
    // Diagnóstico sin auth: si esto cuelga, el problema es routing/proxy, no JWT.
    api.get('/__raw', async () => ({ ok: true }));

    await registerAuthRoutes(api, ctx);

    await api.register((scope) => registerReservasRoutes(scope, ctx), { prefix: '/reservas' });
    await api.register((scope) => registerMesasRoutes(scope, ctx),    { prefix: '/mesas' });
    await api.register((scope) => registerConfigRoutes(scope, ctx),   { prefix: '/config' });
    await api.register((scope) => registerSesionesRoutes(scope, ctx), { prefix: '/sesiones' });
    await api.register((scope) => registerMetricasRoutes(scope, ctx), { prefix: '/metricas' });
    await api.register((scope) => registerSuperadminRoutes(scope, ctx), { prefix: '/superadmin' });
  }, { prefix: '/api' });
}
