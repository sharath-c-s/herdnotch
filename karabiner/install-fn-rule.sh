#!/bin/bash
#
# Appends every rule in RULE_FILES below to every Karabiner-Elements profile: the fn-double-tap rule
# (herd-fn-double-tap.json, pane search). It relays a double-tap of fn into a bare F19 that Carbon can
# register; see the JSON file's own comments-by-example for the shape. (The caffeinate toggle no longer
# needs a rule here — it moved to the ordinary chord Control+Shift+C, which Carbon claims directly.)
#
# Why a script rather than "paste this into the Karabiner UI": Karabiner's own import flow only offers rules
# published to its online catalogue, and hand-editing karabiner.json is how people lose the rules they
# already had. This does the append with three properties that matter:
#
#   1. It BACKS UP first, to karabiner.json.herd-backup-<timestamp>, and refuses to continue if that fails.
#   2. It APPENDS. Every existing complex modification, including a CapsLock remap, is preserved verbatim.
#   3. It is IDEMPOTENT, per rule. Each rule is matched by its own `description`, so running this twice
#      leaves one copy of each, and running it after editing one rule replaces that rule's old copy in place
#      without touching the other.
#
# Every rule file is applied in its own del-then-append (or just del, for --remove) jq pass, chained one
# after another so the whole run still ends in a single atomic write: it writes the final result through a
# temporary file and moves it into place, so an interrupted run cannot leave a truncated karabiner.json,
# which Karabiner would reject wholesale and which would take the user's existing rules with it.
#
# Karabiner watches karabiner.json and reloads it within a second or so, so no restart is needed. The script
# lints each rule file and prints what it found, because a rule Karabiner rejects fails silently: the key
# simply does nothing and the only evidence is in Karabiner's own log.
#
# Re-run this after pulling a change that adds or edits a rule here — Karabiner never sees a new rule file on
# its own, only what this script has actually merged into karabiner.json.
#
# Usage:
#     ./install-fn-rule.sh            # append or update the fn-fn rule
#     ./install-fn-rule.sh --remove   # take it out again, leaving everything else alone
#     ./install-fn-rule.sh --dry-run  # print what would change and touch nothing

set -euo pipefail

cd "$(dirname "$0")"

RULE_FILES=(
    "$PWD/herd-fn-double-tap.json"
)
CONFIG="$HOME/.config/karabiner/karabiner.json"
KARABINER_CLI="/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"

MODE="install"
case "${1:-}" in
    --remove)  MODE="remove" ;;
    --dry-run) MODE="dry-run" ;;
    "")        ;;
    *)         echo "usage: $0 [--remove|--dry-run]" >&2; exit 2 ;;
esac

for tool in jq; do
    command -v "$tool" >/dev/null || { echo "error: $tool is required" >&2; exit 1; }
done
for RULE_FILE in "${RULE_FILES[@]}"; do
    [ -f "$RULE_FILE" ] || { echo "error: $RULE_FILE is missing" >&2; exit 1; }
done
[ -f "$CONFIG" ] || { echo "error: $CONFIG does not exist; open Karabiner-Elements once first" >&2; exit 1; }

jq -e . "$CONFIG" >/dev/null || { echo "error: $CONFIG is not valid JSON; not touching it" >&2; exit 1; }

echo "==> profiles and existing complex modifications, before:"
jq -r '.profiles[] | "    \(.name): \((.complex_modifications.rules // []) | length) rule(s)"' "$CONFIG"
jq -r '.profiles[] | .complex_modifications.rules // [] | .[] | "      - \(.description // "(no description)")"' \
    "$CONFIG"

# Every rule file is applied in turn, each pass reading the previous pass's own output, chaining into one
# final result before anything is written to disk. Temp files accumulate in STEP_FILES and are all cleaned
# up on exit, success or failure alike.
STEP_FILES=()
cleanup() { rm -f "${STEP_FILES[@]:-}"; }
trap cleanup EXIT

