#!/bin/bash
# scripts/currency.sh — is every third-party version this repo pins still the upstream latest?
#
#   bash scripts/currency.sh             one line per pin: `<name> pinned <x> upstream <y> <state>`
#   bash scripts/currency.sh --offline   the pinned values only, read out of the files; no network
#   bash scripts/currency.sh --coverage  every pin-shaped variable in modules/ that the table omits
#
# Exit (online): 0 every pin current · 1 any BEHIND · 2 any unknown (an upstream did not answer) and
# none BEHIND · 3 the table names a pin its file does not hold. --offline exits 0, or 3 on that same
# table defect. --coverage exits 0 when the table covers every pin, else 1. It never edits a pin.
#
# ── WHY IT READS THE MODULE, NEVER A COPY ────────────────────────────────────────────────────
# Each row names the file and the shell variable that holds the pin, and the value is read out of
# that file on every run. A second copy of "0.143.0" here would say current long after the module
# moved, which is the one lie this script exists to catch. A pin that lives only inside a URL takes a
# capture — a sed -E pattern with one group, applied to the variable's value (or, with variable `-`,
# to the file itself, for a pin a document states rather than a script).
#
# ── ADDING A PIN IS ONE ROW ──────────────────────────────────────────────────────────────────
# Fields are `|`-separated, so no field may contain `|` (a capture cannot use alternation).
# Upstream kinds:
#   npm:<package>              the registry's `latest` dist-tag
#   github:<owner>/<repo>      releases/latest's tag_name (a leading v is ignored when comparing)
#   github-commit:<owner>/<repo>  the pin is a commit: BEHIND when releases/latest's tag contains
#                              commits the pinned sha does not (GitHub's compare status)
#   node-line                  the newest nodejs.org release on the pinned major
#   sparkle:<appcast url>      the highest version a Sparkle appcast offers
#   text:<url>                 a URL whose whole body is the version (Claude Code's stable channel pointer)
# --coverage keeps the table honest: a top-level assignment in modules/*.sh whose name ends _VERSION,
# _TAG or _PIN, or whose literal value is a URL carrying a version (3.7.1, 3_7_1), must have a row.
#
# Seams, for tests (file:// works): CURRENCY_TABLE=<file> replaces the table · CURRENCY_ROOT=<dir>
# resolves the rows' files · CURRENCY_NPM · CURRENCY_GITHUB_API · CURRENCY_NODE_INDEX replace the
# upstream bases. GITHUB_TOKEN, when set, is sent to the GitHub API only (never on argv).

set -u

CURRENCY_TABLE_BUILTIN="$(cat <<'CURRENCY_TABLE'
# name              | file                     | variable                       | capture                          | upstream
ms-365-mcp-server   | modules/microsoft365.sh  | MICROSOFT365_SERVER_VERSION    | -                                | npm:@softeria/ms-365-mcp-server
node                | modules/microsoft365.sh  | MICROSOFT365_NODE_VERSION      | -                                | node-line
ollama              | modules/rewrite_model.sh | REWRITE_MODEL_OLLAMA_VERSION   | -                                | github:ollama/ollama
Hammerspoon         | modules/screenshot.sh    | SCREENSHOT_HAMMERSPOON_URL     | /download/([0-9.]+)/             | github:Hammerspoon/hammerspoon
iTerm2              | modules/pane_equalize.sh | PANE_EQUALIZE_ITERM_URL        | iTerm2-([0-9_]+)\.zip            | sparkle:https://iterm2.com/appcasts/final_modern.xml
kitty               | modules/pane_equalize.sh | PANE_EQUALIZE_KITTY_URL        | /download/v([0-9.]+)/            | github:kovidgoyal/kitty
VoiceInk            | modules/voiceink.sh      | BOOTSTRAP_VOICEINK_TAG         | -                                | github:Beingpax/VoiceInk
whisper.cpp         | modules/voiceink.sh      | BOOTSTRAP_VOICEINK_WHISPER_PIN | -                                | github-commit:ggml-org/whisper.cpp
copilot-cli         | README.md                | -                              | Copilot CLI ([0-9][0-9.]*[0-9])  | npm:@github/copilot
claude-code         | modules/agent_cli.sh     | AGENT_CLI_CLAUDE_VERSION       | -                                | text:https://downloads.claude.ai/claude-code-releases/stable
copilot-cli-binary  | modules/agent_cli.sh     | AGENT_CLI_COPILOT_VERSION      | -                                | npm:@github/copilot
codex-cli           | modules/extra_agents.sh  | EXTRA_AGENTS_CODEX_VERSION     | -                                | npm:@openai/codex
gemini-cli          | modules/extra_agents.sh  | EXTRA_AGENTS_GEMINI_VERSION    | -                                | npm:@google/gemini-cli
node-extra-agents   | modules/extra_agents.sh  | EXTRA_AGENTS_NODE_VERSION      | -                                | node-line
CURRENCY_TABLE
)"

