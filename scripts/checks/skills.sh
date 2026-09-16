# shellcheck shell=bash
# scripts/checks/skills.sh — the portable agent skills. Sourced by scripts/characterize.sh.
#
# The four properties worth proving, none of which a file count can see:
#   1. the files land under an agent root that EXISTS, and no root is created to hold them;
#   2. what landed parses as the document it claims to be — read back here with grep+cut, which
#      is neither the module's awk nor the cp that wrote it;
#   3. the verifier can say NO (a description taken away must not still read as installed);
#   4. somebody else's skill at one of our names is never overwritten, and never removed.

if [ -r "$CHECK_ROOT/modules/skills.sh" ]; then
  # A SKILL.md's frontmatter, read back by a third code path: sed over the first block only.
  sk_key() { grep "^$2: " "$1" 2>/dev/null | head -1 | cut -d' ' -f2-; }
  sk_sum() { find "$1" -type f 2>/dev/null | sort | xargs shasum -a 256 2>/dev/null | shasum -a 256 | cut -d' ' -f1; }

  h="$(fresh_home skills)"
  mkdir -p "$h/.claude"                      # ONE agent root exists; the other deliberately does not
  drive_at "$h" --only skills
  same "skills-install-rc" "$CHECK_RC" 0
  same "skills-three-files-landed" \
    "$(find "$h/.claude/skills" -name SKILL.md 2>/dev/null | grep -c . | tr -d ' ')" "3"
  # …and the module NEVER creates a root for an agent that is not here.
  same "skills-creates-no-absent-agent-root" "$([ -e "$h/.copilot" ] && printf created || printf absent)" "absent"

  # Each file names ITSELF, as its own directory, with a non-empty description.
  SK_OK=0
  for n in handoff-continuation plan-conventions verify-by-readback; do
    f="$h/.claude/skills/$n/SKILL.md"
    [ "$(sk_key "$f" name)" = "$n" ] && [ -n "$(sk_key "$f" description)" ] && SK_OK=$((SK_OK + 1))
  done
  same "skills-frontmatter-reads-back" "$SK_OK" "3"

  SK_SUM="$(sk_sum "$h/.claude/skills")"
  drive_at "$h" --only skills
  same "skills-second-run-changes-nothing" "$(sk_sum "$h/.claude/skills")" "$SK_SUM"

  # NEGATIVE CONTROL: take the description away and verify must say no.
  grep -v '^description:' "$h/.claude/skills/plan-conventions/SKILL.md" > "$CHECK_TMP/sk-nodesc" &&
    mv "$CHECK_TMP/sk-nodesc" "$h/.claude/skills/plan-conventions/SKILL.md"
  HOME="$h" /bin/bash "$CHECK_ROOT/bootstrap.sh" --verify --only skills >/dev/null 2>&1; CHECK_RC=$?
  same "skills-verify-sees-a-broken-file" "$CHECK_RC" 20

  # A skill of somebody else's, under one of OUR names, and one under a name of their own.
  h2="$(fresh_home skills-theirs)"
  mkdir -p "$h2/.claude/skills/plan-conventions" "$h2/.claude/skills/their-own"
  printf -- '---\nname: plan-conventions\ndescription: Their own.\n---\n\nPRECIOUS\n' > "$h2/.claude/skills/plan-conventions/SKILL.md"
  printf -- '---\nname: their-own\ndescription: Theirs too.\n---\n\nPRECIOUS\n' > "$h2/.claude/skills/their-own/SKILL.md"
  drive_at "$h2" --only skills
  same "skills-collision-is-needs-human" "$CHECK_RC" 10
  same "skills-collision-never-overwritten" \
    "$(sed -n '$p' "$h2/.claude/skills/plan-conventions/SKILL.md")" "PRECIOUS"

  # …and uninstall removes only what carries our marker.
  h3="$(fresh_home skills-uninstall)"
  mkdir -p "$h3/.claude" "$h3/.copilot"
  drive_at "$h3" --only skills
  same "skills-installs-into-both-roots" \
    "$(find "$h3/.claude/skills" "$h3/.copilot/skills" -name SKILL.md 2>/dev/null | grep -c . | tr -d ' ')" "6"
  mkdir -p "$h3/.claude/skills/their-own"
  printf -- '---\nname: their-own\ndescription: Theirs.\n---\n\nPRECIOUS\n' > "$h3/.claude/skills/their-own/SKILL.md"
  drive_at "$h3" --uninstall --only skills
  same "skills-uninstall-removes-ours" \
    "$(find "$h3/.claude/skills" "$h3/.copilot/skills" -name SKILL.md 2>/dev/null | grep -c . | tr -d ' ')" "1"
  same "skills-uninstall-keeps-what-is-not-ours" \
    "$([ -f "$h3/.claude/skills/their-own/SKILL.md" ] && printf kept || printf gone)" "kept"

  # A company policy that reserves personal skills to IT must turn the row NEEDS_HUMAN and NAME the
  # key — never SATISFIED over files the agent will not load. The managed root is a fixture, and the
  # control one directory over is empty, so the difference is the policy and not the sandbox.
  sk_drive() { local hh="$1" mm="$2"; shift 2
    HOME="$hh" TMPDIR="$CHECK_WORK" BOOTSTRAP_MANAGED_ROOT="$mm" \
      /usr/bin/env -u CLAUDE_CONFIG_DIR -u COPILOT_HOME /bin/bash "$CHECK_ROOT/bootstrap.sh" "$@" >/dev/null 2>&1
    CHECK_RC=$?; }
  sk_note() { local i=0 m
    while [ "$i" -lt 64 ]; do
      m="$(json_at "$1/.mac-bootstrap/receipt.json" "modules.$i.module")" || return 1
      [ "$m" = skills ] && { json_at "$1/.mac-bootstrap/receipt.json" "modules.$i.note"; return 0; }
      i=$((i + 1))
    done; return 1; }

  SK_MR="$CHECK_TMP/skills-policy"
  mkdir -p "$SK_MR/locked/Library/Application Support/ClaudeCode" "$SK_MR/open"
  printf '{"strictPluginOnlyCustomization": ["skills"]}\n' \
    > "$SK_MR/locked/Library/Application Support/ClaudeCode/managed-settings.json"

  h5="$(fresh_home skills-policy)"; mkdir -p "$h5/.claude"
  sk_drive "$h5" "$SK_MR/locked" --only skills
  same "skills-policy-lockdown-is-needs-human" "$CHECK_RC" 10
  case "$(sk_note "$h5")" in
    *strictPluginOnlyCustomization*) pass "skills-policy-names-the-key" ;;
    *) fail "skills-policy-names-the-key" "note: $(sk_note "$h5")" ;;
  esac
  same "skills-policy-installs-nothing" \
    "$(find "$h5/.claude/skills" -name SKILL.md 2>/dev/null | grep -c . | tr -d ' ')" "0"

  h6="$(fresh_home skills-policy-open)"; mkdir -p "$h6/.claude"
  sk_drive "$h6" "$SK_MR/open" --only skills
  same "skills-policy-control-with-no-policy" "$CHECK_RC" 0

  # No agent root at all: nothing to install, nothing claimed, and nothing created.
  h4="$(fresh_home skills-noroot)"
  drive_at "$h4" --only skills
  same "skills-no-agent-root-rc" "$CHECK_RC" 0
  if [ -e "$h4/.claude" ] || [ -e "$h4/.copilot" ]; then SK_MADE=created; else SK_MADE=absent; fi
  same "skills-no-agent-root-creates-nothing" "$SK_MADE" "absent"
fi
