#!/bin/bash
# model-advisor.sh — read this Mac, print the local rewrite models it can actually run, and name
# the one command that measures them. Writes NOTHING. Changes NOTHING. Installs NOTHING.
#
# Standalone by design, exactly like model-gate.sh: no bootstrap-lib.sh, no repo, no python, no jq.
# bash 3.2, /usr/bin/curl, /usr/sbin/sysctl, /usr/bin/pmset. Safe to curl onto a bare machine.
#
#   bash model-advisor.sh            human-readable advice
#   bash model-advisor.sh --json     one key=value block, for an agent to parse
#   bash model-advisor.sh --facts    the hardware probe only, no advice
#
#   exit 0  advice printed
#   exit 2  could not read something essential — the advice would have been a guess
#
# ═════════════════════════════════════════════════════════════════════════════════════════════
# WHY THIS EXISTS, AND WHY IT RECOMMENDS A MEASUREMENT RATHER THAN A MODEL
# ═════════════════════════════════════════════════════════════════════════════════════════════
#
# The thing this replaces was a sentence in README.md telling an agent "at 16 GB or more use
# qwen3:8b", beside a module that branched at 12 GB. An agent following the prose and an agent
# reading the code reached different answers on the same Mac. Worse, BOTH numbers were compared
# against the wrong quantity — see THE BUDGET below.
#
# It does not print a winner. Every measurement behind it says the same thing: on this task,
# belief about a model is worth less than one run of the gate against it. So the advisor's
# output is a SHORTLIST ORDERED BY WHAT FITS, and the command that scores it. The scoring is
# assets/model-gate.sh, which is the only thing here entitled to say a model is fit.
#
# ── THE BUDGET — three corrections to the obvious arithmetic, each measured ───────────────────
#
#  1. THE GPU GETS 75% OF UNIFIED MEMORY, NOT ALL OF IT. Measured from ollama's own scheduler
#     log on a 64 GB M1 Max: total="48.0 GiB", and 48.0/64 = 0.750000 exactly. A rule that
#     subtracts a model's size from hw.memsize overstates what is available by a quarter.
#     (`iogpu.wired_limit_max` does NOT exist — `sysctl` returns "unknown oid". The real oid is
#     iogpu.wired_limit_mb, and it is an OVERRIDE, 0 meaning "system default", never a reading.
#     So the default is exposed by no oid and 0.75 is an estimate; the provenance travels with
#     the number below, as gpu_budget_source.)
#
#  2. THE FLOOR IS 6.6 GiB, NOT 5. Measured co-resident set while dictating: macOS ~3.0 GB,
#     a browser 2.5-2.9, ollama's own server 0.09, and VoiceInk itself — which is BIMODAL:
#     22 MB idle, 1,976 MB the moment the hotkey is pressed and the transcription model loads.
#     A headroom rule computed against idle VoiceInk passes, and then fails at the only instant
#     that matters, which is while the user is speaking.
#
#  3. WEIGHTS ARE NOT THE FOOTPRINT. Resident = weights + context. ollama 0.33.3 picks its
#     default context from total VRAM (>=47 GiB -> 262144, >=23 GiB -> 32768, else 4096), and
#     KV cache is decoupled from parameter count: qwen3:4b and qwen3:8b have IDENTICAL KV
#     geometry (36 layers x 8 kv-heads x 128), ~78 KB/token, so the 4B is the one that blows up.
#     This is why every model below is installed through a Modelfile that pins num_ctx 4096 —
#     with that pin the weights ARE the footprint, and a table like this becomes honest.
#
# ── WHAT THIS SCRIPT DELIBERATELY DOES NOT COLLECT ───────────────────────────────────────────
# `system_profiler SPHardwareDataType` carries the machine serial, the hardware UUID and the
# provisioning UDID. An advisor that an agent will paste into a chat window has no business
# emitting those, so the chip is read from sysctl and the GPU from ioreg's AGXAccelerator node.
# ═════════════════════════════════════════════════════════════════════════════════════════════

set -u

ADVISOR_MODE=human
ADVISOR_SYSCTL=/usr/sbin/sysctl
ADVISOR_CURL=/usr/bin/curl
ADVISOR_PMSET=/usr/bin/pmset
ADVISOR_IOREG=/usr/sbin/ioreg
ADVISOR_URL="${MODEL_GATE_BASE_URL:-http://localhost:11434}"

while [ $# -gt 0 ]; do
  case "$1" in
    --json)  ADVISOR_MODE=json;  shift ;;
    --facts) ADVISOR_MODE=facts; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 2 ;;
    *) printf 'model-advisor: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done

# ── the probe. Every field is one fact, read through the cheapest stable path. ────────────────

