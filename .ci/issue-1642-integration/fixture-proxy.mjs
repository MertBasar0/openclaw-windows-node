import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import { fileURLToPath } from 'node:url';

const apiHost = 'api.github.com';
const releasePath = '/repos/openclaw/openclaw-windows-node/releases';

// Routing only: metadata is input; production code must perform all selection.
export function responseFor(request, scenario) {
  if (request.method !== 'GET' || request.headers.authorization || request.headers.cookie ||
      request.headers['proxy-authorization']) return { status: 403, kind: 'forbidden' };
  const url = new URL(request.url, 'https://' + apiHost);
  if (url.origin !== 'https://' + apiHost) return { status: 403, kind: 'forbidden' };
  if (url.pathname === releasePath + '/latest' && !url.search)
    return { status: 200, kind: 'latest', body: scenario.latest };
  const query = [...url.searchParams];
  if (url.pathname === releasePath && query.every(([key, value]) =>
      (key === 'page' && value === '1') || (key === 'per_page' && value === '30')))
    return { status: 200, kind: 'list', body: scenario.releases };
  if (url.pathname.startsWith('/fixture-assets/')) return { status: 403, kind: 'blocked-download' };
  return { status: 403, kind: 'forbidden' };
}

export async function startFixture(directory) {
  const root = path.resolve(directory);
  const requests = path.join(root, 'requests.ndjson');
  const timeoutMs = Number(process.env.OPENCLAW_UPDATER_PROOF_IO_TIMEOUT_MS ?? 30000);
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1000) throw new Error('Invalid I/O timeout');
  const sockets = new Set();
  function track(socket) {
    sockets.add(socket);
    socket.setTimeout(timeoutMs, () => socket.destroy());
    socket.once('close', () => sockets.delete(socket));
  }
  function trace(record) {
    fs.appendFileSync(requests, JSON.stringify(record) + String.fromCharCode(10));
  }
  const tlsServer = https.createServer({
    key: fs.readFileSync(path.join(root, 'server-key.pem')),
    cert: fs.readFileSync(path.join(root, 'server-cert.pem')),
    minVersion: 'TLSv1.2',
  }, (request, response) => {
    let scenario;
    let result;
    try {
      scenario = JSON.parse(fs.readFileSync(path.join(root, 'scenario.json'), 'utf8'));
      result = responseFor(request, scenario);
    } catch {
      result = { status: 503, kind: 'fixture-not-ready' };
    }
    // Never record headers, credentials or response bodies.
    trace({ caseId: scenario?.caseId ?? null, kind: result.kind,
      method: request.method, path: request.url });
    response.writeHead(result.status, { 'content-type': 'application/json', connection: 'close' });
    response.end(result.status === 200 ? JSON.stringify(result.body) : '{}');
  });
  tlsServer.on('connection', track);
  tlsServer.on('tlsClientError', error => trace({ kind: 'tls-error', code: error.code ?? 'unknown' }));
  tlsServer.requestTimeout = timeoutMs;
  tlsServer.headersTimeout = timeoutMs;
  await new Promise((resolve, reject) => {
    tlsServer.once('error', reject);
    tlsServer.listen(0, '127.0.0.1', resolve);
  });
  const tlsPort = tlsServer.address().port;
  const proxy = http.createServer((request, response) => {
    trace({ kind: 'forbidden-plaintext', method: request.method });
    response.writeHead(403, { connection: 'close' }); response.end();
  });
  proxy.on('connection', track);
  proxy.on('connect', (request, client, head) => {
    if (request.url !== apiHost + ':443' || request.headers['proxy-authorization']) {
      trace({ kind: 'forbidden-connect' });
      client.end(['HTTP/1.1 403 Forbidden', 'Connection: close', '', ''].join(String.fromCharCode(13, 10)));
      return;
    }
    // The ONLY outbound socket this fixture creates is to its own TLS listener.
    // It cannot forward a request to GitHub or to a download host.
    const local = net.connect({ host: '127.0.0.1', port: tlsPort });
    track(local);
    local.once('connect', () => {
      client.write(['HTTP/1.1 200 Connection Established', '', ''].join(String.fromCharCode(13, 10)));
      if (head.length) local.write(head);
      client.pipe(local); local.pipe(client);
    });
    local.on('error', () => client.destroy());
    client.on('error', () => local.destroy());
    client.on('close', () => local.destroy());
  });
  try {
    await new Promise((resolve, reject) => {
      proxy.once('error', reject);
      proxy.listen(0, '127.0.0.1', resolve);
    });
  } catch (error) {
    tlsServer.close();
    throw error;
  }
  const address = 'http://127.0.0.1:' + proxy.address().port;
  fs.writeFileSync(path.join(root, 'ready.json'), JSON.stringify({ pid: process.pid, proxy: address }));
  return {
    address,
    close: async () => {
      for (const socket of sockets) socket.destroy();
      await Promise.all([proxy, tlsServer].map(server => new Promise(resolve => server.close(resolve))));
    },
  };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.length !== 3) throw new Error('Usage: node fixture-proxy.mjs <task-directory>');
  const fixture = await startFixture(process.argv[2]);
  let stopping = false;
  const stop = async () => {
    if (stopping) return;
    stopping = true;
    await fixture.close();
    process.exit(0);
  };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}
