#!/bin/bash
# rewrite_model — the LOCAL model that replaces cloud Gemini as VoiceInk's rewrite engine.
#
# Sourced by bootstrap.sh. Six verbs + bench_. No top-level side effects. See CONTRACT.md.
#
# END STATE, and every clause of it is read back through a path that did not write it:
#
#   1. ollama is installed and its server answers at http://localhost:11434 — a LOOPBACK address.
#      Any other base URL is refused before a single request is made to it.
#   2. that server's OWN /api/status says cloud.disabled == true. The lever is
#      $HOME/.ollama/server.json {"disable_ollama_cloud": true} (plus OLLAMA_NO_CLOUD=1 on a server
#      this module starts), but the FILE is never the evidence: one with a trailing comma leaves
#      cloud ON while plutil still parses it (measured), and a running server reads it only at
#      start (measured: 8 s after the write, a live server still said disabled:false).
#   3. a DERIVED model `voiceink-rewrite` exists, built FROM the tier's base with
#      num_ctx 4096 / temperature 0.2 / top_p 0.9 / top_k 20 / repeat_penalty 1.0 baked in, and
#      NOT backed by a remote host. A cloud base (`*-cloud`, `:cloud`, or a model whose /api/tags
#      entry carries remote_host) is refused by --model and --bench before any request.
#   4. THAT EXACT MODEL (matched by digest, not by name) has passed assets/model-gate.sh
#   5. VoiceInk's EnhancementTimeoutSeconds is 15
#   6. EVERY enabled VoiceInk mode with AI enhancement on names provider Ollama AND model
#      voiceink-rewrite, and VoiceInk's Ollama URL is loopback. Only the GUI sets a mode, so this
#      is also the evidence that the human did the one step no script does.
#
# ═════════════════════════════════════════════════════════════════════════════════════════════
# WHY A DERIVED MODEL, AND WHY THE GUI STEP IS STRUCTURAL — read before changing anything here
# ═════════════════════════════════════════════════════════════════════════════════════════════
#
# THE MODEL. `ollama pull qwen3:8b` and picking `qwen3:8b` in VoiceInk's picker produces a
# working-LOOKING setup that runs at the tag's own temperature (0.6-0.8) on a task whose failure
# mode is invention, because VoiceInk sends `temperature` at the top level of /api/generate where
# ollama drops it. The Modelfile is the only lever. The full measurement, both arms of the A/B and
# the refutation of the "24 GB" story are in assets/voiceink-rewrite.Modelfile.
#
# THE GUI STEP (this is this module's whole point). VoiceInk resolves its AI provider PER MODE, and
# the source this repo builds (upstream Beingpax/VoiceInk v2.13, commit 68b871e7) does it in
# ModeRuntimeConfiguration.swift:204-216:
#   - a mode that NAMES a provider gets that provider if it is connected, and NOTHING otherwise —
#     no enhancement, no egress. A mode that names Gemini therefore calls Gemini, whatever else runs.
#   - a mode whose provider is nil gets connectedProviders.first, and connectedProviders filters
#     AIProvider.allCases IN DECLARATION ORDER (AIService.swift:245-264): seven cloud providers
#     come before Ollama, so any surviving cloud key wins. The migration also re-seeds a nil
#     provider from the global selectedAIProvider at every launch (ModeDataMigration.swift:36-46).
#   - the model is the mode's selectedAIModel if /api/tags lists it, else the FIRST listed model.
# So the only evidence that the local model runs is per mode: provider Ollama, model
# voiceink-rewrite, on every enabled mode with enhancement on — any enabled mode can become the
# effective one through its hotkey or an app trigger (ModeConfig.swift:391-429). The global
# ollamaSelectedModel this module used to read proves nothing: the runtime reaches it only when
# Ollama's model list is empty (AIService.swift:87). Measured on the development Mac: five of six
# modes had enhancement on with provider Gemini while that key named the local model.
#
# 🚨 The fallback rule this block used to state — "an explicit provider is honoured only if it is
# connected, otherwise connectedProviders.first" — is the FORK's (renchris/voiceink-opensource-build
# main-2.0, ModeRuntimeConfiguration.swift:256-268), not v2.13's. On the fork a mode pinned to Ollama
# silently reroutes to a cloud provider whenever the Ollama server is down; on v2.13 it does not.
#
#   *** WHICH PROVIDER A MODE NAMES IS WHY THE HUMAN GESTURE IS REQUIRED — and a module that reported
#   *** SATISFIED without reading it would be lying about where the dictated text goes.
#
# 🚨 CORRECTED 2026-09-13. This block used to say "NO `defaults write` CAN EVER SELECT OLLAMA; the
# Connect click is STRUCTURALLY REQUIRED", on the reasoning that ollama joins connectedProviders
# only via a live checkConnection() probe. The premise is true and the conclusion does not follow:
# VoiceInk.swift:97 calls refreshOllamaAvailabilityInBackground() UNCONDITIONALLY in the App's
# init(), so that probe runs at every launch and ollama auto-connects whenever its server is up —
# the button is labelled "Refresh" once connected, not "Connect". The end state this module holds
# out for survives unchanged, but it rests on the cloud-key race above, NOT on an unreachable
# preference key. Kept as a correction rather than a silent edit because the false version was
# load-bearing in a way that would have made a future reader trust the wrong mechanism.
#
# So rewrite_model does every reversible thing itself, and then REFUSES to call itself done until the one
# irreducibly-human gesture has left its mark in the modes.
#
# WHERE THE KEYS LIVE, corrected. This block used to say a LOCAL_BUILD keeps every API key in
# UserDefaults as `LocalKeychain_<provider>APIKey`, citing KeychainService.swift:14-17,36-38 — the
# FORK's lines. At v2.13 a LOCAL_BUILD keeps them in the login keychain under the service
# com.prakashjoshipax.VoiceInk.Local (KeychainService.swift:27-33,215-231); `LocalKeychain_*` is a
# legacy fallback that the first read migrates into the keychain and deletes (:160-166,241-246). The
# probe that followed from the wrong premise checked the defaults keys and a keychain service no build
# uses, so after one v2.13 launch it answered "no cloud key" while every Gemini mode kept calling
# Gemini. It is gone.
#
# WHAT THIS MODULE WILL NOT DO
#   - It will not plutil-copy or export the com.prakashjoshipax.VoiceInk domain. That domain
#     holds live provider API keys. It writes exactly two keys, individually, by name.
#   - It will not write a mode, or ollamaSelectedModel. A mode is a JSON blob holding the person's
#     hotkeys, prompts and triggers; the app owns it, and the app is where the provider is picked.
#   - It will not start an ollama server that can reach ollama.com, or send a request to an ollama
#     that is not on this Mac.
#   - It will not install a model it has not just measured. If the gate fails, the derived model
#     is REMOVED and the module reports FAILED — a certified-bad rewrite engine pastes invented
#     text into the user's documents, and is strictly worse than no enhancement at all.
#   - Below 12 GB it will not guess. There is no measured 100th-percentile option at 8 GB, and
#     `bench_rewrite_model` exists precisely so nobody has to.
#
# THE TIER RULE — measured, and the REASON has been corrected since the first write-up
#   >= 12 GB unified memory -> qwen3:8b   (resident 5.65 GB at num_ctx 4096; byte-identical 5/5
#                                          on all four fixtures, reproduced twice independently;
#                                          0.64-1.50 s median on an M1 Max)
#
#   🚨 "all four fixtures" was FALSE when written and is true as of 2026-09-13. assets/model-gate.sh
#   shipped TWO (F4, F2) while this comment claimed four and the ban on qwen3.5:9b cited a
#   time-invention fixture that existed nowhere — so the gate could not reproduce its own bans,
#   and would have PASSED the model this file records rejecting. F5 (an invented AM/PM qualifier)
#   and F13 (an invented number) now ship, and the claim above is checkable again.
#   <  12 GB                -> NOTHING is installed. Every model measured at <= 2.5 GB that
#                              passed the question-rephrasing fixture lost content elsewhere, and
#                              every one that cleaned well answered the question. Leaving AI
#                              enhancement OFF is a better outcome than a model that invents.
#
# 🚨 DO NOT re-justify qwen3:8b with "there is no 2026 model in that size class". That claim is
# FALSE and checkable in 30 seconds: qwen3.5 ships dense 4b and 9b, gemma4 ships e2b/e4b. The
# reason is the MEASUREMENT. qwen3.5:9b was pulled and run head-to-head at the same num_ctx 4096
# and temp 0.2: lighter (5.44 vs 5.65 GB), equally fast, and it fixes qwen3:8b's one blemish —
# but it INVENTED an AM/PM qualifier ("three thirty" -> "3:30 PM") against a prompt whose rule is
# "do not add unsupported facts", and was byte-identical on only 2 of 4 fixtures against
# qwen3:8b's 4 of 4. On a task whose failure mode is invention, determinism is the product.
#
# 🚨 qwen3:4b IS FORBIDDEN and install_ refuses it by name. It is the most attractive-looking tag
# in the library for this job and the single worst performer measured: 82-156 s per call, ~2,200-
# 2,900 output tokens for a 30-word transcript, and it writes its chain of thought as PLAIN PROSE
# that VoiceInk's <think>-tag filter cannot strip — so the reasoning is pasted into the document.
# Tuning num_ctx and temperature does not fix it; it is a property of the tag's own template.
# `bench_` will still measure it on request, because a ban nobody can re-test is a ban nobody can
# ever retire.
#
# THE TRANSCRIPTION MODEL is deliberately ADVISORY here, not part of verify_. The measured
# recommendation is `parakeet-unified-0.6b` over `ggml-large-v3-turbo` — the fork's own registry
# rates it faster (0.99 vs 0.75), more accurate (0.95 vs 0.94) and lighter (ram 1.0 vs 1.8);
# upstream reports 2.15% WER on LibriSpeech test-clean (on an M5 Pro — the WER transfers, the
# RTFx does not); its heavy layers are ANE-resident with the tail on CPU, so it does not contend
# with the rewrite model on the GPU; and it emits its own punctuation and capitalisation, which
# removes work from the rewrite model. It is NOT verified because it is a LANGUAGE choice:
# Unified is English-only, `parakeet-tdt-0.6b-v3` covers 25 EU languages, and for anything
# outside those, whisper's ~99-language coverage is still unmatched in the registry. A verifier
# that demanded Parakeet would convict a multilingual user forever. note_ says it instead.

# ── seams. Every one has a default; none is required. ────────────────────────────────────────
REWRITE_MODEL_NAME="${BOOTSTRAP_REWRITE_MODEL_NAME:-voiceink-rewrite}"            # the derived model, and the VoiceInk picker entry
REWRITE_MODEL_URL="${MODEL_GATE_BASE_URL:-http://localhost:11434}"
REWRITE_MODEL_DOMAIN="${BOOTSTRAP_REWRITE_MODEL_DOMAIN:-com.prakashjoshipax.VoiceInk}"
REWRITE_MODEL_TIMEOUT_S="${BOOTSTRAP_REWRITE_MODEL_TIMEOUT_S:-15}"                # EnhancementTimeoutSeconds
# The app whose running-ness blocks a preference write. A seam ONLY so the lifecycle can be
# exercised on a machine where VoiceInk is open (it is paired with BOOTSTRAP_REWRITE_MODEL_DOMAIN, which points the
# writes at a throwaway domain). Pointing it at nothing on a real machine does not manufacture a
# green: VoiceInk would rewrite the domain on quit, the next verify_ would read the old value
# back, and the module would return to NEEDS_HUMAN.
REWRITE_MODEL_APP="${BOOTSTRAP_REWRITE_MODEL_APP_PROCESS:-VoiceInk}"
# The ollama and brew executables, when set: each is then the ONLY candidate, so a test can make
# a tool absent on a Mac that has it (a path that does not exist) or stand a stub in for it.
REWRITE_MODEL_OLLAMA_SEAM="${BOOTSTRAP_REWRITE_MODEL_OLLAMA:-}"
REWRITE_MODEL_BREW_SEAM="${BOOTSTRAP_REWRITE_MODEL_BREW:-}"
REWRITE_MODEL_CURL="${BOOTSTRAP_REWRITE_MODEL_CURL:-/usr/bin/curl}"     # a seam only so tests can stand in a fake server
REWRITE_MODEL_DEFAULTS=/usr/bin/defaults
REWRITE_MODEL_PGREP=/usr/bin/pgrep
REWRITE_MODEL_SYSCTL=/usr/sbin/sysctl
REWRITE_MODEL_LAUNCHCTL=/bin/launchctl

