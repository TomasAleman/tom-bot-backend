/**
 * Catálogo único de parámetros de tombot.config.
 *
 * Los nombres deben coincidir EXACTAMENTE con los que consume n8n
 * (workflows/code-nodes/01_decidir_flujo.js y otros). Respetamos el
 * typo histórico "BloqueMaximoMinutos" para no romper esos workflows.
 *
 * Los valores se siguen guardando en la BD como TEXT (compatibilidad
 * con n8n, que parsea con parseInt/String(...).toLowerCase()). El
 * tipado es solo para validar y para que el panel renderice el
 * input adecuado.
 */

export const PARAMETROS_CONFIG = {
  AvisarBloqueo: {
    tipo: 'bool',
    label: 'Avisar al bloquear',
    descripcion:
      'Si está en Sí, el bot avisa al usuario cuando se bloquea por superar el límite de mensajes sin completar.',
  },
  BloqueMaximoMinutos: {
    tipo: 'int',
    min: 1,
    max: 1440,
    label: 'Tope de bloqueo (minutos)',
    descripcion:
      'Tope superior del bloqueo (en minutos). El bloqueo crece exponencialmente pero nunca supera este valor.',
  },
  BloqueoInicialMinutos: {
    tipo: 'int',
    min: 1,
    max: 60,
    label: 'Bloqueo inicial (minutos)',
    descripcion:
      'Duración del primer bloqueo cuando un usuario excede el límite de mensajes sin completar.',
  },
  DiasMaxAnticipacion: {
    tipo: 'int',
    min: 1,
    max: 365,
    label: 'Días máx. de anticipación',
    descripcion:
      'Cuántos días en el futuro como máximo puede reservar un cliente.',
  },
  MensajesMaxSinCompletar: {
    tipo: 'int',
    min: 1,
    max: 100,
    label: 'Mensajes sin completar antes del bloqueo',
    descripcion:
      'Cantidad de mensajes consecutivos sin cerrar la reserva antes de bloquear al usuario.',
  },
  NombreRestaurante: {
    tipo: 'string',
    maxLength: 120,
    label: 'Nombre del restaurante',
    descripcion:
      'Nombre con el que el bot se presenta y firma los mensajes.',
  },
};

/**
 * Devuelve true si el parámetro está en el catálogo.
 */
export function esParametroConocido(parametro) {
  return Object.prototype.hasOwnProperty.call(PARAMETROS_CONFIG, parametro);
}

/**
 * Valida y normaliza un valor según el tipo del catálogo.
 *
 * Devuelve { ok: true, valor: string } con el valor normalizado a TEXT
 * para persistir, o { ok: false, error: string } con el motivo.
 */
export function validarValor(parametro, valor) {
  const def = PARAMETROS_CONFIG[parametro];
  if (!def) return { ok: false, error: 'parametro_desconocido' };

  if (valor === null || valor === undefined || valor === '') {
    return { ok: true, valor: null };
  }

  if (def.tipo === 'bool') {
    if (valor === true || valor === 1 || valor === '1' || valor === 'true' || valor === 'TRUE' || valor === 'True') {
      return { ok: true, valor: 'true' };
    }
    if (valor === false || valor === 0 || valor === '0' || valor === 'false' || valor === 'FALSE' || valor === 'False') {
      return { ok: true, valor: 'false' };
    }
    return { ok: false, error: 'valor_no_booleano' };
  }

  if (def.tipo === 'int') {
    const n = typeof valor === 'number' ? valor : Number(String(valor).trim());
    if (!Number.isInteger(n)) return { ok: false, error: 'valor_no_entero' };
    if (typeof def.min === 'number' && n < def.min) return { ok: false, error: `valor_min_${def.min}` };
    if (typeof def.max === 'number' && n > def.max) return { ok: false, error: `valor_max_${def.max}` };
    return { ok: true, valor: String(n) };
  }

  if (def.tipo === 'string') {
    const s = String(valor).trim();
    if (s.length === 0) return { ok: true, valor: null };
    if (typeof def.maxLength === 'number' && s.length > def.maxLength) {
      return { ok: false, error: `valor_max_length_${def.maxLength}` };
    }
    return { ok: true, valor: s };
  }

  return { ok: false, error: 'tipo_desconocido' };
}
