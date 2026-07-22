#!/usr/bin/env bash
#
# claude-config-bootstrap — idempotent setup for an isolated, per-client
# Claude Code config directory with shared + client-local CLAUDE.md memory.
#
# Configures ONE config dir: wires a two-tier memory file (shared global imported
# into a client-local file) and installs a client-aware statusline. Pass --client
# and the dir is derived (CLIENTS_PARENT/<client>) — no env var needed. Shell
# launchers (cc-<client>, the bare-claude guard, the global command) are managed
# by the `client-session` CLI, not here. Safe to run repeatedly.
#
# Usage:
#   ./setup.sh --client macleod      # configure ~/.claude-clients/macleod
#   ./setup.sh --client macleod --check
#
# Flags:
#   --client NAME        Client/label for this config dir (e.g. macleod, clientA)
#   --shared-dir PATH    Where the shared global.md lives (default: ~/.claude-shared)
#   --no-statusline      Skip statusline installation
#   --clients-parent PATH  Where client config dirs live (default: ~/.claude-clients)
#   --check              Report what IS and ISN'T set up, change nothing (dry run)
#   -h, --help           Show this help

set -euo pipefail

# ---------------------------------------------------------------------------
# Styling (rich-ish output without dependencies)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
  GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; CYAN=$'\033[36m'; BLUE=$'\033[34m'
else
  BOLD=""; DIM=""; RESET=""; GREEN=""; YELLOW=""; RED=""; CYAN=""; BLUE=""
fi

ok()    { printf "  ${GREEN}✓${RESET} %s\n" "$1"; }
add()   { printf "  ${BLUE}+${RESET} %s\n" "$1"; }
warn()  { printf "  ${YELLOW}!${RESET} %s\n" "$1"; }
err()   { printf "  ${RED}✗${RESET} %s\n" "$1" >&2; }
info()  { printf "  ${DIM}%s${RESET}\n" "$1"; }
hdr()   { printf "\n${BOLD}%s${RESET}\n" "$1"; }

# ---------------------------------------------------------------------------
# Defaults & arg parsing
# ---------------------------------------------------------------------------
CLIENT=""
SHARED_DIR="${HOME}/.claude-shared"
INSTALL_STATUSLINE=1
CLIENTS_PARENT="${HOME}/.claude-clients"
DRY_RUN=0

print_help() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --client)         CLIENT="${2:-}"; shift 2 ;;
    --shared-dir)     SHARED_DIR="${2:-}"; shift 2 ;;
    --no-statusline)  INSTALL_STATUSLINE=0; shift ;;
    --clients-parent) CLIENTS_PARENT="${2:-}"; shift 2 ;;
    --check)          DRY_RUN=1; shift ;;
    -h|--help)        print_help; exit 0 ;;
    *) err "Unknown argument: $1"; echo "Try --help"; exit 2 ;;
  esac
done

# Expand a leading ~ in a path (covers --shared-dir ~/foo passed literally).
expand_tilde() {
  case "$1" in
    "~")    printf '%s' "$HOME" ;;
    "~/"*)  printf '%s/%s' "$HOME" "${1#\~/}" ;;
    *)      printf '%s' "$1" ;;
  esac
}
SHARED_DIR="$(expand_tilde "$SHARED_DIR")"
CLIENTS_PARENT="$(expand_tilde "$CLIENTS_PARENT")"

# ---------------------------------------------------------------------------
# 1. Resolve the client label and the config dir to configure.
#    Pass --client and the dir is derived (CLIENTS_PARENT/<client>), so there's
#    no need to export CLAUDE_CONFIG_DIR just to configure a client. If the env
#    var IS set it wins (configures whatever dir is active). With neither, we
#    fall back to the DEFAULT ~/.claude and warn.
# ---------------------------------------------------------------------------
hdr "Claude Code config bootstrap"

derive_client() {
  # ~/.claude-clients/macleod -> macleod ; ~/.claude-clientA -> clientA ; ~/.claude -> default
  local base; base="$(basename "$1")"
  if [ "$base" = ".claude" ]; then echo "default"; else echo "${base#.claude-}"; fi
}

# Sanitize a label to something filesystem- and case-pattern-friendly.
sanitize_client() { printf '%s' "$1" | tr -cd '[:alnum:]_-'; }

if [ -n "$CLIENT" ]; then
  CLIENT="$(sanitize_client "$CLIENT")"
  [ -n "$CLIENT" ] || { err "Empty client label after sanitizing. Aborting."; exit 2; }
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    CONFIG_DIR="$(expand_tilde "$CLAUDE_CONFIG_DIR")"
    ok "Active config dir (from CLAUDE_CONFIG_DIR): ${BOLD}${CONFIG_DIR}${RESET}"
  else
    CONFIG_DIR="${CLIENTS_PARENT}/${CLIENT}"
    ok "Config dir (derived from --client): ${BOLD}${CONFIG_DIR}${RESET}"
  fi
