#!/usr/bin/env bash
#
# Regression tests for the rotation-pool and account-safety scripts.
#
# Every test runs in a throwaway sandbox: its own HOME, SHARED_DIR and client
# dirs under a mktemp dir, a fake `claude` on PATH, and the CC_ROTATE_* vars of
# any surrounding pooled session unset — nothing here can reach a real config
# dir, rc file or running session. No network, no real claude.
#
# Usage: bash tests/run.sh        (exit 1 if any test fails)

set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$REPO/claude-config-bootstrap/scripts"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ccb-tests.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
unset CC_ROTATE_ACTIVE CC_ROTATE_PIDFILE ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CONFIG_DIR
export HOME="$ROOT/home"; mkdir -p "$HOME"

PASS=0; FAIL=0; T=""
ok()   { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31m✗ %s\033[0m\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3], got [$2]"; fi; }

# A fresh sandbox per test: $T/shared (installed scripts), $T/c/<dirs>, $T/bin.
sandbox() {
  T="$ROOT/$1"; mkdir -p "$T/shared/pools" "$T/c" "$T/bin"
  case "$T" in "$ROOT"/*) ;; *) echo "sandbox escaped: $T" >&2; exit 2 ;; esac
  local f; for f in cc-rotate cc-rotate-kill cc-rotate-now cc-account-guard; do
    cp "$SCRIPTS/$f" "$T/shared/$f"; chmod +x "$T/shared/$f"
  done
  ln -s /bin/bash "$T/bin/fakeclaude-sh" 2>/dev/null
  mkdir -p "$T/proc"; ln -s /bin/bash "$T/proc/claude"   # a process whose `ps` name is claude
}
acct() {  # $1 = dir, $2 = email: a subscription login as claude records it
  mkdir -p "$1"
  printf '{"oauthAccount": {"emailAddress": "%s", "organizationUuid": "org-%s"}}\n' "$2" "$2" > "$1/.claude.json"
}
pool() { local c="$1"; shift; printf '%s\n' "$@" > "$T/shared/pools/$c.pool"; local d; for d in "${@:2}"; do echo "$c" > "$d/.ccb-pool-member"; done; }
# Fake claude for supervisor tests: logs dir, key and args; behaviour per dir
# comes from $dir/.fake ("limit" = hit a rate limit, recording $dir/.fake-sid).
fake_claude() {
  cat > "$T/bin/claude" <<EOF
#!/bin/bash
d="\${CLAUDE_CONFIG_DIR:-}"
echo "\${d##*/} key=\${ANTHROPIC_API_KEY:-none} args=\$*" >> "$T/calls.log"
case "\$1" in auth) exit 0 ;; esac
if [ "\$(cat "\$d/.fake" 2>/dev/null)" = limit ]; then
  sid="\$(cat "\$d/.fake-sid" 2>/dev/null)"
  [ -n "\$sid" ] && echo "\$sid" > "\$CC_ROTATE_PIDFILE.session"
  touch "\$CC_ROTATE_PIDFILE.rotate"; exit 143
fi
exit 0
EOF
  chmod +x "$T/bin/claude"
}
transcript() { mkdir -p "$T/shared/pools/$1-projects/$2"; echo '{}' > "$T/shared/pools/$1-projects/$2/$3.jsonl"; }

# ---------------------------------------------------------------------------
echo "cc-rotate-kill (StopFailure hook)"
PL='{"session_id":"sess-1","hook_event_name":"StopFailure","error":"rate_limit"}'
hook_case() {  # $1 = name, $2 = shell run by the supervised "claude"; echoes "exit flag session"
  local pf="$T/pid.$1"
  env CC_ROTATE_ACTIVE=1 CC_ROTATE_PIDFILE="$pf" HOOK="$T/shared/cc-rotate-kill" PL="$PL" CL="$T/proc/claude" \
    "$T/proc/claude" -c "echo \$\$ > '$pf'; $2; sleep 1; true"
  echo "$? $([ -f "$pf.rotate" ] && echo flag || echo noflag) $(cat "$pf.session" 2>/dev/null || echo nosid)"
}
sandbox hook
# The hook's own session rate-limits: it must rotate, and say which conversation failed.
check "rotates its own session and records the failing session id" \
  "$(hook_case own 'printf "%s" "$PL" | "$HOOK"')" "143 flag sess-1"
