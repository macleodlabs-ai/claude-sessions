---
name: claude-config-bootstrap
description: Set up or repair an isolated per-client Claude Code config directory with a two-tier CLAUDE.md memory system (a shared global file imported into a client-local file), a client-aware statusline that labels which account or billing entity the session belongs to, and optional shell launcher functions (named cc-clientname) that set the config-dir environment variable automatically plus neuter the bare claude command. Also covers rate-limit rotation pools — adding extra accounts to a client so its cc- launcher automatically fails over to the next account when a rate limit is hit and resumes the same conversation. Use this skill whenever the user wants to configure a new client or work config dir, add shared-plus-local memory across multiple Claude Code accounts, stop sessions from looking identical in the footer, set up per-client launch commands so they don't have to export the config-dir variable by hand, fix a config dir that's missing the shared import or statusline, add a second account or subscription to rotate on rate limits, keep working when they "hit the usage limit", or asks to "set up this Claude", "bootstrap my config", or "run the client setup". Safe and idempotent — re-running only changes what's missing or has drifted, so reach for it even when unsure whether a dir is already configured.
---

# Claude Config Bootstrap

Configures the **currently active** Claude Code config directory so it has:

1. A **shared global** `CLAUDE.md` (one canonical file, `~/.claude-shared/global.md`) that is imported into every client's memory via the `@import` mechanism.
2. A **client-local** `CLAUDE.md` (in this config dir) that imports the shared file and holds client-specific memory below it.
3. A **client-aware statusline** that reads `CLAUDE_CONFIG_DIR` and shows which client/billing entity the session belongs to in the footer — so three terminals running three accounts are visually distinct.

This assumes the user runs each client as an isolated config dir via `CLAUDE_CONFIG_DIR` (e.g. `~/.claude-clients/macleod`). The script detects that dir automatically from the environment; it does not need to be told where it is.

## When to run it

The simplest path is to pass `--client <name>`: the script derives that client's config dir as `~/.claude-clients/<name>` and configures it, so you do **not** need to export `CLAUDE_CONFIG_DIR` first. You can run it from any terminal.

