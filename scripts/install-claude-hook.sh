#!/bin/bash
#
# Registers (or removes) HerdNotch's Claude Code PermissionRequest hook in Claude's user settings.
#
# It BACKS UP settings.json first, REPLACES any earlier HerdNotch hook entry (so running it twice leaves
# one), and leaves every other key and hook untouched. The new content is built in a temp file and then
# copied over settings.json in place, which keeps its mode and any symlink.
#
# Usage:
#     scripts/install-claude-hook.sh [--app /path/HerdNotch.app]
#     scripts/install-claude-hook.sh [--app /path/HerdNotch.app] --uninstall

set -euo pipefail

APP="/Applications/HerdNotch.app"
# Run from inside the bundle (Contents/Resources): the app is two levels up.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ "$(basename "$SELF_DIR")" = "Resources" ] && [ "$(basename "$(dirname "$SELF_DIR")")" = "Contents" ]; then
    APP="$(dirname "$(dirname "$SELF_DIR")")"
fi
UNINSTALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --app)
            [ $# -ge 2 ] || { echo "error: --app needs a path" >&2; exit 2; }
            APP="$2"
            shift 2
            ;;
        --uninstall)
            UNINSTALL=1
            shift
            ;;
        *)
            echo "usage: $0 [--app /path/HerdNotch.app] [--uninstall]" >&2
            exit 2
            ;;
    esac
done

if [ -x /usr/bin/jq ]; then
    JQ=/usr/bin/jq
elif command -v jq >/dev/null 2>&1; then
    JQ="$(command -v jq)"
else
    echo "error: jq not found" >&2
    exit 1
fi

APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
EXE="$APP/Contents/MacOS/HerdNotch"
if [ "$UNINSTALL" -eq 0 ] && [ ! -x "$EXE" ]; then
    echo "error: HerdNotch executable not found at $EXE" >&2
    exit 1
fi

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CONFIG_DIR/settings.json"
mkdir -p "$CONFIG_DIR"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
"$JQ" -e . "$SETTINGS" >/dev/null || { echo "error: $SETTINGS is not valid JSON" >&2; exit 1; }

BACKUP="$SETTINGS.herdnotch-backup-$(date +%Y%m%d-%H%M%S)"
cp "$SETTINGS" "$BACKUP"

COMMAND="\"$EXE\" --claude-permission-hook"
TMP="$(mktemp "$SETTINGS.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

# The literal flag below is PermissionHookClient.flag in HerdKit; keep the two in sync.
# Drop every group's HerdNotch hook, then any group left with no hooks.
"$JQ" --arg cmd "$COMMAND" --argjson install "$((1 - UNINSTALL))" '
    def strip:
        if .hooks.PermissionRequest then
            .hooks.PermissionRequest |= (
                map(if has("hooks") then .hooks = ((.hooks // []) | map(select((.command // "") | contains("--claude-permission-hook") | not))) else . end)
                | map(select((has("hooks") | not) or ((.hooks | length) > 0)))
            )
        else . end;
    strip
    | if $install == 1 then
        .hooks.PermissionRequest = ((.hooks.PermissionRequest // []) + [
            {"matcher": "", "hooks": [{"type": "command", "command": $cmd, "timeout": 600}]}
        ])
      elif (.hooks.PermissionRequest // [1]) == [] then del(.hooks.PermissionRequest)
      else . end
' "$SETTINGS" > "$TMP"

echo "Backup written to $BACKUP"
cat "$TMP" > "$SETTINGS" || { cat "$BACKUP" > "$SETTINGS"; echo "Write failed. Restored from $BACKUP" >&2; exit 1; }
rm -f "$TMP"
trap - EXIT

if [ "$UNINSTALL" -eq 1 ]; then
    echo "Removed the HerdNotch PermissionRequest hook from $SETTINGS"
else
    echo "Installed the HerdNotch PermissionRequest hook in $SETTINGS"
    echo "Command: $COMMAND"
fi
echo "New Claude sessions pick this up. Running sessions keep their old settings."
