#!/bin/bash
# markdown-convert.sh — turn ONE file into markdown on stdout, or say exactly why it cannot.
#
#   markdown-convert.sh <file>                  markdown on stdout
#   markdown-convert.sh -- <file>               the same, for a file whose name starts with "-"
#   markdown-convert.sh --converter-id <file>   one line: the converter that WOULD be used, "<tool> <version>"
#                                               (e.g. "pandoc 3.11", "passthrough 1") or "none"
#   markdown-convert.sh --types                 every extension this dispatches, one per line
#   markdown-convert.sh --selftest              offline fixtures; rc 0 iff every case passes
#
# Shared by the meeting archive and by shared-folder. Both store the --converter-id beside what they
# convert, because the same bytes convert differently across converter versions: an upgrade is a
# REBASELINE of every view, not an edit to one.
#
# Exit codes — the contract both callers depend on:
#    0  converted
#    1  the converter ran and failed (its stderr is passed through)
#    2  usage: no such file, not a regular file, no argument
#   10  no converter installed for this type — stderr names the one install command
#   11  dataless — the file is a File Provider placeholder whose bytes are not on this Mac
#
# 🚨 A DATALESS FILE IS NEVER READ. OneDrive and iCloud keep "online-only" files as placeholders whose
# BSD flags carry SF_DATALESS (0x40000000). Opening one does not fail — it DOWNLOADS it, silently, which
# for a background refresher walking a client's library means hydrating the whole library. So the flag
# is read with `stat` (metadata only) before any byte is, and a file that carries it — or whose flags
# cannot be read at all — gets rc 11. A real dataless file cannot be manufactured offline, so the
# selftest drives the parse through a stub stat (DATALESS_STAT_COMMAND) and proves the file was not
# opened with one that is chmod 000: reading it would have failed.
#
# WHERE THE TOOLS ARE LOOKED FOR: PATH first, then MARKDOWN_CONVERT_TOOL_DIRS (colon-separated;
# default Homebrew's two prefixes and uv's $HOME/.local/bin). The second list exists because a launchd
# job runs with PATH=/usr/bin:/bin:/usr/sbin:/sbin, where neither pandoc nor markitdown ever is.
#
# Nothing here needs a network, writes a file outside its own temp dir, or needs any permission.

set -u

MARKDOWN_CONVERT_SF_DATALESS=1073741824        # 0x40000000, from <sys/stat.h>
MARKDOWN_CONVERT_PANDOC_INSTALL="brew install pandoc"
MARKDOWN_CONVERT_MARKITDOWN_INSTALL="uv tool install 'markitdown[all]'"
MARKDOWN_CONVERT_TYPES="md markdown txt csv json html htm docx odt rtf epub pptx xlsx xls pdf vtt"

markdown_convert_say() { printf 'markdown-convert: %s\n' "$*" >&2; }

# ── the lowercase extension of a path, or nothing. A bare dotfile (".profile") has none. ──────────
markdown_convert_extension() {
  local name="${1##*/}"
  case "$name" in
    .*.*) name="${name#.}" ;;
    .*)   return 0 ;;
  esac
  case "$name" in *.*) : ;; *) return 0 ;; esac
  printf '%s' "${name##*.}" | tr '[:upper:]' '[:lower:]'
}

# ── dataless detection ─────────────────────────────────────────────────────────────────────────────
# markdown_convert_flags_say_dataless <hex> — the PARSE, separated from the stat so it can be tested
# on literal values. `stat -f %Xf` prints the flags in hex with no 0x prefix. Anything that is not
# plain hex is treated as dataless: when we cannot tell, not reading is the safe answer.
markdown_convert_flags_say_dataless() {
  local hex="${1:-}"
  case "$hex" in ''|*[!0-9a-fA-F]*) return 0 ;; esac
  [ "${#hex}" -le 15 ] || return 0
  [ $(( 0x$hex & MARKDOWN_CONVERT_SF_DATALESS )) -ne 0 ]
}

