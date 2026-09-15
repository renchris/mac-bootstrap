#!/usr/bin/env node
'use strict';
// fake-server.js — an offline stand-in for the Softeria ms-365-mcp-server, used only by
// `node archive.js --selftest`. Zero dependencies. It speaks the same newline-delimited JSON-RPC over
// stdio (initialize, tools/list, tools/call) and answers the two tools the archive engine may call:
//
//   list-accounts   {accounts:[{email, name, isDefault}], count}
//   graph-batch     arguments.body.requests[] -> {responses:[{id, status, headers, body}]}, the shape the
//                   real server relays from Microsoft Graph's $batch: a JSON body stays an object, any
//                   other body is base64 (Graph's batch rule), so the engine's decoder is exercised.
//
// Answers come from fixtures/<name>.json, merged in the order named (a later file wins per key):
//   node fake-server.js --fixtures base,transcripts-available [--auth-dead]
// A fixture file is {"graph": {"GET <relative url>": answer, …}, "downloads": {"/<path>": {contentType, text}}}.
// Keys are compared canonically: the path and every query parameter percent-decoded, parameters sorted,
// so a fixture is written readably and still matches whatever encoding the engine chose. An answer is
// {status, headers, body} or {status, headers, text} (text is served base64), {sequence:[answer, …]}
// (served in turn, the last repeating), or {toolError: "<message>"} (the whole tools/call fails, the
// way a network failure inside the real server surfaces). An unknown url answers Graph's 404.
// "{{download_base}}" in any answer becomes this process's loopback download server, which serves
// "downloads" — the stand-in for Graph's pre-authenticated download URLs.
// --auth-dead makes every tools/call fail the way an expired sign-in does.
// MICROSOFT365_ARCHIVE_FAKE_REQUEST_LOG=<file> appends one JSON line per sub-request received, so a
// test can read back, from the server's side, exactly what the engine sent.

const fs = require('fs');
const path = require('path');
const http = require('http');

const args = process.argv.slice(2);
const fixtureNames = [];
let authDead = false;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--fixtures' && args[i + 1] !== undefined) { fixtureNames.push(...args[++i].split(',').filter(Boolean)); continue; }
  if (args[i] === '--auth-dead') { authDead = true; continue; }
  process.stderr.write('fake-server: unknown argument ' + args[i] + '\n');
  process.exit(2);
}

function safeDecode(s) { try { return decodeURIComponent(s); } catch (e) { return s; } }
function canonicalKey(method, url) {
  const u = String(url);
  const q = u.indexOf('?');
  const p = safeDecode(q < 0 ? u : u.slice(0, q));
  const params = q < 0 ? [] : u.slice(q + 1).split('&').filter(Boolean).map((kv) => {
    const e = kv.indexOf('=');
    return e < 0 ? [safeDecode(kv), ''] : [safeDecode(kv.slice(0, e)), safeDecode(kv.slice(e + 1))];
  });
  params.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0));
  return String(method).toUpperCase() + ' ' + p + (params.length ? '?' + params.map((x) => x[0] + '=' + x[1]).join('&') : '');
}

const graph = new Map();
const downloads = new Map();
for (const name of fixtureNames) {
  if (!/^[A-Za-z0-9._-]+$/.test(name)) { process.stderr.write('fake-server: bad fixture name ' + name + '\n'); process.exit(2); }
  let data;
  try { data = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', name + '.json'), 'utf8')); } catch (e) {
    process.stderr.write('fake-server: cannot read fixture ' + name + ': ' + e.message + '\n');
    process.exit(2);
  }
  for (const [k, v] of Object.entries(data.graph || {})) {
    const sp = k.indexOf(' ');
    graph.set(canonicalKey(k.slice(0, sp), k.slice(sp + 1)), v);
  }
  for (const [k, v] of Object.entries(data.downloads || {})) downloads.set(k, v);
}

let downloadBase = 'http://127.0.0.1:1';
const served = new Map();   // canonical key -> times served, for {sequence}
const requestLog = process.env.MICROSOFT365_ARCHIVE_FAKE_REQUEST_LOG || '';

function logRequest(entry) {
  if (!requestLog) return;
  try { fs.appendFileSync(requestLog, JSON.stringify(entry) + '\n'); } catch (e) { /* the log is a test aid only */ }
}

function withDownloadBase(value) {
  return JSON.parse(JSON.stringify(value).split('{{download_base}}').join(downloadBase));
}

