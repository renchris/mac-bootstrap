#!/usr/bin/env node
'use strict';
// archive.js — the Microsoft 365 archive engine: harvests the signed-in user's Teams meetings and
// Copilot material into one markdown folder, read-only, by driving the installed Softeria
// ms-365-mcp-server over stdio JSON-RPC. No npm dependency; node >= 18; CommonJS.
//
//   node archive.js --version                  prints "microsoft365-archive 1"
//   node archive.js --selftest                 offline: render + resolve fixtures, the GET-only guard,
//                                              and an end-to-end run against fake-server.js
//   node archive.js run [--since ISO] [--until ISO]    harvest meetings, then Copilot
//   node archive.js status                     one line per artifact class from the last run, on stdout:
//                                              "<class>\t<status>\t<detail>" (a status may hold spaces)
//   node archive.js copilot-import <file>      import a Copilot export (aiInteraction JSON or the
//                                              consumer CSV) into copilot/sessions/, resolving links
//   node archive.js explain                    what would unlock each refused class
// Options: --config <file> (key=value lines: root, account, node, server, tenant, client_id,
//   server_args, convert), --root, --account, --server. MICROSOFT365_ARCHIVE_CONFIG names the config
//   when --config is absent.
// Exit: 0 ok · 2 usage/config · 3 sign-in needed (prints the one --login command) · 4 partial (some
//   artifacts not harvested; the archive is still consistent) · 5 the server failed to start or answer.
//
// READ-ONLY BY CONSTRUCTION. A launchd job never passes the agents' PreToolUse guard, so this engine
// enforces its own before every tools/call (guardToolCall): only graph-batch and list-accounts; every
// batch sub-request a GET on a relative Graph path with no '://', '..', '%2e', '#' or whitespace, and
// never /special/ (a GET there CREATES folders — measured); nextLinks only from graph.microsoft.com/v1.0;
// never Prefer: redeemSharingLink (that grants access — a write). Pre-authenticated download URLs are
// fetched with plain https and no Authorization header, capped at 50 MB.
//
// IDEMPOTENT. Every archive file is written through a byte compare: same bytes, no write. Nothing
// volatile (run times, counts) lands in the archive; that lives in <root>/.state/. A changed artifact
// keeps its previous bytes in <folder>/history/<name>.<first 12 hex of sha256(old)>.

const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const http = require('http');
const https = require('https');
const { spawn, spawnSync } = require('child_process');
const render = require('./render.js');
const resolve = require('./resolve.js');

const VERSION_LINE = 'microsoft365-archive 1';
const SCHEMA = 'microsoft365-archive/1';
const GRAPH_V1 = 'https://graph.microsoft.com/v1.0/';
const EXIT = { ok: 0, usage: 2, authDead: 3, partial: 4, serverFailed: 5 };
const EXIT_NAMES = { 0: 'ok', 2: 'usage', 3: 'sign-in-needed', 4: 'partial', 5: 'server-failed' };
const ARTIFACTS = ['transcript', 'recording', 'attendance', 'ai_notes', 'chat', 'loop_notes'];
const ARTIFACT_LABELS = { transcript: 'Transcript', recording: 'Recording', attendance: 'Attendance', ai_notes: 'AI notes', chat: 'Chat', loop_notes: 'Loop notes' };
const STATUS_CLASSES = ['meetings'].concat(ARTIFACTS, ['copilot_history', 'copilot_files']);
const MEETING_KEYS = ['schema', 'ical_uid', 'event_id', 'subject', 'start', 'end', 'organizer', 'attendees', 'join_url', 'online_meeting_id', 'artifacts'];
const EVENT_SELECT = 'id,iCalUId,subject,start,end,organizer,attendees,isOnlineMeeting,onlineMeeting,onlineMeetingProvider,seriesMasterId,type,webLink,isCancelled';
const DOWNLOAD_CAP = 50 * 1024 * 1024;
const CHAT_CAP = 2000;
const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const WINDOW_BEFORE = 15 * MINUTE;   // an artifact belongs to an occurrence created in [start-15m, end+4h]
const WINDOW_AFTER = 4 * HOUR;
const APP_ONLY = 'forbidden:app-only — needs an app registration with AiEnterpriseInteraction.Read.All and a Microsoft 365 Copilot licence';
const DRIVE_FOLDERS = ['Meetings', 'Recordings', 'Whiteboards'];
const COPILOT_FILES_FOLDER = 'Microsoft Copilot Chat Files';
const RUN_BUDGET_MS = 50 * MINUTE;
// Every artifact read through /me/onlineMeetings/{id} (ai_notes through /copilot/users/{me}/onlineMeetings).
const ONLINE_MEETING_ARTIFACTS = ['transcript', 'recording', 'attendance', 'ai_notes', 'chat'];
// MSAL's home tenant for every personal (consumer) Microsoft account.
const PERSONAL_TENANT = '9188040d-6c67-4c5b-b112-36a304b66dad';
const PERSONAL_ACCOUNT = 'personal-account';
const EXTERNAL_ORGANIZER = 'external-organizer'; // recorded as external-organizer:<organizer tenant id>
const GUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// What would unlock each refused class — the asks of SYNTHESIS §5, one per status family.
const UNLOCK = {
  meetings: { forbidden: 'Consent Calendars.Read for the account (it is in the default sign-in; re-run the sign-in).' },
  transcript: {
    forbidden: 'Admin-consent the delegated scope OnlineMeetingTranscript.Read.All for the server\'s app and run the server with --org-mode.',
    'tenant-disabled': 'As Teams admin: Set-CsTeamsMeetingConfiguration -Identity Global -EnableGraphTranscriptAccess $true -EnableAttributedTranscripts $true',
  },
  recording: { forbidden: 'Admin-consent the delegated scope OnlineMeetingRecording.Read.All and run the server with --org-mode (your own OneDrive /Recordings folder is already linked).' },
  attendance: { forbidden: 'Consent OnlineMeetingArtifact.Read.All (user-consentable) by signing in with --org-mode; reports exist only for meetings you organised.' },
  ai_notes: {
    forbidden: 'Consent OnlineMeetingAiInsight.Read.All through your own app registration (--extra-scopes); it needs admin consent.',
    'license-required': 'Assign a Microsoft 365 Copilot licence to the signed-in user; AI notes exist only for licensed users.',
  },
  chat: { forbidden: 'Consent Chat.Read (the Microsoft-managed consent policy reserves it for an admin) and run the server with --org-mode.' },
  loop_notes: { forbidden: 'Consent Files.Read.All to read notes in other people\'s drives; your own OneDrive needs nothing more.' },
  copilot_history: {
    forbidden: 'A single-tenant app registration with the application permission AiEnterpriseInteraction.Read.All, admin consent and a certificate, plus a Microsoft 365 Copilot seat — or a Purview eDiscovery export (add yourself to eDiscovery Manager).',
    'personal-account': 'The Copilot interaction history API serves work or school accounts only; sign in with one that holds a Microsoft 365 Copilot licence.',
  },
  copilot_files: { forbidden: 'Files.ReadWrite on your own OneDrive is in the default sign-in; re-run the sign-in.' },
};
// Asks that hold for every class a status family reaches; a class's own entry above wins.
const UNLOCK_ANY = {
  'external-organizer': 'These live in the organizer\'s tenant. Ask the organizer to share the recording and transcript with you (they land in your OneDrive/Teams chat, which this archive then links), or sign in with an account in that tenant.',
  'personal-account': 'Teams meeting recordings, transcripts, attendance and AI notes are not available to personal Microsoft accounts through Graph; sign in with a work or school account.',
};
// The status families "What would unlock more" and explain speak to.
const REFUSED_FAMILIES = ['forbidden', 'tenant-disabled', 'license-required', 'external-organizer', 'personal-account'];
function statusFamily(st) {
  const s = String(st == null ? '' : st);
  return /^forbidden/.test(s) ? 'forbidden' : /^external-organizer(:|$)/.test(s) ? 'external-organizer' : s;
}
function unlockAsk(cls, fam) { return (UNLOCK[cls] && UNLOCK[cls][fam]) || UNLOCK_ANY[fam] || null; }

// ── errors ────────────────────────────────────────────────────────────────────────────────────────
class ArchiveError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}
const guardError = (m) => new ArchiveError('GUARD', 'GET-only guard: ' + m);
const AUTH_PATTERN = /InteractionRequired|invalid_grant|not logged in|login first|re-login|--login|No valid token|Silent token acquisition failed|Failed to acquire token|No accounts found|Account '[^']*' not found|AADSTS\d+/i;
// What clears a sign-in Microsoft refused, by the AADSTS code it answered with — the meanings of
// Microsoft's Entra error reference and Conditional Access pages, and the same ones the microsoft365
// module's note prints. Two cannot be cleared by any sign-in on a Mac: token protection admits only
// clients that sign in through Microsoft's identity broker, and this server is MSAL Node on its own.
const SIGNIN_ADVICE = {
  AADSTS65001: 'your tenant lets only an administrator approve this app\'s mail and calendar access; ask IT to grant admin consent, or to register their own app.',
  AADSTS90094: 'your tenant lets only an administrator approve this app\'s mail and calendar access; ask IT to grant admin consent, or to register their own app.',
  AADSTS90095: 'your tenant lets only an administrator approve this app\'s mail and calendar access; ask IT to grant admin consent, or to register their own app.',
  AADSTS53000: 'your organization lets only compliant or managed devices sign in; ask IT to enrol this Mac (Company Portal), then sign in again.',
  AADSTS53001: 'your organization lets only compliant or managed devices sign in; ask IT to enrol this Mac (Company Portal), then sign in again.',
  AADSTS53003: 'a Conditional Access policy blocks it; if it is the code sign-in it blocks, sign in again with --auth-browser, otherwise ask IT which policy applies.',
  AADSTS530036: 'Conditional Access blocks the device-code sign-in, and the token that sign-in left can never be used again; sign in again in the browser (--auth-browser).',
  AADSTS530084: 'your organization requires token protection, which only apps signing in through Microsoft\'s identity broker (Company Portal) can meet; this server cannot meet it on any Mac, so ask IT to exempt it, or do without the archive.',
  AADSTS7000112: 'the app the server signs in through is disabled, in your tenant or by its publisher; ask IT to enable it, or to register their own app.',
  AADSTS50105: 'IT has not assigned you to this app; ask them to.',
};
function signInCode(msg) { const m = /AADSTS\d+/.exec(String(msg || '')); return m ? m[0] : null; }
function signInAdvice(msg) {
  const code = signInCode(msg);
  return code ? 'Microsoft refused the sign-in (' + code + '): ' + (SIGNIN_ADVICE[code] || 'sign in again.') : null;
}

// ── small helpers ─────────────────────────────────────────────────────────────────────────────────
const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');
const shortHash = (buf) => sha256(buf).slice(0, 12);
const ok = (res) => !!res && res.status >= 200 && res.status < 300;
const oneLine = (s) => String(s == null ? '' : s).replace(/\s+/g, ' ').trim();
const cell = (s) => oneLine(s).replace(/\|/g, '\\|');
const seg = (id) => encodeURIComponent(String(id == null ? '' : id));
const mdLink = (u) => String(u).replace(/ /g, '%20').replace(/\(/g, '%28').replace(/\)/g, '%29');

