#!/usr/bin/env bash
# Remove claude-sessions: the login agent, the CLI, the hook, and its wiring.
# The registry in ~/.claude/resume is left alone unless you pass --purge.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
AGENT_LABEL="com.claude-sessions.resume"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
RESUME_DIR="${CLAUDE_RESUME_DIR:-$CLAUDE_DIR/resume}"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

PYTHON=$(command -v python3 || echo /usr/bin/python3)

launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null && echo "  agent unloaded" || true
rm -f "$AGENT_PLIST" "$CLAUDE_DIR/bin/claude-sessions" \
      "$HOME/.local/bin/claude-sessions" "$CLAUDE_DIR/hooks/session-registry.sh"
echo "  cli + hook removed"

if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  "$PYTHON" - "$SETTINGS" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as fh:
    s = json.load(fh)
for event, groups in list(s.get("hooks", {}).items()):
    for grp in groups:
        grp["hooks"] = [h for h in grp.get("hooks", [])
                        if "session-registry.sh" not in h.get("command", "")]
    s["hooks"][event] = [g for g in groups if g.get("hooks")]
    if not s["hooks"][event]:
        del s["hooks"][event]
with open(p, "w") as fh:
    json.dump(s, fh, indent=2)
    fh.write("\n")
print("  hooks unwired from settings.json")
PY
fi

if [ "$PURGE" = 1 ]; then
  rm -rf "$RESUME_DIR"; echo "  registry purged ($RESUME_DIR)"
else
  echo "  registry kept at $RESUME_DIR (pass --purge to delete)"
fi
