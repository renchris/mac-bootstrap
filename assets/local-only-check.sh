#!/bin/bash
# local-only-check.sh — READ this Mac and say whether any app or agent config that a mac-bootstrap
# module sets up can send local data to a cloud AI service.
#
#   bash local-only-check.sh [--only voiceink|ollama|agents|apps] [--quiet]
#
# One line per probe, on stdout and nowhere else:
#     ok    <subject> — <detail>      nothing here leaves this Mac
#     FAIL  <subject> — <detail>      a cloud path is live, OR the probe could not verify (fail closed)
#     warn  <subject> — <detail>      worth knowing, and not a verdict about local data
#     n/a   <subject> — <detail>      not installed / not running / not applicable
# Exit 0 = no FAIL · 1 = at least one FAIL · 2 = the check itself could not run.
# --quiet prints only the FAIL lines. Diagnostics go to stderr. --only may be repeated.
#
# ── WHAT IT NEVER DOES ──────────────────────────────────────────────────────────────────────
# It never reads a secret. VoiceInk's preference domain holds API keys as data, so it is never
# dumped (`defaults read <domain>`, `defaults export`, `plutil -p` would all print them): a key's
# PRESENCE is read with `defaults read-type`, which prints a type, and the keychain is asked with
# `security find-generic-password` WITHOUT -w/-g, and only its exit code is kept (0 present,
# 44 absent, anything else = cannot verify). An environment variable holding a key is reported by
# NAME; a base URL is reported by HOST only (a URL can carry user:password@).
# It never writes a preference or a keychain, and it makes no network request except to an Ollama
# server on loopback (or a file:// fixture). curl runs with --noproxy '*' so a loopback request
# cannot be relayed by a proxy, --proto '=http,file' and no -L so a redirect cannot take it
# elsewhere.
#
# ── SEAMS (all optional; every one exists so the tests read through the SAME code path) ───────
#   LOCAL_ONLY_VOICEINK_DOMAIN  a defaults domain, or an ABSOLUTE plist path without ".plist"
#                               (`defaults read-type /abs/path key` reads that file)
#   LOCAL_ONLY_VOICEINK_APP     the VoiceInk.app bundle to fingerprint
#   LOCAL_ONLY_KEYCHAIN         a keychain file, passed as find-generic-password's trailing argument
#   LOCAL_ONLY_SECURITY_CLI     the `security` binary (tests substitute a stub that answers by rc)
#   LOCAL_ONLY_OLLAMA_URL       the Ollama base URL; a file:///dir base reads dir/api/status etc.
#   LOCAL_ONLY_ITERM_DOMAIN     the iTerm2 defaults domain, or an absolute plist path without .plist
#   LOCAL_ONLY_ITERM_SECURE_DIR the directory holding iTerm2's root-owned *.secureSetting files
# HOME already sandboxes the agent config files ($HOME/.claude, $HOME/.copilot, $HOME/.ollama).
#
# Built from .claude-plans/research/one-command-install-2026-09-15/{voiceink-providers.md §3-§6,
# ollama-local.md "Probe list", agent-egress-catalogue.md §B, egress-redteam.md §5}.
#
# bash 3.2 (the target's /bin/bash). set -u, never set -e: one probe failing must not hide the rest.

set -u
# noglob: the host lists carry '*' patterns and are word-split; pathname expansion would turn
# "*.openai.azure.com" into file names from the current directory. `case` patterns still glob.
set -f

LOCAL_ONLY_FAILS=0
LOCAL_ONLY_QUIET=0
LOCAL_ONLY_SELECTED=""

PLUTIL=/usr/bin/plutil
DEFAULTS=/usr/bin/defaults
SECURITY="${LOCAL_ONLY_SECURITY_CLI:-/usr/bin/security}"
CURL=/usr/bin/curl
GREP=/usr/bin/grep

usage() { /usr/bin/sed -n '2,15p' "${BASH_SOURCE[0]:-$0}" | /usr/bin/sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --only)
      [ $# -ge 2 ] || { printf 'local-only-check: --only needs one of voiceink ollama agents apps\n' >&2; exit 2; }
      case "$2" in
        voiceink|ollama|agents|apps) LOCAL_ONLY_SELECTED="$LOCAL_ONLY_SELECTED $2" ;;
        *) printf 'local-only-check: unknown probe "%s" (known: voiceink ollama agents apps)\n' "$2" >&2; exit 2 ;;
      esac
      shift ;;
    --quiet) LOCAL_ONLY_QUIET=1 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'local-only-check: unknown argument "%s" (try --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$LOCAL_ONLY_SELECTED" ] || LOCAL_ONLY_SELECTED=" voiceink ollama agents apps"

[ -x "$PLUTIL" ] || { printf 'local-only-check: %s is missing — nothing here can be read without it\n' "$PLUTIL" >&2; exit 2; }

LOCAL_ONLY_TMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/local-only-check.XXXXXX")" || {
  printf 'local-only-check: cannot create a temporary directory\n' >&2; exit 2; }
trap '/bin/rm -rf "$LOCAL_ONLY_TMP"' EXIT

# ── output ───────────────────────────────────────────────────────────────────────────────────
# Anything that came from the machine (a mode name, a host) is stripped of control characters so
# it cannot forge a second line.
clean() { printf '%s' "$1" | /usr/bin/tr -d '\000-\037\177' | /usr/bin/cut -c1-80; }
emit() {                                        # emit <ok|FAIL|warn|n/a> <subject> <detail>
  [ "$1" = FAIL ] && LOCAL_ONLY_FAILS=$((LOCAL_ONLY_FAILS + 1))
  [ "$LOCAL_ONLY_QUIET" = 1 ] && [ "$1" != FAIL ] && return 0
  printf '    %-6s%s — %s\n' "$1" "$2" "$3"
}
selected() { case "$LOCAL_ONLY_SELECTED " in *" $1 "*) return 0 ;; esac; return 1; }
lower() { printf '%s' "$1" | /usr/bin/tr 'A-Z' 'a-z'; }

