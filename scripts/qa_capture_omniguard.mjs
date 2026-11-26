#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import http from 'node:http';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const OUT_DIR = path.join(ROOT, 'docs', 'frames');
mkdirSync(OUT_DIR, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function findChrome() {
  const home = process.env.HOME || '';
  for (const p of [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    path.join(home, 'Library/Caches/ms-playwright/chromium-1217/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing'),
  ]) if (existsSync(p)) return p;
  throw new Error('Chrome not found');
}

async function waitForHttp(url) {
  for (let i = 0; i < 60; i++) {
    try { const r = await fetch(url); if (r.ok) return; } catch {}
    await sleep(200);
  }
  throw new Error('Timeout ' + url);
}

class CDP {
  constructor(wsUrl) { this.wsUrl = wsUrl; this.id = 1; this.pending = new Map(); this.listeners = new Map(); }
  async connect() {
    this.ws = new WebSocket(this.wsUrl);
    await new Promise((res, rej) => { this.ws.addEventListener('open', res, { once: true }); this.ws.addEventListener('error', rej, { once: true }); });
    this.ws.addEventListener('message', (e) => {
      const m = JSON.parse(String(e.data));
      if (m.id && this.pending.has(m.id)) {
        const { res, rej } = this.pending.get(m.id); this.pending.delete(m.id);
        m.error ? rej(new Error(m.error.message)) : res(m.result);
      } else if (m.method && this.listeners.has(m.method)) {
        for (const fn of this.listeners.get(m.method)) fn(m.params);
      }
    });
  }
  on(m, fn) { if (!this.listeners.has(m)) this.listeners.set(m, []); this.listeners.get(m).push(fn); }
  send(method, params = {}) {
    const id = this.id++;
    return new Promise((res, rej) => { this.pending.set(id, { res, rej }); this.ws.send(JSON.stringify({ id, method, params })); });
  }
  async eval(expr) {
    const r = await this.send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.text);
    return r.result?.value;
  }
  async shot(file) {
    const { data } = await this.send('Page.captureScreenshot', { format: 'png' });
    writeFileSync(file, Buffer.from(data, 'base64'));
  }
  close() { try { this.ws?.close(); } catch {} }
}

async function main() {
  const html = readFileSync(path.join(ROOT, 'dashboard', 'index.html'));
  const srv = http.createServer((req, res) => { res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' }); res.end(html); });
  await new Promise((r) => srv.listen(5192, '127.0.0.1', r));
  const debugPort = 9455;
  let chrome = null; let cdp = null;
  try {
    chrome = spawn(findChrome(), ['--headless=new', '--disable-gpu', '--no-sandbox', `--remote-debugging-port=${debugPort}`, '--window-size=1440,900', 'about:blank'], { stdio: 'ignore' });
    await waitForHttp(`http://127.0.0.1:${debugPort}/json/list`);
    const targets = await (await fetch(`http://127.0.0.1:${debugPort}/json/list`)).json();
    cdp = new CDP(targets.find(t => t.type === 'page' && t.webSocketDebuggerUrl).webSocketDebuggerUrl);
    await cdp.connect();
    const errs = [];
    cdp.on('Runtime.exceptionThrown', p => errs.push(p.exceptionDetails?.text || 'err'));
    await cdp.send('Page.enable');
    await cdp.send('Runtime.enable');
    await cdp.send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
    await cdp.send('Page.navigate', { url: 'http://127.0.0.1:5192/' });
    await sleep(4000); // wait for live 3-chain RPC calls to Base, Lasna, Unichain

    const info = await cdp.eval(`(() => ({
      baseCbs: document.getElementById('baseCbs')?.textContent,
      baseLat: document.getElementById('baseLatency')?.textContent,
      lasnaEv: document.getElementById('lasnaEvents')?.textContent,
      uniCbs: document.getElementById('uniCbs')?.textContent,
      uniLat: document.getElementById('uniLatency')?.textContent,
      overflowX: document.documentElement.scrollWidth - document.documentElement.clientWidth
    }))()`);
    await cdp.shot(path.join(OUT_DIR, '01-live-3chain-rpc.png'));

    await cdp.eval(`simulateSlowBleed()`);
    await sleep(300);
    await cdp.shot(path.join(OUT_DIR, '02-slow-bleed-dual-freeze.png'));

    await cdp.eval(`resetSim(); simulateStopLoss();`);
    await sleep(300);
    await cdp.shot(path.join(OUT_DIR, '03-keeperless-stoploss-hedge.png'));

    await cdp.eval(`simulateStaleAccrual();`);
    await sleep(300);
    await cdp.shot(path.join(OUT_DIR, '04-stale-accrual-breaker.png'));

    console.log(JSON.stringify({ status: errs.length === 0 ? 'PASS' : 'FAIL', errors: errs, liveRpc: info }, null, 2));
    if (errs.length > 0) process.exit(1);
  } finally {
    cdp?.close();
    chrome?.kill('SIGTERM');
    srv.close();
  }
}
main().catch(e => { console.error(e); process.exit(1); });