# ── the no-admin route: ollama's own signed, notarized CLI tarball, pinned ─────────────────────
# Homebrew's installer needs an administrator, and its ollama bottle needs a source build of
# python on Sonoma and on Intel (no bottle for either), so a standard user on a corporate Mac has
# no Homebrew route at all. The tarball is universal (x86_64 + arm64, measured with lipo), signed
# with Developer ID team 3MU9H2V9Y9 and the hardened runtime (measured with codesign), and a file
# curl writes carries no quarantine flag. Its layout is FLAT — `ollama`, `llama-server`, the ggml
# and mlx libraries side by side at the archive root — and the binary runs through a symlink
# (measured: it served and found Metal from $(bootstrap_tools_dir)/bin/ollama). Its floor is macOS 14.
# The sha is the one ollama publishes in the release's sha256sum.txt; the download was re-hashed here.
# Official install.sh is NOT used: on macOS it moves into /Applications and sudo-links /usr/local/bin.
REWRITE_MODEL_OLLAMA_VERSION=0.34.0
REWRITE_MODEL_OLLAMA_TARBALL="https://github.com/ollama/ollama/releases/download/v$REWRITE_MODEL_OLLAMA_VERSION/ollama-darwin.tgz"
REWRITE_MODEL_OLLAMA_SHA256=dd12b00bcce2d6551178e67ada90d5af9f75bdb54a118b96655250fa3e8ef734
REWRITE_MODEL_OLLAMA_MACOS_FLOOR=14
# The user LaunchAgent this module runs the server under whenever it is the one starting it. Its
# environment carries OLLAMA_NO_CLOUD=1, so this server can never reach ollama.com. The two brew
# labels are the ones `brew services` uses (sh.brew.* since 2026, homebrew.mxcl.* before).
REWRITE_MODEL_AGENT_LABEL=com.mac-bootstrap.ollama
REWRITE_MODEL_SERVER_LABELS="$REWRITE_MODEL_AGENT_LABEL sh.brew.ollama homebrew.mxcl.ollama"

# ── tiny helpers. All absolute-path-first: a PATH lookup inside a bootstrap inherits whatever
#    the operator's shell happens to be, and `brew` is not on the PATH of a fresh login shell
#    until the shellenv line lands. bootstrap_find_tool searches the pinned copy first. ────────
rewrite_model_ollama() {
  if [ -n "$REWRITE_MODEL_OLLAMA_SEAM" ]; then
    [ -x "$REWRITE_MODEL_OLLAMA_SEAM" ] && { printf '%s' "$REWRITE_MODEL_OLLAMA_SEAM"; return 0; }
    return 1
  fi
  bootstrap_find_tool ollama
}
rewrite_model_brew() {
  if [ -n "$REWRITE_MODEL_BREW_SEAM" ]; then
    [ -x "$REWRITE_MODEL_BREW_SEAM" ] && { printf '%s' "$REWRITE_MODEL_BREW_SEAM"; return 0; }
    return 1
  fi
  bootstrap_find_tool brew
}

# rewrite_model_brew_usable — a brew THIS user can install with: its Cellar is writable. On a corporate
# Mac an administrator usually installed Homebrew, so the prefix is theirs and `brew install` fails
# for everyone else; BOOTSTRAP_ASSUME_STANDARD_USER=1 stands for exactly that shape.
rewrite_model_brew_usable() {
  local b
  b="$(rewrite_model_brew)" || return 1
  [ "${BOOTSTRAP_ASSUME_STANDARD_USER:-0}" = 1 ] && return 1
  [ -w "$(/usr/bin/dirname "$(/usr/bin/dirname "$b")")/Cellar" ]
}

rewrite_model_macos_major() {
  local v
  v="$(/usr/bin/sw_vers -productVersion 2>/dev/null)" || v=""
  v="${v%%.*}"
  case "${v:-}" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$v" ;; esac
}

# rewrite_model_route — how ollama gets onto this Mac, one token, so every verb agrees:
#   present  an ollama is already on disk (the pinned copy, Homebrew's, or anything on PATH)
#   brew     Homebrew, which this user can install with
#   pinned   ollama's own tarball into $(bootstrap_tools_dir) — no Homebrew, no admin
#   oldmac   the pinned route is the only one, and this macOS is below its floor
rewrite_model_route() {
  if rewrite_model_ollama >/dev/null 2>&1; then printf 'present'
  elif rewrite_model_brew_usable; then printf 'brew'
  elif [ "$(rewrite_model_macos_major)" -lt "$REWRITE_MODEL_OLLAMA_MACOS_FLOOR" ]; then printf 'oldmac'
  else printf 'pinned'; fi
}

# rewrite_model_url_host <url> — the host of a base URL, brackets kept for IPv6.
rewrite_model_url_host() {
  local h="${1#*://}"
  h="${h%%/*}"
  case "$h" in
    '['*) h="${h%%]*}]" ;;
    *:*)  h="${h%:*}" ;;
  esac
  printf '%s' "$h"
}
rewrite_model_url_port() {
  local h="${1#*://}"
  h="${h%%/*}"
  case "$h" in
    *\]:*|[!\[]*:*) h="${h##*:}" ;;
    *) h=11434 ;;
  esac
  case "$h" in ''|*[!0-9]*) h=11434 ;; esac
  printf '%s' "$h"
}
# rewrite_model_is_loopback <host> — the only hosts a prompt may go to. 0.0.0.0 is not one: it is a bind
# address meaning "every interface".
rewrite_model_is_loopback() {
  case "$(printf '%s' "${1:-}" | /usr/bin/tr 'A-Z' 'a-z')" in
    127.*|localhost|::1|'[::1]') return 0 ;;
  esac
  return 1
}
# rewrite_model_url_ok — the base URL every request here goes to is on this Mac. Every request path
# below checks it, so a MODEL_GATE_BASE_URL naming another host is refused before a byte is sent —
# fixture prompts included, which are text the person never agreed to send anywhere.
rewrite_model_url_ok() {
  case "$REWRITE_MODEL_URL" in http://*|https://*) : ;; *) return 1 ;; esac
  rewrite_model_is_loopback "$(rewrite_model_url_host "$REWRITE_MODEL_URL")"
}

# rewrite_model_cloud_ref <tag> — rc 0 if ollama would send this model reference to ollama.com. ollama's
# own rule (internal/modelref parseSourceSuffix): the last `:` segment is `cloud` or ends in
# `-cloud`, any case. Since v0.18.0 such a reference needs no local model at all — the server
# proxies it straight out — so a name alone is enough to refuse it. A name with no tag that ends in
# -cloud is refused too: over-refusing a spelling costs a rename, under-refusing costs a transcript.
# The `:local` suffix forces local and is not refused.
rewrite_model_cloud_ref() {
  local s
  s="$(printf '%s' "${1##*:}" | /usr/bin/tr 'A-Z' 'a-z')"
  case "$s" in cloud|*-cloud) return 0 ;; esac
  return 1
}

# Everything this module writes lives in the state dir, never in the repo. Files named
# rewrite-model-cache-* are raw API responses, kept only so the caller can parse fields out of them; they
# are the ONLY files that differ between two consecutive runs (ollama stamps modified_at into
# every /api/tags reply), and nothing reads them across runs.
rewrite_model_state() { printf '%s/%s' "${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}" "$1"; }

# rewrite_model_mem_gb — unified memory in whole GB, or 0 when sysctl cannot say. 0 is NOT "small": it is
# unknown, and the tier rule treats unknown as "do not guess", which is the same branch as 8 GB.
rewrite_model_mem_gb() {
  local b
  b="$("$REWRITE_MODEL_SYSCTL" -n hw.memsize 2>/dev/null)" || b=""
  case "${b:-}" in ''|*[!0-9]*) printf '0'; return 0 ;; esac
  printf '%s' $((b / 1073741824))
}

# rewrite_model_base — the base tag this machine should derive from, or EMPTY when there is no measured
# option. An explicit --model always wins: it is the operator's own choice, and bench_ exists to
# inform it.
rewrite_model_base() {
  local m
  m="${BOOTSTRAP_MODEL:-${BOOTSTRAP_MODEL:-}}"
  [ -n "$m" ] && { printf '%s' "$m"; return 0; }
  [ "$(rewrite_model_mem_gb)" -ge 12 ] && { printf 'qwen3:8b'; return 0; }
  return 0
}

# rewrite_model_forbidden <tag> — rc 0 if this base may not be installed. Matches the family, not one
# spelling: qwen3:4b, qwen3:4b-q8_0 and qwen3:4b-instruct all carry the same template.
rewrite_model_forbidden() {
  case "${1:-}" in
    # Every spelling of the family, not one tag. `qwen3:4b` was the only pattern here, so a
    # DERIVED model built from it — vi-qwen3-4b, which already exists on the development
    # machine — carried the identical broken template straight past the ban.
    qwen3:4b|qwen3:4b-*|*qwen3-4b*|*qwen3_4b*|*qwen3.4b*) return 0 ;;
    *deepseek-r1*) return 0 ;;
  esac
  return 1
}

# rewrite_model_thinking_base <tag> — rc 0 if ollama reports this model as a THINKING fine-tune.
# The name-matching above is a convenience that catches the two families we have measured; THIS
# is the property that actually predicts the defect, and it is read from the server's own
# manifest rather than from a list someone has to remember to update.
#
# It is deliberately NOT a gate. A thinking base is a reason to look, not a conviction: polarity
# is per-family (qwen3:4b leaks at think:false and is clean at think:true; granite4.2:3b is the
# exact mirror), so only a generation can settle it. assets/model-gate.sh clause E does that, by
# behaviour, for every model regardless of its name — which is why the ban list no longer has to
# be complete to be safe.
#
# 🚨 THIS IS THE ONE READ IN THIS MODULE THAT DOES NOT GO THROUGH bootstrap_settings_get, AND THE
# REASON IS STRUCTURAL, NOT LAZINESS. The field is `model_info` -> `"general.finetune"` — a JSON
# key that CONTAINS A DOT. The library splits keypaths on `.` (CONTRACT.md §1 states the segment
# rule outright), so `model_info.general.finetune` addresses a nested object that does not exist
# and the value is unreachable through the house parser. Verified: plutil returns nothing for the
# keypath while the key holds "Thinking". So this reads the server's own reply with a targeted
# pattern — which is still an independent read of a document this module did not write, not the
# grep-for-what-you-just-wrote that the house rule forbids.
rewrite_model_thinking_base() {
  local f
  f="$(rewrite_model_state rewrite-model-cache-think.json)"
  rewrite_model_show "${1:-}" "$f" || return 1
  LC_ALL=C /usr/bin/grep -q '"general\.finetune"[[:space:]]*:[[:space:]]*"[^"]*[Tt]hinking' "$f"
}

# ── the ollama HTTP API. Every read-back goes through this, and NEVER through the `ollama` CLI
#    that wrote the model — two engines by construction. Parsing is plutil-only, for the same
#    reason bootstrap_settings_get is: it must work on a Mac with no jq. ─────────────────────────────

# rewrite_model_api_post <path> <body> <outfile> — rc 0 iff curl succeeded AND the reply parses as JSON.
rewrite_model_api_post() {
  local p="$1" body="$2" out="$3" rc
  rewrite_model_url_ok || return 1
  "$REWRITE_MODEL_CURL" -sS -m "${BOOTSTRAP_REWRITE_MODEL_HTTP_TIMEOUT:-30}" -H 'Content-Type: application/json' \
    -d "$body" "$REWRITE_MODEL_URL$p" >"$out" 2>/dev/null
  rc=$?
  [ $rc -eq 0 ] || return 1
  bootstrap_json_ok "$out" || return 1
  return 0
}
rewrite_model_api_get() {
  local p="$1" out="$2" rc
  rewrite_model_url_ok || return 1
  "$REWRITE_MODEL_CURL" -sS -m "${BOOTSTRAP_REWRITE_MODEL_HTTP_TIMEOUT:-30}" "$REWRITE_MODEL_URL$p" >"$out" 2>/dev/null
  rc=$?
  [ $rc -eq 0 ] || return 1
  bootstrap_json_ok "$out" || return 1
  return 0
}