# ── reading values ───────────────────────────────────────────────────────────────────────────
# `plutil -extract` prints its failure sentence to STDOUT (CONTRACT §7 trap 3): the rc decides.
json_get() {                                    # json_get <file> <keypath> → value on rc 0
  local out
  out="$("$PLUTIL" -extract "$2" raw -o - -- "$1" 2>/dev/null)" || return 1
  printf '%s' "$out"
}
# json_has <file> <keypath> — any type; xml1 renders a dict, an array and a scalar alike.
json_has() { "$PLUTIL" -extract "$2" xml1 -o /dev/null -- "$1" >/dev/null 2>&1; }
# plist_file <domain> — the file behind a defaults domain, or the seam's absolute path.
plist_file() { case "$1" in /*) printf '%s.plist' "$1" ;; *) printf '%s/Library/Preferences/%s.plist' "$HOME" "$1" ;; esac; }
truthy() { case "$(lower "$1")" in 1|true|yes) return 0 ;; esac; return 1; }

# ── hosts ────────────────────────────────────────────────────────────────────────────────────
url_host() {                                    # url_host <url-or-host[:port]> → lowercase host
  local h="$1"
  case "$h" in *://*) h="${h#*://}" ;; esac
  h="${h%%/*}"; h="${h%%\?*}"; h="${h%%#*}"
  case "$h" in *@*) h="${h##*@}" ;; esac        # userinfo is dropped here and never printed
  case "$h" in
    '['*) h="${h#[}"; h="${h%%]*}" ;;
    *:*:*) : ;;                                 # a bare IPv6 literal
    *) h="${h%:*}" ;;
  esac
  h="${h%.}"
  lower "$h"
}
is_loopback_host() {
  case "$1" in
    localhost|::1|0:0:0:0:0:0:0:1) return 0 ;;
    127.*) case "$1" in *[!0-9.]*) return 1 ;; esac; return 0 ;;
  esac
  return 1
}
# The catalogue's host list (§B.4). '*' is any label; a '/path' suffix is dropped because every
# probe here compares a HOST, and each of those hosts is an AI endpoint as a host.
CLOUD_AI_HOSTS="generativelanguage.googleapis.com aiplatform.googleapis.com *-aiplatform.googleapis.com
aiplatform.us.rep.googleapis.com aiplatform.eu.rep.googleapis.com speech.googleapis.com texttospeech.googleapis.com
api.openai.com *.openai.azure.com *.cognitiveservices.azure.com *.services.ai.azure.com models.inference.ai.azure.com
*.stt.speech.microsoft.com *.tts.speech.microsoft.com models.github.ai api.anthropic.com *.githubcopilot.com
copilot-proxy.githubusercontent.com bedrock-runtime.*.amazonaws.com bedrock-runtime-fips.*.amazonaws.com
bedrock-agent-runtime.*.amazonaws.com bedrock-mantle.*.api.aws aws-external-anthropic.*.api.aws
transcribe.*.amazonaws.com transcribestreaming.*.amazonaws.com api.groq.com api.deepgram.com api.elevenlabs.io
api.mistral.ai codestral.mistral.ai openrouter.ai api.cerebras.ai api.together.xyz api.together.ai api.fireworks.ai
api.perplexity.ai api.x.ai api.cohere.com api.cohere.ai api.deepseek.com api.assemblyai.com streaming.assemblyai.com
api.replicate.com router.huggingface.co api-inference.huggingface.co *.endpoints.huggingface.cloud ollama.com
api.soniox.com stt-rt.soniox.com asr.api.speechmatics.com *.rt.speechmatics.com api.cartesia.ai api.gladia.io
api.rev.ai integrate.api.nvidia.com api.deepinfra.com api.sambanova.ai api.hyperbolic.xyz api.novita.ai
api.moonshot.ai api.moonshot.cn api.z.ai open.bigmodel.cn dashscope.aliyuncs.com dashscope-intl.aliyuncs.com
api.minimax.io api.minimaxi.com api.voyageai.com api.jina.ai ai-gateway.vercel.sh gateway.ai.cloudflare.com
api.portkey.ai api.studio.nebius.ai api.tokenfactory.nebius.com api.lambda.ai inference.baseten.co api.inference.wandb.ai"
CLAUDE_OWN_HOSTS="api.anthropic.com claude.ai claude.com platform.claude.com mcp-proxy.anthropic.com"
COPILOT_OWN_HOSTS="*.githubcopilot.com copilot-proxy.githubusercontent.com github.com api.github.com"

host_in_list() {                                # host_in_list <host> <list> → prints the matching pattern
  local p
  for p in $2; do
    # shellcheck disable=SC2254   # the pattern IS a glob, on purpose
    case "$1" in $p) printf '%s' "$p"; return 0 ;; esac
  done
  return 1
}
# host_regex <glob> — an ERE for one catalogue host, with the catalogue's boundaries so that
# api.openai.com.evil.example and MY-api.openai.com do not match.
host_regex() {
  local body
  body="$(printf '%s' "$1" | /usr/bin/sed -e 's/\./\\./g' -e 's/^\*\\\./([a-z0-9-]+\\.)+/' -e 's/\*/[a-z0-9-]+/g')"
  printf '(^|[^a-z0-9.-])%s\\.?([^a-z0-9.-]|$)' "$body"
}
# file_cloud_hosts <file> — each catalogue host the file names, one per line. -q only: grep never
# prints a byte of the file, so a secret in it cannot reach this output.
file_cloud_hosts() {
  local p
  for p in $CLOUD_AI_HOSTS; do
    "$GREP" -qiE "$(host_regex "$p")" "$1" 2>/dev/null && printf '%s\n' "$p"
  done
}

# ── ollama transport — loopback or file:// only ──────────────────────────────────────────────
ollama_url_ok() {                               # the ONE gate every Ollama request passes
  case "$1" in
    file://*) return 0 ;;
    http://*) is_loopback_host "$(url_host "$1")" ;;
    *) return 1 ;;
  esac
}
ollama_get() {                                  # ollama_get <base> <path> <outfile> → rc 0 on a 2xx body
  ollama_url_ok "$1" || return 3
  "$CURL" -fsS --noproxy '*' --proto '=http,file' -m 5 "${1%/}$2" -o "$3" 2>/dev/null
}
is_cloud_tag() {                                # mirrors ollama internal/modelref parseSourceSuffix
  case "$1" in *:*) ;; *) return 1 ;; esac
  case "$(lower "${1##*:}")" in cloud|*-cloud) return 0 ;; esac
  return 1
}
# tags_resolve <tags.json> <model-or-empty> → the index of the model VoiceInk would run: the named
# one if it is listed, else the FIRST listed (research §4, ModeRuntimeConfiguration.swift:233-245).
tags_resolve() {
  local f="$1" want="$2" i=0 n pick=""
  while n="$(json_get "$f" "models.$i.name")"; do
    [ -n "$pick" ] || pick="$i"
    case "$n" in "$want"|"$want:latest") pick="$i"; break ;; esac
    i=$((i + 1))
  done
  [ -n "$pick" ] || return 1
  printf '%s' "$pick"
}
model_remote() {                                # model_remote <tags.json> <index> → where it runs, if remote
  local n r
  n="$(json_get "$1" "models.$2.name")" || return 1
  r="$(json_get "$1" "models.$2.remote_host")" || r=""
  [ -n "$r" ] || r="$(json_get "$1" "models.$2.remote_model")" || r=""
  if [ -n "$r" ]; then printf '%s' "$(url_host "$r")"; return 0; fi
  is_cloud_tag "$n" && { printf 'ollama.com (a cloud tag)'; return 0; }
  return 1
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# 1. VOICEINK — research voiceink-providers.md §6: build shape, stored keys, every mode
# ═════════════════════════════════════════════════════════════════════════════════════════════
VOICEINK_KEYCHAIN_SERVICE=com.prakashjoshipax.VoiceInk.Local
VOICEINK_KEYCHAIN_SERVICE_OFFICIAL=com.prakashjoshipax.VoiceInk
# account:provider — the 15 fixed keychain accounts (research §3, APIKeyManager.swift:12-27).
VOICEINK_ACCOUNTS="groqAPIKey:Groq deepgramAPIKey:Deepgram cerebrasAPIKey:Cerebras geminiAPIKey:Gemini
mistralAPIKey:Mistral elevenLabsAPIKey:ElevenLabs sonioxAPIKey:Soniox speechmaticsAPIKey:Speechmatics
assemblyAIAPIKey:AssemblyAI xaiAPIKey:xAI cartesiaAPIKey:Cartesia openAIAPIKey:OpenAI
anthropicAPIKey:Anthropic openRouterAPIKey:OpenRouter customAPIKey:Custom"
# The enhancement providers that come BEFORE the local ones in AIProvider's declaration order, so
# a surviving key wins the fallback (research §1).
VOICEINK_CLOUD_REWRITE="cerebras groq gemini anthropic openai openrouter mistral"
# Cloud transcription model names (research §2) → the provider whose key makes them usable.
VOICEINK_CLOUD_AUDIO="whisper-large-v3-turbo:Groq scribe_v2:ElevenLabs nova-3:Deepgram nova-3-medical:Deepgram
voxtral-mini-latest:Mistral gemini-3.5-transcribe:Gemini stt-async-v5:Soniox speechmatics-enhanced:Speechmatics
universal-3-5-pro:AssemblyAI universal-2:AssemblyAI grok-stt:xAI ink-2:Cartesia"

VOICEINK_KEYS_PRESENT=""                        # space-separated provider names with a stored key
VOICEINK_UNKNOWN=0

voiceink_key_state() {                          # voiceink_key_state <account> → present|absent|unknown
  local rc svc state=absent
  "$DEFAULTS" read-type "$VOICEINK_DOMAIN" "LocalKeychain_$1" >/dev/null 2>&1 && state=present
  for svc in "$VOICEINK_KEYCHAIN_SERVICE" "$VOICEINK_KEYCHAIN_SERVICE_OFFICIAL"; do
    if [ -n "${LOCAL_ONLY_KEYCHAIN:-}" ]; then
      "$SECURITY" find-generic-password -s "$svc" -a "$1" "$LOCAL_ONLY_KEYCHAIN" >/dev/null 2>&1; rc=$?
    else
      "$SECURITY" find-generic-password -s "$svc" -a "$1" >/dev/null 2>&1; rc=$?
    fi
    case "$rc" in
      0) state=present ;;
      44) : ;;
      *) [ "$state" = present ] || state=unknown ;;
    esac
  done
  printf '%s' "$state"
}
voiceink_has_key() {                            # provider names compare case-insensitively (research §3)
  [ -n "$1" ] || return 1
  case " $(lower "$VOICEINK_KEYS_PRESENT") " in *" $(lower "$1") "*) return 0 ;; esac; return 1; }
