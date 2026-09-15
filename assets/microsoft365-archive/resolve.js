'use strict';
// resolve.js — the Microsoft 365 archive's link resolver: canonicalise a URL, classify it, and walk the
// links found in chats, Copilot answers and meeting notes breadth-first through Microsoft Graph, read-only.
// No npm dependency and no I/O of its own: every Graph request goes through the graphGet the engine injects.
//
// Exports (the engine, archive.js, depends on exactly these):
//   normalizeUrl(u)                   canonical string, or null when u is not a URL. Unwraps Outlook and Teams
//                                     safelinks, decodes HTML entities, drops the fragment and tracking
//                                     parameters (utm_*, EntityRepresentationId, web=1, and on SharePoint and
//                                     OneDrive hosts also csf, e, mobileredirect, action, wdOrigin, referrer,
//                                     referrerScenario), lowercases the host, sorts the query.
//   classifyUrl(u)                    {kind, url, route, …}; kind is one of sharepoint · onedrive-business ·
//                                     onedrive-consumer · teams · stream · loop · graph · web · unsupported.
//                                     route says how it is fetched: shares · drive-item · graph · object-url · none.
//   sharesId(url)                     'u!' + base64url(url) without padding — the /shares/{id} token.
//   resolveAll(roots, graphGet, opts) async; see below.
//   selftest(write)                   async; runs the fixtures below; resolves to the number of failures.
//
// resolveAll(roots, graphGet, opts) -> Promise<records>
//   roots     URL strings (or {url, parent}) found in a root source; each starts at depth 0.
//   graphGet  (relativePath, headers) -> Promise<{status, headers, body}>, supplied by the engine, which
//             enforces its own GET-only guard. resolveAll never sends a Prefer header, and in particular never
//             Prefer: redeemSharingLink — that grants the caller durable access to the item, an ACL write.
//             A graphGet that throws an error whose .code is 'AUTH_DEAD' (or whose .fatal is true) aborts the
//             walk: the rejection is passed through. Any other throw is recorded as that node's error.
//   opts      maxDepth (default 3): a node at depth d is resolved when d <= maxDepth; roots are depth 0.
//             maxNodes (default 200): the walk stops once this many records exist.
//             tenantHosts: the home tenant's SharePoint hosts; a 403 on any other *.sharepoint.com host is
//             labelled a foreign tenant in its detail.
//             expand(record) -> urls[] (sync or async): extra outlinks for a fetched record, e.g. links the
//             engine found inside a converted document. Chat and channel messages are expanded built-in.
//   records   [{url, key, status, item, depth, parent, kind, detail, aliases}] in discovery order, where
//             status is fetched · denied · external · unsupported · error. The array also carries
//             .skipped = {depth, budget}: outlinks not followed because of maxDepth or maxNodes.
//   Rules     BFS. Dedupe on the canonical key: sharepointIds (site, list, listItemUniqueId), then
//             driveId + itemId, then the normalised URL. A folder's children are listed ONE level only —
//             a child folder is recorded but never listed, so a link to a library cannot walk all of it.
//             Plain web links are recorded as external and never fetched (v1). A 403 is denied, never gone:
//             /shares answers one generic 403 for missing, unshared, foreign-tenant and non-SharePoint alike.
//
// Self-test:  node resolve.js --selftest    (rc 0 iff every fixture passes)

const GRAPH_V1 = 'https://graph.microsoft.com/v1.0/';
const DRIVE_ITEM_SELECT = 'id,name,size,file,folder,parentReference,sharepointIds,eTag,cTag,lastModifiedDateTime,webUrl';
const compareText = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

// ── canonical URLs ────────────────────────────────────────────────────────────────────────────────
const URL_ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };
function decodeUrlEntities(s) {
  return s.replace(/&(#\d{1,7}|#[xX][0-9a-fA-F]{1,6}|amp|lt|gt|quot|apos|nbsp);/g, (whole, body) => {
    if (body[0] !== '#') return URL_ENTITIES[body];
    const cp = body[1] === 'x' || body[1] === 'X' ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
    return cp > 0 && cp <= 0x10FFFF && !(cp >= 0xD800 && cp <= 0xDFFF) ? String.fromCodePoint(cp) : whole;
  });
}

