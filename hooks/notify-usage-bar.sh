#!/bin/bash
# Claude Code hook -> ClaudeUsageBar.
#
# Claude Code pipes a JSON payload on stdin. We forward ONLY the three fields the
# notch displays (event name, session id, tool name) to a local Unix socket owned
# by ClaudeUsageBar. No prompt text, no file contents, no tool arguments leave
# this script, and nothing from the payload is ever executed.
#
# It must never slow Claude Code down or fail a turn: every path exits 0, and the
# send is bounded by a short timeout in case the socket has no reader.
set -u

SOCK="$HOME/Library/Application Support/ClaudeUsageBar/activity.sock"
[ -S "$SOCK" ] || exit 0            # app not running — nothing to do

payload=$(cat 2>/dev/null) || exit 0

line=$(printf '%s' "$payload" | /usr/bin/python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
out = {
    "hook_event_name": str(d.get("hook_event_name", ""))[:32],
    "session_id":      str(d.get("session_id", ""))[:64],
    "tool_name":       str(d.get("tool_name", ""))[:32],
}
sys.stdout.write(json.dumps(out))
' 2>/dev/null) || exit 0

[ -n "$line" ] || exit 0

# nc speaks Unix sockets on macOS; the timeout stops a wedged reader from
# blocking the hook (and therefore Claude Code) indefinitely.
printf '%s\n' "$line" | /usr/bin/nc -U -w 1 "$SOCK" >/dev/null 2>&1

exit 0
