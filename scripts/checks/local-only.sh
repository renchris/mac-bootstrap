# shellcheck shell=bash
# scripts/checks/local-only.sh — assets/local-only-check.sh, the read-only "does anything send local
# data to a cloud AI service" check. Sourced by scripts/characterize.sh, which supplies the harness;
# never run on its own.
#
# Every fixture lives under $CHECK_TMP and every run is `env -i` with a sandbox HOME, so nothing
# here reads the developer's VoiceInk, keychain, Ollama or agent config. The seams point the check
# at fixtures and it reads them through the same code path it uses on a real Mac: a plist PATH as
# the defaults domain, a file:// Ollama, and a stub `security` that answers by exit code. Fixture
# plists are written as XML files, never through cfprefsd, and each fixture gets its own path
# because cfprefsd caches a domain it has read.
#
# The real throwaway-keychain arm is not run: `security create-keychain` adds the keychain to the
# user's search list, which this harness will not touch. The stub covers the exit-code logic, and
# the real login keychain answering 44 for every VoiceInk account covers the absent path.

LOCAL_ONLY_SCRIPT="$CHECK_ROOT/assets/local-only-check.sh"
LOCAL_ONLY_FX="$CHECK_TMP/local-only"
LOCAL_ONLY_HOME="$(fresh_home local-only)"
mkdir -p "$LOCAL_ONLY_FX/iterm-secure"

# ── fixture writers ──────────────────────────────────────────────────────────────────────────
local_only_plist() {                            # local_only_plist <path-without-.plist> <xml entries>
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n%s\n<key>fixture</key><true/>\n</dict>\n</plist>\n' "$2" > "$1.plist"
}
local_only_data() { printf '<key>%s</key><data>%s</data>' "$1" "$(printf '%s' "$2" | /usr/bin/base64)"; }
local_only_string() { printf '<key>%s</key><string>%s</string>' "$1" "$2"; }
local_only_mode() {                             # local_only_mode <name> <enabled> <enhance> <provider> <model>
  printf '{"name":"%s","isEnabled":%s,"isAIEnhancementEnabled":%s,"selectedAIProvider":"%s","selectedAIModel":"%s","isDefault":false}' \
    "$1" "$2" "$3" "$4" "$5"
}
local_only_ollama() {                           # local_only_ollama <dir> <cloud-disabled> <tags json>
  mkdir -p "$1/api"
  printf '{"version":"0.33.3"}' > "$1/api/version"
  printf '{"cloud":{"disabled":%s,"source":"config"}}' "$2" > "$1/api/status"
  printf '%s' "$3" > "$1/api/tags"
}

# the app bundle: a local build carries the .Local keychain service literal (research §3, the build-shape fingerprint)
mkdir -p "$LOCAL_ONLY_FX/app/VoiceInk.app/Contents/MacOS" "$LOCAL_ONLY_FX/unknown/VoiceInk.app/Contents/MacOS"
printf 'stub\0com.prakashjoshipax.VoiceInk.Local\0stub' > "$LOCAL_ONLY_FX/app/VoiceInk.app/Contents/MacOS/VoiceInk"
printf 'stub with neither literal' > "$LOCAL_ONLY_FX/unknown/VoiceInk.app/Contents/MacOS/VoiceInk"

