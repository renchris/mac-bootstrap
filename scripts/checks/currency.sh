# shellcheck shell=bash
# scripts/checks/currency.sh — the pin table in scripts/currency.sh. Sourced by scripts/characterize.sh.
#
# No network. The offline listing is read back against what bash itself evaluates from each module,
# the table's coverage of modules/ is checked with a fixture that adds pins it lacks, and the online
# verdicts and exit codes are driven against file:// fixtures of every upstream kind.

if [ -r "$CHECK_ROOT/scripts/currency.sh" ]; then
  CUR="$CHECK_ROOT/scripts/currency.sh"
  # The table's own rows, read out of the script's heredoc — the count the listing is scored against.
  CUR_TABLE="$(sed -n '/^CURRENCY_TABLE_BUILTIN=/,/^CURRENCY_TABLE$/p' "$CUR" | grep -Ev '^(CURRENCY_TABLE|[[:space:]]*#|[[:space:]]*$)')"
  CUR_ROWS="$(printf '%s\n' "$CUR_TABLE" | grep -c '|')"

  CUR_OUT="$(GITHUB_TOKEN='' /bin/bash "$CUR" --offline 2>&1)"; CUR_RC=$?
  same "currency-offline-rc" "$CUR_RC" 0
  true_ "currency-table-has-rows" "$([ "$CUR_ROWS" -gt 0 ] && printf 1)" "$CUR_ROWS row(s)"
  same "currency-offline-lists-every-row" "$(printf '%s\n' "$CUR_OUT" | grep -c ' pinned [^ ?]')" "$CUR_ROWS"

  # Independent read-back: source the module in an empty environment and let bash evaluate the
  # variable; the listed pin must be inside that value (3.7.1 may be spelled 3_7_1 in a URL).
  currency_readback() {  # <root> <table rows> <--offline output> → CUR_BAD (names that disagree), CUR_READ
    CUR_BAD=""; CUR_READ=0
    while IFS='|' read -r CUR_NAME CUR_FILE CUR_VAR _ _; do
      CUR_NAME="$(printf '%s' "$CUR_NAME" | tr -d ' ')"; CUR_FILE="$(printf '%s' "$CUR_FILE" | tr -d ' ')"; CUR_VAR="$(printf '%s' "$CUR_VAR" | tr -d ' ')"
      [ "$CUR_VAR" = - ] && continue
      CUR_PINNED="$(printf '%s\n' "$3" | sed -n "s/^$CUR_NAME pinned //p")"
      CUR_EVAL="$(env -i HOME="$CHECK_TMP/currency-home" PATH=/usr/bin:/bin /bin/bash -c \
        '. "$1" >/dev/null 2>&1 </dev/null; eval "printf %s \"\${$2:-}\""' _ "$1/$CUR_FILE" "$CUR_VAR")"
      CUR_READ=$((CUR_READ + 1))
      case "$CUR_EVAL" in
        *"$CUR_PINNED"*|*"$(printf '%s' "$CUR_PINNED" | tr . _)"*) [ -n "$CUR_PINNED" ] || CUR_BAD="$CUR_BAD $CUR_NAME" ;;
        *) CUR_BAD="$CUR_BAD $CUR_NAME(listed [$CUR_PINNED], bash says [$CUR_EVAL])" ;;
      esac
    done <<EOF