# Unified memory in whole GiB. 0 means UNKNOWN, which is never treated as "small".
adv_mem_gib() {
  local b
  b="$("$ADVISOR_SYSCTL" -n hw.memsize 2>/dev/null)" || b=""
  case "${b:-}" in ''|*[!0-9]*) printf '0'; return 0 ;; esac
  printf '%s' $((b / 1073741824))
}

adv_chip() { "$ADVISOR_SYSCTL" -n machdep.cpu.brand_string 2>/dev/null || printf 'unknown'; }

# Apple silicon or not. An Intel Mac runs these models on the CPU and loses on latency, not on
# memory — so the tier table would pass it and the gate would then reject it. Say so up front.
adv_is_apple_silicon() {
  case "$(adv_chip)" in *Apple*) return 0 ;; esac
  return 1
}

# GPU core count. ioreg's AGXAccelerator node answers in ~26 ms; `ioreg -l` carries the same key
# at 1.14 s, which is 44x the cost for the same byte.
adv_gpu_cores() {
  local v
  v="$("$ADVISOR_IOREG" -rc AGXAccelerator -d1 2>/dev/null \
        | /usr/bin/awk -F'= ' '/"gpu-core-count"/{gsub(/[^0-9]/,"",$2); print $2; exit}')" || v=""
  case "${v:-}" in ''|*[!0-9]*) printf 'unknown' ;; *) printf '%s' "$v" ;; esac
}

adv_os_major() { /usr/bin/sw_vers -productVersion 2>/dev/null | /usr/bin/cut -d. -f1; }

# Free space on the boot volume, whole GiB. A 7 GB pull onto a full disk fails halfway.
adv_disk_free_gib() {
  local v
  v="$(/bin/df -g / 2>/dev/null | /usr/bin/awk 'NR==2{print $4}')" || v=""
  case "${v:-}" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$v" ;; esac
}

# Chassis and power. `hw.model` stopped being a chassis test (a MacBook Pro M3 reports Mac15,3),
# so the laptop question is answered by whether an internal battery exists.
adv_chassis()  { "$ADVISOR_PMSET" -g batt 2>/dev/null | /usr/bin/grep -q 'InternalBattery' && printf 'laptop' || printf 'desktop'; }
adv_power()    { "$ADVISOR_PMSET" -g batt 2>/dev/null | /usr/bin/grep -q "'AC Power'" && printf 'ac' || printf 'battery'; }

adv_ollama_bin() {
  local c
  for c in /opt/homebrew/bin/ollama /usr/local/bin/ollama /Applications/Ollama.app/Contents/Resources/ollama; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}
adv_ollama_server() { "$ADVISOR_CURL" -fsS -m 5 "$ADVISOR_URL/api/version" >/dev/null 2>&1; }

ADV_MEM="$(adv_mem_gib)"
ADV_CHIP="$(adv_chip)"
ADV_GPU="$(adv_gpu_cores)"
ADV_OS="$(adv_os_major)"
ADV_DISK="$(adv_disk_free_gib)"
ADV_CHASSIS="$(adv_chassis)"
ADV_POWER="$(adv_power)"
ADV_ARCH=intel
adv_is_apple_silicon && ADV_ARCH=apple-silicon
ADV_OLLAMA_BIN=no; adv_ollama_bin >/dev/null 2>&1 && ADV_OLLAMA_BIN=yes
ADV_OLLAMA_SRV=no; adv_ollama_server && ADV_OLLAMA_SRV=yes

# ── the budget ───────────────────────────────────────────────────────────────────────────────
# Two independent ceilings; the model must clear the LOWER. Reported separately, because which
# one binds tells you what to do about it: a Metal-bound Mac cannot be helped, a floor-bound one
# can be helped by closing the browser.
ADV_GPU_BUDGET=0
ADV_FLOOR_BUDGET=0
ADV_BUDGET=0
ADV_BUDGET_BIND=unknown
ADV_GPU_BUDGET_SRC=estimate-75pct-of-hw.memsize
if [ "$ADV_MEM" -gt 0 ]; then
  ADV_GPU_BUDGET=$(( ADV_MEM * 3 / 4 ))
  ADV_FLOOR_BUDGET=$(( ADV_MEM - 7 ))          # 6.6 GiB co-resident floor, rounded up to whole GiB
  [ "$ADV_FLOOR_BUDGET" -lt 0 ] && ADV_FLOOR_BUDGET=0
  if [ "$ADV_GPU_BUDGET" -le "$ADV_FLOOR_BUDGET" ]; then
    ADV_BUDGET="$ADV_GPU_BUDGET"; ADV_BUDGET_BIND=metal-cap
  else
    ADV_BUDGET="$ADV_FLOOR_BUDGET"; ADV_BUDGET_BIND=co-resident-floor
  fi