# 2026-10-23: a `claude -p` run from inside a pooled session hit ITS account's
# limit and the inherited CC_ROTATE_* vars made its hook kill the parent session.
check "ignores a rate limit from a nested claude that inherited the vars" \
  "$(hook_case nested '"$CL" -c "printf \"%s\" \"\$PL\" | \"\$HOOK\"; true"')" "0 noflag nosid"
check "is a no-op outside a cc-rotate session" \
  "$(hook_case inactive 'printf "%s" "$PL" | CC_ROTATE_ACTIVE=0 "$HOOK"')" "0 noflag nosid"

# ---------------------------------------------------------------------------
echo "cc-rotate (supervisor)"
run_rotate() { PATH="$T/bin:$PATH" SHARED_DIR="$T/shared" "$T/shared/cc-rotate" "$@" >"$T/out.log" 2>&1; }

sandbox resume; fake_claude
acct "$T/c/p" a@x; acct "$T/c/p-2" b@x; pool p "$T/c/p" "$T/c/p-2"
echo limit > "$T/c/p/.fake"; echo real-sess > "$T/c/p/.fake-sid"
transcript p proj real-sess; sleep 1; transcript p agent-scratch decoy-sess
run_rotate p
# The pool history is shared: subagents, `claude -p` and other windows write
# newer transcripts there, and resuming "the newest" resumed the wrong one.
check "resumes the session that hit the limit, not the newest transcript" \
  "$(grep -c -- '--resume real-sess' "$T/calls.log")" "1"

sandbox fallback; fake_claude
acct "$T/c/p" a@x; acct "$T/c/p-2" b@x; pool p "$T/c/p" "$T/c/p-2"
echo limit > "$T/c/p/.fake"; transcript p proj only-sess
run_rotate p
check "falls back to the newest transcript when no session id was recorded" \
  "$(grep -c -- '--resume only-sess' "$T/calls.log")" "1"

sandbox apikey; fake_claude
acct "$T/c/p" a@x; mkdir -p "$T/c/p-2"; echo '{}' > "$T/c/p-2/.claude.json"; pool p "$T/c/p" "$T/c/p-2"
echo limit > "$T/c/p/.fake"
ANTHROPIC_API_KEY=sk-test run_rotate p
# 2026-10-23: tl/tl-2 had approved an env API key, so claude billed an empty API
# account ("Credit balance is too low") instead of the Max subscription.
check "drops an env API key for a subscription dir" "$(grep -c '^p key=none' "$T/calls.log")" "1"
check "keeps the env API key for a dir with no subscription login" "$(grep -c '^p-2 key=sk-test' "$T/calls.log")" "1"

sandbox skipdrift; fake_claude
acct "$T/c/p" b@x; echo a@x > "$T/c/p/.ccb-account"; acct "$T/c/p-2" b@x; echo b@x > "$T/c/p-2/.ccb-account"
pool p "$T/c/p" "$T/c/p-2"
run_rotate p
# A dir that drifted onto another member's account must not spend that account.
check "skips a dir logged into an account other than its pin" "$(cut -d' ' -f1 "$T/calls.log" | tr '\n' ' ')" "p-2 "

# ---------------------------------------------------------------------------
echo "cc-rotate-now (manual rotation)"
sandbox now
pf="$T/pid.now"
env CC_ROTATE_ACTIVE=1 CC_ROTATE_PIDFILE="$pf" NOW="$T/shared/cc-rotate-now" CL="$T/proc/claude" \
  "$T/proc/claude" -c "echo \$\$ > '$pf'; \"\$CL\" -c '\"\$NOW\" 2>/dev/null; true'; sleep 1; true"
check "refuses to rotate from a different claude session that inherited the vars" \
  "$([ -f "$pf.rotate" ] && echo rotated || echo refused)" "refused"
{ env CC_ROTATE_ACTIVE=1 CC_ROTATE_PIDFILE="$pf" NOW="$T/shared/cc-rotate-now" CLAUDE_CODE_SESSION_ID=sess-9 \
  "$T/proc/claude" -c "echo \$\$ > '$pf'; \"\$NOW\" p-2 2>/dev/null; sleep 1; true"; } 2>/dev/null
