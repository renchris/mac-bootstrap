# shellcheck shell=bash
# shellcheck disable=SC1090,SC2034  # the library and modules are sourced from runtime paths, and the
# variables the wrapper functions set are read by the module those wrappers run inside.
# scripts/checks/rewrite-model.sh — the local rewrite model keeps dictation on this Mac. Sourced by
# scripts/characterize.sh, which supplies the harness; never run on its own.
#
# No network, no real ollama, no real VoiceInk preferences. Three stand-ins make that possible, and
# each is a seam the modules already carry for exactly this:
#   - an ollama API served by a curl STUB (BOOTSTRAP_REWRITE_MODEL_CURL) that answers /api/* from
#     JSON files under $CHECK_TMP, so verify_ runs end to end against a server that does not exist;
#   - a VoiceInk preference domain that is an absolute .plist path under $CHECK_TMP
#     (BOOTSTRAP_REWRITE_MODEL_DOMAIN, BOOTSTRAP_VOICEINK_DOMAIN) — `defaults` writes that file and
#     nothing else, so the real com.prakashjoshipax.VoiceInk is never opened;
#   - an ollama executable that does not exist, or a stub (BOOTSTRAP_REWRITE_MODEL_OLLAMA), so the
#     development Mac's own ollama is invisible.
# Every positive check sits beside a negative control that proves the reader can say no.

RM_DIR="$CHECK_TMP/rewrite-model"
mkdir -p "$RM_DIR/api" "$RM_DIR/bin"
RM_LIB="$CHECK_ROOT/assets/hooks/bootstrap-lib.sh"
RM_MOD="$CHECK_ROOT/modules/rewrite_model.sh"
VI_MOD="$CHECK_ROOT/modules/voiceink.sh"

# The fake ollama API. It records every URL it is asked for, so a refusal can be shown to have sent
# nothing at all.
cat > "$RM_DIR/bin/curl" <<'STUB'
#!/bin/bash
out=""; fmt=""; url=""; fail=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -w) fmt="$2"; shift ;;
    -d|-H|-m) shift ;;
    -*f*) fail=1 ;;
    http*) url="$1" ;;
  esac
  shift
