function isRecepcionista(rol) {
  // compat: 'staff' era el rol legacy
  return rol === 'recepcionista' || rol === 'staff';
}

export function requireWriteAccess(req, reply) {
  const rol = req.user?.rol;
  if (isRecepcionista(rol)) {
    return reply.code(403).send({ error: 'forbidden', message: 'no tenes permisos para esta accion' });
  }
  return undefined;
}

export async function requireSuperadmin(req, reply) {
  const rol = req.user?.rol;
  req.log?.info?.({ evt: 'authz_superadmin_check', rol: rol ?? null }, 'requireSuperadmin');
  if (rol !== 'superadmin') {
    await reply.code(403).send({ error: 'forbidden', message: 'solo superadmin' });
    return undefined;
  }
  return undefined;
}