# rewrite_model_json_field <file> <keypath> — the library's own read-back, pinned to `raw`. NOT a second
# implementation: bootstrap_settings_get already handles the trap that matters here, which is that
# `plutil -extract` writes its FAILURE MESSAGE TO STDOUT, so a reader that forwards stdout
# blindly hands its caller an error sentence where a value belongs. The wrapper exists only to
# fix the format argument at every call site — an ollama reply is a JSON document and every
# field this module reads out of one is a scalar.
rewrite_model_json_field() { bootstrap_settings_get "${1:-}" "${2:-}" raw; }

rewrite_model_server_up() { rewrite_model_url_ok && "$REWRITE_MODEL_CURL" -fsS -m 5 "$REWRITE_MODEL_URL/api/version" >/dev/null 2>&1; }

# rewrite_model_wait_up <seconds> — a first start of a freshly unpacked ollama took ~20 s before it
# answered (GPU discovery; measured), so the budget is generous.
rewrite_model_wait_up() {
  local waited=0
  while [ "$waited" -lt "${1:-90}" ]; do
    rewrite_model_server_up && return 0
    sleep 1
    waited=$((waited + 1))
  done
  rewrite_model_server_up
}

# rewrite_model_cloud_disabled — the SERVER's own statement of its cloud policy, GET /api/status
# (ollama >= 0.16.2). This is the evidence, never server.json: see the header, clause 2. An older
# server has no such route and no cloud switch, so it answers no here — correctly.
rewrite_model_cloud_disabled() {
  local f
  f="$(rewrite_model_state rewrite-model-cache-status.json)"
  rewrite_model_api_get /api/status "$f" || return 1
  [ "$(rewrite_model_json_field "$f" cloud.disabled 2>/dev/null)" = true ]
}

# rewrite_model_remote_model <name> — rc 0 if /api/tags lists this model with a remote_host, i.e. its
# generations are proxied to another machine. Read from /api/tags, NOT /api/show: with cloud
# disabled, show on a remote-backed model is a 403, which reads as "not installed" (measured in
# the research), while tags lists it with remote_host either way. A model that is not listed is
# not remote — the callers that need it present check that separately.
rewrite_model_remote_model() {
  local t n i r
  t="$(rewrite_model_state rewrite-model-cache-tags.json)"
  rewrite_model_api_get /api/tags "$t" || return 1
  i=0
  while [ "$i" -lt 512 ]; do
    n="$(rewrite_model_json_field "$t" "models.$i.name")" || break
    case "$n" in
      "$1"|"$1:latest")
        r="$(rewrite_model_json_field "$t" "models.$i.remote_host" 2>/dev/null)" || r=""
        [ -n "$r" ] && return 0
        return 1 ;;
    esac
    i=$((i + 1))
  done
  return 1
}

# rewrite_model_show <model> <outfile> — POST /api/show. rc 1 when the model is not there.
rewrite_model_show() {
  # bootstrap_json_escape, not string interpolation: REWRITE_MODEL_NAME arrives from a seam and a bare " in it
  # would produce a body the server rejects with an error this function would then read as
  # "the model is not there".
  rewrite_model_api_post /api/show "{\"model\":\"$(bootstrap_json_escape "$1")\"}" "$2" || return 1
  rewrite_model_json_field "$2" details >/dev/null 2>&1 || return 1
  return 0
}

# rewrite_model_digest <model> — the registry digest from /api/tags, which is what binds a gate PASS to the
# BYTES that passed it. A name is not an identity: `ollama create` over the same name with a
# different base leaves the name intact and every byte different.
rewrite_model_digest() {
  local t n i d total
  t="$(rewrite_model_state rewrite-model-cache-tags.json)"
  rewrite_model_api_get /api/tags "$t" || return 1
  i=0; total=0
  while [ "$i" -lt 512 ]; do
    n="$(rewrite_model_json_field "$t" "models.$i.name")" || break
    total=$((total + 1))
    case "$n" in
      "$1"|"$1:latest")
        d="$(rewrite_model_json_field "$t" "models.$i.digest")" || d=""
        [ -n "$d" ] && { printf '%s' "$d"; return 0; }
        ;;
    esac
    i=$((i + 1))
  done
  [ "$total" -eq 0 ] && return 1     # an empty library is not the same as "not found", but both
  return 1                            # mean the same thing to every caller here
}

rewrite_model_model_present() { rewrite_model_digest "$1" >/dev/null 2>&1; }

# rewrite_model_params_ok <showfile> — does the derived model actually carry the parameters we baked?
# /api/show renders `parameters` as ollama's own text block, produced by the SERVER from its
# stored manifest — not by us, and not by the CLI call that created it. Reading it back is a
# genuine second engine; what would NOT be one is grepping the Modelfile we just wrote.
rewrite_model_params_ok() {
  local p
  p="$(rewrite_model_json_field "$1" parameters)" || return 1
  printf '%s' "$p" | grep -qE '^[[:space:]]*num_ctx[[:space:]]+4096[[:space:]]*$' || return 1
  printf '%s' "$p" | grep -qE '^[[:space:]]*temperature[[:space:]]+0\.2[[:space:]]*$' || return 1
  return 0
}

# ── VoiceInk preferences ─────────────────────────────────────────────────────────────────────
# `defaults`, not bootstrap_settings_merge: that function is the one writer for JSON settings FILES and
# structurally refuses anything whose first byte is not `{` — this domain is a binary plist owned
# by cfprefsd. The read-back is `defaults read`, deliberately NOT plutil on the .plist: cfprefsd
# holds the authoritative copy and the file on disk can lag a write by an unbounded interval, so
# a plutil read can report the old value and convict a write that landed.
rewrite_model_preference() {                                   # rewrite_model_preference <key> -> value, rc 1 when absent
  local v rc
  v="$("$REWRITE_MODEL_DEFAULTS" read "$REWRITE_MODEL_DOMAIN" "$1" 2>/dev/null)"
  rc=$?
  [ $rc -eq 0 ] || return 1
  printf '%s' "$v"
}
rewrite_model_preference_exists() { "$REWRITE_MODEL_DEFAULTS" read-type "$REWRITE_MODEL_DOMAIN" "$1" >/dev/null 2>&1; }

# rewrite_model_voiceink_running — a RUNNING VoiceInk rewrites its whole preference domain when it exits, so
# any `defaults write` made underneath it is silently discarded. -x, never -f: `pgrep -f` matches
# any command line that merely MENTIONS the string, which in an agent session includes the brief
# describing this module.
rewrite_model_voiceink_running() { "$REWRITE_MODEL_PGREP" -x "$REWRITE_MODEL_APP" >/dev/null 2>&1; }