CURRENCY_MODE=online
case "${1:-}" in
  "")          : ;;
  --offline)   CURRENCY_MODE=offline ;;
  --coverage)  CURRENCY_MODE=coverage ;;
  --help|-h)   sed -n '2,33p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *)           printf 'currency: unknown argument: %s   (try --help)\n' "$1" >&2; exit 2 ;;
esac

CURRENCY_ROOT="${CURRENCY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd -P)}"
CURRENCY_NPM="${CURRENCY_NPM:-https://registry.npmjs.org}"
CURRENCY_GITHUB_API="${CURRENCY_GITHUB_API:-https://api.github.com}"
CURRENCY_NODE_INDEX="${CURRENCY_NODE_INDEX:-https://nodejs.org/dist/index.json}"

currency_rows() {  # the table without comments or blank lines, one row per line
  if [ -n "${CURRENCY_TABLE:-}" ]; then cat "$CURRENCY_TABLE"; else printf '%s\n' "$CURRENCY_TABLE_BUILTIN"; fi \
    | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$'
}

currency_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# The literal value a top-level `NAME=` assignment gives, with quotes, a trailing comment and a
# `${NAME:-default}` wrapper removed. Empty when the file holds no such assignment.
currency_assigned() {  # <file> <variable>
  local rhs v
  rhs="$(sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1)"
  case "$rhs" in
    \"*) v="${rhs#\"}"; v="${v%%\"*}" ;;
    \'*) v="${rhs#\'}"; v="${v%%\'*}" ;;
    *)   v="${rhs%%[[:space:]]*}" ;;
  esac
  case "$v" in '${'*':-'*'}') v="${v#*:-}"; v="${v%\}}" ;; esac
  printf '%s' "$v"
}

# The pinned value one row names, or empty. Underscores become dots (iTerm2 spells 3.7.1 as 3_7_1).
currency_pinned() {  # <file> <variable|-> <capture|->
  local file="$CURRENCY_ROOT/$1" v
  [ -r "$file" ] || return 0
  if [ "$2" = - ]; then
    [ "$3" = - ] && return 0
    v="$(sed -nE "s#.*$3.*#\\1#p" "$file" | head -1)"
  else
    v="$(currency_assigned "$file" "$2")"
    [ -n "$v" ] && [ "$3" != - ] && v="$(printf '%s\n' "$v" | sed -nE "s#.*$3.*#\\1#p" | head -1)"
  fi
  printf '%s' "$v" | tr '_' '.'
}

currency_get() {  # <url> → the body; non-zero on any failure (DNS, refused, timeout, HTTP ≥ 400)
  case "$1" in
    "$CURRENCY_GITHUB_API"/*)
      if [ -n "${GITHUB_TOKEN:-}" ]; then
        printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" \
          | curl -fsL --connect-timeout 10 -m 30 -K - -H 'Accept: application/vnd.github+json' "$1"
        return
      fi ;;
  esac
  curl -fsL --connect-timeout 10 -m 30 "$1"
}

currency_host() {  # <kind:arg> → the host a row's upstream query goes to, for an unknown's note
  local u
  case "$1" in
    npm:*) u="$CURRENCY_NPM" ;; github*) u="$CURRENCY_GITHUB_API" ;;
    node-line*) u="$CURRENCY_NODE_INDEX" ;; sparkle:*) u="${1#sparkle:}" ;; text:*) u="${1#text:}" ;; *) u="$1" ;;
  esac
  u="${u#*://}"; printf '%s' "${u%%/*}"
}

currency_github_tag() {  # <owner/repo> → releases/latest's tag_name
  currency_get "$CURRENCY_GITHUB_API/repos/$1/releases/latest" | sed -nE 's/.*"tag_name": *"([^"]*)".*/\1/p' | head -1
}

currency_behind() {  # <pinned> <upstream> → 0 when upstream is a later version; prerelease suffixes ignored
  local a="${1#v}" b="${2#v}" x y
  a="${a%%-*}"; b="${b%%-*}"
  while [ -n "$a$b" ]; do
    x="${a%%.*}"; y="${b%%.*}"
    x="${x%%[!0-9]*}"; y="${y%%[!0-9]*}"
    [ "${x:-0}" -lt "${y:-0}" ] && return 0
    [ "${x:-0}" -gt "${y:-0}" ] && return 1
    case "$a" in *.*) a="${a#*.}" ;; *) a="" ;; esac
    case "$b" in *.*) b="${b#*.}" ;; *) b="" ;; esac
  done
  return 1
}

