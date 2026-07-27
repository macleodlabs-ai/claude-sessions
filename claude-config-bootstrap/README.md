# claude-config-bootstrap

Run multiple Claude Code accounts on one machine — cleanly isolated, visually distinguishable, and with shared-plus-local memory — using a single idempotent setup script.

This is packaged as a Claude Code **skill**, but the core is just `scripts/setup.sh`; you can run it directly without involving the skill system at all.

---

## The problem this solves

Claude Code stores everything — credentials, session history, settings, MCP config — in one directory, `~/.claude`, and writes the active credential to your system keychain. **One directory means one account.** So if you consult for several clients, each with its own Claude subscription, you hit three frictions:

1. **Sessions stomp on each other.** Logging into account B in one terminal switches *every* running session to B, because they all share `~/.claude` and the keychain credential.
2. **You can't tell sessions apart.** Three terminals running three accounts look identical. Nothing in the footer or `/usage` says *which* account you're in.
3. **Memory is all-or-nothing.** A global `~/.claude/CLAUDE.md` is shared by everything or not at all; there's no clean "shared conventions + per-client specifics" split.

The supported fix for isolation is the `CLAUDE_CONFIG_DIR` environment variable: point it at a different directory and you get a fully independent Claude Code — separate credentials, settings, history, and its own 5-hour usage window. This skill builds the rest of the ergonomics on top of that: a two-tier memory system, a client-aware statusline, and one-word launcher commands.

---

## What it sets up

For each **config dir** (one per client/account, e.g. `~/.claude-clients/macleod`):

| Piece | Path | Purpose |
|---|---|---|
| Client-local memory | `<config-dir>/CLAUDE.md` | Imports the shared file, holds client-specific memory below it |
| Statusline pointer | `<config-dir>/settings.json` | Wires the footer to the shared statusline script |

**Shared across all clients** (created once, reused):

| Piece | Path | Purpose |
|---|---|---|
| Shared memory | `~/.claude-shared/global.md` | Conventions every client inherits, via `@import` |
| Statusline script | `~/.claude-shared/statusline-client.sh` | Reads `CLAUDE_CONFIG_DIR`, labels the footer with the client name |

**Shell integration** (managed by the `claude-session` CLI, not this script):

| Piece | Path | Purpose |
|---|---|---|
| Launcher block | `~/.zshrc` or `~/.bashrc` | `cc-<client>` functions that set the env var and launch; neutered bare `claude`; a global, auto-sourcing `claude-session` command |

The result is a **three-tier memory stack** inside any repo:

```
1. Shared global   ~/.claude-shared/global.md          (all clients, via import)
2. Client-local    <config-dir>/CLAUDE.md              (per billing entity)
3. Project-local   ./CLAUDE.md at the repo root         (per project, config-dir-independent)
```

Credentials and usage windows stay **fully isolated** per config dir. This tool only shares memory *content* and the statusline *script* — never auth.

---

## Requirements

- **macOS or Linux** with `bash`.
- **Claude Code** installed and working.
- **`jq`** — recommended but not required. Used only for (a) the statusline's model/directory fields and (b) safely merging into a *pre-existing* `settings.json`. Without it, the client label still shows and a fresh `settings.json` is still written; only those two things degrade. Install on macOS with `brew install jq`.

The script never hard-fails on a missing `jq`; it tells you exactly what to add by hand if it can't do it safely.

---

## Installation

From the repo root, run the `claude-session` CLI — it copies this skill folder into your Claude Code skills directory (so Claude can trigger it by name), installs a global `claude-session` command, and bootstraps the clients you name in the same step:

```bash
./claude-session --create macleod clientA   # install skill + bootstrap clients
```

The shared files it creates live outside any one config dir, so installing it in your default location makes it usable from every account.

You can also skip the CLI entirely and call this script directly — see below.

---

## Quick start (three clients)

Assume three accounts: `macleod` (your own), `clientA`, `clientB`.

