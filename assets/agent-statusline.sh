#!/bin/bash
# agent-statusline.sh — context-% in the status line, for Claude Code AND Copilot CLI.
# ONE script, ONE alternation, no host detection. Reads the session JSON on stdin, prints one
# line, exits 0. jq is used when present and is NOT required.
#
# THE FIELD, measured 2026-09-11 (CC 2.1.260 / Copilot CLI 1.0.83) — do not "simplify" it back:
#   Claude Code  .context_window.used_percentage                  FLOAT, already / the live window
#   Copilot      .context_window.current_context_used_percentage  INTEGER; used_percentage is
#                null in 39 of 39 captured payloads, even after a real authenticated turn.
#   NEVER rate_limits.*.used_percentage — that is a QUOTA number. Reading it paints a false red
#   91% on every session's first redraw, which is exactly when context usage is legitimately
#   absent. The no-jq arm therefore CUTS the remainder at "rate_limits" before matching.
#   A float truncates (45.7 -> 45): `[ 93.4 -ge 90 ]` is an arithmetic error, and the swallowed
#   error falls through to the CALM colour — the alarm inverted at the one end that matters.
# It also writes $BOOTSTRAP_TELEMETRY_DIR/<session_id>.json, because no HOOK event on Claude Code
# carries a context-window size: the status line is the only producer of this number.
set -u

IN=$(cat)
PCT=''; MODEL=''; DIR=''; SID=''

if [ -n "$IN" ] && command -v jq >/dev/null 2>&1; then
  # One line per field; a JSON string can never contain a raw newline, so empty fields stay
  # positional. floor before subtracting so this arm and the no-jq arm agree on a float.
  { read -r PCT; read -r MODEL; read -r DIR; read -r SID; } <<EOF
$(printf '%s' "$IN" | jq -r '(.context_window // {}) as $c
    | (($c.used_percentage // $c.current_context_used_percentage
        // .current_context_used_percentage
        // (if ($c.remaining_percentage|type) == "number"
              then 100 - ($c.remaining_percentage|floor) else null end)
        // "") | tostring),
      (.model.display_name // .model.id // ""),
      (.cwd // .workspace.current_dir // ""),
      (.session_id // "")' 2>/dev/null)
EOF
elif [ -n "$IN" ]; then
  case $IN in *\"context_window\"*) CW=${IN#*\"context_window\"} ;; *) CW='' ;; esac
  CW=${CW%%\"rate_limits\"*}
  [[ $CW =~ \"used_percentage\"[[:space:]]*:[[:space:]]*([0-9]+) ]] && PCT=${BASH_REMATCH[1]}
  [[ -z $PCT && $CW =~ \"current_context_used_percentage\"[[:space:]]*:[[:space:]]*([0-9]+) ]] &&
    PCT=${BASH_REMATCH[1]}
  [[ -z $PCT && $IN =~ \"current_context_used_percentage\"[[:space:]]*:[[:space:]]*([0-9]+) ]] &&
    PCT=${BASH_REMATCH[1]}
  if [ -z "$PCT" ] && [[ $CW =~ \"remaining_percentage\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
    PCT=$((100 - BASH_REMATCH[1]))
  fi
  MD=${IN#*\"model\"}
  [[ $MD =~ \"display_name\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && MODEL=${BASH_REMATCH[1]}
  [[ -z $MODEL && $MD =~ \"id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && MODEL=${BASH_REMATCH[1]}
  [[ $IN =~ \"cwd\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && DIR=${BASH_REMATCH[1]}
  [[ -z $DIR && $IN =~ \"current_dir\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && DIR=${BASH_REMATCH[1]}
  [[ $IN =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && SID=${BASH_REMATCH[1]}
fi

PCT=${PCT%%.*}                                  # 45.7 -> 45
case $PCT in ''|*[!0-9]*) PCT='' ;; esac        # null/absent/"" stay ABSENT — never a fake 0
[ -n "$PCT" ] && [ "$PCT" -gt 100 ] && PCT=''

[ -n "$DIR" ] || DIR=$(pwd)
DIR=${DIR##*/}
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || BRANCH=''
[ "$BRANCH" = HEAD ] && BRANCH=''

G=$'\033[38;5;245m'; R=$'\033[38;5;167m'; Z=$'\033[0m'
OUT=''
if [ -n "$PCT" ]; then
  if   [ "$PCT" -ge 90 ]; then OUT="${R}${PCT}%${Z}"
  elif [ "$PCT" -ge 60 ]; then OUT="${PCT}%"
  else                         OUT="${G}${PCT}%${Z}"
  fi
fi
for seg in "$MODEL" "$DIR" "$BRANCH"; do
  [ -n "$seg" ] || continue
  [ -n "$OUT" ] && OUT="${OUT}${G} · ${Z}"
  OUT="${OUT}${G}${seg}${Z}"
done
printf '%s\n' "$OUT"

# ── the telemetry producer. Runs AFTER the render is already flushed, so no failure here can
#    cost the status line. A session id is used as a FILENAME: anything but [A-Za-z0-9._-] is
#    refused rather than sanitised. Written to a temp name and moved, so a reader never sees half.
if [ -n "$PCT" ] && [ -n "$SID" ]; then
  case $SID in ''|*[!A-Za-z0-9._-]*) SID='' ;; esac
fi
if [ -n "$PCT" ] && [ -n "$SID" ]; then
  TD=${BOOTSTRAP_TELEMETRY_DIR:-/tmp/pb-telemetry}
  if mkdir -p "$TD" 2>/dev/null; then
    TS=$(date +%s 2>/dev/null) || TS=0
    case $TS in ''|*[!0-9]*) TS=0 ;; esac
    if printf '{"ts":%s,"session_id":"%s","used_pct":%s,"src":"agent-statusline"}\n' \
         "$TS" "$SID" "$PCT" > "$TD/$SID.json.$$" 2>/dev/null; then
      mv -f "$TD/$SID.json.$$" "$TD/$SID.json" 2>/dev/null || rm -f "$TD/$SID.json.$$" 2>/dev/null
    else
      rm -f "$TD/$SID.json.$$" 2>/dev/null
    fi
  fi
fi
exit 0