voiceink_rewrite_key_present() {                # any key that wins the nil-provider fallback
  local p
  for p in $VOICEINK_KEYS_PRESENT; do
    case " $VOICEINK_CLOUD_REWRITE " in *" $(lower "$p") "*) printf '%s' "$p"; return 0 ;; esac
  done
  return 1
}
# voiceink_data_json <key> <outfile> — a data-typed preference holding JSON, decoded to a file.
# rc 0 decoded · 1 absent · 2 present but undecodable (cannot verify).
voiceink_data_json() {
  local b64
  "$DEFAULTS" read-type "$VOICEINK_DOMAIN" "$1" >/dev/null 2>&1 || return 1
  if b64="$("$PLUTIL" -extract "$1" raw -o - -- "$VOICEINK_PLIST" 2>/dev/null)" \
     && printf '%s' "$b64" | /usr/bin/base64 -D > "$2" 2>/dev/null \
     && "$PLUTIL" -convert json -o /dev/null -- "$2" >/dev/null 2>&1; then
    return 0
  fi
  # stored as a real array instead of data
  "$PLUTIL" -extract "$1" json -o "$2" -- "$VOICEINK_PLIST" >/dev/null 2>&1 && return 0
  return 2
}
voiceink_pref() { json_get "$VOICEINK_PLIST" "$1"; }

# ── per-provider verdicts: each prints one line per cloud path it finds, nothing when local ──
voiceink_ollama_verdict() {                     # voiceink_ollama_verdict <the mode's selectedAIModel>
  local idx where_to
  if ! is_loopback_host "$VOICEINK_OLLAMA_HOST"; then
    printf 'rewrites through an Ollama at %s, which is not this Mac\n' "$(clean "${VOICEINK_OLLAMA_HOST:-an unreadable address}")"; return 0
  fi
  if is_cloud_tag "$1"; then printf 'rewrites with Ollama model %s, a cloud model run on ollama.com\n' "$(clean "$1")"; return 0; fi
  # not answering: v2.13 skips the rewrite then; the fork's fallback is judged separately
  [ "$VOICEINK_TAGS_OK" = 1 ] || return 0
  idx="$(tags_resolve "$VOICEINK_TAGS" "$1")" || return 0
  where_to="$(model_remote "$VOICEINK_TAGS" "$idx")" || return 0
  printf 'rewrites with Ollama model %s, which runs on %s\n' "$(clean "$(json_get "$VOICEINK_TAGS" "models.$idx.name")")" "$(clean "$where_to")"
}
voiceink_localcli_verdict() {
  [ -n "$VOICEINK_TEMPLATE" ] || return 0       # an empty template is not connected
  case "$VOICEINK_TEMPLATE_CMD" in
    fm) : ;;
    ollama) printf '%s' "$VOICEINK_TEMPLATE" | "$GREP" -qiE '(:|-)cloud([^a-z0-9]|$)' \
              && printf 'runs ollama with a cloud model from its Local CLI command\n' ;;
    *) printf 'hands the dictation to a Local CLI command (%s), and every template of that kind VoiceInk ships runs a cloud agent\n' \
         "$(clean "${VOICEINK_TEMPLATE_CMD:-a shell command}")" ;;
  esac
}
voiceink_custom_verdict() {                     # fail closed: judged by address, whether or not a key is stored
  local i=0 u h
  while u="$(json_get "$VOICEINK_CUSTOM_PROVIDERS" "$i.baseURL")"; do
    h="$(url_host "$u")"
    is_loopback_host "$h" || printf 'rewrites through a Custom provider at %s\n' "$(clean "${h:-an unreadable address}")"
    i=$((i + 1))
  done
  # the runtime mirror, only when the list itself is empty (otherwise it repeats an entry above)
  if [ "$i" = 0 ] && u="$(voiceink_pref customProviderBaseURL)" && [ -n "$u" ]; then
    h="$(url_host "$u")"
    is_loopback_host "$h" || printf 'rewrites through a Custom provider at %s\n' "$(clean "${h:-an unreadable address}")"
  fi
}
voiceink_audio_verdict() {                      # voiceink_audio_verdict <transcription model name>
  local a i=0 cu
  for a in $VOICEINK_CLOUD_AUDIO; do
    if [ "${a%%:*}" = "$1" ] && voiceink_has_key "${a#*:}"; then
      printf 'transcribes with %s, which uploads the AUDIO to %s\n' "$1" "${a#*:}"
    fi
  done
  while cu="$(json_get "$VOICEINK_CUSTOM_MODELS" "$i.name")"; do    # a custom model needs no key check
    [ "$cu" = "$1" ] && printf 'transcribes with custom cloud model %s, which uploads the AUDIO\n' "$(clean "$1")"
    i=$((i + 1))
  done
  return 0
}
# voiceink_mode_verdicts <index> — research §6, the per-mode rules, for one mode. A line starting "WARN " is a
# warning; every other line is a cloud path.
voiceink_mode_verdicts() {
  local m="$VOICEINK_MODES" n="$1" enh prov eff le model stt win cmd v
  enh="$(json_get "$m" "$n.isAIEnhancementEnabled")" || enh=true     # absent: assume on (fail closed)
  prov="$(json_get "$m" "$n.selectedAIProvider")" || prov=""
  model="$(json_get "$m" "$n.selectedAIModel")" || model=""
  if truthy "$enh"; then
    eff="$prov"; [ -n "$eff" ] || eff="$VOICEINK_GLOBAL_PROVIDER"   # a nil provider is seeded from the global at load
    le="$(lower "$eff")"
    win="$(voiceink_rewrite_key_present)" || win=""
    if [ -z "$le" ]; then
      if [ -n "$win" ]; then
        printf 'has no provider, so it takes the first connected one: %s (its key is stored)\n' "$win"
      else
        { voiceink_ollama_verdict "$model"; voiceink_localcli_verdict; voiceink_custom_verdict; } | while IFS= read -r v; do
          printf 'has no provider, so the first connected one runs, and that could be one that %s\n' "$v"
        done
      fi
    elif case " $VOICEINK_CLOUD_REWRITE " in *" $le "*) true ;; *) false ;; esac; then
      if voiceink_has_key "$eff"; then
        printf 'rewrites through %s (its key is stored)\n' "$(clean "$eff")"
      elif [ "$VOICEINK_SHAPE" = fork ] && [ -n "$win" ]; then
        printf 'names %s, and this build falls back to %s, whose key is stored\n' "$(clean "$eff")" "$win"
      else
        printf 'WARN names %s but no %s key is stored, so nothing is sent — storing one would start sending\n' "$(clean "$eff")" "$(clean "$eff")"
      fi
    else
      case "$le" in
        ollama) voiceink_ollama_verdict "$model" ;;
        "voiceink refine") : ;;
        "local cli") voiceink_localcli_verdict ;;
        custom) voiceink_custom_verdict ;;
        *) printf 'uses provider "%s", which this check does not know — cannot verify\n' "$(clean "$eff")" ;;
      esac
      if [ "$VOICEINK_SHAPE" = fork ] && [ -n "$win" ]; then
        printf 'falls back to %s whenever its own provider is not connected (this build does that, and a %s key is stored)\n' "$win" "$win"
      fi
    fi
  fi
  stt="$(json_get "$m" "$n.selectedTranscriptionModelName")" || stt=""
  [ -n "$stt" ] && voiceink_audio_verdict "$stt"
  if [ "$(json_get "$m" "$n.outputMode")" = customCommand ] && cmd="$(json_get "$m" "$n.customCommand.command")" && [ -n "$cmd" ]; then
    printf 'hands every transcript to a shell command, and this check cannot see where that sends it\n'
  fi
  return 0
}