fi

# ── the candidate table ──────────────────────────────────────────────────────────────────────
# Columns: need_gib|tag|disk|licence|status|why
# `need_gib` is the resident weight at num_ctx 4096, rounded UP to a whole GiB.
# `status` is the evidence class, and it is the most important column here:
#   measured-good  scored PASS on this repo's own gate, this month
#   contested      the repo asserts it and a later probe disagreed — re-measure before trusting
#   unmeasured     catalogue-verified, never scored. A candidate, not a recommendation.
adv_candidates() {
  cat <<'CANDIDATES'
8|gemma4:12b-it-qat|7.2 GB|Apache-2.0|measured-good|byte-identical 3/3 on both gate fixtures; Q4_0 quantization-aware training, so 4-bit costs it little; smaller on disk than the 9B alternatives
7|qwen3.5:9b|6.6 GB|Apache-2.0|contested|like-for-like replacement for the incumbent; one probe cleaned better than qwen3:8b, an earlier one rejected it for inventing an AM/PM qualifier
6|granite4.2:8b|5.3 GB|Apache-2.0|unmeasured|newest Apache-2.0 text-only 8B (2026-08-25); IBM ships a full provenance trail, which is the easiest licence review in the set
6|qwen3:8b|5.2 GB|Apache-2.0|contested|THE INCUMBENT. The module claims byte-identical 5/5; a later probe of the base tag retained fillers and dropped a terminal question mark. Re-measure before keeping it
4|ministral-3:3b|3.0 GB|Apache-2.0|unmeasured|its API REFUSES think:true, so determinism comes from the architecture rather than from a flag someone must remember to send
3|granite4.2:3b|2.2 GB|Apache-2.0|unmeasured|smallest Apache-2.0 candidate with a real vendor behind it
2|qwen3.5:0.8b|1.0 GB|Apache-2.0|unmeasured|the reason an 8 GB Mac is a question and not a refusal — it fits at 1.66 GB resident with room to spare
CANDIDATES
}

# Models that may not be installed, and the reason, which is never "it felt slow".
adv_forbidden() {
  cat <<'FORBIDDEN'
qwen3:4b|its base is Qwen3-4B-Thinking-2507, whose template prefills an unclosed <think>. think:false — exactly what VoiceInk sends — disables ollama's thinking PARSER but not the template's PREFILL, so 2,300+ words of chain of thought land in the response field carrying only a closing tag. The same defect rides any tag built FROM it
lfm2.5|LFM Open License v1.0 section 5 withdraws commercial use above a $10M annual-revenue Threshold. This module targets corporate Macs, which is the population that clause excludes
FORBIDDEN
}

# ── output ───────────────────────────────────────────────────────────────────────────────────
adv_emit_facts() {
  printf 'chip=%s\n' "$ADV_CHIP"
  printf 'arch=%s\n' "$ADV_ARCH"
  printf 'gpu_cores=%s\n' "$ADV_GPU"
  printf 'mem_gib=%s\n' "$ADV_MEM"
  printf 'gpu_budget_gib=%s\n' "$ADV_GPU_BUDGET"
  printf 'gpu_budget_source=%s\n' "$ADV_GPU_BUDGET_SRC"
  printf 'coresident_floor_gib=7\n'
  printf 'model_budget_gib=%s\n' "$ADV_BUDGET"
  printf 'model_budget_bound_by=%s\n' "$ADV_BUDGET_BIND"
  printf 'os_major=%s\n' "$ADV_OS"
  printf 'disk_free_gib=%s\n' "$ADV_DISK"
  printf 'chassis=%s\n' "$ADV_CHASSIS"
  printf 'power_source=%s\n' "$ADV_POWER"
  printf 'ollama_binary=%s\n' "$ADV_OLLAMA_BIN"
  printf 'ollama_server=%s\n' "$ADV_OLLAMA_SRV"
}

if [ "$ADV_MEM" -eq 0 ]; then
  printf 'COULD-NOT-RUN: sysctl did not report hw.memsize, so every number below would be a guess.\n' >&2
  exit 2
fi

if [ "$ADVISOR_MODE" = facts ]; then adv_emit_facts; exit 0; fi

if [ "$ADVISOR_MODE" = json ]; then
  adv_emit_facts
  adv_candidates | while IFS='|' read -r need tag disk lic status why; do
    [ -n "${tag:-}" ] || continue
    if [ "$ADV_BUDGET" -ge "$need" ]; then
      printf 'candidate=%s status=%s disk=%s licence=%s\n' "$tag" "$status" "$disk" "$lic"
    fi
  done
  adv_forbidden | while IFS='|' read -r tag why; do
    [ -n "${tag:-}" ] || continue
    printf 'forbidden=%s\n' "$tag"
  done
  exit 0
