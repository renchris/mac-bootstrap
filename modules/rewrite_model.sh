#!/bin/bash
# rewrite_model — the LOCAL model that replaces cloud Gemini as VoiceInk's rewrite engine.
#
# Sourced by bootstrap.sh. Six verbs + bench_. No top-level side effects. See CONTRACT.md.
#
# END STATE, and every clause of it is read back through a path that did not write it:
#
#   1. ollama is installed and its server answers at http://localhost:11434
#   2. a DERIVED model `voiceink-rewrite` exists, built FROM the tier's base with
#      num_ctx 4096 / temperature 0.2 / top_p 0.9 / top_k 20 / repeat_penalty 1.0 baked in
#   3. THAT EXACT MODEL (matched by digest, not by name) has passed assets/model-gate.sh
#   4. VoiceInk's EnhancementTimeoutSeconds is 15
#   5. VoiceInk's ollamaSelectedModel names the derived model — which ONLY THE GUI CAN SET,
#      and is therefore this module's evidence that the human did the one step no script can
#      do. rewrite_model never writes that key; writing it would destroy the only signal we have.
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
# THE GUI STEP (this is this module's whole point). VoiceInk resolves its AI provider PER MODE:
# ModeRuntimeConfiguration reads mode?.selectedAIProvider and falls back to `resolvedProvider`,
# which returns `aiService.connectedProviders.first` — and connectedProviders filters
# AIProvider.allCases IN DECLARATION ORDER, where gemini is 3rd and ollama is 13th. So ANY
# surviving cloud key silently wins the fallback and the local model is never called. Worse,
# ollama qualifies for that list only if `ollamaService.isConnected`, which is set by a LIVE
# checkConnection() probe and by nothing else:
#
#   *** NO `defaults write` CAN EVER SELECT OLLAMA. The Connect click is not advisable, it is
#   *** STRUCTURALLY REQUIRED, and a module that reported SATISFIED without it would be lying.
#
# So rewrite_model does every reversible thing itself, and then REFUSES to call itself done until the one
# irreducibly-human gesture has left its mark in ollamaSelectedModel.
#
# MEASURED HERE, NOT IN THE INHERITED RESEARCH (it says the keys live in the Keychain): the
# open-source build compiles with LOCAL_BUILD (LocalBuild.xcconfig:15), and under that flag
# KeychainService stores every API key in UserDefaults as `LocalKeychain_<provider>APIKey`
# (KeychainService.swift:14-17,36-38). So on the Mac this repo bootstraps, a surviving cloud key
# is a DEFAULTS key, and rewrite_model can detect the trap without a Keychain dialog. It probes with
# `defaults read-type`, which prints a type and never a value — a live key was found that way on
# the development machine, and its bytes never entered a log.
#
# WHAT THIS MODULE WILL NOT DO
#   - It will not plutil-copy or export the com.prakashjoshipax.VoiceInk domain. That domain
#     holds live provider API keys. It writes exactly two keys, individually, by name.
#   - It will not write ollamaSelectedModel (see above), and it will not touch a mode.
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
REWRITE_MODEL_CURL=/usr/bin/curl
REWRITE_MODEL_DEFAULTS=/usr/bin/defaults
REWRITE_MODEL_PGREP=/usr/bin/pgrep
REWRITE_MODEL_SYSCTL=/usr/sbin/sysctl

# ── tiny helpers. All absolute-path-first: a PATH lookup inside a bootstrap inherits whatever
#    the operator's shell happens to be, and `brew` is not on the PATH of a fresh login shell
#    until the shellenv line lands. ─────────────────────────────────────────────────────────
rewrite_model_ollama() {
  local c
  for c in /opt/homebrew/bin/ollama /usr/local/bin/ollama; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  c="$(command -v ollama 2>/dev/null)" || c=""
  [ -n "$c" ] && { printf '%s' "$c"; return 0; }
  return 1
}
rewrite_model_brew() {
  local c
  for c in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  c="$(command -v brew 2>/dev/null)" || c=""
  [ -n "$c" ] && { printf '%s' "$c"; return 0; }
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
    qwen3:4b|qwen3:4b-*) return 0 ;;
  esac
  return 1
}

# ── the ollama HTTP API. Every read-back goes through this, and NEVER through the `ollama` CLI
#    that wrote the model — two engines by construction. Parsing is plutil-only, for the same
#    reason bootstrap_settings_get is: it must work on a Mac with no jq. ─────────────────────────────