probe_voiceink() {
  VOICEINK_DOMAIN="${LOCAL_ONLY_VOICEINK_DOMAIN:-com.prakashjoshipax.VoiceInk}"
  VOICEINK_PLIST="$(plist_file "$VOICEINK_DOMAIN")"
  local app="" bin="" shape a acct prov st
  if [ -n "${LOCAL_ONLY_VOICEINK_APP:-}" ]; then
    [ -d "$LOCAL_ONLY_VOICEINK_APP" ] && app="$LOCAL_ONLY_VOICEINK_APP"
  else
    for a in "$HOME/Applications/VoiceInk.app" /Applications/VoiceInk.app; do [ -d "$a" ] && { app="$a"; break; }; done
  fi
  if [ -z "$app" ]; then
    emit n/a "VoiceInk" "not installed in \$HOME/Applications or /Applications"
    return 0
  fi

  # ── build shape: which key stores are authoritative ──
  bin="$app/Contents/MacOS/VoiceInk.debug.dylib"; [ -f "$bin" ] || bin="$app/Contents/MacOS/VoiceInk"
  if [ ! -r "$bin" ]; then
    shape=unknown
  elif /usr/bin/codesign -d --entitlements - "$app" 2>/dev/null | LC_ALL=C "$GREP" -q keychain-access-groups; then
    shape=official
  elif LC_ALL=C "$GREP" -q -a -F "$VOICEINK_KEYCHAIN_SERVICE" "$bin" 2>/dev/null; then
    shape=local-build
  elif LC_ALL=C "$GREP" -q -a -F 'LocalKeychain_' "$bin" 2>/dev/null; then
    shape=fork
  else
    shape=unknown
  fi
  case "$shape" in
    local-build) emit ok "VoiceInk build" "a local build: keys live in the $VOICEINK_KEYCHAIN_SERVICE keychain item or its preferences, both readable here" ;;
    fork) emit ok "VoiceInk build" "the fork build: keys live in its preferences, readable here (it falls back to ANY connected provider)" ;;
    official) emit FAIL "VoiceInk build" "an official signed build keeps its keys in the data-protection keychain, which a shell cannot see — cannot verify"; VOICEINK_UNKNOWN=1 ;;
    *) emit FAIL "VoiceInk build" "cannot tell where this build keeps its keys — cannot verify"; VOICEINK_UNKNOWN=1 ;;
  esac

  # ── which cloud keys exist (presence only) ──
  local custom_ids="" f i id unknown_accts=""
  VOICEINK_CUSTOM_PROVIDERS="$LOCAL_ONLY_TMP/custom-providers.json"
  VOICEINK_CUSTOM_MODELS="$LOCAL_ONLY_TMP/custom-models.json"
  voiceink_data_json customAIProviders "$VOICEINK_CUSTOM_PROVIDERS"; st=$?
  [ "$st" = 2 ] && { emit FAIL "VoiceInk custom providers" "stored, but unreadable — cannot verify"; VOICEINK_UNKNOWN=1; }
  [ "$st" = 0 ] || : > "$VOICEINK_CUSTOM_PROVIDERS"
  i=0; while id="$(json_get "$VOICEINK_CUSTOM_PROVIDERS" "$i.id")"; do custom_ids="$custom_ids customAIProvider_${id}_APIKey:Custom"; i=$((i + 1)); done
  voiceink_data_json customCloudModels "$VOICEINK_CUSTOM_MODELS"; st=$?
  [ "$st" = 2 ] && { emit FAIL "VoiceInk custom transcription" "stored, but unreadable — cannot verify"; VOICEINK_UNKNOWN=1; }
  [ "$st" = 0 ] || : > "$VOICEINK_CUSTOM_MODELS"
  i=0; while id="$(json_get "$VOICEINK_CUSTOM_MODELS" "$i.id")"; do custom_ids="$custom_ids customModel_${id}_APIKey:Custom"; i=$((i + 1)); done
  for a in $VOICEINK_ACCOUNTS $custom_ids; do
    acct="${a%%:*}"; prov="${a#*:}"
    st="$(voiceink_key_state "$acct")"
    case "$st" in
      present) voiceink_has_key "$prov" || VOICEINK_KEYS_PRESENT="$VOICEINK_KEYS_PRESENT $prov" ;;
      unknown) case " $unknown_accts " in *" $prov "*) : ;; *) unknown_accts="$unknown_accts $prov" ;; esac ;;
    esac
  done
  if [ -n "$unknown_accts" ]; then
    emit FAIL "VoiceInk keys" "the keychain would not answer for:$(clean "$unknown_accts") (locked or refused) — cannot verify"
    VOICEINK_UNKNOWN=1
  fi

  # ── every mode — any enabled mode can become effective by hotkey or trigger (research §3) ──
  VOICEINK_MODES="$LOCAL_ONLY_TMP/modes.json"
  voiceink_data_json modeConfigurationsV2 "$VOICEINK_MODES"; st=$?
  [ "$st" = 1 ] && { voiceink_data_json powerModeConfigurationsV2 "$VOICEINK_MODES"; st=$?; }
  [ "$st" = 2 ] && { emit FAIL "VoiceInk modes" "stored, but unreadable — cannot verify"; VOICEINK_UNKNOWN=1; }
  [ "$st" = 0 ] || : > "$VOICEINK_MODES"

  local base w n=0 on=0 cloud=0 name enabled line stt
  base="$(voiceink_pref ollamaBaseURL)" && [ -n "$base" ] || base="http://localhost:11434"
  VOICEINK_OLLAMA_HOST="$(url_host "$base")"
  VOICEINK_TAGS="$LOCAL_ONLY_TMP/voiceink-tags.json"; VOICEINK_TAGS_OK=0
  if is_loopback_host "$VOICEINK_OLLAMA_HOST"; then
    # the seam stands in for "the Ollama server on this Mac"
    ollama_get "${LOCAL_ONLY_OLLAMA_URL:-$base}" /api/tags "$VOICEINK_TAGS" && VOICEINK_TAGS_OK=1
  fi
  VOICEINK_GLOBAL_PROVIDER="$(voiceink_pref selectedAIProvider)" || VOICEINK_GLOBAL_PROVIDER=""
  VOICEINK_TEMPLATE="$(voiceink_pref localCLICommandTemplate)" || VOICEINK_TEMPLATE=""
  VOICEINK_TEMPLATE_CMD=""                      # the command word only: the template may carry a key as VAR=value
  for w in $VOICEINK_TEMPLATE; do case "$w" in *=*) continue ;; esac; VOICEINK_TEMPLATE_CMD="${w##*/}"; break; done
  VOICEINK_SHAPE="$shape"

  while json_has "$VOICEINK_MODES" "$n"; do
    name="$(json_get "$VOICEINK_MODES" "$n.name")" || name=""
    [ -n "$name" ] || name="mode $((n + 1))"
    name="$(clean "$name")"
    enabled="$(json_get "$VOICEINK_MODES" "$n.isEnabled")" || enabled=true   # absent: assume enabled
    case "$(lower "$enabled")" in false|0|no) enabled=0 ;; *) enabled=1; on=$((on + 1)) ;; esac
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      case "$line" in
        "WARN "*) emit warn "VoiceInk mode \"$name\"" "${line#WARN }" ;;
        *) if [ "$enabled" = 1 ]; then emit FAIL "VoiceInk mode \"$name\"" "$line"; cloud=$((cloud + 1))
           else emit warn "VoiceInk mode \"$name\" (disabled)" "$line, once it is turned on"; fi ;;
      esac
    done <<VOICEINK_VERDICTS_EOF