If `CLAUDE_CONFIG_DIR` **is** set in the environment, it wins — the script configures whatever dir is active (useful when you run the script inside the very session you're configuring). With neither `--client` nor the env var, it falls back to the default `~/.claude` and warns loudly, because that's the account a bare `claude` uses — usually not what someone setting up per-client isolation wants.

## How to use

The skill bundles one script: `scripts/setup.sh`. It is idempotent — every action checks current state first and only writes when something is missing or has drifted. Re-running on an already-configured dir prints all ✓ and changes nothing.

**Step 1 — Look before leaping.** Run a dry run first to show the user exactly what will happen, change nothing:

```bash
bash scripts/setup.sh --check
```

This reports which pieces are present vs. missing for the active config dir. Read the output to the user.

**Step 2 — Apply.** Run it for real. Prefer passing the client label explicitly so the run is non-interactive:

```bash
bash scripts/setup.sh --client <name>
```

If `--client` is omitted, the script derives a sensible label from the config dir name (e.g. `~/.claude-clients/macleod` → `macleod`) and, when run interactively, confirms it. In an automated context always pass `--client` so it never blocks on a prompt.

**Step 3 — Verify.** Tell the user to confirm inside Claude Code:
- Run `/memory` — it lists the loaded memory files and their sources. The shared `global.md` should appear in the tree, proving the import resolved.
- **Restart the session** to pick up the statusline (statusline changes load at startup), then check the footer shows the client label.

## Rate-limit rotation pools (handled by the `claude-session` CLI)

A client can hold a **rotation pool** of extra accounts (each its own
subscription). With a pool, the `cc-<client>` launcher routes through the
`scripts/cc-rotate` supervisor: when the active account hits its rate limit, a
`StopFailure` hook fires, the supervisor relaunches `claude` under the next
account in the pool, and resumes the same conversation with `--resume`.
Session history is shared across the pool's dirs via symlinks so the resume
always finds the transcript.

When the user asks to add a rotation account, rotate on rate limits, or keep
working past a usage limit, run (from anywhere, once installed):

```bash
claude-session --pool-add <client>     # creates <client>-2, walks through login
claude-session --pool-list <client>    # members, order, login state
claude-session --login <name>          # (re)log in an account by name; a pooled
                                       # client name logs in every member missing creds
claude-session --pool-remove <name>    # remove a member; last removal disbands
```

Two things to tell the user every time:
1. The new member must be logged into a **different** subscription than the
   primary (the `/login` at the end of `--pool-add` is where that happens).
2. This rotates the user's **own** accounts via the genuine claude binary — no
   token extraction or proxying — but rotating to extend usage is a gray area
   in Anthropic's terms; keep it to human-paced, interactive use.

## Shell launchers (handled by the `claude-session` CLI)

This script configures memory + statusline for **one** config dir. It does **not** touch the shell rc file. The per-client launcher functions (`cc-<client>`), the neutered bare `claude` guard, and the global `claude-session` command are managed by the `claude-session` CLI that ships alongside this skill in the repo. The usual entry point is `claude-session --create <name>...`, which copies this skill into place, calls this script per client, and then installs the launchers. There's no `--install-launchers` flag here anymore.

## Flags

- `--client NAME` — client/label for this config dir. Sanitized to alphanumerics, `_`, and `-`. With it, the config dir is derived as `CLIENTS_PARENT/<name>` (no env var needed).
- `--shared-dir PATH` — where the shared `global.md` lives. Default `~/.claude-shared`. Keep this the same across all clients so they share one file.
- `--no-statusline` — set up only the memory files, skip the statusline.
- `--clients-parent PATH` — where client config dirs live. Default `~/.claude-clients`.
- `--check` — dry run; report state, change nothing.
- `-h`, `--help` — usage.

## What it writes (and what it leaves alone)

In the active config dir:
- `CLAUDE.md` — a small **sentinel-delimited managed block** at the very top holds the `@import` of the shared file. **Everything the user writes below the end marker is preserved verbatim** on every re-run. If the shared path later changes, only the managed block is refreshed; user content stays put. If a `CLAUDE.md` already exists with no managed block, the block is prepended and the existing content kept.
- `settings.json` — sets `statusLine.command` to point at the shared statusline script. An existing `settings.json` is **merged** (all other keys preserved) when `jq` is available; a brand-new one is written directly with no dependency.

Shared, written once and then left untouched on re-runs:
- `~/.claude-shared/global.md` — starter shared memory (only created if absent; never overwritten).
- `~/.claude-shared/statusline-client.sh` — the client-aware statusline, shared by all config dirs.

## Running it for each client

The user has multiple accounts, so the workflow is: open each client's terminal (with that client's `CLAUDE_CONFIG_DIR` exported), and run the skill once in each. The shared files are created on the first run and reused by the rest; each run only adds that client's local `CLAUDE.md` block and `settings.json` pointer. Order doesn't matter and running it again later is always safe.

## Dependencies

Pure Bash plus standard Unix tools. `jq` is used for two things only: reading `.model.display_name`/`.workspace.current_dir` in the statusline, and **merging** into a pre-existing `settings.json`. Without `jq` the statusline still shows the client label (the important part) and a fresh `settings.json` is still written; only merging into an existing settings file and the model/dir fields degrade. On macOS, `brew install jq` covers it. The script never hard-fails on a missing `jq`.

## After setup: the three-tier memory the user ends up with

Inside any repo for a given client, three layers merge:
1. **Shared global** — `~/.claude-shared/global.md` (same for all clients, via import)
2. **Client-local** — this config dir's `CLAUDE.md` (per billing entity)
3. **Project-local** — `./CLAUDE.md` at the repo root (per project, loads regardless of config dir)

Anthropic credentials and usage windows remain fully isolated per config dir — this skill never copies an Anthropic login. Within a rotation pool, `cc-pool-sync` additionally relights *third-party* auth between members (MCP server OAuth tokens, plugin secrets, and the Chrome-extension pairing) so tools stay logged in across a rate-limit switch; on macOS the credential store is the keychain and each member authenticates its MCP servers once (`claude mcp login <server>`).