$2
EOF
  }
  currency_readback "$CHECK_ROOT" "$CUR_TABLE" "$CUR_OUT"
  if [ -z "$CUR_BAD" ] && [ "$CUR_READ" -gt 0 ]; then pass "currency-pins-match-what-bash-evaluates" "$CUR_READ variable row(s)"
  else fail "currency-pins-match-what-bash-evaluates" "${CUR_BAD:- no variable rows read}"; fi

  # NEGATIVE CONTROL for the read-back: a module that reassigns its pin, so the first literal the
  # table reads is not the value bash ends up with. The read-back must name it.
  mkdir -p "$CHECK_TMP/currency-reassign/modules"
  printf 'REASSIGNED_VERSION="1.0.0"\nREASSIGNED_VERSION="2.0.0"\n' > "$CHECK_TMP/currency-reassign/modules/reassigned.sh"
  CUR_ROW="reassigned | modules/reassigned.sh | REASSIGNED_VERSION | - | npm:reassigned"
  printf '%s\n' "$CUR_ROW" > "$CHECK_TMP/currency-reassign/table"
  currency_readback "$CHECK_TMP/currency-reassign" "$CUR_ROW" \
    "$(CURRENCY_ROOT="$CHECK_TMP/currency-reassign" CURRENCY_TABLE="$CHECK_TMP/currency-reassign/table" /bin/bash "$CUR" --offline 2>&1)"
  same "currency-read-back-sees-a-disagreement" "$CUR_BAD" " reassigned(listed [1.0.0], bash says [2.0.0])"
  unset -f currency_readback

  # NEGATIVE CONTROL: a row naming a variable its module does not hold is reported, never dropped,
  # and it does not swallow the good row beside it.
  printf '%s\n' "no-such-pin | modules/microsoft365.sh | NO_SUCH_PIN_VARIABLE | - | npm:nothing" \
    "$(printf '%s\n' "$CUR_TABLE" | head -1)" > "$CHECK_TMP/currency-missing.table"
  CUR_OUT="$(CURRENCY_TABLE="$CHECK_TMP/currency-missing.table" /bin/bash "$CUR" --offline 2>&1)"; CUR_RC=$?
  same "currency-missing-pin-is-reported" \
    "$CUR_RC/$(printf '%s\n' "$CUR_OUT" | grep -c '^no-such-pin pinned ? MISSING')/$(printf '%s\n' "$CUR_OUT" | grep -c ' pinned [^ ?]')" "3/1/1"

  # Coverage: every pin-shaped variable in the real modules/ has a row ...
  CUR_OUT="$(/bin/bash "$CUR" --coverage 2>&1)"; CUR_RC=$?
  same "currency-table-covers-every-module-pin" "$CUR_RC" 0
  [ "$CUR_RC" = 0 ] || printf '%s\n' "$CUR_OUT" | head -10

  # ... and the check can say no: a module with two new pins, a floor and a local URL, which are not pins.
  mkdir -p "$CHECK_TMP/currency-tree/modules"
  cat > "$CHECK_TMP/currency-tree/modules/extra_tool.sh" <<'EOF'
EXTRA_TOOL_VERSION="1.2.3"
EXTRA_TOOL_URL='https://example.invalid/downloads/extra-tool-4_5_6.zip'
EXTRA_TOOL_FLOOR=2.0
EXTRA_TOOL_LOCAL_URL="http://localhost:11434"
EOF
  CUR_OUT="$(CURRENCY_ROOT="$CHECK_TMP/currency-tree" /bin/bash "$CUR" --coverage 2>&1)"; CUR_RC=$?
  same "currency-coverage-sees-an-unlisted-pin" "$CUR_RC:$(printf '%s\n' "$CUR_OUT" | grep '^uncovered' | tr '\n' ' ')" \
    "1:uncovered modules/extra_tool.sh EXTRA_TOOL_URL uncovered modules/extra_tool.sh EXTRA_TOOL_VERSION "

  # Online verdicts against file:// upstreams — one row per upstream kind, each with a trap:
  # 0.9.0 vs v0.10.0 must be BEHIND (numeric, not lexical); node-line must stay on the pinned major
  # though a newer major exists; the appcast verdict takes its highest version, not its first.
  CUR_UP="$CHECK_TMP/currency-upstream"; CUR_FIX="$CHECK_TMP/currency-online"
  mkdir -p "$CUR_FIX/modules" "$CUR_UP/npm/-/package/npm-current" "$CUR_UP/npm/-/package/@scope/document-pin" \
    "$CUR_UP/github/repos/owner/github-behind/releases" "$CUR_UP/github/repos/owner/url-capture/releases" \
    "$CUR_UP/github/repos/owner/commit/releases" "$CUR_UP/github/repos/owner/commit/compare"
  cat > "$CUR_FIX/modules/fixture_tool.sh" <<'EOF'