$(voiceink_mode_verdicts "$n")
VOICEINK_VERDICTS_EOF
    n=$((n + 1))
  done

  # the default transcription model — a mode without its own uses it
  stt="$(voiceink_pref CurrentTranscriptionModel)" || stt=""
  if [ -n "$stt" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && { emit FAIL "VoiceInk default transcription" "$line"; cloud=$((cloud + 1)); }
    done <<VOICEINK_AUDIO_EOF
$(voiceink_audio_verdict "$stt")
VOICEINK_AUDIO_EOF
  fi

  # a stored cloud key is a live path even with every mode local: a mode with no provider, a mode
  # edit, or (on the fork) an Ollama outage each turns it into egress — research §6 CLOUD_POSSIBLE
  if [ -n "$VOICEINK_KEYS_PRESENT" ]; then
    emit FAIL "VoiceInk keys" "a key is stored for:$(clean "$VOICEINK_KEYS_PRESENT") — any mode that picks it up sends dictation there (values not read)"
  fi
  is_loopback_host "$VOICEINK_OLLAMA_HOST" \
    || emit warn "VoiceInk Ollama address" "points at $(clean "${VOICEINK_OLLAMA_HOST:-an unreadable address}"), which is not this Mac"
  if [ "$cloud" = 0 ] && [ -z "$VOICEINK_KEYS_PRESENT" ] && [ "$VOICEINK_UNKNOWN" = 0 ]; then
    emit ok "VoiceInk" "$on enabled mode(s), none reaches a cloud service, and no cloud key is stored"
  fi
  case "$(lower "$(voiceink_pref enableAnnouncements)")" in
    false|0|no) : ;;
    *) emit warn "VoiceInk announcements" "on: it fetches beingpax.github.io/VoiceInk/announcements.json at launch and every 4 h (no dictation data)" ;;
  esac
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# 2. OLLAMA — research ollama-local.md "Probe list". Never sends a prompt; the one POST carries a
#    model NAME only, goes to loopback only, and only after the server said cloud is disabled.
# ═════════════════════════════════════════════════════════════════════════════════════════════
probe_ollama() {
  local url="${LOCAL_ONLY_OLLAMA_URL:-http://127.0.0.1:11434}" fixture=0 installed=0 t="$LOCAL_ONLY_TMP" h hh w
  case "$url" in file://*) fixture=1 ;; esac
  # first, what needs no server: what the environment tells the next `ollama` to use
  for w in environment launchctl; do
    if [ "$w" = environment ]; then h="${OLLAMA_HOST:-}"
    elif [ "$fixture" = 1 ]; then continue
    else h="$(/bin/launchctl getenv OLLAMA_HOST 2>/dev/null)"; fi
    [ -n "$h" ] || continue
    hh="$(url_host "$h")"
    if is_loopback_host "$hh"; then emit ok "Ollama OLLAMA_HOST ($w)" "loopback"
    elif [ -z "$hh" ]; then emit FAIL "Ollama OLLAMA_HOST ($w)" "an empty host binds EVERY interface, so other machines can use this Ollama"
    else emit FAIL "Ollama OLLAMA_HOST ($w)" "$(clean "$hh") is not this Mac — the ollama CLI talks to it, and a server started here binds off-loopback"; fi
  done

  if ! ollama_url_ok "$url"; then
    printf 'local-only-check: LOCAL_ONLY_OLLAMA_URL=%s is not loopback; refusing to contact it\n' "$url" >&2
    emit FAIL "Ollama" "the configured server is not on this Mac, so it was not contacted — cannot verify"
    return 0
  fi
  if [ "$fixture" = 0 ]; then
    command -v ollama >/dev/null 2>&1 && installed=1
    for w in /opt/homebrew/bin/ollama /usr/local/bin/ollama /Applications/Ollama.app "$HOME/Applications/Ollama.app"; do
      [ -e "$w" ] && installed=1
    done
  fi

  # the server answers and is new enough to HAVE a cloud switch (v0.16.2)
  local v maj rest min pat
  if ! ollama_get "$url" /api/version "$t/version.json" || ! v="$(json_get "$t/version.json" version)"; then
    if [ "$fixture" = 1 ]; then emit FAIL "Ollama" "the fixture has no api/version — cannot verify"
    elif [ "$installed" = 1 ]; then emit n/a "Ollama" "installed, not running — nothing can pass through it until it starts"
    else emit n/a "Ollama" "not installed"; fi
    return 0
  fi
  maj="${v%%.*}"; rest="${v#*.}"; min="${rest%%.*}"; pat="${rest#*.}"; pat="${pat%%[!0-9]*}"
  case "$maj$min" in *[!0-9]*|'') maj=0; min=0; pat=0 ;; esac
  if [ "${maj:-0}" -gt 0 ] || [ "${min:-0}" -gt 16 ] || { [ "${min:-0}" -eq 16 ] && [ "${pat:-0}" -ge 2 ]; }; then
    emit ok "Ollama version" "$(clean "$v") (has the switch that disables its cloud)"
  else
    emit FAIL "Ollama version" "$(clean "$v") predates 0.16.2 — its cloud models cannot be switched off"
  fi

  # every LISTEN socket on the port is loopback. netstat, not lsof: lsof without sudo sees
  # only this user's processes, so a root-owned server would read as nothing listening.
  if [ "$fixture" = 1 ]; then
    emit n/a "Ollama listener" "fixture — no socket to read"
  else
    local port="${url##*:}" proto addr bad=0 any=0
    port="${port%%/*}"; case "$port" in ''|*[!0-9]*) port=11434 ;; esac
    /usr/sbin/netstat -an -p tcp 2>/dev/null | /usr/bin/awk -v p="$port" '$NF=="LISTEN" { n=split($4,a,"."); if (a[n]==p) print $1, $4 }' > "$t/listen.txt"
    while read -r proto addr; do
      any=1
      case "$addr" in 127.*|::1.*) : ;; *) bad=1; emit FAIL "Ollama listener" "$proto $addr accepts connections from other machines" ;; esac
    done < "$t/listen.txt"
    if [ "$any" = 0 ]; then emit FAIL "Ollama listener" "the server answers but no LISTEN socket on :$port was found — cannot verify"
    elif [ "$bad" = 0 ]; then emit ok "Ollama listener" "loopback only (:$port)"; fi
  fi

  # the server's own statement of its cloud policy (it resolved env AND ~/.ollama/server.json)
  local dis="" src="" cloud_off=0
  if ollama_get "$url" /api/status "$t/status.json"; then
    dis="$(json_get "$t/status.json" cloud.disabled)" || dis=""
    src="$(json_get "$t/status.json" cloud.source)" || src=""
  fi
  if [ "$dis" = true ]; then
    emit ok "Ollama cloud" "disabled (source: $(clean "${src:-unknown}"))"; cloud_off=1
  elif [ "$dis" = false ]; then
    emit FAIL "Ollama cloud" "Ollama can reach ollama.com — any app can send a prompt there by naming a :cloud model (set disable_ollama_cloud in \$HOME/.ollama/server.json)"
  else
    emit FAIL "Ollama cloud" "/api/status did not say whether its cloud is disabled — cannot verify"
  fi

  # behavioural confirmation of the cloud switch, loopback http only: a :cloud reference must be refused
  if [ "$cloud_off" = 1 ] && [ "$fixture" = 0 ]; then
    local code
    code="$("$CURL" -sS --noproxy '*' --proto '=http' -m 10 -o "$t/show.json" -w '%{http_code}' \
            -H 'Content-Type: application/json' -d '{"model":"mac-bootstrap-canary:cloud"}' "${url%/}/api/show" 2>/dev/null)" || code=000
    if [ "$code" = 403 ]; then emit ok "Ollama cloud refusal" "a :cloud model name is refused locally (403)"
    else emit FAIL "Ollama cloud refusal" "a :cloud model name returned HTTP $code, not 403 — the switch is not holding"; fi
  fi

  # no installed model runs on a remote host
  local i=0 nm where_to remote=0
  if ollama_get "$url" /api/tags "$t/tags.json" && "$PLUTIL" -convert json -o /dev/null -- "$t/tags.json" >/dev/null 2>&1; then
    while nm="$(json_get "$t/tags.json" "models.$i.name")"; do
      if where_to="$(model_remote "$t/tags.json" "$i")"; then
        remote=$((remote + 1)); emit FAIL "Ollama model $(clean "$nm")" "a cloud model: prompts to it run on $(clean "$where_to")"
      fi
      i=$((i + 1))
    done
    [ "$remote" = 0 ] && emit ok "Ollama models" "$i installed, none runs on a remote host"
  else
    emit FAIL "Ollama models" "/api/tags unreadable — cannot verify"
  fi

  # a server.json that asks for the switch, cross-checked against what the server says it
  # read (plutil accepts a trailing comma that Go rejects, and then cloud stays ENABLED)
  local sj="$HOME/.ollama/server.json"
  if [ -f "$sj" ] && [ "$(json_get "$sj" disable_ollama_cloud)" = true ]; then
    case "$src" in
      config|both) : ;;
      *) emit FAIL "Ollama server.json" "asks to disable the cloud but the server reports source=$(clean "${src:-absent}") — malformed, not restarted, or the server runs as another user" ;;
    esac
  fi
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# 3. AGENTS — provider overrides for Claude Code and Copilot CLI (catalogue §B.3)
#    An agent's own vendor, in the agent's own config, is fine. A cloud AI host that is NOT that
#    agent's vendor is a warn: routing an agent is the person's choice, and the line says so.
# ═════════════════════════════════════════════════════════════════════════════════════════════
AGENT_KEY_VARS="GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_GENERATIVE_AI_API_KEY OPENAI_API_KEY OPENAI_ORG_ID OPENAI_PROJECT_ID
AZURE_OPENAI_API_KEY AZURE_OPENAI_AD_TOKEN AZURE_API_KEY AZURE_AI_API_KEY AZURE_INFERENCE_CREDENTIAL AZURE_SPEECH_KEY SPEECH_KEY
ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_FOUNDRY_API_KEY ANTHROPIC_FOUNDRY_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
GROQ_API_KEY DEEPGRAM_API_KEY ELEVENLABS_API_KEY ELEVEN_API_KEY MISTRAL_API_KEY CODESTRAL_API_KEY OPENROUTER_API_KEY
CEREBRAS_API_KEY TOGETHER_API_KEY TOGETHERAI_API_KEY FIREWORKS_API_KEY FIREWORKS_AI_API_KEY PERPLEXITY_API_KEY PPLX_API_KEY
XAI_API_KEY GROK_API_KEY COHERE_API_KEY CO_API_KEY DEEPSEEK_API_KEY AWS_BEARER_TOKEN_BEDROCK ASSEMBLYAI_API_KEY
REPLICATE_API_TOKEN REPLICATE_API_KEY HF_TOKEN HUGGINGFACE_API_KEY HUGGINGFACEHUB_API_TOKEN HUGGING_FACE_HUB_TOKEN
OLLAMA_API_KEY SONIOX_API_KEY SPEECHMATICS_API_KEY CARTESIA_API_KEY GLADIA_API_KEY REVAI_ACCESS_TOKEN NVIDIA_API_KEY
NGC_API_KEY DEEPINFRA_API_KEY DEEPINFRA_TOKEN SAMBANOVA_API_KEY HYPERBOLIC_API_KEY NOVITA_API_KEY MOONSHOT_API_KEY
ZHIPUAI_API_KEY ZAI_API_KEY DASHSCOPE_API_KEY MINIMAX_API_KEY VOYAGE_API_KEY JINA_API_KEY AI_GATEWAY_API_KEY
PORTKEY_API_KEY NEBIUS_API_KEY LAMBDA_API_KEY BASETEN_API_KEY GITHUB_MODELS_TOKEN COPILOT_GITHUB_TOKEN
COPILOT_PROVIDER_API_KEY COPILOT_PROVIDER_BEARER_TOKEN"
# base-URL variables whose VALUE is a URL (read for its host only). OLLAMA_HOST is the Ollama probe's.
AGENT_URL_VARS="OPENAI_BASE_URL OPENAI_API_BASE OPENAI_API_HOST OPENAI_ENDPOINT AZURE_OPENAI_ENDPOINT ANTHROPIC_BASE_URL
ANTHROPIC_BEDROCK_BASE_URL ANTHROPIC_BEDROCK_MANTLE_BASE_URL ANTHROPIC_VERTEX_BASE_URL ANTHROPIC_FOUNDRY_BASE_URL
ANTHROPIC_AWS_BASE_URL GOOGLE_GEMINI_BASE_URL GEMINI_BASE_URL OPENROUTER_BASE_URL GROQ_BASE_URL MISTRAL_BASE_URL
DEEPSEEK_BASE_URL XAI_BASE_URL TOGETHER_BASE_URL HF_ENDPOINT HF_INFERENCE_ENDPOINT OLLAMA_BASE_URL OLLAMA_API_BASE
COPILOT_PROVIDER_BASE_URL LITELLM_BASE_URL LITELLM_PROXY_API_BASE"
# routing switches: name:where it sends the agent
AGENT_ROUTE_VARS="CLAUDE_CODE_USE_BEDROCK:AWS_Bedrock CLAUDE_CODE_USE_VERTEX:Google_Vertex_AI_(aiplatform.googleapis.com)
CLAUDE_CODE_USE_FOUNDRY:Microsoft_Foundry CLAUDE_CODE_USE_ANTHROPIC_AWS:Claude_Platform_on_AWS
CLAUDE_CODE_USE_MANTLE:AWS_Bedrock_Mantle"

