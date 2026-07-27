# Relogin: automating MCP + Chrome-extension re-login on account switch

**Status: Phase 1 (MCP OAuth + plugin-secret relogin) and the Phase 2 Chrome
pairing sync are IMPLEMENTED in `cc-pool-sync` (v1.1.0). v1.2.0 adds the
Phase 1b provisioning hints (`--pool-list`/`--pool-add` name each MCP server
still awaiting its one-time `claude mcp login`) and the Phase 2 Chrome
profile map (`pools/<client>.chrome-profiles`, printed by `cc-rotate` on
switch).** Still open: macOS keychain support — deliberately unimplemented,
because on macOS the third-party keys live inside the same keychain item as
the Anthropic login, and rewriting that item from a script risks corrupting
the login store (the exact failure mode this design forbids); authenticate
once per member there. Rollback: see "Versioning" at the end.
Researched 2026-07-27 against Claude Code v2.1.220, this repo's pool/rotation
machinery, and the upstream `anthropics/claude-code` issue tracker + changelog.

## Problem

Rotation pools make sessions survive a rate limit — transcripts, skills,
plugins, agents, commands, and MCP *definitions* all carry across the switch
(symlinks + `cc-pool-sync`). Two things still die and need a manual relogin
on every switch to a member account:

1. **OAuth-backed MCP servers** (Linear, Notion, …) — each member must run
   `/mcp` → authenticate once per server.
2. **Claude in Chrome pairing** — the browser extension needs `/chrome`
   re-pairing, and may refuse to connect at all under the rotated account.

This doc records where that state actually lives, what upstream will and won't
fix, and the recommended automation design.

## Where the state actually lives

Everything below was verified against the shipped `claude` binary (the file
layout is not fully documented). Per config dir (`CLAUDE_CONFIG_DIR`):

| State | File | Scope | Carried across rotation today? |
|---|---|---|---|
| `claudeAiOauth` (Anthropic login) | `<dir>/.credentials.json` | Anthropic account | No — **by design**, this is the whole point of separate accounts |
| `mcpOAuth`, `mcpOAuthClientConfig` (third-party MCP tokens: accessToken, refreshToken, clientId, clientSecret, expiresAt, scope per server) | **same** `.credentials.json` | third-party service | **No — the gap** |
| `trustedDeviceToken` (Remote Control bridge) | same `.credentials.json` | Anthropic account | No (one-time re-enroll per member, then persists in that dir) |
| MCP server *definitions* | `<dir>/.claude.json` `.mcpServers` | neither | Yes (`cc-pool-sync`) |
| `chromeExtension.pairedDeviceId` / `.pairedDeviceName`, `cachedChromeExtensionInstalled` | `<dir>/.claude.json` | local device pairing — **no secrets** | **No — the other gap** |
| `mcp-needs-auth-cache.json`, `mcp-discovery-cache/` | `<dir>/` | third-party | No (harmless, but stale "needs auth" nags) |
| Native-messaging host manifest, `/tmp/claude-mcp-browser-bridge-$USER` socket | outside any config dir | machine/user | Yes (implicitly shared already) |

Key facts that shape the design:

- **MCP OAuth tokens sit in the *same* `.credentials.json` as the Anthropic
  login**, as sibling top-level keys. On macOS the whole store is one Keychain
  item (`Claude Code-credentials`, suffixed `-<sha256(configDir)[:8]>` for
  non-default dirs). Linux/Windows: plain file, mode 0600.
- **MCP OAuth grants are independent of the Anthropic account.** They are
  grants from Linear/Notion/etc. to *this human*; switching the active
  Anthropic account does not invalidate them. They're merely stranded in the
  other config dir. Copying them between members leaks no Anthropic
  credential and touches no Anthropic token — it is not the ToS ban vector
  (which is proxying/extracting *Anthropic* OAuth).
- **`CLAUDE_SECURESTORAGE_CONFIG_DIR`** (undocumented, first-class in the
  binary) points the credential store at a different directory than
  `CLAUDE_CONFIG_DIR`. It moves the *whole* store — `claudeAiOauth` included —
  so it cannot unify pools (members must keep distinct Anthropic logins), but
  see "single-login variant" below.
