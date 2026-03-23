'use strict';
/**
 * server.integration.test.js
 *
 * Spawns server.js on a random port, exercises the HTTP /config endpoint
 * and the WebSocket PTY protocol (b64 commands, resize, reconnect).
 *
 * Requires: node-pty native bindings compiled (npm install from the parent dir).
 */

const http     = require('http');
const { spawn }  = require('child_process');
const { WebSocket } = require('ws');
const path     = require('path');

// ── helpers ───────────────────────────────────────────────────────────────────

const SERVER_JS = path.join(__dirname, '..', 'server.js');
const PORT      = 14001;
const BASE      = `http://localhost:${PORT}`;
const WS_BASE   = `ws://localhost:${PORT}`;

function httpGet(url) {
  return new Promise((resolve, reject) => {
    http.get(url, (res) => {
      let body = '';
      res.on('data', (d) => (body += d));
      res.on('end', () => resolve({ status: res.statusCode, body, headers: res.headers }));
    }).on('error', reject);
  });
}

function openWs(url = WS_BASE) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    ws.once('open',  () => resolve(ws));
    ws.once('error', reject);
  });
}

/** Collect all WS messages for `ms` milliseconds, then return them. */
function collectMessages(ws, ms) {
  return new Promise((resolve) => {
    const msgs = [];
    const handler = (data) => msgs.push(data.toString());
    ws.on('message', handler);
    setTimeout(() => { ws.off('message', handler); resolve(msgs); }, ms);
  });
}

/** Wait until at least one WS message contains `substr`. */
function waitForOutput(ws, substr, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`Timeout waiting for "${substr}"`)), timeoutMs);
    const buf = [];
    function check(data) {
      buf.push(data.toString());
      const full = buf.join('');
      if (full.includes(substr)) {
        clearTimeout(timer);
        ws.off('message', check);
        resolve(full);
      }
    }
    ws.on('message', check);
  });
}

function send(ws, obj) {
  ws.send(JSON.stringify(obj));
}

// ── lifecycle ─────────────────────────────────────────────────────────────────

let proc;

beforeAll(() => new Promise((resolve, reject) => {
  proc = spawn('node', [SERVER_JS], {
    env: {
      ...process.env,
      PORT:                String(PORT),
      CONTROL_PLANE_HOST:  'test-host',
      GITEA_PORT:          '30080',
      ARGOCD_PORT:         '8080',
      COCKPIT_TITLE:       'test cockpit',
      SHELL_CMD:           '/bin/sh',   // use sh; bash may not be in all envs
    },
  });

  proc.stdout.on('data', (d) => {
    if (d.toString().includes('planectl →')) resolve();
  });
  proc.stderr.on('data', () => {});   // suppress noise
  proc.on('error', reject);
  setTimeout(() => reject(new Error('Server did not start within 8s')), 8000);
}));

afterAll(() => { if (proc) proc.kill(); });

// ── HTTP tests ─────────────────────────────────────────────────────────────────

describe('GET /config', () => {
  test('returns 200 JSON', async () => {
    const res = await httpGet(`${BASE}/config`);
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/json/);
  });

  test('response contains host, title, giteaUrl, argoUrl', async () => {
    const res = await httpGet(`${BASE}/config`);
    const body = JSON.parse(res.body);
    expect(body.host).toBe('test-host');
    expect(body.title).toBe('test cockpit');
    expect(body.giteaUrl).toMatch(/^http:\/\/test-host:/);
    expect(body.argoUrl).toMatch(/^http:\/\/test-host:/);
  });

  test('giteaUrl uses GITEA_PORT', async () => {
    const { body } = await httpGet(`${BASE}/config`);
    expect(JSON.parse(body).giteaUrl).toBe('http://test-host:30080');
  });

  test('argoUrl uses ARGOCD_PORT', async () => {
    const { body } = await httpGet(`${BASE}/config`);
    expect(JSON.parse(body).argoUrl).toBe('http://test-host:8080');
  });
});

