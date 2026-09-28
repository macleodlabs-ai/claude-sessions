# Browser sync (experimental)

Use the account of a local Claude Code session, including messages sent through
Remote Control from a phone, to prepare one shared Chrome profile. This is an
**experimental handoff, not verified unattended switching of the official
Claude extension**. No mobile account-change detection or iPhone Shortcut is
needed. Merely opening/viewing a session does not trigger hooks.

## Current behaviour and verification gate

1. `SessionStart` / `UserPromptSubmit` record only session ID, config path and time.
2. The first `PreToolUse` for `mcp__claude-in-chrome__*` reserves the browser for
   `(CLAUDE_CONFIG_DIR, session_id)` and denies that call pending verification.
3. The companion extension polls the local helper, restores the mapped website
   login from Keychain, verifies the website email, and reloads Claude tabs.
4. **On the Mac, open the official Claude extension and check its account.**
   If it retained the old account, sign into the requested account there.
   In the companion popup, type that verified email and confirm. This is a human
   assertion, not programmatic proof of the official extension's identity.
5. Retry the browser request in the same Claude Code session. Further browser
   calls can proceed while that session owns the browser. Other sessions are denied.
6. `Stop` / `SessionEnd` releases a verified handoff. Unverified/failed requests
   stay reserved so a denied tool followed by `Stop` does not discard the handoff.

**The first handoff of each turn requires confirmation in this version.** Cookie
switching alone cannot prove official-extension authentication. This draft is
not yet the fully automatic mobile-to-browser workflow. Do not remove the gate
until an extension-specific identity check has been implemented and validated.
No Claude Code credentials are extracted or copied into Chrome.

The ownership lock protects cooperating Claude Code sessions using these hooks.
It does not stop a person, another extension, another browser automation tool,
or an unconfigured terminal from changing the browser. Do not run those during
owned browser work. Detached/background browser work that survives `Stop` is
not supported. No global browser account can serve two accounts concurrently.

## Install on your Mac

Requirements: Chrome, Python 3.9+, Apple's Swift compiler (`xcode-select --install`
if missing), and already-configured `cc-<client>` accounts. Normal Claude Sessions
usage does not gain any new dependencies or hooks until you opt in.

From the updated checkout:

1. Open `chrome://extensions`, enable Developer mode, and **Load unpacked** →
   `browser-sync/extension` in this checkout. Keep the checkout in a stable location.
2. Copy the companion extension's ID (not the official Claude extension's ID).
3. Install its native host and compile the Keychain helper:

   ```bash
   ./claude-session --browser-sync install --extension-id YOUR_COMPANION_EXTENSION_ID
   ```

4. Use the installed helper for subsequent commands:

   ```bash
   browser_sync() { python3 "$HOME/.claude-shared/browser-sync/cc-browser-sync.py" "$@"; }
   ```

   If `SHARED_DIR` is customized, substitute that path. The installer prints it.
   The native host pins the Python interpreter used at installation; rerun install
   after moving/upgrading that interpreter. Reload the companion extension.

5. Log into account A on `claude.ai`. In the companion popup, enter a unique alias
   (e.g. `macleod`) and **Save login to Mac Keychain**. Click **Add another login**,
   sign into B in the new tab, and save it under a different alias. Do not use
   Claude’s server-side Logout to switch during registration: it may revoke the
   saved session. Use a regular Chrome window, not Incognito. Saved sessions
   must be registered independently in the browser; CLI logins are not browser cookies.
6. Bind each existing config directory to its alias and exact email:

   ```bash
   browser_sync bind "$HOME/.claude-clients/macleod" macleod you@example.com
   browser_sync bind "$HOME/.claude-clients/clientA" clientA other@example.com
   ```

7. Restart those Claude Code sessions through their usual `cc-` launchers. Connect
   from mobile as normal. Request a browser action and follow the confirmation gate.

