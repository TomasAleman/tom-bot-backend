function isRecepcionista(rol) {
  // compat: 'staff' era el rol legacy
  return rol === 'recepcionista' || rol === 'staff';
}

export async function requireRestaurante(req, reply) {
  const rol = req.user?.rol;
  req.log?.info?.({ evt: 'authz_restaurante_check', rol: rol ?? null }, 'requireRestaurante');
  if (rol !== 'restaurante') {
    await reply.code(403).send({ error: 'forbidden', message: 'solo rol restaurante' });
    return undefined;
  }
  return undefined;
}

export async function requireWriteAccess(req, reply) {
  const rol = req.user?.rol;
  req.log?.info?.({ evt: 'authz_write_check', rol: rol ?? null }, 'requireWriteAccess');
  if (isRecepcionista(rol)) {
    await reply.code(403).send({ error: 'forbidden', message: 'no tenes permisos para esta accion' });
    return undefined;
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