function parseTime(value) {
  if (value == null || value === '') return NaN;
  let s = String(value).trim().replace(/(\.\d{3})\d+/, '$1');
  if (/^\d{4}-\d\d-\d\dT\d\d:\d\d(:\d\d(\.\d+)?)?$/.test(s)) s += 'Z';
  return Date.parse(s);
}
function isoUtc(t) { return new Date(t).toISOString().replace(/\.000Z$/, 'Z'); }
function graphDateTime(dt) {
  if (!dt || !dt.dateTime) return NaN;
  const zone = String(dt.timeZone || 'UTC');
  let s = String(dt.dateTime).replace(/(\.\d{3})\d+/, '$1');
  if (!/[zZ]$|[+-]\d\d:?\d\d$/.test(s) && /^(UTC|Etc\/UTC|GMT|Coordinated Universal Time)$/i.test(zone)) s += 'Z';
  else if (!/[zZ]$|[+-]\d\d:?\d\d$/.test(s)) s += 'Z'; // Prefer: outlook.timezone="UTC" was ignored: best effort
  return Date.parse(s);
}
function mkdirp(d) { fs.mkdirSync(d, { recursive: true }); }
function readText(f) { try { return fs.readFileSync(f, 'utf8'); } catch (e) { return null; } }
function readJson(f) { const t = readText(f); if (t === null) return null; try { return JSON.parse(t); } catch (e) { return null; } }
function shellQuote(s) { return /^[A-Za-z0-9_@%+=:,./-]+$/.test(s) ? s : "'" + String(s).replace(/'/g, "'\\''") + "'"; }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── the GET-only guard ────────────────────────────────────────────────────────────────────────────
// decodedGraphPath — the path part (before '?') as a server would read it: every %XX escape decoded,
// again and again until nothing changes, because one decode of '/spec%2569al' is still an escape and
// a second one is '/special'. Escapes are decoded one by one, so a stray '%' never stops the rest from
// being decoded. null when the raw path holds a malformed escape or is still changing after 8 rounds.
function decodedGraphPath(url) {
  let p = String(url).split('?')[0];
  if (/%(?![0-9A-Fa-f]{2})/.test(p)) return null;
  for (let round = 0; round < 8; round++) {
    const next = p.replace(/%([0-9A-Fa-f]{2})/g, (m, hex) => String.fromCharCode(parseInt(hex, 16)));
    if (next === p) return p;
    p = next;
  }
  return null;
}
function unsafeGraphPath(url) {
  if (typeof url !== 'string' || !url) return 'the url is not a string';
  if (url[0] !== '/') return 'the url must be a relative Graph path starting with /';
  if (url.indexOf('://') >= 0) return 'the url contains ://';
  if (url.indexOf('..') >= 0) return 'the url contains ..';
  if (/%2e/i.test(url)) return 'the url contains %2e';
  if (url.indexOf('#') >= 0) return 'the url contains #';
  if (/\s/.test(url)) return 'the url contains whitespace';
  if (url.indexOf('\\') >= 0) return 'the url contains a backslash';
  // The same rules again on the path Graph will actually route: an encoded letter ('spec%69al'), an
  // encoded slash ('drive%2Fspecial') or a double encoding must not reach /special/ either.
  const decoded = decodedGraphPath(url);
  if (decoded === null) return 'the url path holds a malformed or runaway percent escape';
  if (decoded.indexOf('..') >= 0) return 'the decoded url path contains ..';
  if (decoded.indexOf('\\') >= 0) return 'the decoded url path contains a backslash';
  if (/\/special(\/|$|:|\?|;)/i.test(url.split('?')[0]) || /\/special(\/|$|:|\?|;)/i.test(decoded)) return 'a /special/ path is refused: a GET there creates folders';
  return null;
}
const ALLOWED_TOOLS = { 'graph-batch': ['body', 'account'], 'list-accounts': ['account'] };
const ALLOWED_HEADERS = ['prefer', 'accept', 'consistencylevel', 'if-none-match'];

function guardToolCall(name, args) {
  if (!Object.prototype.hasOwnProperty.call(ALLOWED_TOOLS, name)) throw guardError('tool ' + JSON.stringify(name) + ' is not allowed');
  if (!args || typeof args !== 'object' || Array.isArray(args)) throw guardError('arguments must be an object');
  for (const k of Object.keys(args)) if (ALLOWED_TOOLS[name].indexOf(k) < 0) throw guardError('argument ' + JSON.stringify(k) + ' is not allowed for ' + name);
  if (name !== 'graph-batch') return;
  const body = args.body;
  const requests = body && typeof body === 'object' && Array.isArray(body.requests) ? body.requests : null;
  if (!requests || !requests.length || requests.length > 20) throw guardError('graph-batch needs 1 to 20 requests');
  if (Object.keys(body).some((k) => k !== 'requests')) throw guardError('graph-batch body may carry only requests');
  for (const r of requests) {
    if (!r || typeof r !== 'object') throw guardError('a sub-request is not an object');
    for (const k of Object.keys(r)) if (['id', 'method', 'url', 'headers'].indexOf(k) < 0) throw guardError('sub-request field ' + JSON.stringify(k) + ' is not allowed');
    if (r.method !== 'GET') throw guardError('sub-request method ' + JSON.stringify(r.method) + ' is not GET');
    const why = unsafeGraphPath(r.url);
    if (why) throw guardError(why + ': ' + JSON.stringify(r.url));
    if (r.headers !== undefined) {
      if (!r.headers || typeof r.headers !== 'object') throw guardError('sub-request headers must be an object');
      for (const [h, v] of Object.entries(r.headers)) {
        if (ALLOWED_HEADERS.indexOf(h.toLowerCase()) < 0) throw guardError('header ' + h + ' is not allowed');
        if (typeof v !== 'string') throw guardError('header ' + h + ' must be a string');
        if (/redeemsharinglink/i.test(v)) throw guardError('Prefer: redeemSharingLink grants access — a write');
      }
    }
  }
}

function relativeFromLink(link) {
  if (typeof link !== 'string' || !link.startsWith(GRAPH_V1)) throw guardError('a nextLink outside ' + GRAPH_V1 + ' is refused: ' + JSON.stringify(String(link).slice(0, 120)));
  const rel = link.slice(GRAPH_V1.length - 1);
  const why = unsafeGraphPath(rel);
  if (why) throw guardError(why + ' (in a nextLink)');
  return rel;
}

// ── configuration ─────────────────────────────────────────────────────────────────────────────────
const CONFIG_KEYS = ['root', 'account', 'node', 'server', 'tenant', 'client_id', 'server_args', 'convert'];

function expandHome(v) {
  if (v === '~') return os.homedir();
  if (v.startsWith('~/')) return path.join(os.homedir(), v.slice(2));
  if (v === '$HOME' || v.startsWith('$HOME/')) return path.join(os.homedir(), v.slice(6));
  return v;
}

function loadConfig(flags) {
  const cfg = {};
  const file = flags.config || process.env.MICROSOFT365_ARCHIVE_CONFIG || '';
  if (file) {
    const text = readText(file);
    if (text === null) throw new ArchiveError('USAGE', 'cannot read the config file ' + file);
    text.split(/\r?\n/).forEach((line, i) => {
      if (!line.trim() || /^\s*#/.test(line)) return;
      const eq = line.indexOf('=');
      if (eq < 1) throw new ArchiveError('USAGE', file + ':' + (i + 1) + ': not a key=value line');
      const k = line.slice(0, eq).trim();
      if (CONFIG_KEYS.indexOf(k) < 0) throw new ArchiveError('USAGE', file + ':' + (i + 1) + ': unknown key ' + k + ' (known: ' + CONFIG_KEYS.join(', ') + ')');
      cfg[k] = line.slice(eq + 1).trim();
    });
  }
  for (const k of ['root', 'account', 'server']) if (flags[k] !== undefined) cfg[k] = flags[k];
  for (const k of ['root', 'node', 'server', 'convert']) if (cfg[k]) cfg[k] = expandHome(cfg[k]);
  if (!cfg.node) cfg.node = process.execPath;
  cfg.serverArgs = cfg.server_args ? cfg.server_args.split(/\s+/).filter(Boolean) : [];
  return cfg;
}

function requireKeys(cfg, keys) {
  const missing = keys.filter((k) => !cfg[k]);
  if (missing.length) throw new ArchiveError('USAGE', 'missing config key(s): ' + missing.join(', ') + ' — pass --config <file> or set MICROSOFT365_ARCHIVE_CONFIG');
}

// A client's data must never be re-uploaded by a sync client: refuse a root inside one. The deepest
// existing ancestor is resolved with realpathSync.NATIVE, which (unlike the JS realpath) also folds
// the letter case to the one on disk, and the not-yet-existing tail is put back; the comparison is
// then made case-insensitively, because macOS volumes are case-insensitive by default and
// '~/library/cloudstorage/…' IS the synced folder. On a case-sensitive volume this only refuses more.
function cloudRootOf(root) {
  let p = path.resolve(root);
  let tail = '';
  while (!fs.existsSync(p) && path.dirname(p) !== p) { tail = path.sep + path.basename(p) + tail; p = path.dirname(p); }
  let real;
  try { real = fs.realpathSync.native(p); } catch (e) { real = p; }
  real = (real === path.sep ? '' : real) + tail;
  const fold = (s) => s.toLowerCase();
  for (const c of [path.join(os.homedir(), 'Library', 'CloudStorage'), path.join(os.homedir(), 'Library', 'Mobile Documents')]) {
    let rc = c;
    try { rc = fs.realpathSync.native(c); } catch (e) { /* absent */ }
    for (const candidate of [rc, c]) {
      if (fold(real) === fold(candidate) || fold(real).startsWith(fold(candidate) + path.sep)) return c;
    }
  }
  return null;
}

// A token IT's policy killed for being a device-code sign-in is replaced only by another flow.
function loginCommand(cfg, why) {
  const env = [];
  if (cfg.tenant) env.push('MS365_MCP_TENANT_ID=' + shellQuote(cfg.tenant));
  if (cfg.client_id) env.push('MS365_MCP_CLIENT_ID=' + shellQuote(cfg.client_id));
  const flow = signInCode(why) === 'AADSTS530036' ? ['--login', '--auth-browser'] : ['--login'];
  return env.concat([shellQuote(cfg.node), shellQuote(cfg.server || '<server>')], flow).join(' ');
}

// ── the MCP client ────────────────────────────────────────────────────────────────────────────────
function serverEnv(cfg, logDir) {
  const env = Object.assign({}, process.env);
  delete env.MS365_MCP_OUTPUT_FORMAT;    // TOON output would not parse as JSON
  delete env.MS365_MCP_REQUIRE_CONFIRM;  // the confirm gate would refuse graph-batch; our own guard keeps it read-only
  if (cfg.tenant) env.MS365_MCP_TENANT_ID = cfg.tenant;
  if (cfg.client_id) env.MS365_MCP_CLIENT_ID = cfg.client_id;
  env.MS365_MCP_LOG_DIR = logDir;
  return env;
}

class McpClient {
  constructor(cfg) {
    this.cfg = cfg;
    this.nextId = 1;
    this.pending = new Map();
    this.stderrTail = '';
    this.child = null;
    this.dead = null;
    this.logDir = null;
  }

  async start() {
    const cfg = this.cfg;
    if (!fs.existsSync(cfg.server)) throw new ArchiveError('SERVER_FAILED', 'the server entry does not exist: ' + cfg.server);
    this.logDir = fs.mkdtempSync(path.join(os.tmpdir(), 'microsoft365-archive-server-log-'));
    const child = spawn(cfg.node, [cfg.server].concat(cfg.serverArgs), { stdio: ['pipe', 'pipe', 'pipe'], env: serverEnv(cfg, this.logDir) });
    this.child = child;
    const fail = (why) => {
      if (!this.dead) this.dead = why;
      for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(new ArchiveError('SERVER_FAILED', why)); }
      this.pending.clear();
    };
    child.on('error', (e) => fail('the server could not be started: ' + e.message));
    child.on('exit', (code, signal) => fail('the server exited (' + (signal || 'code ' + code) + ')' + (this.stderrTail ? ': ' + oneLine(this.stderrTail).slice(-300) : '')));
    child.stdin.on('error', () => { /* reported by exit */ });
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (d) => { this.stderrTail = (this.stderrTail + d).slice(-4000); });
    let buf = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (d) => {
      buf += d;
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i);
        buf = buf.slice(i + 1);
        let m;
        try { m = JSON.parse(line); } catch (e) { continue; }
        this.onMessage(m);
      }
    });
    await this.request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'microsoft365-archive', version: '1' } }, 30000);
    this.notify('notifications/initialized', {});
    const listed = await this.request('tools/list', {}, 30000);
    const names = (listed && Array.isArray(listed.tools) ? listed.tools : []).map((t) => t && t.name);
    if (names.indexOf('graph-batch') < 0) {
      throw new ArchiveError('SERVER_FAILED', 'the server exposes no graph-batch tool (is it started with --read-only?); the archive reads through graph-batch and guards it to GET itself');
    }
  }

  onMessage(m) {
    if (m && m.id !== undefined && m.id !== null && m.method) { // a request from the server: we offer nothing
      this.send({ id: m.id, error: { code: -32601, message: 'the archive client offers no methods' } });
      return;
    }
    if (!m || m.id === undefined || !this.pending.has(m.id)) return;
    const p = this.pending.get(m.id);
    this.pending.delete(m.id);
    clearTimeout(p.timer);
    if (m.error) p.reject(new ArchiveError('TRANSPORT', 'JSON-RPC error ' + m.error.code + ': ' + m.error.message));
    else p.resolve(m.result);
  }

  send(msg) {
    if (this.dead || !this.child) return;
    try { this.child.stdin.write(JSON.stringify(Object.assign({ jsonrpc: '2.0' }, msg)) + '\n'); } catch (e) { /* exit reports it */ }
  }
  notify(method, params) { this.send({ method, params }); }

  request(method, params, timeoutMs) {
    if (this.dead) return Promise.reject(new ArchiveError('SERVER_FAILED', this.dead));
    const id = this.nextId++;
    return new Promise((fulfil, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new ArchiveError(method === 'tools/call' ? 'TRANSPORT' : 'SERVER_FAILED', 'the server did not answer ' + method + ' within ' + Math.round(timeoutMs / 1000) + ' s'));
      }, timeoutMs);
      this.pending.set(id, { resolve: fulfil, reject: reject, timer });
      this.send({ id, method, params });
    });
  }

  async callTool(name, args) {
    guardToolCall(name, args); // before anything leaves this process
    const result = await this.request('tools/call', { name, arguments: args }, 300000);
    return parseToolResult(result);
  }

  close() {
    if (this.child && !this.dead) {
      try { this.child.stdin.end(); } catch (e) { /* already gone */ }
      const c = this.child;
      setTimeout(() => { try { c.kill(); } catch (e) { /* gone */ } }, 1500).unref();
    }
    if (this.logDir) { try { fs.rmSync(this.logDir, { recursive: true, force: true }); } catch (e) { /* temp */ } }
  }
}

function parseToolResult(result) {
  const text = (result && Array.isArray(result.content) ? result.content : []).filter((c) => c && c.type === 'text').map((c) => c.text).join('');
  let data;
  try { data = JSON.parse(text); } catch (e) { data = undefined; }
  const errorText = data && typeof data === 'object' && data.error !== undefined && !data.responses
    ? (typeof data.error === 'string' ? data.error : JSON.stringify(data.error)) : null;
  if ((result && result.isError) || errorText) {
    const msg = errorText || text || 'the tool reported an error with no message';
    if (AUTH_PATTERN.test(msg)) throw new ArchiveError('AUTH_DEAD', oneLine(msg).slice(0, 400));
    throw new ArchiveError('TRANSPORT', oneLine(msg).slice(0, 400));
  }
  if (data === undefined) throw new ArchiveError('TRANSPORT', 'the tool answered something that is not JSON: ' + oneLine(text).slice(0, 200));
  return data;
}

// ── Graph, through graph-batch ────────────────────────────────────────────────────────────────────
function decodeSubResponse(r) {
  const headers = {};
  for (const [k, v] of Object.entries((r && r.headers) || {})) headers[k.toLowerCase()] = v;
  const ct = String(headers['content-type'] || '');
  let body = r ? r.body : undefined;
  let bytes = null;
  if (typeof body === 'string') {
    // Graph's batch rule: a body that is not JSON comes back base64.
    if (/json/i.test(ct)) { bytes = Buffer.from(body, 'utf8'); try { body = JSON.parse(body); } catch (e) { /* stays text */ } }
    else if (ct || (/^[A-Za-z0-9+/=\s]*$/.test(body) && body.replace(/\s/g, '').length % 4 === 0)) { bytes = Buffer.from(body, 'base64'); body = bytes.toString('utf8'); }
    else bytes = Buffer.from(body, 'utf8');
  } else if (body !== undefined && body !== null) {
    bytes = Buffer.from(JSON.stringify(body), 'utf8');
  }
  return { status: Number(r && r.status) || 0, headers, body: body === undefined ? null : body, bytes };
}

class Graph {
  constructor(client, account, log) { this.client = client; this.account = account; this.log = log || (() => {}); }

  async sendBatch(reqs) {
    const body = { requests: reqs.map((r, i) => {
      const o = { id: String(i + 1), method: 'GET', url: r.url };
      if (r.headers && Object.keys(r.headers).length) o.headers = r.headers;
      return o;
    }) };
    const args = { body };
    if (this.account) args.account = this.account;
    const data = await this.client.callTool('graph-batch', args);
    const responses = data && Array.isArray(data.responses) ? data.responses : null;
    if (!responses) throw new ArchiveError('TRANSPORT', 'graph-batch answered without a responses array');
    const byId = new Map(responses.map((x) => [String(x && x.id), x]));
    return reqs.map((r, i) => {
      const x = byId.get(String(i + 1));
      if (!x) throw new ArchiveError('TRANSPORT', 'graph-batch answered no response for ' + r.url);
      return decodeSubResponse(x);
    });
  }

  // getMany — GETs in batches of 20, in order. 429/503 honour Retry-After, three tries in all.
  async getMany(reqs) {
    const out = new Array(reqs.length);
    for (let start = 0; start < reqs.length; start += 20) {
      let idx = [];
      for (let i = start; i < Math.min(reqs.length, start + 20); i++) idx.push(i);
      for (let attempt = 1; idx.length; attempt++) {
        const answers = await this.sendBatch(idx.map((i) => reqs[i]));
        const again = [];
        let wait = 0;
        answers.forEach((a, j) => {
          out[idx[j]] = a;
          if ((a.status === 429 || a.status === 503) && attempt < 3) {
            again.push(idx[j]);
            const ra = Number(a.headers['retry-after']);
            wait = Math.max(wait, Number.isFinite(ra) && ra >= 0 ? ra * 1000 : attempt * 2000);
          }
        });
        if (!again.length) break;
        this.log('throttled (' + again.length + ' request(s)); retrying in ' + Math.round(wait / 1000) + ' s');
        await sleep(Math.min(wait, 120000));
        idx = again;
      }
    }
    return out;
  }

  async get(url, headers) { return (await this.getMany([{ url, headers: headers || {} }]))[0]; }

  // pages — the first page is already in hand; follow nextLinks (guarded) up to cap items.
  async pages(first, headers, cap) {
    if (!ok(first)) return { res: first, items: [] };
    let items = [];
    let res = first;
    for (let page = 1; ; page++) {
      const v = res.body && Array.isArray(res.body.value) ? res.body.value : [];
      items = items.concat(v);
      const next = res.body && res.body['@odata.nextLink'];
      if (!next || items.length >= cap || page >= 200) break;
      res = await this.get(relativeFromLink(next), headers);
      if (!ok(res)) throw new ArchiveError('TRANSPORT', 'a later page answered HTTP ' + res.status);
    }
    return { res: first, items: items.slice(0, cap) };
  }

  async getAll(url, headers, cap) { return this.pages(await this.get(url, headers), headers, cap || 5000); }

  // graphGet for resolve.js: {status, headers, body}.
  graphGet() { return (rel, headers) => this.get(rel, headers || {}); }
}

// A pre-authenticated download URL (a 302 Location or @microsoft.graph.downloadUrl): plain https, no
// Authorization header — a Graph bearer never leaves for another host — and a 50 MB ceiling.
function isPrivateHost(host) {
  const h = host.replace(/^\[|\]$/g, '').toLowerCase();
  return h === 'localhost' || /^127\./.test(h) || /^10\./.test(h) || /^192\.168\./.test(h) || /^172\.(1[6-9]|2\d|3[01])\./.test(h) ||
    /^169\.254\./.test(h) || /^0\./.test(h) || h === '::1' || /^f[cd]/.test(h) || /^fe80:/.test(h);
}
function fetchPreauthenticated(url, redirects) {
  return new Promise((fulfil, reject) => {
    let u;
    try { u = new URL(url); } catch (e) { reject(new ArchiveError('TRANSPORT', 'not a URL: ' + String(url).slice(0, 100))); return; }
    const loopbackAllowed = process.env.MICROSOFT365_ARCHIVE_ALLOW_LOOPBACK_DOWNLOADS === '1' && u.hostname === '127.0.0.1';
    if (u.protocol === 'https:' ? isPrivateHost(u.hostname) : !(u.protocol === 'http:' && loopbackAllowed)) {
      reject(new ArchiveError('TRANSPORT', 'refused download URL ' + u.protocol + '//' + u.hostname + ' (https to a public host only)'));
      return;
    }
    const lib = u.protocol === 'https:' ? https : http;
    const req = lib.get(u, { headers: { 'User-Agent': 'microsoft365-archive/1' } }, (res) => {
      if ([301, 302, 303, 307, 308].indexOf(res.statusCode) >= 0 && res.headers.location) {
        res.resume();
        if ((redirects || 0) >= 3) { reject(new ArchiveError('TRANSPORT', 'too many redirects')); return; }
        fetchPreauthenticated(new URL(res.headers.location, u).href, (redirects || 0) + 1).then(fulfil, reject);
        return;
      }
      if (res.statusCode !== 200) { res.resume(); reject(new ArchiveError('TRANSPORT', 'download answered HTTP ' + res.statusCode)); return; }
      if (Number(res.headers['content-length']) > DOWNLOAD_CAP) { res.destroy(); reject(new ArchiveError('TRANSPORT', 'download larger than 50 MB')); return; }
      const chunks = [];
      let size = 0;
      res.on('data', (d) => {
        size += d.length;
        if (size > DOWNLOAD_CAP) { res.destroy(); reject(new ArchiveError('TRANSPORT', 'download larger than 50 MB')); return; }
        chunks.push(d);
      });
      res.on('end', () => fulfil(Buffer.concat(chunks)));
      res.on('error', (e) => reject(new ArchiveError('TRANSPORT', 'download failed: ' + e.message)));
    });
    req.setTimeout(120000, () => req.destroy(new Error('timed out')));
    req.on('error', (e) => reject(new ArchiveError('TRANSPORT', 'download failed: ' + e.message)));
  });
}

// bytesOf — the content of a Graph content response: the body itself, or a 302 followed without auth.
async function bytesOf(res) {
  if (res.status === 302 || res.status === 303 || res.status === 307) {
    const loc = res.headers.location;
    if (!loc) throw new ArchiveError('TRANSPORT', 'a redirect without a Location');
    return fetchPreauthenticated(loc, 0);
  }
  return res.bytes || Buffer.alloc(0);
}

// ── status derivation (status-as-data: a refusal is recorded, never a failure) ────────────────────
function errorParts(res) {
  const b = res && res.body;
  const e = b && typeof b === 'object' && b.error ? b.error : null;
  if (!e) return { code: '', inner: '', message: typeof b === 'string' ? b.slice(0, 300) : '' };
  const inner = e.innerError || e.innererror || {};
  return { code: String(e.code || ''), inner: String(inner.code || ''), message: String(e.message || '') };
}

