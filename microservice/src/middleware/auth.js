/**
 * Middleware de autenticación JWT para las rutas /api/* del panel.
 *
 * Verifica el header Authorization: Bearer <token>, decodifica y deja
 * el payload en req.user = { usuario_id, restaurante_id, rol, email }.
 *
 * Devuelve 401 si falta el header, está malformado o el token expiró.
 *
 * IMPORTANTE: las queries de la API deben usar SIEMPRE
 * req.user.restaurante_id como filtro, ignorando cualquier
 * restaurante_id que venga del cliente.
 */

export async function authHook(req, reply) {
  try {
    const t0 = Date.now();
    req.log?.info?.({ evt: 'auth_jwt_verify_start' }, 'jwtVerify start');
    await Promise.race([
      req.jwtVerify(),
      new Promise((_, reject) =>
        setTimeout(() => {
          const e = new Error('jwt_verify_timeout');
          e.code = 'JWT_VERIFY_TIMEOUT';
          reject(e);
        }, 1000)
      ),
    ]);
    req.log?.info?.({ evt: 'auth_jwt_verify_ok', ms: Date.now() - t0 }, 'jwtVerify ok');
  } catch (err) {
    req.log?.warn?.({ evt: 'auth_jwt_verify_fail', code: err?.code, message: err?.message }, 'jwtVerify fail');
    if (err?.code === 'JWT_VERIFY_TIMEOUT') {
      return reply.code(401).send({ error: 'unauthorized', message: 'jwt_verify_timeout' });
    }
    return reply.code(401).send({ error: 'unauthorized', message: 'token invalido o expirado' });
  }

  const payload = req.user || {};
  const rol = payload.rol;
  if (!payload.usuario_id || !rol) {
    return reply.code(401).send({ error: 'unauthorized', message: 'token sin claims requeridos' });
  }
  if (rol !== 'superadmin' && !payload.restaurante_id) {
    return reply.code(401).send({ error: 'unauthorized', message: 'token sin claims requeridos' });
  }
  return undefined;
}