elif [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  CONFIG_DIR="$(expand_tilde "$CLAUDE_CONFIG_DIR")"
  ok "Active config dir: ${BOLD}${CONFIG_DIR}${RESET}"
  SUGGESTED="$(derive_client "$CONFIG_DIR")"
  if [ "$DRY_RUN" -eq 1 ]; then
    CLIENT="$SUGGESTED"
  else
    printf "  Client label for this config [${BOLD}%s${RESET}]: " "$SUGGESTED"
    read -r entered </dev/tty || entered=""
    CLIENT="${entered:-$SUGGESTED}"
  fi
  CLIENT="$(sanitize_client "$CLIENT")"
  [ -n "$CLIENT" ] || { err "Empty client label after sanitizing. Aborting."; exit 2; }
else
  CONFIG_DIR="${HOME}/.claude"
  CLIENT="default"
  warn "No --client and CLAUDE_CONFIG_DIR is not set — falling back to the DEFAULT dir:"
  warn "  ${CONFIG_DIR}"
  warn "This is the account a bare 'claude' uses. To configure an isolated client,"
  warn "re-run with --client <name> (no export needed)."
  if [ "$DRY_RUN" -eq 0 ]; then
    printf "  Continue configuring the DEFAULT dir anyway? [y/N] "
    read -r reply </dev/tty || reply=""
    case "$reply" in
      [yY]|[yY][eE][sS]) : ;;
      *) info "Aborted. Nothing changed."; exit 0 ;;
    esac
  fi
fi
ok "Client label: ${BOLD}${CLIENT}${RESET}"

# ---------------------------------------------------------------------------
# Paths we manage
# ---------------------------------------------------------------------------
SHARED_FILE="${SHARED_DIR}/global.md"
CLIENT_MEMORY="${CONFIG_DIR}/CLAUDE.md"
SETTINGS_FILE="${CONFIG_DIR}/settings.json"
STATUSLINE_SCRIPT="${SHARED_DIR}/statusline-client.sh"   # shared across all clients
IMPORT_LINE="@${SHARED_FILE}"                            # absolute path: most robust across versions
SENTINEL_BEGIN="<!-- claude-config-bootstrap:begin -->"
SENTINEL_END="<!-- claude-config-bootstrap:end -->"

if [ "$DRY_RUN" -eq 1 ]; then hdr "Dry run — reporting state only, no changes"; fi

# ---------------------------------------------------------------------------
# 3. Shared dir + global.md
# ---------------------------------------------------------------------------
hdr "Shared global memory"
if [ -d "$SHARED_DIR" ]; then ok "Shared dir exists: $SHARED_DIR"
else
  if [ "$DRY_RUN" -eq 1 ]; then add "Would create shared dir: $SHARED_DIR"
  else mkdir -p "$SHARED_DIR"; add "Created shared dir: $SHARED_DIR"; fi
fi

if [ -f "$SHARED_FILE" ]; then
  ok "Shared global.md exists (left untouched): $SHARED_FILE"
else
  if [ "$DRY_RUN" -eq 1 ]; then add "Would create starter global.md: $SHARED_FILE"
  else
    cat > "$SHARED_FILE" <<EOF
# Shared global memory

<!-- Content here is imported into EVERY client's CLAUDE.md. -->
<!-- Edit this file once; all clients pick up the change. -->

Shared-memory marker: claude-config-bootstrap OK

## Conventions
- (your cross-client conventions go here)
EOF
    add "Created starter global.md: $SHARED_FILE"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Client-local CLAUDE.md that imports the shared file
#    Idempotency: we own only a sentinel-delimited block at the TOP of the file.
#    Anything the user adds below the block is preserved verbatim.
# ---------------------------------------------------------------------------
hdr "Client-local memory (${CLIENT})"

managed_block() {
  cat <<EOF
${SENTINEL_BEGIN}
# Imports shared global memory. Managed by claude-config-bootstrap — edit below the end marker.
${IMPORT_LINE}
${SENTINEL_END}
EOF
}

block_present_and_correct() {
  [ -f "$CLIENT_MEMORY" ] || return 1
  grep -qF "$SENTINEL_BEGIN" "$CLIENT_MEMORY" || return 1
  grep -qF "$IMPORT_LINE"    "$CLIENT_MEMORY" || return 1
  return 0
}

if block_present_and_correct; then
  ok "Import block already present in $CLIENT_MEMORY"