# rewrite_model_domain_plist — the FILE behind the domain. BOOTSTRAP_REWRITE_MODEL_DOMAIN may be an absolute
# .plist path, which `defaults` reads and writes directly (measured), so a test never touches the
# real domain. The app is unsandboxed, so the real file is in ~/Library/Preferences.
rewrite_model_domain_plist() {
  case "$REWRITE_MODEL_DOMAIN" in
    /*.plist) printf '%s' "$REWRITE_MODEL_DOMAIN" ;;
    /*)       printf '%s.plist' "$REWRITE_MODEL_DOMAIN" ;;
    *)        printf '%s/Library/Preferences/%s.plist' "$HOME" "$REWRITE_MODEL_DOMAIN" ;;
  esac
}

# rewrite_model_modes_pinned — rc 0 iff at least one enabled mode has AI enhancement on, EVERY such mode
# names provider Ollama and model voiceink-rewrite, and VoiceInk's Ollama URL is loopback. rc 1
# otherwise, with one line on stdout saying which mode names what (mode names and provider names
# only — the modes hold no key material). rc 2 when the modes cannot be read at all.
#
# The modes are one JSON array stored as DATA under modeConfigurationsV2. `defaults read` truncates
# data ({length = N, bytes = …}) and `defaults export` would pipe every saved API key, so the one key
# is extracted from the plist file with plutil and base64-decoded into a temp file that is deleted
# before return. The file can lag cfprefsd by a save, which errs towards NOT satisfied — the safe side.
# A missing isEnabled or isAIEnhancementEnabled is read as ON: fail closed.
rewrite_model_modes_pinned() {
  local plist b64 tmp i on=0 bad="" name en enh prov model url
  plist="$(rewrite_model_domain_plist)"
  [ -f "$plist" ] || { printf 'VoiceInk has no preferences yet, so it has no mode'; return 2; }
  [ "$(/usr/bin/plutil -type modeConfigurationsV2 "$plist" 2>/dev/null)" = data ] \
    || { printf 'VoiceInk has no modes saved (modeConfigurationsV2 is absent)'; return 2; }
  b64="$(/usr/bin/plutil -extract modeConfigurationsV2 raw -o - "$plist" 2>/dev/null)" \
    || { printf 'VoiceInk modes could not be read'; return 2; }
  tmp="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/rewrite-model-modes.XXXXXX")" || return 2
  printf '%s' "$b64" | /usr/bin/base64 -D >"$tmp" 2>/dev/null
  if ! bootstrap_json_ok "$tmp"; then /bin/rm -f "$tmp"; printf 'VoiceInk modes are not JSON'; return 2; fi
  i=0
  while [ "$i" -lt 64 ]; do
    /usr/bin/plutil -extract "$i" json -o /dev/null "$tmp" >/dev/null 2>&1 || break
    name="$(bootstrap_settings_get "$tmp" "$i.name" raw 2>/dev/null)" || name="mode $((i + 1))"
    name="$(printf '%s' "$name" | /usr/bin/tr -d '\n\r')"
    en="$(bootstrap_settings_get "$tmp" "$i.isEnabled" raw 2>/dev/null)" || en=true
    enh="$(bootstrap_settings_get "$tmp" "$i.isAIEnhancementEnabled" raw 2>/dev/null)" || enh=true
    i=$((i + 1))
    [ "$en" = false ] && continue
    [ "$enh" = false ] && continue
    on=$((on + 1))
    prov="$(bootstrap_settings_get "$tmp" "$((i - 1)).selectedAIProvider" raw 2>/dev/null)" || prov=""
    model="$(bootstrap_settings_get "$tmp" "$((i - 1)).selectedAIModel" raw 2>/dev/null)" || model=""
    if [ "$prov" = Ollama ]; then
      case "$model" in "$REWRITE_MODEL_NAME"|"$REWRITE_MODEL_NAME:latest") continue ;; esac
    fi
    bad="$bad${bad:+; }\"$name\" uses ${prov:-no provider (so the first connected one, cloud first)}${model:+ / $model}"
  done
  /bin/rm -f "$tmp"
  if [ "$on" -eq 0 ]; then printf 'no enabled VoiceInk mode has AI enhancement on, so the local model is never called'; return 1; fi
  if [ -n "$bad" ]; then printf '%s' "$bad"; return 1; fi
  url="$(rewrite_model_preference ollamaBaseURL)" || url=""
  if [ -n "$url" ] && ! rewrite_model_is_loopback "$(rewrite_model_url_host "$url")"; then
    printf 'VoiceInk'"'"'s Ollama URL is %s, which is not this Mac' "$url"; return 1
  fi
  return 0
}

# ── ollama's cloud switch ─────────────────────────────────────────────────────────────────────
rewrite_model_server_json() { printf '%s/.ollama/server.json' "$HOME"; }

# rewrite_model_cloud_off_write — {"disable_ollama_cloud": true} into the server's own config, through the
# one JSON writer. What was there before is recorded ONCE, so uninstall_ can put it back rather than
# switching off a setting the person made themselves.
rewrite_model_cloud_off_write() {
  local f prev v
  f="$(rewrite_model_server_json)"
  prev="$(rewrite_model_state rewrite-model-server-json.prev)"
  if [ ! -f "$prev" ]; then
    if [ ! -f "$f" ]; then v=no-file
    else v="$(bootstrap_settings_get "$f" disable_ollama_cloud raw 2>/dev/null)" || v=no-key
    fi
    printf '%s\n' "$v" >"$prev" 2>/dev/null || true
  fi
  bootstrap_settings_merge "$f" disable_ollama_cloud true
}

# ── the server this module starts: a user LaunchAgent, never `nohup … &` ──────────────────────
rewrite_model_agent_plist() { printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$REWRITE_MODEL_AGENT_LABEL"; }
rewrite_model_uid() { /usr/bin/id -u 2>/dev/null; }
rewrite_model_label_loaded() { "$REWRITE_MODEL_LAUNCHCTL" print "gui/$(rewrite_model_uid)/$1" >/dev/null 2>&1; }

# rewrite_model_server_label — the loaded launchd job that runs ollama for this user, or rc 1. A server
# with a label is one this module can restart (kickstart -k needs no brew and no admin: the job
# is in this user's own domain); one without — Ollama.app, a hand-run `ollama serve`, a root
# service — is not, and that is a human step.
rewrite_model_server_label() {
  local l
  for l in $REWRITE_MODEL_SERVER_LABELS; do
    rewrite_model_label_loaded "$l" && { printf '%s' "$l"; return 0; }
  done
  return 1
}

# rewrite_model_brew_service_on — Homebrew's own ollama service is registered and not stopped, read
# from `brew services list`, whose rows are `<name> <status> <user> <file>`; `none` and `stopped` are
# the two statuses under which nothing runs at login.
rewrite_model_brew_service_on() {
  local b
  b="$(rewrite_model_brew)" || return 1
  bootstrap_brew "$b" services list 2>/dev/null | /usr/bin/awk '$1 == "ollama" && $2 != "none" && $2 != "stopped" { f = 1 } END { exit !f }'
}

rewrite_model_xml_escape() { printf '%s' "$1" | /usr/bin/sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# rewrite_model_agent_render <ollama> — the LaunchAgent, as text. Bound to 127.0.0.1 on the base URL's port,
# cloud off in its environment, and the two variables the Homebrew service sets, so a server
# started here has the resident footprint the tier rule was MEASURED under (flash attention and a
# q8_0 KV cache; the engine's own defaults differ).
rewrite_model_agent_render() {
  local bin log
  bin="$(rewrite_model_xml_escape "$1")"
  log="$(rewrite_model_xml_escape "$(rewrite_model_state ollama-serve.log)")"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$REWRITE_MODEL_AGENT_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$bin</string>
		<string>serve</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>OLLAMA_HOST</key>
		<string>127.0.0.1:$(rewrite_model_url_port "$REWRITE_MODEL_URL")</string>
		<key>OLLAMA_NO_CLOUD</key>
		<string>1</string>
		<key>OLLAMA_FLASH_ATTENTION</key>
		<string>1</string>
		<key>OLLAMA_KV_CACHE_TYPE</key>
		<string>q8_0</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$log</string>
	<key>StandardErrorPath</key>
	<string>$log</string>
</dict>
</plist>
EOF
}

# rewrite_model_agent_start <ollama> — write the agent (only when its text would change) and have launchd
# run it. rc 0 when launchd holds the job afterwards; the SERVER answering is checked by the caller.
rewrite_model_agent_start() {
  local plist uid changed=0
  plist="$(rewrite_model_agent_plist)"
  uid="$(rewrite_model_uid)"
  /bin/mkdir -p "$(/usr/bin/dirname "$plist")" 2>/dev/null || return 1
  rewrite_model_agent_render "$1" >"$plist.tmp.$$" 2>/dev/null || { /bin/rm -f "$plist.tmp.$$"; return 1; }
  /usr/bin/plutil -lint "$plist.tmp.$$" >/dev/null 2>&1 || { /bin/rm -f "$plist.tmp.$$"; bootstrap_warn "rewrite_model: the LaunchAgent did not render as a valid plist"; return 1; }
  if /usr/bin/cmp -s "$plist.tmp.$$" "$plist" 2>/dev/null; then /bin/rm -f "$plist.tmp.$$"
  else /bin/mv -f "$plist.tmp.$$" "$plist" || return 1; changed=1
  fi
  if rewrite_model_label_loaded "$REWRITE_MODEL_AGENT_LABEL"; then
    [ "$changed" = 1 ] || return 0
    "$REWRITE_MODEL_LAUNCHCTL" bootout "gui/$uid/$REWRITE_MODEL_AGENT_LABEL" >/dev/null 2>&1 || true
  fi
  "$REWRITE_MODEL_LAUNCHCTL" bootstrap "gui/$uid" "$plist" >/dev/null 2>&1 || true
  rewrite_model_label_loaded "$REWRITE_MODEL_AGENT_LABEL"
}

# ── the pinned fetch ──────────────────────────────────────────────────────────────────────────
rewrite_model_pinned_dir() { printf '%s/ollama-%s' "$(bootstrap_tools_dir)" "$REWRITE_MODEL_OLLAMA_VERSION"; }

# rewrite_model_fetch_marker — a pinned fetch that failed IN THIS RUN. It holds the driver's pid ($$ in a
# verb's subshell is the driver's), so gate_ reports the failure for the rest of this run and a
# later run retries the download instead of inheriting a stale refusal.
rewrite_model_fetch_marker() { rewrite_model_state rewrite-model-fetch-failed; }
rewrite_model_fetch_failed_now() {
  local f
  f="$(rewrite_model_fetch_marker)"
  [ -f "$f" ] || return 1
  [ "$(/usr/bin/sed -n 's/^pid=//p' "$f" 2>/dev/null | /usr/bin/head -1)" = "$$" ]
}
rewrite_model_fetch_field() { /usr/bin/sed -n "s/^$1=//p" "$(rewrite_model_fetch_marker)" 2>/dev/null | /usr/bin/head -1; }

# rewrite_model_exec_refused <rc> — the exit status of running a binary that this Mac REFUSED TO EXECUTE,
# as opposed to one that ran and failed: 126 is execve refused (Santa and other binary-authorization
# tools answer EPERM), 137 is SIGKILL at exec, which is how the kernel's code-signing enforcement
# answers (measured: a malformed Mach-O comes back 137 with no output). Anything else ran.
rewrite_model_exec_refused() { [ "${1:-}" = 126 ] || [ "${1:-}" = 137 ]; }

# rewrite_model_signer <file> — who signed it, in the terms an allowlist rule is written in (Santa's
# rules are TEAMID, SIGNINGID, CERTIFICATE, BINARY and CDHASH): its Team ID when it has one, else its
# cdhash, else its SHA-256. codesign reads the file — through a symlink, measured on Homebrew's link —
# and never executes it, so a refused binary still answers. CDHash is printed only at -dvvv.
rewrite_model_signer() {
  local out v
  out="$(/usr/bin/codesign -dvvv "${1:-}" 2>&1)" || out=""
  v="$(printf '%s\n' "$out" | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/head -1)"
  case "$v" in ''|'not set') : ;; *) printf 'Developer ID team %s' "$v"; return 0 ;; esac
  v="$(printf '%s\n' "$out" | /usr/bin/sed -n 's/^CDHash=//p' | /usr/bin/head -1)"
  [ -n "$v" ] && { printf 'the binary with cdhash %s (it has no Team ID)' "$v"; return 0; }
  v="$(/usr/bin/shasum -a 256 "${1:-}" 2>/dev/null)" || v=""
  printf 'the binary with SHA-256 %s (it is not signed)' "${v%% *}"
}

# rewrite_model_mark_refused <ollama> <how it got here> — record, for the rest of this run, that this Mac
# will not execute that ollama, so gate_ reports REFUSED — NEEDS_HUMAN naming what IT must allow — and
# never FAILED. The file is kept: once IT allows it, the next run uses it without a download.
rewrite_model_mark_refused() {
  printf 'pid=%s\nrc=4\nhow=%s\npath=%s\nsigner=%s\n' "$$" "$2" "$1" "$(rewrite_model_signer "$1")" \
    >"$(rewrite_model_fetch_marker)" 2>/dev/null
}

# rewrite_model_fetch_ollama — the tarball, hash-checked BEFORE extraction by bootstrap_fetch_pinned,
# unpacked beside a temp name and moved into place whole, then linked into $(bootstrap_tools_dir)/bin.
# rc 0 the pinned ollama runs · 1 not fetched · 2 hash refused · 3 fetched but will not unpack or run
# · 4 fetched and hash-checked, but this Mac refuses to execute it (binary authorization).
rewrite_model_fetch_ollama() {
  local dir tgz rc out
  dir="$(rewrite_model_pinned_dir)"
  tgz="$(bootstrap_tools_dir)/ollama-$REWRITE_MODEL_OLLAMA_VERSION-darwin.tgz"
  /bin/rm -f "$(rewrite_model_fetch_marker)" 2>/dev/null
  if [ ! -x "$dir/ollama" ]; then
    printf 'rewrite_model: fetching ollama %s from its GitHub release (pinned by sha256; no Homebrew, no admin)\n' "$REWRITE_MODEL_OLLAMA_VERSION"
    bootstrap_fetch_pinned "$REWRITE_MODEL_OLLAMA_TARBALL" "$REWRITE_MODEL_OLLAMA_SHA256" "$tgz"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      printf 'pid=%s\nrc=%s\n' "$$" "$rc" >"$(rewrite_model_fetch_marker)" 2>/dev/null
      return "$rc"
    fi
    /bin/rm -rf "$dir.part" 2>/dev/null
    /bin/mkdir -p "$dir.part" || return 3
    if ! /usr/bin/tar -xzf "$tgz" -C "$dir.part" 2>/dev/null || [ ! -x "$dir.part/ollama" ]; then
      /bin/rm -rf "$dir.part" "$tgz"
      printf 'pid=%s\nrc=3\n' "$$" >"$(rewrite_model_fetch_marker)" 2>/dev/null
      return 3
    fi
    /bin/rm -rf "$dir" 2>/dev/null
    /bin/mv "$dir.part" "$dir" || return 3
    /bin/rm -f "$tgz"
  fi
  /bin/mkdir -p "$(bootstrap_tools_dir)/bin" || return 3
  /bin/ln -sfn "../ollama-$REWRITE_MODEL_OLLAMA_VERSION/ollama" "$(bootstrap_tools_dir)/bin/ollama" || return 3
  # Executed, not assumed. OLLAMA_HOST at a dead loopback port: the version line must come from THIS
  # binary, not from whatever server happens to be answering on 11434.
  out="$(OLLAMA_HOST=127.0.0.1:9 "$(bootstrap_tools_dir)/bin/ollama" --version 2>&1)"; rc=$?
  case "$out" in
    *"$REWRITE_MODEL_OLLAMA_VERSION"*) return 0 ;;
  esac
  if rewrite_model_exec_refused "$rc"; then
    rewrite_model_mark_refused "$(bootstrap_tools_dir)/bin/ollama" "downloaded from its GitHub release and its sha256 checked"
    return 4
  fi
  printf 'pid=%s\nrc=3\n' "$$" >"$(rewrite_model_fetch_marker)" 2>/dev/null
  return 3
}

# ── the gate receipt: a PASS bound to the bytes that passed ──────────────────────────────────
rewrite_model_receipt_digest() {
  local f d
  f="$(rewrite_model_state rewrite-model-gate.receipt)"
  [ -f "$f" ] || return 1
  d="$(sed -n 's/^digest=//p' "$f" 2>/dev/null | head -1)"
  [ -n "$d" ] || return 1
  printf '%s' "$d"
}
rewrite_model_receipt_base() {
  local f b
  f="$(rewrite_model_state rewrite-model-gate.receipt)"
  [ -f "$f" ] || return 1
  b="$(sed -n 's/^base=//p' "$f" 2>/dev/null | head -1)"
  [ -n "$b" ] || return 1
  printf '%s' "$b"
}

# rewrite_model_asset <name> — the shipped asset's absolute path, from the tree the driver verified
# against the release's sha256 manifest and exported as BOOTSTRAP_ASSETS. There is no fallback
# fetch: the raw-URL download this used to make was the one byte stream here nobody checked.
rewrite_model_asset() {
  if [ -n "${BOOTSTRAP_ASSETS:-}" ] && [ -r "$BOOTSTRAP_ASSETS/$1" ]; then printf '%s' "$BOOTSTRAP_ASSETS/$1"; return 0; fi
  return 1
}

# rewrite_model_machine_ready — everything this SCRIPT can bring about, with no human in the loop. The gate
# verbs below key on it so that a human gesture is only ever reported once it is the ONLY thing
# left; reporting it earlier would stop install_ from ever running, and the model would never be
# pulled at all.
rewrite_model_machine_ready() {
  local show dg rg
  rewrite_model_ollama >/dev/null 2>&1 || return 1
  rewrite_model_server_up || return 1
  show="$(rewrite_model_state rewrite-model-cache-show.json)"
  rewrite_model_show "$REWRITE_MODEL_NAME" "$show" || return 1
  rewrite_model_params_ok "$show" || return 1
  dg="$(rewrite_model_digest "$REWRITE_MODEL_NAME")" || return 1
  rg="$(rewrite_model_receipt_digest)" || return 1
  [ "$dg" = "$rg" ] || return 1
  # A derived model built FROM a cloud base renders its parameters locally and passes params_ok
  # (measured in the research), so only its remote_host tells it apart.
  rewrite_model_remote_model "$REWRITE_MODEL_NAME" && return 1
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# THE SIX VERBS
# ═════════════════════════════════════════════════════════════════════════════════════════════

# ── catalog metadata (optional verbs; see CONTRACT.md) ────────────────────────────────────────
# what_ and cost_ name the ROUTE, because it is what a standard user most needs to know before
# choosing this: whether it will ask for Homebrew, which they cannot install.
what_rewrite_model() {
  case "$(rewrite_model_route 2>/dev/null)" in
    brew)          printf '%s' 'a LOCAL speech-rewrite model, so dictation cleanup needs no cloud API key — ollama via Homebrew' ;;
    pinned|oldmac) printf '%s' 'a LOCAL speech-rewrite model, so dictation cleanup needs no cloud API key — ollama from its pinned GitHub release, into your home folder, with no admin rights needed' ;;
    *)             printf '%s' 'a LOCAL speech-rewrite model, so dictation cleanup needs no cloud API key — on the ollama already installed' ;;
  esac
}
cost_rewrite_model() {
  local server
  server="An ollama server stays running from login, listening on 127.0.0.1:$(rewrite_model_url_port "$REWRITE_MODEL_URL")."
  case "$(rewrite_model_route 2>/dev/null)" in
    brew)          printf '%s' "Homebrew's ollama + a ~5 GB model download. Several minutes. $server One pass through VoiceInk's modes at the end." ;;
    pinned|oldmac) printf '%s' "a pinned 160 MB ollama download + a ~5 GB model download. Several minutes. $server One pass through VoiceInk's modes at the end." ;;
    *)             printf '%s' "a ~5 GB model download. Several minutes. $server One pass through VoiceInk's modes at the end." ;;
  esac
}
profile_rewrite_model() { printf '%s' 'standard'; }

# Every host this module reaches. The route decides which install hosts apply, so both are listed
# with the route named. ollama.com is absent on purpose: every server this module starts runs with
# OLLAMA_NO_CLOUD=1, and verify_ fails unless the server's own /api/status says cloud is disabled —
# so the one way ollama.com is reached is a server this module did not start and could not switch
# off, and that is reported as NEEDS_HUMAN, never as satisfied.
egress_rewrite_model() {
  printf '%s\n' \
    'github.com install the pinned ollama CLI release tarball, when there is no Homebrew this user can install with' \
    'release-assets.githubusercontent.com install the same tarball, redirected from github.com; kept only if its sha256 matches the pin' \
    'formulae.brew.sh install brew install ollama, when this user has a usable Homebrew (formula API and auto-update)' \
    'ghcr.io install the ollama bottle manifest, Homebrew route only' \
    'pkg-containers.githubusercontent.com install the ollama bottle download, Homebrew route only' \
    'registry.ollama.ai install ollama pull of the base model (model name and your IP, never a prompt)' \
    'dd20bb891979d25aebc8bec07b2b3bbc.r2.cloudflarestorage.com install the model blobs registry.ollama.ai redirects to'
}

# What a company's IT or security team governs here, one `<class> <clause>` per line. The server is
# named whatever the route, because either route leaves one running; the software line appears only
# when this run would install ollama rather than use the one already on disk.
clearance_rewrite_model() {
  printf 'background a local ollama server that starts at login, stays running and listens on 127.0.0.1:%s — the LaunchAgent %s, or Homebrew'"'"'s own ollama service (`brew services start ollama`) when your Homebrew runs ollama; uninstall stops the first and leaves Homebrew'"'"'s running\n' \
    "$(rewrite_model_url_port "$REWRITE_MODEL_URL")" "$REWRITE_MODEL_AGENT_LABEL"
  case "$(rewrite_model_route 2>/dev/null)" in
    pinned|oldmac) printf 'software the ollama server and its libraries from ollama'"'"'s GitHub release (Developer ID team 3MU9H2V9Y9), unpacked into the hidden folder ~/.mac-bootstrap/tools, where Gatekeeper never assesses it — not distributed by IT\n' ;;
    brew)          printf 'software Homebrew'"'"'s ollama build, which is ad-hoc signed with no Team ID — not distributed by IT\n' ;;
  esac
}

# rewrite_model_local_only — the second, independent reader of VoiceInk: assets/local-only-check.sh
# decides, from every key store, every enabled mode and every cloud transcription model, whether
# VoiceInk can still reach a cloud service. The per-mode proof above cannot see a SAVED cloud key,
# which wins the fork build's fallback on the first Ollama outage, nor a cloud transcription model.
# Executed, never sourced. Prints its FAIL lines (names only, never a key); rc 0 = VoiceInk is local.
rewrite_model_local_only() {
  local c="${BOOTSTRAP_ASSETS:-}/local-only-check.sh"
  if [ ! -r "$c" ]; then printf '    FAIL  assets/local-only-check.sh is missing, so VoiceInk cannot be shown to be local\n'; return 1; fi
  if [ -n "${BOOTSTRAP_REWRITE_MODEL_DOMAIN:-}" ]; then
    LOCAL_ONLY_VOICEINK_DOMAIN="${BOOTSTRAP_REWRITE_MODEL_DOMAIN%.plist}" /bin/bash "$c" --only voiceink --quiet 2>/dev/null
  else
    /bin/bash "$c" --only voiceink --quiet 2>/dev/null
  fi
}

verify_rewrite_model() {
  # The defaults domain is resolved from the password database, not from $HOME, so a sandboxed
  # HOME would silently rewrite the REAL machine. Refuse instead. (bootstrap-lib.sh: bootstrap_defaults_home_ok)
  bootstrap_defaults_home_ok || return 1
  local show want got t
  rewrite_model_url_ok || return 1
  rewrite_model_machine_ready || return 1
  rewrite_model_cloud_disabled || return 1

  # The base is checked against the RECEIPT, not against a re-derivation of the tier rule: a
  # machine the operator deliberately pointed at another base with --model must keep verifying.
  # An explicit --model on THIS run, though, is a new instruction and must not read as satisfied.
  show="$(rewrite_model_state rewrite-model-cache-show.json)"
  got="$(rewrite_model_json_field "$show" details.parent_model)" || got=""
  want="$(rewrite_model_receipt_base)" || want=""
  [ -n "$got" ] && [ -n "$want" ] && [ "$got" = "$want" ] || return 1
  if [ -n "${BOOTSTRAP_MODEL:-${BOOTSTRAP_MODEL:-}}" ] && [ "${BOOTSTRAP_MODEL:-${BOOTSTRAP_MODEL:-}}" != "$got" ]; then
    return 1
  fi

  t="$(rewrite_model_preference EnhancementTimeoutSeconds)" || return 1
  [ "$t" = "$REWRITE_MODEL_TIMEOUT_S" ] || return 1

  # The GUI evidence, per mode. rewrite_model never writes a mode, so this can only have come from
  # a human in VoiceInk — and it is the setting that decides which provider each dictation reaches.
  rewrite_model_modes_pinned >/dev/null 2>&1 || return 1
  rewrite_model_local_only >/dev/null 2>&1 || return 1

  # An optional live re-measurement. Off by default because it costs a model load, and the
  # receipt is already bound to the digest; on when you want the end-to-end answer rather than
  # the recorded one.
  if [ -n "${BOOTSTRAP_REWRITE_MODEL_VERIFY_INFERENCE:-}" ]; then
    local g
    g="$(rewrite_model_asset model-gate.sh)" || return 1
    BOOTSTRAP_MODEL="$REWRITE_MODEL_NAME" MODEL_GATE_BASE_URL="$REWRITE_MODEL_URL" /bin/bash "$g" --runs 1 >/dev/null 2>&1 || return 1
  fi
  return 0
}

# rewrite_model_pending — THE ONE BRANCH DECISION, so gate_, note_ and gesture_ cannot contradict each
# other. They did, in the first run of this module: the note said "quit VoiceInk" while the
# gesture printed `open -a VoiceInk`, which is the silver-platter defect in its purest form —
# two lines of one hand-off telling the operator opposite things. One function, three readers.
#
# Prints exactly one token:
#   FETCH     the pinned ollama download failed IN THIS RUN, and there is no Homebrew route
#   OLDMAC    no Homebrew route, and this macOS is below the pinned build's floor
#   DECIDE    below the measured floor: bench a candidate, or leave AI enhancement off
#   CLOUD     a server this module cannot restart still has cloud on; server.json already says off
#   QUIT      a running VoiceInk discards `defaults write` on exit, so the timeout cannot land
#   GUI       the machine side is done; only choosing Ollama + the model on each mode remains
#   NONE      nothing is waiting on a human
#
# QUIT and GUI are deliberately gated on rewrite_model_machine_ready. Reporting a human gesture BEFORE
# the machine side is reachable would stop install_ from ever running (the driver takes the
# NEEDS_HUMAN branch and never calls it), and the model would never be pulled at all. For the same
# reason CLOUD waits until server.json already asks for cloud off, and only for a server with no
# launchd label this module can kickstart: before that, install_ must run to write the file or do
# the restart itself.
rewrite_model_pending() {
  local t
  if rewrite_model_fetch_failed_now && [ "$(rewrite_model_fetch_field rc)" = 4 ]; then printf 'REFUSED'; return 0; fi
  if ! rewrite_model_ollama >/dev/null 2>&1; then
    rewrite_model_fetch_failed_now && { printf 'FETCH'; return 0; }
    [ "$(rewrite_model_route)" = oldmac ] && { printf 'OLDMAC'; return 0; }
  fi
  if [ -z "$(rewrite_model_base)" ]; then printf 'DECIDE'; return 0; fi
  if [ "$(bootstrap_settings_get "$(rewrite_model_server_json)" disable_ollama_cloud raw 2>/dev/null)" = true ] \
     && rewrite_model_server_up && ! rewrite_model_cloud_disabled && ! rewrite_model_server_label >/dev/null 2>&1; then
    printf 'CLOUD'; return 0
  fi
  if rewrite_model_machine_ready; then
    t="$(rewrite_model_preference EnhancementTimeoutSeconds)" || t=""
    if [ "$t" != "$REWRITE_MODEL_TIMEOUT_S" ] && rewrite_model_voiceink_running; then printf 'QUIT'; return 0; fi
    rewrite_model_modes_pinned >/dev/null 2>&1 || { printf 'GUI'; return 0; }
    rewrite_model_local_only >/dev/null 2>&1 || { printf 'GUI'; return 0; }
  fi
  printf 'NONE'
  return 0
}

# rewrite_model_fetch_why — the marker's rc, in words. A TLS-inspecting proxy that re-signs downloads
# shows up as the hash refusal, which is why that one names the proxy.
rewrite_model_fetch_why() {
  case "$(/usr/bin/sed -n 's/^rc=//p' "$(rewrite_model_fetch_marker)" 2>/dev/null | /usr/bin/head -1)" in
    2) printf 'it did not match the sha256 this release pins, so it was deleted unrun — a proxy that rewrites downloads does this' ;;
    3) printf 'it downloaded but would not unpack or run' ;;
    4) printf 'it was %s, but this Mac refused to execute it — binary authorization such as Santa blocks software IT has not allowed; the one to allow is %s' \
         "$(rewrite_model_fetch_field how)" "$(rewrite_model_fetch_field signer)" ;;
    *) printf 'it could not be downloaded — no network, or a proxy that blocks github.com' ;;
  esac
}

gate_rewrite_model() {
  # A sandboxed HOME is a DECISION, not a bug: `defaults` would escape it and hit the real
  # domain, so bootstrap_defaults_home_ok refuses. Reported through gate_ so it reads NEEDS_HUMAN
  # rather than FAILED — FAILED sends the reader to the log for a defect that is not there.
  bootstrap_defaults_home_ok >/dev/null 2>&1 || return 0
  [ "$(rewrite_model_pending)" = NONE ] && return 1
  return 0
}

note_rewrite_model() {
  if ! bootstrap_defaults_home_ok >/dev/null 2>&1; then
    printf 'this run has a sandboxed HOME ($HOME is not your real home), and `defaults` ignores $HOME — writing would hit your REAL preferences. Nothing was written.'
    return 0
  fi
  local why lo
  case "$(rewrite_model_pending)" in
    FETCH)
      if bootstrap_is_admin && ! rewrite_model_brew >/dev/null 2>&1; then
        printf 'The pinned ollama download from github.com failed (%s). Homebrew is the other route, and its installer needs your password.\n' "$(rewrite_model_fetch_why)"
      else
        printf 'The pinned ollama download from github.com failed (%s). This account cannot install Homebrew, so ask IT to allow downloads from github.com and release-assets.githubusercontent.com (or to install ollama), then run this again.\n' "$(rewrite_model_fetch_why)"
      fi ;;
    REFUSED)
      printf 'This Mac refused to execute ollama (%s), which was %s — binary authorization such as Santa blocks software IT has not allowed. Ask IT to allow %s, then run this again.\n' \
        "$(rewrite_model_fetch_field path)" "$(rewrite_model_fetch_field how)" "$(rewrite_model_fetch_field signer)" ;;
    OLDMAC)
      printf 'This Mac runs macOS %s, and the ollama build this installs needs macOS %s or later; Homebrew, the other route, is not available to this account. Update macOS (or ask IT to), then run this again.\n' "$(/usr/bin/sw_vers -productVersion 2>/dev/null)" "$REWRITE_MODEL_OLLAMA_MACOS_FLOOR" ;;
    DECIDE)
      printf 'This Mac reports %s GB of unified memory, and no local rewrite model is measured good at that size — bench a candidate (qwen3.5:4b, 3.4 GB, is the untested one worth trying) or leave VoiceInk AI enhancement off rather than installing a model that invents text.\n' "$(rewrite_model_mem_gb)" ;;
    CLOUD)
      if rewrite_model_ollama_app_running; then
        printf 'The Ollama app runs the server at %s and still has cloud models enabled, so a model name ending in :cloud sends its prompt to ollama.com. ~/.ollama/server.json now switches cloud off, but the server reads it only when it starts — quit and reopen Ollama.\n' "$REWRITE_MODEL_URL"
      else
        printf 'The ollama server at %s was not started by this bootstrap and still has cloud models enabled, so a model name ending in :cloud sends its prompt to ollama.com. ~/.ollama/server.json now switches cloud off, but the server reads it only when it starts — stop that server and start it again (a server run by root reads /var/root/.ollama/server.json instead, which only an administrator can change).\n' "$REWRITE_MODEL_URL"
      fi ;;
    QUIT)
      printf 'VoiceInk is running and it rewrites its own preferences when it quits, so the %s-second enhancement timeout cannot be written underneath it — quit VoiceInk and run this again.\n' "$REWRITE_MODEL_TIMEOUT_S" ;;
    GUI)
      why="$(rewrite_model_modes_pinned 2>/dev/null)"
      # What the independent check found, joined onto this one line: names only, never a key.
      lo="$(rewrite_model_local_only | sed 's/^ *FAIL *//' | tr '\n' ';' | sed 's/;$//')"
      [ -n "$lo" ] && why="${why:+$why; }$lo"
      printf 'In VoiceInk, Settings > Modes: for every mode with AI enhancement on, choose provider Ollama and model %s — a mode that names a cloud provider sends your dictation there (%s). While you are in Settings > Transcription, download parakeet-unified-0.6b from its model card and select it — it is faster, more accurate and lighter than the whisper turbo default, and it punctuates its own output, which is work the rewrite model then does not have to do.\n' "$REWRITE_MODEL_NAME" "${why:-the modes could not be read}" ;;
    *)
      printf 'nothing is waiting on you for the local rewrite model.\n' ;;
  esac
  return 0
}