### 1. Bootstrap each client

Pass every client name to `claude-session --create`. It copies the skill into
place, then for each name derives that client's config dir
(`~/.claude-clients/<name>`) and sets up its memory, statusline, and
`cc-<client>` launcher. No `export` needed. The first run also creates the
shared files.

```bash
./claude-session --create macleod clientA clientB
```

(Equivalent low-level call for memory+statusline only, one client at a time:
`bash scripts/setup.sh --client macleod`. Launchers are added by the CLI.)

### 2. Load the launchers

```bash
source ~/.zshrc        # one time only — afterwards claude-session auto-reloads
```

### 3. From now on, launch by name

```bash
cc-macleod     # = CLAUDE_CONFIG_DIR=~/.claude-clients/macleod claude
cc-clientA
cc-clientB
```

A bare `claude` now refuses to launch and reminds you to pick one — this is deliberate, so you can never silently start an unlabeled session against the default account. To bypass on purpose: `command claude`.

### 4. Verify

Inside any session:

- **`/memory`** — lists the loaded memory files. You should see `~/.claude-shared/global.md` in the tree, proving the shared import resolved.
- **Restart the session**, then look at the **footer** — it should show the client label (e.g. `● macleod`). Statusline changes only load at startup.

---

## Editing your memory

After setup, each client's `CLAUDE.md` looks like this:

```markdown
<!-- claude-config-bootstrap:begin -->
# Imports shared global memory. Managed by claude-config-bootstrap — edit below the end marker.
@/Users/you/.claude-shared/global.md
<!-- claude-config-bootstrap:end -->

## macleod-specific
- Billing entity: macleod
- (client-only conventions go here)
```

- **Shared conventions** → edit `~/.claude-shared/global.md`. Every client picks up the change.
- **Client-specific notes** → edit anything **below** the `:end` marker in that client's `CLAUDE.md`.
- **Never edit** the block between the `:begin` and `:end` markers by hand — it's regenerated by the script. Everything outside it is yours and is preserved on every re-run.

---

## Idempotency — re-running is always safe

Every action checks current state first and only writes when something is missing or has drifted. Re-running on an already-configured dir prints all ✓ and changes nothing. Specifically:

- Your hand-written memory below the marker is **preserved verbatim**.
- An existing `settings.json` is **merged** (other keys untouched), never clobbered — and if it's invalid JSON, the script refuses rather than corrupt it.
- `~/.claude-shared/global.md` is created only if absent; it's **never overwritten**.
- The launcher block is regenerated from the live set of config dirs and lives between sentinel markers; the rest of your rc file is untouched, and a `.ccbak` backup is written before any edit.

Always-safe dry run to preview:

```bash
bash scripts/setup.sh --client macleod --check
```

---

## Flags

| Flag | Default | Purpose |
|---|---|---|
| `--client NAME` | derived from dir name | Label for this config dir; derives `CLIENTS_PARENT/<name>`. Sanitized to alphanumerics, `_`, `-`. |
| `--shared-dir PATH` | `~/.claude-shared` | Where the shared `global.md` and statusline live. Keep identical across clients. |
| `--no-statusline` | off | Set up only the memory files; skip the statusline. |
| `--clients-parent PATH` | `~/.claude-clients` | Where client config dirs live. |
| `--check` | off | Dry run: report state, change nothing. |
| `-h`, `--help` | — | Usage. |

Shell launchers, deletion, and revert are the `claude-session` CLI's job — see the repo README.

---

## How it works (mechanics)

**Config-dir detection.** When you pass `--client <name>`, the script derives the dir as `~/.claude-clients/<name>` — no environment needed. Otherwise it reads `CLAUDE_CONFIG_DIR` to learn which dir to configure (it can't *set* that variable for your shell — a child process can't export into its parent — which is why launching Claude itself relies on the `cc-<client>` launchers exporting it). With neither, it falls back to `~/.claude` (the default account) and warns loudly.

