#!/bin/bash
# Registers notify-usage-bar.sh with Claude Code so ClaudeUsageBar's notch can
# show live activity. Backs up ~/.claude/settings.json first and merges rather
# than overwriting, so any hooks you already have are left alone.
#
# Undo with: ./install-hooks.sh --uninstall
set -euo pipefail
cd "$(dirname "$0")"

HOOK="$(pwd)/notify-usage-bar.sh"
SETTINGS="$HOME/.claude/settings.json"
MODE="${1:-install}"

[ -x "$HOOK" ] || { echo "Hook script not executable: $HOOK" >&2; exit 1; }
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

BACKUP="$SETTINGS.bak.$(date +%Y%m%d-%H%M%S)"
cp "$SETTINGS" "$BACKUP"
echo "Backed up settings to $BACKUP"

/usr/bin/python3 - "$SETTINGS" "$HOOK" "$MODE" <<'PY'
import json, sys

settings_path, hook, mode = sys.argv[1], sys.argv[2], sys.argv[3]
with open(settings_path) as f:
    cfg = json.load(f)

# PreToolUse/PostToolUse take a matcher; the others fire unconditionally.
events = {
    "SessionStart":     None,
    "UserPromptSubmit": None,
    "PreToolUse":       "*",
    "PostToolUse":      "*",
    "Notification":     None,
    "Stop":             None,
    "SessionEnd":       None,
}

hooks = cfg.setdefault("hooks", {})

def is_ours(entry):
    return any(h.get("command", "").endswith("notify-usage-bar.sh")
               for h in entry.get("hooks", []))

for event, matcher in events.items():
    groups = [g for g in hooks.get(event, []) if not is_ours(g)]
    if mode != "--uninstall":
        entry = {"hooks": [{"type": "command", "command": hook, "timeout": 5}]}
        if matcher is not None:
            entry["matcher"] = matcher
        groups.append(entry)
    if groups:
        hooks[event] = groups
    else:
        hooks.pop(event, None)

if not hooks:
    cfg.pop("hooks", None)

with open(settings_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

print("Uninstalled." if mode == "--uninstall" else "Installed hooks for: " + ", ".join(events))
PY

echo
echo "Restart any running Claude Code sessions for the change to take effect."