AGENT_FOUND=0
# agent_var_owner <NAME> → claude|copilot|any — whose provider the variable configures
agent_var_owner() {
  case "$1" in
    ANTHROPIC_*|CLAUDE_CODE_*) printf claude ;;
    COPILOT_*) printf copilot ;;
    *) printf any ;;
  esac
}
agent_label() { case "$1" in claude) printf 'Claude Code' ;; copilot) printf 'Copilot' ;; *) printf 'any agent started from here' ;; esac; }
# agent_url <source> <NAME> <value> — classify one base URL by its host
agent_url() {
  local src="$1" name="$2" h owner vendor pat
  h="$(url_host "$3")"; owner="$(agent_var_owner "$name")"
  AGENT_FOUND=1
  if [ -z "$h" ]; then emit warn "$src $name" "set, but no host could be read from it"; return 0; fi
  if is_loopback_host "$h"; then emit ok "$src $name" "loopback ($(clean "$h")) — stays on this Mac"; return 0; fi
  case "$owner" in claude) vendor="$CLAUDE_OWN_HOSTS" ;; copilot) vendor="$COPILOT_OWN_HOSTS" ;; *) vendor="" ;; esac
  if [ -n "$vendor" ] && host_in_list "$h" "$vendor" >/dev/null; then
    emit ok "$src $name" "$(clean "$h") — $(agent_label "$owner")'s own vendor"
  elif pat="$(host_in_list "$h" "$CLOUD_AI_HOSTS")"; then
    emit warn "$src $name" "$(clean "$h") is a cloud AI service ($pat) that is not $(agent_label "$owner")'s vendor — routing it there is your choice, and it sends that agent's prompts and files there"
  else
    emit warn "$src $name" "$(clean "$h") is not this Mac and not a known AI vendor (a gateway or proxy?) — the agent's prompts go there"
  fi
}
agent_key() {                                   # agent_key <source> <NAME> — presence only, value never read
  local src="$1" name="$2" owner
  owner="$(agent_var_owner "$name")"
  AGENT_FOUND=1
  case "$name" in
    ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN)
      emit ok "$src $name" "Claude Code's own vendor credential (value not read)" ;;
    COPILOT_GITHUB_TOKEN)
      emit ok "$src $name" "Copilot's own vendor credential (value not read)" ;;
    COPILOT_PROVIDER_API_KEY|COPILOT_PROVIDER_BEARER_TOKEN)
      emit ok "$src $name" "the credential for COPILOT_PROVIDER_BASE_URL, judged on that line (value not read)" ;;
    *)
      emit warn "$src $name" "a cloud AI credential is set; $(agent_label "$owner") can use it to reach that service (value not read)" ;;
  esac
}
agent_route() {                                 # agent_route <source> <NAME> <value> <where>
  case "$(lower "$3")" in ''|0|false|no|off) return 0 ;; esac
  AGENT_FOUND=1
  emit warn "$1 $2" "routes $(agent_label "$(agent_var_owner "$2")") through $(printf '%s' "$4" | /usr/bin/tr '_' ' ') — a cloud AI endpoint that is your choice, not the agent's default"
}