check "rotates its own session to the named member and records the session" \
  "$(cat "$pf.rotate" 2>/dev/null)|$(cat "$pf.session" 2>/dev/null)" "manual:p-2|sess-9"

# ---------------------------------------------------------------------------
echo "cc-account-guard (first login sticks)"
guard() { env -u CC_ROTATE_ACTIVE -u CC_ROTATE_PIDFILE SHARED_DIR="$T/shared" "$T/shared/cc-account-guard" "$@" 2>/dev/null; }

sandbox guard
acct "$T/c/p" a@x; acct "$T/c/p-2" b@x; acct "$T/c/p-3" a@x; mkdir -p "$T/c/solo"
pool p "$T/c/p" "$T/c/p-2" "$T/c/p-3"
echo '{"theme": "dark", "forceLoginOrgUUID": null}' > "$T/c/p/settings.json"
guard "$T/c/p"
check "pins an unpinned dir to the account it is logged into" "$(cat "$T/c/p/.ccb-account" 2>/dev/null)" "a@x"
# The org lock is what makes claude itself reject a /login into another account.
check "locks the dir's logins to that account's org, keeping other settings" \
  "$(jq -c '[.theme, .forceLoginOrgUUID]' "$T/c/p/settings.json")" '["dark","org-a@x"]'
guard "$T/c/p-3"; rc=$?
check "never pins a second dir to an account another pool dir holds" \
  "$rc $(cat "$T/c/p-3/.ccb-account" 2>/dev/null || echo unpinned)" "0 unpinned"
guard "$T/c/solo"
check "leaves a dir that isn't logged in alone" "$([ -f "$T/c/solo/.ccb-account" ] && echo pinned || echo unpinned)" "unpinned"

sandbox dupfirst
acct "$T/c/p" a@x; acct "$T/c/p-2" a@x; pool p "$T/c/p" "$T/c/p-2"
guard "$T/c/p-2"; guard "$T/c/p"
# Two unpinned dirs on one account: the earlier dir in pool order (the primary)
# keeps it, whatever order they are checked in.
check "gives a shared account to the earlier pool dir" \
  "$(cat "$T/c/p/.ccb-account" 2>/dev/null || echo -) $(cat "$T/c/p-2/.ccb-account" 2>/dev/null || echo -)" "a@x -"

sandbox drift
acct "$T/c/p" a@x; acct "$T/c/p-2" b@x; pool p "$T/c/p" "$T/c/p-2"
guard "$T/c/p"; guard "$T/c/p-2"
acct "$T/c/p" b@x   # a /login inside p's session signed in as p-2's account
guard "$T/c/p"; rc=$?
check "rejects a dir that drifted onto another account (launchers refuse it)" "$rc" "1"
check "keeps the original pin after a drift" "$(cat "$T/c/p/.ccb-account")" "a@x"
printf '#!/bin/bash\necho "$*" >> "%s/rot.log"\n' "$T" > "$T/shared/cc-rotate-now"
: > "$T/pidf"
for _ in 1 2; do
  env CC_ROTATE_ACTIVE=1 CC_ROTATE_PIDFILE="$T/pidf" SHARED_DIR="$T/shared" \
    "$T/shared/cc-account-guard" --session "$T/c/p" >/dev/null 2>&1
done
# The user's ask: when a login lands on another pool account, switch the session
# to the dir that owns that account, so a dir never maps to the wrong account.
check "inside a rotated session, switches to the member that owns the account, once" \
  "$(cat "$T/rot.log" 2>/dev/null | tr '\n' ' ')" "p-2 "
rm -f "$T/rot.log"
SHARED_DIR="$T/shared" "$T/shared/cc-account-guard" --session "$T/c/p" >/dev/null 2>&1
check "does not rotate a session that cc-rotate didn't start" "$([ -f "$T/rot.log" ] && echo rotated || echo no)" "no"

