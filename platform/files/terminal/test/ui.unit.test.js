'use strict';
/**
 * ui.unit.test.js
 *
 * Tests the browser-side JS behaviour defined in index.html using jsdom.
 * External libraries (xterm, AttachAddon, FitAddon, WebLinksAddon) are
 * stubbed so tests run without a real browser.
 *
 * Covers:
 *   - run(cmd)        — encodes command as b64 JSON and sends via WebSocket
 *   - setStatus()     — updates the connection dot and label in the DOM
 *   - sendResize()    — sends {type:'resize', cols, rows} JSON
 *   - config fetch    — patches header links and title from /config response
 */

const fs   = require('fs');
const path = require('path');

// ── stub the xterm globals that index.html expects ────────────────────────────

class FakeTerminal {
  constructor() { this._data = null; this.cols = 80; this.rows = 24; }
  loadAddon() {}
  open() {}
  clear() {}
  onResize(fn) { this._resizeFn = fn; }
  _triggerResize(cols, rows) { this.cols = cols; this.rows = rows; if (this._resizeFn) this._resizeFn({ cols, rows }); }
}

class FakeFitAddon   { fit() {} }
class FakeWebLinks   {}
class FakeAttachAddon { constructor(ws) { this.ws = ws; } }

// ── mock WebSocket ─────────────────────────────────────────────────────────────

class MockWebSocket {
  constructor(url) {
    this.url = url;
    this.readyState = MockWebSocket.OPEN;
    this.sent = [];
    MockWebSocket.last = this;
  }
  send(data) { this.sent.push(data); }
  close() { this.readyState = MockWebSocket.CLOSED; }
  static get OPEN()       { return 1; }
  static get CLOSED()     { return 3; }
  static get CONNECTING() { return 0; }
}

// ── load index.html and extract + eval the <script> block ─────────────────────

function loadCockpitScript() {
  const html    = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
  const match   = html.match(/<script>([\s\S]+?)<\/script>\s*<\/body>/);
  if (!match) throw new Error('Could not extract <script> block from index.html');
  return match[1];
}

let _scriptInjected = false;

function buildSandbox() {
  // DOM stubs
  document.body.innerHTML = `
    <div id="logo-text"></div>
    <div id="header-title"></div>
    <a id="gitea-link" href="#"></a>
    <a id="argo-link"  href="#"></a>
    <span id="conn-dot"   style="background:#d29922;"></span>
    <span id="conn-label">connecting…</span>
    <div id="card-gitea"      class="wire-card pending"><div class="wire-dot"></div><div><div class="wire-name">gitea</div><div class="wire-desc">checking…</div></div></div>
    <div id="card-argocd"     class="wire-card pending"><div class="wire-dot"></div><div><div class="wire-name">argocd</div><div class="wire-desc">checking…</div></div></div>
    <div id="card-crossplane" class="wire-card pending"><div class="wire-dot"></div><div><div class="wire-name">crossplane</div><div class="wire-desc">checking…</div></div></div>
    <div id="card-wiring"     class="wire-card pending"><div class="wire-dot"></div><div><div class="wire-name">wiring</div><div class="wire-desc">checking…</div></div></div>
    <div id="tc"></div>
  `;

  // Install globals the script reads
  global.Terminal         = FakeTerminal;
  global.FitAddon         = { FitAddon: FakeFitAddon };
  global.WebLinksAddon    = { WebLinksAddon: FakeWebLinks };
  global.AttachAddon      = { AttachAddon: FakeAttachAddon };
  global.WebSocket        = MockWebSocket;

  // Default fetch stub — returns an empty config so the script doesn't throw.
  if (!global.fetch || !global.fetch.mock) {
    global.fetch = jest.fn(() =>
      Promise.resolve({ json: () => Promise.resolve({ host: 'localhost', title: 'platform cockpit', giteaUrl: 'http://localhost:30080', argoUrl: 'http://localhost:8080' }) })
    );
  }
  window.fetch = global.fetch;

  // Prevent real timers from firing during eval
  jest.useFakeTimers();

  // Inject the script only once — jsdom shares one window per file,
  // so re-injecting causes "Identifier 'term' has already been declared".
  if (!_scriptInjected) {
    const script = loadCockpitScript();
    const el = document.createElement('script');
    el.textContent = script;
    document.head.appendChild(el);
    _scriptInjected = true;
  }

  return { MockWebSocket };
}

