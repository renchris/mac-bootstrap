# mac-bootstrap

One entry point that bootstraps a brand-new Mac for an agent workflow which must work under both Claude Code and GitHub Copilot CLI.

## Commands — the only ones; never guess a script or a package manager
- Install `git clone <this repo>` · Dev `bash bootstrap.sh` · Build — there is no build step
- Test `bash assets/hooks/pb-lib.sh --selftest` — single test: `bash verify.sh --only m2_instructions`
- Lint + typecheck `shellcheck -S warning bootstrap.sh verify.sh modules/*.sh assets/hooks/*.sh` and `/bin/bash -n` each file — run both before every commit

## Layout
- `modules/mN_name.sh` — one deliverable each; six verbs, no top-level side effects. `CONTRACT.md` is the spec
- `assets/` — bytes that land on the machine verbatim; `assets/hooks/pb-lib.sh` is the only shared code

## Rules an agent would get wrong unless told
- Target bash is **3.2.57**: no associative arrays, no `${x^^}`, no `mapfile`. Check with `/bin/bash -n`, never Homebrew's bash 5
- `pb_settings_merge` is the **only** thing here that may write a JSON settings file; every hook exits `0` on every path
- Verify by independent read-back — parse it, execute it, read the geometry — never by grepping for a phrase you just wrote

## Never
- Never write the user's permissions, allowlists, or credentials, and never commit a path containing a user name — ask in chat, and use `$HOME`
