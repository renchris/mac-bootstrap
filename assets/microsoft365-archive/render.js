'use strict';
// render.js — the Microsoft 365 archive's renderers. Pure functions: no I/O, no clock, no randomness,
// no npm dependency. The same input always yields the same bytes, which is what lets the archive's
// "a second run changes zero bytes" rule hold.
//
// Exports (the engine, archive.js, depends on exactly these):
//   vttToMarkdown(vttText)                  Teams WebVTT transcript -> turns, consecutive same-speaker cues merged
//   aiInsightToMarkdown(insight)            one callAiInsight -> notes / action items / mentions
//   attendanceToMarkdown(report, records)   attendance report -> table (name, email, role, h:mm:ss, joins)
//   chatToMarkdown(messages)                chatMessage[] -> oldest first, system events on one italic line,
//                                           a DLP-flagged message withheld (who and when only)
//   htmlToMarkdown(html)                    dependency-free HTML -> GitHub-flavoured markdown
//   interactionsToSessions(interactions)    Copilot aiInteraction[] -> [{sessionId, startedAt, title, markdown, links}]
//   consumerCsvToSessions(csvText)          consumer Copilot activity CSV -> same shape, or throws naming the columns
//   slugify(s)                              [a-z0-9]+ joined by '-', at most 60 characters, 'untitled' when empty
//   frontMatter(obj, keyOrder)              deterministic YAML front matter, strings quoted when YAML would retype them
//   selftest(write)                         runs the fixtures below; returns the number of failures
//
// Self-test:  node render.js --selftest    (rc 0 iff every fixture passes)

// ── HTML entities ─────────────────────────────────────────────────────────────────────────────────
// The Latin-1 block, in code-point order from U+00A0. The selftest asserts there are exactly 96, so a
// dropped or doubled name cannot silently shift every later character by one.
const LATIN1_ENTITY_NAMES = ('nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr ' +
  'deg plusmn sup2 sup3 acute micro para middot cedil sup1 ordm raquo frac14 frac12 frac34 iquest ' +
  'Agrave Aacute Acirc Atilde Auml Aring AElig Ccedil Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml ' +
  'ETH Ntilde Ograve Oacute Ocirc Otilde Ouml times Oslash Ugrave Uacute Ucirc Uuml Yacute THORN szlig ' +
  'agrave aacute acirc atilde auml aring aelig ccedil egrave eacute ecirc euml igrave iacute icirc iuml ' +
  'eth ntilde ograve oacute ocirc otilde ouml divide oslash ugrave uacute ucirc uuml yacute thorn yuml').split(' ');
const NAMED_ENTITIES = Object.assign(Object.create(null), {
  amp: 38, lt: 60, gt: 62, quot: 34, apos: 39, OElig: 338, oelig: 339, Scaron: 352, scaron: 353, Yuml: 376,
  fnof: 402, circ: 710, tilde: 732, ensp: 8194, emsp: 8195, thinsp: 8201, zwnj: 8204, zwj: 8205, lrm: 8206,
  rlm: 8207, ndash: 8211, mdash: 8212, lsquo: 8216, rsquo: 8217, sbquo: 8218, ldquo: 8220, rdquo: 8221,
  bdquo: 8222, dagger: 8224, Dagger: 8225, bull: 8226, hellip: 8230, permil: 8240, prime: 8242, Prime: 8243,
  lsaquo: 8249, rsaquo: 8250, euro: 8364, trade: 8482, larr: 8592, uarr: 8593, rarr: 8594, darr: 8595,
  harr: 8596, minus: 8722, ne: 8800, le: 8804, ge: 8805,
});
LATIN1_ENTITY_NAMES.forEach((name, i) => { NAMED_ENTITIES[name] = 160 + i; });

function decodeEntities(s) {
  return String(s).replace(/&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});/g, (whole, body) => {
    if (body[0] === '#') {
      const cp = (body[1] === 'x' || body[1] === 'X') ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
      if (!(cp > 0 && cp <= 0x10FFFF) || (cp >= 0xD800 && cp <= 0xDFFF)) return '\uFFFD';
      return String.fromCodePoint(cp);
    }
    return body in NAMED_ENTITIES ? String.fromCodePoint(NAMED_ENTITIES[body]) : whole;
  });
}

// ── small shared helpers ──────────────────────────────────────────────────────────────────────────
const oneLine = (s) => String(s == null ? '' : s).replace(/\s+/g, ' ').trim();
const pad2 = (n) => String(n).padStart(2, '0');
const tableCell = (s) => oneLine(s).replace(/\|/g, '\\|');
const compareText = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
// A link destination with no space, parenthesis or angle bracket needs no <…> wrapping.
const markdownUrl = (u) => String(u).trim().replace(/ /g, '%20').replace(/\(/g, '%28').replace(/\)/g, '%29')
  .replace(/</g, '%3C').replace(/>/g, '%3E');

// parseUtc — milliseconds since the epoch for an ISO-8601 date-time, else NaN. A date-time WITHOUT a zone
// is read as UTC, never as local time: Date.parse would read it in the machine's zone, so the same export
// would sort differently on two Macs.
function parseUtc(value) {
  if (value == null) return NaN;
  const m = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d{1,9}))?)?)?\s*(Z|[+-]\d{2}:?\d{2})?$/i
    .exec(String(value).trim());
  if (!m) return NaN;
  const ms = m[7] ? Math.floor(Number('0.' + m[7]) * 1000) : 0;
  let t = Date.UTC(+m[1], +m[2] - 1, +m[3], +(m[4] || 0), +(m[5] || 0), +(m[6] || 0), ms);
  if (m[8] && m[8].toUpperCase() !== 'Z') {
    const sign = m[8][0] === '-' ? -1 : 1;
    t -= sign * ((+m[8].slice(1, 3)) * 60 + (+m[8].slice(-2))) * 60000;
  }
  return t;
}
const timeKey = (value) => { const t = parseUtc(value); return Number.isFinite(t) ? t : Infinity; };
const isoOrNull = (value) => { const t = parseUtc(value); return Number.isFinite(t) ? new Date(t).toISOString() : null; };
function utcStamp(value) {
  const t = parseUtc(value);
  if (!Number.isFinite(t)) return value ? String(value) : 'unknown time';
  return new Date(t).toISOString().replace('T', ' ').replace(/\.\d+Z$/, ' UTC');
}