done
printf '%s\n' "$url" >> "$RM_FAKE_API/calls"
p="${url#*://}"; p="/${p#*/}"
f="$RM_FAKE_API/$(printf '%s' "${p#/api/}" | tr '/' '_').json"
if [ ! -f "$f" ]; then [ "$fail" = 1 ] && exit 22; [ -n "$fmt" ] && printf '404'; exit 0; fi
if [ -n "$out" ]; then cat "$f" > "$out"; else cat "$f"; fi
[ -n "$fmt" ] && printf '200'
exit 0
STUB
printf '#!/bin/bash\nexit 0\n' > "$RM_DIR/bin/ollama"
printf '#!/bin/bash\nexit 1\n' > "$RM_DIR/bin/ollama-broken"
chmod +x "$RM_DIR/bin/curl" "$RM_DIR/bin/ollama" "$RM_DIR/bin/ollama-broken"

# rm_api — a server that is certified, cloud off, and serves the derived model with the right parameters.
rm_api() {
  rm -rf "$RM_DIR/api"; mkdir -p "$RM_DIR/api" "$RM_DIR/lo/api"
  ln -sfn "$RM_DIR/api/tags.json" "$RM_DIR/lo/api/tags"   # the same bytes, in the local-only reader's file:// layout
  printf '{"version":"0.34.0"}' > "$RM_DIR/api/version.json"
  printf '{"models":[{"name":"voiceink-rewrite:latest","digest":"d1g3st","size":5225387842}]}' > "$RM_DIR/api/tags.json"
  printf '{"details":{"parent_model":"qwen3:8b"},"parameters":"num_ctx                        4096\\ntemperature                    0.2"}' > "$RM_DIR/api/show.json"
  printf '{"cloud":{"disabled":true,"source":"env"}}' > "$RM_DIR/api/status.json"
}

# rm_voiceink <plist> <modes-json> — a VoiceInk preference file with the timeout set and these modes.
rm_voiceink() {
  rm -f "$1"
  plutil -create xml1 "$1"
  plutil -insert EnhancementTimeoutSeconds -integer 15 "$1"
  plutil -insert modeConfigurationsV2 -data "$(printf '%s' "$2" | base64)" "$1"
}
RM_MODE_OLLAMA='{"id":"a","name":"Default","isEnabled":true,"isDefault":true,"isAIEnhancementEnabled":true,"selectedAIProvider":"Ollama","selectedAIModel":"voiceink-rewrite"}'
RM_MODE_GEMINI='{"id":"b","name":"Email","isEnabled":true,"isAIEnhancementEnabled":true,"selectedAIProvider":"Gemini","selectedAIModel":"gemini-3-flash"}'
RM_MODE_OFF='{"id":"c","name":"Raw","isEnabled":true,"isAIEnhancementEnabled":false,"selectedAIProvider":"Gemini"}'
RM_MODE_DISABLED_GEMINI='{"id":"d","name":"Old","isEnabled":false,"isAIEnhancementEnabled":true,"selectedAIProvider":"Gemini"}'
RM_MODE_OLLAMA_WRONG='{"id":"e","name":"Default","isEnabled":true,"isAIEnhancementEnabled":true,"selectedAIProvider":"Ollama","selectedAIModel":"qwen3:8b"}'
# rm_fx <modes-json> — a FRESH fixture path each time: cfprefsd caches a domain it has read, so a file
# rewritten under the same path could be answered from the cache.
RM_N=0
rm_fx() { RM_N=$((RM_N + 1)); RM_DOMAIN="$RM_DIR/voiceink-$RM_N.plist"; rm_voiceink "$RM_DOMAIN" "$1"; }

# rm_call <home> <function> [args] — one module function, in a subshell, against a sandbox HOME and a
# fixture domain. Extra environment is passed by prefixing the call.
rm_call() {
  local h="$1"; shift
  ( export HOME="$h" BOOTSTRAP_STATE_DIR="$h/.mac-bootstrap" BOOTSTRAP_ALLOW_FOREIGN_DEFAULTS=1 \
           BOOTSTRAP_REWRITE_MODEL_DOMAIN="$RM_DOMAIN" \
           BOOTSTRAP_REWRITE_MODEL_OLLAMA="${RM_OLLAMA:-$RM_DIR/bin/ollama}" \
           BOOTSTRAP_REWRITE_MODEL_BREW="${BOOTSTRAP_REWRITE_MODEL_BREW:-$RM_DIR/no-brew}" \
           BOOTSTRAP_REWRITE_MODEL_CURL="$RM_DIR/bin/curl" RM_FAKE_API="$RM_DIR/api" LOCAL_ONLY_OLLAMA_URL="file://$RM_DIR/lo" BOOTSTRAP_ASSETS="$CHECK_ROOT/assets" \
           BOOTSTRAP_REWRITE_MODEL_APP_PROCESS=no-such-voiceink-process
    unset BOOTSTRAP_LOG
    . "$RM_LIB" >/dev/null 2>&1; . "$RM_MOD" >/dev/null 2>&1
    "$@" )
}
rm_receipt() { mkdir -p "$1/.mac-bootstrap"; printf 'digest=d1g3st\nmodel=voiceink-rewrite\nbase=qwen3:8b\nat=x\n' > "$1/.mac-bootstrap/rewrite-model-gate.receipt"; }

# 1. The done-marker is the MODES, read against a server that is certified and cloud-off. ─────────
h="$(fresh_home rm-verify)"; rm_receipt "$h"; rm_api
rm_fx "[$RM_MODE_OLLAMA,$RM_MODE_OFF,$RM_MODE_DISABLED_GEMINI]"
rm_call "$h" verify_rewrite_model 2>/dev/null; same "rewrite-model-verify-all-local" "$?" 0
rm_fx "[$RM_MODE_OLLAMA,$RM_MODE_GEMINI]"
plutil -insert ollamaSelectedModel -string voiceink-rewrite "$RM_DOMAIN"
rm_call "$h" verify_rewrite_model 2>/dev/null; same "rewrite-model-verify-gemini-mode" "$?" 1
same "rewrite-model-gemini-mode-is-named" "$(rm_call "$h" rewrite_model_modes_pinned 2>/dev/null)" '"Email" uses Gemini / gemini-3-flash'
rm_fx "[$RM_MODE_OLLAMA_WRONG]"
rm_call "$h" verify_rewrite_model 2>/dev/null; same "rewrite-model-verify-wrong-ollama-model" "$?" 1
rm_fx "[$RM_MODE_OFF]"
rm_call "$h" verify_rewrite_model 2>/dev/null; same "rewrite-model-verify-no-enhanced-mode" "$?" 1
rm_fx "[$RM_MODE_OLLAMA]"
plutil -insert ollamaBaseURL -string 'http://10.0.0.5:11434' "$RM_DOMAIN"
rm_call "$h" verify_rewrite_model 2>/dev/null; same "rewrite-model-verify-remote-ollama-url" "$?" 1

# 2. The cloud switch is judged by the SERVER, and a remote-backed model is never local. ───────────
rm_fx "[$RM_MODE_OLLAMA]"
printf '{"cloud":{"disabled":false,"source":"none"}}' > "$RM_DIR/api/status.json"
rm_call "$h" verify_rewrite_model 2>/dev/null; same "rewrite-model-verify-cloud-on" "$?" 1
rm_api
printf '{"models":[{"name":"voiceink-rewrite:latest","digest":"d1g3st","size":231,"remote_host":"https://ollama.com:443"}]}' > "$RM_DIR/api/tags.json"
rm_call "$h" verify_rewrite_model 2>/dev/null; same "rewrite-model-verify-remote-model" "$?" 1
rm_api
rm_call "$h" verify_rewrite_model 2>/dev/null; same "rewrite-model-verify-control-again" "$?" 0

# 3. server.json: written through the one writer, read back by plutil, idempotent, undone. ─────────
h="$(fresh_home rm-serverjson)"
rm_call "$h" rewrite_model_cloud_off_write >/dev/null 2>&1
same "server-json-reads-back" "$(plutil -extract disable_ollama_cloud raw -o - "$h/.ollama/server.json" 2>/dev/null)" true
RM_SUM1="$(shasum -a 256 "$h/.ollama/server.json" | cut -d' ' -f1)"
rm_call "$h" rewrite_model_cloud_off_write >/dev/null 2>&1
same "server-json-second-run-changes-nothing" "$(shasum -a 256 "$h/.ollama/server.json" | cut -d' ' -f1)" "$RM_SUM1"
same "server-json-no-backup-of-a-new-file" "$(find "$h/.ollama" -name '*backup*' | wc -l | tr -d ' ')" 0
rm_call "$h" rewrite_model_cloud_off_undo
if [ -e "$h/.ollama/server.json" ]; then fail "server-json-undo-removes-its-own-file"; else pass "server-json-undo-removes-its-own-file"; fi
h="$(fresh_home rm-serverjson-kept)"; mkdir -p "$h/.ollama"; printf '{"other":1}\n' > "$h/.ollama/server.json"
rm_call "$h" rewrite_model_cloud_off_write >/dev/null 2>&1
same "server-json-additive" "$(plutil -extract other raw -o - "$h/.ollama/server.json" 2>/dev/null)/$(plutil -extract disable_ollama_cloud raw -o - "$h/.ollama/server.json" 2>/dev/null)" "1/true"
rm_call "$h" rewrite_model_cloud_off_undo
same "server-json-undo-keeps-the-file" "$(plutil -extract other raw -o - "$h/.ollama/server.json" 2>/dev/null)/$(plutil -extract disable_ollama_cloud raw -o - "$h/.ollama/server.json" 2>/dev/null)" "1/false"

# 4. Refusals happen before any request. ──────────────────────────────────────────────────────────
for t in gpt-oss:120b-cloud kimi-k2.5:cloud MiniMax-M2:CLOUD; do
  rm_call "$h" rewrite_model_cloud_ref "$t"; same "cloud-ref-refused-$t" "$?" 0
done
for t in qwen3:8b qwen3.5:4b gemma3:cloudy qwen3:8b-local; do
  rm_call "$h" rewrite_model_cloud_ref "$t"; same "cloud-ref-allowed-$t" "$?" 1
done
for u in http://localhost:11434 http://127.0.0.1:11434 'http://[::1]:11434'; do
  ( MODEL_GATE_BASE_URL="$u"; export MODEL_GATE_BASE_URL; rm_call "$h" rewrite_model_url_ok ); same "loopback-accepted-$u" "$?" 0
done
for u in http://192.0.2.1:11434 http://0.0.0.0:11434 https://ollama.com http://localhost.example.com:11434; do
  ( MODEL_GATE_BASE_URL="$u"; export MODEL_GATE_BASE_URL; rm_call "$h" rewrite_model_url_ok ); same "non-loopback-refused-$u" "$?" 1
done

h="$(fresh_home rm-refuse)"; rm_api; : > "$RM_DIR/api/calls"
RM_OUT="$( (BOOTSTRAP_MODEL=gpt-oss:120b-cloud; export BOOTSTRAP_MODEL; rm_call "$h" install_rewrite_model) 2>&1)"; RM_RC=$?
same "install-refuses-cloud-model-rc" "$RM_RC" 2
case "$RM_OUT" in *"CLOUD model"*) pass "install-says-why-it-refused" ;; *) fail "install-says-why-it-refused" "$RM_OUT" ;; esac
same "install-refusal-sent-nothing" "$(grep -c . "$RM_DIR/api/calls" | tr -d ' ')" 0
RM_OUT="$( (BOOTSTRAP_MODEL=qwen3:8b; RM_OLLAMA="$RM_DIR/bin/ollama-broken"; export BOOTSTRAP_MODEL RM_OLLAMA; rm_call "$h" install_rewrite_model) 2>&1)"
case "$RM_OUT" in *"will not run"*) pass "install-passes-a-local-tag" "reached the ollama check" ;; *) fail "install-passes-a-local-tag" "$RM_OUT" ;; esac
RM_OUT="$( (MODEL_GATE_BASE_URL=http://192.0.2.1:11434; export MODEL_GATE_BASE_URL; rm_call "$h" install_rewrite_model) 2>&1)"; RM_RC=$?
same "install-refuses-remote-url-rc" "$RM_RC" 2
same "install-remote-url-sent-nothing" "$(grep -c . "$RM_DIR/api/calls" | tr -d ' ')" 0