probe_agents() {
  local name value r nm where src
  # ── the environment this check runs in (a launcher's or a shell's) ──
  local exported
  exported=" $(compgen -e | /usr/bin/tr '\n' ' ') "
  AGENT_FOUND=0
  for name in $AGENT_KEY_VARS; do case "$exported" in *" $name "*) agent_key environment "$name" ;; esac; done
  for name in $AGENT_URL_VARS; do case "$exported" in *" $name "*) agent_url environment "$name" "${!name}" ;; esac; done
  for r in $AGENT_ROUTE_VARS; do
    nm="${r%%:*}"; where="${r#*:}"
    case "$exported" in *" $nm "*) agent_route environment "$nm" "${!nm}" "$where" ;; esac
  done
  [ "$AGENT_FOUND" = 1 ] || emit ok "environment" "no AI provider override or cloud AI credential is exported"

  # ── Claude Code settings.json `env` (reaches every MCP server and hook Claude starts) ──
  local dirs="$HOME/.claude" d f keys
  [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "${CLAUDE_CONFIG_DIR%/}" != "$HOME/.claude" ] && dirs="$dirs ${CLAUDE_CONFIG_DIR%/}"
  for d in $dirs; do
    f="$d/settings.json"
    case "$f" in "$HOME"/*) src="Claude \$HOME/${f#"$HOME"/}" ;; *) src="Claude $f" ;; esac
    if [ ! -f "$f" ]; then emit n/a "$src" "no such file"; continue; fi
    if ! "$PLUTIL" -convert json -o /dev/null -- "$f" >/dev/null 2>&1; then
      emit FAIL "$src" "does not parse as JSON — cannot verify"; continue
    fi
    # the env block's KEY names only; sed drops every value line
    keys=" $("$PLUTIL" -extract env xml1 -o - -- "$f" 2>/dev/null | /usr/bin/sed -n 's#^[[:space:]]*<key>\([A-Za-z0-9_]*\)</key>.*#\1#p' | /usr/bin/tr '\n' ' ') "
    AGENT_FOUND=0
    for name in $AGENT_KEY_VARS; do case "$keys" in *" $name "*) agent_key "$src env" "$name" ;; esac; done
    for name in $AGENT_URL_VARS OLLAMA_HOST; do
      case "$keys" in *" $name "*) value="$(json_get "$f" "env.$name")" || value=""; agent_url "$src env" "$name" "$value" ;; esac
    done
    for r in $AGENT_ROUTE_VARS; do
      nm="${r%%:*}"; where="${r#*:}"
      case "$keys" in *" $nm "*) value="$(json_get "$f" "env.$nm")" || value=""; agent_route "$src env" "$nm" "$value" "$where" ;; esac
    done
    [ "$AGENT_FOUND" = 1 ] || emit ok "$src" "its env sets no AI provider override"
  done

  # ── Copilot CLI: config.json (JSONC, managed by Copilot) and settings.json. Copilot has no env
  #    key, so these are read as TEXT: which catalogue host or variable NAME they mention (grep -q,
  #    never a byte of the file printed) — plus settings.json's `model`. ──
  local cdir="${COPILOT_HOME:-$HOME/.copilot}" h hits stripped model
  for f in "$cdir/config.json" "$cdir/settings.json"; do
    case "$f" in "$HOME"/*) src="Copilot \$HOME/${f#"$HOME"/}" ;; *) src="Copilot $f" ;; esac
    [ -f "$f" ] || { emit n/a "$src" "no such file"; continue; }
    stripped="$LOCAL_ONLY_TMP/copilot-$(basename "$f")"
    /usr/bin/sed -e '/^[[:space:]]*\/\//d' "$f" > "$stripped" 2>/dev/null
    AGENT_FOUND=0
    hits="$(file_cloud_hosts "$stripped")"
    for h in $hits; do
      AGENT_FOUND=1
      if case " $COPILOT_OWN_HOSTS " in *" $h "*) true ;; *) false ;; esac; then
        emit ok "$src" "names $h — Copilot's own vendor"
      else
        emit warn "$src" "names $h, a cloud AI service that is not Copilot's vendor — routing Copilot there is your choice"
      fi
    done
    for name in $AGENT_KEY_VARS $AGENT_URL_VARS; do
      "$GREP" -qE "(^|[^A-Za-z0-9_])$name([^A-Za-z0-9_]|\$)" "$stripped" 2>/dev/null && {
        AGENT_FOUND=1; emit warn "$src" "mentions $name (value not read)"; }
    done
    if [ "${f##*/}" = settings.json ] && model="$(json_get "$stripped" model)" && [ -n "$model" ]; then
      AGENT_FOUND=1
      case "$(lower "$model")" in
        *gemini*) emit warn "$src model" "$(clean "$model") — GitHub hosts Gemini models on Google Cloud, so prompts go to Google" ;;
        *) emit ok "$src model" "$(clean "$model"), through GitHub Copilot" ;;
      esac
    fi
    [ "$AGENT_FOUND" = 1 ] || emit ok "$src" "names no AI provider override"
  done
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# 4. APPS — iTerm2's AI endpoint, Homebrew analytics
# ═════════════════════════════════════════════════════════════════════════════════════════════
# iterm_ai_enabled — iTerm2 honours EnableAI only from a ROOT-OWNED <dir>/EnableAI.secureSetting
# whose second line is the hex of "true" (iTerm2 SecureUserDefaults.swift: load() refuses any file
# not owned by uid 0). A user-writable file claiming true is ignored by iTerm2, so it is ignored here.
iterm_ai_enabled() {
  local d f payload
  if [ -n "${LOCAL_ONLY_ITERM_SECURE_DIR:-}" ]; then set -- "$LOCAL_ONLY_ITERM_SECURE_DIR"
  else set -- "$HOME/Library/Application Support/iTerm2" /usr/local/iTerm2-secure-settings; fi
  for d in "$@"; do
    f="$d/EnableAI.secureSetting"
    [ -f "$f" ] || continue
    [ "$(/usr/bin/stat -f '%u' "$f" 2>/dev/null)" = 0 ] || continue
    payload="$(/usr/bin/awk 'NR==2' "$f" 2>/dev/null | /usr/bin/xxd -r -p 2>/dev/null)"
    [ "$payload" = true ] && return 0
    [ "$payload" = false ] || return 2          # root-owned and unreadable: cannot verify
  done
  return 1
}