# ---------------------------------------------------------------------------
echo "cc-<client> launcher (_ccb_claude in the rc block)"
sandbox launcher; fake_claude
acct "$T/c/sub" a@x; mkdir -p "$T/c/api"; echo '{}' > "$T/c/api/.claude.json"
runner="$(awk "/<<'RUNNER'\$/{f=1;next} /^RUNNER\$/{f=0} f" "$REPO/claude-session")"
launch() { env SHARED_DIR="$T/shared" PATH="$T/bin:$PATH" ANTHROPIC_API_KEY=sk-test bash -c "_ccb_guard='$T/shared/cc-account-guard'; $runner
_ccb_claude \"\$@\"" _ "$@" 2>/dev/null; }
launch "$T/c/sub" --x; launch "$T/c/api" --x
check "drops the env API key for a subscription dir, keeps it otherwise" \
  "$(cut -d' ' -f1,2 "$T/calls.log" | tr '\n' ' ')" "sub key=none api key=sk-test "
check "pins the dir on its first launch" "$(cat "$T/c/sub/.ccb-account" 2>/dev/null)" "a@x"
acct "$T/c/sub" other@x; : > "$T/calls.log"
launch "$T/c/sub" --x; rc=$?
check "refuses to launch a dir that drifted off its account" "$rc $(wc -l < "$T/calls.log" | tr -d ' ')" "1 0"

# ---------------------------------------------------------------------------
echo "statusline billing mode"
sandbox statusline
awk "/<<'SL'\$/{f=1;next} /^SL\$/{f=0} f" "$SCRIPTS/setup.sh" > "$T/shared/statusline.sh"
acct "$T/c/sub" a@x; mkdir -p "$T/c/api"; echo '{}' > "$T/c/api/.claude.json"
acct "$T/c/rej" a@x; jq '.customApiKeyResponses = {rejected: ["KKKKKKKKKKKKKKKKKKKK"]}' "$T/c/rej/.claude.json" > "$T/x" && mv "$T/x" "$T/c/rej/.claude.json"
mode() { printf '{"model":{"display_name":"M"},"cwd":"%s"}' "$T" | env -u ANTHROPIC_API_KEY CLAUDE_CONFIG_DIR="$T/c/$1" ${2:+ANTHROPIC_API_KEY=$2} \
  bash "$T/shared/statusline.sh" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -oE '💳 sub|🔑 API' || echo none; }
KEY=sk-xxxxKKKKKKKKKKKKKKKKKKKK
check "shows sub for a subscription session" "$(mode sub)" "💳 sub"
check "shows API when an env key will be billed" "$(mode api $KEY)" "🔑 API"
check "shows sub when the dir rejected the env key" "$(mode rej $KEY)" "💳 sub"

# ---------------------------------------------------------------------------
echo "claude-session --update (and hourly auto-update)"
sandbox update
G="git -c user.name=t -c user.email=t@t -c init.defaultBranch=main"
mkdir -p "$T/remote" && (cd "$REPO" && git ls-files -co --exclude-standard | grep -v '^assets/' | while IFS= read -r f; do
  [ -f "$f" ] && mkdir -p "$T/remote/$(dirname "$f")" && cp -p "$f" "$T/remote/$f"; done)
(cd "$T/remote" && $G init -q && $G add -A && $G commit -qm base)
git clone -q "$T/remote" "$T/dev"
cs_env() { env -u CLAUDE_CONFIG_DIR SHARED_DIR="$T/shared" CLIENTS_PARENT="$T/c" RC_FILE="$T/rc" SKILLS_DIR="$T/defskills" "$@"; }
rm -f "$T/shared/cc-"*   # start from a clean install
cs_env CCB_NO_PLUGIN=1 bash "$T/dev/claude-session" -y --create c1 >/dev/null 2>&1
check "--create records where updates come from" "$(cat "$T/shared/.ccb-source" 2>/dev/null)" "$T/remote"
# Each account loads skills from its own config dir; the skill used to land only
# in the dir of the session that ran the installer (2026-10-23).
check "--create gives the client its own copy of the skill" \
  "$([ -f "$T/c/c1/skills/claude-config-bootstrap/SKILL.md" ] && echo yes || echo no)" "yes"