h="$(fresh_home rm-bench)"
for t in gpt-oss:120b-cloud kimi-k2.5:cloud; do
  BOOTSTRAP_REWRITE_MODEL_OLLAMA="$RM_DIR/no-ollama" MODEL_GATE_BASE_URL=http://127.0.0.1:9 drive_at "$h" --only rewrite_model --bench "$t"
  same "bench-refuses-$t-rc" "$CHECK_RC" 2
  case "$CHECK_OUT" in *"REFUSED $t"*) pass "bench-says-it-refused-$t" ;; *) fail "bench-says-it-refused-$t" "$(printf '%s' "$CHECK_OUT" | tail -3)" ;; esac
done
BOOTSTRAP_REWRITE_MODEL_OLLAMA="$RM_DIR/no-ollama" MODEL_GATE_BASE_URL=http://127.0.0.1:9 drive_at "$h" --only rewrite_model --bench qwen3.5:4b
case "$CHECK_OUT" in *REFUSED*) fail "bench-local-tag-not-refused" "$(printf '%s' "$CHECK_OUT" | tail -3)" ;; *"ollama is not installed"*) pass "bench-local-tag-not-refused" ;; *) fail "bench-local-tag-not-refused" "$(printf '%s' "$CHECK_OUT" | tail -3)" ;; esac
BOOTSTRAP_REWRITE_MODEL_OLLAMA="$RM_DIR/no-ollama" MODEL_GATE_BASE_URL=http://192.0.2.1:11434 drive_at "$h" --only rewrite_model --bench qwen3.5:4b
same "bench-refuses-remote-url-rc" "$CHECK_RC" 2
case "$CHECK_OUT" in *"REFUSED MODEL_GATE_BASE_URL"*) pass "bench-says-url-is-not-loopback" ;; *) fail "bench-says-url-is-not-loopback" "$(printf '%s' "$CHECK_OUT" | tail -3)" ;; esac

