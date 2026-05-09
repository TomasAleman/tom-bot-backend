/**
 * k6 load test: POST cuerpo tipo Evolution API contra n8n o Fastify.
 *
 * Uso (PowerShell):
 *   $env:BASE_URL="https://n8n.ejemplo.com"; $env:WEBHOOK_PATH="/webhook/whatsapp-reservas-v2"; $env:INSTANCE_NAME="mi-instancia"; k6 run stress.js
 *
 * Ver README.md para variables y ejemplos.
 */

import http from 'k6/http';
import { check, sleep } from 'k6';

function intEnv(name, fallback) {
  const raw = __ENV[name];
  if (raw === undefined || raw === '') return fallback;
  const n = parseInt(raw, 10);
  return Number.isFinite(n) ? n : fallback;
}

function trimSlash(s) {
  if (!s) return '';
  return s.replace(/\/+$/, '');
}

function isFastifyTarget() {
  const target = (__ENV.TARGET || '').toLowerCase();
  if (target === 'fastify' || target === 'node') return true;
  const path = (__ENV.WEBHOOK_PATH || '').toLowerCase();
  return path.includes('whatsapp-reservas-fast');
}

function buildUrl() {
  const base = trimSlash(__ENV.BASE_URL || '');
  let path = __ENV.WEBHOOK_PATH || '/webhook/whatsapp-reservas-v2';
  if (!path.startsWith('/')) path = `/${path}`;
  if (!base) {
    throw new Error('BASE_URL es obligatoria (sin barra final), ej: https://n8n.midominio.com');
  }
  return `${base}${path}`;
}

const fastifyMode = isFastifyTarget();

export const options = {
  stages: [
    { duration: `${intEnv('STAGE1_DURATION_SEC', 30)}s`, target: intEnv('STAGE1_TARGET', 10) },
    { duration: `${intEnv('STAGE2_DURATION_SEC', 120)}s`, target: intEnv('STAGE2_TARGET', 40) },
    { duration: `${intEnv('STAGE3_DURATION_SEC', 30)}s`, target: intEnv('STAGE3_TARGET', 0) },
  ],
  // Modo descubrimiento: no fallar el run por checks/SLA; analizar consola y summary.
  thresholds: {
    http_req_duration: ['p(99)<3600000'],
    checks: ['rate>=0'],
  },
};

export function setup() {
  const url = buildUrl();
  return { url, fastify: fastifyMode };
}

export default function (data) {
  const url = data?.url || buildUrl();
  const useFastify = data?.fastify !== undefined ? data.fastify : fastifyMode;

  const instance = __ENV.INSTANCE_NAME || 'stress-test-instance';
  const messageText = __ENV.MESSAGE_TEXT || 'Hola, quiero reservar mesa para 2 personas mañana a las 20hs';

  const vu = __VU;
  const iter = __ITER;
  const suffix = `${vu}${iter}`.replace(/[^0-9]/g, '');
  const digits = (suffix + '0000000000').slice(0, 10);
  const remoteJid = `549351${digits}@s.whatsapp.net`;

  const body = JSON.stringify({
    event: 'messages.upsert',
    instance,
    data: {
      key: {
        fromMe: false,
        remoteJid,
      },
      message: {
        conversation: messageText,
      },
    },
  });

  const params = {
    headers: { 'Content-Type': 'application/json' },
    tags: { name: 'webhook' },
  };

  const res = http.post(url, body, params);

  const okStatus = useFastify
    ? res.status === 202
    : res.status >= 200 && res.status < 300;

  check(res, {
    status_ok: () => okStatus,
  });

  const sleepMs = intEnv('SLEEP_MS', 0);
  if (sleepMs > 0) {
    sleep(sleepMs / 1000);
  }
}