echo "# marker-v2" >> "$T/remote/claude-config-bootstrap/scripts/cc-member"
echo "marker-v2" >> "$T/remote/claude-config-bootstrap/README.md"
(cd "$T/remote" && $G commit -qam v2)
cs_env CCB_NO_PLUGIN=1 "$T/shared/claude-session" --update --auto > "$T/up.log" 2>&1
check "--update installs the new scripts without a pull or --create by hand" \
  "$(tail -n 1 "$T/shared/cc-member")" "# marker-v2"
check "--update refreshes every client's skill copy" \
  "$(grep -c marker-v2 "$T/c/c1/skills/claude-config-bootstrap/README.md" 2>/dev/null)" "1"
check "--update leaves the dev checkout alone (it pulls into its own clone)" \
  "$(grep -c marker-v2 "$T/dev/claude-config-bootstrap/scripts/cc-member")" "0"
check "the launcher block calls the auto-updater" "$(grep -c '_ccb_autoupdate; ' "$T/rc")" "1"
cs_env CCB_NO_PLUGIN=1 "$T/shared/claude-session" --update --auto > "$T/up2.log" 2>&1; rc=$?
check "--auto with nothing new does nothing" "$rc $(grep -c updated "$T/up2.log")" "0 0"
mkdir "$T/shared/.update.lock"
cs_env "$T/shared/claude-session" --update --auto > "$T/up3.log" 2>&1; rc=$?
check "--auto backs off while another update holds the lock" "$rc $(wc -c < "$T/up3.log" | tr -d ' ')" "0 0"
rmdir "$T/shared/.update.lock"
# The hourly throttle: launches and statusline refreshes must not spawn an update each time.
printf '#!/bin/bash\necho "$*" >> %q\n' "$T/auto.log" > "$T/fakecli"; chmod +x "$T/fakecli"
auto() { bash -c "source '$T/rc' 2>/dev/null; _ccb_cli='$T/fakecli'; _ccb_autoupdate; sleep 0.3"; }
: > "$T/shared/.update-stamp"; auto
check "auto-update is skipped within an hour of the last check" "$(cat "$T/auto.log" 2>/dev/null)" ""
touch -t 202001010000 "$T/shared/.update-stamp"; auto
check "auto-update starts in the background once the hour has passed" "$(cat "$T/auto.log" 2>/dev/null)" "--update --auto"
# Inside a running session the statusline is the trigger, so long sessions update too.
rm -f "$T/auto.log"; cp "$T/fakecli" "$T/shared/claude-session"
awk "/<<'SL'\$/{f=1;next} /^SL\$/{f=0} f" "$SCRIPTS/setup.sh" > "$T/shared/statusline.sh"
touch -t 202001010000 "$T/shared/.update-stamp"
printf '{"cwd":"%s"}' "$T" | CLAUDE_CONFIG_DIR="$T/c/c1" bash "$T/shared/statusline.sh" >/dev/null 2>&1; sleep 0.3
check "a running session's statusline starts the hourly auto-update" "$(cat "$T/auto.log" 2>/dev/null)" "--update --auto"

# ---------------------------------------------------------------------------
echo "sessions plugin (shows in /plugin, updates there)"
sandbox plugin
# Fake `claude plugin`: log the call; `install` enables the plugin the way claude does.
cat > "$T/bin/claude" <<EOF
#!/bin/bash
echo "\${CLAUDE_CONFIG_DIR##*/} \$*" >> "$T/plugin.log"
if [ "\$1 \$2" = "plugin marketplace" ]; then
  s="\$CLAUDE_CONFIG_DIR/settings.json"; [ -f "\$s" ] || echo '{}' > "\$s"
  jq '.extraKnownMarketplaces["claude-sessions"] = {source: {source: "github", repo: "macleodlabs-ai/claude-sessions"}}' "\$s" > "\$s.t" && mv "\$s.t" "\$s"
fi
if [ "\$1 \$2" = "plugin install" ]; then
  s="\$CLAUDE_CONFIG_DIR/settings.json"
  jq '.enabledPlugins["sessions@claude-sessions"] = true' "\$s" > "\$s.t" && mv "\$s.t" "\$s"