function trimTrailingPunctuation(s) {
  let u = s;
  for (;;) {
    const before = u;
    u = u.replace(/[.,;:!?'"*]+$/, '');
    if (u.endsWith(')') && (u.match(/\(/g) || []).length < (u.match(/\)/g) || []).length) u = u.slice(0, -1);
    if (u.endsWith(']') && (u.match(/\[/g) || []).length < (u.match(/\]/g) || []).length) u = u.slice(0, -1);
    if (u === before) return u;
  }
}

function isSafelinkWrapper(url) {
  const host = url.hostname;
  return /(^|\.)safelinks\.protection\.outlook\.com$/.test(host) ||
    (host === 'statics.teams.cdn.office.net' && /safelinks/i.test(url.pathname));
}

// prepareUrl — a WHATWG URL for u with entities decoded, safelinks and an onenote: prefix unwrapped, a
// Copilot [^n^] citation suffix and trailing sentence punctuation removed, and the fragment dropped.
function prepareUrl(u, unwrapDepth) {
  if (u == null) return null;
  let s = decodeUrlEntities(String(u)).trim().replace(/^<(.*)>$/, '$1').replace(/\[\^\d+\^\]$/, '');
  s = trimTrailingPunctuation(s);
  if (/^onenote:https?:/i.test(s)) s = s.slice('onenote:'.length);
  if (!s) return null;
  let url;
  try { url = new URL(s); } catch (e) { return null; }
  if ((url.protocol === 'https:' || url.protocol === 'http:') && isSafelinkWrapper(url) && unwrapDepth < 4) {
    const inner = url.searchParams.get('url');
    if (inner) return prepareUrl(inner, unwrapDepth + 1);
  }
  url.hash = '';
  return url;
}

const isMicrosoftFileHost = (host) => /\.sharepoint(-df)?\.com$/.test(host) || host === 'onedrive.live.com' ||
  host === '1drv.ms' || /(^|\.)microsoftpersonalcontent\.com$/.test(host);
const MICROSOFT_VIEW_PARAMS = new Set(['csf', 'e', 'mobileredirect', 'action', 'wdorigin', 'referrer', 'referrerscenario']);
// %XX of an unreserved character (but never '.', so no dot-segment can appear) is decoded; others uppercased.
const normalizePercent = (path) => path.replace(/%([0-9a-fA-F]{2})/g, (m, hex) => {
  const c = String.fromCharCode(parseInt(hex, 16));
  return /[A-Za-z0-9\-_~]/.test(c) ? c : '%' + hex.toUpperCase();
});
const encodeQueryPart = (s) => encodeURIComponent(s).replace(/%3A/g, ':').replace(/%2F/g, '/').replace(/%40/g, '@').replace(/%2C/g, ',');

function normalizeUrl(u) {
  const url = prepareUrl(u, 0);
  if (!url) return null;
  if (url.protocol !== 'https:' && url.protocol !== 'http:') return url.href; // mailto:, tel:, … scheme lowercased
  const host = url.hostname;
  const fileHost = isMicrosoftFileHost(host);
  const kept = [];
  for (const [k, v] of url.searchParams) {
    const lk = k.toLowerCase();
    if (lk.startsWith('utm_') || lk === 'entityrepresentationid' || (lk === 'web' && v === '1')) continue;
    if (fileHost && MICROSOFT_VIEW_PARAMS.has(lk)) continue;
    kept.push([k, v]);
  }
  kept.sort((a, b) => compareText(a[0], b[0]) || compareText(a[1], b[1]));
  let path = normalizePercent(url.pathname);
  if (fileHost && path.length > 1) path = path.replace(/\/+$/, '') || '/';
  const query = kept.length ? '?' + kept.map(([k, v]) => encodeQueryPart(k) + '=' + encodeQueryPart(v)).join('&') : '';
  return url.protocol + '//' + host + (url.port ? ':' + url.port : '') + path + query;
}

// ── /shares token ─────────────────────────────────────────────────────────────────────────────────
function sharesId(url) {
  return 'u!' + Buffer.from(String(url), 'utf8').toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
}

// ── classification ────────────────────────────────────────────────────────────────────────────────
// One Graph path segment built from a URL-borne id. '.', '..', or anything carrying a slash, whitespace,
// '#' or '%' is refused (null) rather than encoded, so no id from a link can steer the path elsewhere.
function pathSegment(id) {
  const s = String(id == null ? '' : id);
  if (!s || s === '.' || s === '..' || /[/\\\s#%?]/.test(s)) return null;
  return encodeURIComponent(s).replace(/%3A/g, ':').replace(/%40/g, '@').replace(/%21/g, '!');
}
const encodeServerPath = (p) => p.split('/').map((seg) => encodeURIComponent(seg)).join('/');
function paramCaseless(url, name) {
  const want = name.toLowerCase();
  for (const [k, v] of url.searchParams) if (k.toLowerCase() === want) return v;
  return null;
}
function safeDecode(s) { try { return decodeURIComponent(s); } catch (e) { return s; } }

const TEAMS_HOSTS = new Set(['teams.microsoft.com', 'teams.cloud.microsoft', 'teams.live.com']);
const MEETING_REASON = 'meeting link: harvested by the meetings pipeline, not by the link resolver';

function classifyTeams(url, normalized) {
  const segs = url.pathname.split('/').filter(Boolean).map(safeDecode);
  const teams = (fields) => Object.assign({ kind: 'teams', url: normalized }, fields);
  const unsupported = (teamsType, reason) => teams({ teamsType, route: 'none', reason });
  if (segs[0] === 'meet' || (segs[0] === 'l' && (segs[1] === 'meetup-join' || segs[1] === 'meeting'))) {
    const eventId = paramCaseless(url, 'eventId');
    return unsupported('meeting', MEETING_REASON + (eventId ? ' (event ' + eventId + ')' : ''));
  }
  if (segs[0] !== 'l') return unsupported('other', 'Teams link of an unrecognised shape');
  const type = segs[1];
  const groupId = paramCaseless(url, 'groupId');
  if (type === 'message' && segs[2] && segs[3]) {
    const thread = pathSegment(segs[2]);
    const message = pathSegment(segs[3]);
    if (!thread || !message) return unsupported('message', 'Teams message link with an unusable id');
    if (groupId) {
      const team = pathSegment(groupId);
      const parent = paramCaseless(url, 'parentMessageId');
      const parentSeg = parent && parent !== segs[3] ? pathSegment(parent) : null;
      if (!team) return unsupported('channel-message', 'Teams channel link with an unusable group id');
      const base = '/teams/' + team + '/channels/' + thread + '/messages/';
      return teams({ teamsType: 'channel-message', route: 'graph', teamId: groupId, channelId: segs[2], messageId: segs[3],
        graphPath: parentSeg ? base + parentSeg + '/replies/' + message : base + message });
    }
    return teams({ teamsType: 'chat-message', route: 'graph', chatId: segs[2], messageId: segs[3], graphPath: '/chats/' + thread + '/messages/' + message });
  }
  if (type === 'chat' && segs[2] && /^19:/.test(segs[2])) {
    const chat = pathSegment(segs[2]);
    return chat ? teams({ teamsType: 'chat', route: 'graph', chatId: segs[2], graphPath: '/chats/' + chat }) : unsupported('chat', 'Teams chat link with an unusable id');
  }
  if (type === 'channel' && segs[2] && groupId) {
    const team = pathSegment(groupId);
    const channel = pathSegment(segs[2]);
    if (team && channel) return teams({ teamsType: 'channel', route: 'graph', teamId: groupId, channelId: segs[2], graphPath: '/teams/' + team + '/channels/' + channel });
  }
  if (type === 'team' && groupId && pathSegment(groupId)) {
    return teams({ teamsType: 'team', route: 'graph', teamId: groupId, graphPath: '/teams/' + pathSegment(groupId) });
  }
  if (type === 'file') {
    const objectUrl = paramCaseless(url, 'objectUrl');
    if (objectUrl) return teams({ teamsType: 'file', route: 'object-url', objectUrl });
  }
  return unsupported(type || 'other', 'Teams link of an unrecognised shape');
}

function classifyUrl(u) {
  const url = prepareUrl(u, 0);
  const normalized = normalizeUrl(u);
  if (!url || normalized === null) return { kind: 'unsupported', url: null, route: 'none', reason: 'not a URL' };
  if (url.protocol !== 'https:' && url.protocol !== 'http:') {
    return { kind: 'unsupported', url: normalized, route: 'none', reason: url.protocol.slice(0, -1) + ': links are recorded, never fetched' };
  }
  const host = url.hostname;
  const path = url.pathname;
  const decodedPath = safeDecode(path);

  if (host === 'graph.microsoft.com') {
    const m = /^\/(v1\.0|beta)(\/.*)$/.exec(path);
    if (!m) return { kind: 'graph', url: normalized, route: 'none', reason: 'Graph URL without a version' };
    if (m[1] !== 'v1.0') return { kind: 'graph', url: normalized, route: 'none', version: m[1], reason: 'Graph beta: the archive reads v1.0 only' };
    return { kind: 'graph', url: normalized, route: 'graph', version: m[1], graphPath: m[2] + url.search };
  }
  if (/\.sharepoint(-df)?\.com$/.test(host)) {
    const business = /-my\.sharepoint(-df)?\.com$/.test(host) ? 'onedrive-business' : 'sharepoint';
    if (/^\/contentstorage\/CSP_/i.test(path)) {
      return { kind: 'loop', url: normalized, route: 'shares', fetchUrl: url.href, container: 'sharepoint-embedded' };
    }
    // stream.aspx?id=<folder> gives 400 and Forms/All.aspx?id= gives 403 (measured), while the plain path form
    // of the same item resolves — so both are rewritten to https://<host><decoded server-relative path>.
    const viewTarget = /\/_layouts\/15\/stream\.aspx$/i.test(path) ? paramCaseless(url, 'id')
      : /\/Forms\/[^/]+\.aspx$/i.test(path) ? (paramCaseless(url, 'id') || paramCaseless(url, 'RootFolder')) : null;
    const isStream = /\/_layouts\/15\/stream\.aspx$/i.test(path);
    if (viewTarget && viewTarget[0] === '/') {
      return { kind: isStream ? 'stream' : business, url: normalized, route: 'shares', fetchUrl: url.origin + encodeServerPath(viewTarget),
        rewrittenFrom: isStream ? 'stream.aspx' : 'library view' };
    }
    const out = { kind: isStream ? 'stream' : business, url: normalized, route: 'shares', fetchUrl: url.href };
    const short = /^\/:([a-z]):\/([rgs])\//i.exec(path);
    if (short) { out.shortLinkType = short[1].toLowerCase(); out.shortLinkForm = short[2].toLowerCase(); }
    return out;
  }
  if (host === 'onedrive.live.com') {
    const cid = paramCaseless(url, 'cid');
    const id = paramCaseless(url, 'id');
    // The legacy consumer webUrl Graph itself returns: /shares answers 403 serviceReadOnly for it (measured),
    // while the direct drive-item path answers 200.
    if (cid && id && /^[0-9A-Fa-f]{1,32}$/.test(cid) && /^[0-9A-Fa-f]{1,32}![0-9A-Za-z._-]{1,64}$/.test(id)) {
      return { kind: 'onedrive-consumer', url: normalized, route: 'drive-item', driveId: cid, itemId: id, legacy: true };
    }
    return { kind: 'onedrive-consumer', url: normalized, route: 'shares', fetchUrl: url.href };
  }
  if (host === '1drv.ms' || /(^|\.)microsoftpersonalcontent\.com$/.test(host)) {
    return { kind: 'onedrive-consumer', url: normalized, route: 'shares', fetchUrl: url.href };
  }
  if (TEAMS_HOSTS.has(host)) return classifyTeams(url, normalized);
  if (host === 'microsoft.teams.com') {
    // Copilot's contextReference pseudo-URL: not fetchable itself, but it names the chat thread.
    const m = /^\/threads\/(19:[^/]+)$/.exec(decodedPath);
    const chat = m && pathSegment(m[1]);
    if (chat) return { kind: 'teams', url: normalized, teamsType: 'thread', route: 'graph', chatId: m[1], graphPath: '/chats/' + chat };
    return { kind: 'teams', url: normalized, teamsType: 'other', route: 'none', reason: 'Copilot context reference of an unrecognised shape' };
  }
  if (host === 'loop.cloud.microsoft' || host === 'loop.microsoft.com' || /\.loop\.microsoft\.com$/.test(host)) {
    // Loop workspaces live in SharePoint Embedded: /shares reaches them only with FileStorageContainer.Selected.
    return { kind: 'loop', url: normalized, route: 'shares', fetchUrl: url.href, container: 'sharepoint-embedded' };
  }
  if (/(^|\.)microsoftstream\.com$/.test(host)) {
    return { kind: 'stream', url: normalized, route: 'none', legacy: true, reason: 'Microsoft Stream (Classic) is retired; its links no longer resolve' };
  }
  return { kind: 'web', url: normalized, route: 'none', reason: 'plain web link: recorded, not fetched' };
}

// ── the walk ──────────────────────────────────────────────────────────────────────────────────────
// The same rules the engine's GET-only guard enforces; checked here too, so a path this module builds can
// never be the one the guard has to catch.
// The path part is judged twice: as written, and as Graph routes it — every %XX decoded until nothing
// changes — so an encoded letter or slash ('spec%69al', 'drive%2Fspecial') cannot reach /special/.
function decodedPathPart(p) {
  let s = String(p).split('?')[0];
  if (/%(?![0-9A-Fa-f]{2})/.test(s)) return null;
  for (let round = 0; round < 8; round++) {
    const next = s.replace(/%([0-9A-Fa-f]{2})/g, (m, hex) => String.fromCharCode(parseInt(hex, 16)));
    if (next === s) return s;
    s = next;
  }
  return null;
}
const SPECIAL_SEGMENT = /\/special(\/|\?|$|:|;)/i;
const pathIsSafe = (p) => {
  if (!(typeof p === 'string' && p[0] === '/' && p.indexOf('://') < 0 && p.indexOf('..') < 0 &&
    !/%2e/i.test(p) && p.indexOf('#') < 0 && !/\s/.test(p) && p.indexOf('\\') < 0 && !SPECIAL_SEGMENT.test(p.split('?')[0]))) return false;
  const decoded = decodedPathPart(p);
  return decoded !== null && decoded.indexOf('..') < 0 && decoded.indexOf('\\') < 0 && !SPECIAL_SEGMENT.test(decoded);
};

function driveItemKey(item) {
  if (!item || typeof item !== 'object') return null;
  const s = item.sharepointIds;
  if (s && s.siteId && s.listId && s.listItemUniqueId) return ('spo:' + s.siteId + ':' + s.listId + ':' + s.listItemUniqueId).toLowerCase();
  const driveId = item.parentReference && item.parentReference.driveId;
  return driveId && item.id ? 'drive:' + driveId + ':' + item.id : null; // drive ids are case-sensitive base64
}

function canonicalKey(c, body) {
  if (!body || typeof body !== 'object') return null;
  if (c.route === 'shares' || c.route === 'drive-item') return driveItemKey(body);
  if (c.kind === 'teams') {
    if (c.teamsType === 'chat-message') return 'chat:' + c.chatId + ':message:' + (body.id || c.messageId);
    if (c.teamsType === 'channel-message') return 'channel:' + c.teamId + ':' + c.channelId + ':message:' + (body.id || c.messageId);
    if (c.teamsType === 'chat' || c.teamsType === 'thread') return 'chat:' + c.chatId;
    if (c.teamsType === 'channel') return 'channel:' + c.teamId + ':' + c.channelId;
    if (c.teamsType === 'team') return 'team:' + c.teamId;
  }
  if (c.kind === 'graph') return 'graph:' + c.graphPath;
  return null;
}

function graphErrorText(res) {
  const b = res.body;
  const e = b && typeof b === 'object' && b.error ? b.error : null;
  if (!e) return typeof b === 'string' && b ? b.slice(0, 200) : 'no error body';
  const inner = e.innerError || e.innererror || {};
  return ((e.code || 'error') + (inner.code ? '/' + inner.code : '') + ': ' + String(e.message || '')).replace(/\s+/g, ' ').slice(0, 300);
}

// Outlinks of a chat or channel message: <a href> in the body, reference attachments, Loop components.
function chatMessageLinks(message) {
  const out = [];
  const html = message && message.body && typeof message.body.content === 'string' ? message.body.content : '';
  const re = /\bhref\s*=\s*(?:"([^"]*)"|'([^']*)')/gi;
  let m;
  while ((m = re.exec(html)) !== null) out.push(decodeUrlEntities(m[1] !== undefined ? m[1] : m[2]));
  for (const att of Array.isArray(message && message.attachments) ? message.attachments : []) {
    if (!att) continue;
    const ct = String(att.contentType || '').toLowerCase();
    if (ct === 'reference' && att.contentUrl) out.push(String(att.contentUrl));
    if (ct === 'application/vnd.microsoft.card.fluidembedcard' && typeof att.content === 'string') {
      try { const c = JSON.parse(att.content); if (c && c.componentUrl) out.push(String(c.componentUrl)); } catch (e) { /* not JSON */ }
    }
  }
  return out.filter((u) => /^https?:\/\//i.test(u));
}

const isFatal = (err) => !!err && (err.code === 'AUTH_DEAD' || err.fatal === true);
const errorText = (err) => String((err && err.message) || err).replace(/\s+/g, ' ').slice(0, 300);

async function resolveAll(roots, graphGet, opts) {
  const o = opts || {};
  const maxDepth = Number.isInteger(o.maxDepth) && o.maxDepth >= 0 ? o.maxDepth : 3;
  const maxNodes = Number.isInteger(o.maxNodes) && o.maxNodes > 0 ? o.maxNodes : 200;
  const tenantHosts = new Set((Array.isArray(o.tenantHosts) ? o.tenantHosts : []).map((h) => String(h).toLowerCase()));
  const records = [];
  const byKey = new Map();
  const byUrl = new Map();
  const skipped = { depth: 0, budget: 0 };
  const queue = [];
  let signInNeeded = false;

  for (const r of Array.isArray(roots) ? roots : [roots]) {
    if (r == null) continue;
    queue.push({ url: typeof r === 'object' ? r.url : r, depth: 0, parent: typeof r === 'object' && r.parent ? r.parent : null });
  }
  const budgetLeft = () => records.length < maxNodes;
  const addRecord = (rec) => { records.push(rec); byKey.set(rec.key, rec); return rec; };
  const alias = (rec, raw) => { const s = String(raw); if (s && rec.aliases.indexOf(s) < 0) rec.aliases.push(s); };
  const rememberUrl = (u, rec) => { const n = normalizeUrl(u); if (n !== null && !byUrl.has('url:' + n)) byUrl.set('url:' + n, rec); };
  const call = async (path) => {
    const res = await graphGet(path, {}); // a fresh, empty header set: never a Prefer header
    let body = res ? res.body : null;
    if (typeof body === 'string') { try { body = JSON.parse(body); } catch (e) { /* a non-JSON body stays a string */ } }
    return { status: Number(res && res.status) || 0, headers: (res && res.headers) || {}, body };
  };

  async function listFolder(rec) {
    const folder = rec.item;
    const driveId = folder.parentReference && folder.parentReference.driveId;
    const listing = driveId && folder.id && pathSegment(driveId) && pathSegment(folder.id)
      ? '/drives/' + pathSegment(driveId) + '/items/' + pathSegment(folder.id) + '/children?$select=' + DRIVE_ITEM_SELECT + '&$top=200' : null;
    if (!listing) { rec.detail = 'folder: children not listed (no drive or item id)'; return; }
    let path = listing;
    let listed = 0;
    for (let page = 0; path && page < 50; page++) {
      let res;
      try { res = await call(path); } catch (err) { if (isFatal(err)) throw err; rec.detail = 'folder: listing failed: ' + errorText(err); return; }
      if (res.status === 401) signInNeeded = true;
      if (res.status < 200 || res.status >= 300) { rec.detail = 'folder: listing failed: http ' + res.status + ' ' + graphErrorText(res); return; }
      const children = res.body && Array.isArray(res.body.value) ? res.body.value : [];
      for (let i = 0; i < children.length; i++) {
        const child = children[i];
        if (!budgetLeft()) { skipped.budget += children.length - i; path = null; break; }
        const key = driveItemKey(child) || (child && child.webUrl && normalizeUrl(child.webUrl) ? 'url:' + normalizeUrl(child.webUrl) : null);
        if (!key) continue;
        const existing = byKey.get(key);
        if (existing) { if (child.webUrl) alias(existing, child.webUrl); continue; }
        const crec = addRecord({ url: String(child.webUrl || ''), key, status: 'fetched', item: child, depth: rec.depth + 1, parent: rec.key,
          kind: rec.kind, detail: child.folder ? 'folder: recorded, not listed (one level only)' : '', aliases: child.webUrl ? [String(child.webUrl)] : [] });
        if (child.webUrl) rememberUrl(child.webUrl, crec);
        if (!child.folder) queue.push({ expand: crec });
        listed++;
      }
      if (!path) break;
      const next = res.body && res.body['@odata.nextLink'];
      path = typeof next === 'string' && next.startsWith(GRAPH_V1) ? next.slice(GRAPH_V1.length - 1) : null;
    }
    rec.detail = 'folder: ' + listed + ' children listed, one level only';
  }

  async function visit(task) {
    const raw = task.url == null ? '' : String(task.url);
    const normalized = normalizeUrl(raw);
    const urlKey = normalized === null ? 'unparsable:' + raw : 'url:' + normalized;
    const seen = byUrl.get(urlKey);
    if (seen) { alias(seen, raw); return seen; }
    const c = classifyUrl(raw);
    const make = (fields) => {
      const rec = addRecord(Object.assign({ url: raw, key: urlKey, status: 'error', item: null, depth: task.depth, parent: task.parent,
        kind: c.kind, detail: '', aliases: [raw] }, fields));
      byUrl.set(urlKey, rec);
      return rec;
    };
    if (c.route === 'object-url') {
      // A Teams file card: the SharePoint URL it wraps is the real target, reached at the same depth.
      const target = await visit({ url: c.objectUrl, depth: task.depth, parent: task.parent });
      if (target) { alias(target, raw); byUrl.set(urlKey, target); }
      return target;
    }
    if (c.route === 'none') return make({ status: c.kind === 'web' ? 'external' : 'unsupported', detail: c.reason || '' });
    if (!budgetLeft()) { skipped.budget++; return null; }
    const path = c.route === 'shares' ? '/shares/' + sharesId(c.fetchUrl) + '/driveItem?$select=' + DRIVE_ITEM_SELECT
      : c.route === 'drive-item' && pathSegment(c.driveId) && pathSegment(c.itemId)
        ? '/drives/' + pathSegment(c.driveId) + '/items/' + pathSegment(c.itemId) + '?$select=' + DRIVE_ITEM_SELECT
        : c.route === 'graph' ? c.graphPath : null;
    if (!pathIsSafe(path)) return make({ status: 'unsupported', detail: 'refused: the Graph path this link maps to fails the read-only path rules' });
    if (signInNeeded) return make({ status: 'error', detail: 'not attempted: an earlier request answered 401 (sign-in needed)' });
    let res;
    try { res = await call(path); } catch (err) {
      if (isFatal(err)) throw err;
      return make({ status: 'error', detail: 'request failed: ' + errorText(err) });
    }
    if (res.status >= 200 && res.status < 300) {
      const key = canonicalKey(c, res.body) || urlKey;
      const existing = byKey.get(key);
      if (existing) { alias(existing, raw); byUrl.set(urlKey, existing); return existing; }
      const rec = make({ key, status: 'fetched', item: res.body, detail: c.rewrittenFrom ? 'rewritten from ' + c.rewrittenFrom : '' });
      if (res.body && typeof res.body === 'object' && res.body.webUrl) rememberUrl(res.body.webUrl, rec);
      if (res.body && res.body.folder && task.depth < maxDepth) await listFolder(rec);
      else queue.push({ expand: rec });
      return rec;
    }
    const text = graphErrorText(res);
    if (res.status === 403) {
      const shareHost = c.fetchUrl ? (prepareUrl(c.fetchUrl, 0) || { hostname: '' }).hostname : '';
      const foreign = tenantHosts.size && /\.sharepoint(-df)?\.com$/.test(shareHost) && !tenantHosts.has(shareHost);
      // /shares gives one generic 403 for missing ∪ unshared ∪ foreign-tenant ∪ non-SharePoint: denied, never gone.
      return make({ status: 'denied', httpStatus: 403, detail: (foreign ? 'foreign tenant (' + shareHost + '); ' : '') + 'forbidden (403): ' + text });
    }
    if (res.status === 401) signInNeeded = true;
    const label = res.status === 401 ? 'sign-in needed (401)' : res.status === 404 ? 'not found (404)' : 'http ' + res.status;
    return make({ status: 'error', httpStatus: res.status, detail: label + ': ' + text });
  }

  async function expand(rec) {
    const builtIn = rec.kind === 'teams' && rec.item && typeof rec.item === 'object' ? chatMessageLinks(rec.item) : [];
    if (rec.depth >= maxDepth) { skipped.depth += builtIn.length; return; }
    let extra = [];
    if (typeof o.expand === 'function') {
      try { extra = await o.expand(rec); } catch (err) {
        if (isFatal(err)) throw err;
        rec.detail = (rec.detail ? rec.detail + '; ' : '') + 'expand failed: ' + errorText(err);
      }
    }
    for (const u of builtIn.concat(Array.isArray(extra) ? extra : [])) queue.push({ url: u, depth: rec.depth + 1, parent: rec.key });
  }

  while (queue.length) {
    const task = queue.shift();
    if (task.expand) { await expand(task.expand); continue; }
    if (!budgetLeft()) {
      const unvisited = new Set(queue.filter((t) => !t.expand).map((t) => normalizeUrl(t.url)));
      if (!byUrl.has('url:' + normalizeUrl(task.url))) unvisited.add(normalizeUrl(task.url));
      for (const n of unvisited) if (!byUrl.has('url:' + n)) skipped.budget++;
      break;
    }
    await visit(task);
  }
  records.skipped = skipped;
  return records;
}

// ═════════════════════════════════════════════════════════════════════════════════════════════════
// SHIPPED FIXTURES — node resolve.js --selftest
// The URL zoo is real-shaped (the forms Graph, Teams, Outlook and Copilot emit, measured 2026-09-14) on a
// fictional tenant. The walk runs against a fake graphGet; each positive check has a negative control.
// ═════════════════════════════════════════════════════════════════════════════════════════════════
async function selftest(write) {
  const say = write || ((s) => process.stdout.write(s + '\n'));
  let passed = 0;
  let failed = 0;
  const check = (name, ok, detail) => {
    if (ok) { passed++; say('ok   resolve: ' + name); return; }
    failed++;
    say('FAIL resolve: ' + name + (detail ? '\n       ' + String(detail).replace(/\n/g, '\n       ') : ''));
  };
  const same = (name, got, want) => check(name, got === want, 'want ' + JSON.stringify(want) + '\ngot  ' + JSON.stringify(got));

  const ANA = 'https://contoso-my.sharepoint.com/personal/ana_contoso_com';
  const enc = encodeURIComponent;
  const planUrl = ANA + '/Documents/Plan.docx';

  // ── normalizeUrl: the zoo ──
  const zoo = [
    ['Outlook safelink around a SharePoint short link', 'https://nam12.safelinks.protection.outlook.com/?url=' + enc('https://contoso-my.sharepoint.com/:w:/r/personal/ana_contoso_com/Documents/Plan.docx?web=1') +
      '&data=05%7C02%7Cana%40contoso.com%7C1f2e%7C0&sdata=Zm9v&reserved=0', 'https://contoso-my.sharepoint.com/:w:/r/personal/ana_contoso_com/Documents/Plan.docx'],
    ['Teams safelink around a web link with utm_*', 'https://statics.teams.cdn.office.net/evergreen-assets/safelinks/1/atp-safelinks.html?url=' +
      enc('https://example.com/docs?utm_source=teams&id=7&utm_medium=chat') + '&locale=en-us', 'https://example.com/docs?id=7'],
    ['HTML-entity-encoded Copilot link with EntityRepresentationId', 'https://contoso.sharepoint.com/sites/Finance/Shared%20Documents/Q3.xlsx?web=1&amp;EntityRepresentationId=025f05ac-1111-2222-3333-444455556666',
      'https://contoso.sharepoint.com/sites/Finance/Shared%20Documents/Q3.xlsx'],
    ['uppercase host, fragment and trailing slash', 'https://CONTOSO-MY.SHAREPOINT.COM/personal/ana_contoso_com/Documents/Recordings/#view',
      'https://contoso-my.sharepoint.com/personal/ana_contoso_com/Documents/Recordings'],
    ['literal spaces become %20', ANA + '/Documents/Apps/MS 365 MCP Server', ANA + '/Documents/Apps/MS%20365%20MCP%20Server'],
    ['Doc.aspx keeps sourcedoc and file, drops action and mobileredirect, sorts', 'https://contoso.sharepoint.com/sites/Finance/_layouts/15/Doc.aspx?sourcedoc={9F2E7260-15D6-4176-A5D3-E9BBC05022BD}&file=Q3.docx&action=default&mobileredirect=true',
      'https://contoso.sharepoint.com/sites/Finance/_layouts/15/Doc.aspx?file=Q3.docx&sourcedoc=%7B9F2E7260-15D6-4176-A5D3-E9BBC05022BD%7D'],
    ['/:f:/r/ folder link drops csf, web and e', ANA.replace('/personal', '/:f:/r/personal') + '/Documents/Recordings?csf=1&web=1&e=Ab12Cd',
      'https://contoso-my.sharepoint.com/:f:/r/personal/ana_contoso_com/Documents/Recordings'],
    ['guest link drops its e= tracker', 'https://contoso.sharepoint.com/:x:/g/personal/ana_contoso_com/EZm9qQ1b2c3d4e5f6g7h8i9jA?e=4%3AabCdEf',
      'https://contoso.sharepoint.com/:x:/g/personal/ana_contoso_com/EZm9qQ1b2c3d4e5f6g7h8i9jA'],
    ['stream.aspx drops its referrer parameters', ANA + '/_layouts/15/stream.aspx?id=' + enc('/personal/ana_contoso_com/Documents/Recordings/Weekly sync.mp4') +
      '&referrer=StreamWebApp.Web&referrerScenario=AddressBarCopied.view', ANA + '/_layouts/15/stream.aspx?id=/personal/ana_contoso_com/Documents/Recordings/Weekly%20sync.mp4'],
    ['legacy consumer cid/id link', 'https://onedrive.live.com?cid=1A2B3C4D5E6F7A8B&id=1A2B3C4D5E6F7A8B%21228', 'https://onedrive.live.com/?cid=1A2B3C4D5E6F7A8B&id=1A2B3C4D5E6F7A8B!228'],
    ['1drv.ms short link drops e=', 'https://1drv.ms/w/s!AkPx3m9Q2Zb7gQ?e=Tr4ck', 'https://1drv.ms/w/s!AkPx3m9Q2Zb7gQ'],
    ['Teams message deep link keeps its context', 'https://teams.microsoft.com/l/message/19:3a1b2c3d4e5f@thread.v2/1726048950123?context=%7B%22contextType%22%3A%22chat%22%7D',
      'https://teams.microsoft.com/l/message/19:3a1b2c3d4e5f@thread.v2/1726048950123?context=%7B%22contextType%22:%22chat%22%7D'],
    ['web link: utm_* dropped, a web-site e= kept, trailing slash kept', 'https://www.example.org/news/?utm_source=newsletter&e=42&utm_medium=email',
      'https://www.example.org/news/?e=42'],
    ['onenote: prefix unwrapped', 'onenote:https://contoso-my.sharepoint.com/personal/ana_contoso_com/Documents/Notebooks/Work#Section1.one',
      'https://contoso-my.sharepoint.com/personal/ana_contoso_com/Documents/Notebooks/Work'],
    ['Copilot citation suffix and sentence punctuation trimmed', 'https://example.org/report.pdf[^1^]', 'https://example.org/report.pdf'],
    ['mailto keeps its address, scheme lowercased', 'MAILTO:ana@contoso.com', 'mailto:ana@contoso.com'],
  ];
  for (const [name, input, want] of zoo) same('normalizeUrl: ' + name, normalizeUrl(input), want);
  same('normalizeUrl NEGATIVE CONTROL: text that is not a URL is null', normalizeUrl('see the deck'), null);
  check('normalizeUrl NEGATIVE CONTROL: a meaningful id= query is NOT dropped',
    normalizeUrl(ANA + '/_layouts/15/onedrive.aspx?id=%2Fpersonal%2Fana&view=0') !== normalizeUrl(ANA + '/_layouts/15/onedrive.aspx?id=%2Fpersonal%2Fbob&view=0'));

  // ── classifyUrl ──
  const kinds = [
    [planUrl, 'onedrive-business', 'shares'],
    ['https://contoso.sharepoint.com/sites/Finance/Shared%20Documents/Q3.xlsx', 'sharepoint', 'shares'],
    ['https://contoso.sharepoint.com/contentstorage/CSP_0a1b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d/Document%20Library/LoopAppData/Plan.loop', 'loop', 'shares'],
    ['https://loop.cloud.microsoft/p/eyJ1IjoiaHR0cHM6Ly9jb250b3NvLnNoYXJlcG9pbnQuY29tIn0%3D', 'loop', 'shares'],
    [ANA + '/_layouts/15/stream.aspx?id=%2Fpersonal%2Fana_contoso_com%2FDocuments%2FRecordings%2Fsync.mp4', 'stream', 'shares'],
    ['https://web.microsoftstream.com/video/0a1b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d', 'stream', 'none'],
    ['https://onedrive.live.com/?cid=1A2B3C4D5E6F7A8B&id=1A2B3C4D5E6F7A8B%21228', 'onedrive-consumer', 'drive-item'],
    ['https://onedrive.live.com/redir?resid=1231244193912!12&authKey=1201919!12921!1', 'onedrive-consumer', 'shares'],
    ['https://my.microsoftpersonalcontent.com/personal/1a2b3c4d5e6f7a8b/Documents/Trip.xlsx', 'onedrive-consumer', 'shares'],
    ['https://teams.microsoft.com/l/message/19%3a3a1b2c3d4e5f%40thread.v2/1726048950123?context=%7B%7D', 'teams', 'graph'],
    ['https://teams.microsoft.com/l/meetup-join/19%3ameeting_NjQ5ZmM1YjEtYzM2Ny00ZDk4%40thread.v2/0?context=%7b%22Tid%22%3a%22x%22%7d', 'teams', 'none'],
    ['https://microsoft.teams.com/threads/19:meeting_abc@thread.v2', 'teams', 'graph'],
    ['https://graph.microsoft.com/v1.0/chats/19:abc@thread.v2/messages/1726/hostedContents/aWQ9eF8w/$value', 'graph', 'graph'],
    ['https://graph.microsoft.com/beta/me/profile', 'graph', 'none'],
    ['https://www.example.org/report.pdf?utm_source=newsletter', 'web', 'none'],
    ['tel:+15551234567', 'unsupported', 'none'],
    ['javascript:alert(1)', 'unsupported', 'none'],
  ];
  for (const [u, kind, route] of kinds) {
    const c = classifyUrl(u);
    same('classifyUrl: ' + kind + ' via ' + route + ' — ' + u.slice(0, 70), c.kind + '/' + c.route, kind + '/' + route);
  }
  const stream = classifyUrl(kinds[4][0]);
  same('classifyUrl: stream.aspx is rewritten to the plain server-relative path', stream.fetchUrl, ANA + '/Documents/Recordings/sync.mp4');
  const libraryView = classifyUrl('https://contoso.sharepoint.com/sites/Finance/Shared%20Documents/Forms/All.aspx?id=%2Fsites%2FFinance%2FShared%20Documents%2FBoard%20Packs&viewid=5e1f');
  same('classifyUrl: a Forms/All.aspx library view is rewritten the same way', libraryView.kind + ' ' + libraryView.fetchUrl,
    'sharepoint https://contoso.sharepoint.com/sites/Finance/Shared%20Documents/Board%20Packs');
  const legacy = classifyUrl(kinds[6][0]);
  same('classifyUrl: a legacy consumer link maps to its drive and item ids', legacy.driveId + ' ' + legacy.itemId, '1A2B3C4D5E6F7A8B 1A2B3C4D5E6F7A8B!228');
  same('classifyUrl: a percent-encoded Teams chat message link maps to the chat message path', classifyUrl(kinds[9][0]).graphPath,
    '/chats/19:3a1b2c3d4e5f@thread.v2/messages/1726048950123');
  same('classifyUrl: a channel reply link maps to the replies path',
    classifyUrl('https://teams.microsoft.com/l/message/19:abcdef0123456789@thread.tacv2/1726048950999?tenantId=t&groupId=5f0c1a2b-0000-4000-8000-000000000001&parentMessageId=1726048950001&teamName=Finance&channelName=General').graphPath,
    '/teams/5f0c1a2b-0000-4000-8000-000000000001/channels/19:abcdef0123456789@thread.tacv2/messages/1726048950001/replies/1726048950999');
  const teamsFile = classifyUrl('https://teams.microsoft.com/l/file/9F2E7260-15D6-4176-A5D3-E9BBC05022BD?tenantId=t&fileType=docx&objectUrl=' +
    enc('https://contoso.sharepoint.com/sites/Finance/Shared Documents/General/Q3.docx') + '&baseUrl=' + enc('https://contoso.sharepoint.com/sites/Finance') + '&serviceName=teams');
  same('classifyUrl: a Teams file card routes to the SharePoint URL it wraps', teamsFile.route + ' ' + teamsFile.objectUrl,
    'object-url https://contoso.sharepoint.com/sites/Finance/Shared Documents/General/Q3.docx');
  const smuggled = classifyUrl('https://teams.microsoft.com/l/message/19:abc@thread.v2/..%2Fme%2Fdrive?context=%7B%7D');
  same('classifyUrl NEGATIVE CONTROL: a message id that decodes to a path ("../me/drive") is refused, never put into a Graph path',
    smuggled.route + ' ' + (smuggled.graphPath || 'no-path'), 'none no-path');

  // ── sharesId — reference tokens produced by the bash encoder the research measured with ──
  same('sharesId: a OneDrive for Business path', sharesId(ANA + '/Documents/Recordings'),
    'u!aHR0cHM6Ly9jb250b3NvLW15LnNoYXJlcG9pbnQuY29tL3BlcnNvbmFsL2FuYV9jb250b3NvX2NvbS9Eb2N1bWVudHMvUmVjb3JkaW5ncw');
  same("sharesId: Microsoft's documented example URL", sharesId('https://onedrive.live.com/redir?resid=1231244193912!12&authKey=1201919!12921!1'),
    'u!aHR0cHM6Ly9vbmVkcml2ZS5saXZlLmNvbS9yZWRpcj9yZXNpZD0xMjMxMjQ0MTkzOTEyITEyJmF1dGhLZXk9MTIwMTkxOSExMjkyMSEx');
  const tricky = 'https://contoso.sharepoint.com/sites/Finance/Shared Documents/Plan???>>~~.docx';
  same('sharesId: + and / become - and _, padding removed', sharesId(tricky),
    'u!aHR0cHM6Ly9jb250b3NvLnNoYXJlcG9pbnQuY29tL3NpdGVzL0ZpbmFuY2UvU2hhcmVkIERvY3VtZW50cy9QbGFuPz8_Pj5-fi5kb2N4');
  same('sharesId: decodes back to the URL through an independent base64url decoder',
    Buffer.from(sharesId(tricky + ' ünïcödé').slice(2), 'base64url').toString('utf8'), tricky + ' ünïcödé');

  // ── resolveAll against a fake Graph ──
  const item = (id, name, uid, extra) => Object.assign({ id, name, parentReference: { driveId: 'b!anaDrive' },
    sharepointIds: { siteId: 'SITE-ANA', listId: 'LIST-DOCS', listItemUniqueId: uid }, webUrl: ANA + '/Documents/' + name, file: {} }, extra || {});
  const plan = item('01PLAN', 'Plan.docx', 'AAAA-PLAN');
  const board = item('01BOARD', 'Board', 'BBBB-BOARD', { folder: { childCount: 3 }, file: undefined });
  const minutes = item('01MIN', 'Board/Minutes.docx', 'CCCC-MIN');
  const archive = item('01ARCH', 'Board/Archive', 'DDDD-ARCH', { folder: { childCount: 40 }, file: undefined });
  const denied = (inner, message) => ({ status: 403, body: { error: { code: 'accessDenied', message, innerError: inner ? { code: inner } : undefined } } });
  const generic403 = denied(null, 'The sharing link no longer exists, or you do not have permission to access it.');
  const chatLink = (n) => 'https://teams.microsoft.com/l/message/19:c1@thread.v2/' + n + '?context=%7B%22contextType%22%3A%22chat%22%7D';
  const message = (n, hrefs) => ({ status: 200, body: { id: String(n), messageType: 'message', body: { contentType: 'html',
    content: hrefs.map((h) => '<a href="' + h.replace(/&/g, '&amp;') + '">link</a>').join(' ') } } });
  const sharesByUrl = new Map([
    [planUrl, { status: 200, body: plan }],
    [ANA + '/_layouts/15/Doc.aspx?sourcedoc={AAAA-PLAN}&file=Plan.docx&action=default', { status: 200, body: plan }],
    [ANA + '/Documents/Board', { status: 200, body: board }],
    ['https://fabrikam.sharepoint.com/sites/Deals/Shared%20Documents/Term%20Sheet.docx', generic403],
    ['https://contoso.sharepoint.com/sites/Finance/Shared%20Documents/Q3.xlsx', denied('sharesAccessDenied', 'The system cannot find the file specified. (Exception from HRESULT: 0x80070002)')],
    [ANA + '/Documents/Recordings/sync.mp4', { status: 200, body: item('01SYNC', 'Recordings/sync.mp4', 'EEEE-SYNC') }],
  ]);
  const byPath = new Map([
    ['/drives/b!anaDrive/items/01BOARD/children?$select=' + DRIVE_ITEM_SELECT + '&$top=200', { status: 200, body: { value: [minutes, archive, plan] } }],
    ['/drives/1A2B3C4D5E6F7A8B/items/1A2B3C4D5E6F7A8B!228?$select=' + DRIVE_ITEM_SELECT,
      { status: 200, body: { id: '1A2B3C4D5E6F7A8B!228', name: 'Trip', folder: undefined, file: {}, parentReference: { driveId: '1a2b3c4d5e6f7a8b' },
        sharepointIds: { siteId: 'SITE-MSA', listId: 'LIST-MSA', listItemUniqueId: 'FFFF-TRIP' } } }],
    ['/chats/19:c1@thread.v2/messages/1', message(1, [chatLink(2), planUrl + '?web=1'])],
    ['/chats/19:c1@thread.v2/messages/2', message(2, [chatLink(3), chatLink(1)])],
    ['/chats/19:c1@thread.v2/messages/3', message(3, [chatLink(4)])],
    ['/chats/19:c1@thread.v2/messages/4', message(4, ['https://example.org/deep'])],
  ]);
  const fakeGraph = (calls, overrides) => async (path, headers) => {
    calls.push({ path, headers });
    if (overrides && overrides[path]) return overrides[path]();
    const shares = /^\/shares\/u!([A-Za-z0-9_-]+)\/driveItem\?\$select=/.exec(path);
    if (shares) {
      const decoded = Buffer.from(shares[1], 'base64url').toString('utf8');
      return sharesByUrl.get(decoded) || generic403; // /shares never 404s: a miss is the generic 403
    }
    return byPath.get(path) || { status: 404, body: { error: { code: 'itemNotFound', message: 'The resource could not be found.' } } };
  };
  const decodedShares = (calls) => calls.map((x) => /^\/shares\/u!([A-Za-z0-9_-]+)\//.exec(x.path)).filter(Boolean)
    .map((m) => Buffer.from(m[1], 'base64url').toString('utf8'));

  const calls = [];
  const safelinkToPlan = 'https://eur02.safelinks.protection.outlook.com/?url=' + enc(planUrl) + '&data=05%7C02&reserved=0';
  const teamsFileToMinutes = 'https://teams.microsoft.com/l/file/CCCC-MIN?tenantId=t&objectUrl=' + enc(ANA + '/Documents/Board/Minutes.docx');
  const roots = [planUrl, planUrl + '?web=1&utm_source=mail', safelinkToPlan, ANA + '/_layouts/15/Doc.aspx?sourcedoc={AAAA-PLAN}&file=Plan.docx&action=default',
    ANA + '/Documents/Board', 'https://fabrikam.sharepoint.com/sites/Deals/Shared%20Documents/Term%20Sheet.docx',
    'https://contoso.sharepoint.com/sites/Finance/Shared%20Documents/Q3.xlsx', chatLink(1), 'https://example.org/report.pdf?utm_source=x',
    'mailto:ana@contoso.com', 'https://onedrive.live.com/?cid=1A2B3C4D5E6F7A8B&id=1A2B3C4D5E6F7A8B%21228',
    ANA + '/_layouts/15/stream.aspx?id=' + enc('/personal/ana_contoso_com/Documents/Recordings/sync.mp4'), teamsFileToMinutes];
  const recs = await resolveAll(roots, fakeGraph(calls), { maxDepth: 3, tenantHosts: ['contoso.sharepoint.com', 'contoso-my.sharepoint.com'] });
  const rec = (key) => recs.find((r) => r.key === key) || { aliases: [], status: 'absent', detail: '' };
  const planRec = rec('spo:site-ana:list-docs:aaaa-plan');
  same('walk: five spellings of one file (plain, tracked, safelink, Doc.aspx, a chat link) become ONE record',
    recs.filter((r) => r.key === planRec.key).length + ' record, ' + planRec.aliases.length + ' aliases', '1 record, 5 aliases');
  same('walk: only the two spellings that normalise differently cost a Graph request',
    decodedShares(calls).filter((u) => /Plan\.docx/.test(u)).length, 2);
  const boardRec = rec('spo:site-ana:list-docs:bbbb-board');
  const minRec = rec('spo:site-ana:list-docs:cccc-min');
  const archRec = rec('spo:site-ana:list-docs:dddd-arch');
  check('walk: a folder is listed one level — its children are records at depth 1 under it',
    minRec.status === 'fetched' && minRec.depth === 1 && minRec.parent === boardRec.key && archRec.status === 'fetched' && archRec.parent === boardRec.key,
    JSON.stringify([minRec, archRec].map((r) => [r.key, r.status, r.depth, r.parent])));
  check('walk NEGATIVE CONTROL: the child folder is never listed (no request for its children)',
    !calls.some((x) => /items\/01ARCH\/children/.test(x.path)), calls.map((x) => x.path).join('\n'));
  check('walk: a Teams file card resolves to the file it wraps, with no extra request',
    minRec.aliases.indexOf(teamsFileToMinutes) >= 0 && !decodedShares(calls).some((u) => /Minutes/.test(u)), JSON.stringify(minRec.aliases));
  const foreign = recs.find((r) => /fabrikam/.test(r.url)) || {};
  const ownDenied = recs.find((r) => /Q3\.xlsx/.test(r.url)) || {};
  check('walk: a 403 is "denied", and a host outside the tenant is labelled foreign',
    foreign.status === 'denied' && /^foreign tenant \(fabrikam\.sharepoint\.com\)/.test(foreign.detail), JSON.stringify(foreign));
  check('walk NEGATIVE CONTROL: an in-tenant 403 is denied but NOT labelled foreign, and keeps the not-found hint',
    ownDenied.status === 'denied' && !/foreign/.test(ownDenied.detail) && /sharesAccessDenied/.test(ownDenied.detail), JSON.stringify(ownDenied));
  same('walk: a 403 is never read as gone — no denied link is recorded as an error',
    recs.filter((r) => r.httpStatus === 403).map((r) => r.status).join(','), 'denied,denied');
  same('walk: the chat cycle 1 → 2 → 1 fetches message 1 exactly once',
    calls.filter((x) => x.path === '/chats/19:c1@thread.v2/messages/1').length, 1);
  same('walk: depth cap 3 resolves messages 1-4 and stops before depth 4',
    ['1', '2', '3', '4'].map((n) => (rec('chat:19:c1@thread.v2:message:' + n).depth)).join(',') + ' skipped.depth=' + recs.skipped.depth, '0,1,2,3 skipped.depth=1');
  check('walk NEGATIVE CONTROL: the depth-4 web link was not recorded', !recs.some((r) => /example\.org\/deep/.test(r.url)));
  const web = recs.find((r) => /report\.pdf/.test(r.url)) || {};
  check('walk: a plain web link is external and never requested',
    web.status === 'external' && !calls.some((x) => /example/.test(x.path)) && !decodedShares(calls).some((u) => /example/.test(u)), JSON.stringify(web));
  same('walk: mailto is recorded unsupported', (recs.find((r) => /^mailto:/.test(r.url)) || {}).status, 'unsupported');
  check('walk: a legacy consumer link is read by drive and item id, never through /shares',
    rec('spo:site-msa:list-msa:ffff-trip').status === 'fetched' && !decodedShares(calls).some((u) => /onedrive\.live\.com/.test(u)));
  same('walk: stream.aspx is fetched through its rewritten path', rec('spo:site-ana:list-docs:eeee-sync').detail, 'rewritten from stream.aspx');
  const redeemed = (hs) => hs.some((h) => Object.keys(h || {}).some((k) => /^prefer$/i.test(k) && /redeemSharingLink/i.test(String(h[k]))));
  check('walk: no request carried a Prefer: redeemSharingLink header', calls.length > 0 && !redeemed(calls.map((x) => x.headers)));
  check('walk NEGATIVE CONTROL: that header check does flag a redeemSharingLink header when one is present',
    redeemed([{}, { Prefer: 'redeemSharingLink' }]));
  check('walk: every request path passes the read-only path rules', calls.every((x) => pathIsSafe(x.path)), calls.map((x) => x.path).join('\n'));
  check('walk NEGATIVE CONTROL: the path rules refuse a traversal, an absolute URL and /special/',
    !pathIsSafe('/me/drive/items/../root') && !pathIsSafe('/https://evil.example/x') && !pathIsSafe('/me/drive/special/recordings') && !pathIsSafe('/a b'));
  check('walk: the path rules judge the DECODED path — an encoded letter, slash or double encoding cannot reach /special/; control: %20 passes',
    ['/me/drive/spec%69al/approot', '/me/drive/%73pecial/approot', '/me/drive%2Fspecial%2Fapproot', '/me/drive/%2573pecial/approot', '/me/%zz']
      .every((p) => !pathIsSafe(p)) && pathIsSafe('/me/drive/root:/Microsoft%20Copilot%20Chat%20Files:/children'));
  const graphSpecial = await resolveAll(['https://graph.microsoft.com/v1.0/me/drive/spec%69al/approot'], async (p) => { throw new Error('fetched ' + p); }, {});
  check('walk: a Graph link to an encoded /special/ path in a chat is recorded unsupported and never requested',
    graphSpecial.length === 1 && graphSpecial[0].status === 'unsupported', JSON.stringify(graphSpecial));

  const shallowCalls = [];
  const shallow = await resolveAll([chatLink(1)], fakeGraph(shallowCalls), { maxDepth: 1 });
  check('depth cap 1: message 2 is resolved and message 3 is never requested',
    shallow.some((r) => r.key === 'chat:19:c1@thread.v2:message:2') && !shallowCalls.some((x) => /messages\/3$/.test(x.path)), shallowCalls.map((x) => x.path).join('\n'));
  const deeperCalls = [];
  await resolveAll([chatLink(1)], fakeGraph(deeperCalls), { maxDepth: 2 });
  check('depth cap NEGATIVE CONTROL: raising the cap to 2 does request message 3', deeperCalls.some((x) => /messages\/3$/.test(x.path)));

  // Budget: a folder of 12 files, node budget 5.
  const bigChildren = Array.from({ length: 12 }, (_, i) => item('01F' + i, 'Big/File' + i + '.txt', 'BIG-' + i));
  const bigOverrides = {
    ['/drives/b!anaDrive/items/01BIG/children?$select=' + DRIVE_ITEM_SELECT + '&$top=200']: () => ({ status: 200, body: { value: bigChildren } }),
  };
  sharesByUrl.set(ANA + '/Documents/Big', { status: 200, body: item('01BIG', 'Big', 'BIG-ROOT', { folder: { childCount: 12 }, file: undefined }) });
  const capped = await resolveAll([ANA + '/Documents/Big', 'https://example.org/late'], fakeGraph([], bigOverrides), { maxNodes: 5 });
  same('budget cap 5: exactly five records, the rest counted as skipped', capped.length + ' records, skipped.budget=' + capped.skipped.budget, '5 records, skipped.budget=9');
  const uncapped = await resolveAll([ANA + '/Documents/Big', 'https://example.org/late'], fakeGraph([], bigOverrides), { maxNodes: 50 });
  same('budget cap NEGATIVE CONTROL: a budget of 50 records all 14 nodes', uncapped.length + ' records, skipped.budget=' + uncapped.skipped.budget, '14 records, skipped.budget=0');

  // Sign-in and thrown errors.
  const authCalls = [];
  const signIn = { status: 401, body: { error: { code: 'InvalidAuthenticationToken', message: 'Access token has expired.' } } };
  const afterAuth = await resolveAll([planUrl, ANA + '/Documents/Board'], fakeGraph(authCalls, { ['/shares/' + sharesId(planUrl) + '/driveItem?$select=' + DRIVE_ITEM_SELECT]: () => signIn }), {});
  check('401: recorded as sign-in needed, and no further request is made',
    authCalls.length === 1 && afterAuth[0].status === 'error' && /401/.test(afterAuth[0].detail) && /not attempted/.test(afterAuth[1].detail),
    JSON.stringify(afterAuth.map((r) => [r.status, r.detail])));
  const throwing = await resolveAll([planUrl], async () => { throw new Error('socket hang up'); }, {});
  same('a graphGet that throws an ordinary error is recorded as that link\'s error', throwing[0].status + ' ' + throwing[0].detail, 'error request failed: socket hang up');
  let rejected = null;
  try { await resolveAll([planUrl], async () => { const e = new Error('InteractionRequired'); e.code = 'AUTH_DEAD'; throw e; }, {}); } catch (e) { rejected = e; }
  check('NEGATIVE CONTROL: an AUTH_DEAD error from graphGet aborts the walk instead of being swallowed', rejected && rejected.code === 'AUTH_DEAD');

  const again = await resolveAll(roots, fakeGraph([]), { maxDepth: 3, tenantHosts: ['contoso.sharepoint.com', 'contoso-my.sharepoint.com'] });
  same('walk: two runs over the same inputs give byte-identical records', JSON.stringify(again), JSON.stringify(recs));

  say('resolve.js selftest: ' + passed + ' passed, ' + failed + ' failed');
  return failed;
}

module.exports = { normalizeUrl, classifyUrl, sharesId, resolveAll, selftest };

if (require.main === module) {
  if (process.argv[2] === '--selftest') {
    selftest().then((n) => process.exit(n === 0 ? 0 : 1), (err) => { process.stdout.write('FAIL resolve: selftest crashed: ' + (err && err.stack || err) + '\n'); process.exit(1); });
  } else {
    process.stderr.write('resolve.js is a library for archive.js. Run: node resolve.js --selftest\n');
    process.exit(2);
  }
}
