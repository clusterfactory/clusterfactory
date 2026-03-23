'use strict';

const express        = require('express');
const http           = require('http');
const path           = require('path');
const { exec }       = require('child_process');
const pty            = require('node-pty');
const { WebSocketServer } = require('ws');

const app    = express();
const server = http.createServer(app);
const wss    = new WebSocketServer({ server });

// ── Runtime config ─────────────────────────────────────────────────────────
const host         = process.env.CONTROL_PLANE_HOST || 'localhost';
const giteaPort    = process.env.GITEA_PORT          || '30080';
const argoPort     = process.env.ARGOCD_PORT         || '8080';
const headlampPort = process.env.HEADLAMP_PORT       || '4466';
const title        = process.env.COCKPIT_TITLE       || 'planectl management cluster';
const releaseName  = process.env.RELEASE_NAME        || 'platform';
const namespace    = process.env.NAMESPACE           || 'platform';

app.get('/wiring', (_req, res) => {
  const md = require('fs').readFileSync(path.join(__dirname, 'wiring.md'), 'utf8');
  res.send(`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>wiring — platform</title>
<script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/mermaid/dist/mermaid.min.js"></script>
<style>
  :root { --bg:#0a0e1a; --surface:#0f1628; --border:#1e2d4a; --accent:#00d4ff; --text:#e2e8f0; --muted:#8892a4; }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: var(--bg); color: var(--text); font-family: system-ui, sans-serif; padding: 40px 20px; }
  #content { max-width: 900px; margin: 0 auto; }
  h1,h2,h3 { color: var(--accent); margin: 1.6em 0 0.6em; font-family: monospace; }
  h1 { font-size: 1.4rem; border-bottom: 1px solid var(--border); padding-bottom: 0.4em; }
  h2 { font-size: 1.1rem; }
  p  { line-height: 1.7; margin: 0.6em 0; color: var(--text); }
  a  { color: var(--accent); }
  code { background: var(--surface); border: 1px solid var(--border); border-radius: 3px; padding: 1px 5px; font-family: monospace; font-size: 0.85em; }
  pre { background: var(--surface); border: 1px solid var(--border); border-radius: 6px; padding: 16px; overflow-x: auto; margin: 1em 0; }
  pre code { background: none; border: none; padding: 0; font-size: 0.82em; }
  table { border-collapse: collapse; width: 100%; margin: 1em 0; }
  th { background: var(--surface); color: var(--accent); font-family: monospace; font-size: 0.85em; padding: 8px 12px; border: 1px solid var(--border); text-align: left; }
  td { padding: 7px 12px; border: 1px solid var(--border); font-size: 0.9em; vertical-align: top; }
  td code { font-size: 0.82em; }
  .mermaid { background: var(--surface); border: 1px solid var(--border); border-radius: 6px; padding: 24px; margin: 1em 0; display: flex; justify-content: center; }
  hr { border: none; border-top: 1px solid var(--border); margin: 2em 0; }
</style>
</head>
<body>
<div id="content"></div>
<script>
  mermaid.initialize({ startOnLoad: false, theme: 'dark', securityLevel: 'loose' });
  const raw = ${JSON.stringify(md)};
  document.getElementById('content').innerHTML = marked.parse(raw);
  const diagrams = [];
  document.querySelectorAll('pre code.language-mermaid').forEach(el => {
    const div = document.createElement('div');
    div.className = 'mermaid';
    div.textContent = el.textContent;
    el.closest('pre').replaceWith(div);
    diagrams.push(div);
  });
  if (diagrams.length) mermaid.run({ nodes: diagrams }).catch(console.error);
</script>
</body>
</html>`);
});

app.get('/config', (_req, res) => {
  res.json({
    host,
    title,
    giteaUrl:    `http://${host}:${giteaPort}`,
    argoUrl:     `http://${host}:${argoPort}`,
    headlampUrl: `http://${host}:${headlampPort}`,
  });
});

// ── Component status ────────────────────────────────────────────────────────
function kubectl(args) {
  return new Promise(resolve => {
    exec(`kubectl ${args}`, { timeout: 4000 }, (err, stdout) => resolve({ err, stdout: stdout || '' }));
  });
}

app.get('/status', async (_req, res) => {
  try {
    const [gitea, argocd, crossplane, wiring] = await Promise.all([
      kubectl(`rollout status deployment/${releaseName}-gitea -n ${namespace} --timeout=3s 2>&1`)
        .then(({ err, stdout }) => (!err && stdout.includes('successfully rolled out')) ? 'ok' : 'pending'),
      kubectl(`rollout status deployment/${releaseName}-argocd-server -n ${namespace} --timeout=3s 2>&1`)
        .then(({ err, stdout }) => (!err && stdout.includes('successfully rolled out')) ? 'ok' : 'pending'),
      kubectl(`rollout status deployment/crossplane -n ${namespace} --timeout=3s 2>&1`)
        .then(({ err, stdout }) => (!err && stdout.includes('successfully rolled out')) ? 'ok' : 'pending'),
      kubectl(`get secret ${releaseName}-wiring-tokens -n ${namespace} 2>/dev/null`)
        .then(({ err }) => err ? 'pending' : 'ok'),
    ]);
    res.json({ gitea, argocd, crossplane, wiring });
  } catch (_) {
    res.json({ gitea: 'pending', argocd: 'pending', crossplane: 'pending', wiring: 'pending' });
  }
});

// Serve static files (index.html, node_modules, etc.)
app.use(express.static(path.join(__dirname)));

wss.on('connection', (ws) => {
  const shellCmd = process.env.SHELL_CMD
    ? process.env.SHELL_CMD.trim().split(/\s+/)
    : [process.env.SHELL || '/bin/bash', '--login'];
  const [shellBin, ...shellArgs] = shellCmd;

  const ptyProcess = pty.spawn(shellBin, shellArgs, {
    name: 'xterm-256color',
    cols: 80,
    rows: 24,
    cwd: process.env.HOME || '/',
    env: process.env,
  });

  // PTY → browser
  ptyProcess.onData((data) => {
    if (ws.readyState === ws.OPEN) ws.send(data);
  });

  // Browser → PTY
  ws.on('message', (msg) => {
    const text = Buffer.isBuffer(msg) ? msg.toString('utf8') : msg;
    try {
      const obj = JSON.parse(text);
      if (obj.type === 'resize') {
        ptyProcess.resize(
          Math.max(2, Math.min(500, obj.cols)),
          Math.max(1, Math.min(200, obj.rows))
        );
        return;
      }
      if (obj.type === 'b64') {
        ptyProcess.write(Buffer.from(obj.data, 'base64').toString('utf8'));
        return;
      }
    } catch (_) { /* raw input */ }
    ptyProcess.write(text);
  });

  ptyProcess.onExit(() => { if (ws.readyState === ws.OPEN) ws.close(); });

  const killPty = () => { try { ptyProcess.kill(); } catch (_) {} };
  ws.on('close', killPty);
  ws.on('error', killPty);
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, '0.0.0.0', () => {
  console.log(`planectl → http://${host}:${PORT}`);
});