// ── single file-level setup ────────────────────────────────────────────────────
// buildSandbox() is called ONCE; all describe blocks share the same jsdom window.

beforeAll(async () => {
  // Route fetch() calls by URL:
  //   /config  → header-patching data
  //   /status  → component status for pollStatus() (all ok so wiring tests pass)
  global.fetch = jest.fn((url) => {
    if (url === '/status') {
      return Promise.resolve({ json: () => Promise.resolve(
        { gitea: 'ok', argocd: 'ok', crossplane: 'ok', wiring: 'ok' }
      )});
    }
    return Promise.resolve({ json: () => Promise.resolve({
      host: 'myhost', title: 'planectl management cluster',
      giteaUrl: 'http://myhost:30080', argoUrl: 'http://myhost:8080',
    })});
  });
  buildSandbox();
  // Flush the 2-level .then() chain from fetch('/config') in the script.
  // Microtasks (Promises) resolve regardless of fake timers.
  await Promise.resolve();
  await Promise.resolve();
});

afterAll(() => jest.useRealTimers());

// ── test suites ───────────────────────────────────────────────────────────────

describe('run(cmd) — b64 command protocol', () => {
  beforeEach(() => {
    MockWebSocket.last.sent = [];
    MockWebSocket.last.readyState = MockWebSocket.OPEN;
  });

  test('sends JSON with type "b64" and base64-encoded command when WS is open', () => {
    run('kubectl get pods\r');

    expect(MockWebSocket.last.sent).toHaveLength(1);
    const msg = JSON.parse(MockWebSocket.last.sent[0]);
    expect(msg.type).toBe('b64');
    expect(atob(msg.data)).toBe('kubectl get pods\r');
  });

  test('encodes the carriage return as part of the b64 payload', () => {
    run('helm list\r');
    const msg = JSON.parse(MockWebSocket.last.sent[0]);
    const decoded = atob(msg.data);
    expect(decoded.endsWith('\r')).toBe(true);
  });

  test('sends nothing when WebSocket is not open (CLOSED)', () => {
    MockWebSocket.last.readyState = MockWebSocket.CLOSED;
    run('kubectl get pods\r');
    expect(MockWebSocket.last.sent).toHaveLength(0);
  });

  test('sends nothing when WebSocket is still CONNECTING', () => {
    MockWebSocket.last.readyState = MockWebSocket.CONNECTING;
    run('kubectl get nodes\r');
    expect(MockWebSocket.last.sent).toHaveLength(0);
  });

  test('different commands produce different b64 payloads', () => {
    run('kubectl get pods\r');
    run('kubectl get nodes\r');
    const msgs = MockWebSocket.last.sent.map(s => JSON.parse(s));
    expect(msgs[0].data).not.toBe(msgs[1].data);
    expect(atob(msgs[0].data)).toBe('kubectl get pods\r');
    expect(atob(msgs[1].data)).toBe('kubectl get nodes\r');
  });
});

describe('setStatus() — connection indicator DOM', () => {
  test('setStatus("connected") turns dot green', () => {
    setStatus('connected');
    expect(document.getElementById('conn-dot').style.background).toMatch(/3fb950|rgb\(63,\s*185,\s*80\)/);
  });

  test('setStatus("connected") sets label text to "connected"', () => {
    setStatus('connected');
    expect(document.getElementById('conn-label').textContent).toBe('connected');
  });

  test('setStatus("disconnected") turns dot red', () => {
    setStatus('disconnected');
    expect(document.getElementById('conn-dot').style.background).toMatch(/ff7b72|rgb\(255,\s*123,\s*114\)/);
  });

  test('setStatus("disconnected") shows reconnecting message', () => {
    setStatus('disconnected');
    expect(document.getElementById('conn-label').textContent).toContain('reconnecting');
  });
});

describe('sendResize() — terminal resize protocol', () => {
  beforeEach(() => {
    MockWebSocket.last.sent = [];
    MockWebSocket.last.readyState = MockWebSocket.OPEN;
  });

  test('sends JSON with type "resize"', () => {
    sendResize();
    const msg = JSON.parse(MockWebSocket.last.sent[0]);
    expect(msg.type).toBe('resize');
  });

  test('includes cols and rows from xterm Terminal', () => {
    sendResize();
    const msg = JSON.parse(MockWebSocket.last.sent[0]);
    expect(typeof msg.cols).toBe('number');
    expect(typeof msg.rows).toBe('number');
    expect(msg.cols).toBeGreaterThan(0);
    expect(msg.rows).toBeGreaterThan(0);
  });

  test('sends nothing when WS is not open', () => {
    MockWebSocket.last.readyState = MockWebSocket.CLOSED;
    sendResize();
    expect(MockWebSocket.last.sent).toHaveLength(0);
  });
});