// errorDetail — the whole Graph refusal on one line, kept in .state/status.json beside an error:<status>
// (the status alone says nothing about why).
function errorDetail(res) {
  const e = errorParts(res);
  return oneLine('HTTP ' + (res ? res.status : 0) + (e.code ? ' ' + e.code + (e.inner ? '/' + e.inner : '') : '') + (e.message ? ': ' + e.message : '')).slice(0, 2000);
}

function scopeHints(message) {
  let m = String(message || '');
  const req = /requires? (?:one of )?'([^']*)'/i.exec(m);
  if (req) m = req[1];
  else m = m.split(/Scopes on the request/i)[0];
  const out = [];
  const re = /\b[A-Z][A-Za-z]+(?:\.(?:Read|ReadBasic|ReadWrite|Write|Send|Selected|Manage|All|Shared|Chat|Everyone))+\b/g;
  let x;
  while ((x = re.exec(m)) !== null) if (out.indexOf(x[0]) < 0 && out.length < 4) out.push(x[0]);
  return out;
}

function deriveStatus(res, artifact) {
  const s = res ? res.status : 0;
  if (s >= 200 && s < 300) return 'available';
  const e = errorParts(res);
  const all = e.code + ' ' + e.inner + ' ' + e.message;
  if (artifact === 'copilot_history' && (s === 412 || s === 403)) return APP_ONLY;
  if (/GraphAccessToTranscriptsDisabled|SpeakerAttributionNotAllowed|transcripts? (?:api )?(?:access )?(?:is|are) (?:disabled|not enabled|turned off)|access to transcripts is disabled/i.test(all)) return 'tenant-disabled';
  if ((s === 403 || s === 404) && /licen[cs]e/i.test(all)) return 'license-required';
  if (s === 403) {
    if (/organi[sz]er/i.test(e.message)) return 'not-organizer';
    const scopes = scopeHints(e.message);
    if (scopes.length) return 'forbidden:needs ' + scopes.join(' or ');
    return 'forbidden:' + (e.code ? e.code + (e.inner ? '/' + e.inner : '') : '403');
  }
  if ((s === 404 || s === 410) && /expir/i.test(all)) return 'expired';
  return 'error:' + s;
}

// ── the writer: byte compare, temp + rename, history of what a change replaced ────────────────────
class Writer {
  constructor(root) { this.root = root; this.written = 0; this.unchanged = 0; }
  write(rel, data, keepHistory) {
    const abs = path.join(this.root, rel);
    const buf = Buffer.isBuffer(data) ? data : Buffer.from(String(data), 'utf8');
    let old = null;
    try { old = fs.readFileSync(abs); } catch (e) { old = null; }
    if (old && old.equals(buf)) { this.unchanged++; return false; }
    const dir = path.dirname(abs);
    mkdirp(dir);
    if (old && keepHistory) {
      const h = path.join(dir, 'history', path.basename(abs) + '.' + shortHash(old));
      if (!fs.existsSync(h)) { mkdirp(path.dirname(h)); atomicWrite(h, old); }
    }
    atomicWrite(abs, buf);
    this.written++;
    return true;
  }
}
function atomicWrite(abs, buf) {
  const tmp = path.join(path.dirname(abs), '.' + path.basename(abs) + '.tmp-' + process.pid);
  fs.writeFileSync(tmp, buf);
  fs.renameSync(tmp, abs);
}

