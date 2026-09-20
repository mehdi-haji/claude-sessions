#!/usr/bin/env bash
# Install claude-sessions: the hook, the CLI, and the login agent.
# Idempotent — safe to re-run after `git pull`.
#
#   ./install.sh              symlink into ~/.claude (repo stays the source of truth)
#   ./install.sh --copy       copy instead, so the repo can be deleted afterwards
#   ./install.sh --no-agent   skip the LaunchAgent (no automatic resume at login)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
AGENT_LABEL="com.claude-sessions.resume"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
RESUME_DIR="${CLAUDE_RESUME_DIR:-$CLAUDE_DIR/resume}"

MODE=symlink
WANT_AGENT=1
for a in "$@"; do
  case "$a" in
    --copy) MODE=copy ;;
    --no-agent) WANT_AGENT=0 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

say() { printf '  %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "macOS only (uses launchd + AppleScript)"
command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq)"
PYTHON=$(command -v python3 || true)
[ -x /usr/bin/python3 ] && PYTHON=/usr/bin/python3   # always present, stable path
[ -n "$PYTHON" ] || die "python3 is required"

echo "installing claude-sessions ($MODE)"
mkdir -p "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/bin" "$HOME/.local/bin" "$RESUME_DIR/sessions"

link() {  # src dst
  rm -f "$2"
  if [ "$MODE" = copy ]; then cp "$1" "$2"; else ln -s "$1" "$2"; fi
  chmod +x "$2" 2>/dev/null || true
}
link "$REPO/hooks/session-registry.sh" "$CLAUDE_DIR/hooks/session-registry.sh"
link "$REPO/bin/claude-sessions"       "$CLAUDE_DIR/bin/claude-sessions"
link "$CLAUDE_DIR/bin/claude-sessions" "$HOME/.local/bin/claude-sessions"
say "hook  -> $CLAUDE_DIR/hooks/session-registry.sh"
say "cli   -> $HOME/.local/bin/claude-sessions"

# --- wire the three hooks into settings.json (idempotent, with a backup) -----
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
"$PYTHON" - "$SETTINGS" "$CLAUDE_DIR/hooks/session-registry.sh" <<'PY'
import json, sys
settings, hook = sys.argv[1], sys.argv[2]
with open(settings) as fh:
    s = json.load(fh)
hooks = s.setdefault("hooks", {})
for event, arg in (("SessionStart", "record"),
                   ("UserPromptSubmit", "record"),
                   ("SessionEnd", "end")):
    lst = hooks.setdefault(event, [])
    # replace any previous wiring of this hook (path may have changed)
    for grp in lst:
        grp["hooks"] = [h for h in grp.get("hooks", [])
                        if "session-registry.sh" not in h.get("command", "")]
    lst[:] = [g for g in lst if g.get("hooks")]
    lst.append({"hooks": [{"type": "command",
                           "command": "%s %s" % (hook, arg),
                           "timeout": 10}]})
    print("  hook  %-17s -> session-registry.sh %s" % (event, arg))
with open(settings, "w") as fh:
    json.dump(s, fh, indent=2)
    fh.write("\n")
PY

# --- login agent -------------------------------------------------------------
if [ "$WANT_AGENT" = 1 ]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  sed -e "s|__PYTHON__|$PYTHON|g" \
      -e "s|__CLI__|$CLAUDE_DIR/bin/claude-sessions|g" \
      -e "s|__LOG__|$RESUME_DIR/launchd.log|g" \
      -e "s|__PATH__|/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin|g" \
      "$REPO/launchagent/$AGENT_LABEL.plist.template" > "$AGENT_PLIST"
  plutil -lint "$AGENT_PLIST" >/dev/null || die "generated plist is invalid"
  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
  say "agent -> $AGENT_PLIST (runs at login)"
  say "        it runs once now, so registered-but-closed sessions reopen"
else
  say "agent   skipped (--no-agent)"
fi

# --- seed the registry from whatever is running right now --------------------
"$CLAUDE_DIR/bin/claude-sessions" snapshot | sed 's/^/  /'

cat <<DONE

done. Sessions register themselves from now on.
  claude-sessions list      what will come back
  claude-sessions resume    bring back everything not currently running
DONE
