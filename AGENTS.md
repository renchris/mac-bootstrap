# mac-bootstrap

One entry point that bootstraps a brand-new Mac for an agent workflow which must work under both Claude Code and GitHub Copilot CLI.

## Commands — the only ones; never guess a script or a package manager
- Install `git clone <this repo>` · Dev `bash bootstrap.sh` · Build — there is no build step
- Test `bash assets/hooks/bootstrap-lib.sh --selftest` — single test: `bash verify.sh --only instructions`
- Lint + typecheck `shellcheck -S warning bootstrap.sh verify.sh scripts/release.sh modules/*.sh assets/hooks/*.sh` and `/bin/bash -n` each file — run both before every commit
- Release `bash scripts/release.sh` after pushing content · check a published one `bash scripts/release.sh --check` (CI runs it on every push to main)

## Layout
- `modules/mN_name.sh` — one deliverable each; six verbs, no top-level side effects. `CONTRACT.md` is the spec
- `assets/` — bytes that land on the machine verbatim; `assets/hooks/bootstrap-lib.sh` is the only shared code

## Rules an agent would get wrong unless told
- Target bash is **3.2.57**: no associative arrays, no `${x^^}`, no `mapfile`. Check with `/bin/bash -n`, never Homebrew's bash 5
- `bootstrap_settings_merge` is the **only** thing here that may write a JSON settings file; every hook exits `0` on every path
- Verify by independent read-back — parse it, execute it, read the geometry — never by grepping for a phrase you just wrote
- **`BOOTSTRAP_PIN` names the release commit's PARENT, and only `scripts/release.sh` may write it.** A curl'd `bootstrap.sh` has no `modules/` beside it, so it fetches them from that pin; a commit cannot contain its own sha, so the pin names the already-published content commit. Editing the line by hand is how `__PIN_SHA__` shipped and killed both entry points
- A clone can never see that class of defect — `modules/` is beside the script — so the only honest test is a standalone `curl` into a sandbox `HOME`. **Never run a non-`--plan` invocation against the real `$HOME`**: modules write `$HOME/.claude`, `$HOME/.copilot` and the iTerm2 plist

## Never
- Never write the user's permissions, allowlists, or credentials, and never commit a path containing a user name — ask in chat, and use `$HOME`