elif [ -f "$CLIENT_MEMORY" ] && grep -qF "$SENTINEL_BEGIN" "$CLIENT_MEMORY"; then
  # Block exists but import line drifted (e.g. shared path changed) — refresh just the block.
  if [ "$DRY_RUN" -eq 1 ]; then add "Would refresh managed import block (path changed) in $CLIENT_MEMORY"
  else
    tmp="$(mktemp)"
    awk -v b="$SENTINEL_BEGIN" -v e="$SENTINEL_END" '
      $0==b {skip=1}
      skip==0 {print}
      $0==e {skip=0}
    ' "$CLIENT_MEMORY" > "$tmp"
    { managed_block; printf '\n'; cat "$tmp"; } > "$CLIENT_MEMORY"
    rm -f "$tmp"
    add "Refreshed managed import block in $CLIENT_MEMORY"
  fi
elif [ -f "$CLIENT_MEMORY" ]; then
  # User has a CLAUDE.md but no managed block — prepend ours, keep theirs.
  if [ "$DRY_RUN" -eq 1 ]; then add "Would prepend import block, preserving existing $CLIENT_MEMORY"
  else
    tmp="$(mktemp)"
    { managed_block; printf '\n'; cat "$CLIENT_MEMORY"; } > "$tmp"
    mv "$tmp" "$CLIENT_MEMORY"
    add "Prepended import block (existing content preserved): $CLIENT_MEMORY"
  fi
else
  # No file at all — create with block + a client section stub.
  if [ "$DRY_RUN" -eq 1 ]; then add "Would create $CLIENT_MEMORY with import block + ${CLIENT} section"
  else
    mkdir -p "$CONFIG_DIR"
    { managed_block; cat <<EOF

## ${CLIENT}-specific
- Billing entity: ${CLIENT}
- (client-only conventions go here)
EOF
    } > "$CLIENT_MEMORY"
    add "Created $CLIENT_MEMORY with import + ${CLIENT} section"
  fi
fi

# ---------------------------------------------------------------------------
# 5. Statusline script (shared) + settings.json pointer (per config dir)
# ---------------------------------------------------------------------------
if [ "$INSTALL_STATUSLINE" -eq 1 ]; then
  hdr "Client-aware statusline"

  # 5a. the shared script
  if [ -f "$STATUSLINE_SCRIPT" ]; then
    ok "Statusline script exists: $STATUSLINE_SCRIPT"
  else
    if [ "$DRY_RUN" -eq 1 ]; then add "Would install statusline script: $STATUSLINE_SCRIPT"
    else
      cat > "$STATUSLINE_SCRIPT" <<'SL'
#!/usr/bin/env bash
# Client-aware statusline. Reads CLAUDE_CONFIG_DIR (inherited from the shell that
# launched claude) to label which client/billing entity this session belongs to.
# Appends usage: context-window %, 5h/7d rate-limit % (with reset time when hot),
# session cost, and lines added/removed (fields present since CC 2.1.x).
input=$(cat)

cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
label="$(basename "$cfg")"
label="${label#.claude-}"
[ "$label" = ".claude" ] && label="DEFAULT(~/.claude)"

# Distinct color per label so tabs are visually separable.
case "$label" in
  DEFAULT*) tag=$'\033[2;33m'"⚪ ${label}"$'\033[0m' ;;
  *)        tag=$'\033[1;36m'"● ${label}"$'\033[0m' ;;
esac