NPM_CURRENT_VERSION="1.2.3"
GITHUB_BEHIND_VERSION=0.9.0
URL_CAPTURE_URL='https://example.invalid/download/v2.0.0/tool.zip'
COMMIT_PIN="${COMMIT_PIN:-0123456789abcdef0123456789abcdef01234567}"   # a pinned commit
NODE_LINE_VERSION="24.1.0"
APPCAST_URL='https://example.invalid/Appcast-3_7_2.zip'
EOF
  printf 'Works with **Document CLI 3.4.5** today.\n' > "$CUR_FIX/README.md"
  printf '{"latest":"1.2.3","next":"1.3.0-1"}' > "$CUR_UP/npm/-/package/npm-current/dist-tags"
  printf '{"latest":"3.4.5"}' > "$CUR_UP/npm/-/package/@scope/document-pin/dist-tags"
  printf '{\n  "tag_name": "v0.10.0",\n}\n' > "$CUR_UP/github/repos/owner/github-behind/releases/latest"
  printf '{\n  "tag_name": "v2.0.0",\n}\n' > "$CUR_UP/github/repos/owner/url-capture/releases/latest"
  printf '{\n  "tag_name": "v1.0.0",\n}\n' > "$CUR_UP/github/repos/owner/commit/releases/latest"
  printf '{\n  "status": "identical",\n}\n' > "$CUR_UP/github/repos/owner/commit/compare/v1.0.0...0123456789abcdef0123456789abcdef01234567"
  printf '[\n{"version":"v26.0.0","lts":false},\n{"version":"v24.1.0","lts":"Krypton"},\n{"version":"v24.0.0","lts":"Krypton"}\n]\n' > "$CUR_UP/node.json"
  printf '<item sparkle:version="3.6.11"/>\n<item sparkle:version="3.7.2"/>\n<item sparkle:version="3.7.0"/>\n' > "$CUR_UP/appcast.xml"
  cat > "$CUR_FIX/table" <<EOF
npm-current   | modules/fixture_tool.sh | NPM_CURRENT_VERSION   | -                             | npm:npm-current
github-behind | modules/fixture_tool.sh | GITHUB_BEHIND_VERSION | -                             | github:owner/github-behind
url-capture   | modules/fixture_tool.sh | URL_CAPTURE_URL       | /download/v([0-9.]+)/         | github:owner/url-capture
commit        | modules/fixture_tool.sh | COMMIT_PIN            | -                             | github-commit:owner/commit
node-line     | modules/fixture_tool.sh | NODE_LINE_VERSION     | -                             | node-line
appcast       | modules/fixture_tool.sh | APPCAST_URL           | Appcast-([0-9_]+)\\.zip        | sparkle:file://$CUR_UP/appcast.xml
document-pin  | README.md               | -                     | Document CLI ([0-9][0-9.]*[0-9]) | npm:@scope/document-pin
EOF
  currency_fixture_run() {  # [npm base] — every upstream a file:// fixture; no network
    CURRENCY_ROOT="$CUR_FIX" CURRENCY_TABLE="$CUR_FIX/table" GITHUB_TOKEN='' CURRENCY_NPM="${1:-file://$CUR_UP/npm}" \
      CURRENCY_GITHUB_API="file://$CUR_UP/github" CURRENCY_NODE_INDEX="file://$CUR_UP/node.json" /bin/bash "$CUR" 2>&1
  }
  CUR_OUT="$(currency_fixture_run)"; CUR_RC=$?
  same "currency-online-verdicts" "$(printf '%s\n' "$CUR_OUT" | grep ' pinned ' | awk '{print $1 "=" $NF}' | tr '\n' ' ')" \
    "npm-current=current github-behind=BEHIND url-capture=current commit=current node-line=current appcast=current document-pin=current "
  same "currency-online-behind-rc" "$CUR_RC" 1

  grep -v '^github-behind' "$CUR_FIX/table" > "$CUR_FIX/table.current" && mv "$CUR_FIX/table.current" "$CUR_FIX/table"
  CUR_OUT="$(currency_fixture_run)"; CUR_RC=$?
  same "currency-online-all-current-rc" "$CUR_RC" 0

  # An upstream that does not answer is unknown (exit 2), never current and never BEHIND.
  CUR_OUT="$(currency_fixture_run "file://$CUR_UP/no-registry-here")"; CUR_RC=$?
  same "currency-online-unanswered-is-unknown" \
    "$CUR_RC:$(printf '%s\n' "$CUR_OUT" | grep -c ' upstream ? unknown')" "2:2"
  unset -f currency_fixture_run
fi