describe('connect() — WebSocket connection setup', () => {
  test('creates a WebSocket pointing to ws://location.host', () => {
    expect(MockWebSocket.last).toBeDefined();
    expect(MockWebSocket.last.url).toMatch(/^ws:\/\//);
  });

  test('reconnects after close (setTimeout scheduled)', () => {
    const ws = MockWebSocket.last;
    // Trigger onclose
    if (ws.onclose) ws.onclose();
    // A reconnect timer should be scheduled
    expect(jest.getTimerCount()).toBeGreaterThan(0);
  });
});

describe('/config fetch — header and title DOM patching', () => {
  // The fetch resolved during the file-level beforeAll with:
  // { host: 'myhost', title: 'platform cockpit', giteaUrl: 'http://myhost:30080', argoUrl: 'http://myhost:8080' }
  // Promise microtasks were flushed before any test ran.

  test('updates logo-text from first word of cfg.title', () => {
    expect(document.getElementById('logo-text').textContent).toBe('planectl');
  });

  test('updates header-title from remaining words of cfg.title', () => {
    expect(document.getElementById('header-title').textContent).toBe('management cluster');
  });

  test('patches gitea-link href from cfg.giteaUrl', () => {
    expect(document.getElementById('gitea-link').getAttribute('href')).toBe('http://myhost:30080');
  });

  test('patches argo-link href from cfg.argoUrl', () => {
    expect(document.getElementById('argo-link').getAttribute('href')).toBe('http://myhost:8080');
  });
});

describe('applyStatus() — component status cards', () => {
  afterEach(() => {
    // Reset all cards to pending so tests are independent
    ['gitea', 'argocd', 'crossplane', 'wiring'].forEach(id => {
      const card = document.getElementById('card-' + id);
      if (card) card.className = 'wire-card pending';
    });
  });

  test('sets card class to "ok" for ok status', () => {
    applyStatus({ gitea: 'ok', argocd: 'pending', crossplane: 'pending', wiring: 'pending' });
    expect(document.getElementById('card-gitea').className).toContain('ok');
  });

  test('sets card class to "pending" for pending status', () => {
    applyStatus({ gitea: 'pending', argocd: 'pending', crossplane: 'pending', wiring: 'pending' });
    expect(document.getElementById('card-gitea').className).toContain('pending');
  });

  test('updates all four cards at once', () => {
    applyStatus({ gitea: 'ok', argocd: 'ok', crossplane: 'ok', wiring: 'ok' });
    ['gitea', 'argocd', 'crossplane', 'wiring'].forEach(id => {
      expect(document.getElementById('card-' + id).className).toContain('ok');
    });
  });

  test('wiring card shows "applied" when ok', () => {
    applyStatus({ gitea: 'pending', argocd: 'pending', crossplane: 'pending', wiring: 'ok' });
    expect(document.getElementById('card-wiring').querySelector('.wire-desc').textContent).toBe('applied');
  });

  test('gitea card shows "running" when ok', () => {
    applyStatus({ gitea: 'ok', argocd: 'pending', crossplane: 'pending', wiring: 'pending' });
    expect(document.getElementById('card-gitea').querySelector('.wire-desc').textContent).toBe('running');
  });

  test('card shows "checking…" when pending', () => {
    applyStatus({ gitea: 'pending', argocd: 'pending', crossplane: 'pending', wiring: 'pending' });
    expect(document.getElementById('card-gitea').querySelector('.wire-desc').textContent).toContain('checking');
  });
});

describe('wiring status card', () => {
  test('wiring card starts as pending', () => {
    const card = document.getElementById('card-wiring');
    expect(card.className).toContain('pending');
  });

  test('wiring card turns ok after pollStatus fires and /status fetch resolves', async () => {
    // Advance 5 s: fires the 4 s setTimeout(pollStatus, 4000) but NOT the
    // 10 s re-poll it schedules, avoiding an infinite-loop in runAllTimers.
    await jest.advanceTimersByTimeAsync(5000);
    const card = document.getElementById('card-wiring');
    expect(card.className).toContain('ok');
  });
});