// ── front matter, read back ───────────────────────────────────────────────────────────────────────
function yamlValue(s) {
  const v = s.trim();
  if (v === 'null' || v === '~' || v === '') return null;
  if (v === '[]') return [];
  if (v === '{}') return {};
  if (v === 'true') return true;
  if (v === 'false') return false;
  if (v[0] === '"') { try { return JSON.parse(v); } catch (e) { return v; } }
  if (/^-?\d+(\.\d+)?$/.test(v)) return Number(v);
  return v;
}
function parseFrontMatter(text) {
  if (typeof text !== 'string' || !text.startsWith('---\n')) return null;
  const end = text.indexOf('\n---\n', 3);
  if (end < 0) return null;
  const out = {};
  let cur = null;
  for (const line of text.slice(4, end).split('\n')) {
    let m;
    if ((m = /^([^\s:"][^:]*):(?: (.*))?$/.exec(line))) {
      const k = m[1];
      if (m[2] === undefined || m[2] === '') { out[k] = null; cur = k; } else { out[k] = yamlValue(m[2]); cur = null; }
    } else if ((m = /^"((?:[^"\\]|\\.)*)":(?: (.*))?$/.exec(line))) {
      const k = JSON.parse('"' + m[1] + '"');
      if (m[2] === undefined || m[2] === '') { out[k] = null; cur = k; } else { out[k] = yamlValue(m[2]); cur = null; }
    } else if (cur && (m = /^ {2}- (.*)$/.exec(line))) {
      if (!Array.isArray(out[cur])) out[cur] = [];
      out[cur].push(yamlValue(m[1]));
    } else if (cur && (m = /^ {2}([^\s:"][^:]*): (.*)$/.exec(line))) {
      if (!out[cur] || typeof out[cur] !== 'object' || Array.isArray(out[cur])) out[cur] = {};
      out[cur][m[1]] = yamlValue(m[2]);
    }
  }
  return out;
}

// ── the state directory ───────────────────────────────────────────────────────────────────────────
const stateDir = (root) => path.join(root, '.state');
function appendRunLog(root, line) {
  try { mkdirp(stateDir(root)); fs.appendFileSync(path.join(stateDir(root), 'run.log'), new Date().toISOString() + ' ' + line + '\n'); } catch (e) { /* best effort */ }
}
function acquireLock(root) {
  const d = path.join(stateDir(root), 'lock');
  mkdirp(stateDir(root));
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      fs.mkdirSync(d);
      fs.writeFileSync(path.join(d, 'pid'), String(process.pid));
      return () => { try { fs.rmSync(d, { recursive: true, force: true }); } catch (e) { /* gone */ } };
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      const pid = Number(readText(path.join(d, 'pid')));
      let alive = false;
      if (pid > 0) { try { process.kill(pid, 0); alive = true; } catch (err) { alive = err.code === 'EPERM'; } }
      let age = Infinity;
      try { age = Date.now() - fs.statSync(d).mtimeMs; } catch (err) { /* raced */ }
      if (alive && age < 3 * HOUR) throw new ArchiveError('LOCKED', 'another archive run holds the lock (pid ' + pid + ')');
      fs.rmSync(d, { recursive: true, force: true });
    }
  }
  throw new ArchiveError('LOCKED', 'cannot take the archive lock');
}

class Tally {
  constructor() { this.classes = {}; }
  // why: the Graph refusal behind an error:<status>, kept (last one per status) so the detail says why
  add(cls, status, detail, why) {
    const c = this.classes[cls] || (this.classes[cls] = { counts: {}, detail: '', errors: {} });
    c.counts[status] = (c.counts[status] || 0) + 1;
    if (detail) c.detail = detail;
    if (why) c.errors[status] = why;
  }
  summary() {
    const out = {};
    for (const cls of Object.keys(this.classes)) {
      const c = this.classes[cls];
      const entries = Object.entries(c.counts).sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
      const total = entries.reduce((sum, e) => sum + e[1], 0);
      const whys = Object.keys(c.errors).sort().map((s) => s + ' — ' + c.errors[s]);
      out[cls] = { status: entries[0][0], counts: c.counts, detail: c.detail || (entries.length === 1 ? 'all ' + total + ' meeting(s)'
        : total + ' meeting(s): ' + entries.map(([s, n]) => s + ' ×' + n).join(', ')) + (whys.length ? '; ' + whys.join('; ') : '') };
      if (whys.length) out[cls].errors = Object.assign({}, c.errors);
    }
    return out;
  }
}

// ── whose tenant: the caller's, and each meeting organizer's ──────────────────────────────────────
// /me/onlineMeetings — and every transcript, recording, attendance report, AI insight and chat reached
// through it — finds only meetings organised in the caller's own tenant, and a personal Microsoft account
// reaches none. Asking anyway spends a request per meeting and records error:400, the wrong answer for
// the commonest real meeting (a consultant's client meetings, measured: 10 of 10). So the run learns the
// caller's tenant once and reads the organizer's from each join URL; when they say the lookup cannot
// succeed, the status says why and nothing is sent. When either is unknown, the meeting is looked up.

// MSAL's homeAccountId is "<object id>.<tenant id>".
function tenantOfHomeAccountId(id) {
  const s = String(id == null ? '' : id);
  const dot = s.indexOf('.');
  const tid = dot < 0 ? '' : s.slice(dot + 1);
  return GUID.test(tid) ? tid.toLowerCase() : null;
}

// The tenant of the cached account whose username is the configured one (case-insensitive).
function accountTenantFrom(accounts, account) {
  const want = String(account || '').toLowerCase();
  if (!want) return null;
  for (const a of Array.isArray(accounts) ? accounts : []) {
    if (!a || typeof a !== 'object' || String(a.username || a.email || '').toLowerCase() !== want) continue;
    const tid = tenantOfHomeAccountId(a.id !== undefined ? a.id : a.homeAccountId);
    if (tid) return tid;
  }
  return null;
}

// The server's own --list-accounts flag reads its token cache, prints {"accounts":[{id: <homeAccountId>,
// username, …}]} and exits: no Graph request, no write. (The list-accounts TOOL leaves the id out.)
function accountsFromServerCli(cfg) {
  const logDir = fs.mkdtempSync(path.join(os.tmpdir(), 'microsoft365-archive-server-log-'));
  try {
    const r = spawnSync(cfg.node, [cfg.server].concat(cfg.serverArgs, ['--list-accounts']),
      { encoding: 'utf8', timeout: 20000, maxBuffer: 4 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'], env: serverEnv(cfg, logDir) });
    if (r.error) return { accounts: null, why: 'the server\'s --list-accounts could not run: ' + r.error.message };
    if (r.status !== 0) return { accounts: null, why: 'the server\'s --list-accounts exited ' + (r.signal || r.status) };
    const lines = String(r.stdout || '').split('\n').map((l) => l.trim()).filter(Boolean);
    for (let i = lines.length - 1; i >= 0; i--) {
      let d;
      try { d = JSON.parse(lines[i]); } catch (e) { continue; }
      if (d && Array.isArray(d.accounts)) return { accounts: d.accounts, why: '' };
    }
    return { accounts: null, why: 'the server\'s --list-accounts printed no account list' };
  } finally {
    try { fs.rmSync(logDir, { recursive: true, force: true }); } catch (e) { /* temp */ }
  }
}

// callerTenant — {id, personal, source}; id null when it cannot be learned (then nothing changes).
// A sign-in pinned to one tenant (config tenant=<guid>, a guest's included) acts in that tenant.
function callerTenant(cfg, toolAccounts) {
  const pinned = String(cfg.tenant || '').trim().toLowerCase();
  let id = null;
  let source;
  if (pinned === 'consumers') { id = PERSONAL_TENANT; source = 'the config tenant consumers'; }
  else if (GUID.test(pinned)) { id = pinned; source = 'the config tenant'; }
  else if ((id = accountTenantFrom(toolAccounts, cfg.account))) source = 'the list-accounts tool';
  else {
    const cli = accountsFromServerCli(cfg);
    id = accountTenantFrom(cli.accounts, cfg.account);
    source = id ? 'the server\'s --list-accounts' : cli.why || 'no cached account ' + cfg.account + ' carries a tenant id';
  }
  return { id, personal: id === PERSONAL_TENANT, source };
}

// organizerTenantOf — the Tid in a Teams join URL's context parameter (URL-encoded JSON), else null.
function organizerTenantOf(joinUrl) {
  let u;
  try { u = new URL(String(joinUrl)); } catch (e) { return null; }
  const raw = u.searchParams.get('context');
  if (!raw) return null;
  let again = raw;
  try { again = decodeURIComponent(raw); } catch (e) { /* not encoded twice */ }
  for (const text of [raw, again]) {
    let c;
    try { c = JSON.parse(text); } catch (e) { continue; }
    const tid = c && typeof c === 'object' ? (c.Tid !== undefined ? c.Tid : c.tid) : undefined;
    return typeof tid === 'string' && GUID.test(tid) ? tid.toLowerCase() : null;
  }
  return null;
}

// meetingOutOfReach — the status every onlineMeeting artifact gets without a request, or null to look.
function meetingOutOfReach(tenant, organizerTenant) {
  if (tenant && tenant.personal) return PERSONAL_ACCOUNT;
  if (tenant && tenant.id && organizerTenant && organizerTenant !== tenant.id) return EXTERNAL_ORGANIZER + ':' + organizerTenant;
  return null;
}

function describeTenant(t) {
  if (!t || !t.id) return 'unknown (' + ((t && t.source) || 'not learned') + '): every meeting is looked up';
  return t.id + (t.personal ? ' — a personal Microsoft account: no onlineMeetings or Copilot history request is made' : '') + ' (from ' + t.source + ')';
}

// ── meetings (goal 1) ─────────────────────────────────────────────────────────────────────────────
function scanMeetingFolders(root) {
  const byHash = new Map();
  const base = path.join(root, 'meetings');
  const list = (d) => { try { return fs.readdirSync(d, { withFileTypes: true }).filter((x) => x.isDirectory()).map((x) => x.name).sort(); } catch (e) { return []; } };
  for (const y of list(base)) for (const m of list(path.join(base, y))) for (const leaf of list(path.join(base, y, m))) {
    const h = /__([0-9a-f]{12})$/.exec(leaf);
    if (h && !byHash.has(h[1])) byHash.set(h[1], ['meetings', y, m, leaf].join('/'));
  }
  return byHash;
}

function personLine(emailAddress) {
  const e = emailAddress || {};
  const name = oneLine(e.name);
  const addr = oneLine(e.address);
  return name && addr && name.toLowerCase() !== addr.toLowerCase() ? name + ' <' + addr + '>' : addr ? '<' + addr + '>' : name || 'unknown';
}

function driveItemCard(item) {
  const lines = ['- **' + oneLine(item.name) + '**'];
  if (item.createdDateTime) lines.push('  - Created: ' + oneLine(item.createdDateTime));
  if (item.size !== undefined) lines.push('  - Size: ' + item.size + ' bytes');
  if (item.webUrl) lines.push('  - Open: <' + mdLink(item.webUrl) + '>');
  return lines.join('\n');
}

const NOTE_EXTENSIONS = /\.(loop|fluid|whiteboard)$/i;

async function listDriveFolders(graph) {
  const answers = await graph.getMany(DRIVE_FOLDERS.map((f) => ({ url: '/me/drive/root:/' + encodeURIComponent(f) + ':/children?$top=200' })));
  const out = {};
  for (let i = 0; i < DRIVE_FOLDERS.length; i++) {
    const res = answers[i];
    if (res.status === 404) { out[DRIVE_FOLDERS[i]] = { status: 'none', items: [] }; continue; }
    if (!ok(res)) { out[DRIVE_FOLDERS[i]] = { status: deriveStatus(res, 'loop_notes'), items: [], detail: errorDetail(res) }; continue; }
    const got = await graph.pages(res, {}, 5000);
    out[DRIVE_FOLDERS[i]] = { status: 'available', items: got.items.filter((x) => x && x.file) };
  }
  return out;
}

async function harvestMeetings(ctx) {
  const { graph, window: win, tally, log } = ctx;
  const calUrl = '/me/calendarView?startDateTime=' + encodeURIComponent(win.since) + '&endDateTime=' + encodeURIComponent(win.until) +
    '&$select=' + EVENT_SELECT + '&$top=100';
  const headers = { Prefer: 'outlook.timezone="UTC", IdType="ImmutableId"' };
  const cal = await graph.getAll(calUrl, headers, 5000);
  if (!ok(cal.res)) {
    const st = deriveStatus(cal.res, 'meetings');
    tally.add('meetings', st, 'calendar: ' + st + (/^error:/.test(st) ? ' — ' + errorDetail(cal.res) : ''));
    log('meetings: the calendar answered ' + st);
    return;
  }
  const events = cal.items.filter((e) => e && e.isOnlineMeeting === true && e.isCancelled !== true);
  tally.add('meetings', 'available', events.length + ' online meeting(s) in ' + win.since + ' .. ' + win.until);
  const folders = await listDriveFolders(graph);
  const byHash = scanMeetingFolders(ctx.root);
  ctx.cache = { meetings: new Map(), lists: new Map(), chats: new Map(), notes: new Map() };
  for (const event of events) {
    try {
      await harvestOne(ctx, event, folders, byHash);
      ctx.meetingCount++;
    } catch (e) {
      if (e.code === 'AUTH_DEAD' || e.code === 'SERVER_FAILED') throw e;
      ctx.errors.push('meeting ' + oneLine(event.subject) + ' (' + oneLine(event.iCalUId) + '): ' + e.message);
      log('meeting ' + oneLine(event.subject) + ': NOT written this run: ' + e.message);
    }
  }
}

function onlineMeetingLookupUrl(joinUrl) {
  return '/me/onlineMeetings?$filter=' + encodeURIComponent("JoinWebUrl eq '" + String(joinUrl).replace(/'/g, "''") + "'");
}

async function meetingLists(ctx, onlineMeeting) {
  if (ctx.cache.lists.has(onlineMeeting.id)) return ctx.cache.lists.get(onlineMeeting.id);
  const base = '/me/onlineMeetings/' + seg(onlineMeeting.id);
  const urls = [base + '/transcripts', base + '/recordings', base + '/attendanceReports'];
  if (ctx.me && ctx.me.id) urls.push('/copilot/users/' + seg(ctx.me.id) + '/onlineMeetings/' + seg(onlineMeeting.id) + '/aiInsights');
  const firsts = await ctx.graph.getMany(urls.map((url) => ({ url })));
  const lists = {};
  const names = ['transcripts', 'recordings', 'attendanceReports', 'aiInsights'];
  for (let i = 0; i < firsts.length; i++) lists[names[i]] = await ctx.graph.pages(firsts[i], {}, 1000);
  if (!lists.aiInsights) lists.aiInsights = { res: { status: 0, headers: {}, body: { error: { code: 'noUser', message: 'the signed-in user id is unknown (GET /me failed)' } } }, items: [] };
  ctx.cache.lists.set(onlineMeeting.id, lists);
  return lists;
}

async function harvestOne(ctx, event, folders, byHash) {
  const { graph, now } = ctx;
  const start = graphDateTime(event.start);
  const end = graphDateTime(event.end);
  if (!Number.isFinite(start) || !Number.isFinite(end)) throw new ArchiveError('DATA', 'the event has no readable start/end');
  const winStart = start - WINDOW_BEFORE;
  const winEnd = end + WINDOW_AFTER;
  const series = !!event.seriesMasterId || event.type === 'occurrence' || event.type === 'exception';
  const inWindow = (value) => { const t = parseTime(value); return Number.isFinite(t) ? t >= winStart && t <= winEnd : !series; };
  const pendingOrNone = now < winEnd ? 'pending' : 'none';
  const byCreated = (a, b) => (parseTime(a.createdDateTime) - parseTime(b.createdDateTime)) || (String(a.id) < String(b.id) ? -1 : String(a.id) > String(b.id) ? 1 : 0);

  const icalUid = String(event.iCalUId || 'event:' + event.id);
  const hash = shortHash(Buffer.from(icalUid, 'utf8'));
  const startIso = isoUtc(start);
  const subject = oneLine(event.subject) || '(no subject)';
  const rel = byHash.get(hash) || ['meetings', startIso.slice(0, 4), startIso.slice(0, 7),
    startIso.slice(0, 10) + '_' + startIso.slice(11, 13) + startIso.slice(14, 16) + '_' + render.slugify(subject) + '__' + hash].join('/');
  byHash.set(hash, rel);

  const status = {};
  for (const a of ARTIFACTS) status[a] = 'none';
  const why = {}; // artifact -> the Graph refusal behind an error:<status>, for .state/status.json
  const derive = (a, res) => { const s = deriveStatus(res, a); if (/^error:/.test(s)) why[a] = errorDetail(res); return s; };
  const files = []; // [name, bytes|string]
  const joinUrl = event.onlineMeeting && event.onlineMeeting.joinUrl ? String(event.onlineMeeting.joinUrl) : '';

  // the onlineMeeting object — one lookup per join URL per run (a series shares one) — unless the
  // caller's tenant cannot reach it (a personal account, or a meeting organised in another tenant)
  let onlineMeeting = null;
  let onlineMeetingStatus = meetingOutOfReach(ctx.tenant, joinUrl ? organizerTenantOf(joinUrl) : null) || 'none';
  let onlineMeetingWhy = '';
  if (joinUrl && onlineMeetingStatus === 'none') {
    let found = ctx.cache.meetings.get(joinUrl);
    if (!found) {
      const res = await graph.get(onlineMeetingLookupUrl(joinUrl));
      const v = ok(res) && res.body && Array.isArray(res.body.value) ? res.body.value : [];
      const st = ok(res) ? (v[0] ? 'available' : 'none') : deriveStatus(res, 'meeting');
      found = { onlineMeeting: v[0] || null, status: st, why: /^error:/.test(st) ? 'looking the meeting up: ' + errorDetail(res) : '' };
      ctx.cache.meetings.set(joinUrl, found);
    }
    onlineMeeting = found.onlineMeeting;
    onlineMeetingStatus = found.status;
    onlineMeetingWhy = found.why;
  }

  let linkRecords = null;
  if (onlineMeeting && onlineMeeting.id) {
    const lists = await meetingLists(ctx, onlineMeeting);
    const base = '/me/onlineMeetings/' + seg(onlineMeeting.id);

    // transcript: only the transcripts created in THIS occurrence's window (a series shares the object)
    if (!ok(lists.transcripts.res)) status.transcript = derive('transcript', lists.transcripts.res);
    else {
      const mine = lists.transcripts.items.filter((t) => t && inWindow(t.createdDateTime)).sort(byCreated);
      if (!mine.length) status.transcript = pendingOrNone;
      else {
        const answers = await graph.getMany(mine.map((t) => ({ url: base + '/transcripts/' + seg(t.id) + '/content?$format=text/vtt' })));
        let got = 0;
        for (let i = 0; i < mine.length; i++) {
          const a = answers[i];
          if (!ok(a) && a.status !== 302) { if (!got) status.transcript = derive('transcript', a); continue; }
          const bytes = await bytesOf(a);
          const suffix = got ? '-' + (got + 1) : '';
          const head = '# Transcript — ' + subject + '\n\n- Transcript: `' + oneLine(mine[i].id) + '`\n- Created: ' + oneLine(mine[i].createdDateTime) + '\n\n';
          files.push(['transcript' + suffix + '.vtt', bytes]);
          files.push(['transcript' + suffix + '.md', head + render.vttToMarkdown(bytes.toString('utf8'))]);
          got++;
          status.transcript = 'available';
        }
      }
    }

    // recording: a link card, never the mp4
    const recCards = [];
    if (ok(lists.recordings.res)) {
      const mine = lists.recordings.items.filter((r) => r && inWindow(r.createdDateTime)).sort(byCreated);
      for (const r of mine) {
        const lines = ['- Recording: `' + oneLine(r.id) + '`'];
        if (r.createdDateTime) lines.push('  - Created: ' + oneLine(r.createdDateTime));
        if (r.endDateTime) lines.push('  - Ended: ' + oneLine(r.endDateTime));
        if (r.contentCorrelationId) lines.push('  - Content correlation: `' + oneLine(r.contentCorrelationId) + '`');
        if (r.recordingContentUrl) lines.push('  - Content (Graph, needs the recording scope): `' + oneLine(r.recordingContentUrl) + '`');
        recCards.push(lines.join('\n'));
      }
      status.recording = mine.length ? 'linked' : pendingOrNone;
    } else status.recording = derive('recording', lists.recordings.res);
    const driveRecs = folders.Recordings.items.filter((x) => inWindow(x.createdDateTime)).sort(byCreated);
    if (driveRecs.length) status.recording = 'linked';
    if (recCards.length || driveRecs.length) {
      const parts = ['# Recording — ' + subject, '', '_A link card: the recording itself is not downloaded._', ''];
      if (recCards.length) parts.push('## From the meeting', '', recCards.join('\n'), '');
      if (driveRecs.length) parts.push('## In your OneDrive /Recordings', '', driveRecs.map(driveItemCard).join('\n'), '');
      files.push(['recording.md', parts.join('\n')]);
    }

    // attendance: the reports of THIS occurrence, each with its records
    if (!ok(lists.attendanceReports.res)) status.attendance = derive('attendance', lists.attendanceReports.res);
    else {
      const mine = lists.attendanceReports.items.filter((r) => r && inWindow(r.meetingStartDateTime))
        .sort((a, b) => (parseTime(a.meetingStartDateTime) - parseTime(b.meetingStartDateTime)) || (String(a.id) < String(b.id) ? -1 : 1));
      if (!mine.length) status.attendance = 'none';
      else {
        const firsts = await graph.getMany(mine.map((r) => ({ url: base + '/attendanceReports/' + seg(r.id) + '/attendanceRecords' })));
        const sections = [];
        for (let i = 0; i < mine.length; i++) {
          const recs = await graph.pages(firsts[i], {}, 5000);
          if (!ok(recs.res)) { status.attendance = derive('attendance', recs.res); continue; }
          sections.push(render.attendanceToMarkdown(mine[i], recs.items));
        }
        if (sections.length) {
          files.push(['attendance.md', '# Attendance — ' + subject + '\n\n' + sections.join('\n')]);
          status.attendance = 'available';
        }
      }
    }

    // AI notes (Copilot meeting insights)
    if (!ok(lists.aiInsights.res)) {
      if (lists.aiInsights.res.status !== 0) status.ai_notes = derive('ai_notes', lists.aiInsights.res);
      else { status.ai_notes = 'error:0'; why.ai_notes = errorDetail(lists.aiInsights.res); }
    } else {
      const mine = lists.aiInsights.items.filter((x) => x && inWindow(x.createdDateTime)).sort(byCreated);
      if (!mine.length) status.ai_notes = pendingOrNone;
      else {
        const answers = await graph.getMany(mine.map((x) => ({ url: '/copilot/users/' + seg(ctx.me.id) + '/onlineMeetings/' + seg(onlineMeeting.id) + '/aiInsights/' + seg(x.id) })));
        const sections = [];
        for (let i = 0; i < mine.length; i++) {
          if (!ok(answers[i])) { status.ai_notes = derive('ai_notes', answers[i]); continue; }
          sections.push(render.aiInsightToMarkdown(answers[i].body));
        }
        if (sections.length) {
          files.push(['ai-notes.md', '# AI notes — ' + subject + '\n\n' + sections.join('\n')]);
          status.ai_notes = 'available';
        }
      }
    }

    // chat: the meeting's thread, oldest first; its links resolved read-only, depth 2
    const threadId = onlineMeeting.chatInfo && onlineMeeting.chatInfo.threadId;
    if (!threadId) status.chat = 'none';
    else {
      let chat = ctx.cache.chats.get(threadId);
      if (!chat) {
        chat = await graph.getAll('/chats/' + seg(threadId) + '/messages?$top=50', {}, CHAT_CAP);
        ctx.cache.chats.set(threadId, chat);
      }
      if (!ok(chat.res)) status.chat = derive('chat', chat.res);
      else if (!chat.items.length) status.chat = 'none';
      else {
        files.push(['chat.md', '# Chat — ' + subject + '\n\n' + render.chatToMarkdown(chat.items)]);
        status.chat = 'available';
        const roots = messageLinks(chat.items);
        if (roots.length) {
          if (!chat.links) chat.links = await resolve.resolveAll(roots, graph.graphGet(), { maxDepth: 2 });
          linkRecords = chat.links;
        }
      }
    }
  } else {
    for (const a of ONLINE_MEETING_ARTIFACTS) { status[a] = onlineMeetingStatus; if (onlineMeetingWhy) why[a] = onlineMeetingWhy; }
    const driveRecs = folders.Recordings.items.filter((x) => inWindow(x.createdDateTime)).sort(byCreated);
    if (driveRecs.length) {
      status.recording = 'linked';
      files.push(['recording.md', ['# Recording — ' + subject, '', '_A link card: the recording itself is not downloaded._', '',
        '## In your OneDrive /Recordings', '', driveRecs.map(driveItemCard).join('\n'), ''].join('\n')]);
    }
  }
  if (linkRecords) files.push(['links.md', linksMarkdown('Links in the chat — ' + subject, linkRecords)]);

  // loop / whiteboard notes and other files in the user's own OneDrive meeting folders
  const noteItems = folders.Meetings.items.concat(folders.Whiteboards.items).filter((x) => inWindow(x.createdDateTime)).sort(byCreated);
  const noteSections = [];
  const noteLinks = [];
  for (const item of noteItems) {
    if (!NOTE_EXTENSIONS.test(String(item.name || ''))) { noteLinks.push(driveItemCard(item)); continue; }
    // The whole outcome is cached — the converted section OR the "not converted" card — so every
    // occurrence whose window holds the note gets the same thing, whichever the calendar listed first.
    let outcome = ctx.cache.notes.get(item.id);
    if (outcome === undefined) {
      const res = await graph.get('/me/drive/items/' + seg(item.id) + '/content?format=html');
      if (ok(res) || res.status === 302) {
        const html = (await bytesOf(res)).toString('utf8');
        outcome = { section: '## ' + oneLine(item.name) + '\n\n' + (item.webUrl ? 'Source: <' + mdLink(item.webUrl) + '>\n\n' : '') + render.htmlToMarkdown(html).trim() + '\n', link: null };
      } else {
        outcome = { section: null, link: driveItemCard(item) + '\n  - Not converted: ' + deriveStatus(res, 'loop_notes') };
      }
      ctx.cache.notes.set(item.id, outcome);
    }
    if (outcome.section) noteSections.push(outcome.section);
    if (outcome.link) noteLinks.push(outcome.link);
  }
  if (noteSections.length || noteLinks.length) {
    const parts = ['# Meeting notes — ' + subject, ''];
    if (noteSections.length) parts.push(noteSections.join('\n'));
    if (noteLinks.length) parts.push('## Linked files', '', noteLinks.join('\n'), '');
    files.push(['notes.md', parts.join('\n')]);
    status.loop_notes = noteSections.length ? 'available' : 'linked';
  } else {
    const refused = [folders.Meetings, folders.Whiteboards].find((f) => f.status !== 'available' && f.status !== 'none');
    status.loop_notes = refused ? refused.status : 'none';
    if (refused && refused.detail) why.loop_notes = refused.detail;
  }

  // write: artifacts first, then the hub that lists them
  for (const [name, content] of files) ctx.writer.write(rel + '/' + name, content, true);
  const organizer = event.organizer && event.organizer.emailAddress ? personLine(event.organizer.emailAddress) : null;
  const attendees = (Array.isArray(event.attendees) ? event.attendees : []).map((a) => personLine(a && a.emailAddress))
    .filter((v, i, arr) => arr.indexOf(v) === i).sort((a, b) => (a.toLowerCase() < b.toLowerCase() ? -1 : a.toLowerCase() > b.toLowerCase() ? 1 : 0));
  const fields = {
    schema: SCHEMA, ical_uid: icalUid, event_id: event.id ? String(event.id) : null, subject, start: startIso, end: isoUtc(end),
    organizer, attendees, join_url: joinUrl || null, online_meeting_id: onlineMeeting && onlineMeeting.id ? String(onlineMeeting.id) : null, artifacts: status,
  };
  const present = listFolderFiles(path.join(ctx.root, rel));
  ctx.writer.write(rel + '/meeting.md', render.frontMatter(fields, MEETING_KEYS) + meetingBody(fields, present), true);
  for (const a of ARTIFACTS) ctx.tally.add(a, status[a], null, /^error:/.test(status[a]) ? why[a] : '');
  ctx.log('meeting ' + startIso.slice(0, 16).replace('T', ' ') + ' ' + subject + ': ' + ARTIFACTS.map((a) => a + '=' + status[a]).join(' '));
}

function listFolderFiles(dir) {
  try {
    return fs.readdirSync(dir, { withFileTypes: true }).filter((d) => d.isFile() && d.name[0] !== '.' && d.name !== 'meeting.md')
      .map((d) => d.name).sort();
  } catch (e) { return []; }
}

function meetingBody(fields, present) {
  const lines = ['', '# ' + fields.subject, '',
    '- When: ' + fields.start.slice(0, 10) + ' ' + fields.start.slice(11, 16) + ' – ' + (fields.end.slice(0, 10) === fields.start.slice(0, 10) ? '' : fields.end.slice(0, 10) + ' ') + fields.end.slice(11, 16) + ' UTC',
    '- Organizer: ' + (fields.organizer || 'unknown'),
    '- Attendees: ' + fields.attendees.length];
  if (fields.join_url) lines.push('- Join link: <' + mdLink(fields.join_url) + '>');
  lines.push('', '## Artifacts', '', '| Artifact | Status |', '| --- | --- |');
  for (const a of ARTIFACTS) lines.push('| ' + ARTIFACT_LABELS[a] + ' | ' + cell(fields.artifacts[a]) + ' |');
  lines.push('', '## Files', '');
  if (!present.length) lines.push('_None yet._');
  for (const f of present) lines.push('- [' + f + '](' + mdLink(f) + ')');
  return lines.join('\n') + '\n';
}

// Outlinks of chat messages: <a href> in the body, reference attachments, Loop components.
function messageLinks(messages) {
  const out = [];
  const add = (u) => { if (/^https?:\/\//i.test(u) && out.indexOf(u) < 0) out.push(u); };
  for (const m of messages) {
    const html = m && m.body && typeof m.body.content === 'string' ? m.body.content : '';
    const re = /\bhref\s*=\s*(?:"([^"]*)"|'([^']*)')/gi;
    let x;
    while ((x = re.exec(html)) !== null) add((x[1] !== undefined ? x[1] : x[2]).replace(/&amp;/g, '&'));
    for (const att of (m && Array.isArray(m.attachments) ? m.attachments : [])) {
      const ct = String((att && att.contentType) || '').toLowerCase();
      if (ct === 'reference' && att.contentUrl) add(String(att.contentUrl));
      if (ct === 'application/vnd.microsoft.card.fluidembedcard' && typeof att.content === 'string') {
        try { const c = JSON.parse(att.content); if (c && c.componentUrl) add(String(c.componentUrl)); } catch (e) { /* not JSON */ }
      }
    }
  }
  return out;
}

function linksMarkdown(title, records) {
  const lines = ['# ' + title, '', '_Resolved read-only through Microsoft Graph; a 403 is "denied", never "gone"._', '',
    '| Status | Kind | Name | Link | Detail |', '| --- | --- | --- | --- | --- |'];
  for (const r of records) {
    const item = r.item && typeof r.item === 'object' ? r.item : {};
    const name = item.name || item.displayName || item.subject || '';
    const url = item.webUrl || r.url || '';
    lines.push('| ' + [cell(r.status), cell(r.kind), cell(name), url ? '<' + mdLink(url) + '>' : '', cell(r.detail)].join(' | ') + ' |');
  }
  const sk = records.skipped;
  if (sk && (sk.depth || sk.budget)) lines.push('', '_Not followed: ' + sk.depth + ' beyond the depth limit, ' + sk.budget + ' beyond the node budget._');
  return lines.join('\n') + '\n';
}

// ── Copilot (goal 3) ──────────────────────────────────────────────────────────────────────────────
function safeFileName(name, used) {
  let n = String(name == null ? '' : name).replace(/[/\\:\u0000-\u001f\u007f]/g, '_').trim();
  if (!n || n === '.' || n === '..') n = 'unnamed';
  if (n[0] === '.') n = '_' + n.slice(1);
  if (n.length > 180) n = n.slice(0, 180);
  let out = n;
  for (let i = 2; used.has(out.toLowerCase()); i++) out = n + '-' + i;
  used.add(out.toLowerCase());
  return out;
}

function converterId(cfg, file) {
  const r = spawnSync('/bin/bash', [cfg.convert, '--converter-id', file], { encoding: 'utf8', timeout: 30000 });
  return r.status === 0 ? oneLine(r.stdout).slice(0, 80) : 'unknown';
}

async function harvestCopilot(ctx) {
  const { graph, tally, writer, cfg } = ctx;
  let history = 'error:0';
  let probeDetail = 'not probed: the signed-in user id is unknown (GET /me failed)';
  if (ctx.tenant && ctx.tenant.personal) {
    history = PERSONAL_ACCOUNT;
    probeDetail = 'not probed: ' + cfg.account + ' is a personal Microsoft account, and the interaction history API serves work or school accounts only';
  } else if (ctx.me && ctx.me.id) {
    const res = await graph.get('/copilot/users/' + seg(ctx.me.id) + '/interactionHistory/getAllEnterpriseInteractions?$top=1');
    history = deriveStatus(res, 'copilot_history');
    probeDetail = 'getAllEnterpriseInteractions answered ' + errorDetail(res);
  }
  tally.add('copilot_history', history, probeDetail);

  const first = await graph.get('/me/drive/root:/' + encodeURIComponent(COPILOT_FILES_FOLDER) + ':/children?$top=200');
  let filesStatus;
  let mirrored = 0;
  if (first.status === 404) filesStatus = 'none';
  else if (!ok(first)) filesStatus = deriveStatus(first, 'copilot_files');
  else {
    const listing = await graph.pages(first, {}, 5000);
    const items = listing.items.filter((x) => x && x.file).sort((a, b) => (String(a.name).toLowerCase() < String(b.name).toLowerCase() ? -1 : String(a.name).toLowerCase() > String(b.name).toLowerCase() ? 1 : String(a.id) < String(b.id) ? -1 : 1));
    const statePath = path.join(stateDir(ctx.root), 'copilot-files.json');
    const known = readJson(statePath) || {};
    const used = new Set();
    const rows = [];
    for (const item of items) {
      const local = safeFileName(item.name, used);
      const rawRel = 'copilot/files/raw/' + local;
      const mdRel = 'copilot/files/' + local + '.md';
      const hash = item.file && item.file.hashes && item.file.hashes.quickXorHash ? String(item.file.hashes.quickXorHash) : '';
      const size = Number(item.size) || 0;
      let note;
      let rawChanged = false;
      if (size > DOWNLOAD_CAP) note = 'link only: larger than 50 MB';
      else if (hash && known[item.id] && known[item.id].quickXorHash === hash && fs.existsSync(path.join(ctx.root, rawRel)) && fs.existsSync(path.join(ctx.root, mdRel))) {
        note = 'mirrored';
        mirrored++;
      } else if (!item['@microsoft.graph.downloadUrl']) note = 'link only: Graph gave no download URL';
      else {
        try {
          const bytes = await fetchPreauthenticated(item['@microsoft.graph.downloadUrl'], 0);
          rawChanged = writer.write(rawRel, bytes, false);
          note = 'mirrored';
          mirrored++;
          known[item.id] = { quickXorHash: hash, name: local };
        } catch (e) {
          if (e.code !== 'TRANSPORT') throw e;
          note = 'download failed: ' + e.message;
          ctx.errors.push('copilot file ' + local + ': ' + e.message);
        }
      }
      if (note !== 'mirrored' || rawChanged || !hash || !fs.existsSync(path.join(ctx.root, mdRel)) || !known[item.id] || known[item.id].converted !== hash) {
        writer.write(mdRel, copilotFileView(cfg, item, note === 'mirrored' ? path.join(ctx.root, rawRel) : null, note), false);
        if (note === 'mirrored' && known[item.id]) known[item.id].converted = hash;
      }
      rows.push('| ' + [cell(item.name), String(size), cell(item.lastModifiedDateTime), item.webUrl ? '<' + mdLink(item.webUrl) + '>' : '',
        '[' + cell(local) + '.md](' + mdLink('files/' + local + '.md') + ')', cell(note)].join(' | ') + ' |');
    }
    mkdirp(stateDir(ctx.root));
    fs.writeFileSync(statePath, JSON.stringify(known, null, 2) + '\n');
    writer.write('copilot/files.md', ['# Files uploaded to Copilot Chat', '',
      '_Your OneDrive folder "' + COPILOT_FILES_FOLDER + '", mirrored read-only._', '',
      '| Name | Size | Last modified | Web | View | State |', '| --- | --- | --- | --- | --- | --- |'].concat(rows).join('\n') + '\n', false);
    filesStatus = 'available';
  }
  tally.add('copilot_files', filesStatus, filesStatus === 'available' ? mirrored + ' file(s) mirrored'
    : filesStatus === 'none' ? 'no "' + COPILOT_FILES_FOLDER + '" folder in your OneDrive (nothing uploaded yet)' : 'listing the folder answered ' + filesStatus);
  writer.write('copilot/status.md', render.frontMatter({ schema: SCHEMA, interaction_history: history, uploaded_files: filesStatus },
    ['schema', 'interaction_history', 'uploaded_files']) + '\n# Copilot sources\n\n' +
    '- Interaction history (the bulk API): ' + history + '\n- Uploaded files: ' + filesStatus +
    (filesStatus === 'available' ? ' — see [files.md](files.md)' : '') + '\n- Imported sessions: [sessions/](sessions/)\n', false);
}

function copilotFileView(cfg, item, rawAbs, note) {
  const head = ['# ' + oneLine(item.name), '', '- Size: ' + (Number(item.size) || 0) + ' bytes',
    '- Last modified: ' + oneLine(item.lastModifiedDateTime)];
  if (item.webUrl) head.push('- Web: <' + mdLink(item.webUrl) + '>');
  if (rawAbs && cfg.convert && fs.existsSync(cfg.convert)) {
    const r = spawnSync('/bin/bash', [cfg.convert, rawAbs], { encoding: 'utf8', timeout: 300000, maxBuffer: 64 * 1024 * 1024 });
    if (r.status === 0) {
      head.push('- Converter: ' + converterId(cfg, rawAbs), '', '---', '');
      return head.join('\n') + '\n' + String(r.stdout).replace(/\s+$/, '') + '\n';
    }
    const why = r.status === 10 ? 'no converter installed for this type — ' + oneLine(r.stderr)
      : r.status === 11 ? 'the file is not downloaded (dataless)' : 'conversion failed (rc ' + r.status + ')';
    return head.join('\n') + '\n\n_Not converted: ' + why + '._\n';
  }
  return head.join('\n') + '\n\n_Not converted: ' + (rawAbs ? 'no converter configured (config key convert)' : note) + '._\n';
}

// ── copilot-import ────────────────────────────────────────────────────────────────────────────────
function scanSessionFiles(root) {
  const byHash = new Map();
  try {
    for (const f of fs.readdirSync(path.join(root, 'copilot', 'sessions')).sort()) {
      const h = /__([0-9a-f]{12})\.md$/.exec(f);
      if (h && !byHash.has(h[1])) byHash.set(h[1], 'copilot/sessions/' + f);
    }
  } catch (e) { /* none yet */ }
  return byHash;
}

async function commandImport(cfg, file) {
  requireKeys(cfg, ['root']);
  const text = readText(file);
  if (text === null) throw new ArchiveError('USAGE', 'cannot read ' + file);
  const trimmed = text.replace(/^\uFEFF/, '').trimStart();
  let sessions;
  let source;
  if (trimmed[0] === '[' || trimmed[0] === '{') {
    let data;
    try { data = JSON.parse(trimmed); } catch (e) { throw new ArchiveError('USAGE', file + ' is not valid JSON: ' + e.message); }
    const list = Array.isArray(data) ? data : data && Array.isArray(data.value) ? data.value : null;
    if (!list) throw new ArchiveError('USAGE', file + ': expected a JSON array of aiInteraction, or {"value": [...]}');
    sessions = render.interactionsToSessions(list);
    source = 'aiInteraction export (JSON)';
  } else {
    try { sessions = render.consumerCsvToSessions(text); } catch (e) { throw new ArchiveError('USAGE', file + ': ' + e.message); }
    source = 'Copilot activity export (CSV)';
  }
  const root = path.resolve(cfg.root);
  const cloud = cloudRootOf(root);
  if (cloud) throw new ArchiveError('USAGE', 'refusing an archive root under ' + cloud + ' — a sync client would re-upload the archive');
  mkdirp(root);
  const release = acquireLock(root);
  const writer = new Writer(root);
  let client = null;
  try {
    const wanted = sessions.some((s) => s.links.some((u) => resolve.classifyUrl(u).route !== 'none'));
    let graph = null;
    if (wanted && cfg.server && cfg.account) {
      client = new McpClient(cfg);
      await client.start();
      graph = new Graph(client, cfg.account, (m) => process.stdout.write(m + '\n'));
    }
    const byHash = scanSessionFiles(root);
    for (const s of sessions) {
      const hash = shortHash(Buffer.from(String(s.sessionId), 'utf8'));
      const date = s.startedAt ? s.startedAt.slice(0, 10) : 'undated';
      const rel = byHash.get(hash) || 'copilot/sessions/' + date + '_' + render.slugify(s.title) + '__' + hash + '.md';
      byHash.set(hash, rel);
      let records;
      if (graph) records = await resolve.resolveAll(s.links, graph.graphGet(), {});
      else {
        records = s.links.map((u) => {
          const c = resolve.classifyUrl(u);
          return { url: u, status: c.route === 'none' ? (c.kind === 'web' ? 'external' : 'unsupported') : 'unresolved', kind: c.kind,
            detail: c.route === 'none' ? (c.reason || '') : 'not resolved: no server and account configured', item: null };
        });
      }
      const fields = render.frontMatter({ schema: SCHEMA, session_id: String(s.sessionId), title: s.title, started_at: s.startedAt, source, links: s.links.length },
        ['schema', 'session_id', 'title', 'started_at', 'source', 'links']);
      const body = s.markdown + (records.length ? '\n' + linksMarkdown('Links', records).replace(/^# /, '## ') : '');
      writer.write(rel, fields + '\n' + body, true);
    }
    writeIndex(root, writer);
    process.stdout.write('copilot-import: ' + sessions.length + ' session(s) from ' + source + ', written ' + writer.written + ', unchanged ' + writer.unchanged + '\n');
    appendRunLog(root, 'copilot-import ' + sessions.length + ' session(s) written ' + writer.written);
  } finally {
    if (client) client.close();
    release();
  }
  return EXIT.ok;
}

// ── index.md ──────────────────────────────────────────────────────────────────────────────────────
function writeIndex(root, writer) {
  const meetings = [];
  const base = path.join(root, 'meetings');
  const dirs = (d) => { try { return fs.readdirSync(d, { withFileTypes: true }).filter((x) => x.isDirectory()).map((x) => x.name).sort(); } catch (e) { return []; } };
  for (const y of dirs(base)) for (const m of dirs(path.join(base, y))) for (const leaf of dirs(path.join(base, y, m))) {
    const rel = ['meetings', y, m, leaf].join('/');
    const fields = parseFrontMatter(readText(path.join(root, rel, 'meeting.md')));
    if (fields) meetings.push({ rel, fields });
  }
  meetings.sort((a, b) => (String(b.fields.start) < String(a.fields.start) ? -1 : String(b.fields.start) > String(a.fields.start) ? 1 : a.rel < b.rel ? -1 : 1));
  const seen = {};
  const note = (cls, st) => {
    const fam = statusFamily(st);
    if (REFUSED_FAMILIES.indexOf(fam) < 0) return;
    const k = cls + '\u0000' + fam;
    if (!seen[k]) seen[k] = { cls, fam, statuses: [] };
    if (seen[k].statuses.indexOf(st) < 0) seen[k].statuses.push(st);
  };
  const out = ['# Microsoft 365 archive', '', '_Generated from the files in this folder on every run; edit nothing here by hand._', '',
    '## Meetings', ''];
  if (!meetings.length) out.push('_No meetings archived yet._');
  else {
    out.push('| Date (UTC) | Subject | Organizer | ' + ARTIFACTS.map((a) => ARTIFACT_LABELS[a]).join(' | ') + ' |',
      '| --- | --- | --- | ' + ARTIFACTS.map(() => '---').join(' | ') + ' |');
    for (const { rel, fields } of meetings) {
      const arts = fields.artifacts && typeof fields.artifacts === 'object' ? fields.artifacts : {};
      for (const a of ARTIFACTS) if (arts[a]) note(a, String(arts[a]));
      out.push('| ' + [cell(String(fields.start || '').slice(0, 16).replace('T', ' ')), '[' + cell(fields.subject) + '](' + mdLink(rel + '/meeting.md') + ')',
        cell(fields.organizer)].concat(ARTIFACTS.map((a) => cell(arts[a] || ''))).join(' | ') + ' |');
    }
  }
  out.push('', '## Copilot', '');
  const cs = parseFrontMatter(readText(path.join(root, 'copilot', 'status.md')));
  if (cs) {
    note('copilot_history', String(cs.interaction_history || ''));
    note('copilot_files', String(cs.uploaded_files || ''));
    out.push('| Source | Status |', '| --- | --- |', '| Interaction history (bulk API) | ' + cell(cs.interaction_history) + ' |',
      '| Uploaded files | ' + cell(cs.uploaded_files) + (cs.uploaded_files === 'available' ? ' — [files.md](copilot/files.md)' : '') + ' |', '');
  }
  const sessions = [];
  try {
    for (const f of fs.readdirSync(path.join(root, 'copilot', 'sessions')).filter((x) => /\.md$/.test(x) && x[0] !== '.').sort()) {
      const fields = parseFrontMatter(readText(path.join(root, 'copilot', 'sessions', f)));
      if (fields) sessions.push({ f, fields });
    }
  } catch (e) { /* none */ }
  sessions.sort((a, b) => (String(b.fields.started_at) < String(a.fields.started_at) ? -1 : String(b.fields.started_at) > String(a.fields.started_at) ? 1 : a.f < b.f ? -1 : 1));
  if (sessions.length) {
    out.push('| Started (UTC) | Session | Links |', '| --- | --- | --- |');
    for (const { f, fields } of sessions) {
      out.push('| ' + cell(String(fields.started_at || 'undated').slice(0, 16).replace('T', ' ')) + ' | [' + cell(fields.title) + '](' + mdLink('copilot/sessions/' + f) + ') | ' + cell(fields.links) + ' |');
    }
  } else out.push('_No Copilot sessions imported yet (`copilot-import <export>`)._');
  out.push('', '## What would unlock more', '');
  const keys = Object.keys(seen).sort();
  if (!keys.length) out.push('_Nothing archived here is refused._');
  // one line per ask: the classes one status family reached with the same ask share it
  const groups = [];
  for (const k of keys) {
    const { cls, fam, statuses } = seen[k];
    const ask = unlockAsk(cls, fam) || 'See the status detail.';
    let g = groups.find((x) => x.fam === fam && x.ask === ask);
    if (!g) groups.push(g = { fam, ask, classes: [], statuses: [] });
    g.classes.push(cls);
    for (const s of statuses) if (g.statuses.indexOf(s) < 0) g.statuses.push(s);
  }
  for (const g of groups) {
    const classes = g.classes.sort((a, b) => STATUS_CLASSES.indexOf(a) - STATUS_CLASSES.indexOf(b)).map((c) => c.replace(/_/g, ' '));
    out.push('- **' + classes.join(', ') + '** (' + g.statuses.sort().map(cell).join('; ') + '): ' + g.ask);
  }
  writer.write('index.md', out.join('\n') + '\n', false);
}

// ── run ───────────────────────────────────────────────────────────────────────────────────────────
function computeWindow(root, flags, now) {
  let since = flags.since !== undefined ? parseTime(flags.since) : NaN;
  let until = flags.until !== undefined ? parseTime(flags.until) : now;
  if (flags.since !== undefined && !Number.isFinite(since)) throw new ArchiveError('USAGE', '--since is not a date: ' + flags.since);
  if (!Number.isFinite(until)) throw new ArchiveError('USAGE', '--until is not a date: ' + flags.until);
  if (flags.since === undefined) {
    const last = parseTime(oneLine(readText(path.join(stateDir(root), 'last-success'))));
    since = Number.isFinite(last) ? last - 48 * HOUR : now - 30 * 24 * HOUR;
  }
  if (since >= until) throw new ArchiveError('USAGE', 'the window is empty: --since must be before --until');
  return { since: new Date(since).toISOString(), until: new Date(until).toISOString() };
}

async function commandRun(cfg, flags) {
  requireKeys(cfg, ['root', 'server', 'account']);
  const root = path.resolve(cfg.root);
  const cloud = cloudRootOf(root);
  if (cloud) throw new ArchiveError('USAGE', 'refusing an archive root under ' + cloud + ' — a sync client would re-upload the archive');
  mkdirp(root);
  const now = Date.now();
  const win = computeWindow(root, flags, now);
  const release = acquireLock(root);
  const startedAt = new Date(now).toISOString();
  const tally = new Tally();
  const log = (m) => process.stdout.write(m + '\n');
  const ctx = { cfg, root, now, window: win, tally, log, writer: new Writer(root), errors: [], meetingCount: 0, me: null, graph: null, tenant: null };
  const client = new McpClient(cfg);
  let rc = EXIT.ok;
  let login = null;
  let advice = null;
  const watchdog = setTimeout(() => { process.stdout.write('run: exceeded ' + RUN_BUDGET_MS / MINUTE + ' minutes; stopping\n'); process.exit(EXIT.partial); }, RUN_BUDGET_MS);
  watchdog.unref();
  try {
    await client.start();
    const accounts = await client.callTool('list-accounts', { account: cfg.account });
    const emails = (accounts && Array.isArray(accounts.accounts) ? accounts.accounts : []).map((a) => String((a && (a.email || a.username)) || '').toLowerCase());
    if (emails.indexOf(String(cfg.account).toLowerCase()) < 0) throw new ArchiveError('AUTH_DEAD', 'the account ' + cfg.account + ' is not signed in to the server (cached: ' + (emails.join(', ') || 'none') + ')');
    ctx.tenant = callerTenant(cfg, accounts && accounts.accounts);
    log('account tenant: ' + describeTenant(ctx.tenant));
    ctx.graph = new Graph(client, cfg.account, log);
    const me = await ctx.graph.get('/me?$select=id,userPrincipalName');
    if (ok(me) && me.body && me.body.id) ctx.me = me.body;
    else ctx.errors.push('GET /me answered ' + deriveStatus(me, 'me'));
    await harvestMeetings(ctx);
    await harvestCopilot(ctx);
    writeIndex(root, ctx.writer);
    if (ctx.errors.length) rc = EXIT.partial;
  } catch (e) {
    if (e.code === 'AUTH_DEAD') {
      rc = EXIT.authDead;
      login = loginCommand(cfg, e.message);
      advice = signInAdvice(e.message);
      log('sign-in needed (' + e.message + ').' + (advice ? ' ' + advice : '') + ' Run:\n' + login);
    } else if (e.code === 'SERVER_FAILED') {
      rc = EXIT.serverFailed;
      log('the Microsoft 365 server failed: ' + e.message);
    } else if (e.code === 'LOCKED') {
      rc = EXIT.partial;
      log(e.message);
    } else {
      rc = EXIT.partial;
      ctx.errors.push(e.code ? e.message : String(e && e.stack || e));
      log('run stopped early: ' + (e.code ? e.message : String(e && e.stack || e)));
    }
  } finally {
    clearTimeout(watchdog);
    client.close();
  }
  const finishedAt = new Date().toISOString();
  const previous = readJson(path.join(stateDir(root), 'status.json')) || {};
  const classes = Object.assign({}, rc === EXIT.authDead || rc === EXIT.serverFailed ? previous.classes || {} : {}, tally.summary());
  const status = { run: { started: startedAt, finished: finishedAt, exit: rc, result: EXIT_NAMES[rc], window: win, meetings: ctx.meetingCount,
    written: ctx.writer.written, unchanged: ctx.writer.unchanged, errors: ctx.errors.slice(0, 50), login, advice, tenant: ctx.tenant }, classes };
  try {
    mkdirp(stateDir(root));
    fs.writeFileSync(path.join(stateDir(root), 'status.json'), JSON.stringify(status, null, 2) + '\n');
    if (rc === EXIT.ok) fs.writeFileSync(path.join(stateDir(root), 'last-success'), startedAt + '\n');
  } catch (e) { log('cannot write .state: ' + e.message); }
  const summary = 'run ' + EXIT_NAMES[rc] + ': ' + ctx.meetingCount + ' meeting(s), written ' + ctx.writer.written + ', unchanged ' + ctx.writer.unchanged +
    ', window ' + win.since + ' .. ' + win.until + (ctx.errors.length ? ', ' + ctx.errors.length + ' error(s)' : '');
  appendRunLog(root, summary + (ctx.errors.length ? ' — ' + ctx.errors.join(' | ') : ''));
  log(summary);
  release();
  return rc;
}

// status — stdout carries ONLY the artifact-class lines, "<class>\t<status>\t<detail>": a status may
// itself hold spaces (forbidden:app-only — needs …), so a tab is the one delimiter a parser can trust.
// The last run's summary and any sign-in command are for a person, and go to stderr. No recorded run
// prints no class line at all (and says so on stderr).
function commandStatus(cfg) {
  requireKeys(cfg, ['root']);
  const st = readJson(path.join(stateDir(path.resolve(cfg.root)), 'status.json'));
  if (!st) { process.stderr.write('no run recorded under ' + cfg.root + '\n'); return EXIT.ok; }
  const r = st.run || {};
  process.stderr.write('last run: ' + (r.result || 'unknown') + ' ' + (r.finished || '') + ', window ' + ((r.window && r.window.since) || '?') + ' .. ' +
    ((r.window && r.window.until) || '?') + ', written ' + (r.written || 0) + ', unchanged ' + (r.unchanged || 0) + '\n');
  if (r.login) process.stderr.write('sign-in needed: ' + r.login + '\n');
  const field = (s) => oneLine(s).replace(/\t/g, ' ');
  for (const cls of STATUS_CLASSES) {
    const c = st.classes && st.classes[cls];
    if (c) process.stdout.write(cls + '\t' + field(c.status) + '\t' + field(c.detail) + '\n');
  }
  return EXIT.ok;
}

function commandExplain(cfg) {
  requireKeys(cfg, ['root']);
  const st = readJson(path.join(stateDir(path.resolve(cfg.root)), 'status.json'));
  if (!st) { process.stdout.write('no run recorded yet: run `archive.js run` first\n'); return EXIT.ok; }
  let n = 0;
  if (st.run && st.run.login) { process.stdout.write('sign-in: ' + st.run.login + '\n'); n++; }
  for (const cls of STATUS_CLASSES) {
    const c = st.classes && st.classes[cls];
    if (!c) continue;
    // one line per class and status family: "<class> <status>[, <status>…]: <ask>"
    const byFamily = new Map();
    for (const s of Object.keys(c.counts || {}).sort()) {
      const fam = statusFamily(s);
      if (!unlockAsk(cls, fam)) continue;
      if (!byFamily.has(fam)) byFamily.set(fam, []);
      byFamily.get(fam).push(s);
    }
    for (const [fam, statuses] of byFamily) {
      process.stdout.write(cls + ' ' + statuses.join(', ') + ': ' + unlockAsk(cls, fam) + '\n');
      n++;
    }
  }
  if (!n) process.stdout.write('nothing was refused in the last run\n');
  return EXIT.ok;
}

// ═════════════════════════════════════════════════════════════════════════════════════════════════
// SELFTEST — offline. render.js and resolve.js fixtures, the guard, status derivation, and full runs of
// this CLI against fake-server.js. Every positive check has a negative control that proves it can say no.
// ═════════════════════════════════════════════════════════════════════════════════════════════════
function treeHash(root) {
  const h = crypto.createHash('sha256');
  const walk = (rel) => {
    const abs = path.join(root, rel);
    for (const d of fs.readdirSync(abs, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1))) {
      const r = rel ? rel + '/' + d.name : d.name;
      if (r === '.state') continue;
      if (d.isDirectory()) walk(r);
      else { h.update(r + '\0'); h.update(fs.readFileSync(path.join(root, r))); h.update('\0'); }
    }
  };
  walk('');
  return h.digest('hex');
}

async function selftest() {
  const say = (s) => process.stdout.write(s + '\n');
  let passed = 0;
  let failed = 0;
  const check = (name, cond, detail) => {
    if (cond) { passed++; say('ok   archive: ' + name); return; }
    failed++;
    say('FAIL archive: ' + name + (detail ? '\n       ' + String(detail).replace(/\n/g, '\n       ') : ''));
  };
  const renderFailures = render.selftest(say);
  const resolveFailures = await resolve.selftest(say);
  check('render.js fixtures pass', renderFailures === 0, renderFailures + ' failure(s)');
  check('resolve.js fixtures pass', resolveFailures === 0, resolveFailures + ' failure(s)');

  // the guard
  const refuses = (name, args) => { try { guardToolCall(name, args); return false; } catch (e) { return e.code === 'GUARD'; } };
  const batch = (reqs) => ({ body: { requests: reqs }, account: 'a@example.com' });
  check('guard admits a plain GET batch (control: the guard can say yes)', !refuses('graph-batch', batch([{ id: '1', method: 'GET', url: '/me?$select=id' }])));
  check('guard rejects a POST sub-request', refuses('graph-batch', batch([{ id: '1', method: 'POST', url: '/me/sendMail' }])));
  check('guard rejects a lower-case "get" (exact GET only)', refuses('graph-batch', batch([{ id: '1', method: 'get', url: '/me' }])));
  check('guard rejects a ".." url', refuses('graph-batch', batch([{ id: '1', method: 'GET', url: '/me/drive/root:/a/../b' }])));
  check('guard rejects %2e, #, whitespace and an absolute url', refuses('graph-batch', batch([{ id: '1', method: 'GET', url: '/me/%2E%2E/x' }])) &&
    refuses('graph-batch', batch([{ id: '1', method: 'GET', url: '/me#x' }])) && refuses('graph-batch', batch([{ id: '1', method: 'GET', url: '/me/drive/root:/a b' }])) &&
    refuses('graph-batch', batch([{ id: '1', method: 'GET', url: 'https://graph.microsoft.com/v1.0/me' }])));
  check('guard rejects /special/ (a GET there creates folders)', refuses('graph-batch', batch([{ id: '1', method: 'GET', url: '/me/drive/special/recordings' }])));
  check('guard rejects /special/ spelled with an encoded letter, an encoded slash or a double encoding, and a malformed escape',
    ['/me/drive/spec%69al/approot', '/me/drive/%73pecial/approot', '/me/drive%2Fspecial%2Fapproot', '/me/drive/%2573pecial/approot', '/me/drive/%zz']
      .every((url) => refuses('graph-batch', batch([{ id: '1', method: 'GET', url }]))));
  check('NEGATIVE CONTROL: an encoded space in a drive path is admitted (the decode refuses only what it should)',
    !refuses('graph-batch', batch([{ id: '1', method: 'GET', url: '/me/drive/root:/Microsoft%20Copilot%20Chat%20Files:/children?$top=200' }])) &&
    !refuses('graph-batch', batch([{ id: '1', method: 'GET', url: '/me/drive/items/specialist-notes/content' }])));
  check('guard rejects Prefer: redeemSharingLink', refuses('graph-batch', batch([{ id: '1', method: 'GET', url: '/shares/u!x/driveItem', headers: { Prefer: 'redeemSharingLink' } }])));
  check('guard rejects a sub-request body and any tool but graph-batch/list-accounts', refuses('graph-batch', batch([{ id: '1', method: 'GET', url: '/me', body: {} }])) &&
    refuses('send-mail', { account: 'a' }) && refuses('logout', {}) && !refuses('list-accounts', { account: 'a' }));
  let nl = null;
  try { nl = relativeFromLink(GRAPH_V1 + 'me/events?$skiptoken=x'); } catch (e) { nl = e; }
  let foreign = null;
  try { relativeFromLink('https://evil.example.com/v1.0/me'); } catch (e) { foreign = e; }
  check('nextLink: graph v1.0 becomes relative; any other host is refused', nl === '/me/events?$skiptoken=x' && foreign && foreign.code === 'GUARD', String(nl));

  // status derivation
  const res = (status, code, message, inner) => ({ status, headers: {}, body: { error: { code, message, innerError: inner ? { code: inner } : undefined } } });
  check('403 missing scope → forbidden:needs <scope> (not the scopes the token already has)',
    deriveStatus(res(403, 'Forbidden', "Missing scope permissions on the request. API requires one of 'OnlineMeetingTranscript.Read.All'. Scopes on the request 'Calendars.ReadWrite, User.Read'"), 'transcript') === 'forbidden:needs OnlineMeetingTranscript.Read.All');
  check('403 transcripts disabled → tenant-disabled', deriveStatus(res(403, 'GraphAccessToTranscriptsDisabled', 'Graph API access to transcripts is disabled for this tenant.'), 'transcript') === 'tenant-disabled');
  check('403/404 licence → license-required; control: a plain 404 is not', deriveStatus(res(404, 'NotFound', 'No Copilot license assigned'), 'ai_notes') === 'license-required' &&
    deriveStatus(res(404, 'NotFound', 'Resource not found'), 'ai_notes') === 'error:404');
  check('412 on the Copilot history → forbidden:app-only; 500 → error:500', deriveStatus(res(412, 'PreconditionFailed', 'not supported in delegated context'), 'copilot_history') === APP_ONLY &&
    deriveStatus(res(500, 'InternalServerError', 'boom'), 'chat') === 'error:500');
  let authErr = null;
  try { parseToolResult({ content: [{ type: 'text', text: JSON.stringify({ error: 'InteractionRequiredAuthError: invalid_grant' }) }], isError: true }); } catch (e) { authErr = e; }
  let transportErr = null;
  try { parseToolResult({ content: [{ type: 'text', text: JSON.stringify({ error: 'fetch failed' }) }], isError: true }); } catch (e) { transportErr = e; }
  check('a tool error naming invalid_grant is AUTH_DEAD; "fetch failed" is not', authErr && authErr.code === 'AUTH_DEAD' && transportErr && transportErr.code === 'TRANSPORT');
  let aadErr = null;
  try { parseToolResult({ content: [{ type: 'text', text: JSON.stringify({ error: 'AADSTS530084: Access has been blocked by conditional access token protection policy' }) }], isError: true }); } catch (e) { aadErr = e; }
  const lcfg = { node: '/n', server: '/s', tenant: 'organizations' };
  check('an AADSTS code is AUTH_DEAD and names its fix: token protection, device-code block (browser login), disabled app; control: no code, no advice',
    aadErr && aadErr.code === 'AUTH_DEAD' && /token protection/.test(signInAdvice(aadErr.message)) &&
    /device-code/.test(signInAdvice('AADSTS530036: The refresh token is invalid')) && /--auth-browser$/.test(loginCommand(lcfg, 'AADSTS530036: x')) &&
    /disabled/.test(signInAdvice('AADSTS7000112: UnauthorizedClientApplicationDisabled')) &&
    signInAdvice('invalid_grant') === null && /--login$/.test(loginCommand(lcfg, 'invalid_grant')));

  // whose tenant: the caller's (MSAL homeAccountId) and the organizer's (the join URL's context)
  const mine = 'c0ffee00-1111-4222-8333-444455556666';
  const theirs = '0e0e0e0e-feed-4bad-8bad-0123456789ab';
  const joinBase = 'https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0';
  const contextOf = (json) => joinBase + '?context=' + json;
  check('organizer tenant: read from the URL-encoded context (Tid in any letter case), a double-encoded context, and a lower-case tid key',
    organizerTenantOf(contextOf('%7b%22Tid%22%3a%22' + theirs.toUpperCase() + '%22%2c%22Oid%22%3a%2233333333-3333-4333-8333-333333333333%22%7d')) === theirs &&
    organizerTenantOf(contextOf(encodeURIComponent(encodeURIComponent('{"Tid":"' + theirs + '"}')))) === theirs &&
    organizerTenantOf(contextOf(encodeURIComponent('{"tid":"' + theirs + '"}'))) === theirs);
  check('NEGATIVE CONTROL: no context, a garbled context, a Tid that is not a GUID, or not a URL at all → organizer tenant unknown',
    [joinBase, contextOf('%7bnot-json'), contextOf(encodeURIComponent('{"Tid":"not-a-guid"}')), contextOf(encodeURIComponent('["' + theirs + '"]')), 'not a url', '']
      .every((u) => organizerTenantOf(u) === null));
  check('caller tenant: the configured username matched case-insensitively (a decoy in another tenant skipped), an entry without an id never matches, an MSA id is the personal tenant',
    accountTenantFrom([{ id: 'decoy.' + theirs, username: 'someone@example.com' }, { id: 'oid.' + mine.toUpperCase(), email: 'Me@Example.com' }], 'me@example.com') === mine &&
    accountTenantFrom([{ email: 'me@example.com', name: 'Me', isDefault: true }], 'me@example.com') === null &&
    tenantOfHomeAccountId('00000000-0000-0000-2a3b-4c5d6e7f8091.' + PERSONAL_TENANT) === PERSONAL_TENANT && tenantOfHomeAccountId('no-tenant-here') === null &&
    callerTenant({ tenant: 'consumers', account: 'me@example.com' }).personal === true && callerTenant({ tenant: mine, account: 'me@example.com' }).id === mine);
  check('out of reach: a personal account → personal-account; another tenant → external-organizer:<tid>; NEGATIVE CONTROL: the same tenant, an unknown caller or an unknown organizer → looked up',
    meetingOutOfReach({ id: PERSONAL_TENANT, personal: true }, null) === PERSONAL_ACCOUNT && meetingOutOfReach({ id: mine, personal: false }, theirs) === 'external-organizer:' + theirs &&
    meetingOutOfReach({ id: mine, personal: false }, mine) === null && meetingOutOfReach({ id: null, personal: false }, theirs) === null &&
    meetingOutOfReach({ id: mine, personal: false }, null) === null && meetingOutOfReach(null, theirs) === null);

  // end to end against the fake server, through this very CLI
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'microsoft365-archive-selftest-'));
  try {
    const stub = path.join(tmp, 'stub-convert.sh');
    fs.writeFileSync(stub, '#!/bin/bash\nif [ "$1" = "--converter-id" ]; then echo "stub 1"; exit 0; fi\nprintf "# converted\\n\\n"; cat "$1"\n');
    const requestLog = path.join(tmp, 'requests.jsonl');
    const writeConfig = (name, fixtures, extra) => {
      const f = path.join(tmp, name + '.config');
      fs.writeFileSync(f, ['root=' + path.join(tmp, name), 'account=selftest@example.com', 'node=' + process.execPath,
        'server=' + (extra && extra.server ? extra.server : path.join(__dirname, 'fake-server.js')),
        'server_args=--fixtures ' + fixtures + (extra && extra.args ? ' ' + extra.args : ''), 'tenant=organizations', 'convert=' + stub].join('\n') + '\n');
      return f;
    };
    const cli = (args, extraEnv) => {
      const env = Object.assign({}, process.env, { MICROSOFT365_ARCHIVE_ALLOW_LOOPBACK_DOWNLOADS: '1', MICROSOFT365_ARCHIVE_FAKE_REQUEST_LOG: requestLog }, extraEnv || {});
      delete env.MICROSOFT365_ARCHIVE_CONFIG;
      const r = spawnSync(process.execPath, [__filename].concat(args), { encoding: 'utf8', timeout: 60000, env });
      return { rc: r.status, out: String(r.stdout || '') + String(r.stderr || ''), stdout: String(r.stdout || '') };
    };
    const window = ['--since', '2026-01-01T00:00:00Z', '--until', '2026-02-01T00:00:00Z'];
    const requests = () => (readText(requestLog) || '').split('\n').filter(Boolean).map((l) => JSON.parse(l));
    const folderOf = (root, ical) => { const h = shortHash(Buffer.from(ical, 'utf8')); return scanMeetingFolders(root).get(h); };
    const meetingFm = (root, ical) => { const rel = folderOf(root, ical); return rel ? parseFrontMatter(readText(path.join(root, rel, 'meeting.md'))) : null; };
    const art = (root, ical, name) => { const rel = folderOf(root, ical); return rel ? readText(path.join(root, rel, name)) : null; };

    // A: transcripts present, run twice
    const availableConfig = writeConfig('available', 'base,transcripts-available');
    const availableRoot = path.join(tmp, 'available');
    const first = cli(['run', '--config', availableConfig].concat(window));
    check('run 1 against the fake server exits 0', first.rc === 0, 'rc ' + first.rc + '\n' + first.out);
    const meCalls = requests().filter((r) => /^\/me\?/.test(r.url)).length;
    check('429 on /me was retried after Retry-After (run 1 alone sent /me twice)', meCalls === 2, meCalls + ' call(s)');
    const hashAfterFirstRun = fs.existsSync(availableRoot) ? treeHash(availableRoot) : '';
    const second = cli(['run', '--config', availableConfig].concat(window));
    const hashAfterSecondRun = fs.existsSync(availableRoot) ? treeHash(availableRoot) : '';
    check('run 2 exits 0 and changes zero bytes (tree sha256 equal, "written 0")', second.rc === 0 && hashAfterFirstRun && hashAfterFirstRun === hashAfterSecondRun && /written 0,/.test(second.out),
      'rc ' + second.rc + ' ' + hashAfterFirstRun + ' vs ' + hashAfterSecondRun + '\n' + second.out.split('\n').slice(-3).join('\n'));
    const reqs = requests();
    check('every sub-request the server received was a GET, and none touched /special, even once decoded (the chat links spell it three encoded ways)',
      reqs.length > 10 && reqs.every((r) => r.method === 'GET' && !/\/special/i.test(r.url) && !/\/special/i.test(String(decodedGraphPath(r.url)))),
      reqs.filter((r) => /special/i.test(String(decodedGraphPath(r.url)))).map((r) => r.url).join('\n') || reqs.length + ' requests');
    const specialLinks = art(availableRoot, 'ical-one-off-0001', 'links.md') || '';
    check('links.md records the encoded /special/ links as refused, never fetched', (specialLinks.match(/\| unsupported \| graph \|/g) || []).length === 3, specialLinks);
    check('the cancelled meeting was never looked up, the in-person event never archived', !reqs.some((r) => /meeting_cancelled/.test(r.url)) &&
      scanMeetingFolders(availableRoot).size === 3, 'folders: ' + scanMeetingFolders(availableRoot).size);
    const oneOffFolder = folderOf(availableRoot, 'ical-one-off-0001');
    check('folder name is <date>_<HHMM>_<slug>__<12 hex of sha256(iCalUId)>', oneOffFolder === 'meetings/2026/2026-01/2026-01-05_1500_quarterly-review-acme-co__' + shortHash(Buffer.from('ical-one-off-0001')), oneOffFolder);
    const oneOffTranscript = art(availableRoot, 'ical-one-off-0001', 'transcript.md') || '';
    const oneOffVtt = art(availableRoot, 'ical-one-off-0001', 'transcript.vtt') || '';
    check('transcript.md merges consecutive same-speaker cues (3 Alice cues in the vtt → 2 Alice turns)', (oneOffVtt.match(/<v Alice Adams>/g) || []).length === 3 &&
      (oneOffTranscript.match(/\*\*Alice Adams\*\*/g) || []).length === 2 && (oneOffTranscript.match(/\*\*Bob Brown\*\*/g) || []).length === 1 && oneOffTranscript.indexOf('Welcome everyone. Let us start with revenue.') >= 0, oneOffTranscript);
    const oneOffMeeting = meetingFm(availableRoot, 'ical-one-off-0001');
    check('NEGATIVE CONTROL: with the transcript present, meeting.md says available, not forbidden', oneOffMeeting && oneOffMeeting.artifacts && oneOffMeeting.artifacts.transcript === 'available', JSON.stringify(oneOffMeeting && oneOffMeeting.artifacts));
    const frontLines = (readText(path.join(availableRoot, oneOffFolder || '', 'meeting.md')) || '').split('\n---\n')[0].split('\n').slice(1);
    const topKeys = frontLines.filter((l) => /^[^\s]/.test(l)).map((l) => l.split(':')[0]);
    check('meeting.md front matter keeps the fixed key order', topKeys.join(',') === MEETING_KEYS.join(','), topKeys.join(','));
    const firstOccurrenceTranscript = art(availableRoot, 'ical-series-0002-occurrence-1', 'transcript.md') || '';
    const secondOccurrenceTranscript = art(availableRoot, 'ical-series-0002-occurrence-2', 'transcript.md') || '';
    check('recurring series: each transcript lands only in the occurrence whose window holds it', firstOccurrenceTranscript.indexOf('First weekly') >= 0 && firstOccurrenceTranscript.indexOf('Second weekly') < 0 &&
      secondOccurrenceTranscript.indexOf('Second weekly') >= 0 && secondOccurrenceTranscript.indexOf('First weekly') < 0 && (firstOccurrenceTranscript + secondOccurrenceTranscript).indexOf('Outside every window') < 0 &&
      !reqs.some((r) => /transcript-series-late/.test(r.url)), firstOccurrenceTranscript + '\n---\n' + secondOccurrenceTranscript);
    const firstOccurrence = meetingFm(availableRoot, 'ical-series-0002-occurrence-1') || { artifacts: {} };
    const secondOccurrence = meetingFm(availableRoot, 'ical-series-0002-occurrence-2') || { artifacts: {} };
    check('statuses: recording forbidden:needs … / linked from /Recordings; attendance available / not-organizer',
      oneOffMeeting.artifacts.recording === 'forbidden:needs OnlineMeetingRecording.Read.All' && firstOccurrence.artifacts.recording === 'linked' && secondOccurrence.artifacts.recording === 'none' &&
      oneOffMeeting.artifacts.attendance === 'available' && firstOccurrence.artifacts.attendance === 'not-organizer', JSON.stringify([oneOffMeeting.artifacts, firstOccurrence.artifacts, secondOccurrence.artifacts]));
    check('statuses: ai_notes license-required / none / available; chat available / forbidden:needs Chat.Read or Chat.ReadWrite',
      oneOffMeeting.artifacts.ai_notes === 'license-required' && firstOccurrence.artifacts.ai_notes === 'none' && secondOccurrence.artifacts.ai_notes === 'available' &&
      oneOffMeeting.artifacts.chat === 'available' && firstOccurrence.artifacts.chat === 'forbidden:needs Chat.Read or Chat.ReadWrite', JSON.stringify([oneOffMeeting.artifacts, firstOccurrence.artifacts, secondOccurrence.artifacts]));
    const chat = art(availableRoot, 'ical-one-off-0001', 'chat.md') || '';
    const links = art(availableRoot, 'ical-one-off-0001', 'links.md') || '';
    check('chat.md holds both pages, oldest first; links.md resolved Plan.docx (fetched) and left the web link external',
      chat.indexOf('Alice Adams') >= 0 && chat.indexOf('reading it now') > chat.indexOf('the plan') && /\| fetched \| sharepoint \| Plan\.docx \|/.test(links) &&
      /\| external \| web \|/.test(links), chat + '\n' + links);
    const notes = art(availableRoot, 'ical-one-off-0001', 'notes.md') || '';
    check('loop notes: .loop fetched through its 302 without auth and rendered; the old agenda not linked', oneOffMeeting.artifacts.loop_notes === 'available' &&
      notes.indexOf('Budget approved') >= 0 && notes.indexOf('p{color') < 0 && notes.indexOf('Old Agenda') < 0, notes);
    const cstatus = parseFrontMatter(readText(path.join(availableRoot, 'copilot', 'status.md'))) || {};
    check('copilot history probe records forbidden:app-only', cstatus.interaction_history === APP_ONLY, JSON.stringify(cstatus));
    check('copilot files: notes.txt mirrored and converted; the 70 MB deck is a link card, not downloaded',
      readText(path.join(availableRoot, 'copilot/files/raw/notes.txt')) === 'Copilot uploaded notes.\n' &&
      /# converted/.test(readText(path.join(availableRoot, 'copilot/files/notes.txt.md')) || '') && !fs.existsSync(path.join(availableRoot, 'copilot/files/raw/deck.pptx')) &&
      /larger than 50 MB/.test(readText(path.join(availableRoot, 'copilot/files/deck.pptx.md')) || ''));
    const index = readText(path.join(availableRoot, 'index.md')) || '';
    const dates = index.split('\n').filter((l) => /^\| 2026-/.test(l)).map((l) => l.split('|')[1].trim());
    check('index.md lists the meetings newest first and says what would unlock the refusals', dates.join(',') === '2026-01-19 10:00,2026-01-12 10:00,2026-01-05 15:00' &&
      /\*\*recording\*\* \(forbidden:needs OnlineMeetingRecording\.Read\.All\)/.test(index) && /\*\*ai notes\*\* \(license-required\)/.test(index) &&
      /\*\*copilot history\*\*/.test(index), dates.join(',') + '\n' + index);
    const st = cli(['status', '--config', availableConfig]);
    const statusRows = st.stdout.split('\n').filter(Boolean).map((l) => l.split('\t'));
    check('status: stdout is ONLY "<class>\\t<status>\\t<detail>" lines, every class a known one, the spaced app-only status one field',
      st.rc === 0 && statusRows.length >= 3 && statusRows.every((r) => r.length === 3 && STATUS_CLASSES.indexOf(r[0]) >= 0) &&
      statusRows.some((r) => r[0] === 'transcript' && r[1] === 'available') && statusRows.some((r) => r[0] === 'copilot_history' && r[1] === APP_ONLY), st.stdout);
    const noRun = cli(['status', '--root', path.join(tmp, 'never-run')]);
    check('NEGATIVE CONTROL: with no recorded run, status prints no class line (rc 0)', noRun.rc === 0 && noRun.stdout === '', noRun.out);
    const ex = cli(['explain', '--config', availableConfig]);
    check('explain names the ask for each refused class', ex.rc === 0 && /^ai_notes license-required: Assign a Microsoft 365 Copilot licence/m.test(ex.out), ex.out);

    // A again, but transcripts now refused: the change keeps the previous bytes in history/
    const oldMeeting = fs.readFileSync(path.join(availableRoot, oneOffFolder, 'meeting.md'));
    const refusedAgainConfig = path.join(tmp, 'available-refused.config');
    fs.writeFileSync(refusedAgainConfig, (readText(availableConfig) || '').replace('base,transcripts-available', 'base,transcripts-forbidden'));
    const third = cli(['run', '--config', refusedAgainConfig].concat(window));
    const hist = path.join(availableRoot, oneOffFolder, 'history', 'meeting.md.' + shortHash(oldMeeting));
    check('a changed artifact keeps its previous bytes at history/<name>.<12 hex sha256(old)>; the old transcript stays', third.rc === 0 &&
      fs.existsSync(hist) && fs.readFileSync(hist).equals(oldMeeting) && fs.existsSync(path.join(availableRoot, oneOffFolder, 'transcript.md')), third.out);

    // B: transcripts refused, a fresh root
    const refusedConfig = writeConfig('refused', 'base,transcripts-forbidden');
    const refusedRoot = path.join(tmp, 'refused');
    const refusedRun = cli(['run', '--config', refusedConfig].concat(window));
    const refusedOneOff = meetingFm(refusedRoot, 'ical-one-off-0001') || { artifacts: {} };
    const refusedSeries = meetingFm(refusedRoot, 'ical-series-0002-occurrence-1') || { artifacts: {} };
    check('a 403 fixture puts forbidden: in meeting.md front matter; the tenant switch reads tenant-disabled', refusedRun.rc === 0 &&
      /^forbidden:/.test(String(refusedOneOff.artifacts.transcript)) && refusedSeries.artifacts.transcript === 'tenant-disabled' && art(refusedRoot, 'ical-one-off-0001', 'transcript.md') === null,
      refusedRun.out + JSON.stringify(refusedOneOff.artifacts));

    // C: two occurrences whose windows both hold one .loop note that Graph refuses to convert — each links
    // it, and the calendar listing them in the opposite order changes zero bytes
    const marchWindow = ['--since', '2026-03-01T00:00:00Z', '--until', '2026-04-01T00:00:00Z'];
    const overlapConfig = writeConfig('overlap', 'base,notes-overlap');
    const overlapRoot = path.join(tmp, 'overlap');
    const overlapRun = cli(['run', '--config', overlapConfig].concat(marchWindow));
    const earlier = meetingFm(overlapRoot, 'ical-overlap-0001') || { artifacts: {} };
    const later = meetingFm(overlapRoot, 'ical-overlap-0002') || { artifacts: {} };
    check('a refused note in two overlapping windows is linked by BOTH occurrences, each with its notes.md',
      overlapRun.rc === 0 && earlier.artifacts.loop_notes === 'linked' && later.artifacts.loop_notes === 'linked' &&
      /Not converted: forbidden:/.test(art(overlapRoot, 'ical-overlap-0001', 'notes.md') || '') && /Not converted: forbidden:/.test(art(overlapRoot, 'ical-overlap-0002', 'notes.md') || ''),
      overlapRun.out + JSON.stringify([earlier.artifacts, later.artifacts]));
    const hashBeforeReorder = treeHash(overlapRoot);
    const reversedConfig = path.join(tmp, 'overlap-reversed.config');
    fs.writeFileSync(reversedConfig, (readText(overlapConfig) || '').replace('base,notes-overlap', 'base,notes-overlap,notes-overlap-reversed'));
    const reversedRun = cli(['run', '--config', reversedConfig].concat(marchWindow));
    check('the same calendar in the opposite order changes zero bytes ("written 0")', reversedRun.rc === 0 && treeHash(overlapRoot) === hashBeforeReorder && /written 0,/.test(reversedRun.out),
      reversedRun.out.split('\n').slice(-4).join('\n'));

    // D: whose tenant. fake-server.js models the server's tools only; this wrapper adds the real server's
    // --list-accounts flag, printing the fixtures' "accounts" (after a log line the engine must skip) and
    // counting each call in <request log>.cli.
    const accountServer = path.join(tmp, 'fake-server-with-account-cache.js');
    fs.writeFileSync(accountServer, ["'use strict';", "const fs = require('fs');", "const path = require('path');",
      'const fake = ' + JSON.stringify(path.join(__dirname, 'fake-server.js')) + ';',
      'const args = process.argv.slice(2);',
      "if (args.indexOf('--list-accounts') >= 0) {",
      "  const at = args.indexOf('--fixtures');",
      '  let accounts = [];',
      "  for (const n of (at >= 0 ? args[at + 1] || '' : '').split(',').filter(Boolean)) {",
      "    const d = JSON.parse(fs.readFileSync(path.join(path.dirname(fake), 'fixtures', n + '.json'), 'utf8'));",
      '    if (Array.isArray(d.accounts)) accounts = d.accounts;',
      '  }',
      "  if (process.env.MICROSOFT365_ARCHIVE_FAKE_REQUEST_LOG) fs.appendFileSync(process.env.MICROSOFT365_ARCHIVE_FAKE_REQUEST_LOG + '.cli', '--list-accounts\\n');",
      "  fs.writeSync(1, '[info] reading the token cache\\n' + JSON.stringify({ accounts }) + '\\n');",
      '} else {',
      '  require(fake);',
      '}', ''].join('\n'));
    const cliCalls = () => (readText(requestLog + '.cli') || '').split('\n').filter(Boolean).length;
    const reachesMeetings = (list) => list.filter((r) => /onlineMeetings/i.test(String(r.url)));
    const mayWindow = ['--since', '2026-05-01T00:00:00Z', '--until', '2026-06-01T00:00:00Z'];
    const juneWindow = ['--since', '2026-06-01T00:00:00Z', '--until', '2026-07-01T00:00:00Z'];
    const externalConfig = writeConfig('external', 'base,tenant-external', { server: accountServer });
    const externalRoot = path.join(tmp, 'external');
    let mark = requests().length;
    const cliMark = cliCalls();
    const externalRun = cli(['run', '--config', externalConfig].concat(mayWindow));
    const externalReqs = requests().slice(mark);
    const external = meetingFm(externalRoot, 'ical-external-0001') || { artifacts: {} };
    check('(a) a meeting organised in another tenant: its five onlineMeeting artifacts read external-organizer:<its tenant>, and the server saw ZERO onlineMeetings requests',
      externalRun.rc === 0 && ONLINE_MEETING_ARTIFACTS.every((a) => external.artifacts[a] === 'external-organizer:' + theirs) && external.online_meeting_id === null &&
      externalReqs.length > 0 && reachesMeetings(externalReqs).length === 0,
      externalRun.out + JSON.stringify(external.artifacts) + '\n' + reachesMeetings(externalReqs).map((r) => r.url).join('\n'));
    check('(a) the caller tenant was learned once, from --list-accounts (the decoy in the organizer\'s tenant skipped); the agenda in your own OneDrive still links',
      cliCalls() - cliMark === 1 && externalRun.out.indexOf('account tenant: ' + mine + " (from the server's --list-accounts)") >= 0 &&
      external.artifacts.loop_notes === 'linked' && /Client Steering Agenda\.docx/.test(art(externalRoot, 'ical-external-0001', 'notes.md') || ''),
      (cliCalls() - cliMark) + ' --list-accounts call(s)\n' + externalRun.out + JSON.stringify(external.artifacts));
    const externalIndex = readText(path.join(externalRoot, 'index.md')) || '';
    const externalExplain = cli(['explain', '--config', externalConfig]);
    check('index.md says what would unlock external-organizer (one line for the five classes), and so does explain',
      externalIndex.indexOf('- **transcript, recording, attendance, ai notes, chat** (external-organizer:' + theirs + '): ' + UNLOCK_ANY['external-organizer']) >= 0 &&
      externalExplain.rc === 0 && externalExplain.out.indexOf('transcript external-organizer:' + theirs + ': These live in the organizer\'s tenant. Ask the organizer to share') >= 0,
      externalIndex + '\n' + externalExplain.out);
    const externalHash = treeHash(externalRoot);
    const externalAgain = cli(['run', '--config', externalConfig].concat(mayWindow));
    check('a second external run changes zero bytes ("written 0")', externalAgain.rc === 0 && treeHash(externalRoot) === externalHash && /written 0,/.test(externalAgain.out),
      externalAgain.out.split('\n').slice(-3).join('\n'));

    const unknownConfig = writeConfig('tenant-unknown', 'base,tenant-external');
    const unknownRoot = path.join(tmp, 'tenant-unknown');
    mark = requests().length;
    const unknownRun = cli(['run', '--config', unknownConfig].concat(mayWindow));
    const unknownReqs = requests().slice(mark);
    const unknownExternal = meetingFm(unknownRoot, 'ical-external-0001') || { artifacts: {} };
    const unknownState = readJson(path.join(stateDir(unknownRoot), 'status.json')) || {};
    const unknownTranscript = (unknownState.classes || {}).transcript || {};
    check('NEGATIVE CONTROL: with the caller\'s tenant unknown (a server with no --list-accounts), the same meeting is looked up as before, and its error keeps the Graph message',
      unknownRun.rc === 0 && /account tenant: unknown/.test(unknownRun.out) &&
      unknownReqs.filter((r) => /^\/me\/onlineMeetings\?/.test(r.url) && /meeting_external/.test(r.url)).length === 1 && unknownExternal.artifacts.transcript === 'error:404' &&
      /looking the meeting up: HTTP 404 itemNotFound: fake server: no fixture for GET \/me\/onlineMeetings/.test(String(unknownTranscript.detail)),
      unknownRun.out + JSON.stringify(unknownExternal.artifacts) + '\n' + JSON.stringify(unknownTranscript));

    const juneConfig = writeConfig('same-tenant', 'base,tenant-external', { server: accountServer });
    const juneRoot = path.join(tmp, 'same-tenant');
    mark = requests().length;
    const juneRun = cli(['run', '--config', juneConfig].concat(juneWindow));
    const juneReqs = requests().slice(mark);
    const same = meetingFm(juneRoot, 'ical-same-tenant-0001') || { artifacts: {} };
    const noContext = meetingFm(juneRoot, 'ical-no-context-0001') || { artifacts: {} };
    check('(b) NEGATIVE CONTROL: a join URL in the caller\'s own tenant (its Tid in upper case) is looked up, and its transcript resolves as before',
      juneRun.rc === 0 && same.online_meeting_id === 'online-meeting-same-tenant' && same.artifacts.transcript === 'available' &&
      /this transcript is ours to read/.test(art(juneRoot, 'ical-same-tenant-0001', 'transcript.md') || ''), juneRun.out + JSON.stringify(same));
    check('(d) a join URL with no context falls back to the lookup (one request for it; its online meeting found)',
      juneReqs.filter((r) => /^\/me\/onlineMeetings\?/.test(r.url) && /meeting_nocontext/.test(r.url)).length === 1 &&
      noContext.online_meeting_id === 'online-meeting-no-context' && noContext.artifacts.transcript === 'none', juneRun.out + JSON.stringify(noContext));
    const attendanceClass = ((readJson(path.join(stateDir(juneRoot), 'status.json')) || {}).classes || {}).attendance || {};
    const juneStatus = cli(['status', '--config', juneConfig]);
    check('an error:<status> keeps the whole Graph message, in .state/status.json and in status\'s detail',
      same.artifacts.attendance === 'error:400' &&
      String(attendanceClass.detail).indexOf('error:400 — HTTP 400 BadRequest/InvalidRequest: selftest-attendance-400: the attendance report request was malformed.') >= 0 &&
      !!attendanceClass.errors && /selftest-attendance-400/.test(String(attendanceClass.errors['error:400'])) &&
      juneStatus.stdout.split('\n').some((l) => /^attendance\terror:400\t.*selftest-attendance-400/.test(l)), JSON.stringify(attendanceClass) + '\n' + juneStatus.stdout);

    const personalConfig = writeConfig('personal', 'base,tenant-external,tenant-personal', { server: accountServer });
    const personalRoot = path.join(tmp, 'personal');
    mark = requests().length;
    const personalRun = cli(['run', '--config', personalConfig].concat(juneWindow));
    const personalReqs = requests().slice(mark);
    const personalMeetings = ['ical-same-tenant-0001', 'ical-no-context-0001'].map((i) => meetingFm(personalRoot, i) || { artifacts: {} });
    const personalCopilot = parseFrontMatter(readText(path.join(personalRoot, 'copilot', 'status.md'))) || {};
    check('(c) a personal account: every meeting\'s five artifacts and copilot_history read personal-account; ZERO onlineMeetings and ZERO interactionHistory requests',
      personalRun.rc === 0 && personalMeetings.every((m) => ONLINE_MEETING_ARTIFACTS.every((a) => m.artifacts[a] === PERSONAL_ACCOUNT)) &&
      personalCopilot.interaction_history === PERSONAL_ACCOUNT && personalReqs.length > 0 && !personalReqs.some((r) => /onlineMeetings|interactionHistory/i.test(String(r.url))),
      personalRun.out + JSON.stringify(personalMeetings.map((m) => m.artifacts)) + JSON.stringify(personalCopilot) + '\n' +
      personalReqs.filter((r) => /onlineMeetings|interactionHistory/i.test(String(r.url))).map((r) => r.url).join('\n'));
    const personalIndex = readText(path.join(personalRoot, 'index.md')) || '';
    const personalExplain = cli(['explain', '--config', personalConfig]);
    check('index.md and explain carry the personal-account asks — the meetings\' one, and Copilot history\'s own',
      personalIndex.indexOf('- **transcript, recording, attendance, ai notes, chat** (personal-account): ' + UNLOCK_ANY['personal-account']) >= 0 &&
      personalIndex.indexOf('- **copilot history** (personal-account): ' + UNLOCK.copilot_history['personal-account']) >= 0 &&
      /^chat personal-account: Teams meeting recordings, transcripts, attendance and AI notes are not available to personal Microsoft accounts/m.test(personalExplain.out) &&
      /^copilot_history personal-account: The Copilot interaction history API serves work or school accounts only/m.test(personalExplain.out),
      personalIndex + '\n' + personalExplain.out);

    // copilot-import into A, twice; an unknown CSV header is refused
    const firstImport = cli(['copilot-import', path.join(__dirname, 'fixtures', 'copilot-export.json'), '--config', availableConfig]);
    const sessions = fs.existsSync(path.join(availableRoot, 'copilot/sessions')) ? fs.readdirSync(path.join(availableRoot, 'copilot/sessions')).filter((f) => /\.md$/.test(f)) : [];
    const session = sessions.length ? readText(path.join(availableRoot, 'copilot/sessions', sessions[0])) : '';
    check('copilot-import writes one session, answer text from the adaptive card, links resolved (fetched / denied / external)', firstImport.rc === 0 && sessions.length === 1 &&
      sessions[0] === '2026-01-07_summarise-the-plan-for-the-acme-review__' + shortHash(Buffer.from('session-alpha')) + '.md' &&
      session.indexOf('The plan has three phases') >= 0 && /\| fetched \| sharepoint \| Plan\.docx/.test(session) && /\| denied \| sharepoint \|/.test(session) &&
      /\| external \| web \|/.test(session), firstImport.out + '\n' + session);
    const hashAfterImport = treeHash(availableRoot);
    const secondImport = cli(['copilot-import', path.join(__dirname, 'fixtures', 'copilot-export.json'), '--config', availableConfig]);
    check('a second identical import changes zero bytes', secondImport.rc === 0 && treeHash(availableRoot) === hashAfterImport && /written 0,/.test(secondImport.out), secondImport.out);
    const csv = path.join(tmp, 'unknown.csv');
    fs.writeFileSync(csv, 'Colour,Flavour\nred,sweet\n');
    const bad = cli(['copilot-import', csv, '--config', availableConfig]);
    check('an unrecognised CSV header exits 2 naming the columns seen', bad.rc === 2 && /Colour, Flavour/.test(bad.out), bad.out);

    // failure classes
    const auth = cli(['run', '--config', writeConfig('auth', 'base', { args: '--auth-dead' })].concat(window));
    check('an expired sign-in exits 3 and prints the one --login command', auth.rc === 3 && /MS365_MCP_TENANT_ID=organizations .*--login/.test(auth.out), auth.out);
    const partial = cli(['run', '--config', writeConfig('partial', 'base,transcripts-available,partial')].concat(window));
    const partialRoot = path.join(tmp, 'partial');
    check('a failed tool call leaves that meeting unwritten, the rest written, and exits 4', partial.rc === 4 && !folderOf(partialRoot, 'ical-one-off-0001') &&
      !!folderOf(partialRoot, 'ical-series-0002-occurrence-1') && !fs.existsSync(path.join(stateDir(partialRoot), 'last-success')), partial.out);
    const dead = cli(['run', '--config', writeConfig('dead', 'base', { server: path.join(tmp, 'no-such-server.js') })].concat(window));
    check('a server that cannot start exits 5', dead.rc === 5, dead.out);
    const usage = cli(['run', '--root', path.join(tmp, 'usage')]);
    check('a config without server/account exits 2; --version answers exactly', usage.rc === 2 && cli(['--version']).out === VERSION_LINE + '\n', usage.out);

    // a root inside a sync client's tree, under a sandbox HOME — spelled as on disk, spelled in another
    // letter case (the same folder on a case-insensitive volume), and through copilot-import
    const fakeHome = path.join(tmp, 'fakehome');
    const synced = path.join(fakeHome, 'Library', 'CloudStorage', 'OneDrive-Contoso');
    mkdirp(synced);
    const inHome = { HOME: fakeHome };
    const serverArgs = ['--server', path.join(__dirname, 'fake-server.js'), '--account', 'selftest@example.com'];
    const exact = cli(['run', '--root', path.join(synced, 'archive-exact')].concat(serverArgs, window), inHome);
    const folded = cli(['run', '--root', path.join(fakeHome, 'library', 'cloudstorage', 'onedrive-contoso', 'archive-lower')].concat(serverArgs, window), inHome);
    const imported = cli(['copilot-import', path.join(__dirname, 'fixtures', 'copilot-export.json'), '--root', path.join(synced, 'import-root')], inHome);
    check('a root under CloudStorage is refused (rc 2) as spelled on disk, in another letter case, and by copilot-import — nothing is created there',
      exact.rc === 2 && folded.rc === 2 && imported.rc === 2 && fs.readdirSync(synced).length === 0,
      [exact.rc, folded.rc, imported.rc].join(' ') + ' ' + fs.readdirSync(synced).join(',') + '\n' + folded.out + imported.out);
    const outside = cli(['copilot-import', path.join(__dirname, 'fixtures', 'copilot-export.json'), '--root', path.join(fakeHome, 'Archive')], inHome);
    check('NEGATIVE CONTROL: the same import into a root beside Library is admitted (rc 0)', outside.rc === 0, outside.out);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
  say('archive.js selftest: ' + passed + ' passed, ' + failed + ' failed');
  return failed;
}

// ── the command line ──────────────────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const flags = {};
  const positional = [];
  const valued = ['config', 'root', 'account', 'server', 'since', 'until'];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--version' || a === '--selftest' || a === '--help' || a === '-h') { flags[a.replace(/^-+/, '')] = true; continue; }
    const m = /^--([a-z]+)(?:=(.*))?$/.exec(a);
    if (m && valued.indexOf(m[1]) >= 0) {
      if (m[2] !== undefined) flags[m[1]] = m[2];
      else if (i + 1 < argv.length) flags[m[1]] = argv[++i];
      else throw new ArchiveError('USAGE', a + ' needs a value');
      continue;
    }
    if (a.startsWith('-')) throw new ArchiveError('USAGE', 'unknown option ' + a);
    positional.push(a);
  }
  return { flags, positional };
}

const USAGE = 'usage: archive.js --version | --selftest | run [--since ISO] [--until ISO] | status | explain | copilot-import <file>\n' +
  '       options: --config <file> (or MICROSOFT365_ARCHIVE_CONFIG), --root <dir>, --account <upn>, --server <index.js>\n';

async function main(argv) {
  let parsed;
  try { parsed = parseArgs(argv); } catch (e) { process.stderr.write(e.message + '\n' + USAGE); return EXIT.usage; }
  const { flags, positional } = parsed;
  if (flags.version) { process.stdout.write(VERSION_LINE + '\n'); return EXIT.ok; }
  if (flags.selftest) return (await selftest()) === 0 ? EXIT.ok : 1;
  if (flags.help) { process.stdout.write(USAGE); return EXIT.ok; }
  const cmd = positional[0];
  try {
    if (cmd === 'run' && positional.length === 1) return await commandRun(loadConfig(flags), flags);
    if (cmd === 'status' && positional.length === 1) return commandStatus(loadConfig(flags));
    if (cmd === 'explain' && positional.length === 1) return commandExplain(loadConfig(flags));
    if (cmd === 'copilot-import' && positional.length === 2) return await commandImport(loadConfig(flags), positional[1]);
  } catch (e) {
    if (e.code === 'USAGE') { process.stderr.write(e.message + '\n'); return EXIT.usage; }
    if (e.code === 'AUTH_DEAD') {
      const advice = signInAdvice(e.message);
      process.stdout.write('sign-in needed (' + e.message + ').' + (advice ? ' ' + advice : '') + ' Run:\n' + loginCommand(loadConfig(flags), e.message) + '\n');
      return EXIT.authDead;
    }
    if (e.code === 'SERVER_FAILED') { process.stdout.write('the Microsoft 365 server failed: ' + e.message + '\n'); return EXIT.serverFailed; }
    if (e.code === 'LOCKED') { process.stdout.write(e.message + '\n'); return EXIT.partial; }
    process.stdout.write('failed: ' + (e.code ? e.message : (e && e.stack) || e) + '\n');
    return EXIT.partial;
  }
  process.stderr.write(USAGE);
  return EXIT.usage;
}

module.exports = { guardToolCall, relativeFromLink, deriveStatus, parseFrontMatter, loadConfig, McpClient, Graph, listDriveFolders, VERSION_LINE };

if (require.main === module) {
  main(process.argv.slice(2)).then((rc) => { process.exitCode = rc; }, (e) => {
    process.stdout.write('failed: ' + ((e && e.stack) || e) + '\n');
    process.exitCode = EXIT.partial;
  });
}
