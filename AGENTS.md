# mac-bootstrap

One entry point that bootstraps a brand-new Mac for an agent workflow which must work under both Claude Code and GitHub Copilot CLI.

## Commands — the only ones; never guess a script or a package manager
- Install `git clone <this repo>` · Dev `bash bootstrap.sh` · Build — there is no build step
- Test `bash scripts/characterize.sh` — name-independent behaviour checks from a sandbox `HOME`; a feature adds its own in `scripts/checks/<feature>.sh`, which it sources. Narrower: `bash assets/hooks/bootstrap-lib.sh --selftest` (and the same flag on each hook) · one module: `bash verify.sh --only instructions`
- Lint + typecheck `shellcheck -S warning bootstrap.sh verify.sh scripts/*.sh scripts/checks/*.sh modules/*.sh assets/hooks/*.sh` and `/bin/bash -n` each file — run both before every commit
- Release `bash scripts/release.sh` after pushing content · check a published one `bash scripts/release.sh --check` (CI runs it on every push to main)

## Layout
- `modules/<name>.sh` — one deliverable each, named for the capability it delivers; six verbs, no top-level side effects. `CONTRACT.md` is the spec. Install order is declared once, in `BOOTSTRAP_MODULE_ORDER`, never implied by a filename
- `assets/` — bytes that land on the machine verbatim; `assets/hooks/bootstrap-lib.sh` is the only shared code

## Rules an agent would get wrong unless told
- Target bash is **3.2.57**: no associative arrays, no `${x^^}`, no `mapfile`. Check with `/bin/bash -n`, never Homebrew's bash 5
- `bootstrap_settings_merge` is the **only** thing here that may write a JSON settings file; every hook exits `0` on every path
- Verify by independent read-back — parse it, execute it, read the geometry — never by grepping for a phrase you just wrote
- **`BOOTSTRAP_PIN` names the release commit's PARENT, and only `scripts/release.sh` may write it.** A curl'd `bootstrap.sh` has no `modules/` beside it, so it fetches them from that pin; a commit cannot contain its own sha, so the pin names the already-published content commit. Editing the line by hand is how `__PIN_SHA__` shipped and killed both entry points
- A clone can never see that class of defect — `modules/` is beside the script — so the only honest test is a standalone `curl` into a sandbox `HOME`. **Never run a non-`--plan` invocation against the real `$HOME`**: modules write `$HOME/.claude`, `$HOME/.copilot` and the iTerm2 plist

## Never
- Never introduce a non-semantic identifier — no `mN_`, no initialism prefix, no bare letter-number code. Every name a reader meets must say what it is. This repo spent a whole pass removing the last of them
- Never write the user's permissions, allowlists, or credentials, and never commit a path containing a user name — ask in chat, and use `$HOME`
