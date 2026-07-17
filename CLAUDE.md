# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A repo for **`claude-config-bootstrap`**, a Claude Code skill that sets up multiple isolated Claude Code accounts on one machine. No application code, build system, or test suite — the core is one idempotent bash script. The skill ships as **plain files** (not a zip), so it's diffable and editable in place:

- `claude-session` — **repo-root CLI and primary entry point.** Owns all shell integration. Subcommands: `--create NAME...`, `--delete NAME...`, `--list`, `--pool-add CLIENT`, `--pool-list CLIENT`, `--pool-remove NAME...`, `--login NAME...` (launch claude under a named client/member dir to log it in; a pooled client name expands to members missing credentials), `--revert [--force]`; flags `-y/--yes` (skip prompts), `--force` (with `--revert`, also delete client account dirs incl. pool members). Delegates per-client memory+statusline to `setup.sh`.
- `claude-config-bootstrap/` — the skill: `SKILL.md` (agent-facing trigger doc), `README.md` (human reference), `scripts/setup.sh` (per-config-dir engine), `scripts/cc-rotate` + `scripts/cc-rotate-kill` (rate-limit rotation supervisor + StopFailure hook helper; installed into `~/.claude-shared/` by the CLI).
- `README.md` — end-user quick start (hero + badges). `LICENSE` — MIT © Macleod Labs. `assets/hero.png` — README banner (generated with Gemini "nano banana").

There is **no `.skill` zip** and **no `install.sh`** (both removed). The skill is plain files; `claude-session --create` copies the folder into `~/.claude/skills/`. If you ever need a standalone zip, `zip -rX claude-config-bootstrap.skill claude-config-bootstrap`, but don't commit it.

## Two scripts, two jobs (don't merge them)

- **`claude-session`** owns the rc file: the `cc-<client>` launchers, the neutered bare `claude`, and a global, auto-sourcing `claude-session` shell function. It is the *single owner* of the rc launcher block (sentinels `# >>> claude-config-bootstrap launchers >>>`). It also self-installs to `~/.claude-shared/claude-session` and copies the skill into the skills dir.
- **`setup.sh`** configures *one* config dir only — memory + statusline. It no longer touches the rc file (the old `--install-launchers` was removed). `claude-session` calls it as `setup.sh --client <name> --clients-parent <p> --shared-dir <s>`.

**Rotation pools (rate-limit failover):** a client may have a pool file `~/.claude-shared/pools/<client>.pool` (ordered config-dir paths, primary first). The generated `cc-<client>` launcher checks for that file at runtime: present → route through `~/.claude-shared/cc-rotate` (restart+resume supervisor), absent → plain `claude` exactly as before. Pool *members* (`<client>-2`, …) carry a `.ccb-pool-member` marker file naming their primary; `discover_dirs` skips marked dirs so members never get their own `cc-` launcher. All pool dirs symlink `projects/` to `~/.claude-shared/pools/<client>-projects/` — this shared history is what makes cross-account `--resume` work, and every teardown path (`--pool-remove` last member, `--delete` of a pooled primary, `--revert`) must restore or knowingly delete it, never orphan it. The `StopFailure` hook (`rate_limit`/`billing_error` → `cc-rotate-kill`) is gated on `CC_ROTATE_ACTIVE=1`, set only by the supervisor, so directly-launched sessions never rotate. Design rationale: everything runs through the genuine `claude` binary with each account's own OAuth — never proxy or extract tokens (ToS ban vector).

**Global + auto-source mechanism:** a plain script can't re-source its parent shell, so `claude-session` is installed as a shell *function* in the rc block that runs the installed script then `source`s the rc file. First-ever run still needs one manual `source` (the function isn't defined yet); after that it's automatic. The function sets `CLAUDE_SESSION_WRAPPED=1` so the script knows it'll be auto-sourced and suppresses the one-time hint.

## Keeping docs in sync

`SKILL.md`'s YAML `description` is what Claude Code matches to decide when to run the skill. The skill's `README.md` is the deep reference; the repo-root `README.md` is the quick start. If you change `setup.sh` behavior/flags, update all three; if you change the CLI, update `claude-session`'s `--help` header and the repo README.

## What setup.sh does

`setup.sh` resolves which config dir to configure in this priority order: (1) `--client <name>` → derives `<clients-parent>/<name>` (no env var needed — the normal path); (2) `CLAUDE_CONFIG_DIR` if set → uses that active dir; (3) neither → falls back to `~/.claude` and warns. The env var wins over a derived dir when both are present — so when calling it for a *named* client, **unset `CLAUDE_CONFIG_DIR`** or the active session's dir will be configured instead.

It builds a **three-tier memory stack**:

1. **Shared global** — `~/.claude-shared/global.md`, imported into every client via an absolute-path `@import`. Created once, never overwritten.
2. **Client-local** — `<config-dir>/CLAUDE.md`. The script owns only a sentinel-delimited block (`<!-- claude-config-bootstrap:begin/end -->`) at the top holding the import; everything below `:end` is the user's and is preserved verbatim.
3. **Project-local** — `./CLAUDE.md` in each repo (not managed by this script).

Plus a shared client-aware **statusline** (`~/.claude-shared/statusline-client.sh`, wired via each config dir's `settings.json`).

## Invariants to preserve when editing these scripts

These are the design guarantees the script makes; don't break them:

- **Idempotent.** Every action checks current state and only writes when missing or drifted. A re-run on a configured dir must print all ✓ and change nothing.
- **Never clobber user content.** Memory below the `:end` marker, other keys in `settings.json`, an existing `global.md`, and the rest of the rc file outside the launcher sentinels must all survive untouched. A `.ccbak` backup is written before any rc-file edit.
- **`jq` is optional, never a hard dependency.** It's used only for the statusline's model/dir fields and for *merging* into a pre-existing `settings.json`. Without it, the client label still shows and a fresh `settings.json` is still written; the script tells the user what to add by hand rather than risk corrupting valid JSON. The script must never hard-fail on missing `jq`.
- **Edit-in-place blocks are managed via sentinels + `awk`.** Block replacement uses `awk` without `-v` interpolation of the block body so backslashes in the content aren't mangled.

## Verifying changes — and a HARD safety rule

There's no automated test harness. `setup.sh` supports a dry run:

```bash
bash claude-config-bootstrap/scripts/setup.sh --client test --check   # reports state, writes nothing
```

`claude-session` has **destructive** subcommands (`--delete`, `--revert --force` run `rm -rf` on real config dirs). All of `claude-session`'s paths are overridable by env var — `SHARED_DIR`, `CLIENTS_PARENT`, `SKILLS_DIR`, `RC_FILE` — for sandbox testing. **But `setup.sh` does NOT inherit those as env vars** (it sets its own defaults); `claude-session` keeps them aligned by passing `--clients-parent`/`--shared-dir` through. 

**THE RULE (learned the hard way — a mis-sandboxed `--revert --force` once deleted real client account dirs):**

1. Never run `--delete` or `--revert` (especially with `--force`/`-y`, which bypass the confirm prompt) against anything that might be your real home. The default confirm prompt is the safety net — do not skip it in tests.
2. Before any destructive test, **assert the sandbox actually took effect** — print the resolved target paths and confirm they're under your temp dir *before* running the destructive command. Do not assume an `env VAR=... ./claude-session` wrapper applied; verify it.
3. Prefer a sandbox via explicit env overrides set as a direct command prefix, and echo `$CLIENTS_PARENT`/`$RC_FILE` from inside a wrapper run first.

After a real run, verify in Claude Code with `/memory` (the shared `global.md` should appear in the loaded tree) and restart the session to see the statusline footer label.
