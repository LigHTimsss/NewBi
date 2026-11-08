import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const swift = await readFile(new URL('../NewBi/Features/Video/VideoDeletionSheet.swift', import.meta.url), 'utf8');
const source = swift.match(/private static let observer = #"""\n([\s\S]*?)\n\s*"""#/)[1];
const endpoint = 'https://member.bilibili.com/x/web/archive/delete';
let passed = 0;

function fixture({ code = 0, status = 200, rejection = false } = {}) {
  const messages = [], calls = [];
  class XHR {
    listeners = [];
    responseType = '';
    open(...args) { this.openArgs = args; }
    addEventListener(name, fn, options) { this.listeners.push({ name, fn, once: options?.once }); }
    removeEventListener(name, fn) { this.listeners = this.listeners.filter(x => x.name !== name || x.fn !== fn); }
    send(body) { this.sentBody = body; }
    complete(result = { code }, responseStatus = status) {
      this.status = responseStatus;
      this.response = result;
      this.responseText = typeof result === 'string' ? result : JSON.stringify(result);
      const listeners = this.listeners;
      this.listeners = listeners.filter(x => !x.once);
      for (const { fn } of listeners) fn();
    }
  }
  const window = {
    webkit: { messageHandlers: { archiveDeleted: { postMessage: value => messages.push(value) } } },
    fetch(...args) {
      calls.push(args);
      return rejection ? Promise.reject(new Error('offline')) : Promise.resolve(new Response(JSON.stringify({ code }), { status }));
    },
  };
  vm.runInNewContext(source, { window, location: { href: endpoint }, URL, URLSearchParams, FormData, Request, XMLHttpRequest: XHR });
  return { window, XHR, messages, calls };
}

async function flush() { await new Promise(resolve => setTimeout(resolve, 30)); }
async function check(name, fn) { await fn(); passed++; console.log(`PASS ${name}`); }

await check('fetch success reports exact aid and preserves response and request', async () => {
  const f = fixture(); const options = { method: 'POST', body: 'aid=123&csrf=test' };
  const response = await f.window.fetch(endpoint, options);
  assert.deepEqual(await response.json(), { code: 0 });
  await flush(); assert.deepEqual(f.messages, ['123']);
  assert.strictEqual(f.calls[0][1], options);
});

await check('API failure, HTTP failure and invalid success values never report deletion', async () => {
  for (const options of [{ code: -403 }, { status: 500 }, { code: '0' }]) {
    const f = fixture(options);
    await f.window.fetch(endpoint, { method: 'POST', body: 'aid=123' });
    await flush(); assert.deepEqual(f.messages, []);
  }
});

await check('unrelated origin, path, GET and missing aid do not report', async () => {
  const f = fixture();
  for (const [url, options] of [
    ['https://example.com/x/web/archive/delete', { method: 'POST', body: 'aid=123' }],
    ['https://member.bilibili.com/x/web/archive/edit', { method: 'POST', body: 'aid=123' }],
    [endpoint, { method: 'GET' }], [endpoint, { method: 'POST', body: 'csrf=test' }],
  ]) await f.window.fetch(url, options);
  await flush(); assert.deepEqual(f.messages, []);
});

await check('Request body and FormData are handled without consuming original requests', async () => {
  const f = fixture();
  const request = new Request(endpoint, { method: 'POST', body: 'aid=234' });
  await f.window.fetch(request);
  const form = new FormData(); form.set('aid', '345');
  await f.window.fetch(endpoint, { method: 'POST', body: form });
  await flush(); assert.deepEqual(f.messages.sort(), ['234', '345']);
  assert.equal(request.bodyUsed, false);
});

await check('network failures remain failures and never imply success', async () => {
  const f = fixture({ rejection: true });
  await assert.rejects(f.window.fetch(endpoint, { method: 'POST', body: 'aid=123' }), /offline/);
  await flush(); assert.deepEqual(f.messages, []);
});

await check('XHR success uses the sent aid and preserves body', async () => {
  const f = fixture(); const xhr = new f.XHR();
  const body = new URLSearchParams({ aid: '456', csrf: 'test' });
  xhr.open('POST', endpoint); xhr.send(body); xhr.complete();
  assert.deepEqual(f.messages, ['456']); assert.strictEqual(xhr.sentBody, body);
});

await check('XHR errors, invalid JSON, GET and other endpoints are ignored', async () => {
  const f = fixture();
  for (const [method, url, result, status] of [
    ['POST', endpoint, { code: -101 }, 200], ['POST', endpoint, { code: 0 }, 503],
    ['POST', endpoint, 'not JSON', 200], ['GET', endpoint, { code: 0 }, 200],
    ['POST', 'https://example.com/x/web/archive/delete', { code: 0 }, 200],
  ]) {
    const xhr = new f.XHR(); xhr.open(method, url); xhr.send('aid=123'); xhr.complete(result, status);
  }
  assert.deepEqual(f.messages, []);
});

await check('JSON XHR responses and reused XHR objects produce one event per response', async () => {
  const f = fixture(); const xhr = new f.XHR(); xhr.responseType = 'json';
  xhr.open('POST', endpoint); xhr.send('aid=567'); xhr.complete();
  xhr.open('POST', endpoint); xhr.send('aid=678'); xhr.complete();
  assert.deepEqual(f.messages, ['567', '678']);
});

await check('aborted and reused XHR cannot report an old target as deleted', async () => {
  const f = fixture(); const xhr = new f.XHR();
  xhr.open('POST', endpoint); xhr.send('aid=123');
  // 第一次没有收到 load，相当于中止；同一个 XHR 被用于另一稿件。
  xhr.open('POST', endpoint); xhr.send('aid=999'); xhr.complete();
  assert.deepEqual(f.messages, ['999']);
});

console.log(`${passed} deletion observer checks passed; no network requests were made.`);