CURRENT="$CONFIG"
for RULE_FILE in "${RULE_FILES[@]}"; do
    # The description is the identity. Matching on it is what makes each rule's own append idempotent and
    # what makes an edit to that rule replace rather than duplicate, independently of every other rule file.
    DESCRIPTION="$(jq -r '.rules[0].description' "$RULE_FILE")"
    [ -n "$DESCRIPTION" ] && [ "$DESCRIPTION" != "null" ] \
        || { echo "error: $RULE_FILE has no .rules[0].description to match on" >&2; exit 1; }
    echo "==> rule: $DESCRIPTION"

    # `del` first, then append for an install. That is what makes a re-run replace rather than duplicate,
    # and it is also the whole of --remove. `(.complex_modifications.rules // [])` covers a profile that has
    # never had one, which would otherwise be a null the append could not extend.
    if [ "$MODE" = "remove" ]; then
        PROGRAM='
          .profiles |= map(
            .complex_modifications.rules = (
              (.complex_modifications.rules // []) | map(select(.description != $description))
            )
          )'
        ARGS=(--arg description "$DESCRIPTION")
    else
        PROGRAM='
          .profiles |= map(
            .complex_modifications.rules = (
              ((.complex_modifications.rules // []) | map(select(.description != $description))) + [$rule]
            )
          )'
        ARGS=(--arg description "$DESCRIPTION" --argjson rule "$(jq -c '.rules[0]' "$RULE_FILE")")
    fi

    STEP="$(mktemp -t karabiner-herd)"
    STEP_FILES+=("$STEP")
    jq "${ARGS[@]}" "$PROGRAM" "$CURRENT" > "$STEP"

    # Checked before this step's result becomes input to the next, because a jq program that produced valid
    # JSON with the wrong shape would otherwise propagate silently through every remaining rule and only
    # fail later, inside Karabiner, where the user cannot see it.
    jq -e '.profiles | length > 0' "$STEP" >/dev/null \
        || { echo "error: result has no profiles after applying $RULE_FILE; aborting without writing" >&2; exit 1; }
    if [ "$MODE" != "remove" ]; then
        jq -e --arg d "$DESCRIPTION" \
            'all(.profiles[]; [.complex_modifications.rules[].description] | map(select(. == $d)) | length == 1)' \
            "$STEP" >/dev/null \
            || { echo "error: rule '$DESCRIPTION' is not present exactly once per profile; aborting" >&2; exit 1; }
    fi
    CURRENT="$STEP"
done

if [ "$MODE" = "dry-run" ]; then
    echo "==> dry run, nothing written. Result would be:"
    jq -r '.profiles[] | "    \(.name): \((.complex_modifications.rules // []) | length) rule(s)"' "$CURRENT"
    jq -r '.profiles[] | .complex_modifications.rules // [] | .[] | "      - \(.description)"' "$CURRENT"
    exit 0
fi

BACKUP="$CONFIG.herd-backup-$(date +%Y%m%d-%H%M%S)"
cp -p "$CONFIG" "$BACKUP"
[ -s "$BACKUP" ] || { echo "error: backup to $BACKUP failed; aborting" >&2; exit 1; }
echo "==> backed up to $BACKUP"

# Copied into place rather than moved, so the file keeps its own inode, ownership and permissions. Karabiner
# watches the path; replacing the inode has been observed to make file watchers miss the change.
cat "$CURRENT" > "$CONFIG"

echo "==> after:"
jq -r '.profiles[] | "    \(.name): \((.complex_modifications.rules // []) | length) rule(s)"' "$CONFIG"
jq -r '.profiles[] | .complex_modifications.rules // [] | .[] | "      - \(.description)"' "$CONFIG"

if [ -x "$KARABINER_CLI" ]; then
    for RULE_FILE in "${RULE_FILES[@]}"; do
        "$KARABINER_CLI" --lint-complex-modifications "$RULE_FILE" || true
    done
fi

if [ "$MODE" = "remove" ]; then
    echo "==> removed. Set a different shortcut in Boring Herd Bar's settings window."
else
    cat <<'NOTE'
==> installed. Karabiner reloads within about a second; no restart needed.

Press fn twice, quickly. Boring Herd Bar's / HerdNotch's pane search should open.
Press left Control twice, quickly. HerdNotch's caffeinate toggle should fire (see `pmset -g assertions`).

If the emoji picker opens as well, macOS is still acting on the fn tap itself. This rule deliberately
forwards fn through so that fn+arrow, fn+delete and fn+F1 keep working, and macOS's globe-key action fires
on that forwarded tap. Turn the action off in System Settings > Keyboard > "Press the globe key to" > "Do
Nothing", or equivalently:

    defaults write com.apple.HIToolbox AppleFnUsageType -int 0

and log out and back in.
NOTE
fi