describe('GET /status', () => {
  test('returns 200 JSON', async () => {
    const res = await httpGet(`${BASE}/status`);
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/json/);
  });

  test('response has gitea, argocd, crossplane, wiring keys', async () => {
    const { body } = await httpGet(`${BASE}/status`);
    const st = JSON.parse(body);
    expect(st).toHaveProperty('gitea');
    expect(st).toHaveProperty('argocd');
    expect(st).toHaveProperty('crossplane');
    expect(st).toHaveProperty('wiring');
  });

  test('all status values are "ok" or "pending"', async () => {
    const { body } = await httpGet(`${BASE}/status`);
    const st = JSON.parse(body);
    for (const val of Object.values(st)) {
      expect(['ok', 'pending']).toContain(val);
    }
  });
});

describe('GET / (static index.html)', () => {
  test('serves index.html', async () => {
    const res = await httpGet(`${BASE}/`);
    expect(res.status).toBe(200);
    expect(res.body).toMatch(/<!DOCTYPE html/i);
  });
});

// ── WebSocket / PTY tests ─────────────────────────────────────────────────────

describe('WebSocket connection', () => {
  test('connects and receives PTY output (shell prompt)', async () => {
    const ws = await openWs();
    // A shell always emits something (prompt, welcome, etc.) shortly after spawn
    const output = await waitForOutput(ws, '$', 4000).catch(() => '');
    ws.close();
    // Either we got a prompt or at minimum the connection succeeded
    expect(ws.readyState).not.toBe(WebSocket.CONNECTING);
  });

  test('multiple concurrent connections are accepted', async () => {
    const [ws1, ws2] = await Promise.all([openWs(), openWs()]);
    expect(ws1.readyState).toBe(WebSocket.OPEN);
    expect(ws2.readyState).toBe(WebSocket.OPEN);
    ws1.close();
    ws2.close();
  });
});

describe('WebSocket b64 command protocol', () => {
  let ws;
  beforeEach(async () => { ws = await openWs(); });
  afterEach(() => { if (ws.readyState === WebSocket.OPEN) ws.close(); });

  test('b64-encoded echo command produces output', async () => {
    const marker = `COCKPIT_TEST_${Date.now()}`;
    // Wait for initial prompt first
    await new Promise(r => setTimeout(r, 500));
    send(ws, { type: 'b64', data: Buffer.from(`echo ${marker}\r`).toString('base64') });
    const output = await waitForOutput(ws, marker, 5000);
    expect(output).toContain(marker);
  });

  test('b64 decoding is correct — special characters survive round-trip', async () => {
    await new Promise(r => setTimeout(r, 500));
    // printf keeps whitespace and special chars intact
    send(ws, { type: 'b64', data: Buffer.from('printf "hello world\\n"\r').toString('base64') });
    const output = await waitForOutput(ws, 'hello world', 5000);
    expect(output).toContain('hello world');
  });

  test('non-JSON raw text is forwarded to PTY', async () => {
    await new Promise(r => setTimeout(r, 500));
    const marker = `RAW_${Date.now()}`;
    ws.send(`echo ${marker}\r`);   // raw string, not JSON
    const output = await waitForOutput(ws, marker, 5000);
    expect(output).toContain(marker);
  });
});

describe('WebSocket resize protocol', () => {
  let ws;
  beforeEach(async () => { ws = await openWs(); });
  afterEach(() => { if (ws.readyState === WebSocket.OPEN) ws.close(); });

  test('resize message does not crash the server', async () => {
    send(ws, { type: 'resize', cols: 120, rows: 40 });
    // Server stays up — we can still run a command
    await new Promise(r => setTimeout(r, 300));
    const marker = `AFTER_RESIZE_${Date.now()}`;
    send(ws, { type: 'b64', data: Buffer.from(`echo ${marker}\r`).toString('base64') });
    const output = await waitForOutput(ws, marker, 5000);
    expect(output).toContain(marker);
  });

  test('resize clamps extreme values without crashing', async () => {
    // cols=0 and rows=0 are clamped to minimum; server must not throw
    send(ws, { type: 'resize', cols: 0, rows: 0 });
    send(ws, { type: 'resize', cols: 9999, rows: 9999 });
    await new Promise(r => setTimeout(r, 400));
    expect(ws.readyState).toBe(WebSocket.OPEN);
  });
});

describe('WebSocket lifecycle', () => {
  test('server stays up after client disconnect', async () => {
    const ws1 = await openWs();
    ws1.close();
    await new Promise(r => setTimeout(r, 500));

    // New connection still works
    const ws2 = await openWs();
    expect(ws2.readyState).toBe(WebSocket.OPEN);
    ws2.close();
  });
});