The hook reads the **actual inherited config directory**, never infers account
identity from the project name or a shared conversation ID. Bind each isolated
account you use separately. Aliases/emails are explicit user mappings, not a
claim that the CLI's authenticated email has been independently checked: verify
it using `claude auth status` under that config directory before binding.
Existing hook groups and other settings are preserved; the first changed
settings file is backed up as `settings.json.browser-sync.bak`. Repeat binds are
idempotent. Newly-created accounts are not enrolled automatically.

## Recovery / opt out

```bash
browser_sync status
# Only after all browser work for that owner has stopped:
browser_sync release --config-dir /absolute/owner/config --session-id SESSION_ID --browser-idle
browser_sync unbind "$HOME/.claude-clients/clientA"
browser_sync disable
```

Owner identity is shown by `status`. There is deliberately no automatic lock
expiry: a timeout must not move the browser under an executing task. If Chrome
or its worker crashes in `switching`, **disable the companion extension first**,
stop browser work, then use `release` with the additional `--extension-disabled`
flag. Re-enable it before retrying. This is explicit operator recovery.

`disable` removes only this installation's hook commands and matching native-host
registration. Remove the companion extension via Chrome separately. Saved
Keychain entries remain; delete entries with service
`ai.macleodlabs.claude_sessions.browser` in Keychain Access if no longer wanted.
The existing `claude-session --revert` calls disable before removing shared files.

The companion refreshes its website identity check every two seconds while it
owns the browser. A check older than six seconds blocks subsequent browser calls.

Expired login / website API change / missing helper / identity mismatch denies
browser access. On restore failure the companion attempts to put the original
cookies back, but rollback can also fail: sign in manually before retrying.
The website identity endpoint is internal and may change. Cookie changes to
`sessionKey` after verification invalidate the handoff (including benign token
rotation); release and repeat verification. Do not paste cookies into logs or PRs.

## Architecture / reuse

- `cc-browser-sync.py`: opt-in settings installer, file-locked owner state,
  hook handler and Chrome Native Messaging host. Local IPC only; no TCP server,
  cloud relay or phone credentials. Native host allows only the installed
  companion extension ID. State contains identifiers, never prompts/transcripts.
- `keychain.swift`: saved cookie snapshots go to macOS Keychain through stdin,
  not command-line arguments or `chrome.storage.local`. Cookies necessarily
  exist in Chrome and in memory during a switch.
- `extension/cookies.mjs`: adapted MIT cookie handling from
  [Smeagolworms4/claude-switch-account](https://github.com/Smeagolworms4/claude-switch-account),
  pinned at `8948a04a334815218a8e1bcc6f6d0c7efa900598`. Attribution/license included.
  Scope narrowed to `claude.ai`; strict failure propagation, validation and
  rollback added. The full upstream popup/storage implementation is not bundled.
- `extension/background.js`: handoff preparation and explicit confirmation.
  It does not access the official extension's private storage or replace its tokens.

## Validation

Portable automated checks (no real accounts or browser required):

```bash
python3 -m unittest discover -s browser-sync/tests -p 'test_*.py' -v
node --test browser-sync/tests/*.test.mjs
bash -n claude-session
```

Mac acceptance checks still required before promoting from experimental:

- Compile/install Swift helper; verify Keychain save/load/permissions on supported macOS.
- Register A/B, verify browser email, then test official-extension identity after
  cookie restore, panel reopen, and extension reconnect. Record versions and results.
- Confirm no browser tool executes until the human confirmation; test a wrong email.
- Two Remote Control sessions: B must not steal A's browser mid-turn; after A stops,
  B must prepare its own account and request fresh confirmation.
- Expired cookies, missing/locked Keychain, helper disconnect, worker restart,
  manual account change, restore failure and rollback failure all block access.
- Test unbind/disable preserve unrelated hooks, MCP config, memory and launchers.

Relevant upstream docs: [hooks](https://code.claude.com/docs/en/hooks),
[Remote Control](https://code.claude.com/docs/en/remote-control),
[Chrome integration](https://code.claude.com/docs/en/chrome),
[Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging).