rewrite_model_ollama_app_running() { "$REWRITE_MODEL_PGREP" -x Ollama >/dev/null 2>&1; }

gesture_rewrite_model() {
  if ! bootstrap_defaults_home_ok >/dev/null 2>&1; then
    printf 'run it from your own account (no HOME override), or set BOOTSTRAP_ALLOW_FOREIGN_DEFAULTS=1 if you truly mean to write the real domain'
    return 0
  fi
  local root
  case "$(rewrite_model_pending)" in
    FETCH)
      # Homebrew only for an administrator, who can run its installer; everyone else gets the note.
      if bootstrap_is_admin && ! rewrite_model_brew >/dev/null 2>&1; then
        printf '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"\n'
      fi ;;
    OLDMAC)
      printf 'open "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"\n' ;;
    CLOUD)
      rewrite_model_ollama_app_running && printf 'osascript -e '"'"'quit app "Ollama"'"'"' && sleep 3 && open -a Ollama\n' ;;
    DECIDE)
      if [ -n "${BOOTSTRAP_ASSETS:-}" ]; then
        root="$(dirname "$BOOTSTRAP_ASSETS")"
        [ -r "$root/bootstrap.sh" ] && { printf 'bash %s/bootstrap.sh --only rewrite_model --bench qwen3.5:4b\n' "$root"; return 0; }
      fi
      printf 'bash bootstrap.sh --only rewrite_model --bench qwen3.5:4b\n' ;;
    QUIT)
      printf 'osascript -e '"'"'quit app "VoiceInk"'"'"'\n' ;;
    GUI)
      # A GUI toggle with no CLI: the one command that puts them in front of it. Never a bare
      # path or an app name alone — what goes under a "run this" marker is executed as typed.
      printf 'open -a VoiceInk\n' ;;
  esac
  return 0
}