# Upstream for one row, as `<version> <state>`; empty when upstream did not answer.
currency_upstream() {  # <kind:arg> <pinned>
  local kind="${1%%:*}" arg="${1#*:}" up body status
  case "$kind" in
    npm)
      up="$(currency_get "$CURRENCY_NPM/-/package/$arg/dist-tags" | sed -nE 's/.*"latest": *"([^"]*)".*/\1/p' | head -1)" ;;
    github)
      up="$(currency_github_tag "$arg")" ;;
    text)
      up="$(currency_get "$arg" | tr -d '[:space:]')"
      case "$up" in [0-9]*.*) : ;; *) up="" ;; esac ;;
    node-line)
      up="$(currency_get "$CURRENCY_NODE_INDEX" | sed -nE "s/^[[:space:]]*\\{\"version\":\"v(${2%%.*}\\.[0-9.]+)\".*/\\1/p" | head -1)" ;;
    sparkle)
      body="$(currency_get "$arg")" || body=""
      up=""
      for status in $(printf '%s\n' "$body" | sed -nE 's/.*sparkle:version="([0-9][0-9.]*)".*/\1/p'); do
        if [ -z "$up" ] || currency_behind "$up" "$status"; then up="$status"; fi   # the highest offered
      done ;;
    github-commit)
      up="$(currency_github_tag "$arg")"
      [ -n "$up" ] || return 0
      status="$(currency_get "$CURRENCY_GITHUB_API/repos/$arg/compare/$up...$2" | sed -nE 's/.*"status": *"([^"]*)".*/\1/p' | head -1)"
      case "$status" in
        identical|ahead) printf '%s current' "$up" ;;
        behind|diverged) printf '%s BEHIND' "$up" ;;
      esac
      return 0 ;;
    *) return 0 ;;
  esac
  [ -n "$up" ] || return 0
  if [ "${up#v}" = "${2#v}" ] || ! currency_behind "$2" "$up"; then printf '%s current' "$up"
  else printf '%s BEHIND' "$up"; fi
}

# ── --coverage ───────────────────────────────────────────────────────────────────────────────
if [ "$CURRENCY_MODE" = coverage ]; then
  covered=" $(currency_rows | while IFS='|' read -r _ file var _ _; do
    printf '%s:%s ' "$(currency_trim "$file")" "$(currency_trim "$var")"; done)"
  missing=0
  for f in "$CURRENCY_ROOT"/modules/*.sh; do
    [ -r "$f" ] || continue
    rel="modules/${f##*/}"
    for var in $(grep -E '^[A-Z][A-Z0-9_]*=' "$f" | sed -nE \
        -e 's/^([A-Z][A-Z0-9_]*_(VERSION|TAG|PIN))=.*/\1/p' \
        -e "s#^([A-Z][A-Z0-9_]*)=[\"']?https?://[^\"' ]*[0-9]+[._][0-9]+.*#\\1#p" | sort -u); do
      case "$covered" in *" $rel:$var "*) : ;; *) printf 'uncovered %s %s\n' "$rel" "$var"; missing=$((missing + 1)) ;; esac
    done
  done
  [ "$missing" = 0 ] && printf 'every pin-shaped variable in modules/ has a row\n'
  [ "$missing" = 0 ]; exit
fi

# ── --offline and the online report ──────────────────────────────────────────────────────────
behind=0; unknown=0; defect=0; current=0
while IFS='|' read -r name file var capture upstream; do
  name="$(currency_trim "$name")"; file="$(currency_trim "$file")"; var="$(currency_trim "$var")"
  capture="$(currency_trim "$capture")"; upstream="$(currency_trim "$upstream")"
  pinned="$(currency_pinned "$file" "$var" "$capture")"
  if [ -z "$pinned" ]; then
    printf '%s pinned ? MISSING (%s holds no %s)\n' "$name" "$file" "$( [ "$var" = - ] && printf 'match for %s' "$capture" || printf '%s' "$var")"
    defect=$((defect + 1)); continue
  fi
  shown="$pinned"
  case "$pinned" in *[!0-9a-f]*) : ;; *) [ "${#pinned}" = 40 ] && shown="$(printf %.12s "$pinned")" ;; esac   # a commit sha
  if [ "$CURRENCY_MODE" = offline ]; then printf '%s pinned %s\n' "$name" "$shown"; continue; fi
  answer="$(currency_upstream "$upstream" "$pinned")"
  case "$answer" in
    *" current") current=$((current + 1)) ;;
    *" BEHIND")  behind=$((behind + 1)) ;;
    *) answer="? unknown ($(currency_host "$upstream") did not answer — a network or proxy block, or no such upstream)"
       unknown=$((unknown + 1)) ;;
  esac
  printf '%s pinned %s upstream %s\n' "$name" "$shown" "$answer"
done <<EOF
$(currency_rows)
EOF

[ "$defect" = 0 ] || exit 3
[ "$CURRENCY_MODE" = offline ] && exit 0
printf -- '-- %s current, %s BEHIND, %s unknown\n' "$current" "$behind" "$unknown"
[ "$behind" = 0 ] || exit 1
[ "$unknown" = 0 ] || exit 2
exit 0