fi
exit 0
EOF
chmod +x "$T/bin/claude"
mkdir -p "$T/remote" && (cd "$REPO" && git ls-files -co --exclude-standard | grep -v '^assets/' | while IFS= read -r f; do
  [ -f "$f" ] && mkdir -p "$T/remote/$(dirname "$f")" && cp -p "$f" "$T/remote/$f"; done)
(cd "$T/remote" && $G init -q && $G add -A && $G commit -qm base)
rm -f "$T/shared/cc-"*
mkdir -p "$T/c/c1-2"; echo c1 > "$T/c/c1-2/.ccb-pool-member"
mkdir -p "$T/c/c1/skills/claude-config-bootstrap"; printf -- '---\nname: claude-config-bootstrap\n---\n' > "$T/c/c1/skills/claude-config-bootstrap/SKILL.md"
penv() { env -u CLAUDE_CONFIG_DIR PATH="$T/bin:$PATH" SHARED_DIR="$T/shared" CLIENTS_PARENT="$T/c" RC_FILE="$T/rc" SKILLS_DIR="$T/defskills" "$@"; }
penv bash "$T/remote/claude-session" -y --create c1 >/dev/null 2>&1
printf '%s\n' "$T/c/c1" "$T/c/c1-2" > "$T/shared/pools/c1.pool"
penv CCB_SOURCE_URL="$T/remote" bash "$T/remote/claude-session" --update >/dev/null 2>&1
# The user's ask (2026-10-23): claude-sessions must show in /plugin for every
# account, pool members included, so it can be updated from inside a session.
check "installs the sessions plugin for a client" "$(jq -r '.enabledPlugins["sessions@claude-sessions"]' "$T/c/c1/settings.json")" "true"
check "installs it for pool members too" "$(jq -r '.enabledPlugins["sessions@claude-sessions"]' "$T/c/c1-2/settings.json" 2>/dev/null)" "true"
check "turns on auto-update for its marketplace" "$(jq -r '.extraKnownMarketplaces["claude-sessions"].autoUpdate' "$T/c/c1/settings.json")" "true"
# Both would load: a copied skill beside the plugin's is a duplicate skill.
check "removes the copied skill once the plugin provides it" "$([ -e "$T/c/c1/skills/claude-config-bootstrap" ] && echo present || echo removed)" "removed"
: > "$T/plugin.log"; penv CCB_SOURCE_URL="$T/remote" bash "$T/remote/claude-session" --update >/dev/null 2>&1
check "does not reinstall a plugin that is already enabled" "$(grep -c 'plugin install' "$T/plugin.log")" "0"

# The plugin's SessionStart hook: a /plugin update must reach the shared scripts.
HOOKS="$REPO/claude-config-bootstrap/scripts/plugin-session-start"
mkdir -p "$T/proot/claude-config-bootstrap/scripts"; cp "$HOOKS" "$T/proot/claude-config-bootstrap/scripts/"
cp "$T/fakecli" "$T/proot/claude-session" 2>/dev/null || printf '#!/bin/bash\necho "$*" >> %q\n' "$T/hook.log" > "$T/proot/claude-session"
printf '#!/bin/bash\necho "$*" >> %q\n' "$T/hook.log" > "$T/proot/claude-session"; chmod +x "$T/proot/claude-session"
hook() { SHARED_DIR="$T/shared" bash "$T/proot/claude-config-bootstrap/scripts/plugin-session-start"; sleep 0.3; }
rm -f "$T/hook.log" "$T/shared/.plugin-root"; : > "$T/shared/.update-stamp"
out="$(hook)"
check "after a plugin update, the hook updates straight away (throttle bypassed)" "$(cat "$T/hook.log" 2>/dev/null)" "--update --auto"
check "the hook prints nothing (its stdout would go into Claude's context)" "$out" ""
rm -f "$T/hook.log"; hook
check "same plugin version within the hour: the hook does nothing" "$(cat "$T/hook.log" 2>/dev/null)" ""
mv "$T/shared/claude-session" "$T/shared/cs.off"; rm -f "$T/shared/.plugin-root"; hook
check "never sets anything up on a machine claude-session isn't installed on" "$(cat "$T/hook.log" 2>/dev/null)" ""
mv "$T/shared/cs.off" "$T/shared/claude-session"

# ---------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