**The `@import`.** Claude Code's `CLAUDE.md` supports importing other files with `@path`. The managed block at the top of each client's memory imports the shared file using an **absolute path** (most robust across versions). That's how three separate accounts share one set of conventions.

**The statusline.** Claude Code pipes a JSON blob to a script on every tick and renders whatever it prints as the footer. The shared script reads `CLAUDE_CONFIG_DIR` (inherited from the launching shell) to derive the client label, then adds model, directory, and git branch. Because the label comes from the env var, not the JSON, it works even without `jq`.

**The launchers.** A single sentinel-delimited block in your rc file defines one function per bootstrapped config dir, a neutered `claude`, and the global `claude-session` command. The `claude-session` CLI rebuilds that block from the live set of dirs on every run, so it stays in sync as you add or remove clients.

---

## Rate-limit rotation pools (mechanics)

The repo's `claude-session` CLI can give a client a **rotation pool** — sibling
accounts it fails over to on a rate limit, resuming the same conversation. The
skill ships the two runtime pieces; the CLI wires them. Full user-facing
walkthrough is in the repo README; this section is the reference.

**Files:**

| Piece | Path | Purpose |
|---|---|---|
| Supervisor | `~/.claude-shared/cc-rotate` | Launches `claude` per pool dir; on the rotate signal relaunches the next dir with `--resume <session-id>` |
| Hook helper | `~/.claude-shared/cc-rotate-kill` | `StopFailure` hook target; signals the supervisor and TERMs claude |
| Pool file | `~/.claude-shared/pools/<client>.pool` | Ordered list of config-dir paths — rotation order, primary first |
| Sync helper | `~/.claude-shared/cc-pool-sync` | Tooling + third-party-auth parity: full sync at `--pool-add` and each rotation, `--push-mcp` hook mode at `SessionEnd` |
| Shared history | `~/.claude-shared/pools/<client>-projects/` | The pool's one real `projects/` dir; every member's `projects` is a symlink to it |
| Member marker | `<member-dir>/.ccb-pool-member` | Contains the primary's name; tells the CLI this dir is a pool member, not a standalone client (no `cc-` launcher is generated for it) |

**Detection.** Each pool dir's `settings.json` gets a `hooks.StopFailure` block
with matchers `rate_limit` and `billing_error` pointing at `cc-rotate-kill`
(merged via `jq` when the file exists; the script prints the snippet to add by
hand if `jq` is missing — same policy as the statusline). `StopFailure` fires
on the structured API error, so there are no false positives from chat text
that merely mentions rate limits.

**The gate.** `cc-rotate-kill` is a silent no-op unless `CC_ROTATE_ACTIVE=1`
and a live supervisor pid file are present in the environment — both are set
only by `cc-rotate`. So the hook is harmless when a pool dir is launched
directly (e.g. for `/login`), and plain `cc-<client>` sessions without a pool
never rotate.

**Why the history symlinks are load-bearing.** `claude --resume <id>` looks the
transcript up under the *active* config dir's `projects/`. Without the shared
dir, switching accounts means `No conversation found with session ID`. The CLI
therefore moves the primary's existing `projects/` into the pool's shared
location on first `--pool-add` (merge, never delete) and symlinks every member
to it. Transcripts carry no account binding, so any member can replay them.
A resume can mint a new session UUID, which is why the supervisor re-reads the
newest `.jsonl` filename after every rotation rather than trusting the old id.