# the stub `security`: exit 0 for an account listed in security-present (under the .Local service),
# else the rc in security-rc (default 44), and it logs its arguments so the keychain seam is visible
cat > "$LOCAL_ONLY_FX/security" <<'LOCAL_ONLY_STUB_EOF'
#!/bin/bash
here="$(dirname "$0")"
printf '%s\n' "$*" >> "$here/security-args"
svc=""; acct=""
while [ $# -gt 0 ]; do case "$1" in -s) svc="$2"; shift ;; -a) acct="$2"; shift ;; esac; shift; done
[ "$svc" = com.prakashjoshipax.VoiceInk.Local ] && /usr/bin/grep -qx "$acct" "$here/security-present" 2>/dev/null && exit 0
exit "$(cat "$here/security-rc" 2>/dev/null || printf 44)"
LOCAL_ONLY_STUB_EOF
chmod +x "$LOCAL_ONLY_FX/security"
: > "$LOCAL_ONLY_FX/security-present"

LOCAL_ONLY_TAGS_LOCAL='{"models":[{"name":"voiceink-rewrite:latest","model":"voiceink-rewrite:latest","size":5225387842,"details":{"parent_model":"qwen3:8b"}}]}'
LOCAL_ONLY_TAGS_REMOTE='{"models":[{"name":"voiceink-rewrite:latest","size":5225387842},{"name":"vr-test:latest","remote_model":"gpt-oss:120b","remote_host":"https://ollama.com:443","size":231}]}'
local_only_ollama "$LOCAL_ONLY_FX/ollama-clean" true "$LOCAL_ONLY_TAGS_LOCAL"
local_only_ollama "$LOCAL_ONLY_FX/ollama-cloud-on" false "$LOCAL_ONLY_TAGS_LOCAL"
local_only_ollama "$LOCAL_ONLY_FX/ollama-remote" true "$LOCAL_ONLY_TAGS_REMOTE"

LOCAL_ONLY_MODE_LOCAL="[$(local_only_mode Dictate true true Ollama voiceink-rewrite)]"
local_only_plist "$LOCAL_ONLY_FX/voiceink-clean" \
  "$(local_only_data modeConfigurationsV2 "$LOCAL_ONLY_MODE_LOCAL")<key>enableAnnouncements</key><false/>"
local_only_plist "$LOCAL_ONLY_FX/iterm-clean" "$(local_only_string Columns 80)"

# ── the runner: env -i, sandbox HOME, every seam on a fixture ────────────────────────────────
LOCAL_ONLY_DOMAIN="$LOCAL_ONLY_FX/voiceink-clean"
LOCAL_ONLY_APP="$LOCAL_ONLY_FX/app/VoiceInk.app"
LOCAL_ONLY_OLLAMA="file://$LOCAL_ONLY_FX/ollama-clean"
LOCAL_ONLY_ITERM="$LOCAL_ONLY_FX/iterm-clean"
LOCAL_ONLY_EXTRA=""
LOCAL_ONLY_OUT=""
LOCAL_ONLY_ERR=""
LOCAL_ONLY_RC=0
local_only_run() {                              # local_only_run <check args...> → LOCAL_ONLY_{RC,OUT,ERR}
  LOCAL_ONLY_OUT="$(env -i HOME="$LOCAL_ONLY_HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="$CHECK_WORK" \
      LOCAL_ONLY_VOICEINK_DOMAIN="$LOCAL_ONLY_DOMAIN" LOCAL_ONLY_VOICEINK_APP="$LOCAL_ONLY_APP" \
      LOCAL_ONLY_SECURITY_CLI="$LOCAL_ONLY_FX/security" LOCAL_ONLY_OLLAMA_URL="$LOCAL_ONLY_OLLAMA" \
      LOCAL_ONLY_ITERM_DOMAIN="$LOCAL_ONLY_ITERM" LOCAL_ONLY_ITERM_SECURE_DIR="$LOCAL_ONLY_FX/iterm-secure" \
      ${LOCAL_ONLY_EXTRA:+"$LOCAL_ONLY_EXTRA"} \
      /bin/bash "$LOCAL_ONLY_SCRIPT" "$@" 2>"$CHECK_WORK/local-only.err")"
  LOCAL_ONLY_RC=$?
  LOCAL_ONLY_ERR="$(cat "$CHECK_WORK/local-only.err" 2>/dev/null)"
  return 0
}
local_only_lines() { printf '%s\n' "$LOCAL_ONLY_OUT" | /usr/bin/grep -cE "$1" | tr -d ' '; }
local_only_has() {                              # local_only_has <check name> <ERE> <what it proves>
  if [ "$(local_only_lines "$2")" -ge 1 ]; then pass "$1" "$3"
  else fail "$1" "no line matching /$2/ — got: $(printf '%s' "$LOCAL_ONLY_OUT" | head -4 | tr '\n' '|')"; fi
}