fi

# human
printf '\n  THIS MAC\n'
printf '    %s · %s GPU cores · %s GiB unified memory · macOS %s · %s on %s\n' \
  "$ADV_CHIP" "$ADV_GPU" "$ADV_MEM" "$ADV_OS" "$ADV_CHASSIS" "$ADV_POWER"
printf '    %s GiB free on the boot volume · ollama binary %s · ollama server %s\n' \
  "$ADV_DISK" "$ADV_OLLAMA_BIN" "$ADV_OLLAMA_SRV"

printf '\n  THE BUDGET FOR A MODEL\n'
printf '    %s GiB — the lower of a %s GiB Metal ceiling (%s) and %s GiB left after the\n' \
  "$ADV_BUDGET" "$ADV_GPU_BUDGET" "$ADV_GPU_BUDGET_SRC" "$ADV_FLOOR_BUDGET"
printf '    7 GiB that macOS, a browser and VoiceInk-while-transcribing measurably occupy.\n'
printf '    Bound by: %s.\n' "$ADV_BUDGET_BIND"

if [ "$ADV_ARCH" = intel ]; then
  printf '\n  ⚠ This is an Intel Mac. It has the memory but not the GPU: these models run on the CPU\n'
  printf '    and will miss the 15 s enhancement timeout, at which point VoiceInk pastes the raw\n'
  printf '    transcript. Measure before installing anything — the gate will tell you plainly.\n'
fi
if [ "$ADV_POWER" = battery ]; then
  printf '\n  ⚠ Measuring on battery. Sustained generation is slower off AC, so a latency FAIL here\n'
  printf '    may be a fact about the power source. Plug in before you score a candidate.\n'
fi

if [ "$ADV_OS" -ge 27 ] 2>/dev/null; then
  printf '\n  BEFORE DOWNLOADING ANYTHING — this Mac may already have a local model\n'
  printf '    macOS 27 preinstalls Apple'"'"'s on-device Foundation Models and an `fm` CLI, which\n'
  printf '    VoiceInk can call through its Local CLI provider with no download and no daemon.\n'
  printf '    It is gated on Apple Intelligence being switched on (a ~7 GB opt-in, GUI-only).\n'
  printf '    Check with:  fm respond "say ok"\n'
  printf '    If that answers, measure it FIRST — it needs no model, no ollama and no licence review.\n'
fi

printf '\n  CANDIDATES THAT FIT, largest first\n'
# A here-doc redirect, never a pipeline: `... | while read` runs the loop in a SUBSHELL under
# bash 3.2, so ADV_ANY would be set in a process that exits before it is read.
ADV_ANY=0
while IFS='|' read -r need tag disk lic status why; do
  [ -n "${tag:-}" ] || continue
  case "${need:-}" in ''|*[!0-9]*) continue ;; esac
  [ "$ADV_BUDGET" -ge "$need" ] || continue
  ADV_ANY=1
  printf '\n    %-22s %s · %s · %s\n' "$tag" "$disk" "$lic" "$status"
  printf '      %s\n' "$why"
done <<CANDIDATE_ROWS
$(adv_candidates)
CANDIDATE_ROWS

if [ "$ADV_ANY" -eq 0 ]; then
  printf '\n    None. At %s GiB of budget no model in this set fits beside a working desktop.\n' "$ADV_BUDGET"
  printf '    Leaving VoiceInk AI enhancement OFF is the honest setting — a model that swaps\n'
  printf '    misses the timeout, and one that is too small invents text into your documents.\n'
fi

printf '\n  WILL NOT BE INSTALLED\n'
while IFS='|' read -r tag why; do
  [ -n "${tag:-}" ] || continue
  printf '\n    %-22s %s\n' "$tag" "$why"
done <<FORBIDDEN_ROWS
$(adv_forbidden)
FORBIDDEN_ROWS

printf '\n  WHAT TO DO WITH THIS\n'
printf '    Nothing above is a recommendation to install. `status` is the evidence, and only\n'
printf '    `measured-good` means anything was scored. Measure the top candidate, then the next:\n'
printf '\n      bash bootstrap.sh --only rewrite_model --bench <tag>\n'
printf '\n    That prints a PASS/FAIL verdict from assets/model-gate.sh and exits 0 only on PASS.\n'
printf '    Install the first one that passes:\n'
printf '\n      bash bootstrap.sh --only rewrite_model --model <tag>\n'
printf '\n'
exit 0