function subResponse(req) {
  const id = String(req && req.id);
  const method = String((req && req.method) || '');
  const url = String((req && req.url) || '');
  logRequest({ method, url, headers: (req && req.headers) || {} });
  if (method.toUpperCase() !== 'GET') {
    return { id, status: 405, headers: { 'Content-Type': 'application/json' }, body: { error: { code: 'methodNotAllowed', message: 'fake server: only GET is served' } } };
  }
  const key = canonicalKey(method, url);
  let answer = graph.get(key);
  if (answer === undefined) {
    return { id, status: 404, headers: { 'Content-Type': 'application/json' }, body: { error: { code: 'itemNotFound', message: 'fake server: no fixture for ' + key } } };
  }
  if (Array.isArray(answer.sequence)) {
    const n = served.get(key) || 0;
    served.set(key, n + 1);
    answer = answer.sequence[Math.min(n, answer.sequence.length - 1)];
  }
  if (answer.toolError) return { toolError: String(answer.toolError) };
  answer = withDownloadBase(answer);
  const headers = Object.assign({}, answer.headers || {});
  const out = { id, status: answer.status || 200, headers };
  if (answer.text !== undefined) {
    if (!Object.keys(headers).some((h) => h.toLowerCase() === 'content-type')) headers['Content-Type'] = 'text/plain';
    out.body = Buffer.from(String(answer.text), 'utf8').toString('base64');
  } else if (answer.body !== undefined) {
    if (!Object.keys(headers).some((h) => h.toLowerCase() === 'content-type')) headers['Content-Type'] = 'application/json';
    out.body = answer.body;
  }
  return out;
}

const text = (s, isError) => (isError ? { content: [{ type: 'text', text: s }], isError: true } : { content: [{ type: 'text', text: s }] });

function callTool(params) {
  const name = params && params.name;
  const a = (params && params.arguments) || {};
  if (authDead) {
    return text(JSON.stringify({ error: "Failed to acquire token for account '" + (a.account || 'unknown') +
      "'. InteractionRequiredAuthError: invalid_grant: AADSTS700082: The refresh token has expired. Please re-login with: --login" }), true);
  }
  if (name === 'list-accounts') {
    return text(JSON.stringify({ accounts: [{ email: 'selftest@example.com', name: 'Selftest User', isDefault: true }], count: 1 }));
  }
  if (name === 'graph-batch') {
    const requests = a.body && Array.isArray(a.body.requests) ? a.body.requests : null;
    if (!requests) return text(JSON.stringify({ error: 'Microsoft Graph API error: 400 Bad Request - body.requests is required' }), true);
    const responses = [];
    for (const r of requests) {
      const s = subResponse(r);
      if (s.toolError) return text(JSON.stringify({ error: 'Error in tool graph-batch: ' + s.toolError }), true);
      responses.push(s);
    }
    responses.reverse(); // Graph answers in arbitrary order: the engine must match by id
    return text(JSON.stringify({ responses }, null, 2));
  }
  return text(JSON.stringify({ error: 'fake server: unknown tool ' + name }), true);
}

const TOOLS = [
  { name: 'graph-batch', description: 'Combine up to 20 Graph requests (fake).', inputSchema: { type: 'object', properties: { body: { type: 'object' }, account: { type: 'string' } } } },
  { name: 'list-accounts', description: 'List the configured accounts (fake).', inputSchema: { type: 'object', properties: {} } },
];

function send(msg) { process.stdout.write(JSON.stringify(Object.assign({ jsonrpc: '2.0' }, msg)) + '\n'); }

function handle(msg) {
  if (!msg || typeof msg !== 'object' || msg.id === undefined || msg.id === null) return; // notifications
  const { id, method, params } = msg;
  if (method === 'initialize') {
    send({ id, result: { protocolVersion: (params && params.protocolVersion) || '2025-06-18', capabilities: { tools: {} },
      serverInfo: { name: 'microsoft365-archive-fake-server', version: '1' } } });
  } else if (method === 'tools/list') {
    send({ id, result: { tools: TOOLS } });
  } else if (method === 'tools/call') {
    send({ id, result: callTool(params) });
  } else if (method === 'ping') {
    send({ id, result: {} });
  } else {
    send({ id, error: { code: -32601, message: 'fake server: method not found: ' + method } });
  }
}

function listen() {
  let buf = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      let m;
      try { m = JSON.parse(line); } catch (e) { continue; }
      handle(m);
    }
  });
  process.stdin.on('end', () => process.exit(0));
}

if (downloads.size) {
  const server = http.createServer((req, res) => {
    const d = downloads.get(String(req.url).split('?')[0]);
    if (!d || req.method !== 'GET') { res.writeHead(404); res.end(); return; }
    if (req.headers.authorization) { res.writeHead(400); res.end('a pre-authenticated URL must not carry a bearer'); return; }
    const bytes = Buffer.from(String(d.text || ''), 'utf8');
    res.writeHead(200, { 'Content-Type': d.contentType || 'application/octet-stream', 'Content-Length': bytes.length });
    res.end(bytes);
  });
  server.listen(0, '127.0.0.1', () => {
    downloadBase = 'http://127.0.0.1:' + server.address().port;
    server.unref();
    listen();
  });
} else {
  listen();
}
