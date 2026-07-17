<div align="center">

![Claude Sessions — run many Claude Code accounts on one machine](assets/hero.png)

[![License: MIT](https://img.shields.io/badge/License-MIT-7c5cff.svg?style=flat-square)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-22d3ee.svg?style=flat-square)
![Shell](https://img.shields.io/badge/shell-bash-34d399.svg?style=flat-square)
![Claude Code skill](https://img.shields.io/badge/Claude%20Code-skill-a78bfa.svg?style=flat-square)
![Idempotent](https://img.shields.io/badge/setup-idempotent-febc2e.svg?style=flat-square)

</div>

# Claude Sessions

Run several **Claude Code** accounts on one machine — isolated credentials,
distinct footers, and shared-plus-local memory — via the
`claude-config-bootstrap` skill in this repo.

One command — `claude-session` — installs the skill and bootstraps your
clients. No copying zips, no exporting environment variables by hand. Replace
`macleod` / `clientA` / `clientB` with your real client names.

---

## Quick start

```bash
git clone <this-repo> claude-sessions
cd claude-sessions
./claude-session --create macleod clientA clientB
source ~/.zshrc   # one time only — see note below
```

That's it. `--create` copies the skill into `~/.claude/skills/`, installs a
global `claude-session` command, and for each client creates its config dir,
memory, statusline, and a `cc-<client>` launcher. The first launch logs that
account in:

```bash
cc-macleod
```

Each client runs in its own terminal. Launch as many at once as you like:

```bash
cc-macleod
cc-clientA
cc-clientB
```

A bare `claude` is disabled on purpose so you can't start an unlabeled session
against the wrong account. To bypass it deliberately:

```bash
command claude
```

> **The one-time `source`.** A script can't reload its parent shell, so the
> *first* run needs `source ~/.zshrc` (or a new terminal). After that,
> `claude-session` is installed as a shell function — available in every
> terminal and **auto-reloading your shell** after each run, so you never type
> `source` again.

<p align="center">
  <img src="assets/footer.png" alt="Claude Sessions — run many Claude Code accounts on one machine" width="100%">
</p>
---

## Managing clients

`claude-session` is global after first install — run it from anywhere:

```bash
claude-session --create newclient   # add one or more clients
claude-session --list               # list configured clients
claude-session --delete clientA     # remove one or more clients (prompts first)
```

Every subcommand is idempotent and refreshes the launchers from the live set of
clients (the shell reloads automatically).

## Rate-limit rotation (pools)

A client can have a **rotation pool**: extra accounts (each with its own
subscription) that `cc-<client>` automatically fails over to when the active
account hits its rate limit — killing the session, relaunching under the next
account, and **resuming the same conversation** with `--resume` (~2s gap,
context intact). Clients without a pool are completely unaffected.

It's a restart+resume supervisor, not a proxy: every request is made by the
real `claude` binary using that account's own login. No tokens are extracted,
shared, or proxied.

### Upgrading an existing setup

Already running `claude-session` with clients like `macleod` / `nr` / `iris`?
Nothing to migrate — pool support installs over the top:

```bash
cd claude-sessions && git pull
./claude-session --pool-add macleod    # run from the repo once; upgrades itself too
```

That single command upgrades the installed `claude-session`, installs the
`cc-rotate` supervisor, and converts `macleod` to pooled mode:

1. Creates and bootstraps `~/.claude-clients/macleod-2` (memory, statusline,
   rate-limit hook) and writes the pool file
   `~/.claude-shared/pools/macleod.pool` (`macleod` first, `macleod-2` second).
2. Moves macleod's existing session history to the pool's shared location and
   symlinks it back — **all existing macleod sessions stay resumable**, now
   from any account in the pool.
3. Launches Claude under `macleod-2` so you can log the new account in
   (see below).

Other clients (`cc-nr`, `cc-iris`) have no pool file, so they keep launching
directly — zero behavior change.

### Logging in the new account (the login IS the connection)

There's no separate "linking" step: a pool member is just an isolated config
dir, and it's connected the moment you log a subscription into it. At the end
of `--pool-add` you land in Claude Code under the new dir:

1. Run `/login` if you're not prompted automatically.
2. In the browser OAuth page, **sign into your *second* Anthropic account** —
   the new Pro/Max subscription, *not* the one macleod already uses. If the
   browser auto-picks your usual account, switch accounts on that page.
   (Reusing the same account would mean both pool members share one rate
   limit — pointless.)
3. Exit Claude. Done — credentials live in `~/.claude-clients/macleod-2`,
   isolated exactly like your other clients.

Quit before finishing, or want to re-login later? No need to re-create
anything:

```bash
CLAUDE_CONFIG_DIR=~/.claude-clients/macleod-2 command claude   # then /login
```

### Daily use

```bash
cc-macleod          # exactly as before
```

`cc-macleod` starts on your primary account. When it hits its 5-hour limit, a
`StopFailure` hook fires, the supervisor switches to `macleod-2`, and your
conversation resumes automatically (the statusline label shows which account
is active). When **every** account in the pool is limited it fails loud —
red message, soonest-reset hint, non-zero exit — never a silent fallback.

```bash
claude-session --pool-add macleod      # add another account (macleod-3, ...)
claude-session --pool-list macleod     # members, rotation order, login state
claude-session --pool-remove macleod-2 # remove an account (prompts first)
```

Removing the last member disbands the pool: `cc-macleod` goes back to
single-account and its session history moves back into its own dir.

> **A word on terms of service.** This keeps every request inside the genuine
> Claude Code binary with that account's own OAuth login — it avoids the
> token-proxy pattern Anthropic actively bans. Rotating accounts to extend
> usage is still a gray area under Anthropic's limit-circumvention policy:
> keep it to your own subscriptions at a human pace, and know that heavy
> always-on workloads belong on API-key billing instead.

---

### Removing everything

```bash
claude-session --revert          # remove tooling, keep account dirs
claude-session --revert --force  # also delete every account dir
```

`--revert` removes the rc launcher block (restoring a normal bare `claude`), the
global command, and `~/.claude-shared`. By default your `~/.claude-clients/*`
account dirs are kept and reported (they hold real logins/history); add
`--force` to delete those too (pool members included). Add `-y`/`--yes` to skip
confirmation prompts. Pooled session history is restored to each client's
primary dir *before* the shared dir is deleted, so no transcripts are lost.

---

## Editing memory

| Want to change… | Edit this file |
|---|---|
| Shared rules (all clients) | `~/.claude-shared/global.md` |
| One client's rules | `~/.claude-clients/<client>/CLAUDE.md` — add lines **below** the `:end` marker |
| One project's rules | `CLAUDE.md` in that repo |

Never edit between the `:begin` / `:end` markers — that block is auto-managed.

---

## Check it's working

Inside a session:

- `/memory` → should list `global.md` (the shared import is loading)
- Look at the footer → shows the client name (e.g. `● macleod`)

If the footer is blank or wrong, quit and relaunch with `cc-<client>`.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `cc-macleod: command not found` | `source ~/.zshrc` (or open a new terminal) |
| Footer shows `⚪ DEFAULT` | You didn't use a `cc-` command. Quit, relaunch with `cc-<client>`. |
| Footer missing model/folder | Install jq: `brew install jq` |
| Footer didn't change after setup | Quit Claude and relaunch with `cc-<client>` |
| Rotation didn't fire on a rate limit | Check the pool member's `settings.json` has the `StopFailure` hook and that you launched via `cc-<client>` (direct `claude` runs never rotate — that's the safety gate) |
| `No conversation found with session ID` after a switch | The pool dirs must share history — `claude-session --pool-list <client>` should show every member; re-run `--pool-add` wiring by checking each dir's `projects` is a symlink into `~/.claude-shared/pools/` |
| Pool member shows `NO CREDENTIALS` | `CLAUDE_CONFIG_DIR=~/.claude-clients/<member> command claude`, then `/login` |

---

## How it works

`claude-session` (repo root) owns the shell integration — the `cc-<client>`
launchers, the bare-`claude` guard, and the global, auto-sourcing
`claude-session` command — and delegates per-client memory + statusline config
to the skill's `setup.sh`. The skill ships as plain files under
`claude-config-bootstrap/` (`SKILL.md`, `README.md`, `scripts/setup.sh`);
`--create` copies that folder into `~/.claude/skills/` so Claude Code can also
trigger it by name. `setup.sh` is idempotent and self-contained. For the full
design, flags, and mechanics, read
[`claude-config-bootstrap/README.md`](claude-config-bootstrap/README.md).

---

## License

[MIT](LICENSE) © 2026 Macleod Labs https://macleodlabs.ai 