# 5. A standard user with no Homebrew is offered the pinned route, never Homebrew. ─────────────────
h="$(fresh_home rm-plan)"
rm_voiceink "$RM_DIR/plan-voiceink.plist" "[$RM_MODE_OLLAMA]"
PATH=/usr/bin:/bin:/usr/sbin:/sbin BOOTSTRAP_ASSUME_STANDARD_USER=1 BOOTSTRAP_ALLOW_FOREIGN_DEFAULTS=1 \
  BOOTSTRAP_REWRITE_MODEL_DOMAIN="$RM_DIR/plan-voiceink.plist" BOOTSTRAP_REWRITE_MODEL_OLLAMA="$RM_DIR/no-ollama" \
  MODEL_GATE_BASE_URL=http://127.0.0.1:9 drive_at "$h" --plan --only rewrite_model --model qwen3:8b
RM_LINE="$(printf '%s\n' "$CHECK_OUT" | grep -E '^ +rewrite_model ')"
case "$RM_LINE" in
  *[Bb]rew*) fail "plan-standard-user-not-homebrew" "$RM_LINE" ;;
  *"pinned GitHub release"*) pass "plan-standard-user-names-pinned-route" ;;
  *) fail "plan-standard-user-names-pinned-route" "$RM_LINE" ;;
esac
# control: a brew this user CAN write is the Homebrew route, so the plan line can say so
mkdir -p "$RM_DIR/brew/bin" "$RM_DIR/brew/Cellar"; printf '#!/bin/bash\nexit 0\n' > "$RM_DIR/brew/bin/brew"; chmod +x "$RM_DIR/brew/bin/brew"
BOOTSTRAP_ALLOW_FOREIGN_DEFAULTS=1 BOOTSTRAP_REWRITE_MODEL_BREW="$RM_DIR/brew/bin/brew" \
  BOOTSTRAP_REWRITE_MODEL_DOMAIN="$RM_DIR/plan-voiceink.plist" BOOTSTRAP_REWRITE_MODEL_OLLAMA="$RM_DIR/no-ollama" \
  MODEL_GATE_BASE_URL=http://127.0.0.1:9 drive_at "$h" --plan --only rewrite_model --model qwen3:8b
RM_LINE="$(printf '%s\n' "$CHECK_OUT" | grep -E '^ +rewrite_model ')"
case "$RM_LINE" in *"via Homebrew"*) pass "plan-usable-brew-names-homebrew" ;; *) fail "plan-usable-brew-names-homebrew" "$RM_LINE" ;; esac
if [ -e "$h/.mac-bootstrap/tools" ] || [ -e "$h/.ollama" ]; then fail "plan-wrote-nothing"; else pass "plan-wrote-nothing"; fi

# 6. The LaunchAgent this module would load: loopback, cloud off, and a path that survives XML. ────
RM_PLIST="$RM_DIR/agent.plist"
( MODEL_GATE_BASE_URL=http://localhost:11500; export MODEL_GATE_BASE_URL; rm_call "$h" rewrite_model_agent_render "/Users/a&b/tools/bin/ollama" ) > "$RM_PLIST"
if plutil -lint "$RM_PLIST" >/dev/null 2>&1; then pass "agent-plist-is-valid"; else fail "agent-plist-is-valid"; fi
same "agent-binds-loopback" "$(json_at "$RM_PLIST" EnvironmentVariables.OLLAMA_HOST)" 127.0.0.1:11500
same "agent-cloud-off" "$(json_at "$RM_PLIST" EnvironmentVariables.OLLAMA_NO_CLOUD)" 1
same "agent-program-path-escaped" "$(json_at "$RM_PLIST" ProgramArguments.0)" "/Users/a&b/tools/bin/ollama"

# 7. Where each module reaches: well-formed egress lines. ─────────────────────────────────────────
for m in rewrite_model voiceink; do
  RM_EG="$( ( . "$RM_LIB" >/dev/null 2>&1; . "$CHECK_ROOT/modules/$m.sh" >/dev/null 2>&1; "egress_$m" ) 2>/dev/null)"
  RM_BAD="$(printf '%s\n' "$RM_EG" | awk 'NF==0{next} $1 !~ /^[a-z0-9-]+(\.[a-z0-9-]+)+$/ || ($2 != "install" && $2 != "run") || NF < 3 {print}')"
  if [ -n "$RM_EG" ] && [ -z "$RM_BAD" ]; then pass "egress-$m-well-formed" "$(printf '%s\n' "$RM_EG" | grep -c .) host(s)"
  else fail "egress-$m-well-formed" "${RM_BAD:-no lines}"; fi
done
case "$( ( . "$RM_LIB" >/dev/null 2>&1; . "$RM_MOD" >/dev/null 2>&1; egress_rewrite_model ) 2>/dev/null)" in
  *ollama.com\ *) fail "egress-rewrite-model-no-ollama-com" ;; *) pass "egress-rewrite-model-no-ollama-com" ;; esac

# 8. voiceink: the admin-bound Xcode step comes before cmake, and a standard user is told who can do it.
vi_call() {
  ( export HOME="$1" BOOTSTRAP_STATE_DIR="$1/.mac-bootstrap"; shift
    unset BOOTSTRAP_LOG
    . "$RM_LIB" >/dev/null 2>&1; . "$VI_MOD" >/dev/null 2>&1
    voiceink_xcodebuild_probe() { printf 'You have not agreed to the Xcode license agreements'; return 1; }
    voiceink_cmake() { return 1; }
    voiceink_identity_cn() { printf 'VoiceInk Local'; }
    "$@" )
}
h="$(fresh_home vi-gates)"
same "voiceink-licence-before-cmake" "$(vi_call "$h" voiceink_blockers | tr '\n' ' ')" "license cmake "
case "$(BOOTSTRAP_ASSUME_STANDARD_USER=1 vi_call "$h" note_voiceink)" in
  *administrator*) pass "voiceink-standard-user-licence-names-admin" ;; *) fail "voiceink-standard-user-licence-names-admin" ;; esac
