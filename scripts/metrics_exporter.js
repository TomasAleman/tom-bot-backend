#!/usr/bin/env node
/**
 * HTTP server super simple que expone metricas Prometheus desde la
 * vista tombot.v_metricas_5min y otras queries agregadas.
 *
 * Levanta en el puerto $METRICS_PORT (default 9100) y atiende /metrics.
 *
 * Uso:
 *   PGURL=postgres://... METRICS_PORT=9100 node scripts/metrics_exporter.js
 *
 * En docker-compose se puede agregar como sidecar:
 *
 *   tombot-metrics:
 *     image: node:20-alpine
 *     command: node /app/scripts/metrics_exporter.js
 *     volumes:
 *       - ./:/app
 *     environment:
 *       PGURL: postgres://postgres:****@postgres:5432/evolution
 *     ports:
 *       - "9100:9100"
 */

const http = require('http');
const { Pool } = require('pg');

const pgPool = new Pool(
  process.env.PGURL
    ? { connectionString: process.env.PGURL }
    : {
        host: process.env.PGHOST || 'localhost',
        port: parseInt(process.env.PGPORT || '5432', 10),
        user: process.env.PGUSER || 'postgres',
        password: process.env.PGPASSWORD,
        database: process.env.PGDATABASE || 'evolution',
      }
);

async function buildMetrics() {
  const lines = [];

  // Por tenant
  const m = await pgPool.query('SELECT * FROM tombot.v_metricas_5min');
  lines.push('# HELP tombot_mensajes_5min Mensajes recibidos en los ultimos 5 minutos');
  lines.push('# TYPE tombot_mensajes_5min gauge');
  for (const r of m.rows) {
    const labels = `restaurante_id="${r.restaurante_id || 'unknown'}",slug="${r.slug || 'unknown'}"`;
    lines.push(`tombot_mensajes_5min{${labels}} ${r.mensajes_5min ?? 0}`);
    lines.push(`tombot_mensajes_1h{${labels}} ${r.mensajes_1h ?? 0}`);
    lines.push(`tombot_reservas_24h{${labels}} ${r.reservas_24h ?? 0}`);
    lines.push(`tombot_rate_limits_1h{${labels}} ${r.rate_limits_1h ?? 0}`);
    if (r.p50_latencia_ms_5min != null) {
      lines.push(`tombot_latencia_p50_ms{${labels}} ${r.p50_latencia_ms_5min}`);
    }
    if (r.p95_latencia_ms_5min != null) {
      lines.push(`tombot_latencia_p95_ms{${labels}} ${r.p95_latencia_ms_5min}`);
    }
  }

  // Tenants activos
  const t = await pgPool.query('SELECT count(*)::INT AS n FROM tombot.restaurantes WHERE activo = TRUE');
  lines.push('# HELP tombot_tenants_activos Cantidad de tenants activos');
  lines.push('# TYPE tombot_tenants_activos gauge');
  lines.push(`tombot_tenants_activos ${t.rows[0].n}`);

  // Reservas globales hoy
  const rh = await pgPool.query(
    "SELECT count(*)::INT AS n FROM tombot.reservas WHERE created_at::DATE = CURRENT_DATE AND estado='Confirmada'"
  );
  lines.push('# HELP tombot_reservas_hoy_total Reservas confirmadas creadas hoy');
  lines.push('# TYPE tombot_reservas_hoy_total counter');
  lines.push(`tombot_reservas_hoy_total ${rh.rows[0].n}`);

  return lines.join('\n') + '\n';
}

const port = parseInt(process.env.METRICS_PORT || '9100', 10);
const server = http.createServer(async (req, res) => {
  if (req.url !== '/metrics') {
    res.writeHead(404);
    res.end('not found');
    return;
  }
  try {
    const text = await buildMetrics();
    res.writeHead(200, { 'Content-Type': 'text/plain; version=0.0.4' });
    res.end(text);
  } catch (err) {
    res.writeHead(500);
    res.end(String(err.message));
  }
});

server.listen(port, () => {
  console.log(`tombot metrics exporter escuchando en :${port}/metrics`);
});