# ── 1. a clean Mac: VoiceInk on Ollama, no key, Ollama cloud off, no remote model → exit 0 ──
LOCAL_ONLY_SUM0="$(shasum -a 256 "$LOCAL_ONLY_DOMAIN.plist" | cut -d' ' -f1)"
local_only_run
same "local-only-clean-rc" "$LOCAL_ONLY_RC" 0
same "local-only-clean-has-no-fail" "$(local_only_lines '^    FAIL  ')" 0
local_only_has "local-only-clean-voiceink-ok" '^    ok    VoiceInk — 1 enabled mode' "the mode on Ollama reads as local"
local_only_has "local-only-clean-ollama-ok" '^    ok    Ollama cloud — disabled' "a server with cloud off reads as local"
local_only_has "local-only-fixture-skips-listener" '^    n/a   Ollama listener — fixture' "no socket to read for a file:// server"
# every line is one of the four shapes, with a subject and a detail
same "local-only-line-shape" "$(printf '%s\n' "$LOCAL_ONLY_OUT" | /usr/bin/grep -cvE '^    (ok    |FAIL  |warn  |n/a   )[^ ].* — .')" 0
same "local-only-clean-stderr-empty" "$LOCAL_ONLY_ERR" ""
same "local-only-reads-only" "$(shasum -a 256 "$LOCAL_ONLY_DOMAIN.plist" | cut -d' ' -f1)" "$LOCAL_ONLY_SUM0"
same "local-only-writes-nothing-in-home" "$(find "$LOCAL_ONLY_HOME" -mindepth 1 | head -3)" ""

# ── 2. NEGATIVE CONTROL: plant a Gemini mode and a Gemini key → it must say no ────────────────
# The key's bytes must appear nowhere in the output, in any encoding.
LOCAL_ONLY_PLANT="PLANTED-GEMINI-KEY-9d41c7"
LOCAL_ONLY_PLANT_B64="$(printf '%s' "$LOCAL_ONLY_PLANT" | /usr/bin/base64)"
LOCAL_ONLY_PLANT_HEX="$(printf '%s' "$LOCAL_ONLY_PLANT" | /usr/bin/xxd -p | tr -d '\n')"
local_only_plist "$LOCAL_ONLY_FX/voiceink-gemini" \
  "$(local_only_data LocalKeychain_geminiAPIKey "$LOCAL_ONLY_PLANT")$(local_only_data modeConfigurationsV2 \
    "[$(local_only_mode Email true true Gemini gemini-2.5-flash),$(local_only_mode Spare false true Gemini gemini-2.5-flash)]")"
LOCAL_ONLY_DOMAIN="$LOCAL_ONLY_FX/voiceink-gemini"
local_only_run
same "local-only-gemini-rc" "$LOCAL_ONLY_RC" 1
local_only_has "local-only-gemini-mode-fails" '^    FAIL  VoiceInk mode "Email" — rewrites through Gemini' "the planted mode is named, with its provider"
local_only_has "local-only-gemini-key-fails" '^    FAIL  VoiceInk keys — .*Gemini' "the planted key is named by provider"
local_only_has "local-only-disabled-mode-warns" '^    warn  VoiceInk mode "Spare" \(disabled\)' "a disabled mode is latent, not live"
case "$LOCAL_ONLY_OUT$LOCAL_ONLY_ERR" in
  *"$LOCAL_ONLY_PLANT"*|*"$LOCAL_ONLY_PLANT_B64"*|*"$LOCAL_ONLY_PLANT_HEX"*|*9d41c7*) fail "local-only-never-prints-a-key" "planted bytes reached the output" ;;
  *) pass "local-only-never-prints-a-key" "planted bytes absent in raw, base64 and hex" ;;
esac
local_only_run --quiet
same "local-only-quiet-prints-only-fail" "$(printf '%s\n' "$LOCAL_ONLY_OUT" | /usr/bin/grep -cv '^    FAIL  ')" 0
same "local-only-quiet-keeps-the-rc" "$LOCAL_ONLY_RC" 1

# ── 3. a key with every mode local is still a live path (research §6 CLOUD_POSSIBLE) ─────────
local_only_plist "$LOCAL_ONLY_FX/voiceink-keyonly" \
  "$(local_only_data LocalKeychain_geminiAPIKey x)$(local_only_data modeConfigurationsV2 "$LOCAL_ONLY_MODE_LOCAL")"
LOCAL_ONLY_DOMAIN="$LOCAL_ONLY_FX/voiceink-keyonly"
local_only_run --only voiceink
same "local-only-key-only-rc" "$LOCAL_ONLY_RC" 1
local_only_has "local-only-key-only-fails" '^    FAIL  VoiceInk keys — .*Gemini' "the key alone fails the check"
same "local-only-key-only-mode-stays-local" "$(local_only_lines '^    FAIL  VoiceInk mode')" 0