probe_apps() {
  local dom="${LOCAL_ONLY_ITERM_DOMAIN:-com.googlecode.iterm2}" url h ai
  if [ ! -f "$(plist_file "$dom")" ]; then
    emit n/a "iTerm2 AI" "no iTerm2 preferences"
  else
    url="$("$DEFAULTS" read "$dom" AitermURL 2>/dev/null)" || url=""
    iterm_ai_enabled; ai=$?
    h="$(url_host "$url")"
    if [ -n "$url" ] && is_loopback_host "$h"; then
      emit ok "iTerm2 AI" "its endpoint is loopback ($(clean "$h"))"
    elif [ "$ai" = 0 ]; then
      emit FAIL "iTerm2 AI" "enabled, and it sends terminal content to $(clean "${h:-api.openai.com (its default)}")"
    elif [ "$ai" = 2 ]; then
      emit FAIL "iTerm2 AI" "its root-owned enable file could not be read — cannot verify"
    elif [ -n "$url" ]; then
      emit warn "iTerm2 AI" "an endpoint is set ($(clean "$h")) but the AI feature is off (it needs an admin-approved switch), so nothing is sent"
    else
      emit ok "iTerm2 AI" "off, and no endpoint set"
    fi
  fi

  local brew="" repo="" off=""
  for w in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$w" ] && { brew="$w"; break; }; done
  if [ -z "$brew" ]; then emit n/a "Homebrew analytics" "Homebrew not installed"; return 0; fi
  case "$brew" in /opt/homebrew/*) repo=/opt/homebrew ;; *) repo=/usr/local/Homebrew ;; esac
  [ -n "${HOMEBREW_NO_ANALYTICS:-}" ] && off="HOMEBREW_NO_ANALYTICS in the environment"
  # `brew analytics off` persists as git config in the brew repo; read the file, not git (which
  # can raise the developer-tools install dialog on a fresh Mac)
  if [ -z "$off" ] && [ -r "$repo/.git/config" ] && /usr/bin/awk '
      /^\[/ { s = ($0 ~ /^\[homebrew\]/) }
      s && tolower($0) ~ /^[[:space:]]*analyticsdisabled[[:space:]]*=[[:space:]]*true/ { f = 1 }
      END { exit !f }' "$repo/.git/config"; then off="brew analytics off"; fi
  if [ -z "$off" ]; then
    for w in /etc/homebrew/brew.env "${brew%/bin/brew}/etc/homebrew/brew.env" "${XDG_CONFIG_HOME:-$HOME/.config}/homebrew/brew.env" "$HOME/.homebrew/brew.env"; do
      [ -r "$w" ] && "$GREP" -qE '^[[:space:]]*(export[[:space:]]+)?HOMEBREW_NO_ANALYTICS=.+' "$w" && { off="brew.env"; break; }
    done
  fi
  if [ -n "$off" ]; then emit ok "Homebrew analytics" "off ($off)"
  else emit warn "Homebrew analytics" "on: package names, OS and CPU go to analytics.brew.sh, never file content — \`brew analytics off\` stops it"; fi
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
selected voiceink && probe_voiceink
selected ollama && probe_ollama
selected agents && probe_agents
selected apps && probe_apps

[ "$LOCAL_ONLY_FAILS" = 0 ] && exit 0
exit 1
