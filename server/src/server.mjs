import http from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { WebSocketServer } from 'ws';
import { bridge } from './relay.mjs';

export function readConfig(env = process.env) {
  if (!env.OPENAI_API_KEY) throw new Error('Set OPENAI_API_KEY on the server.');
  if (!env.DEVICE_TOKEN || env.DEVICE_TOKEN.length < 32 || /[\s\x00-\x1f\x7f-\x9f]/.test(env.DEVICE_TOKEN)) {
    throw new Error('Set DEVICE_TOKEN to a random token of at least 32 characters (no whitespace or control characters).');
  }
  const port = Number(env.PORT ?? 8787);
  const maxSeconds = Number(env.SESSION_MAX_SECONDS ?? 300);
  const maxSessions = Number(env.MAX_SESSIONS ?? 1);
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error('Invalid PORT.');
  if (!Number.isInteger(maxSeconds) || maxSeconds < 10 || maxSeconds > 1800) throw new Error('SESSION_MAX_SECONDS must be 10–1800.');
  if (!Number.isInteger(maxSessions) || maxSessions < 1 || maxSessions > 10) throw new Error('MAX_SESSIONS must be 1–10.');
  return { apiKey: env.OPENAI_API_KEY, deviceToken: env.DEVICE_TOKEN, host: env.HOST ?? '127.0.0.1', port, maxSeconds, maxSessions, model: env.LIVE_MODEL ?? 'gpt-live-1' };
}

export function createRelayServer(config, connectUpstream) {
  const server = http.createServer((request, response) => {
    response.setHeader('Cache-Control', 'no-store');
    if (request.url === '/health' && request.method === 'GET') {
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.end(JSON.stringify({ status: 'ok', mode: 'prototype', providerConnectionVerified: false }));
    } else { response.writeHead(404); response.end(); }
  });
  const sockets = new WebSocketServer({ noServer: true, maxPayload: 65_536, perMessageDeflate: false });
  server.on('upgrade', (request, socket, head) => {
    const provided = Buffer.from(request.headers.authorization ?? '');
    const expected = Buffer.from(`Bearer ${config.deviceToken}`);
    const authorized = provided.length === expected.length && timingSafeEqual(provided, expected);
    let status;
    if (request.url !== '/interpret') status = '404 Not Found';
    else if (request.headers.origin) status = '403 Forbidden'; // Native app only; reject cross-site browser use.
    else if (!authorized) status = '401 Unauthorized';
    else if (sockets.clients.size >= config.maxSessions) status = '429 Too Many Requests';
    if (status) { socket.end(`HTTP/1.1 ${status}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`); return; }
    sockets.handleUpgrade(request, socket, head, (client) => bridge(client, config, connectUpstream));
  });
  return { server, sockets };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const config = readConfig();
    const { server, sockets } = createRelayServer(config);
    server.listen(config.port, config.host, () => {
      console.log(`Development relay listening at ${config.host}:${config.port}. Remote clients require a trusted TLS reverse proxy.`);
    });
    const shutdown = () => { for (const socket of sockets.clients) socket.terminate(); sockets.close(); server.close(); };
    process.on('SIGINT', shutdown);
    process.on('SIGTERM', shutdown);
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