model="?"; dir=""; ctx=""; five=""; five_reset=""; seven=""; cost=""; added=""; removed=""
if command -v jq >/dev/null 2>&1; then
  IFS=$'\t' read -r model dir ctx five five_reset seven cost added removed < <(printf '%s' "$input" | jq -r '[
    (.model.display_name // "?"),
    (.workspace.current_dir // .cwd // ""),
    (.context_window.used_percentage // -1 | round),
    (.rate_limits.five_hour.used_percentage // -1 | round),
    (.rate_limits.five_hour.resets_at // 0),
    (.rate_limits.seven_day.used_percentage // -1 | round),
    (.cost.total_cost_usd // -1),
    (.cost.total_lines_added // 0),
    (.cost.total_lines_removed // 0)
  ] | @tsv')
fi
[ -n "$dir" ] && base=$(basename "$dir") || base="?"
branch=$(git -C "$dir" branch --show-current 2>/dev/null || true)

# green <50, yellow 50-79, red >=80
pct_paint() {
  if [ "$1" -ge 80 ]; then printf '\033[1;31m%s%%\033[0m' "$1"
  elif [ "$1" -ge 50 ]; then printf '\033[33m%s%%\033[0m' "$1"
  else printf '\033[32m%s%%\033[0m' "$1"; fi
}

printf '%s \033[2m│\033[0m %s \033[2m│\033[0m 📁 %s' "$tag" "$model" "$base"
[ -n "$branch" ] && printf ' \033[2m│\033[0m 🌿 %s' "$branch"

if [ -n "$ctx" ] && [ "$ctx" -ge 0 ] 2>/dev/null; then
  printf ' \033[2m│\033[0m 🧠 '; pct_paint "$ctx"
fi

if [ -n "$five" ] && [ "$five" -ge 0 ] 2>/dev/null; then
  printf ' \033[2m│\033[0m ⏳ 5h '; pct_paint "$five"
  # show when the 5h window resets once it's running hot (the rotation-pool signal)
  if [ "$five" -ge 80 ] && [ "$five_reset" -gt 0 ] 2>/dev/null; then
    printf '\033[2m→%s\033[0m' "$(date -r "$five_reset" +%H:%M 2>/dev/null)"
  fi
  if [ -n "$seven" ] && [ "$seven" -ge 0 ] 2>/dev/null; then
    printf ' \033[2m·\033[0m 7d '; pct_paint "$seven"
  fi
fi

if [ -n "$cost" ] && [ "$cost" != "-1" ]; then
  printf ' \033[2m│\033[0m \033[2m$%.2f +%s/-%s\033[0m' "$cost" "$added" "$removed"
fi
printf '\n'
SL
      chmod +x "$STATUSLINE_SCRIPT"
      add "Installed statusline script: $STATUSLINE_SCRIPT"
    fi
  fi
  # Ensure executable even if it pre-existed.
  [ "$DRY_RUN" -eq 0 ] && [ -f "$STATUSLINE_SCRIPT" ] && chmod +x "$STATUSLINE_SCRIPT"

  # 5b. settings.json pointer (must live in THIS config dir)
  desired_cmd="$STATUSLINE_SCRIPT"
  needs_settings=1
  if [ -f "$SETTINGS_FILE" ]; then
    if command -v jq >/dev/null 2>&1; then
      current_cmd="$(jq -r '.statusLine.command // empty' "$SETTINGS_FILE" 2>/dev/null || true)"
      [ "$current_cmd" = "$desired_cmd" ] && needs_settings=0
    else
      # No jq: best-effort substring check so a correct re-run stays a no-op.
      grep -qF "$desired_cmd" "$SETTINGS_FILE" && needs_settings=0
    fi
  fi

  if [ "$needs_settings" -eq 0 ]; then
    ok "settings.json statusLine already points to the script"
  elif [ "$DRY_RUN" -eq 1 ]; then
    add "Would set statusLine.command in $SETTINGS_FILE"
  elif [ ! -f "$SETTINGS_FILE" ]; then
    # No existing file: write a fresh one. Pure bash, no jq needed.
    mkdir -p "$CONFIG_DIR"
    cat > "$SETTINGS_FILE" <<EOF
{
  "statusLine": {
    "type": "command",
    "command": "${desired_cmd}"
  }
}
EOF
    add "Created settings.json with statusLine pointer"
  elif command -v jq >/dev/null 2>&1; then
    # Existing file: merge so we don't clobber the user's other settings.
    tmp="$(mktemp)"
    if jq --arg cmd "$desired_cmd" \
         '.statusLine = {type: "command", command: $cmd}' \
         "$SETTINGS_FILE" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$SETTINGS_FILE"
      add "Updated statusLine in existing settings.json (other keys preserved)"
    else
      rm -f "$tmp"
      err "settings.json exists but isn't valid JSON — refusing to overwrite."
      warn "Fix the JSON, then re-run. Or add manually:"
      info '  "statusLine": { "type": "command", "command": "'"${desired_cmd}"'" }'
    fi
  else
    # Existing file but no jq: don't risk clobbering. Tell the user exactly what to add.
    warn "settings.json already exists and jq isn't installed, so it can't be"
    warn "merged safely. Add this key manually to ${SETTINGS_FILE}:"
    info '  "statusLine": { "type": "command", "command": "'"${desired_cmd}"'" }'
  fi
fi

# ---------------------------------------------------------------------------
# 6. Summary
# ---------------------------------------------------------------------------
hdr "Summary"
info "Config dir   : $CONFIG_DIR"
info "Client       : $CLIENT"
info "Shared file  : $SHARED_FILE"
info "Client memory: $CLIENT_MEMORY  (imports shared, your edits go below the end marker)"
[ "$INSTALL_STATUSLINE" -eq 1 ] && info "Statusline   : $STATUSLINE_SCRIPT  (wired in this dir's settings.json)"

if [ "$DRY_RUN" -eq 1 ]; then
  printf "\n${YELLOW}Dry run complete — no changes were made.${RESET}\n"
else
  printf "\n${GREEN}Done.${RESET} Verify inside Claude Code with: ${BOLD}/memory${RESET} (shows loaded files) "
  printf "and restart the session to see the statusline.\n"
  printf "${DIM}Re-running this script is safe; it only changes what's missing or drifted.${RESET}\n"
fi