install_rewrite_model() {
  # The defaults domain is resolved from the password database, not from $HOME, so a sandboxed
  # HOME would silently rewrite the REAL machine. Refuse instead. (bootstrap-lib.sh: bootstrap_defaults_home_ok)
  bootstrap_defaults_home_ok || return 1
  local base ollama brew mf rendered show dg g rc t prev label why how

  # Nothing below may send a request anywhere but this Mac.
  if ! rewrite_model_url_ok; then
    bootstrap_warn "rewrite_model: refusing MODEL_GATE_BASE_URL=$REWRITE_MODEL_URL — it is not a loopback address, and every request here (fixture prompts included) would go to that host"
    return 2
  fi

  base="$(rewrite_model_base)"
  if [ -z "$base" ]; then
    bootstrap_warn "rewrite_model: $(rewrite_model_mem_gb) GB of unified memory and no measured model at that size — refusing to guess. Run --bench."
    return 2
  fi
  # A model tag goes into a sed replacement and into a shell word below. ollama tags are
  # [name]:[tag] over letters, digits, . _ - and /, so anything else is not a tag we should be
  # handing to sed — where `&` means "the matched text" and `|` would end the s-command.
  case "$base" in
    *[!A-Za-z0-9._:/-]*)
      bootstrap_warn "rewrite_model: refusing base '$base' — that is not a well-formed ollama model tag"
      return 2 ;;
  esac
  if rewrite_model_cloud_ref "$base"; then
    bootstrap_warn "rewrite_model: refusing base '$base' — it is an ollama CLOUD model, whose every generation is sent to ollama.com. Nothing was requested."
    return 2
  fi
  if rewrite_model_forbidden "$base"; then
    bootstrap_warn "rewrite_model: refusing base '$base'. Measured 82-156 s per call and untagged prose reasoning that VoiceInk's <think> filter cannot strip, so the reasoning is pasted into the document. Use --bench to re-measure it if you want to challenge that."
    return 2
  fi

  # 1. ollama ─────────────────────────────────────────────────────────────────────────────────
  how='already on this Mac'
  case "$(rewrite_model_route)" in
    present) : ;;
    brew)
      how='installed by Homebrew'
      brew="$(rewrite_model_brew)"
      printf 'rewrite_model: installing ollama via Homebrew\n'
      bootstrap_brew "$brew" install ollama || bootstrap_warn "rewrite_model: brew install ollama exited non-zero; checking anyway" ;;
    pinned)
      rewrite_model_fetch_ollama
      rc=$?
      if [ "$rc" -ne 0 ]; then
        # Non-zero is the contract's own path back to gate_, which now reports FETCH for this run.
        bootstrap_warn "rewrite_model: the pinned ollama $REWRITE_MODEL_OLLAMA_VERSION could not be installed (rc $rc): $(rewrite_model_fetch_why)"
        return 2
      fi ;;
    oldmac)
      bootstrap_warn "rewrite_model: macOS $(/usr/bin/sw_vers -productVersion 2>/dev/null) is below the pinned ollama's floor ($REWRITE_MODEL_OLLAMA_MACOS_FLOOR), and there is no Homebrew this user can install with"
      return 2 ;;
  esac
  ollama="$(rewrite_model_ollama)" || { bootstrap_warn "rewrite_model: ollama is still not on disk after installing it"; return 2; }
  # Executed, not assumed: an installer's exit code is never the verdict. A Mac that refuses to
  # EXECUTE it (Santa, or another binary-authorization tool) is recorded for gate_, which reports
  # NEEDS_HUMAN naming what IT must allow — not FAILED, which would blame a defect that is not there.
  "$ollama" --version >/dev/null 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then
    if rewrite_model_exec_refused "$rc"; then
      rewrite_model_mark_refused "$ollama" "$how"
      bootstrap_warn "rewrite_model: this Mac refuses to execute $ollama ($(rewrite_model_fetch_why))"
    else
      bootstrap_warn "rewrite_model: $ollama will not run"
    fi
    return 2
  fi

  # 2. cloud off, BEFORE any server starts — a server reads server.json only when it starts, so a
  #    first start after this line never needs a restart.
  rewrite_model_cloud_off_write || { bootstrap_warn "rewrite_model: could not write disable_ollama_cloud into $(rewrite_model_server_json)"; return 2; }

  # 3. the server ─────────────────────────────────────────────────────────────────────────────
  # Homebrew's service when Homebrew is this user's and runs its ollama; otherwise this module's
  # own LaunchAgent, which carries OLLAMA_NO_CLOUD=1 and survives logout (the `nohup … &` it
  # replaces did neither).
  if ! rewrite_model_server_up; then
    if rewrite_model_brew_usable && [ "$(/usr/bin/dirname "$ollama")" = "$(/usr/bin/dirname "$(rewrite_model_brew)")" ]; then
      printf 'rewrite_model: starting the Homebrew ollama service\n'
      bootstrap_brew "$(rewrite_model_brew)" services start ollama >/dev/null 2>&1 || true
      rewrite_model_wait_up 30 || true
    fi
    if ! rewrite_model_server_up; then
      printf 'rewrite_model: starting ollama as the user LaunchAgent %s (127.0.0.1 only, cloud off)\n' "$REWRITE_MODEL_AGENT_LABEL"
      # The stable path — $(bootstrap_tools_dir)/bin/ollama, or Homebrew's link — not a versioned
      # file, so a later pin or a brew upgrade is picked up at the next start. The pinned binary
      # was measured serving (and finding Metal) through that link.
      rewrite_model_agent_start "$ollama" \
        || bootstrap_warn "rewrite_model: launchd does not hold $REWRITE_MODEL_AGENT_LABEL after bootstrap"
    fi
    rewrite_model_wait_up 90 || true
  fi
  rewrite_model_server_up || { bootstrap_warn "rewrite_model: no ollama server answering at $REWRITE_MODEL_URL"; return 2; }

  # 4. cloud off, READ BACK from the server itself ────────────────────────────────────────────
  if ! rewrite_model_cloud_disabled; then
    if label="$(rewrite_model_server_label)"; then
      printf 'rewrite_model: restarting %s so it reads server.json (it reads it only at start)\n' "$label"
      "$REWRITE_MODEL_LAUNCHCTL" kickstart -k "gui/$(rewrite_model_uid)/$label" >/dev/null 2>&1 || true
      sleep 2
      rewrite_model_wait_up 90 || true
    fi
    if ! rewrite_model_cloud_disabled; then
      bootstrap_warn "rewrite_model: the ollama server at $REWRITE_MODEL_URL still reports cloud enabled (GET /api/status) — refusing to continue with a server that can send prompts to ollama.com"
      return 7
    fi
  fi

  # 5. the base model ─────────────────────────────────────────────────────────────────────────
  if ! rewrite_model_model_present "$base"; then
    printf 'rewrite_model: pulling %s — several GB from registry.ollama.ai\n' "$base"
    "$ollama" pull "$base" || { bootstrap_warn "rewrite_model: ollama pull $base failed"; return 2; }
    rewrite_model_model_present "$base" || { bootstrap_warn "rewrite_model: $base is still absent after the pull"; return 2; }
  fi
  # A name without a cloud suffix can still be a remote-backed model (one `ollama create`d FROM a
  # cloud tag): it is refused before anything is derived from it or any text is sent to it.
  if rewrite_model_remote_model "$base"; then
    bootstrap_warn "rewrite_model: refusing base '$base' — ollama lists it with a remote_host, so its generations run on another machine"
    return 2
  fi

  # 6. the derived model ──────────────────────────────────────────────────────────────────────
  show="$(rewrite_model_state rewrite-model-cache-show.json)"
  if rewrite_model_show "$REWRITE_MODEL_NAME" "$show" && rewrite_model_params_ok "$show" \
     && [ "$(rewrite_model_json_field "$show" details.parent_model 2>/dev/null)" = "$base" ]; then
    printf 'rewrite_model: %s already derives from %s with the right parameters\n' "$REWRITE_MODEL_NAME" "$base"
  else
    mf="$(rewrite_model_asset voiceink-rewrite.Modelfile)" || { bootstrap_warn "rewrite_model: cannot find or fetch assets/voiceink-rewrite.Modelfile"; return 2; }
    rendered="$(rewrite_model_state voiceink-rewrite.Modelfile)"
    # The asset is the single source of the PARAMETER block; only FROM is rewritten, so a tier
    # change cannot silently drift from the parameters that were measured.
    sed "s|^FROM .*|FROM $base|" "$mf" >"$rendered" || { bootstrap_warn "rewrite_model: could not render the Modelfile"; return 2; }
    # Compared as a STRING, not as a regex: a tag like qwen3.5:9b contains a `.`, and
    # `grep "^FROM qwen3.5:9b$"` would happily match FROM qwen3x5:9b.
    [ "$(sed -n 's/^FROM //p' "$rendered" | head -1)" = "$base" ] \
      || { bootstrap_warn "rewrite_model: the rendered Modelfile does not say FROM $base"; return 2; }
    printf 'rewrite_model: creating %s from %s\n' "$REWRITE_MODEL_NAME" "$base"
    "$ollama" create "$REWRITE_MODEL_NAME" -f "$rendered" || { bootstrap_warn "rewrite_model: ollama create $REWRITE_MODEL_NAME failed"; return 2; }
    rewrite_model_show "$REWRITE_MODEL_NAME" "$show" || { bootstrap_warn "rewrite_model: $REWRITE_MODEL_NAME is absent after create"; return 2; }
    rewrite_model_params_ok "$show" || { bootstrap_warn "rewrite_model: $REWRITE_MODEL_NAME exists but the server does not report num_ctx 4096 / temperature 0.2"; return 2; }
  fi
  if rewrite_model_remote_model "$REWRITE_MODEL_NAME"; then
    bootstrap_warn "rewrite_model: $REWRITE_MODEL_NAME is backed by a remote host; removing it rather than sending fixture text to another machine"
    "$ollama" rm "$REWRITE_MODEL_NAME" >/dev/null 2>&1 || true
    return 2
  fi

  # 7. the acceptance gate — BEFORE anything is called done ───────────────────────────────────
  # A model that answers the dictated question instead of rewriting it pastes its answer into
  # whatever the user was typing into. If it fails, it is removed: leaving a certified-bad model
  # under the name VoiceInk will pick is worse than leaving the machine with no local model.
  # Idempotency: a PASS is bound to the model's DIGEST, so if the receipt already names these
  # exact bytes there is nothing new to measure and re-running costs a model load for no
  # information. Anything that changes the model changes the digest and the gate runs again.
  dg="$(rewrite_model_digest "$REWRITE_MODEL_NAME")" || { bootstrap_warn "rewrite_model: cannot read the digest of $REWRITE_MODEL_NAME"; return 2; }
  if [ "$dg" = "$(rewrite_model_receipt_digest 2>/dev/null)" ]; then
    printf 'rewrite_model: %s is already certified at this digest — the gate is not re-run\n' "$REWRITE_MODEL_NAME"
  else
    g="$(rewrite_model_asset model-gate.sh)" || { bootstrap_warn "rewrite_model: cannot find or fetch assets/model-gate.sh"; return 2; }
    printf 'rewrite_model: running the acceptance gate against %s\n' "$REWRITE_MODEL_NAME"
    BOOTSTRAP_MODEL="$REWRITE_MODEL_NAME" MODEL_GATE_BASE_URL="$REWRITE_MODEL_URL" MODEL_GATE_MAX_MS="$((REWRITE_MODEL_TIMEOUT_S * 1000))" \
      /bin/bash "$g"
    rc=$?
    case "$rc" in
      0) : ;;
      1) bootstrap_warn "rewrite_model: $REWRITE_MODEL_NAME FAILED the acceptance gate; removing it rather than leaving a bad rewrite engine wired up"
         "$ollama" rm "$REWRITE_MODEL_NAME" >/dev/null 2>&1 || true
         rm -f "$(rewrite_model_state rewrite-model-gate.receipt)" 2>/dev/null || true
         return 3 ;;
      *) bootstrap_warn "rewrite_model: the acceptance gate could not run (rc $rc) — nothing was measured, so nothing is certified"
         return 4 ;;
    esac
  fi

  # Written only when it would SAY something different. Re-stamping `at=` on every run would
  # make the second run of an idempotent module diff against the first, which is the very thing
  # house rule 8 asks you to check for.
  if [ "$dg" != "$(rewrite_model_receipt_digest 2>/dev/null)" ] \
     || [ "$base" != "$(rewrite_model_receipt_base 2>/dev/null)" ] \
     || [ "$REWRITE_MODEL_NAME" != "$(sed -n 's/^model=//p' "$(rewrite_model_state rewrite-model-gate.receipt)" 2>/dev/null | head -1)" ]; then
    {
      printf 'digest=%s\n' "$dg"
      printf 'model=%s\n' "$REWRITE_MODEL_NAME"
      printf 'base=%s\n' "$base"
      printf 'at=%s\n' "$(date -u +%FT%TZ)"
    } >"$(rewrite_model_state rewrite-model-gate.receipt)"
  fi

  # 8. the two VoiceInk preferences ───────────────────────────────────────────────────────────
  # Exactly two keys, each written by name. The domain is never exported or copied: it holds live
  # provider API keys. No mode is written — see the header.
  t="$(rewrite_model_preference EnhancementTimeoutSeconds)" || t=""
  if [ "$t" != "$REWRITE_MODEL_TIMEOUT_S" ] && rewrite_model_voiceink_running; then
    bootstrap_warn "rewrite_model: VoiceInk is running; it rewrites its preferences on quit, so the ${REWRITE_MODEL_TIMEOUT_S}s timeout was not written (it currently reads '${t:-absent}')"
  elif rewrite_model_voiceink_running; then
    : # already correct, and a running app is only a problem when something must be written
  else
    if [ "$t" != "$REWRITE_MODEL_TIMEOUT_S" ]; then
      prev="$(rewrite_model_state rewrite-model-timeout.prev)"
      [ -f "$prev" ] || printf '%s\n' "${t:-absent}" >"$prev"    # once, so uninstall can undo it
      "$REWRITE_MODEL_DEFAULTS" write "$REWRITE_MODEL_DOMAIN" EnhancementTimeoutSeconds -int "$REWRITE_MODEL_TIMEOUT_S" 2>/dev/null \
        || bootstrap_warn "rewrite_model: could not write EnhancementTimeoutSeconds"
    fi
    # Harmless and idempotent: it pre-fills the field the human is about to Connect through.
    rewrite_model_preference_exists ollamaBaseURL || "$REWRITE_MODEL_DEFAULTS" write "$REWRITE_MODEL_DOMAIN" ollamaBaseURL -string "$REWRITE_MODEL_URL" 2>/dev/null || true
    t="$(rewrite_model_preference EnhancementTimeoutSeconds)" || t=""
    [ "$t" = "$REWRITE_MODEL_TIMEOUT_S" ] || { bootstrap_warn "rewrite_model: EnhancementTimeoutSeconds reads back as '${t:-absent}'"; return 2; }
  fi

  # 9. the one step no script can take ────────────────────────────────────────────────────────
  # Returning non-zero here is deliberate and is the contract's own path: the driver re-evaluates
  # gate_, which now reports the GUI gesture, and the module is recorded NEEDS_HUMAN with the
  # note and the command. Returning 0 would have the driver call verify_, watch it disagree, and
  # record FAILED — sending the reader to the log for a bug that is not there. The same applies
  # to a preference that could not be written because the app was open: FAILED with "the
  # read-back disagreed" is a true sentence that names the wrong cause.
  t="$(rewrite_model_preference EnhancementTimeoutSeconds)" || t=""
  if [ "$t" != "$REWRITE_MODEL_TIMEOUT_S" ]; then
    printf 'rewrite_model: the %ss enhancement timeout is still unwritten because VoiceInk is open.\n' "$REWRITE_MODEL_TIMEOUT_S"
    return 6
  fi
  if why="$(rewrite_model_modes_pinned)"; then return 0; fi
  printf 'rewrite_model: the machine side is done. Each VoiceInk mode with AI enhancement on must now name Ollama and %s: %s\n' "$REWRITE_MODEL_NAME" "$why"
  return 5
}