# markdown_convert_is_dataless <file> — rc 0 when the file must not be read. -L: the flags of what a
# symlink points at, which is the file that would be opened.
markdown_convert_is_dataless() {
  local flags
  flags="$("${DATALESS_STAT_COMMAND:-/usr/bin/stat}" -L -f %Xf "$1" 2>/dev/null)" || return 0
  markdown_convert_flags_say_dataless "$flags"
}

# ── tool lookup ────────────────────────────────────────────────────────────────────────────────────
markdown_convert_find_tool() {
  local name="$1" found dir dirs
  found="$(command -v "$name" 2>/dev/null)"
  case "$found" in /*) [ -x "$found" ] && { printf '%s' "$found"; return 0; } ;; esac
  dirs="${MARKDOWN_CONVERT_TOOL_DIRS-/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin}"
  local IFS=:
  for dir in $dirs; do
    [ -n "$dir" ] && [ -x "$dir/$name" ] && [ ! -d "$dir/$name" ] && { printf '%s' "$dir/$name"; return 0; }
  done
  return 1
}

# markdown_convert_tool_version <path> — the version word of a tool's `--version` first line.
# `pandoc --version` → "pandoc 3.11"; `markitdown --version` → "markitdown 0.1.7". Last word, either way.
markdown_convert_tool_version() {
  local first
  first="$("$1" --version 2>/dev/null | sed -n 1p)"
  first="${first##* }"
  case "$first" in ''|*[!0-9A-Za-z.+_-]*) printf 'unknown' ;; *) printf '%s' "$first" ;; esac
}

# markdown_convert_plan <file> — decide, without reading the file, how it would be converted.
# Sets: plan_kind (passthrough|csv|json|pandoc|markitdown|none), plan_tool (path), plan_id (the
# converter id), plan_why (the rc-10 message when kind is none).
markdown_convert_plan() {
  local ext
  ext="$(markdown_convert_extension "$1")"
  plan_kind=none; plan_tool=""; plan_id=none; plan_why=""
  case "$ext" in
    md|markdown|txt) plan_kind=passthrough; plan_id="passthrough 1" ;;
    csv)             plan_kind=csv;         plan_id="csv-table 1" ;;
    json)            plan_kind=json;        plan_id="json-fence 1" ;;
    html|htm|docx|odt|rtf|epub)
      if plan_tool="$(markdown_convert_find_tool pandoc)"; then
        plan_kind=pandoc; plan_id="pandoc $(markdown_convert_tool_version "$plan_tool")"
      else
        plan_why="no converter for .$ext files is installed — install one with: $MARKDOWN_CONVERT_PANDOC_INSTALL"
      fi ;;
    pptx|xlsx|xls|pdf)
      # pandoc is deliberately NOT a fallback here: markitdown is the one that keeps pptx speaker
      # notes and reads pdf at all.
      if plan_tool="$(markdown_convert_find_tool markitdown)"; then
        plan_kind=markitdown; plan_id="markitdown $(markdown_convert_tool_version "$plan_tool")"
      else
        plan_why="no converter for .$ext files is installed — install one with: $MARKDOWN_CONVERT_MARKITDOWN_INSTALL"
      fi ;;
    vtt) plan_why="a .vtt transcript is rendered by the meeting archive itself, not here — nothing to install" ;;
    "")  plan_why="no converter for a file with no extension — nothing to install" ;;
    *)   plan_why="no converter for .$ext files — this tool does not handle the type, so there is nothing to install" ;;
  esac
}

# ── the built-in converters ────────────────────────────────────────────────────────────────────────
# csv → a GFM table. RFC 4180 quoting (commas, doubled quotes and newlines inside quotes), a UTF-8
# BOM and CRLF tolerated. A pipe in a cell is escaped `\|` or it would split the cell; a newline in
# a cell becomes <br>. Short rows are padded so every row has the header's column count.
markdown_convert_csv() {
  /usr/bin/awk '
    function esc(v,   out, i, c) {
      out = ""
      for (i = 1; i <= length(v); i++) { c = substr(v, i, 1); out = out ((c == "|") ? "\\|" : c) }
      return out
    }
    function endrecord() { cell[nrec, nf++] = field; field = ""; if (nf > maxc) maxc = nf; nrec++; nf = 0 }
    BEGIN { nrec = 0; nf = 0; maxc = 0; inq = 0; field = "" }
    {
      line = $0
      if (NR == 1) sub(/^\357\273\277/, "", line)
      sub(/\r$/, "", line)
      if (inq) field = field "<br>"
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (inq) {
          if (c == "\"") { if (substr(line, i + 1, 1) == "\"") { field = field "\""; i++ } else inq = 0 }
          else field = field c
        } else if (c == "\"") inq = 1
        else if (c == ",") { cell[nrec, nf++] = field; field = "" }
        else field = field c
      }
      if (!inq) endrecord()
    }
    END {
      if (inq) endrecord()
      if (nrec == 0) exit 0
      for (r = 0; r < nrec; r++) {
        row = "|"
        for (k = 0; k < maxc; k++) row = row " " esc(((r, k) in cell) ? cell[r, k] : "") " |"
        print row
        if (r == 0) { sep = "|"; for (k = 0; k < maxc; k++) sep = sep " --- |"; print sep }
      }
    }
  ' "$1"
}

# json → a fenced block, verbatim. The fence is one backtick longer than the longest backtick run in
# the file, so a value that contains ``` cannot close it early.
markdown_convert_json() {
  local run fence
  run="$(/usr/bin/awk '{ n = 0; for (i = 1; i <= length($0); i++) { if (substr($0, i, 1) == "`") { n++; if (n > m) m = n } else n = 0 } } END { print m + 0 }' "$1")" || return 1
  fence='```'
  while [ "${#fence}" -le "$run" ]; do fence="$fence\`"; done
  printf '%sjson\n' "$fence"
  /usr/bin/awk '{ print }' "$1" || return 1
  printf '%s\n' "$fence"
}

# markdown_convert_run <file> — the whole pipeline for one file; returns the contract's exit code.
markdown_convert_run() {
  local file="${1:-}" safe
  [ -n "$file" ] || { markdown_convert_say "usage: markdown-convert.sh <file>"; return 2; }
  [ -e "$file" ] || { markdown_convert_say "$file: no such file"; return 2; }
  [ -f "$file" ] || { markdown_convert_say "$file: not a regular file"; return 2; }
  markdown_convert_plan "$file"
  [ "$plan_kind" = none ] && { markdown_convert_say "$plan_why"; return 10; }
  # A path that starts with "-" would be read as an option — by stat below, and by pandoc and
  # markitdown — so every tool is handed the ./-prefixed form.
  case "$file" in /*) safe="$file" ;; *) safe="./$file" ;; esac
  if markdown_convert_is_dataless "$safe"; then
    markdown_convert_say "$file: dataless — not downloaded; reading it would download it. In Finder choose Always keep on this device, then convert again."
    return 11
  fi
  case "$plan_kind" in
    passthrough) /bin/cat "$safe" || return 1 ;;
    csv)         markdown_convert_csv "$safe" || return 1 ;;
    json)        markdown_convert_json "$safe" || return 1 ;;
    pandoc)
      # --sandbox: a client's html or docx may name other files or URLs; pandoc reads none of them.
      local format
      format="$(markdown_convert_extension "$file")"
      [ "$format" = htm ] && format=html
      if [ "$format" = docx ]; then
        "$plan_tool" --sandbox -f docx -t gfm --wrap=none --track-changes=all "$safe" || return 1
      else
        "$plan_tool" --sandbox -f "$format" -t gfm --wrap=none "$safe" || return 1
      fi ;;
    markitdown)  "$plan_tool" "$safe" || return 1 ;;
  esac
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════════════════════════
# SHIPPED FIXTURES — markdown-convert.sh --selftest
# Every positive case has a negative control beside it that proves the check can say no.
# ═════════════════════════════════════════════════════════════════════════════════════════════════
markdown_convert_selftest_total=0
markdown_convert_selftest_failed=0
markdown_convert_ok()  { markdown_convert_selftest_total=$((markdown_convert_selftest_total + 1)); printf '  ok   %s\n' "$1"; }
markdown_convert_bad() {
  markdown_convert_selftest_total=$((markdown_convert_selftest_total + 1))
  markdown_convert_selftest_failed=$((markdown_convert_selftest_failed + 1))
  printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
}
markdown_convert_is() { if [ "$2" = "$3" ]; then markdown_convert_ok "$1"; else markdown_convert_bad "$1" "want [$3] got [$2]"; fi; }

markdown_convert_selftest() {
  local self work rc out stub pandoc
  self="${BASH_SOURCE[0]:-$0}"
  self="$(CDPATH='' cd -- "$(dirname -- "$self")" && pwd -P)/$(basename -- "$self")"   # absolute: one case below runs from another dir
  work="$(mktemp -d -t markdown-convert-selftest)" || return 30
  printf 'markdown-convert.sh selftest · bash %s · %s\n' "${BASH_VERSION:-?}" "$(sw_vers -productVersion 2>/dev/null)"

  # 1. passthrough: the bytes out are the bytes in.
  printf '# Title\n\nbody with | pipe and `code`\n' > "$work/note.md"
  /bin/bash "$self" "$work/note.md" > "$work/note.out" 2>/dev/null; rc=$?
  markdown_convert_is "passthrough: rc 0" "$rc" "0"
  if cmp -s "$work/note.md" "$work/note.out"; then markdown_convert_ok "passthrough: output is byte-identical to the input"
  else markdown_convert_bad "passthrough: output differs from the input"; fi
  markdown_convert_is "passthrough: converter id" "$(/bin/bash "$self" --converter-id "$work/note.md")" "passthrough 1"
  printf 'plain\n' > "$work/UPPER.TXT"
  markdown_convert_is "extension is matched case-insensitively (.TXT is passthrough)" "$(/bin/bash "$self" --converter-id "$work/UPPER.TXT")" "passthrough 1"

  # 2. csv: a pipe inside a cell, a quoted comma, a doubled quote, a newline inside quotes, CRLF, a
  #    short row. The table is read back by SPLITTING it on unescaped pipes, not by grepping it.
  printf 'name,note,n\r\n"Smith, J","a | b",1\r\nplain,"say ""hi""\nthere"\r\nshort\r\n' > "$work/t.csv"
  /bin/bash "$self" "$work/t.csv" > "$work/t.out" 2>/dev/null; rc=$?
  markdown_convert_is "csv: rc 0" "$rc" "0"
  markdown_convert_is "csv: header + separator + 3 rows = 5 lines" "$(wc -l < "$work/t.out" | tr -d ' ')" "5"
  out="$(/usr/bin/awk '{ gsub(/\\\|/, "@"); n = split($0, parts, "|"); print n - 2 }' "$work/t.out" | sort -u | tr '\n' ' ')"
  markdown_convert_is "csv: every row splits into exactly 3 cells on unescaped pipes" "$out" "3 "
  out="$(/usr/bin/awk 'NR == 3 { gsub(/\\\|/, "@"); split($0, parts, "|"); print parts[2] "#" parts[3] }' "$work/t.out")"
  markdown_convert_is "csv: the quoted comma stays in its cell and the pipe is escaped" "$out" " Smith, J # a @ b "
  out="$(/usr/bin/awk 'NR == 4 { split($0, parts, "|"); print parts[3] }' "$work/t.out")"
  markdown_convert_is "csv: doubled quote unescaped, embedded newline becomes <br>" "$out" ' say "hi"<br>there '
  out="$(/usr/bin/awk 'NR == 2' "$work/t.out")"
  markdown_convert_is "csv: separator row has one cell per column" "$out" "| --- | --- | --- |"
  printf 'a,b\nc,d\n' > "$work/nopipe.csv"
  /bin/bash "$self" "$work/nopipe.csv" > "$work/nopipe.out" 2>/dev/null
  if /usr/bin/awk '/\\\|/ { found = 1 } END { exit found ? 0 : 1 }' "$work/nopipe.out"; then
    markdown_convert_bad "csv negative control: a csv with no pipe must produce no escaped pipe"
  else markdown_convert_ok "csv negative control: a csv with no pipe produces no escaped pipe"; fi

  # 3. json: fenced, verbatim inside, and a value holding ``` gets a longer fence.
  printf '{"a": [1, 2], "b": "x"}\n' > "$work/d.json"
  /bin/bash "$self" "$work/d.json" > "$work/d.out" 2>/dev/null; rc=$?
  markdown_convert_is "json: rc 0" "$rc" "0"
  markdown_convert_is "json: opens with a json fence" "$(sed -n 1p "$work/d.out")" '```json'
  markdown_convert_is "json: closes with the fence" "$(sed -n '$p' "$work/d.out")" '```'
  sed '1d;$d' "$work/d.out" > "$work/d.inner"
  if cmp -s "$work/d.json" "$work/d.inner"; then markdown_convert_ok "json: the fenced body is byte-identical to the file"
  else markdown_convert_bad "json: the fenced body differs from the file"; fi
  printf '{"s": "````"}\n' > "$work/ticks.json"
  markdown_convert_is "json: a value with a 4-backtick run gets a 5-backtick fence" "$(/bin/bash "$self" "$work/ticks.json" | sed -n 1p)" '`````json'

  # 4. types with no converter, and usage errors.
  printf 'x\n' > "$work/thing.xyz"
  /bin/bash "$self" "$work/thing.xyz" > /dev/null 2>&1; rc=$?
  markdown_convert_is "unknown extension: rc 10" "$rc" "10"
  markdown_convert_is "unknown extension: converter id is none" "$(/bin/bash "$self" --converter-id "$work/thing.xyz")" "none"
  printf 'WEBVTT\n' > "$work/call.vtt"
  /bin/bash "$self" "$work/call.vtt" > /dev/null 2>&1; rc=$?
  markdown_convert_is "vtt: rc 10 (the archive renders it itself)" "$rc" "10"
  /bin/bash "$self" "$work/absent.md" > /dev/null 2>&1; rc=$?
  markdown_convert_is "missing file: rc 2" "$rc" "2"
  /bin/bash "$self" > /dev/null 2>&1; rc=$?
  markdown_convert_is "no argument: rc 2" "$rc" "2"
  mkdir "$work/folder.md"
  /bin/bash "$self" "$work/folder.md" > /dev/null 2>&1; rc=$?
  markdown_convert_is "a directory: rc 2" "$rc" "2"
  # a RELATIVE name that starts with "-", after "--": stat (and the converters) must not read it as an option
  printf '# dash\n' > "$work/-notes.md"
  out="$(CDPATH='' cd -- "$work" && /bin/bash "$self" -- -notes.md 2>&1)"; rc=$?
  markdown_convert_is "a relative -notes.md after --: rc 0 and its bytes, not a dataless refusal" "$rc|$out" "0|# dash"
  (CDPATH='' cd -- "$work" && /bin/bash "$self" -notes.md > /dev/null 2>&1); rc=$?
  markdown_convert_is "negative control: the same name WITHOUT -- is an unknown option (rc 2)" "$rc" "2"
  /bin/bash "$self" --help | /usr/bin/awk '/markdown-convert\.sh -- <file>/ { f = 1 } END { exit f ? 0 : 1 }' \
    && markdown_convert_ok "--help documents the -- form" || markdown_convert_bad "--help does not document the -- form"

  # 5. the missing-converter arm runs on EVERY machine: with PATH and the tool dirs emptied, pandoc
  #    and markitdown types must say rc 10 and name the install command — read back from stderr.
  printf '<h1>x</h1>\n' > "$work/p.html"
  printf 'x' > "$work/s.pptx"
  out="$(PATH=/usr/bin:/bin MARKDOWN_CONVERT_TOOL_DIRS='' /bin/bash "$self" "$work/p.html" 2>&1 >/dev/null)"; rc=$?
  markdown_convert_is "no pandoc: html is rc 10" "$rc" "10"
  case "$out" in *"$MARKDOWN_CONVERT_PANDOC_INSTALL") markdown_convert_ok "no pandoc: stderr ends with the one install command" ;;
    *) markdown_convert_bad "no pandoc: stderr does not end with the install command" "$out" ;; esac
  out="$(PATH=/usr/bin:/bin MARKDOWN_CONVERT_TOOL_DIRS='' /bin/bash "$self" "$work/s.pptx" 2>&1 >/dev/null)"; rc=$?
  markdown_convert_is "no markitdown: pptx is rc 10" "$rc" "10"
  case "$out" in *"$MARKDOWN_CONVERT_MARKITDOWN_INSTALL") markdown_convert_ok "no markitdown: stderr ends with the one install command" ;;
    *) markdown_convert_bad "no markitdown: stderr does not end with the install command" "$out" ;; esac
  markdown_convert_is "no pandoc: converter id is none" \
    "$(PATH=/usr/bin:/bin MARKDOWN_CONVERT_TOOL_DIRS='' /bin/bash "$self" --converter-id "$work/p.html")" "none"

  # 6. DATALESS. The parse on literal flag values first, then end to end through a stub stat.
  markdown_convert_flags_say_dataless 40000000 && markdown_convert_ok "flags 40000000 parse as dataless" || markdown_convert_bad "flags 40000000 did not parse as dataless"
  markdown_convert_flags_say_dataless 40000020 && markdown_convert_ok "flags 40000020 (dataless+compressed) parse as dataless" || markdown_convert_bad "flags 40000020 did not parse as dataless"
  markdown_convert_flags_say_dataless 0 && markdown_convert_bad "negative control: flags 0 parsed as dataless" || markdown_convert_ok "negative control: flags 0 are not dataless"
  markdown_convert_flags_say_dataless 8020 && markdown_convert_bad "negative control: flags 8020 (hidden+compressed) parsed as dataless" || markdown_convert_ok "negative control: flags 8020 (hidden+compressed) are not dataless"
  markdown_convert_flags_say_dataless 'garbage' && markdown_convert_ok "unreadable flags fail closed (treated as dataless)" || markdown_convert_bad "unreadable flags were treated as readable"
  stub="$work/stat-stub"
  # The stub answers "dataless" for any file whose name contains "online-only", and is the real
  # stat for everything else.
  cat > "$stub" <<'STUB'
#!/bin/bash
for last in "$@"; do :; done
case "$last" in *online-only*) printf '40000000\n'; exit 0 ;; esac
exec /usr/bin/stat "$@"
STUB
  chmod 755 "$stub"
  printf 'secret\n' > "$work/online-only.md"
  chmod 000 "$work/online-only.md"
  DATALESS_STAT_COMMAND="$stub" /bin/bash "$self" "$work/online-only.md" > /dev/null 2>&1; rc=$?
  markdown_convert_is "dataless (stubbed flag, chmod 000 file): rc 11 — the file was never opened" "$rc" "11"
  /bin/bash "$self" "$work/online-only.md" > /dev/null 2>&1; rc=$?
  markdown_convert_is "negative control: the same chmod 000 file WITHOUT the flag fails to read (rc 1)" "$rc" "1"
  chmod 644 "$work/online-only.md"
  out="$(DATALESS_STAT_COMMAND="$stub" /bin/bash "$self" --converter-id "$work/online-only.md")"
  markdown_convert_is "converter id of a dataless file is still answered (it needs no read)" "$out" "passthrough 1"

  # 7. the converter arms themselves, only where the tool exists.
  if pandoc="$(markdown_convert_find_tool pandoc)"; then
    printf '<h1>Heading</h1><p>Some <b>bold</b> text and <a href="https://example.com/x">a link</a>.</p>\n' > "$work/page.html"
    /bin/bash "$self" "$work/page.html" > "$work/page.out" 2>/dev/null; rc=$?
    markdown_convert_is "pandoc html: rc 0" "$rc" "0"
    markdown_convert_is "pandoc html: the h1 is an ATX heading" "$(sed -n 1p "$work/page.out")" "# Heading"
    if /usr/bin/awk '/\*\*bold\*\*/ && /\[a link\]\(https:\/\/example.com\/x\)/ { f = 1 } END { exit f ? 0 : 1 }' "$work/page.out"; then
      markdown_convert_ok "pandoc html: bold and the link survive as markdown"
    else markdown_convert_bad "pandoc html: bold or link lost" "$(cat "$work/page.out")"; fi
    markdown_convert_is "pandoc: converter id names pandoc" "$(/bin/bash "$self" --converter-id "$work/page.html" | cut -d' ' -f1)" "pandoc"
    printf '# Report\n\nParagraph one.\n' > "$work/seed.md"
    if "$pandoc" -o "$work/report.docx" "$work/seed.md" 2>/dev/null; then
      /bin/bash "$self" "$work/report.docx" > "$work/report.out" 2>/dev/null; rc=$?
      markdown_convert_is "pandoc docx: rc 0" "$rc" "0"
      markdown_convert_is "pandoc docx: round-trips the heading" "$(sed -n 1p "$work/report.out")" "# Report"
    else markdown_convert_bad "pandoc could not build the docx fixture"; fi
    printf 'not a zip' > "$work/broken.docx"
    /bin/bash "$self" "$work/broken.docx" > /dev/null 2>&1; rc=$?
    markdown_convert_is "negative control: a corrupt docx is rc 1 (failed), not 0" "$rc" "1"
  else
    printf '  --   skipped: no pandoc (html/htm/docx/odt/rtf/epub arms)\n'
  fi
  if markdown_convert_find_tool markitdown > /dev/null; then
    if [ -n "${pandoc:-}" ] && "$pandoc" -o "$work/deck.pptx" "$work/seed.md" 2>/dev/null; then
      /bin/bash "$self" "$work/deck.pptx" > "$work/deck.out" 2>/dev/null; rc=$?
      markdown_convert_is "markitdown pptx: rc 0" "$rc" "0"
      if /usr/bin/awk '/Report/ { f = 1 } END { exit f ? 0 : 1 }' "$work/deck.out"; then markdown_convert_ok "markitdown pptx: the slide title is in the markdown"
      else markdown_convert_bad "markitdown pptx: slide title missing" "$(cat "$work/deck.out")"; fi
    else
      printf '  --   skipped: no pandoc to build a pptx fixture for markitdown\n'
    fi
    markdown_convert_is "markitdown: converter id names markitdown" "$(/bin/bash "$self" --converter-id "$work/s.pptx" | cut -d' ' -f1)" "markitdown"
  else
    printf '  --   skipped: no markitdown (pptx/xlsx/xls/pdf arms)\n'
  fi

  chmod -R u+rwx "$work" 2>/dev/null
  rm -rf "$work"
  printf '%d/%d passed\n' "$((markdown_convert_selftest_total - markdown_convert_selftest_failed))" "$markdown_convert_selftest_total"
  [ "$markdown_convert_selftest_failed" -eq 0 ]
}

case "${1:-}" in
  --selftest)     markdown_convert_selftest; exit $? ;;
  --types)        printf '%s\n' $MARKDOWN_CONVERT_TYPES; exit 0 ;;
  --converter-id)
    [ -n "${2:-}" ] || { markdown_convert_say "usage: markdown-convert.sh --converter-id <file>"; exit 2; }
    markdown_convert_plan "$2"; printf '%s\n' "$plan_id"; exit 0 ;;
  -h|--help)      sed -n '2,33p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  --)             markdown_convert_run "${2:-}"; exit $? ;;
  -*)             markdown_convert_say "unknown option: $1"; exit 2 ;;
  *)              markdown_convert_run "${1:-}"; exit $? ;;
esac