same "voiceink-standard-user-no-sudo-gesture" "$(BOOTSTRAP_ASSUME_STANDARD_USER=1 vi_call "$h" gesture_voiceink)" ""
if vi_call "$h" bootstrap_is_admin; then
  same "voiceink-admin-licence-gesture" "$(vi_call "$h" gesture_voiceink)" "sudo xcodebuild -license accept"
else
  pass "voiceink-admin-licence-gesture" "n/a: this account is not an administrator"
fi

# 9. voiceink: announcements go off beside Sparkle, and never from a sandbox that would hit the real domain.
h="$(fresh_home vi-announce)"
VI_FX="$RM_DIR/voiceink-announce.plist"; rm -f "$VI_FX"; plutil -create xml1 "$VI_FX"
( export HOME="$h" BOOTSTRAP_STATE_DIR="$h/.mac-bootstrap" BOOTSTRAP_VOICEINK_DOMAIN="$VI_FX"; unset BOOTSTRAP_LOG BOOTSTRAP_ALLOW_FOREIGN_DEFAULTS
  . "$RM_LIB" >/dev/null 2>&1; . "$VI_MOD" >/dev/null 2>&1; voiceink_sparkle_off ) >/dev/null 2>&1
same "voiceink-sandbox-refuses-defaults-rc" "$?" 1
same "voiceink-sandbox-wrote-nothing" "$(json_at "$VI_FX" enableAnnouncements || printf absent)" absent
( export HOME="$h" BOOTSTRAP_STATE_DIR="$h/.mac-bootstrap" BOOTSTRAP_VOICEINK_DOMAIN="$VI_FX" BOOTSTRAP_ALLOW_FOREIGN_DEFAULTS=1; unset BOOTSTRAP_LOG
  . "$RM_LIB" >/dev/null 2>&1; . "$VI_MOD" >/dev/null 2>&1; voiceink_sparkle_off ) >/dev/null 2>&1
same "voiceink-announcements-off" "$(json_at "$VI_FX" enableAnnouncements)/$(json_at "$VI_FX" SUEnableAutomaticChecks)" "false/false"

# 10. The pinned route: fetched from a file:// fixture, hash-checked, linked, and undone — and a refused
# hash is a FETCH gate for this run only, with no Homebrew offered to a standard user.
mkdir -p "$RM_DIR/tgz"
printf '#!/bin/bash\n[ "${1:-}" = --version ] && printf "Warning: client version is 0.34.0\\n"\nexit 0\n' > "$RM_DIR/tgz/ollama"
chmod +x "$RM_DIR/tgz/ollama"
tar -czf "$RM_DIR/fake-ollama.tgz" -C "$RM_DIR/tgz" ollama
RM_FAKE_SHA="$(shasum -a 256 "$RM_DIR/fake-ollama.tgz" | cut -d' ' -f1)"
rm_pin() { REWRITE_MODEL_OLLAMA_TARBALL="file://$RM_DIR/fake-ollama.tgz"; REWRITE_MODEL_OLLAMA_SHA256="${RM_PIN_SHA:-$RM_FAKE_SHA}"; "$@"; }
h="$(fresh_home rm-pinned)"; rm_api
mkdir -p "$h/.mac-bootstrap/tools/bin"; printf 'not ours\n' > "$h/.mac-bootstrap/tools/bin/someone-elses-tool"
rm_call "$h" rm_pin rewrite_model_fetch_ollama >/dev/null 2>&1; same "pinned-fetch-rc" "$?" 0
same "pinned-fetch-is-found-first" "$( (unset BOOTSTRAP_REWRITE_MODEL_OLLAMA; RM_OLLAMA=""; export RM_OLLAMA; HOME="$h" BOOTSTRAP_STATE_DIR="$h/.mac-bootstrap"; export HOME BOOTSTRAP_STATE_DIR; . "$RM_LIB" >/dev/null 2>&1; bootstrap_find_tool ollama) 2>/dev/null)" "$h/.mac-bootstrap/tools/bin/ollama"
( RM_OLLAMA="$h/.mac-bootstrap/tools/bin/ollama"; export RM_OLLAMA; rm_call "$h" uninstall_rewrite_model ) >/dev/null 2>&1
if [ -e "$h/.mac-bootstrap/tools/bin/ollama" ] || [ -e "$h/.mac-bootstrap/tools/ollama-0.34.0" ]; then fail "uninstall-removes-the-pinned-copy"; else pass "uninstall-removes-the-pinned-copy"; fi
if [ -f "$h/.mac-bootstrap/tools/bin/someone-elses-tool" ]; then pass "uninstall-keeps-other-tools"; else fail "uninstall-keeps-other-tools"; fi

h="$(fresh_home rm-fetch-refused)"
( RM_PIN_SHA=0000000000000000000000000000000000000000000000000000000000000000; RM_OLLAMA="$RM_DIR/no-ollama"; export RM_PIN_SHA RM_OLLAMA
  rm_call "$h" rm_pin rewrite_model_fetch_ollama ) >/dev/null 2>&1