# rewrite_model_api_post <path> <body> <outfile> — rc 0 iff curl succeeded AND the reply parses as JSON.
rewrite_model_api_post() {
  local p="$1" body="$2" out="$3" rc
  "$REWRITE_MODEL_CURL" -sS -m "${BOOTSTRAP_REWRITE_MODEL_HTTP_TIMEOUT:-30}" -H 'Content-Type: application/json' \
    -d "$body" "$REWRITE_MODEL_URL$p" >"$out" 2>/dev/null
  rc=$?
  [ $rc -eq 0 ] || return 1
  bootstrap_json_ok "$out" || return 1
  return 0
}
rewrite_model_api_get() {
  local p="$1" out="$2" rc
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

rewrite_model_server_up() { "$REWRITE_MODEL_CURL" -fsS -m 5 "$REWRITE_MODEL_URL/api/version" >/dev/null 2>&1; }

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

# rewrite_model_cloud_key_present — is a cloud provider key still saved? If so, it BEATS ollama in
# VoiceInk's connectedProviders fallback and the local model is never called, so the human must
# also pin Ollama on the active mode. Probed with `read-type`, which prints a TYPE and never a
# value; no key material is ever read, logged or printed. Both storage shapes are checked: the
# LOCAL_BUILD build keeps keys in this defaults domain, a signed build in the Keychain.
rewrite_model_cloud_key_present() {
  local k
  for k in geminiAPIKey openAIAPIKey anthropicAPIKey groqAPIKey cerebrasAPIKey mistralAPIKey \
           openRouterAPIKey xaiAPIKey; do
    rewrite_model_preference_exists "LocalKeychain_$k" && return 0
  done
  if [ -x /usr/bin/security ] && [ -z "${BOOTSTRAP_REWRITE_MODEL_NO_KEYCHAIN_PROBE:-}" ]; then
    for k in geminiAPIKey openAIAPIKey anthropicAPIKey; do
      # metadata only — no -w, so no secret is read and no unlock dialog is raised
      /usr/bin/security find-generic-password -s "$REWRITE_MODEL_DOMAIN" -a "$k" >/dev/null 2>&1 && return 0
    done
  fi
  return 1
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

# rewrite_model_asset <name> — the shipped asset's absolute path: beside bootstrap.sh when running from a
# clone, otherwise fetched once into the state dir at the release pin. Never writes in the repo.
rewrite_model_asset() {
  local n="$1" dest code
  if [ -n "${BOOTSTRAP_ASSETS:-}" ] && [ -r "$BOOTSTRAP_ASSETS/$n" ]; then printf '%s' "$BOOTSTRAP_ASSETS/$n"; return 0; fi
  dest="$(rewrite_model_state "$n")"
  [ -r "$dest" ] && { printf '%s' "$dest"; return 0; }
  case "${BOOTSTRAP_PIN:-}" in
    ''|__PIN_SHA__|main|master|HEAD) return 1 ;;    # a moving ref is not a pin; refuse to fetch
  esac
  code="$("$REWRITE_MODEL_CURL" -sS -L -o "$dest.part" -w '%{http_code}' "${BOOTSTRAP_RAW:-}/assets/$n" 2>/dev/null)" || code=""
  if [ "$code" = "200" ] && [ -s "$dest.part" ]; then
    mv "$dest.part" "$dest" 2>/dev/null && { printf '%s' "$dest"; return 0; }
  fi
  rm -f "$dest.part" 2>/dev/null
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
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# THE SIX VERBS
# ═════════════════════════════════════════════════════════════════════════════════════════════

# ── catalog metadata (optional verbs; see CONTRACT.md) ────────────────────────────────────────
what_rewrite_model()    { printf '%s' 'a LOCAL speech-rewrite model, so dictation cleanup needs no cloud API key'; }
cost_rewrite_model()    { printf '%s' 'Homebrew + ollama + a ~5 GB model download. Several minutes. One in-app picker at the end.'; }
profile_rewrite_model() { printf '%s' 'standard'; }

verify_rewrite_model() {
  # The defaults domain is resolved from the password database, not from $HOME, so a sandboxed
  # HOME would silently rewrite the REAL machine. Refuse instead. (bootstrap-lib.sh: bootstrap_defaults_home_ok)
  bootstrap_defaults_home_ok || return 1
  local show want got sel t
  rewrite_model_machine_ready || return 1

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

  # The GUI evidence. rewrite_model never writes this key, so its value can only have come from a human in
  # VoiceInk's own picker — which is the only thing that also sets the in-app connection state
  # that decides whether the local model is called at all.
  sel="$(rewrite_model_preference ollamaSelectedModel)" || return 1
  case "$sel" in "$REWRITE_MODEL_NAME"|"$REWRITE_MODEL_NAME:latest") ;; *) return 1 ;; esac

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
#   HOMEBREW  ollama cannot be installed without it, and its installer wants their password
#   DECIDE    below the measured floor: bench a candidate, or leave AI enhancement off
#   QUIT      a running VoiceInk discards `defaults write` on exit, so the timeout cannot land
#   GUI       the machine side is done; only the Connect-and-pick click remains
#   NONE      nothing is waiting on a human
#
# QUIT and GUI are deliberately gated on rewrite_model_machine_ready. Reporting a human gesture BEFORE the
# machine side is reachable would stop install_ from ever running (the driver takes the
# NEEDS_HUMAN branch and never calls it), and the model would never be pulled at all.
rewrite_model_pending() {
  local t sel
  if ! rewrite_model_ollama >/dev/null 2>&1 && ! rewrite_model_brew >/dev/null 2>&1; then printf 'HOMEBREW'; return 0; fi
  if [ -z "$(rewrite_model_base)" ]; then printf 'DECIDE'; return 0; fi
  if rewrite_model_machine_ready; then
    t="$(rewrite_model_preference EnhancementTimeoutSeconds)" || t=""
    if [ "$t" != "$REWRITE_MODEL_TIMEOUT_S" ] && rewrite_model_voiceink_running; then printf 'QUIT'; return 0; fi
    sel="$(rewrite_model_preference ollamaSelectedModel)" || sel=""
    case "$sel" in "$REWRITE_MODEL_NAME"|"$REWRITE_MODEL_NAME:latest") ;; *) printf 'GUI'; return 0 ;; esac
  fi
  printf 'NONE'
  return 0
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
  local extra=""
  rewrite_model_cloud_key_present && extra=' You must ALSO pin Ollama on your active mode under Settings > Modes: a saved cloud key still outranks Ollama in the provider fallback, so without the pin your local model is never called.'
  case "$(rewrite_model_pending)" in
    HOMEBREW)
      printf 'Homebrew is missing, so ollama cannot be installed; its installer needs your password.\n' ;;
    DECIDE)
      printf 'This Mac reports %s GB of unified memory, and no local rewrite model is measured good at that size — bench a candidate (qwen3.5:4b, 3.4 GB, is the untested one worth trying) or leave VoiceInk AI enhancement off rather than installing a model that invents text.\n' "$(rewrite_model_mem_gb)" ;;
    QUIT)
      printf 'VoiceInk is running and it rewrites its own preferences when it quits, so the %s-second enhancement timeout cannot be written underneath it — quit VoiceInk, re-run this, then do the Connect step in Settings > AI Models > Ollama.\n' "$REWRITE_MODEL_TIMEOUT_S" ;;
    GUI)
      printf 'In VoiceInk: Settings > AI Models > Ollama > Connect, then pick %s in the model list — no preference can do this, because the app only counts Ollama as connected after a live probe.%s While you are in Settings > Transcription, download parakeet-unified-0.6b from its model card and select it — it is faster, more accurate and lighter than the whisper turbo default, and it punctuates its own output, which is work the rewrite model then does not have to do.\n' "$REWRITE_MODEL_NAME" "$extra" ;;
    *)
      printf 'nothing is waiting on you for the local rewrite model.\n' ;;
  esac
  return 0
}