# ── 4. the keychain arm, through the stub: present, then a keychain that will not answer ─────
LOCAL_ONLY_DOMAIN="$LOCAL_ONLY_FX/voiceink-clean"
LOCAL_ONLY_EXTRA="LOCAL_ONLY_KEYCHAIN=$LOCAL_ONLY_FX/fixture.keychain-db"
printf 'geminiAPIKey\n' > "$LOCAL_ONLY_FX/security-present"
: > "$LOCAL_ONLY_FX/security-args"
local_only_run --only voiceink
same "local-only-keychain-key-rc" "$LOCAL_ONLY_RC" 1
local_only_has "local-only-keychain-key-fails" '^    FAIL  VoiceInk keys — .*Gemini' "a keychain item under the .Local service is found by rc"
if /usr/bin/grep -q " geminiAPIKey $LOCAL_ONLY_FX/fixture.keychain-db\$" "$LOCAL_ONLY_FX/security-args" \
   && ! /usr/bin/grep -qE '(^| )-(w|g)( |$)' "$LOCAL_ONLY_FX/security-args"; then
  pass "local-only-keychain-seam-and-no-secret-flag" "the keychain is the trailing argument; -w/-g never passed"
else
  fail "local-only-keychain-seam-and-no-secret-flag" "$(head -2 "$LOCAL_ONLY_FX/security-args" | tr '\n' '|')"
fi
: > "$LOCAL_ONLY_FX/security-present"
printf '51\n' > "$LOCAL_ONLY_FX/security-rc"
local_only_run --only voiceink
same "local-only-keychain-refusal-rc" "$LOCAL_ONLY_RC" 1
local_only_has "local-only-keychain-refusal-fails-closed" '^    FAIL  VoiceInk keys — .*cannot verify' "an rc other than 0/44 is not read as absent"
rm -f "$LOCAL_ONLY_FX/security-rc"
LOCAL_ONLY_EXTRA=""
pass "local-only-real-keychain" "n/a — create-keychain adds to the user's search list; not run (stub + real rc 44 cover it)"

# ── 5. a build whose key store cannot be seen fails closed ────────────────────────────────────
LOCAL_ONLY_APP="$LOCAL_ONLY_FX/unknown/VoiceInk.app"
local_only_run --only voiceink
same "local-only-unknown-build-rc" "$LOCAL_ONLY_RC" 1
local_only_has "local-only-unknown-build-fails-closed" '^    FAIL  VoiceInk build — .*cannot verify' "no fingerprint, no verdict"
LOCAL_ONLY_APP="$LOCAL_ONLY_FX/nowhere/VoiceInk.app"
local_only_run --only voiceink
same "local-only-no-voiceink-rc" "$LOCAL_ONLY_RC" 0
local_only_has "local-only-no-voiceink-na" '^    n/a   VoiceInk — ' "an absent app is not applicable"
LOCAL_ONLY_APP="$LOCAL_ONLY_FX/app/VoiceInk.app"

# ── 6. Ollama: cloud on, a remote model, an off-loopback OLLAMA_HOST ─────────────────────────
LOCAL_ONLY_OLLAMA="file://$LOCAL_ONLY_FX/ollama-cloud-on"
local_only_run --only ollama
same "local-only-ollama-cloud-on-rc" "$LOCAL_ONLY_RC" 1
local_only_has "local-only-ollama-cloud-on-fails" '^    FAIL  Ollama cloud — Ollama can reach ollama\.com' "cloud.disabled=false is a live path"
LOCAL_ONLY_OLLAMA="file://$LOCAL_ONLY_FX/ollama-remote"
local_only_run --only ollama
same "local-only-ollama-remote-rc" "$LOCAL_ONLY_RC" 1
local_only_has "local-only-ollama-remote-fails" '^    FAIL  Ollama model vr-test:latest — .*ollama\.com' "a remote_host model is named"
LOCAL_ONLY_OLLAMA="file://$LOCAL_ONLY_FX/ollama-clean"
LOCAL_ONLY_EXTRA="OLLAMA_HOST=0.0.0.0"
local_only_run --only ollama
same "local-only-ollama-host-rc" "$LOCAL_ONLY_RC" 1
local_only_has "local-only-ollama-host-fails" '^    FAIL  Ollama OLLAMA_HOST \(environment\)' "a non-loopback OLLAMA_HOST is named"
LOCAL_ONLY_EXTRA="LOCAL_ONLY_OLLAMA_URL=http://example.com:11434"
local_only_run --only ollama
local_only_has "local-only-ollama-refuses-remote-server" '^    FAIL  Ollama — .*not contacted' "the check never contacts a non-loopback server"