same "pinned-hash-refused-rc" "$?" 2
if [ -e "$h/.mac-bootstrap/tools/ollama-0.34.0" ] || [ -e "$h/.mac-bootstrap/tools/ollama-0.34.0-darwin.tgz" ]; then fail "pinned-hash-refused-keeps-nothing"; else pass "pinned-hash-refused-keeps-nothing"; fi
rm_std() { BOOTSTRAP_ASSUME_STANDARD_USER=1; BOOTSTRAP_REWRITE_MODEL_BREW="$RM_DIR/no-brew"; REWRITE_MODEL_BREW_SEAM="$RM_DIR/no-brew"; export BOOTSTRAP_ASSUME_STANDARD_USER; "$@"; }
RM_OLLAMA="$RM_DIR/no-ollama" rm_call "$h" rm_std rewrite_model_pending >"$RM_DIR/pending" 2>/dev/null
same "fetch-refusal-gates-this-run" "$(cat "$RM_DIR/pending")" FETCH
case "$(RM_OLLAMA="$RM_DIR/no-ollama" rm_call "$h" rm_std note_rewrite_model 2>/dev/null)" in
  *sha256*IT*) pass "fetch-note-names-the-hash-and-it" ;; *) fail "fetch-note-names-the-hash-and-it" ;; esac
same "fetch-standard-user-no-homebrew-gesture" "$(RM_OLLAMA="$RM_DIR/no-ollama" rm_call "$h" rm_std gesture_rewrite_model 2>/dev/null)" ""
sed -i '' 's/^pid=.*/pid=1/' "$h/.mac-bootstrap/rewrite-model-fetch-failed"
same "fetch-refusal-from-another-run-retries" "$(RM_OLLAMA="$RM_DIR/no-ollama" rm_call "$h" rm_std rewrite_model_pending 2>/dev/null)" NONE

# 11. A server this module cannot restart, still cloud-on after server.json says off, is the human's.
h="$(fresh_home rm-cloud-gate)"; rm_api; rm_fx "[$RM_MODE_OLLAMA]"
rm_nolabel() { REWRITE_MODEL_SERVER_LABELS=com.example.no-such-job; "$@"; }
same "cloud-gate-waits-for-server-json" "$(rm_call "$h" rm_nolabel rewrite_model_pending 2>/dev/null)" NONE
rm_call "$h" rewrite_model_cloud_off_write >/dev/null 2>&1
same "cloud-gate-server-already-off" "$(rm_call "$h" rm_nolabel rewrite_model_pending 2>/dev/null)" NONE
printf '{"cloud":{"disabled":false,"source":"none"}}' > "$RM_DIR/api/status.json"
same "cloud-gate-unmanaged-server-on" "$(rm_call "$h" rm_nolabel rewrite_model_pending 2>/dev/null)" CLOUD
rm_call "$h" rm_nolabel gate_rewrite_model; same "cloud-gate-is-needs-human" "$?" 0

# The second reader: a SAVED cloud key alone — no mode naming it — must stop rewrite_model reading as
# local, because the fork build falls back to any connected provider. The per-mode proof cannot see it;
# assets/local-only-check.sh can. Fixture domain only: the real VoiceInk preferences are never read here.
RM_FX="$CHECK_TMP/rm-voiceink-fixture"
plutil -create xml1 "$RM_FX.plist" 2>/dev/null || printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict/></plist>\n' > "$RM_FX.plist"
RM_CLEAN="$( ( . "$CHECK_ROOT/assets/hooks/bootstrap-lib.sh"; . "$CHECK_ROOT/modules/rewrite_model.sh"
               BOOTSTRAP_ASSETS="$CHECK_ROOT/assets" BOOTSTRAP_REWRITE_MODEL_DOMAIN="$RM_FX" rewrite_model_local_only >/dev/null; echo $? ) 2>/dev/null)"
plutil -insert LocalKeychain_geminiAPIKey -data AA== "$RM_FX.plist" 2>/dev/null
RM_KEYED="$( ( . "$CHECK_ROOT/assets/hooks/bootstrap-lib.sh"; . "$CHECK_ROOT/modules/rewrite_model.sh"
               BOOTSTRAP_ASSETS="$CHECK_ROOT/assets" BOOTSTRAP_REWRITE_MODEL_DOMAIN="$RM_FX" rewrite_model_local_only ) 2>/dev/null)"
same "rewrite-model-second-reader-clean-fixture" "$RM_CLEAN" 0
case "$RM_KEYED" in *Gemini*) pass "rewrite-model-second-reader-sees-a-saved-key" ;;
  *) fail "rewrite-model-second-reader-sees-a-saved-key" "${RM_KEYED:-no FAIL line}" ;; esac

# 12. What IT governs: every clearance_ line is `<class> <clause>`, the class from the fixed set. ──
RM_CLEARANCE_CLASSES='data background trust permission software agent'
rm_clearance_bad() {                                  # prints every line that is not well formed
  printf '%s\n' "$1" | awk -v ok="$RM_CLEARANCE_CLASSES" '
    BEGIN { n = split(ok, a, " "); for (i = 1; i <= n; i++) c[a[i]] = 1 }
    NF == 0 { next }
    !($1 in c) || NF < 3 { print }'
}
same "clearance-check-catches-an-invented-class" "$(rm_clearance_bad 'telemetry it phones home')" 'telemetry it phones home'
same "clearance-check-catches-a-bare-class" "$(rm_clearance_bad 'trust')" 'trust'
h="$(fresh_home rm-clearance)"
RM_CL="$(rm_call "$h" clearance_rewrite_model 2>/dev/null)"
if [ -n "$RM_CL" ] && [ -z "$(rm_clearance_bad "$RM_CL")" ]; then pass "clearance-rewrite-model-well-formed" "$(printf '%s\n' "$RM_CL" | grep -c .) line(s)"
else fail "clearance-rewrite-model-well-formed" "${RM_CL:-no lines}"; fi
case "$RM_CL" in
  *"background "*"127.0.0.1:11434"*com.mac-bootstrap.ollama*"brew services start ollama"*) pass "clearance-rewrite-model-names-both-servers" ;;
  *) fail "clearance-rewrite-model-names-both-servers" "$RM_CL" ;;