- **Chrome pairing is per config dir but secret-free** (`pairedDeviceId` is a
  local device identifier). However, since v2.1.208/2.1.216 upstream
  *enforces* that the CLI's Anthropic account matches the claude.ai account
  the Chrome profile is logged into, and the extension has **no account
  selector** (feature request dup-closed as #69208).

## What upstream will and won't fix (build-vs-wait)

Shipped and usable now:

- `claude mcp login <server>` / `logout` (v2.1.186+) — scriptable per-dir MCP
  auth from the shell, `--no-browser` paste-the-URL flow for headless.
- `--callback-port` — pins the OAuth callback port. Without it the credential
  key embeds a random ephemeral port, which is why parallel instances re-auth
  (#43000, closed not-planned; the flag is the sanctioned mitigation).
- `headersHelper` + `${ENV}` expansion in `.mcp.json` (v2.1.195+) — servers
  that accept static tokens can skip OAuth entirely via a shared script.
- Auto refresh on 401/reconnect (v2.1.206/2.1.208).

Requested but going nowhere (don't wait):

- Multi-account login/switching (`gh auth switch`-style): ~a dozen issues,
  all dup-closed or stale — canonical open one is
  [#30031](https://github.com/anthropics/claude-code/issues/30031); `/login`
  in-place switching closed not-planned
  ([#23906](https://github.com/anthropics/claude-code/issues/23906)).
  `CLAUDE_CONFIG_DIR`-per-account (this repo's design) is the converged
  community pattern; no sign it gets obsoleted.
- MCP token export/import or cross-dir sharing: no issue, no primitive. The
  on-disk format is fully reverse-engineered in
  [#43000](https://github.com/anthropics/claude-code/issues/43000) /
  [#59460](https://github.com/anthropics/claude-code/issues/59460) (open:
  every re-auth re-runs Dynamic Client Registration, orphaning the previous
  refresh token — the area churns, so copied tokens are valid but fragile).
- Chrome extension account selector decoupled from browser login:
  dup-closed ([#69208](https://github.com/anthropics/claude-code/issues/69208)).
  Upstream direction is the opposite — enforce account match.

**Verdict: build locally.**

## Recommended design

### Phase 1 — MCP OAuth relogin (high value, low risk)

Extend `cc-pool-sync` with a credential-key cherry-pick, alongside the
existing `.claude.json` merge:

1. `sync_credentials <from> <to>`: with `jq`, copy **only** the `mcpOAuth`,
   `mcpOAuthClientConfig`, and `pluginSecrets` top-level keys from
   `<from>/.credentials.json` into `<to>/.credentials.json`, per-server,
   **freshest-wins by `expiresAt`** for tokens. (`pluginSecrets` holds plugin
   API keys — service-scoped exactly like MCP grants, so it syncs on the same
   rationale; it was originally on the never-copy list out of caution.)
   Never read or write `claudeAiOauth`, `trustedDeviceToken`, `designOauth`,
   `organizationUuid`, `enterpriseGateway`. Create the target
   file `{}` if absent; `chmod 600` before writing content; write via temp
   file + `mv` in the same directory.
2. Run it in all three existing sync moments: `--pool-add` provisioning, each
   `cc-rotate` iteration (`LAST_DIR` → next dir), and the `SessionEnd`
   `--push-mcp` hook (so a token refreshed mid-session propagates before the
   next launch — this defuses the "snapshots go stale in hours" rotation
   problem, since refresh tokens rotate on use).
3. Delete `<to>/mcp-needs-auth-cache.json` after a successful copy so the
   startup "servers need auth" notice doesn't lie.
4. Fallback when `jq` is missing or on macOS-keychain dirs: print the exact
   `claude mcp login <server>` commands per member instead (see Phase 1b).
   Keychain support (`security find/add-generic-password` against the
   suffixed service name) is possible but deferred — file format inside the
   keychain item is the same JSON blob.

Why copy rather than symlink one shared `.credentials.json`: the file also
holds `claudeAiOauth`, and pool members are *different* Anthropic accounts.
A shared store would collapse the isolation that makes rotation work.

Known fragility (accepted): upstream DCR churn (#59460) means a manual
`/mcp` re-auth on one member mints a fresh OAuth client and can orphan the
copied refresh tokens on siblings — the next SessionEnd push re-heals them.

### Phase 1b — first-provision auth, and OAuth-free servers

- Implemented (v1.2.0): `--pool-list` (and therefore the pool status printed
  at the end of `--pool-add`) names every remote MCP server that still lacks
  an OAuth grant in each member dir, with the `claude mcp login <server>`
  command to run. With Phase 1 in place that auth is needed **once, on any
  member** — the sync fans it out. (Consider `--callback-port <fixed>` in
  server definitions so credential keys stay stable across instances.)
- Document the zero-relogin option for servers that accept static tokens
  (GitHub PAT, Sentry, internal servers): define them with
  `headers.Authorization = "Bearer ${VAR}"` or a `headersHelper` script that
  reads a token from `~/.claude-shared/` — one token, all members, no OAuth
  at all.

### Phase 2 — Chrome extension

Two distinct sub-problems:

1. **Pairing state** (`chromeExtension.*`, `cachedChromeExtensionInstalled`
   in `.claude.json`): add these keys to `cc-pool-sync`'s `.claude.json`
   merge (additive, source wins). Secret-free, and removes the `/chrome`
   re-pair dance where accounts permit connection.
2. **Account match** (the hard wall): the extension authenticates as the
   claude.ai account of the *Chrome profile*, and since v2.1.208/2.1.216 the
   CLI refuses/flags a mismatch. There is no unify-to-one-login here and no
   scripting surface. The only working pattern for cross-account rotation is
   **one Chrome profile per pool member**, each logged into the matching
   claude.ai account. Implemented (v1.2.0, print-only): create
   `~/.claude-shared/pools/<client>.chrome-profiles` with one
   `<member-name>=<profile name>` line per member (blank lines and
   `#`-comments allowed), and `cc-rotate` names the matching profile on each
   switch — it never launches or kills the browser.
3. **Remote Control** already re-arms via `--remote-control` re-add in
   `cc-rotate`; `trustedDeviceToken` is Anthropic-account-scoped so each
   member enrolls once and then keeps it in its own dir. No action; document.

### Rejected: unify to a single login

- `CLAUDE_SECURESTORAGE_CONFIG_DIR` pointed at a shared dir gives all config
  dirs one credential store — one login, one set of MCP grants. That is the
  right tool for the *single-account, many-client-dirs* user (worth a README
  note), but for rotation pools it would make every member the same Anthropic
  account, which defeats rate-limit rotation entirely.
- Anything that proxies or extracts the Anthropic OAuth token to fake a
  unified login stays out of scope permanently (ToS ban vector — repo
  invariant).

## Upstream asks worth filing / upvoting

- [#30031](https://github.com/anthropics/claude-code/issues/30031) — native
  multi-account switching (upvote).
- [#69208](https://github.com/anthropics/claude-code/issues/69208) /
  successor — Chrome extension account selector (upvote/refile).
- [#59460](https://github.com/anthropics/claude-code/issues/59460) — DCR
  client reuse (upvote; it's what makes token copies fragile).
- [#20215](https://github.com/anthropics/claude-code/issues/20215) — device
  authorization grant for headless MCP auth.
- New: `claude mcp login --if-needed` (exit 0 silently when a valid token
  exists) so a `SessionStart` hook can relogin non-interactively; and
  documented export/import of `mcpOAuth` entries.

## Invariants for the implementation

- Never copy, share, proxy, or log `claudeAiOauth`, `trustedDeviceToken`,
  `designOauth`, `organizationUuid`, `enterpriseGateway`. (Third-party
  `pluginSecrets` IS synced — same service-scoped rationale as `mcpOAuth`.)
- `.credentials.json` writes: 0600 before content, temp-file + same-dir `mv`,
  target's non-MCP keys preserved verbatim, additive per-server merge.
- `jq` remains optional: without it, fall back to printing the
  `claude mcp login` commands — never risk corrupting the credential file.
- Idempotent: a re-run with identical stores changes nothing.

## Versioning and safe rollback

The repo carries release tags so the relogin machinery can be regressed
cleanly if a Claude Code update changes the credential layout:

- **`v1.0.0`** = commit `b39d5cc` — last state *before* any
  credential/pairing sync existed (`cc-pool-sync` touched only MCP
  definitions, plugins, skills).
- **`v1.1.0`** = commit `82a0b9d` — this implementation (credential relogin
  + Chrome pairing sync + plugin/skill push in the SessionEnd hook;
  `claude-session --version` reports the matching `CCB_VERSION`).
- **`v1.2.0`** = commit `fbcddf4` — Phase 1b/2 follow-up: MCP-login hints in the pool status
  and the `pools/<client>.chrome-profiles` map printed by `cc-rotate`.

The remote this was developed through only accepts branch pushes, so the
tags exist locally on the dev container; recreate/push them from any normal
clone:

```bash
git tag -a v1.0.0 b39d5cc -m "Pre-relogin baseline"
git tag -a v1.1.0 82a0b9d -m "Third-party auth relogin"
git tag -a v1.2.0 fbcddf4 -m "Relogin follow-up: MCP login hints + Chrome profile map"
git push origin v1.0.0 v1.1.0 v1.2.0
```

To roll back: `git checkout v1.0.0 -- claude-session claude-config-bootstrap`
then re-run `claude-session --create <any-client>` (or `--pool-add`), which
reinstalls the older scripts into `~/.claude-shared/` — the installer copies
on content mismatch, so the downgrade propagates. Already-synced credential
keys are inert data; nothing needs cleaning up on a rollback.