# ── 7. agents: a Copilot provider pointed at Gemini is the person's choice → warn, exit 0 ────
LOCAL_ONLY_EXTRA="COPILOT_PROVIDER_BASE_URL=https://generativelanguage.googleapis.com/v1beta/openai"
local_only_run --only agents
same "local-only-copilot-gemini-rc" "$LOCAL_ONLY_RC" 0
local_only_has "local-only-copilot-gemini-warns" '^    warn  environment COPILOT_PROVIDER_BASE_URL — generativelanguage\.googleapis\.com' "named by variable and host"
LOCAL_ONLY_EXTRA="COPILOT_PROVIDER_BASE_URL=http://localhost:11434/v1"
local_only_run --only agents
local_only_has "local-only-copilot-loopback-ok" '^    ok    environment COPILOT_PROVIDER_BASE_URL — loopback' "the control: a local provider is fine"
same "local-only-copilot-loopback-no-warn" "$(local_only_lines '^    warn  ')" 0
# a cloud key exported into the environment is reported by NAME, and its value never appears
LOCAL_ONLY_EXTRA="GEMINI_API_KEY=$LOCAL_ONLY_PLANT"
local_only_run --only agents
local_only_has "local-only-env-key-warns" '^    warn  environment GEMINI_API_KEY — ' "an exported cloud key is named"
case "$LOCAL_ONLY_OUT$LOCAL_ONLY_ERR" in
  *"$LOCAL_ONLY_PLANT"*|*9d41c7*) fail "local-only-env-key-value-never-printed" "the planted value reached the output" ;;
  *) pass "local-only-env-key-value-never-printed" ;;
esac
LOCAL_ONLY_EXTRA=""
# a key in Claude's settings env is reported by NAME only
mkdir -p "$LOCAL_ONLY_HOME/.claude"
printf '{"env":{"GEMINI_API_KEY":"%s","ANTHROPIC_BASE_URL":"https://api.anthropic.com"}}\n' "$LOCAL_ONLY_PLANT" > "$LOCAL_ONLY_HOME/.claude/settings.json"
local_only_run --only agents
local_only_has "local-only-claude-env-key-warns" '^    warn  Claude \$HOME/\.claude/settings\.json env GEMINI_API_KEY — ' "a cloud key in Claude's env is named"
local_only_has "local-only-claude-own-vendor-ok" '^    ok    Claude .* ANTHROPIC_BASE_URL — api\.anthropic\.com' "Claude's own vendor in Claude's config is fine"
case "$LOCAL_ONLY_OUT$LOCAL_ONLY_ERR" in
  *"$LOCAL_ONLY_PLANT"*|*9d41c7*) fail "local-only-claude-env-value-never-printed" "the planted value reached the output" ;;
  *) pass "local-only-claude-env-value-never-printed" ;;
esac
rm -rf "$LOCAL_ONLY_HOME/.claude"

# ── 8. apps: an iTerm2 endpoint with a USER-owned enable file is dormant, not live ───────────
local_only_plist "$LOCAL_ONLY_FX/iterm-endpoint" "$(local_only_string AitermURL https://api.openai.com/v1/responses)"
printf 'magic\n%s\n' "$(printf true | /usr/bin/xxd -p)" > "$LOCAL_ONLY_FX/iterm-secure/EnableAI.secureSetting"
LOCAL_ONLY_ITERM="$LOCAL_ONLY_FX/iterm-endpoint"
local_only_run --only apps
same "local-only-iterm-dormant-rc" "$LOCAL_ONLY_RC" 0
local_only_has "local-only-iterm-user-file-ignored" '^    warn  iTerm2 AI — an endpoint is set \(api\.openai\.com\)' "iTerm2 honours only a root-owned enable file"
rm -f "$LOCAL_ONLY_FX/iterm-secure/EnableAI.secureSetting"
LOCAL_ONLY_ITERM="$LOCAL_ONLY_FX/iterm-clean"

# ── 9. arguments ─────────────────────────────────────────────────────────────────────────────
local_only_run --only nonsense
same "local-only-bad-probe-rc" "$LOCAL_ONLY_RC" 2
local_only_run --frobnicate
same "local-only-bad-flag-rc" "$LOCAL_ONLY_RC" 2
same "local-only-bad-flag-stdout-empty" "$LOCAL_ONLY_OUT" ""