**Third-party auth parity ("relight").** `cc-pool-sync` runs at `--pool-add`,
before every rotation, and from a `SessionEnd` hook on each member. Besides
MCP definitions, plugins, and skills, it cherry-picks the *third-party* keys
out of `.credentials.json` — `mcpOAuth` (freshest `expiresAt` wins, since
refresh tokens rotate on use), `mcpOAuthClientConfig`, `pluginSecrets` — and
the Chrome-extension pairing keys out of `.claude.json`, so OAuth-backed MCP
servers and secret-holding plugins stay logged in across a switch. The
Anthropic account keys (`claudeAiOauth`, `trustedDeviceToken`, `designOauth`,
`organizationUuid`, `enterpriseGateway`) are **never read or copied** — each
member keeps its own login. Needs `jq` (prints what to run by hand without
it); no-op on macOS, where the credential store is the keychain. Full
investigation and design rationale: `docs/relight.md` in the repo.

**Failure policy.** Pool exhausted → red stderr, non-zero exit, and a manual
`claude --resume` command you can run by hand later. A non-rate-limit exit
(user quits, crash) passes straight through with claude's own exit code.

**Teardown symmetry.** `--pool-remove` of the last member, `--delete` of a
pooled primary, and `--revert` all restore or intentionally delete the shared
history — `--revert` moves it back into the primary dir *before* removing
`~/.claude-shared`, so no transcripts are lost. The `StopFailure` hook is left
in `settings.json` after a disband (it's inert without the supervisor).

---

## Why nest under `~/.claude-clients/` instead of `~/.claude/`

Putting client dirs *inside* `~/.claude/` technically works, but couples them to the one directory most likely to be wiped or scanned: `~/.claude` is the default account's home, and `rm -rf ~/.claude` or usage tools globbing `~/.claude/projects/` would sweep up all your clients and merge their histories across billing entities. A sibling directory (`~/.claude-clients/`) keeps the default account cleanly separate and out of the blast radius. That's the layout this tool defaults to.

---

## Troubleshooting

**The footer doesn't show the label.** Statusline loads at startup — restart the session. Confirm `settings.json` in that config dir has a `statusLine.command` pointing at `~/.claude-shared/statusline-client.sh`.

**`/memory` doesn't list the shared file.** The import path may not be resolving. The script uses an absolute path, which is the most reliable form; if your Claude Code version is older, open the client's `CLAUDE.md` and confirm the `@` line points at a real, absolute path to `global.md`.

**Footer shows `⚪ DEFAULT(~/.claude)`.** You launched a session without `CLAUDE_CONFIG_DIR` set — it's using the default account. Use a `cc-<client>` launcher instead. (This warning is the whole point of the neutered bare `claude`.)

**Launchers don't exist after install.** You need to reload your shell: `source ~/.zshrc` or open a new terminal.

**Model/directory missing from the footer.** `jq` isn't installed. `brew install jq`. The client label works regardless.

**Wrong rc file edited.** The `claude-session` CLI infers the rc file from `$SHELL` (`~/.zshrc` or `~/.bashrc`); override with the `RC_FILE` environment variable.

---

## Uninstall

**Remove the launchers:** delete the block between these two lines in your rc file (a `.ccbak` backup sits next to it):

```
# >>> claude-config-bootstrap launchers >>>
# <<< claude-config-bootstrap launchers <<<
```

**Remove a client's config entirely:** delete its config dir (this also removes that account's local login and history):

```bash
rm -rf ~/.claude-clients/<client>
```

**Remove the shared files:**

```bash
rm -rf ~/.claude-shared
```

**Remove the skill:**

```bash
rm -rf ~/.claude/skills/claude-config-bootstrap
```

---

## Files in this package

```
claude-config-bootstrap/
├── SKILL.md              # Agent-facing trigger doc (used by Claude Code's skill system)
├── README.md            # This file (human-facing reference)
└── scripts/
    ├── setup.sh         # The idempotent per-config-dir setup script
    ├── cc-rotate        # Rotation supervisor (installed to ~/.claude-shared by the CLI)
    └── cc-rotate-kill   # StopFailure hook helper (installed alongside it)
```

`SKILL.md` is what Claude reads to decide when to run this; `README.md` is for you. `setup.sh` configures one config dir; the `cc-rotate` pair powers the optional rate-limit rotation pools managed by the `claude-session` CLI.