uninstall_rewrite_model() {
  local ollama prev
  if ollama="$(rewrite_model_ollama)" && rewrite_model_server_up && rewrite_model_model_present "$REWRITE_MODEL_NAME"; then
    "$ollama" rm "$REWRITE_MODEL_NAME" >/dev/null 2>&1 || bootstrap_warn "rewrite_model: ollama rm $REWRITE_MODEL_NAME failed"
  fi
  # The BASE model is left alone unless asked: re-pulling several GB over someone's network is
  # not a reversal anybody wants by surprise, and other things on the machine may use it.
  if [ -n "${BOOTSTRAP_REWRITE_MODEL_UNINSTALL_BASE:-}" ] && ollama="$(rewrite_model_ollama)"; then
    local b; b="$(rewrite_model_receipt_base)" || b=""
    [ -n "$b" ] && "$ollama" rm "$b" >/dev/null 2>&1 || true
  fi

  prev="$(rewrite_model_state rewrite-model-timeout.prev)"
  if [ -f "$prev" ] && ! rewrite_model_voiceink_running; then
    local v; v="$(head -1 "$prev" 2>/dev/null)"
    if [ "$v" = "absent" ]; then
      "$REWRITE_MODEL_DEFAULTS" delete "$REWRITE_MODEL_DOMAIN" EnhancementTimeoutSeconds 2>/dev/null || true
    else
      case "${v:-}" in
        ''|*[!0-9]*) : ;;
        *) "$REWRITE_MODEL_DEFAULTS" write "$REWRITE_MODEL_DOMAIN" EnhancementTimeoutSeconds -int "$v" 2>/dev/null || true ;;
      esac
    fi
    rm -f "$prev" 2>/dev/null || true
  fi

  rewrite_model_cloud_off_undo

  # The server this module started, and the ollama it unpacked — and nothing else: Homebrew's
  # ollama and its service, the Ollama app, and every model under ~/.ollama are left alone.
  # launchd's gui domain is per USER, not per HOME, so the job is booted out only when THIS home
  # holds its plist — a sandboxed uninstall must never stop the real account's server.
  if [ -f "$(rewrite_model_agent_plist)" ] && rewrite_model_label_loaded "$REWRITE_MODEL_AGENT_LABEL"; then
    "$REWRITE_MODEL_LAUNCHCTL" bootout "gui/$(rewrite_model_uid)/$REWRITE_MODEL_AGENT_LABEL" >/dev/null 2>&1 \
      || bootstrap_warn "rewrite_model: launchctl bootout $REWRITE_MODEL_AGENT_LABEL failed"
  fi
  rm -f "$(rewrite_model_agent_plist)" 2>/dev/null || true
  case "$(/usr/bin/readlink "$(bootstrap_tools_dir)/bin/ollama" 2>/dev/null)" in
    ../ollama-*/ollama) rm -f "$(bootstrap_tools_dir)/bin/ollama" 2>/dev/null || true ;;
  esac
  rm -rf "$(rewrite_model_pinned_dir)" "$(rewrite_model_pinned_dir).part" \
         "$(bootstrap_tools_dir)/ollama-$REWRITE_MODEL_OLLAMA_VERSION-darwin.tgz" "$(bootstrap_tools_dir)/ollama-$REWRITE_MODEL_OLLAMA_VERSION-darwin.tgz.part" 2>/dev/null || true
  rmdir "$(bootstrap_tools_dir)/bin" "$(bootstrap_tools_dir)" 2>/dev/null || true     # only if now empty
  # Homebrew's service is left alone — install_ may have started it, but Homebrew owns it and other
  # things may use it — and a server still listening at login is not something to leave unsaid.
  if rewrite_model_brew_service_on; then
    printf 'rewrite_model: Homebrew'"'"'s own ollama service is still running and starts at login; it was left alone on purpose. To stop it:\n'
    printf 'brew services stop ollama\n'
  fi

  # LAST, not first: every read above (is the model there? what base was it?) re-creates the
  # API caches, so deleting them at the top of the function leaves them behind at the bottom.
  rm -f "$(rewrite_model_state rewrite-model-gate.receipt)" "$(rewrite_model_state voiceink-rewrite.Modelfile)" \
        "$(rewrite_model_state rewrite-model-cache-show.json)" "$(rewrite_model_state rewrite-model-cache-tags.json)" \
        "$(rewrite_model_state rewrite-model-cache-status.json)" "$(rewrite_model_state rewrite-model-fetch-failed)" \
        "$(rewrite_model_state rewrite-model-cache-bench-show.json)" "$(rewrite_model_state rewrite-model-cache-bench-ps.json)" \
        "$(rewrite_model_state ollama-serve.log)" 2>/dev/null || true
  return 0
}

