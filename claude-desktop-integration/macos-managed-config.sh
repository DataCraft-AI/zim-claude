#!/usr/bin/env bash
# macos-managed-config.sh — point Claude Desktop at the :4002 gateway on macOS
# WITHOUT an Anthropic subscription and WITHOUT the in-app dialog.
#
#   ./macos-managed-config.sh            install the config (quit the app first)
#   ./macos-managed-config.sh --status   show what is currently configured
#   ./macos-managed-config.sh --uninstall  restore the most recent backup
#   ./macos-managed-config.sh --help
#
# Why this exists: the "Configure Third-Party Inference…" dialog does not write
# config directly. It runs an OAuth *scope-expansion* authorize against
# api.anthropic.com first, which returns 403 permission_error for any account
# without a Claude Code entitlement. The dialog therefore fails with
# "Couldn't load configuration" and never reaches the point of saving. The
# supported no-click route on Linux (/etc/claude-desktop/managed-settings.json)
# has no macOS equivalent: the macOS build reads a *managed plist* from
# /Library/Managed Preferences/, which needs root, or a user-owned
# "config library" under the app's -3p profile, which does not.
#
# This script writes that config library. Nothing here needs sudo, and the
# in-app dialog keeps working afterwards if you ever want it.
#
# See README.md, "macOS without a subscription", for the mechanism.

set -euo pipefail

PORT="${CLAUDE_DESKTOP_PORT:-4002}"
KEY="${CLAUDE_DESKTOP_LITELLM_KEY:-sk-claude-desktop-local}"

# The app derives its userData as <userData>-3p unless the path already ends in
# "-3p" (see the app's own iQ()). So third-party config lives in a sibling
# profile, not in "Claude/".
BASE="$HOME/Library/Application Support/Claude-3p"
CONFIG="$BASE/claude_desktop_config.json"
LIB="$BASE/configLibrary"
META="$LIB/_meta.json"
# Fixed sentinel id so re-running is idempotent (same file, overwritten).
ENTRY_ID="00000000-0000-4000-8000-000000000115"
ENTRY="$LIB/$ENTRY_ID.json"
BACKUP_ROOT="$HOME/.local/share/zim-claude/backups"

DO_STATUS=0 DO_UNINSTALL=0
while (($#)); do
  case "$1" in
    --status)     DO_STATUS=1 ;;
    --uninstall)  DO_UNINSTALL=1 ;;
    -h|--help)    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

say()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; }

app_running() { pgrep -f 'Claude.app/Contents/MacOS/Claude' >/dev/null 2>&1; }

# --- status -------------------------------------------------------------------
if (( DO_STATUS )); then
  say "profile: $BASE"
  if [[ -f "$CONFIG" ]]; then
    printf 'deploymentMode: '
    plutil -extract deploymentMode raw -o - "$CONFIG" 2>/dev/null || echo '(unset)'
  else
    warn "no $CONFIG (app has never run in 3p mode here)"
  fi
  if [[ -f "$META" ]]; then
    printf '_meta.json:    '; cat "$META"
  fi
  if [[ -f "$ENTRY" ]]; then
    say "config library entry:"
    plutil -p "$ENTRY"
  else
    warn "no config library entry at $ENTRY"
  fi
  exit 0
fi

# --- uninstall ----------------------------------------------------------------
if (( DO_UNINSTALL )); then
  app_running && { err "quit Claude Desktop first (osascript -e 'tell application \"Claude\" to quit')"; exit 1; }
  # newest backup that is genuinely pre-3p (older runs may have snapshotted 3p itself)
  latest=""
  for d in $(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort -r); do
    m="$(plutil -extract deploymentMode raw -o - "$d/claude_desktop_config.json" 2>/dev/null || true)"
    if [[ "$m" != "3p" ]]; then latest="$d"; break; fi
  done
  [[ -n "$latest" ]] || { err "no pre-3p backup under $BACKUP_ROOT"; exit 1; }
  say "restoring from $latest"
  [[ -f "$latest/claude_desktop_config.json" ]] && cp "$latest/claude_desktop_config.json" "$CONFIG" && ok "restored claude_desktop_config.json"
  [[ -f "$latest/configLibrary/_meta.json" ]] && cp "$latest/configLibrary/_meta.json" "$META" && ok "restored _meta.json"
  rm -f "$ENTRY" && ok "removed $ENTRY"
  warn "relaunch Claude Desktop to return to your account."
  exit 0