esac
case "$RM_CL" in *software*) fail "clearance-rewrite-model-present-installs-nothing" "$RM_CL" ;; *) pass "clearance-rewrite-model-present-installs-nothing" ;; esac
RM_CL="$(RM_OLLAMA="$RM_DIR/no-ollama" rm_call "$h" rm_std clearance_rewrite_model 2>/dev/null)"
case "$RM_CL" in *"software the ollama server"*3MU9H2V9Y9*) pass "clearance-rewrite-model-pinned-names-software" ;; *) fail "clearance-rewrite-model-pinned-names-software" "$RM_CL" ;; esac
RM_CL="$( ( . "$RM_LIB" >/dev/null 2>&1; . "$VI_MOD" >/dev/null 2>&1; clearance_voiceink ) 2>/dev/null)"
if [ -n "$RM_CL" ] && [ -z "$(rm_clearance_bad "$RM_CL")" ]; then pass "clearance-voiceink-well-formed" "$(printf '%s\n' "$RM_CL" | grep -c .) line(s)"
else fail "clearance-voiceink-well-formed" "${RM_CL:-no lines}"; fi
case "$RM_CL" in
  *"trust "*"import -A"*add-trusted-cert*"trust "*"xattr -cr"*) pass "clearance-voiceink-names-both-trust-changes" ;;
  *) fail "clearance-voiceink-names-both-trust-changes" "$RM_CL" ;;
esac
case "$RM_CL" in *"permission Microphone"*Accessibility*) pass "clearance-voiceink-names-permissions" ;; *) fail "clearance-voiceink-names-permissions" "$RM_CL" ;; esac

# 13. What a person reads BEFORE choosing names the server, the port, and the keychain trust. ──────
case "$(rm_call "$h" cost_rewrite_model 2>/dev/null)" in *"stays running from login"*127.0.0.1:11434*) pass "cost-rewrite-model-names-server-and-port" ;;
  *) fail "cost-rewrite-model-names-server-and-port" "$(rm_call "$h" cost_rewrite_model 2>/dev/null)" ;; esac
case "$( ( . "$RM_LIB" >/dev/null 2>&1; . "$VI_MOD" >/dev/null 2>&1; cost_voiceink ) 2>/dev/null)" in *"mark trusted"*EDR*IT*) pass "cost-voiceink-names-keychain-trust" ;;
  *) fail "cost-voiceink-names-keychain-trust" ;; esac

# …and uninstall says so when it leaves Homebrew's ollama service running, with the one command.
rm_fake_brew() {                                      # rm_fake_brew <name> <ollama status>
  mkdir -p "$RM_DIR/$1/bin" "$RM_DIR/$1/Cellar"
  printf '#!/bin/bash\n[ "$1 $2" = "services list" ] && printf "Name   Status  User File\\nollama %s  me   ~/Library/LaunchAgents/homebrew.mxcl.ollama.plist\\n"\nexit 0\n' "$2" > "$RM_DIR/$1/bin/brew"
  chmod +x "$RM_DIR/$1/bin/brew"
}
rm_fake_brew brew-started started; rm_fake_brew brew-none none
h="$(fresh_home rm-uninstall-brew)"; rm_api
RM_OUT="$(BOOTSTRAP_REWRITE_MODEL_BREW="$RM_DIR/brew-started/bin/brew" rm_call "$h" uninstall_rewrite_model 2>&1)"
case "$RM_OUT" in *"still running"*"brew services stop ollama"*) pass "uninstall-names-the-homebrew-service" ;; *) fail "uninstall-names-the-homebrew-service" "$RM_OUT" ;; esac
same "uninstall-stop-command-on-its-own-line" "$(printf '%s\n' "$RM_OUT" | grep -c '^brew services stop ollama$')" 1
RM_OUT="$(BOOTSTRAP_REWRITE_MODEL_BREW="$RM_DIR/brew-none/bin/brew" rm_call "$h" uninstall_rewrite_model 2>&1)"
case "$RM_OUT" in *"brew services stop"*) fail "uninstall-silent-when-no-homebrew-service" "$RM_OUT" ;; *) pass "uninstall-silent-when-no-homebrew-service" ;; esac

# 14. A verified ollama this Mac refuses to EXECUTE (Santa) is NEEDS_HUMAN naming IT, never FAILED. ─
# The fixture is a malformed Mach-O the kernel really refuses (measured rc 137) — not a script that
# pretends to, so the classification is tested against the kernel's own answer.
mkdir -p "$RM_DIR/refused"
printf '\317\372\355\376\007\000\000\001\003\000\000\000\002\000\000\000' > "$RM_DIR/refused/ollama"; chmod +x "$RM_DIR/refused/ollama"
tar -czf "$RM_DIR/refused-ollama.tgz" -C "$RM_DIR/refused" ollama
h="$(fresh_home rm-refused)"
( RM_PIN_SHA="$(shasum -a 256 "$RM_DIR/refused-ollama.tgz" | cut -d' ' -f1)"; RM_OLLAMA="$RM_DIR/no-ollama"; export RM_PIN_SHA RM_OLLAMA
  rm_refused_pin() { REWRITE_MODEL_OLLAMA_TARBALL="file://$RM_DIR/refused-ollama.tgz"; REWRITE_MODEL_OLLAMA_SHA256="$RM_PIN_SHA"; "$@"; }
  rm_call "$h" rm_refused_pin rewrite_model_fetch_ollama ) >/dev/null 2>&1