# rewrite_model_cloud_off_undo — put server.json back the way install_ found it. The library has no
# key-removal verb, and bootstrap_settings_merge is the only JSON writer, so: a file this module
# created that still holds only its one key is deleted; anywhere else the key goes back to the
# value recorded (false, ollama's default, when it was absent). A true the person set themselves
# is never touched. The server reads the change at its next start.
rewrite_model_cloud_off_undo() {
  local f prev v
  f="$(rewrite_model_server_json)"
  prev="$(rewrite_model_state rewrite-model-server-json.prev)"
  [ -f "$prev" ] || return 0
  v="$(/usr/bin/head -1 "$prev" 2>/dev/null)"
  if [ -f "$f" ]; then
    case "$v" in
      true) : ;;
      no-file)
        if [ "$(/usr/bin/plutil -convert xml1 -o - "$f" 2>/dev/null)" = "$(bootstrap_json_norm '{"disable_ollama_cloud":true}' canonical)" ]; then
          rm -f "$f" 2>/dev/null || true
        else
          bootstrap_settings_merge "$f" disable_ollama_cloud false >/dev/null 2>&1 || true
        fi ;;
      *) bootstrap_settings_merge "$f" disable_ollama_cloud false >/dev/null 2>&1 || true ;;
    esac
  fi
  rm -f "$prev" 2>/dev/null || true
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# bench_ — measure a candidate and PRINT A VERDICT. Nothing here is installed, and the receipt
# the agent reads is never touched.
#
# This exists because below 12 GB there is no measured answer, and the honest response to that is
# an instrument, not a guess. It is also how the qwen3:4b ban gets re-tested: a ban nobody can
# re-measure is a ban nobody can ever retire.
#
# It DOES pull the candidate if it is absent, and that is a deliberate deviation from "bench
# changes nothing" — a model that is not on the disk cannot be measured, and refusing to pull it
# would make the verb useless on exactly the machine that needs it. What it never does is leave
# its own derived model behind, write the receipt, or touch the installed one. The base it pulled
# stays, and the exact `ollama rm` line to undo that is printed.
# ═════════════════════════════════════════════════════════════════════════════════════════════
bench_rewrite_model() {
  local cand ollama tmpname mf rendered show g rc resident mem headroom gb hr

  cand="${BOOTSTRAP_BENCH:-${BOOTSTRAP_BENCH:-}}"
  [ -n "$cand" ] || { printf 'bench: no candidate. Pass --bench <model tag>, e.g. --bench qwen3.5:4b\n'; return 2; }

  case "$cand" in
    *[!A-Za-z0-9._:/-]*) printf 'bench: %s is not a well-formed ollama model tag.\n' "$cand"; return 2 ;;
  esac
  # Both refusals come before ANY request, and exit 2 on the gate's scale: nothing was measured.
  # Printed on stdout, which is the bench's verdict channel, and on stderr for a caller reading it.
  if rewrite_model_cloud_ref "$cand"; then
    printf 'bench: REFUSED %s — it is an ollama CLOUD model, so every fixture would be sent to ollama.com. Nothing was requested.\n' "$cand"
    bootstrap_warn "rewrite_model bench: refused cloud model $cand; nothing was measured"
    return 2
  fi
  if ! rewrite_model_url_ok; then
    printf 'bench: REFUSED MODEL_GATE_BASE_URL=%s — it is not a loopback address, so the fixtures would leave this Mac. Nothing was requested.\n' "$REWRITE_MODEL_URL"
    bootstrap_warn "rewrite_model bench: refused non-loopback base URL $REWRITE_MODEL_URL; nothing was measured"
    return 2
  fi

  ollama="$(rewrite_model_ollama)" || { printf 'bench: ollama is not installed — nothing was measured.\n'; return 2; }
  rewrite_model_server_up || { printf 'bench: no ollama server at %s — nothing was measured.\n' "$REWRITE_MODEL_URL"; return 2; }

  if rewrite_model_forbidden "$cand"; then
    printf 'bench: %s is on this module'"'"'s forbidden list — 82-156 s per call and untagged prose\n' "$cand"
    printf '       reasoning that VoiceInk cannot strip. Measuring it anyway, because a ban that\n'
    printf '       cannot be re-tested can never be retired. Read the latency line below.\n'
  fi

  if ! rewrite_model_model_present "$cand"; then
    printf 'bench: pulling %s (this leaves it on the disk; `%s rm %s` removes it)\n' "$cand" "$ollama" "$cand"
    "$ollama" pull "$cand" || { printf 'bench: could not pull %s — nothing was measured.\n' "$cand"; return 2; }
  fi
  if rewrite_model_remote_model "$cand"; then
    printf 'bench: REFUSED %s — ollama lists it with a remote_host, so its generations run on another machine. Nothing was measured.\n' "$cand"
    bootstrap_warn "rewrite_model bench: refused remote-backed model $cand; nothing was measured"
    return 2
  fi

  # A fixed scratch name, so it is obvious and easy to remove — but never at the cost of
  # silently overwriting something of the user's, or of two concurrent benches measuring each
  # other's model.
  tmpname="voiceink-bench"
  if rewrite_model_model_present "$tmpname"; then
    printf 'bench: a model named %s already exists. Remove it first — `%s rm %s` — or wait for\n' "$tmpname" "$ollama" "$tmpname"
    printf '       the bench that is using it. Refusing to overwrite it. Nothing was measured.\n'
    return 2
  fi
  mf="$(rewrite_model_asset voiceink-rewrite.Modelfile)" || { printf 'bench: cannot find assets/voiceink-rewrite.Modelfile\n'; return 2; }
  rendered="$(rewrite_model_state voiceink-bench.Modelfile)"
  sed "s|^FROM .*|FROM $cand|" "$mf" >"$rendered" || { printf 'bench: could not render the Modelfile\n'; return 1; }
  "$ollama" create "$tmpname" -f "$rendered" >/dev/null 2>&1 \
    || { printf 'bench: ollama create failed for %s\n' "$cand"; rm -f "$rendered"; return 2; }

  show="$(rewrite_model_state rewrite-model-cache-bench-show.json)"
  if rewrite_model_show "$tmpname" "$show" && ! rewrite_model_params_ok "$show"; then
    printf 'bench: WARNING — the server does not report num_ctx 4096 / temperature 0.2 for this base.\n'
  fi

  g="$(rewrite_model_asset model-gate.sh)" || { printf 'bench: cannot find assets/model-gate.sh\n'; return 2; }
  printf 'bench: %s -> derived %s, running the same acceptance gate the installer uses\n' "$cand" "$tmpname"
  printf '\n'
  BOOTSTRAP_MODEL="$tmpname" MODEL_GATE_BASE_URL="$REWRITE_MODEL_URL" MODEL_GATE_MAX_MS="$((REWRITE_MODEL_TIMEOUT_S * 1000))" \
    MODEL_GATE_RUNS="${MODEL_GATE_RUNS:-5}" /bin/bash "$g"
  rc=$?

  # Resident memory is the binding constraint on a small Mac, and it is the number the tag's
  # on-disk size does NOT tell you. Read it from the server, while the model is still loaded.
  resident=""
  if rewrite_model_api_get /api/ps "$(rewrite_model_state rewrite-model-cache-bench-ps.json)"; then
    local i n s
    i=0
    while [ "$i" -lt 32 ]; do
      n="$(rewrite_model_json_field "$(rewrite_model_state rewrite-model-cache-bench-ps.json)" "models.$i.name")" || break
      case "$n" in
        "$tmpname"|"$tmpname:latest")
          s="$(rewrite_model_json_field "$(rewrite_model_state rewrite-model-cache-bench-ps.json)" "models.$i.size_vram")" || s=""
          case "${s:-}" in ''|*[!0-9]*) : ;; *) resident="$((s / 1048576)) MB" ;; esac
          break ;;
      esac
      i=$((i + 1))
    done
  fi

  mem="$(rewrite_model_mem_gb)"
  gb=0
  headroom=""
  case "${resident:-}" in
    *' MB') gb=$(( ${resident% MB} / 1024 )); headroom=$((mem - gb)) ;;
  esac
  # A missing resident figure is UNKNOWN, never zero: treating it as zero would compute the whole
  # of unified memory as headroom and call a model that does not fit "usable".

  printf '\n'
  if [ -n "$headroom" ]; then hr="≈${headroom}GB"; else hr="unknown"; fi
  printf 'BENCH  candidate=%s  derived=%s  resident=%s  unified_memory=%sGB  headroom=%s  gate_rc=%s\n' \
    "$cand" "$tmpname" "${resident:-unknown}" "$mem" "$hr" "$rc"
  case "$rc" in
    0) printf 'BENCH_RESULT=PASS model=%s resident=%s headroom=%s\n' "$cand" "${resident:-unknown}" "${headroom:-unknown}"
       if [ -z "$headroom" ]; then
         printf 'VERDICT: PASSES, FOOTPRINT UNKNOWN. The gate passed, but the server did not report this\n'
         printf '         model as resident, so how much memory it leaves for macOS, VoiceInk, the ASR model\n'
         printf '         and a browser was not measured. Re-run the bench before installing it on a small Mac.\n'
       elif [ "$headroom" -ge 5 ]; then
         printf 'VERDICT: USABLE. It passed the same gate the installer uses, and it leaves ~%s GB for macOS,\n' "$headroom"
         printf '         VoiceInk, the transcription model and a browser. Install it with:\n'
         printf '           --only rewrite_model --model %s\n' "$cand"
       else
         printf 'VERDICT: PASSES BUT TIGHT. Only ~%s GB would be left for macOS, VoiceInk, the ASR model and a\n' "$headroom"
         printf '         browser (5 GB is the floor this repo uses). Expect swapping, which collapses generation\n'
         printf '         speed by an order of magnitude. Leaving AI enhancement off is the more honest setting.\n'
       fi ;;
    1) printf 'BENCH_RESULT=REJECTED model=%s\n' "$cand"
       printf 'VERDICT: REJECTED. The WHY line above names the clause it failed, on the run that failed it.\n'
       printf '         Do not install it. Both clauses are silent in production: a model that answers a\n'
       printf '         dictated question pastes its answer into the document, and one that drops a trailing\n'
       printf '         clause loses a sentence the user said, with nothing to show that it happened.\n' ;;
    *) printf 'BENCH_RESULT=NOT-MEASURED model=%s\n' "$cand"
       printf 'VERDICT: NOT MEASURED. The gate could not run, so this is neither a pass nor a fail.\n' ;;
  esac
  printf 'Cleaning up: removing the derived %s. The base %s stays — remove it with `%s rm %s`.\n' \
    "$tmpname" "$cand" "$ollama" "$cand"
  "$ollama" rm "$tmpname" >/dev/null 2>&1 || true
  rm -f "$rendered" "$show" "$(rewrite_model_state rewrite-model-cache-bench-ps.json)" 2>/dev/null || true
  # The GATE's verdict, propagated. Returning 0 here regardless — which is what this line used to
  # do — told every caller that a REJECTED model had passed, and an agent scripting on $? would
  # install it. 0 = PASS, 1 = REJECTED, 2 = nothing was measured.
  return "$rc"
}