// escapeLineStart — a line of TEXT that markdown would otherwise read as structure (a heading, a quote, a
// list item, a rule, a fence) gets one backslash, so a sentence beginning "1. " stays a sentence.
function escapeLineStart(line) {
  if (/^#{1,6}(\s|$)/.test(line) || /^>/.test(line) || /^[-+*](\s|$)/.test(line)) return '\\' + line;
  const ordered = /^(\d{1,9})([.)])(\s|$)/.exec(line);
  if (ordered) return ordered[1] + '\\' + line.slice(ordered[1].length);
  if (/^([-=_*])(\s*\1){2,}\s*$/.test(line) || /^(`{3,}|~{3,})/.test(line)) return '\\' + line;
  return line;
}

// ── HTML: tokenizer ───────────────────────────────────────────────────────────────────────────────
const VOID_ELEMENTS = new Set('area base br col embed hr img input link meta param source track wbr'.split(' '));
// Raw-text elements: their content is not markup, so it is skipped to the matching end tag unread.
const RAW_TEXT_ELEMENTS = new Set('script style title textarea xmp iframe noembed noframes noscript'.split(' '));
const TAG_START = /<(\/?)([A-Za-z][A-Za-z0-9:_-]*)/y;

function tokenize(html) {
  const s = String(html).replace(/\u0000/g, '');
  const tokens = [];
  let i = 0;
  let text = '';
  const flushText = () => { if (text) { tokens.push({ type: 'text', text: decodeEntities(text) }); text = ''; } };
  while (i < s.length) {
    const lt = s.indexOf('<', i);
    if (lt < 0) { text += s.slice(i); break; }
    text += s.slice(i, lt);
    i = lt;
    if (s.startsWith('<!--', i)) { const e = s.indexOf('-->', i + 4); i = e < 0 ? s.length : e + 3; continue; }
    if (s[i + 1] === '!' || s[i + 1] === '?') { const e = s.indexOf('>', i); i = e < 0 ? s.length : e + 1; continue; }
    TAG_START.lastIndex = i;
    const m = TAG_START.exec(s);
    if (!m) { text += '<'; i += 1; continue; }
    flushText();
    const closing = m[1] === '/';
    const name = m[2].toLowerCase();
    let j = TAG_START.lastIndex;
    const attrs = Object.create(null);
    let selfClosing = false;
    while (j < s.length) {
      while (j < s.length && /\s/.test(s[j])) j++;
      if (j >= s.length) break;
      if (s[j] === '>') { j++; break; }
      if (s[j] === '/') { if (s[j + 1] === '>') { selfClosing = true; j += 2; break; } j++; continue; }
      let k = j;
      while (k < s.length && !/[\s=>/]/.test(s[k])) k++;
      const attrName = s.slice(j, k).toLowerCase();
      j = k;
      while (j < s.length && /\s/.test(s[j])) j++;
      let value = '';
      if (s[j] === '=') {
        j++;
        while (j < s.length && /\s/.test(s[j])) j++;
        const q = s[j];
        if (q === '"' || q === "'") {
          const e = s.indexOf(q, j + 1);
          value = s.slice(j + 1, e < 0 ? s.length : e);
          j = e < 0 ? s.length : e + 1;
        } else {
          let e = j;
          while (e < s.length && !/[\s>]/.test(s[e])) e++;
          value = s.slice(j, e);
          j = e;
        }
      }
      if (attrName && !(attrName in attrs)) attrs[attrName] = decodeEntities(value);
    }
    i = j;
    if (closing) { tokens.push({ type: 'end', name }); continue; }
    tokens.push({ type: 'start', name, attrs, selfClosing });
    if (RAW_TEXT_ELEMENTS.has(name) && !selfClosing) {
      const endRe = new RegExp('</' + name + '(?=[\\s/>])', 'ig');
      endRe.lastIndex = i;
      const found = endRe.exec(s);
      const contentEnd = found ? found.index : s.length;
      if (name === 'textarea') tokens.push({ type: 'text', text: decodeEntities(s.slice(i, contentEnd)) });
      const gt = found ? s.indexOf('>', contentEnd) : -1;
      i = gt < 0 ? s.length : gt + 1;
      tokens.push({ type: 'end', name });
    }
  }
  flushText();
  return tokens;
}

// ── HTML: tree builder (the implied-end-tag rules real-world HTML leans on) ───────────────────────
const set = (words) => new Set(words.split(' '));
const CLOSES_OPEN_PARAGRAPH = set('address article aside blockquote center details dialog dir div dl fieldset ' +
  'figcaption figure footer form h1 h2 h3 h4 h5 h6 header hgroup hr main menu nav ol p pre section summary table ul li dd dt search');
const BUTTON_SCOPE = set('button table td th caption html template object marquee applet');
const LIST_ITEM_SCOPE = set('ul ol table td th caption html template');
const HEADING = /^h[1-6]$/;
const MAX_NESTING = 256;

function parseHtml(html) {
  const root = { tag: '#root', attrs: Object.create(null), children: [] };
  const stack = [root];
  const top = () => stack[stack.length - 1];
  const findOpen = (names, boundaries) => {
    for (let i = stack.length - 1; i > 0; i--) {
      if (names.has(stack[i].tag)) return i;
      if (boundaries && boundaries.has(stack[i].tag)) return -1;
    }
    return -1;
  };
  const closeFrom = (i) => { if (i > 0) stack.length = i; };
  for (const tok of tokenize(html)) {
    if (tok.type === 'text') { top().children.push({ text: tok.text }); continue; }
    const name = tok.name;
    if (tok.type === 'end') {
      if (name === 'br') { top().children.push({ tag: 'br', attrs: Object.create(null), children: [] }); continue; }
      closeFrom(findOpen(new Set([name]), null));
      continue;
    }
    if (CLOSES_OPEN_PARAGRAPH.has(name)) closeFrom(findOpen(set('p'), BUTTON_SCOPE));
    if (name === 'li') closeFrom(findOpen(set('li'), LIST_ITEM_SCOPE));
    else if (name === 'dt' || name === 'dd') closeFrom(findOpen(set('dt dd'), set('dl table td th')));
    else if (name === 'tr') closeFrom(findOpen(set('tr'), set('table')));
    else if (name === 'td' || name === 'th') closeFrom(findOpen(set('td th'), set('tr table')));
    else if (name === 'thead' || name === 'tbody' || name === 'tfoot') closeFrom(findOpen(set('thead tbody tfoot'), set('table')));
    else if (name === 'a') closeFrom(findOpen(set('a'), BUTTON_SCOPE));
    else if (HEADING.test(name) && HEADING.test(top().tag)) stack.pop();
    const el = { tag: name, attrs: tok.attrs, children: [] };
    top().children.push(el);
    // Past MAX_NESTING open elements, new ones stay empty and their content joins the deepest parent: the
    // text survives, and a hostile message nested ten thousand deep cannot overflow the renderer's stack.
    if (!VOID_ELEMENTS.has(name) && !tok.selfClosing && stack.length < MAX_NESTING) stack.push(el);
  }
  return root;
}

// ── HTML: markdown renderer ───────────────────────────────────────────────────────────────────────
const DROPPED = set('script style noscript template head title svg math iframe object embed select option ' +
  'datalist meta link base map area audio video canvas');
const BLOCK_CONTAINERS = set('address article aside body center details dialog dir div dl fieldset figcaption figure ' +
  'footer form header hgroup html main menu nav p section summary dt dd caption legend search');
const BLOCK_SPECIAL = set('h1 h2 h3 h4 h5 h6 ul ol pre blockquote hr table li tr td th thead tbody tfoot');
const isBlock = (n) => n.tag !== undefined && (BLOCK_CONTAINERS.has(n.tag) || BLOCK_SPECIAL.has(n.tag));
const LINE_BREAK = '\u0000'; // a <br> while inline text is assembled; NUL was stripped from the input
const collapseWhitespace = (s) => s.replace(/\s+/g, ' ');
// escapeText — TEXT from a text node, made inert as markdown: entities were decoded, so an escaped
// "&lt;img …&gt;" is now "<img …>" and must not become a live tag; "*", "_", "`", "[", "]" and "\" must
// not become emphasis, code or a link. '&' is escaped only where it would start an entity again.
const escapeText = (s) => s.replace(/[\\`*_[\]<>]|&(?=#?[A-Za-z0-9]+;)/g,
  (c) => (c === '<' ? '&lt;' : c === '>' ? '&gt;' : c === '&' ? '&amp;' : '\\' + c));
// safeHref — a link or image target with the ASCII control characters a browser ignores removed
// ("java\tscript:" IS javascript:), or null when the scheme can run code or smuggle bytes.
const stripControls = (s) => String(s || '').replace(/[\x00-\x1f\x7f]/g, '').trim();
function safeHref(value) {
  const href = stripControls(value);
  return /^(javascript|vbscript|data):/i.test(href) ? null : href;
}

function textContentRaw(node) {
  if (node.text !== undefined) return node.text;
  if (node.tag === 'br') return '\n';
  if (DROPPED.has(node.tag)) return '';
  return node.children.map(textContentRaw).join('');
}

function wrapEmphasis(s, marker) {
  const m = /^([\s\u0000]*)([\s\S]*?)([\s\u0000]*)$/.exec(s);
  if (!m[2]) return s;
  const middle = m[2];
  const alreadyWrapped = middle.length >= 2 * marker.length && middle.startsWith(marker) && middle.endsWith(marker) &&
    middle.slice(marker.length, -marker.length).indexOf(marker) < 0;
  return m[1] + (alreadyWrapped ? middle : marker + middle + marker) + m[3];
}

function inlineCode(t) {
  if (!t.trim()) return t;
  const runs = t.match(/`+/g) || [];
  const fence = '`'.repeat(runs.reduce((n, r) => Math.max(n, r.length), 0) + 1);
  const padding = /^`|`$/.test(t) ? ' ' : '';
  return fence + padding + t + padding + fence;
}

function renderInlineChildren(node) {
  return node.children.map((c) => (isBlock(c) ? LINE_BREAK + renderInlineChildren(c) + LINE_BREAK : renderInline(c))).join('');
}

function renderInline(node) {
  if (node.text !== undefined) return escapeText(collapseWhitespace(node.text));
  const tag = node.tag;
  if (DROPPED.has(tag)) return '';
  switch (tag) {
    case 'br': return LINE_BREAK;
    case 'wbr': return '';
    case 'strong': case 'b': return wrapEmphasis(renderInlineChildren(node), '**');
    case 'em': case 'i': case 'cite': case 'dfn': case 'var': return wrapEmphasis(renderInlineChildren(node), '*');
    case 'del': case 's': case 'strike': return wrapEmphasis(renderInlineChildren(node), '~~');
    case 'code': case 'kbd': case 'samp': case 'tt': return inlineCode(collapseWhitespace(textContentRaw(node)));
    case 'q': return '"' + renderInlineChildren(node) + '"';
    case 'at': return '@' + renderInlineChildren(node).trim(); // a Teams @mention
    case 'emoji': return node.attrs.alt ? escapeText(node.attrs.alt) : renderInlineChildren(node);
    case 'input': {
      if (String(node.attrs.type || '').toLowerCase() !== 'checkbox') return '';
      return ('checked' in node.attrs ? '[x]' : '[ ]') + ' ';
    }
    case 'img': {
      const alt = escapeText(oneLine(node.attrs.alt || ''));
      const rawSrc = stripControls(node.attrs.src || node.attrs['data-src'] || '');
      if (/emoji/i.test(node.attrs.itemtype || '')) return alt; // Teams renders emoji as <img itemtype=…Emoji>
      if (!rawSrc) return alt;
      if (/^data:/i.test(rawSrc)) return '[inline image' + (alt ? ': ' + alt : '') + ']'; // bytes, not a link
      const src = safeHref(rawSrc);
      if (!src) return alt;
      return '![' + alt + '](' + markdownUrl(src) + ')';
    }
    case 'a': {
      const href = safeHref(node.attrs.href);
      const text = renderInlineChildren(node).replace(/\u0000/g, ' ').replace(/ +/g, ' ').trim();
      if (!href || href[0] === '#') return text;
      if (!text) return '[' + escapeText(href) + '](' + markdownUrl(href) + ')';
      if (oneLine(textContentRaw(node)) === href && /^https?:\/\//i.test(href)) return '<' + markdownUrl(href) + '>';
      return '[' + text + '](' + markdownUrl(href) + ')';
    }
    default: return renderInlineChildren(node);
  }
}

// finishInline — inline markdown (with LINE_BREAK markers) -> paragraph strings. One <br> is a hard line
// break (backslash-newline, as pandoc writes it); two or more in a row end the paragraph.
function finishInline(s) {
  const t = s.replace(/ +/g, ' ').replace(/ *\u0000 */g, LINE_BREAK);
  return t.split(/\u0000{2,}/)
    .map((p) => p.replace(/^[\u0000 ]+|[\u0000 ]+$/g, ''))
    .filter(Boolean)
    .map((p) => p.split(LINE_BREAK).map(escapeLineStart).join('\\\n'));
}

function inlineText(node) {
  return renderInlineChildren(node).replace(/\u0000/g, ' ').replace(/\s+/g, ' ').trim();
}

function renderBlocks(nodes) {
  const blocks = [];
  let inline = '';
  const flushInline = () => { for (const p of finishInline(inline)) blocks.push({ md: p, kind: 'paragraph' }); inline = ''; };
  for (const node of nodes) {
    if (node.text !== undefined) { inline += escapeText(collapseWhitespace(node.text)); continue; }
    if (DROPPED.has(node.tag)) continue;
    if (isBlock(node)) { flushInline(); for (const b of renderBlockElement(node)) blocks.push(b); continue; }
    inline += renderInline(node);
  }
  flushInline();
  return blocks.filter((b) => b.md);
}

function renderList(node, ordered) {
  let first = ordered ? parseInt(node.attrs.start, 10) : 1;
  if (!Number.isFinite(first)) first = 1;
  const items = [];
  for (const c of node.children) {
    if (c.tag === 'li') items.push(renderBlocks(c.children));
    else if (c.tag === 'ul' || c.tag === 'ol') {
      const nested = renderBlockElement(c);
      if (items.length) items[items.length - 1].push(...nested); else items.push(nested);
    } else if (c.text !== undefined && !c.text.trim()) continue;
    else items.push(renderBlocks([c]));
  }
  const lines = [];
  let number = first;
  for (const blocks of items) {
    let body = '';
    blocks.forEach((b, j) => { if (j) body += b.kind === 'list' ? '\n' : '\n\n'; body += b.md; });
    if (!body) continue;
    const marker = ordered ? (number++) + '. ' : '- ';
    const indent = ' '.repeat(marker.length);
    body.split('\n').forEach((l, k) => lines.push(k === 0 ? marker + l : (l ? indent + l : '')));
  }
  return lines.length ? [{ md: lines.join('\n'), kind: 'list' }] : [];
}

function renderTable(node) {
  const rows = [];
  let caption = '';
  const walk = (n) => {
    for (const c of n.children || []) {
      if (c.tag === 'tr') rows.push(c);
      else if (c.tag === 'thead' || c.tag === 'tbody' || c.tag === 'tfoot') walk(c);
      else if (c.tag === 'caption') caption = inlineText(c);
    }
  };
  walk(node);
  const cellsOf = (row) => row.children.filter((c) => c.tag === 'td' || c.tag === 'th');
  const cellText = (cell) => renderBlocks(cell.children).map((b) => b.md).join(' ')
    .replace(/\\\n/g, ' ').replace(/\s+/g, ' ').replace(/\|/g, '\\|').trim();
  // A table whose every row holds at most one cell is page layout (mail templates), not data.
  if (!rows.length || rows.every((r) => cellsOf(r).length <= 1)) {
    const out = caption ? [{ md: caption, kind: 'paragraph' }] : [];
    if (!rows.length) return out.concat(renderBlocks(node.children.filter((c) => c.tag !== 'caption')));
    for (const r of rows) for (const cell of cellsOf(r)) out.push(...renderBlocks(cell.children));
    return out;
  }
  const grid = rows.map((r) => {
    const cells = [];
    for (const cell of cellsOf(r)) {
      cells.push(cellText(cell));
      const span = Math.min(parseInt(cell.attrs.colspan, 10) || 1, 50);
      for (let k = 1; k < span; k++) cells.push('');
    }
    return cells;
  }).filter((r) => r.length);
  const width = grid.reduce((n, r) => Math.max(n, r.length), 0);
  const line = (cells) => '| ' + Array.from({ length: width }, (_, k) => cells[k] || '').join(' | ') + ' |';
  const md = [line(grid[0]), '|' + ' --- |'.repeat(width)].concat(grid.slice(1).map(line)).join('\n');
  return (caption ? [{ md: caption, kind: 'paragraph' }] : []).concat([{ md, kind: 'table' }]);
}

function renderBlockElement(node) {
  const tag = node.tag;
  if (HEADING.test(tag)) {
    const t = inlineText(node);
    return t ? [{ md: '#'.repeat(+tag[1]) + ' ' + t, kind: 'heading' }] : [];
  }
  switch (tag) {
    case 'ul': return renderList(node, false);
    case 'ol': return renderList(node, true);
    case 'li': return renderList({ tag: 'ul', attrs: Object.create(null), children: [node] }, false);
    case 'hr': return [{ md: '---', kind: 'rule' }];
    case 'table': return renderTable(node);
    case 'blockquote': {
      const inner = renderBlocks(node.children).map((b) => b.md).join('\n\n');
      if (!inner) return [];
      return [{ md: inner.split('\n').map((l) => (l ? '> ' + l : '>')).join('\n'), kind: 'quote' }];
    }
    case 'pre': {
      let code = textContentRaw(node).replace(/\r\n?/g, '\n');
      if (code.startsWith('\n')) code = code.slice(1);
      code = code.replace(/\s+$/, '');
      if (!code) return [];
      const codeChild = node.children.find((c) => c.tag === 'code');
      const classes = String(node.attrs.class || '') + ' ' + String((codeChild && codeChild.attrs.class) || '');
      const lang = (/(?:^|\s)(?:language|lang)-([A-Za-z0-9_+#-]+)/.exec(classes) || [])[1] || '';
      const runs = code.match(/`{3,}/g) || [];
      const fence = '`'.repeat(runs.reduce((n, r) => Math.max(n, r.length + 1), 3));
      return [{ md: fence + lang + '\n' + code + '\n' + fence, kind: 'code' }];
    }
    default: return renderBlocks(node.children);
  }
}

function htmlToMarkdown(html) {
  if (html == null) return '';
  const md = renderBlocks(parseHtml(String(html)).children).map((b) => b.md).join('\n\n');
  return md ? md + '\n' : '';
}

// ── WebVTT transcripts ────────────────────────────────────────────────────────────────────────────
function vttTimestamp(ts) {
  const m = /^(?:(\d+):)?(\d{1,2}):(\d{2})(?:[.,](\d{1,3}))?$/.exec(String(ts).trim());
  if (!m) return null;
  return (+(m[1] || 0)) * 3600 + (+m[2]) * 60 + (+m[3]) + (m[4] ? +m[4].padEnd(3, '0') / 1000 : 0);
}
const clock = (seconds) => {
  const s = Math.floor(seconds);
  return pad2(Math.floor(s / 3600)) + ':' + pad2(Math.floor((s % 3600) / 60)) + ':' + pad2(s % 60);
};
// Cue text is decoded, but < and > stay escaped: a spoken "<done>" must not become raw HTML in markdown.
const cueText = (s) => oneLine(decodeEntities(s.replace(/<[^>]*>/g, ''))).replace(/</g, '&lt;').replace(/>/g, '&gt;');
const escapeSpeaker = (s) => s.replace(/&(?=#?[A-Za-z0-9]+;)/g, '&amp;').replace(/([\\*_`[\]])/g, '\\$1').replace(/</g, '&lt;').replace(/>/g, '&gt;');
// A cue identifier as Teams and other encoders write one: a number, or a GUID with an optional
// "/<n>-<n>" suffix. Used only to spot the NEXT cue's id when the blank line before it is missing.
const CUE_IDENTIFIER = /^(\d+|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}(\/[\w-]+)?)$/;

// One cue's payload -> [{speaker, text}]. Handles <v Speaker>, <v.class Speaker>, several voices in one
// cue, and Teams' metadataContent cues whose payload is a JSON object {speakerName, spokenText}.
function cueSegments(lines) {
  const joined = lines.join('\n').trim();
  if (joined[0] === '{') {
    try {
      const o = JSON.parse(joined);
      if (o && typeof o.spokenText === 'string') return [{ speaker: o.speakerName ? String(o.speakerName) : null, text: oneLine(o.spokenText) }];
    } catch (e) { /* not JSON: fall through to voice-tag parsing */ }
  }
  const segments = [];
  let speaker = null;
  for (const line of lines) {
    const voice = /<v(?:\.[^\s>]*)?(?:\s+([^>]*))?>/g;
    let last = 0;
    let m;
    const pieces = [];
    while ((m = voice.exec(line)) !== null) {
      pieces.push({ speaker, raw: line.slice(last, m.index) });
      speaker = oneLine(decodeEntities(m[1] || '')) || null;
      last = voice.lastIndex;
    }
    pieces.push({ speaker, raw: line.slice(last) });
    for (const p of pieces) {
      const text = cueText(p.raw);
      if (!text) continue;
      const prev = segments[segments.length - 1];
      if (prev && prev.speaker === p.speaker) prev.text += ' ' + text;
      else segments.push({ speaker: p.speaker, text });
    }
  }
  return segments;
}

function vttToMarkdown(vttText) {
  const lines = String(vttText == null ? '' : vttText).replace(/^\uFEFF/, '').split(/\r\n|\r|\n/);
  const turns = [];
  let cue = null;
  let skippingBlock = false;
  const finishCue = () => {
    if (!cue) return;
    for (const seg of cueSegments(cue.lines)) {
      const speaker = seg.speaker || 'Unattributed';
      const last = turns[turns.length - 1];
      if (last && last.speaker === speaker) last.text += ' ' + seg.text;
      else turns.push({ speaker, start: cue.start, text: seg.text });
    }
    cue = null;
  };
  lines.forEach((line, index) => {
    if (index === 0 && /^WEBVTT/.test(line)) { skippingBlock = true; return; }
    // Only an EMPTY line ends a cue or a block (WebVTT); a line of spaces inside a cue is payload, and
    // ending the cue there would make the next spoken line read as a cue identifier and be dropped.
    if (line === '') { finishCue(); skippingBlock = false; return; }
    // A timing line ends a header or NOTE block even without the blank line (Teams metadataContent omits it).
    if (skippingBlock && line.indexOf('-->') < 0) return;
    skippingBlock = false;
    if (!cue && /^(NOTE|STYLE|REGION)(\s|$)/.test(line)) { skippingBlock = true; return; }
    if (line.indexOf('-->') >= 0) {
      // Tolerate a missing blank line between two cues: the last line of the open cue, when it is
      // shaped like a cue identifier, belongs to the cue this timing line starts, and is dropped.
      if (cue && cue.lines.length && CUE_IDENTIFIER.test(cue.lines[cue.lines.length - 1].trim())) cue.lines.pop();
      finishCue();
      const start = vttTimestamp(line.split('-->')[0]);
      cue = { start: start == null ? 0 : start, lines: [] };
      return;
    }
    if (cue) cue.lines.push(line); // lines before a timing line are cue identifiers: dropped
  });
  finishCue();
  if (!turns.length) return '_No spoken content in this transcript._\n';
  return turns.map((t) => '**' + escapeSpeaker(t.speaker) + '** [' + clock(t.start) + ']\n' + escapeLineStart(t.text))
    .join('\n\n') + '\n';
}

// ── Copilot meeting AI insights ───────────────────────────────────────────────────────────────────
function aiInsightToMarkdown(insight) {
  const it = insight || {};
  const out = ['## Copilot meeting notes', '', '_AI-generated by Microsoft 365 Copilot; it may be inaccurate._', ''];
  if (it.id) out.push('- Insight: `' + it.id + '`');
  if (it.callId) out.push('- Call: `' + it.callId + '`');
  if (it.contentCorrelationId) out.push('- Content correlation: `' + it.contentCorrelationId + '`');
  if (it.createdDateTime || it.endDateTime) out.push('- Covers: ' + (it.createdDateTime || '?') + ' to ' + (it.endDateTime || '?'));
  if (out[out.length - 1] !== '') out.push('');
  const entry = (title, text) => {
    const t = oneLine(title);
    const x = oneLine(text);
    return t && x ? '**' + t + '** — ' + x : t ? '**' + t + '**' : x;
  };
  out.push('### Meeting notes', '');
  const notes = Array.isArray(it.meetingNotes) ? it.meetingNotes : [];
  if (!notes.length) out.push('_None._');
  for (const n of notes) {
    out.push('- ' + entry(n && n.title, n && n.text));
    for (const sp of (n && Array.isArray(n.subpoints) ? n.subpoints : [])) out.push('  - ' + entry(sp && sp.title, sp && sp.text));
  }
  out.push('', '### Action items', '');
  const actions = Array.isArray(it.actionItems) ? it.actionItems : [];
  if (!actions.length) out.push('_None._');
  for (const a of actions) {
    out.push('- [ ] ' + entry(a && a.title, a && a.text) + ' _(owner: ' + (oneLine(a && a.ownerDisplayName) || 'unassigned') + ')_');
  }
  out.push('', '### Mentions of the signed-in user', '');
  const mentions = it.viewpoint && Array.isArray(it.viewpoint.mentionEvents) ? it.viewpoint.mentionEvents : [];
  if (!mentions.length) out.push('_None._');
  for (const m of mentions) {
    const sp = (m && m.speaker) || {};
    const who = oneLine((sp.user && sp.user.displayName) || (sp.application && sp.application.displayName) ||
      (sp.device && sp.device.displayName) || 'unknown speaker');
    out.push('- ' + (oneLine(m && m.eventDateTime) || 'unknown time') + ' — **' + who + '**: ' + oneLine(m && m.transcriptUtterance));
  }
  return out.join('\n') + '\n';
}

// ── attendance ────────────────────────────────────────────────────────────────────────────────────
function clockUnpaddedHours(seconds) {
  const n = Number(seconds);
  if (seconds == null || seconds === '' || !Number.isFinite(n) || n < 0) return '';
  const s = Math.round(n);
  return Math.floor(s / 3600) + ':' + pad2(Math.floor((s % 3600) / 60)) + ':' + pad2(s % 60);
}

function attendanceToMarkdown(report, records) {
  const r = report || {};
  const list = (Array.isArray(records) ? records : Array.isArray(r.attendanceRecords) ? r.attendanceRecords : []).slice();
  const nameOf = (x) => oneLine((x && x.identity && x.identity.displayName) || '');
  const firstJoin = (x) => Math.min(Infinity, ...((x && x.attendanceIntervals) || []).map((i) => timeKey(i && i.joinDateTime)));
  // Sorted by first join, then name, then email: the table never depends on the order Graph returned.
  list.sort((a, b) => {
    const ta = firstJoin(a);
    const tb = firstJoin(b);
    if (ta !== tb) return ta < tb ? -1 : 1;
    return compareText(nameOf(a).toLowerCase(), nameOf(b).toLowerCase()) ||
      compareText(String((a && a.emailAddress) || ''), String((b && b.emailAddress) || ''));
  });
  const out = ['## Attendance', ''];
  if (r.id) out.push('- Report: `' + r.id + '`');
  if (r.meetingStartDateTime || r.meetingEndDateTime) out.push('- Meeting: ' + (r.meetingStartDateTime || '?') + ' to ' + (r.meetingEndDateTime || '?'));
  if (r.totalParticipantCount != null) out.push('- Participants: ' + r.totalParticipantCount);
  if (out[out.length - 1] !== '') out.push('');
  if (!list.length) return out.concat(['_No attendance records._']).join('\n') + '\n';
  out.push('| Name | Email | Role | Total | Joins |', '| --- | --- | --- | --- | --- |');
  for (const x of list) {
    const joins = Array.isArray(x && x.attendanceIntervals) ? x.attendanceIntervals.length : '';
    out.push('| ' + [tableCell(nameOf(x)), tableCell(x && x.emailAddress), tableCell(x && x.role),
      clockUnpaddedHours(x && x.totalAttendanceInSeconds), String(joins)].join(' | ') + ' |');
  }
  return out.join('\n') + '\n';
}

// ── chat ──────────────────────────────────────────────────────────────────────────────────────────
function identityName(from) {
  const f = from || {};
  return oneLine((f.user && f.user.displayName) || (f.application && f.application.displayName) ||
    (f.device && f.device.displayName) || '');
}
function parseJsonMaybe(v) {
  if (v && typeof v === 'object') return v;
  if (typeof v !== 'string') return null;
  try { return JSON.parse(v); } catch (e) { return null; }
}
function humanize(camel) { return camel.replace(/([a-z0-9])([A-Z])/g, '$1 $2').toLowerCase(); }

function summarizeEvent(m) {
  const d = m.eventDetail || {};
  const type = String(d['@odata.type'] || '').replace(/^#?microsoft\.graph\./, '').replace(/EventMessageDetail$/, '');
  const by = identityName(d.initiator);
  let s = type ? humanize(type) : 'system event';
  const members = Array.isArray(d.members) ? d.members.map((x) => oneLine(x && x.displayName)).filter(Boolean) : [];
  if (members.length) s += ': ' + members.join(', ');
  if (d.chatDisplayName) s += ' to "' + oneLine(d.chatDisplayName) + '"';
  if (d.callDuration) s += ' (' + oneLine(d.callDuration) + ')';
  if (d.callRecordingDisplayName) s += ': ' + oneLine(d.callRecordingDisplayName);
  if (d.callRecordingUrl) s += ' <' + markdownUrl(d.callRecordingUrl) + '>';
  if (by) s += ' by ' + by;
  return s;
}

function attachmentLine(att) {
  const ct = String(att.contentType || '').toLowerCase();
  const name = oneLine(att.name);
  if (ct === 'reference' && att.contentUrl) return '- Attachment: [' + (name || att.contentUrl) + '](' + markdownUrl(att.contentUrl) + ')';
  if (ct === 'application/vnd.microsoft.card.fluidembedcard') {
    const c = parseJsonMaybe(att.content) || {};
    const url = c.componentUrl || att.contentUrl;
    return url ? '- Loop component: [' + (name || 'Loop component') + '](' + markdownUrl(url) + ')' : '- Loop component' + (name ? ': ' + name : '');
  }
  if (ct === 'messagereference') return null; // rendered as a quote above the body
  if (ct === 'application/vnd.microsoft.card.adaptive') {
    const texts = adaptiveCardTexts(att.content);
    return '- Card: ' + (texts.length ? oneLine(texts.join(' ')) : (name || 'adaptive card with no text'));
  }
  if (att.contentUrl) return '- Attachment: [' + (name || att.contentUrl) + '](' + markdownUrl(att.contentUrl) + ')';
  return '- Attachment: ' + (name || 'unnamed') + ' (' + (att.contentType || 'unknown type') + ')';
}

function chatToMarkdown(messages) {
  const list = (Array.isArray(messages) ? messages : []).filter((m) => m && typeof m === 'object').slice();
  list.sort((a, b) => {
    const ta = timeKey(a.createdDateTime);
    const tb = timeKey(b.createdDateTime);
    if (ta !== tb) return ta < tb ? -1 : 1;
    const ia = String(a.id || '');
    const ib = String(b.id || '');
    if (/^\d+$/.test(ia) && /^\d+$/.test(ib) && ia.length !== ib.length) return ia.length < ib.length ? -1 : 1;
    return compareText(ia, ib);
  });
  const out = [];
  for (const m of list) {
    const when = utcStamp(m.createdDateTime);
    const who = identityName(m.from) || 'Unknown sender';
    if (m.deletedDateTime) { out.push('*(' + when + ') message from ' + who + ' deleted*'); continue; }
    // Graph returns policyViolation on a message the tenant's DLP flagged. Copying such a message into a
    // local markdown file, where DLP and retention no longer reach it, is the one thing DLP exists to stop:
    // the message is withheld, and only who and when survive. No new scope — it is in the same GET.
    if (m.policyViolation) {
      out.push('*(' + when + ') message from ' + who + " withheld: your organisation's data-loss-prevention policy flagged it*");
      continue;
    }
    if (m.messageType && m.messageType !== 'message') { out.push('*(' + when + ') ' + summarizeEvent(m) + '*'); continue; }
    const parts = ['**' + who + '** (' + when + ')' + (m.lastEditedDateTime ? ' (edited)' : '') + ':'];
    if (m.subject) parts.push('Subject: ' + oneLine(m.subject));
    const atts = Array.isArray(m.attachments) ? m.attachments : [];
    for (const att of atts) {
      if (String(att && att.contentType).toLowerCase() !== 'messagereference') continue;
      const c = parseJsonMaybe(att.content) || {};
      const sender = identityName(c.messageSender) || 'someone';
      parts.push('> Replying to **' + sender + '**: ' + oneLine(c.messagePreview || ''));
    }
    const body = m.body || {};
    const text = String(body.contentType || '').toLowerCase() === 'text'
      ? String(body.content || '').replace(/\r\n?/g, '\n').trim()
      : htmlToMarkdown(body.content || '').trim();
    if (text) parts.push(text);
    const lines = atts.map((a) => attachmentLine(a || {})).filter(Boolean);
    if (lines.length) parts.push(lines.join('\n'));
    out.push(parts.join('\n\n'));
  }
  return out.length ? out.join('\n\n') + '\n' : '_No messages._\n';
}

// ── Copilot interactions (the aiInteraction export shape) ─────────────────────────────────────────
// The BizChat answer text lives in an Adaptive Card attachment, not in body: a JSON string whose
// TextBlocks hold markdown. Microsoft's example carries the answer twice — once with [n](url) citations
// and once as id MessageTextField with bare [^n^] footnotes — so the MessageTextField copy is dropped
// whenever another block has text, and exact duplicates are dropped too.
function adaptiveCardTexts(content) {
  const card = parseJsonMaybe(content);
  if (!card) return typeof content === 'string' && content.trim() ? [content.trim()] : [];
  const blocks = [];
  const walk = (n) => {
    if (Array.isArray(n)) { n.forEach(walk); return; }
    if (!n || typeof n !== 'object') return;
    if (n.type === 'TextBlock' && typeof n.text === 'string') blocks.push({ id: n.id, text: n.text.trim() });
    else if (n.type === 'RichTextBlock' && Array.isArray(n.inlines)) {
      blocks.push({ id: n.id, text: n.inlines.map((x) => (typeof x === 'string' ? x : (x && x.text) || '')).join('').trim() });
    }
    for (const k of Object.keys(n)) if (n[k] && typeof n[k] === 'object') walk(n[k]);
  };
  walk(card);
  const withText = blocks.filter((b) => b.text);
  const hasPrimary = withText.some((b) => b.id !== 'MessageTextField');
  const seen = new Set();
  const out = [];
  for (const b of withText) {
    if (hasPrimary && b.id === 'MessageTextField') continue;
    if (seen.has(b.text)) continue;
    seen.add(b.text);
    out.push(b.text);
  }
  return out;
}

// URLs in text, trailing punctuation and Copilot's [^n^] citation suffix trimmed. Order of appearance.
function extractUrls(text) {
  const out = [];
  const re = /https?:\/\/[^\s<>"'`\]]+/g;
  let m;
  while ((m = re.exec(String(text || ''))) !== null) {
    let u = m[0].replace(/\[\^\d+\^?$/, '');
    for (;;) {
      const before = u;
      u = u.replace(/[.,;:!?*_'"]+$/, '');
      if (u.endsWith(')') && (u.match(/\(/g) || []).length < (u.match(/\)/g) || []).length) u = u.slice(0, -1);
      if (u === before) break;
    }
    out.push(decodeEntities(u));
  }
  return out;
}

function bodyToMarkdown(body) {
  if (!body) return '';
  const content = String(body.content == null ? '' : body.content);
  if (String(body.contentType || '').toLowerCase() === 'html') return htmlToMarkdown(content).trim();
  return content.replace(/\r\n?/g, '\n').trim();
}

function titleFrom(markdownText, fallback) {
  const plain = oneLine(String(markdownText || '').replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1').replace(/[*_`#>\\]/g, ''));
  if (!plain) return fallback;
  const chars = Array.from(plain);
  return chars.length > 80 ? chars.slice(0, 79).join('').trimEnd() + '…' : plain;
}

function makeLinkSet() {
  const list = [];
  const seen = new Set();
  return {
    list,
    add(u) {
      if (!u || typeof u !== 'string') return;
      const v = decodeEntities(u.trim());
      if (!/^https?:\/\//i.test(v) || seen.has(v)) return;
      seen.add(v);
      list.push(v);
    },
  };
}

function compareSessions(a, b) {
  const ta = timeKey(a.startedAt);
  const tb = timeKey(b.startedAt);
  if (ta !== tb) return ta < tb ? -1 : 1;
  return compareText(a.sessionId, b.sessionId);
}

function interactionsToSessions(interactions) {
  const list = Array.isArray(interactions) ? interactions : (interactions && Array.isArray(interactions.value) ? interactions.value : []);
  const groups = new Map();
  for (const it of list) {
    if (!it || typeof it !== 'object') continue;
    const sid = it.sessionId ? String(it.sessionId) : '(no session id)';
    if (!groups.has(sid)) groups.set(sid, []);
    groups.get(sid).push(it);
  }
  const sessions = [];
  for (const [sessionId, items] of groups) {
    items.sort((a, b) => {
      const ta = timeKey(a.createdDateTime);
      const tb = timeKey(b.createdDateTime);
      if (ta !== tb) return ta < tb ? -1 : 1;
      return compareText(String(a.id || ''), String(b.id || ''));
    });
    const exchanges = [];
    const byRequest = new Map();
    items.forEach((it, idx) => {
      const rid = it.requestId ? 'request:' + it.requestId : 'item:' + (it.id || idx);
      let ex = byRequest.get(rid);
      if (!ex) { ex = { prompts: [], responses: [], others: [] }; byRequest.set(rid, ex); exchanges.push(ex); }
      const type = String(it.interactionType || '');
      (type === 'userPrompt' ? ex.prompts : type === 'aiResponse' ? ex.responses : ex.others).push(it);
    });
    const links = makeLinkSet();
    const apps = [];
    for (const it of items) if (it.appClass && apps.indexOf(String(it.appClass)) < 0) apps.push(String(it.appClass));
    let title = '';
    const renderItem = (it, role) => {
      const who = identityName(it.from) || (role === 'prompt' ? 'User' : 'Copilot');
      const parts = ['**' + who + '** (' + (role === 'prompt' ? 'prompt' : role === 'response' ? 'response' : String(it.interactionType || 'item')) + ', ' + utcStamp(it.createdDateTime) + '):'];
      const bodyMd = bodyToMarkdown(it.body);
      if (bodyMd) { parts.push(bodyMd); extractUrls(bodyMd).forEach(links.add); }
      if (role === 'prompt' && !title) title = titleFrom(bodyMd, '');
      const lines = [];
      for (const att of Array.isArray(it.attachments) ? it.attachments : []) {
        if (!att) continue;
        if (String(att.contentType || '').toLowerCase() === 'application/vnd.microsoft.card.adaptive') {
          const texts = adaptiveCardTexts(att.content);
          if (texts.length) { parts.push(texts.join('\n\n')); texts.forEach((t) => extractUrls(t).forEach(links.add)); }
          continue;
        }
        if (att.contentUrl) links.add(att.contentUrl);
        lines.push(attachmentLine(att));
      }
      for (const l of Array.isArray(it.links) ? it.links : []) {
        if (!l || !l.linkUrl) continue;
        links.add(l.linkUrl);
        lines.push('- Link: [' + (oneLine(l.displayName) || oneLine(l.linkUrl)) + '](' + markdownUrl(decodeEntities(String(l.linkUrl))) + ')' +
          (l.linkType ? ' (' + oneLine(l.linkType) + ')' : ''));
      }
      for (const c of Array.isArray(it.contexts) ? it.contexts : []) {
        if (!c) continue;
        if (/^https?:\/\//i.test(String(c.contextReference || ''))) links.add(c.contextReference);
        lines.push('- Context: ' + (oneLine(c.displayName) || 'unnamed') + (c.contextType ? ' (' + oneLine(c.contextType) + ')' : '') +
          (c.contextReference ? ': `' + oneLine(c.contextReference) + '`' : ''));
      }
      if (lines.length) parts.push(lines.join('\n'));
      return parts.join('\n\n');
    };
    const body = [];
    exchanges.forEach((ex, n) => {
      const firstItem = ex.prompts[0] || ex.responses[0] || ex.others[0];
      body.push('## Exchange ' + (n + 1) + ' · ' + utcStamp(firstItem.createdDateTime));
      for (const it of ex.prompts) body.push(renderItem(it, 'prompt'));
      for (const it of ex.responses) body.push(renderItem(it, 'response'));
      for (const it of ex.others) body.push(renderItem(it, 'other'));
    });
    if (!title) {
      const ctx = items.map((it) => (Array.isArray(it.contexts) ? it.contexts : []).map((c) => c && c.displayName).find(Boolean)).find(Boolean);
      title = oneLine(ctx) || 'Copilot session';
    }
    const startedAt = isoOrNull(items[0].createdDateTime);
    const head = ['# ' + title, '', '- Session: `' + sessionId + '`', '- Started: ' + (startedAt || 'unknown')];
    if (apps.length) head.push('- Apps: ' + apps.join(', '));
    sessions.push({ sessionId, startedAt, title, markdown: head.join('\n') + '\n\n' + body.join('\n\n') + '\n', links: links.list });
  }
  return sessions.sort(compareSessions);
}

// ── consumer Copilot activity export (CSV) ────────────────────────────────────────────────────────
function parseCsv(text) {
  const s = String(text == null ? '' : text).replace(/^\uFEFF/, '');
  const firstLine = s.slice(0, Math.max(0, s.search(/\r|\n/)) || s.length);
  const delimiter = firstLine.indexOf(',') >= 0 ? ',' : firstLine.indexOf('\t') >= 0 ? '\t' : firstLine.indexOf(';') >= 0 ? ';' : ',';
  const rows = [];
  let row = [];
  let field = '';
  let quoted = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (quoted) {
      if (c === '"') { if (s[i + 1] === '"') { field += '"'; i++; } else quoted = false; } else field += c;
      continue;
    }
    if (c === '"' && field === '') { quoted = true; continue; }
    if (c === delimiter) { row.push(field); field = ''; continue; }
    if (c === '\r' || c === '\n') {
      if (c === '\r' && s[i + 1] === '\n') i++;
      row.push(field); rows.push(row); row = []; field = '';
      continue;
    }
    field += c;
  }
  if (field !== '' || row.length) { row.push(field); rows.push(row); }
  return rows.filter((r) => !(r.length === 1 && r[0] === ''));
}

// The column names each role is recognised by, compared lowercased with every non-alphanumeric removed.
// A header that names none of the grouping columns, or none of the text columns, is refused with the
// columns listed: the export's real header is unmeasured, and guessing one silently would misfile chats.
const CSV_COLUMN_ROLES = {
  conversationId: 'conversationid chatid threadid sessionid conversationguid',
  conversationTitle: 'conversationtitle conversationname conversation title chattitle chatname topic',
  time: 'timestamp time datetime date createdat createddatetime createdtime messagetime timecreated createdon sentat sent',
  author: 'author role sender speaker from participant messageauthor authorrole messagerole who',
  message: 'message text content body messagetext messagecontent messagebody',
  prompt: 'prompt userprompt question request usermessage yourmessage input query',
  response: 'response answer copilotresponse airesponse reply copilotmessage botresponse output',
};

function consumerCsvToSessions(csvText) {
  const rows = parseCsv(csvText);
  const header = rows.length ? rows[0].map((h) => h.trim()) : [];
  const norm = header.map((h) => h.toLowerCase().replace(/[^a-z0-9]/g, ''));
  const column = {};
  for (const role of Object.keys(CSV_COLUMN_ROLES)) {
    const names = CSV_COLUMN_ROLES[role].split(' ');
    let best = -1;
    for (const name of names) { const i = norm.indexOf(name); if (i >= 0 && Object.values(column).indexOf(i) < 0) { best = i; break; } }
    if (best >= 0) column[role] = best;
  }
  const group = column.conversationId !== undefined ? column.conversationId : column.conversationTitle;
  const hasText = column.message !== undefined || column.prompt !== undefined || column.response !== undefined;
  if (group === undefined || !hasText) {
    throw new Error('unrecognised Copilot CSV header: need a conversation id or title column and a message ' +
      '(or prompt/response) column; columns seen: ' + (header.length ? header.join(', ') : '(none)'));
  }
  const used = new Set(Object.values(column));
  const unrendered = header.filter((_, i) => !used.has(i));
  const cell = (r, role) => (column[role] === undefined ? '' : String(r[column[role]] == null ? '' : r[column[role]]));
  const groups = new Map();
  rows.slice(1).forEach((r, index) => {
    if (r.every((v) => !String(v).trim())) return;
    const sid = cell(r, group === column.conversationId ? 'conversationId' : 'conversationTitle').trim() || '(no conversation id)';
    if (!groups.has(sid)) groups.set(sid, []);
    groups.get(sid).push({ r, index });
  });
  const sessions = [];
  for (const [sessionId, entries] of groups) {
    entries.sort((a, b) => {
      const ta = timeKey(cell(a.r, 'time'));
      const tb = timeKey(cell(b.r, 'time'));
      if (ta !== tb) return ta < tb ? -1 : 1;
      return a.index - b.index;
    });
    const links = makeLinkSet();
    const parts = [];
    let firstText = '';
    for (const { r } of entries) {
      const when = cell(r, 'time').trim();
      const stamp = when ? ' (' + (Number.isFinite(parseUtc(when)) ? utcStamp(when) : when) + ')' : '';
      const say = (who, text) => {
        const t = String(text).replace(/\r\n?/g, '\n').trim();
        if (!t) return;
        if (!firstText) firstText = t;
        extractUrls(t).forEach(links.add);
        parts.push('**' + who + '**' + stamp + ':\n\n' + t);
      };
      if (column.message !== undefined) say(oneLine(cell(r, 'author')) || 'Unknown author', cell(r, 'message'));
      if (column.prompt !== undefined) say(oneLine(cell(r, 'author')) || 'You', cell(r, 'prompt'));
      if (column.response !== undefined) say('Copilot', cell(r, 'response'));
    }
    const titleCell = column.conversationTitle !== undefined ? oneLine(cell(entries[0].r, 'conversationTitle')) : '';
    const title = titleCell || titleFrom(firstText, 'Copilot conversation');
    const startedAt = entries.map((e) => isoOrNull(cell(e.r, 'time'))).find(Boolean) || null;
    const head = ['# ' + title, '', '- Conversation: `' + sessionId + '`', '- Started: ' + (startedAt || 'unknown'),
      '- Source: Microsoft Copilot activity history export (CSV)',
      '- Columns rendered: ' + header.filter((_, i) => used.has(i)).join(', ') +
      (unrendered.length ? ' · not rendered: ' + unrendered.join(', ') : '')];
    sessions.push({ sessionId, startedAt, title, markdown: head.join('\n') + '\n\n' + (parts.length ? parts.join('\n\n') : '_No messages._') + '\n', links: links.list });
  }
  return sessions.sort(compareSessions);
}

// ── names and front matter ────────────────────────────────────────────────────────────────────────
function slugify(s) {
  const words = String(s == null ? '' : s).normalize('NFKD').replace(/[\u0300-\u036f]/g, '').toLowerCase().match(/[a-z0-9]+/g) || [];
  let out = words.join('-');
  if (out.length > 60) out = out.slice(0, 60).replace(/-+$/, '');
  return out || 'untitled';
}

// A string is quoted when a YAML 1.1 or 1.2 reader would give it back as anything but the same string:
// a number, a date, a boolean (yes/no/on/off included), null, an indicator character, or a line break.
function yamlNeedsQuotes(s) {
  return s === '' || s !== s.trim() ||
    /[\u0000-\u001f\u007f-\u009f\u2028\u2029\uFEFF]/.test(s) ||
    /^[-?:,[\]{}#&*!|>'"%@`=]/.test(s) || /^<</.test(s) ||
    /: |:$| #/.test(s) ||
    /^(?:true|false|yes|no|y|n|on|off|null|~)$/i.test(s) ||
    /^[-+]?(?:\.?\d|\.(?:inf|nan)$)/i.test(s);
}
function yamlQuote(s) {
  return JSON.stringify(s).replace(/[\u007f-\u009f\u2028\u2029\uFEFF]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0'));
}
function yamlScalar(v) {
  if (v === null || v === undefined) return 'null';
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (typeof v === 'number') return Number.isFinite(v) ? String(v) : yamlQuote(String(v));
  if (v instanceof Date) return yamlQuote(Number.isFinite(v.getTime()) ? v.toISOString() : String(v));
  const s = String(v);
  return yamlNeedsQuotes(s) ? yamlQuote(s) : s;
}
const isPlainObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v) && !(v instanceof Date);

function yamlNode(value, indent) {
  const pad = '  '.repeat(indent);
  if (Array.isArray(value)) {
    if (!value.length) return { inline: '[]' };
    const lines = [];
    for (const item of value) {
      const n = yamlNode(item, indent + 1);
      if (n.inline !== undefined) { lines.push(pad + '- ' + n.inline); continue; }
      lines.push(pad + '- ' + n.lines[0].slice(pad.length + 2));
      for (const l of n.lines.slice(1)) lines.push(l);
    }
    return { lines };
  }
  if (isPlainObject(value)) {
    const keys = Object.keys(value);
    if (!keys.length) return { inline: '{}' };
    const lines = [];
    for (const k of keys) yamlEntry(lines, k, value[k], indent);
    return { lines };
  }
  return { inline: yamlScalar(value) };
}
function yamlEntry(lines, key, value, indent) {
  const pad = '  '.repeat(indent);
  const k = yamlScalar(String(key));
  const n = yamlNode(value, indent + 1);
  if (n.inline !== undefined) lines.push(pad + k + ': ' + n.inline);
  else { lines.push(pad + k + ':'); for (const l of n.lines) lines.push(l); }
}

// frontMatter(obj, keyOrder) — every key in keyOrder, in that order (a missing one is written null, so the
// schema's key set is fixed), then any other key of obj in sorted order. Nested objects keep their own
// insertion order.
function frontMatter(obj, keyOrder) {
  const o = obj || {};
  const keys = [];
  for (const k of Array.isArray(keyOrder) ? keyOrder : []) if (keys.indexOf(k) < 0) keys.push(k);
  for (const k of Object.keys(o).sort()) if (keys.indexOf(k) < 0) keys.push(k);
  const lines = [];
  for (const k of keys) yamlEntry(lines, k, o[k], 0);
  return '---\n' + lines.join('\n') + (lines.length ? '\n' : '') + '---\n';
}

// ═════════════════════════════════════════════════════════════════════════════════════════════════
// SHIPPED FIXTURES — node render.js --selftest
// Each positive check sits beside a negative control that proves the same check can say no.
// ═════════════════════════════════════════════════════════════════════════════════════════════════
function selftest(write) {
  const say = write || ((s) => process.stdout.write(s + '\n'));
  let passed = 0;
  let failed = 0;
  const check = (name, ok, detail) => {
    if (ok) { passed++; say('ok   render: ' + name); return; }
    failed++;
    say('FAIL render: ' + name + (detail ? '\n       ' + String(detail).replace(/\n/g, '\n       ') : ''));
  };
  const same = (name, got, want) => check(name, got === want, 'want ' + JSON.stringify(want) + '\ngot  ' + JSON.stringify(got));
  const throwsWith = (fn, re) => { try { fn(); return false; } catch (e) { return re.test(String(e && e.message)); } };

  // ── entities ──
  same('the Latin-1 entity table holds exactly 96 names', LATIN1_ENTITY_NAMES.length, 96);
  same('entities decode by name, decimal and hex, and leave unknown names alone',
    decodeEntities('&eacute;&yuml;&#233;&#x1F600;&amp;&bogus;&#0;'), 'éÿé\u{1F600}&&bogus;\uFFFD');

  // ── VTT ──
  const vtt = [
    'WEBVTT', '', 'NOTE synthetic Teams-shaped transcript', 'spanning two lines', '',
    'STYLE', '::cue { color: yellow }', '',
    '3f1c2a9e-1b7d-4c6e-9a51-0d2f8e7b6c11/12-0', '00:00:03.120 --> 00:00:05.480 align:start position:10%',
    "<v Ana Pérez>Morning everyone, let&apos;s start</v>", '',
    '3f1c2a9e-1b7d-4c6e-9a51-0d2f8e7b6c11/12-1', '00:00:05.480 --> 00:00:08.900',
    '<v Ana Pérez>with the <c.yellow>budget</c> &amp; the deck.</v>', '',
    '3f1c2a9e-1b7d-4c6e-9a51-0d2f8e7b6c11/15-0', '00:00:09.100 --> 00:00:12.000',
    "<v Ben O'Neil>Sounds good. I have", 'two updates.</v>', '',
    '00:00:12.000 --> 00:00:14.250', "<v Ben O'Neil>First, Q1 is &lt;done&gt;.<00:00:13.500></v>",
    '01:02:03.000 --> 01:02:05.000', '<v.loud Ana Pérez>Great.</v>', '',
    '01:02:06.000 --> 01:02:08.000', '- a line that reads like a list item', '',
  ].join('\n');
  const vttWant = [
    '**Ana Pérez** [00:00:03]', "Morning everyone, let's start with the budget & the deck.", '',
    "**Ben O'Neil** [00:00:09]", 'Sounds good. I have two updates. First, Q1 is &lt;done&gt;.', '',
    '**Ana Pérez** [01:02:03]', 'Great.', '',
    '**Unattributed** [01:02:06]', '\\- a line that reads like a list item', '',
  ].join('\n');
  same('vtt: cue ids, NOTE and STYLE blocks, settings and styling dropped; same-speaker cues merged', vttToMarkdown(vtt), vttWant);
  same('vtt: CRLF line endings plus a BOM render byte-identically', vttToMarkdown('\uFEFF' + vtt.replace(/\n/g, '\r\n')), vttWant);
  const alternating = 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n<v A>one</v>\n\n00:00:02.000 --> 00:00:03.000\n<v B>two</v>\n\n' +
    '00:00:03.000 --> 00:00:04.000\n<v A>three</v>\n';
  same('vtt NEGATIVE CONTROL: the same speaker separated by another is NOT merged (three turns)',
    (vttToMarkdown(alternating).match(/^\*\*/gm) || []).length, 3);
  const metadataCues = 'WEBVTT\n00:00:16.246 --> 00:00:17.726\n' +
    '{"speakerName":"Ana Pérez","spokenText":"Morning everyone,"}\n\n00:00:17.726 --> 00:00:19.000\n' +
    '{"speakerName":"Ana Pérez","spokenText":"let\'s start."}\n\n00:00:19.100 --> 00:00:21.000\n{"speakerName":"Ben O\'Neil","spokenText":"Two updates."}\n';
  same('vtt: metadataContent JSON cues use speakerName and spokenText', vttToMarkdown(metadataCues),
    "**Ana Pérez** [00:00:16]\nMorning everyone, let's start.\n\n**Ben O'Neil** [00:00:19]\nTwo updates.\n");
  same('vtt: a line of spaces inside a cue does not end it — the spoken line after it is kept',
    vttToMarkdown('WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n<v A>one\n   \n<v A>kept after the spaces\n'), '**A** [00:00:01]\none kept after the spaces\n');
  same('vtt: with the blank line between cues missing, the next cue\'s id (a number, a Teams GUID/n-n) is dropped, not spoken',
    vttToMarkdown('WEBVTT\n\n1\n00:00:01.000 --> 00:00:02.000\n<v A>one\n2\n00:00:03.000 --> 00:00:04.000\n<v B>two\n' +
      '3f1c2a9e-1b7d-4c6e-9a51-0d2f8e7b6c11/15-0\n00:00:05.000 --> 00:00:06.000\n<v B>three\n'), '**A** [00:00:01]\none\n\n**B** [00:00:03]\ntwo three\n');
  same('vtt NEGATIVE CONTROL: a spoken last line before a timing line is NOT taken for an id',
    vttToMarkdown('WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n<v A>I think\nyes\n00:00:03.000 --> 00:00:04.000\n<v B>two\n'), '**A** [00:00:01]\nI think yes\n\n**B** [00:00:03]\ntwo\n');
  same('vtt: voice names are entity-decoded like the speech, and stay inert markdown',
    vttToMarkdown('WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n<v R&amp;D Room>x\n\n00:00:02.000 --> 00:00:03.000\n<v A &gt; B>y\n'), '**R&D Room** [00:00:01]\nx\n\n**A &gt; B** [00:00:02]\ny\n');
  same('vtt: a transcript with no cues says so instead of rendering empty', vttToMarkdown('WEBVTT\n\nNOTE nothing here\n'),
    '_No spoken content in this transcript._\n');

  // ── aiInsight — the shape of Microsoft's documented callAiInsight example ──
  const insight = {
    '@odata.context': "https://graph.microsoft.com/v1.0/$metadata#copilot/users('b935e675-5e67-48b9-8d45-249d5f88e964')/onlineMeetings('YTc3OT...')/aiInsights/$entity",
    id: 'Z2HWbT...', callId: 'af630fe0-04d3-4559-8cf9-91fe45e36296', contentCorrelationId: 'bc842d7a-2f6e-4b18-a1c7-73ef91d5c8e3',
    createdDateTime: '2024-05-27T08:17:10.7261294Z', endDateTime: '2024-05-27T08:32:10.7261294Z',
    meetingNotes: [{ title: 'Introducing Project Objectives and Key Stakeholders', text: 'The stakeholders present included representatives from each department involved in the project, ensuring alignment and clear communication channels from the start.',
      subpoints: [{ title: 'Discussion on action items', text: 'Action items were assigned to team members, and a follow-up meeting schedule was established.' }] }],
    actionItems: [{ title: 'Finalize Project Timeline', text: 'Review and finalize the project timeline to ensure alignment with stakeholder expectations and resource availability.', ownerDisplayName: 'Bella Smith' },
      { title: 'Prepare Presentation Draft', text: 'Draft a presentation outlining project goals, objectives, and progress updates for review by the project stakeholders.', ownerDisplayName: 'Bella Smith' }],
    viewpoint: { mentionEvents: [
      { speaker: { application: null, device: null, user: { '@odata.type': '#Microsoft.Teams.GraphSvc.teamworkUserIdentity', id: '9a7608d3-53e4-4a92-804f-ef43f1e5f5b5', displayName: 'John Smith', userIdentityType: 'aadUser', tenantId: 'd1aeb56e' } },
        eventDateTime: '2024-05-21T09:00:00', transcriptUtterance: 'We need to get approval from Sarah Johnson before proceeding with the budget allocation.' },
      { speaker: { user: { displayName: 'Emily Davis' } }, eventDateTime: '2024-05-21T09:15:00', transcriptUtterance: 'Sarah Johnson suggested reaching out to potential vendors | for the upcoming project.' }] },
  };
  same('aiInsight: notes as a nested list, action items with owners, mentions as a list', aiInsightToMarkdown(insight), [
    '## Copilot meeting notes', '', '_AI-generated by Microsoft 365 Copilot; it may be inaccurate._', '',
    '- Insight: `Z2HWbT...`', '- Call: `af630fe0-04d3-4559-8cf9-91fe45e36296`', '- Content correlation: `bc842d7a-2f6e-4b18-a1c7-73ef91d5c8e3`',
    '- Covers: 2024-05-27T08:17:10.7261294Z to 2024-05-27T08:32:10.7261294Z', '',
    '### Meeting notes', '',
    '- **Introducing Project Objectives and Key Stakeholders** — The stakeholders present included representatives from each department involved in the project, ensuring alignment and clear communication channels from the start.',
    '  - **Discussion on action items** — Action items were assigned to team members, and a follow-up meeting schedule was established.', '',
    '### Action items', '',
    '- [ ] **Finalize Project Timeline** — Review and finalize the project timeline to ensure alignment with stakeholder expectations and resource availability. _(owner: Bella Smith)_',
    '- [ ] **Prepare Presentation Draft** — Draft a presentation outlining project goals, objectives, and progress updates for review by the project stakeholders. _(owner: Bella Smith)_', '',
    '### Mentions of the signed-in user', '',
    '- 2024-05-21T09:00:00 — **John Smith**: We need to get approval from Sarah Johnson before proceeding with the budget allocation.',
    '- 2024-05-21T09:15:00 — **Emily Davis**: Sarah Johnson suggested reaching out to potential vendors | for the upcoming project.', '',
  ].join('\n'));
  const bare = aiInsightToMarkdown({ meetingNotes: [{ title: 'Only notes', text: 'x' }] });
  check('aiInsight NEGATIVE CONTROL: no action items renders "_None._" and no checkbox line',
    /### Action items\n\n_None\._/.test(bare) && !/- \[ \]/.test(bare), bare);

  // ── attendance ──
  const attendance = attendanceToMarkdown(
    { id: 'c9b6db1c-d5eb-427d-a5c0-20088d9b22d7', totalParticipantCount: 2, meetingStartDateTime: '2026-09-10T08:00:00Z', meetingEndDateTime: '2026-09-10T09:05:00Z' },
    [{ emailAddress: 'ben@contoso.com', totalAttendanceInSeconds: 59, role: 'Attendee', identity: { displayName: 'Ben | Guest' },
      attendanceIntervals: [{ joinDateTime: '2026-09-10T08:03:00Z' }] },
    { emailAddress: 'ana@contoso.com', totalAttendanceInSeconds: 3725, role: 'Organizer', identity: { displayName: 'Ana Pérez' },
      attendanceIntervals: [{ joinDateTime: '2026-09-10T08:00:00Z' }, { joinDateTime: '2026-09-10T08:30:00Z' }] }]);
  same('attendance: ordered by first join, seconds as h:mm:ss, pipes escaped, joins counted', attendance, [
    '## Attendance', '', '- Report: `c9b6db1c-d5eb-427d-a5c0-20088d9b22d7`', '- Meeting: 2026-09-10T08:00:00Z to 2026-09-10T09:05:00Z',
    '- Participants: 2', '', '| Name | Email | Role | Total | Joins |', '| --- | --- | --- | --- | --- |',
    '| Ana Pérez | ana@contoso.com | Organizer | 1:02:05 | 2 |', '| Ben \\| Guest | ben@contoso.com | Attendee | 0:00:59 | 1 |', ''].join('\n'));

  // ── chat ──
  const chatMessages = [
    { id: '1726048952000', messageType: 'message', createdDateTime: '2026-09-10T08:22:32Z', from: { user: { displayName: 'Ben O\'Neil' } },
      body: { contentType: 'html', content: '<p>See <a href="https://contoso.sharepoint.com/sites/Finance/Q3.xlsx">the sheet</a>, <at id="0">Ana</at>.<br>Thanks<attachment id="a1"></attachment></p>' },
      attachments: [{ id: 'a1', contentType: 'reference', contentUrl: 'https://contoso.sharepoint.com/sites/Finance/Shared Documents/Q3.xlsx', name: 'Q3.xlsx' }] },
    { id: '1726048950000', messageType: 'systemEventMessage', createdDateTime: '2026-09-10T08:22:30Z', body: { contentType: 'html', content: '<systemEventMessage/>' },
      eventDetail: { '@odata.type': '#microsoft.graph.callStartedEventMessageDetail', initiator: { user: { displayName: 'Ana Pérez' } } } },
    { id: '1726048951000', messageType: 'message', createdDateTime: '2026-09-10T08:22:31Z', from: { user: { displayName: 'Ana Pérez' } },
      body: { contentType: 'text', content: 'Morning!' } },
    { id: '1726048953000', messageType: 'message', createdDateTime: '2026-09-10T08:22:33Z', deletedDateTime: '2026-09-10T08:23:00Z',
      from: { user: { displayName: 'Ana Pérez' } }, body: { contentType: 'html', content: '' } },
    { id: '1726048954000', messageType: 'message', createdDateTime: '2026-09-10T08:22:34Z', from: { user: { displayName: 'Ben O\'Neil' } },
      policyViolation: { dlpAction: 'BlockAccess', policyTip: { generalText: 'This message may contain sensitive data.' } },
      body: { contentType: 'text', content: 'card 4111 1111 1111 1111 exp 03/28' } },
  ];
  const chat = chatToMarkdown(chatMessages);
  same('chat: oldest first, system event on one italic line, html body converted, attachment listed', chat, [
    '*(2026-09-10 08:22:30 UTC) call started by Ana Pérez*', '',
    '**Ana Pérez** (2026-09-10 08:22:31 UTC):', '', 'Morning!', '',
    "**Ben O'Neil** (2026-09-10 08:22:32 UTC):", '',
    'See [the sheet](https://contoso.sharepoint.com/sites/Finance/Q3.xlsx), @Ana.\\', 'Thanks', '',
    '- Attachment: [Q3.xlsx](https://contoso.sharepoint.com/sites/Finance/Shared%20Documents/Q3.xlsx)', '',
    '*(2026-09-10 08:22:33 UTC) message from Ana Pérez deleted*', '',
    "*(2026-09-10 08:22:34 UTC) message from Ben O'Neil withheld: your organisation's data-loss-prevention policy flagged it*", ''].join('\n'));
  check('chat: a DLP-flagged message keeps nothing of its body (the check can see the body when it is not flagged)',
    chat.indexOf('4111 1111') < 0 && chatToMarkdown([Object.assign({}, chatMessages[4], { policyViolation: undefined })]).indexOf('4111 1111') >= 0, chat);
  same('chat: input order does not matter (the reversed list renders byte-identically)', chatToMarkdown(chatMessages.slice().reverse()), chat);
  const movedEarlier = chatToMarkdown(chatMessages.map((m) => (m.id === '1726048952000' ? Object.assign({}, m, { createdDateTime: '2026-09-10T08:00:00Z' }) : m)));
  check('chat NEGATIVE CONTROL: moving a message\'s timestamp earlier moves it ahead of the system event',
    movedEarlier.indexOf('the sheet') >= 0 && movedEarlier.indexOf('the sheet') < movedEarlier.indexOf('call started'), movedEarlier);

  // ── htmlToMarkdown ──
  same('html: headings, emphasis, links, entities, br, and whitespace collapsed',
    htmlToMarkdown('<h1>Q3   plan</h1>\n<p>Revenue &amp; <b>cost</b>, <em>not</em> <a href="https://example.com/a b">the doc</a>&nbsp;&mdash; caf&eacute;<br>line two</p>'),
    '# Q3 plan\n\nRevenue & **cost**, *not* [the doc](https://example.com/a%20b) — café\\\nline two\n');
  same('html: script, style, head and comments are dropped',
    htmlToMarkdown('<html><head><title>T</title><style>p{color:red}</style></head><body><script>var x = "<p>no</p>";</script><!-- hidden --><p>kept</p></body></html>'),
    'kept\n');
  same('html: nested lists, implied </li>, ordered start, and a checkbox',
    htmlToMarkdown('<ul><li>one<li>two<ul><li>two-a</li></ul><li><input type="checkbox" checked>done</ul><ol start="3"><li>three<li>four</ol>'),
    '- one\n- two\n  - two-a\n- [x] done\n\n3. three\n4. four\n');
  same('html: a table becomes a GFM table with pipes escaped and short rows padded',
    htmlToMarkdown('<table><thead><tr><th>Name</th><th>Note</th></tr></thead><tbody><tr><td>Ana</td><td>a|b</td></tr><tr><td colspan="2">wide</td></tr><tr><td>solo</td></tr></tbody></table>'),
    '| Name | Note |\n| --- | --- |\n| Ana | a\\|b |\n| wide |  |\n| solo |  |\n');
  same('html: pre keeps whitespace in a fenced block with its language; inline code; images',
    htmlToMarkdown('<pre><code class="language-js">if (a) {\n  b();\n}\n</code></pre><p>Run <code>npm  test</code> <img alt="chart" src="https://example.com/c.png"></p>'),
    '```js\nif (a) {\n  b();\n}\n```\n\nRun `npm test` ![chart](https://example.com/c.png)\n');
  same('html: a paragraph that begins like a list item or heading is escaped, blockquote prefixed',
    htmlToMarkdown('<p>1. not a list</p><p># not a heading</p><blockquote><p>quoted</p><p>twice</p></blockquote><hr>'),
    '1\\. not a list\n\n\\# not a heading\n\n> quoted\n>\n> twice\n\n---\n');
  same('html: unclosed <p> is closed by the next block, and a layout table unwraps to its cells',
    htmlToMarkdown('<p>first<div>second</div><table><tr><td><p>cell one</p></td></tr><tr><td>cell two</td></tr></table>'),
    'first\n\nsecond\n\ncell one\n\ncell two\n');
  const noisy = htmlToMarkdown('<p>a<script>alert("SECRET")</script>b<style>.SECRET{}</style></p>');
  check('html NEGATIVE CONTROL: dropped script/style text never leaks into the output', noisy === 'ab\n' && noisy.indexOf('SECRET') < 0, noisy);
  same('html: escaped markup in text stays text — never a live tag in the markdown',
    htmlToMarkdown('<p>use &lt;tenant-id&gt; here</p><p>&lt;img src=x onerror=alert(1)&gt;</p>'), 'use &lt;tenant-id&gt; here\n\n&lt;img src=x onerror=alert(1)&gt;\n');
  same('html: markdown syntax in text is escaped (no emphasis, no link), and an entity-shaped "&" stays literal',
    htmlToMarkdown('<p>2*3*4 and [not a link](x), snake_case, a `tick` and a \\ &amp;lt;</p>'), '2\\*3\\*4 and \\[not a link\\](x), snake\\_case, a \\`tick\\` and a \\\\ &amp;lt;\n');
  same('html: javascript:, vbscript: and data: hrefs are dropped even with a tab, newline or leading space inside the scheme',
    htmlToMarkdown('<a href="java&#09;script:alert(1)">x</a> <a href=" VBScript:y">v</a> <a href="da&#10;ta:text/html,z">d</a> <img alt="i" src="jav&#x0A;ascript:q">'), 'x v d i\n');
  same('html NEGATIVE CONTROL: an ordinary link and an autolink with an underscore still render as links',
    htmlToMarkdown('<a href="https://example.com/a_b">https://example.com/a_b</a> <a href="https://example.com/x">the_doc</a>'), '<https://example.com/a_b> [the\\_doc](https://example.com/x)\n');
  same('html: empty input renders empty', htmlToMarkdown('   <!-- only a comment -->  '), '');
  let deep = '';
  try { deep = htmlToMarkdown('<div>'.repeat(20000) + '<b>bottom</b>' + '</div>'.repeat(20000)); } catch (e) { deep = 'threw: ' + e.message; }
  same('html: 20,000 nested elements render without overflowing the stack, text kept', deep, 'bottom\n');

  // ── Copilot interactions (aiInteraction; BizChat puts the answer in an Adaptive Card) ──
  const card = JSON.stringify({ type: 'AdaptiveCard', version: '1.5', body: [
    { type: 'TextBlock', wrap: true, text: 'Revenue grew 12% in Q3 [1](https://contoso.sharepoint.com/sites/Finance/Shared%20Documents/Q3.xlsx?web=1).' },
    { type: 'TextBlock', id: 'MessageTextField', text: 'Revenue grew 12% in Q3 [^1^] MESSAGE-TEXT-FIELD-COPY.' }] });
  const interactions = { value: [
    { id: 'r1', sessionId: '19:aa11bb22@thread.v2', requestId: 'q1', appClass: 'IPM.SkypeTeams.Message.Copilot.BizChat', interactionType: 'aiResponse',
      createdDateTime: '2026-09-11T10:00:05Z', from: { application: { displayName: 'Microsoft 365 Chat' } },
      body: { contentType: 'html', content: '<attachment id="c1"></attachment>' },
      attachments: [{ attachmentId: 'c1', contentType: 'application/vnd.microsoft.card.adaptive', content: card }],
      links: [{ linkUrl: 'https://teams.microsoft.com/l/meeting/details?eventId=AAMkAGE1&amp;EntityRepresentationId=025f05ac-1111', displayName: 'Weekly sync', linkType: 'Event' }] },
    { id: 'p1', sessionId: '19:aa11bb22@thread.v2', requestId: 'q1', appClass: 'IPM.SkypeTeams.Message.Copilot.BizChat', interactionType: 'userPrompt',
      createdDateTime: '2026-09-11T10:00:00Z', from: { user: { displayName: 'Ana Pérez' } }, body: { contentType: 'text', content: 'How did Q3 revenue do?' },
      contexts: [{ contextReference: 'https://microsoft.teams.com/threads/19:meeting_abc@thread.v2', contextType: 'TeamsMeeting', displayName: 'Weekly sync' }] },
    { id: 'p0', sessionId: '19:earlier@thread.v2', requestId: 'q0', interactionType: 'userPrompt', createdDateTime: '2026-09-01T09:00:00Z',
      from: { user: { displayName: 'Ana Pérez' } }, body: { contentType: 'text', content: 'Summarise https://example.org/report.pdf.' } },
  ] };
  const sessions = interactionsToSessions(interactions);
  same('interactions: grouped by sessionId, ordered by start', sessions.map((s) => s.sessionId).join(' '), '19:earlier@thread.v2 19:aa11bb22@thread.v2');
  const q3 = sessions[1] || { markdown: '', links: [] };
  same('interactions: title from the first prompt, startedAt from the earliest item', q3.title + ' @ ' + q3.startedAt, 'How did Q3 revenue do? @ 2026-09-11T10:00:00.000Z');
  check('interactions: the prompt renders before its paired response, and the answer comes from the card',
    q3.markdown.indexOf('How did Q3 revenue do?') >= 0 && q3.markdown.indexOf('How did Q3 revenue do?') < q3.markdown.indexOf('Revenue grew 12%'), q3.markdown);
  check('interactions NEGATIVE CONTROL: the MessageTextField duplicate of the answer is dropped', q3.markdown.indexOf('MESSAGE-TEXT-FIELD-COPY') < 0, q3.markdown);
  same('interactions: links from contexts[], card citations and links[] (entities decoded), in order of appearance', q3.links.join('\n'), [
    'https://microsoft.teams.com/threads/19:meeting_abc@thread.v2',
    'https://contoso.sharepoint.com/sites/Finance/Shared%20Documents/Q3.xlsx?web=1',
    'https://teams.microsoft.com/l/meeting/details?eventId=AAMkAGE1&EntityRepresentationId=025f05ac-1111'].join('\n'));
  same('interactions: a URL at the end of a sentence loses its full stop', (sessions[0] || { links: [] }).links.join(' '), 'https://example.org/report.pdf');

  // ── consumer CSV ──
  const csv = '\uFEFFConversation ID,Conversation Title,Timestamp,Author,Message,Image\r\n' +
    'c-2,"Trip, Lisbon",2026-08-02T10:00:05Z,Copilot,"Try ""Time Out Market"":\nhttps://example.com/lisbon.",\r\n' +
    'c-1,Budget,2026-08-01T09:00:00Z,You,Draft a budget,\r\n' +
    'c-2,"Trip, Lisbon",2026-08-02T10:00:00Z,You,Where should I eat?,photo.png\r\n';
  const consumer = consumerCsvToSessions(csv);
  same('csv: one session per conversation id, sessions ordered by start', consumer.map((s) => s.sessionId + '=' + s.title).join(' '), 'c-1=Budget c-2=Trip, Lisbon');
  const lisbon = consumer[1] || { markdown: '', links: [] };
  check('csv: quoted commas, doubled quotes and embedded newlines survive; rows ordered by time',
    lisbon.markdown.indexOf('Where should I eat?') < lisbon.markdown.indexOf('Try "Time Out Market":\nhttps://example.com/lisbon.') &&
    lisbon.markdown.indexOf('Where should I eat?') >= 0, lisbon.markdown);
  same('csv: links extracted, and the unrendered column is named', lisbon.links.join(' ') + ' | ' + /not rendered: (.*)/.exec(lisbon.markdown)[1], 'https://example.com/lisbon | Image');
  check('csv NEGATIVE CONTROL: an unknown header throws and lists every column it saw',
    throwsWith(() => consumerCsvToSessions('Foo,Bar Baz,Qux\n1,2,3\n'), /columns seen: Foo, Bar Baz, Qux$/));

  // ── slugify ──
  same('slugify: accents folded, punctuation collapsed', slugify('Q3 Budget Review — Ana Pérez & Co.'), 'q3-budget-review-ana-perez-co');
  const longSlug = slugify('word '.repeat(30));
  check('slugify: at most 60 characters and never ends in a hyphen', longSlug.length <= 60 && !/-$/.test(longSlug) && longSlug.length > 50, longSlug);
  same('slugify: nothing sluggable becomes "untitled"', slugify('—!!—'), 'untitled');

  // ── frontMatter ──
  const meta = { subject: 'Q3: budget # review', start: '2026-09-10T08:00:00Z', flag: 'yes', empty: '', version: '1.10',
    organizer: 'Ana Pérez <ana@contoso.com>', attendees: ['Ben <ben@contoso.com>', 'no'], multi: 'line one\nline two',
    artifacts: { transcript: 'available', recording: 'forbidden: needs OnlineMeetingRecording.Read.All' }, count: 3, extra_b: true, extra_a: null,
    history: [{ sha: '0badc0ffee12', at: '2026-09-10' }, { sha: 'e1f2', note: '' }] };
  const order = ['schema', 'subject', 'start', 'flag', 'empty', 'version', 'organizer', 'attendees', 'multi', 'artifacts', 'count'];
  const fm = frontMatter(Object.assign({ schema: 'microsoft365-archive/1' }, meta), order);
  same('frontMatter: fixed key order, then the rest sorted; strings YAML would retype are quoted', fm, [
    '---', 'schema: microsoft365-archive/1', 'subject: "Q3: budget # review"', 'start: "2026-09-10T08:00:00Z"', 'flag: "yes"',
    'empty: ""', 'version: "1.10"', 'organizer: Ana Pérez <ana@contoso.com>', 'attendees:', '  - Ben <ben@contoso.com>', '  - "no"',
    'multi: "line one\\nline two"', 'artifacts:', '  transcript: available', '  recording: "forbidden: needs OnlineMeetingRecording.Read.All"',
    'count: 3', 'extra_a: null', 'extra_b: true', 'history:', '  - sha: "0badc0ffee12"', '    at: "2026-09-10"', '  - sha: e1f2', '    note: ""', '---', ''].join('\n'));
  same('frontMatter: a key in keyOrder that the object lacks is written null', frontMatter({}, ['ical_uid']), '---\nical_uid: null\n---\n');
  // Independent read-back: a different YAML engine (Ruby's Psych, YAML 1.1 — the stricter reader for
  // yes/no/dates) must give back exactly the object that went in.
  const yamlRead = (text) => {
    const cp = require('child_process');
    const ruby = '/usr/bin/ruby';
    if (!require('fs').existsSync(ruby)) return null;
    const r = cp.spawnSync(ruby, ['-ryaml', '-rjson', '-e', 'puts JSON.generate(YAML.safe_load(STDIN.read))'],
      { input: text, encoding: 'utf8', timeout: 20000 });
    if (r.status !== 0) return { error: String(r.stderr).split('\n').filter((l) => !/warning/i.test(l)).join(' ').slice(0, 200) };
    try { return { value: JSON.parse(r.stdout) }; } catch (e) { return { error: 'unparsable ruby output' }; }
  };
  const readBack = yamlRead(fm.replace(/^---\n|---\n$/g, ''));
  if (readBack === null) say('skip render: frontMatter independent YAML read-back (no /usr/bin/ruby)');
  else {
    const wantBack = Object.assign({ schema: 'microsoft365-archive/1' }, meta);
    const canon = (o) => JSON.stringify(Object.keys(o).sort().reduce((a, k) => { a[k] = o[k]; return a; }, {}));
    check('frontMatter: Ruby YAML reads the front matter back as exactly the input object',
      readBack.value !== undefined && canon(readBack.value) === canon(wantBack), JSON.stringify(readBack));
    const naive = yamlRead('start: 2026-09-10\nflag: yes\n');
    check('frontMatter NEGATIVE CONTROL: the same reader retypes an UNquoted date and yes (the check can say no)',
      !(naive && naive.value && naive.value.start === '2026-09-10' && naive.value.flag === 'yes'), JSON.stringify(naive));
  }

  say('render.js selftest: ' + passed + ' passed, ' + failed + ' failed');
  return failed;
}

module.exports = {
  vttToMarkdown, aiInsightToMarkdown, attendanceToMarkdown, chatToMarkdown, htmlToMarkdown,
  interactionsToSessions, consumerCsvToSessions, slugify, frontMatter, selftest,
};

if (require.main === module) {
  if (process.argv[2] === '--selftest') process.exit(selftest() === 0 ? 0 : 1);
  process.stderr.write('render.js is a library for archive.js. Run: node render.js --selftest\n');
  process.exit(2);
}