fi

# --- install ------------------------------------------------------------------
if app_running; then
  err "Claude Desktop is running — quit it first, or the app will overwrite this on exit:"
  err "  osascript -e 'tell application \"Claude\" to quit'"
  exit 1
fi

command -v plutil >/dev/null 2>&1 || { err "plutil not found (this is a macOS-only script)"; exit 1; }

# 1. back up what we are about to change.
#    Skipped when we are already in 3p: re-running would otherwise overwrite the
#    one backup that matters (the pre-3p state) with our own output, and
#    --uninstall would then "restore" 3p.
CUR_MODE=""
[[ -f "$CONFIG" ]] && CUR_MODE="$(plutil -extract deploymentMode raw -o - "$CONFIG" 2>/dev/null || true)"
if [[ "$CUR_MODE" == "3p" ]]; then
  say "already in 3p; keeping the existing pre-3p backup"
else
  STAMP="$(date +%Y%m%d-%H%M%S)"
  BK="$BACKUP_ROOT/$STAMP"
  say "backing up to $BK"
  mkdir -p "$BK/configLibrary"
  chmod 700 "$BACKUP_ROOT" "$BK"
  [[ -f "$CONFIG" ]] && cp -p "$CONFIG" "$BK/claude_desktop_config.json"
  [[ -f "$META"   ]] && cp -p "$META"   "$BK/configLibrary/_meta.json"
  # keep any prior library entries too, so --uninstall is a true restore
  cp -p "$LIB"/*.json "$BK/configLibrary/" 2>/dev/null || true
  ok "backup complete"
fi

# 2. write the config library entry.
#    Keys are the flat spellings the *local* tier validates. Note
#    "disableDeploymentModeChooser" (flatKey), NOT "disableClaudeAiSignIn"
#    (the enum name): the local tier accepts only flatKeys, and logs
#    "not a recognized configuration key" for the enum spelling. The plist
#    reader has the opposite convention — see README.
say "writing config library entry"
mkdir -p "$LIB"
chmod 700 "$LIB"
cat >"$ENTRY" <<EOF
{
  "inferenceProvider": "gateway",
  "inferenceCredentialKind": "static",
  "inferenceGatewayBaseUrl": "http://127.0.0.1:$PORT",
  "inferenceGatewayApiKey": "$KEY",
  "inferenceGatewayAuthScheme": "bearer",
  "disableDeploymentModeChooser": true
}
EOF
# plutil -lint only validates plist syntax; -convert is what parses JSON.
plutil -convert xml1 -o /dev/null "$ENTRY" 2>/dev/null \
  || { err "wrote malformed JSON to $ENTRY"; exit 1; }
ok "wrote $ENTRY"

# 3. point _meta.json at it, preserving any existing fields
say "updating $META"
[[ -f "$META" ]] || printf '{"entries":[]}\n' >"$META"
plutil -replace appliedId -string "$ENTRY_ID" "$META" 2>/dev/null \
  || plutil -insert appliedId -string "$ENTRY_ID" "$META"
ok "_meta.json appliedId -> $ENTRY_ID"

# 4. flip the persisted deployment mode. 3p is what actually selects the
#    gateway; the library entry is what supplies the credentials.
if [[ -f "$CONFIG" ]]; then
  plutil -replace deploymentMode -string "3p" "$CONFIG" 2>/dev/null \
    || plutil -insert deploymentMode -string "3p" "$CONFIG"
  ok "deploymentMode -> 3p"
else
  warn "no $CONFIG yet; launching the app will create it. Re-run this script after the first 3p launch."
fi

# 5. verify what actually landed
say "verifying"
plutil -p "$ENTRY"
printf 'deploymentMode: '; plutil -extract deploymentMode raw -o - "$CONFIG" 2>/dev/null || echo '(unset)'

cat <<EOF

$(ok "configured. Now launch Claude Desktop:")
    open -a Claude

  It should come up in third-party mode with claude-opus-5-5 in the picker.
  Confirm from the app's own log:

    grep -E '3P mode active|apiHost|Model discovery' \\
      ~/Library/Logs/Claude-3p/main.log | tail -5

  Expected:
    [custom-3p] Credentials loaded from managed config { provider: 'gateway' }
    [custom-3p] 3P mode active { provider: 'gateway' }
    [custom-3p] inference apiHost=http://127.0.0.1:$PORT

  To revert:  $0 --uninstall
EOF