gesture_rewrite_model() {
  if ! bootstrap_defaults_home_ok >/dev/null 2>&1; then
    printf 'run it from your own account (no HOME override), or set BOOTSTRAP_ALLOW_FOREIGN_DEFAULTS=1 if you truly mean to write the real domain'
    return 0
  fi
  local root
  case "$(rewrite_model_pending)" in
    HOMEBREW)
      printf '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"\n' ;;
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
  local base ollama brew mf rendered show dg g rc waited sel t prev

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
  if rewrite_model_forbidden "$base"; then
    bootstrap_warn "rewrite_model: refusing base '$base'. Measured 82-156 s per call and untagged prose reasoning that VoiceInk's <think> filter cannot strip, so the reasoning is pasted into the document. Use --bench to re-measure it if you want to challenge that."
    return 2
  fi

  # 1. ollama ─────────────────────────────────────────────────────────────────────────────────
  if ! ollama="$(rewrite_model_ollama)"; then
    brew="$(rewrite_model_brew)" || { bootstrap_warn "rewrite_model: no ollama and no brew"; return 2; }
    printf 'rewrite_model: installing ollama via Homebrew\n'
    "$brew" install ollama || bootstrap_warn "rewrite_model: brew install ollama exited non-zero; checking anyway"
    ollama="$(rewrite_model_ollama)" || { bootstrap_warn "rewrite_model: ollama is still not on disk after brew install"; return 2; }
  fi
  # Executed, not assumed: an installer's exit code is never the verdict.
  "$ollama" --version >/dev/null 2>&1 || { bootstrap_warn "rewrite_model: $ollama will not run"; return 2; }

  # 2. the server ─────────────────────────────────────────────────────────────────────────────
  if ! rewrite_model_server_up; then
    if brew="$(rewrite_model_brew)"; then
      printf 'rewrite_model: starting the ollama service\n'
      "$brew" services start ollama >/dev/null 2>&1 || true
    fi
    if ! rewrite_model_server_up; then
      printf 'rewrite_model: starting `ollama serve` in the background\n'
      # `&` on its own line, deliberately NOT `brew services start … || nohup … &`: in that form
      # the `&` binds the whole AND-OR list, so `brew services start` itself is backgrounded and
      # the fallback runs unconditionally. That shape is in the research script this replaces.
      nohup "$ollama" serve >"$(rewrite_model_state ollama-serve.log)" 2>&1 &
    fi
    waited=0
    while [ "$waited" -lt 30 ]; do
      rewrite_model_server_up && break
      sleep 1
      waited=$((waited + 1))
    done
  fi
  rewrite_model_server_up || { bootstrap_warn "rewrite_model: no ollama server answering at $REWRITE_MODEL_URL after 30 s"; return 2; }

  # 3. the base model ─────────────────────────────────────────────────────────────────────────
  if ! rewrite_model_model_present "$base"; then
    printf 'rewrite_model: pulling %s — this is the only network step, and it is several GB\n' "$base"
    "$ollama" pull "$base" || { bootstrap_warn "rewrite_model: ollama pull $base failed"; return 2; }
    rewrite_model_model_present "$base" || { bootstrap_warn "rewrite_model: $base is still absent after the pull"; return 2; }
  fi

  # 4. the derived model ──────────────────────────────────────────────────────────────────────
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

  # 5. the acceptance gate — BEFORE anything is called done ───────────────────────────────────
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

  # 6. the two VoiceInk preferences ───────────────────────────────────────────────────────────
  # Exactly two keys, each written by name. The domain is never exported or copied: it holds live
  # provider API keys. ollamaSelectedModel is deliberately NOT written — see the header.
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

  # 7. the one step no script can take ────────────────────────────────────────────────────────
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
  sel="$(rewrite_model_preference ollamaSelectedModel)" || sel=""
  case "$sel" in
    "$REWRITE_MODEL_NAME"|"$REWRITE_MODEL_NAME:latest") return 0 ;;
  esac
  printf 'rewrite_model: the machine side is done. VoiceInk itself must now be pointed at %s — no preference can do it.\n' "$REWRITE_MODEL_NAME"
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

  # LAST, not first: every read above (is the model there? what base was it?) re-creates the
  # API caches, so deleting them at the top of the function leaves them behind at the bottom.
  rm -f "$(rewrite_model_state rewrite-model-gate.receipt)" "$(rewrite_model_state voiceink-rewrite.Modelfile)" \
        "$(rewrite_model_state rewrite-model-cache-show.json)" "$(rewrite_model_state rewrite-model-cache-tags.json)" \
        "$(rewrite_model_state rewrite-model-cache-bench-show.json)" "$(rewrite_model_state rewrite-model-cache-bench-ps.json)" \
        "$(rewrite_model_state ollama-serve.log)" 2>/dev/null || true
  return 0
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

  ollama="$(rewrite_model_ollama)" || { printf 'bench: ollama is not installed — nothing was measured.\n'; return 2; }
  rewrite_model_server_up || { printf 'bench: no ollama server at %s — nothing was measured.\n' "$REWRITE_MODEL_URL"; return 2; }

  case "$cand" in
    *[!A-Za-z0-9._:/-]*) printf 'bench: %s is not a well-formed ollama model tag.\n' "$cand"; return 2 ;;
  esac

  if rewrite_model_forbidden "$cand"; then
    printf 'bench: %s is on this module'"'"'s forbidden list — 82-156 s per call and untagged prose\n' "$cand"
    printf '       reasoning that VoiceInk cannot strip. Measuring it anyway, because a ban that\n'
    printf '       cannot be re-tested can never be retired. Read the latency line below.\n'
  fi

  if ! rewrite_model_model_present "$cand"; then
    printf 'bench: pulling %s (this leaves it on the disk; `%s rm %s` removes it)\n' "$cand" "$ollama" "$cand"
    "$ollama" pull "$cand" || { printf 'bench: could not pull %s — nothing was measured.\n' "$cand"; return 2; }
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