same "refused-exec-fetch-rc" "$?" 4
if [ -x "$h/.mac-bootstrap/tools/ollama-0.34.0/ollama" ]; then pass "refused-exec-keeps-the-verified-copy"; else fail "refused-exec-keeps-the-verified-copy"; fi
same "refused-exec-gates-as-refused" "$(rm_call "$h" rm_std rewrite_model_pending 2>/dev/null)" REFUSED
rm_call "$h" rm_std gate_rewrite_model; same "refused-exec-is-needs-human" "$?" 0
case "$(rm_call "$h" rm_std note_rewrite_model 2>/dev/null)" in
  *"refused to execute"*"sha256 checked"*"Ask IT to allow"*) pass "refused-exec-note-asks-it" ;;
  *) fail "refused-exec-note-asks-it" "$(rm_call "$h" rm_std note_rewrite_model 2>/dev/null)" ;; esac
same "refused-exec-no-gesture" "$(rm_call "$h" rm_std gesture_rewrite_model 2>/dev/null)" ""
# the same on an ollama that was already on disk, through install_'s own execute-to-verify
h="$(fresh_home rm-refused-present)"
( BOOTSTRAP_MODEL=qwen3:8b; RM_OLLAMA="$RM_DIR/refused/ollama"; export BOOTSTRAP_MODEL RM_OLLAMA; rm_call "$h" install_rewrite_model ) >/dev/null 2>&1
same "refused-exec-present-gates-as-refused" "$(RM_OLLAMA="$RM_DIR/refused/ollama" rm_call "$h" rewrite_model_pending 2>/dev/null)" REFUSED
case "$(RM_OLLAMA="$RM_DIR/refused/ollama" rm_call "$h" note_rewrite_model 2>/dev/null)" in
  *"already on this Mac"*"Ask IT to allow"*) pass "refused-exec-present-note-asks-it" ;; *) fail "refused-exec-present-note-asks-it" ;; esac
# control: a binary that RUNS and fails is not a refusal
h="$(fresh_home rm-broken-not-refused)"
( BOOTSTRAP_MODEL=qwen3:8b; RM_OLLAMA="$RM_DIR/bin/ollama-broken"; export BOOTSTRAP_MODEL RM_OLLAMA; rm_call "$h" install_rewrite_model ) >/dev/null 2>&1
case "$(RM_OLLAMA="$RM_DIR/bin/ollama-broken" rm_call "$h" rewrite_model_pending 2>/dev/null)" in REFUSED) fail "broken-ollama-is-not-a-refusal" ;; *) pass "broken-ollama-is-not-a-refusal" ;; esac

# 15. voiceink is pinned by COMMIT beside its tag, and a moved tag is refused. A local git fixture, no network.
vi_pin() { ( . "$RM_LIB" >/dev/null 2>&1; unset BOOTSTRAP_VOICEINK_COMMIT; [ -n "${1:-}" ] && BOOTSTRAP_VOICEINK_TAG="$1"; . "$VI_MOD" >/dev/null 2>&1; printf '%s' "$BOOTSTRAP_VOICEINK_COMMIT" ) 2>/dev/null; }
same "voiceink-default-tag-pins-its-commit" "$(vi_pin)" 68b871e79e2b1ec4c3b4914cccd2e0907d94237a
same "voiceink-other-tag-carries-no-pin" "$(vi_pin v2.14)" ""
case "$( ( . "$RM_LIB" >/dev/null 2>&1; . "$VI_MOD" >/dev/null 2>&1; printf '%s' "$BOOTSTRAP_VOICEINK_WHISPER_URL" ) 2>/dev/null)" in
  https://github.com/ggml-org/whisper.cpp.git) pass "voiceink-whisper-at-its-current-home" ;; *) fail "voiceink-whisper-at-its-current-home" ;; esac
VI_UP="$RM_DIR/voiceink-upstream"; rm -rf "$VI_UP"; mkdir -p "$VI_UP"
( cd "$VI_UP" && git init -q && git -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m one \
  && git -c user.name=t -c user.email=t@example.invalid tag -a v2.13 -m v2.13 ) >/dev/null 2>&1
VI_SHA="$(git -C "$VI_UP" rev-parse 'v2.13^{commit}' 2>/dev/null)"
vi_fetch() {                                          # vi_fetch <home> <pinned commit>
  ( export HOME="$1" BOOTSTRAP_STATE_DIR="$1/.mac-bootstrap" BOOTSTRAP_VOICEINK_UPSTREAM="file://$VI_UP" \
           BOOTSTRAP_VOICEINK_SRC="$1/voiceink-src" BOOTSTRAP_VOICEINK_COMMIT="$2"; unset BOOTSTRAP_LOG
    . "$RM_LIB" >/dev/null 2>&1; . "$VI_MOD" >/dev/null 2>&1; voiceink_fetch_source ) 2>&1
}
h="$(fresh_home vi-pin-ok)"; out="$(vi_fetch "$h" "$VI_SHA")"
same "voiceink-pinned-commit-checks-out" "$?" 0
h="$(fresh_home vi-pin-moved)"; out="$(vi_fetch "$h" 0000000000000000000000000000000000000000)"; rc=$?
case "$rc/$out" in 1/*"was moved upstream"*) pass "voiceink-moved-tag-refused" ;; *) fail "voiceink-moved-tag-refused" "rc $rc: $out" ;; esac
