#!/usr/bin/env bash
# Keep a durable registry of interactive Claude Code sessions so that
# `claude-sessions resume` can bring them all back after a reboot.
#
# Wiring (in ~/.claude/settings.json — install.sh does this for you):
#   SessionStart      -> session-registry.sh record
#   UserPromptSubmit  -> session-registry.sh record   (catches /rename)
#   SessionEnd        -> session-registry.sh end
#
# Registry: one file per session at ~/.claude/resume/sessions/<session_id>.json
# so a dozen sessions starting at once never race on a shared file.
#
# Why SessionEnd keeps the entry on reason "other": that is what Claude Code
# reports when the process is HUP'd — a closed tab, a quitting terminal, a
# reboot. Those are exactly the sessions we want back. A deliberate /exit,
# Ctrl-D or /clear reports prompt_input_exit / logout / clear and is removed.
# (Verified on 2.1.270: /exit -> prompt_input_exit, SIGHUP -> other.)
#
# Fails open everywhere: any error simply leaves the registry as it was and
# exits 0. Nothing here may block, slow down, or print into a session —
# SessionStart/UserPromptSubmit stdout would be injected into the context.
set -uo pipefail

REG="${CLAUDE_RESUME_DIR:-$HOME/.claude/resume}/sessions"
LIVE="$HOME/.claude/sessions"        # Claude's own per-PID registry
cmd="${1:-record}"

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat) || exit 0
[ -z "$input" ] && exit 0

sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
[ -z "$sid" ] && exit 0
entry="$REG/$sid.json"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

case "$cmd" in
  record)
    # Only real terminal sessions get registered. Three things are not tabs:
    #   * `claude -p` (scripts, benchmarks, subagents): entrypoint sdk-cli
    #   * daemon-forked background sessions: Claude records kind "bg" for them,
    #     and they DO have entrypoint cli and a pty, so the kind field is the
    #     only reliable signal
    #   * anything with no controlling terminal
    [ "${CLAUDE_CODE_ENTRYPOINT:-}" = "cli" ] || exit 0

    live="$LIVE/${CLAUDE_PID:-none}.json"
    if [ -f "$live" ]; then
      kind=$(jq -r '.kind // empty' "$live" 2>/dev/null)
      # Skip only when Claude positively says this is not interactive; if the
      # file is missing or unreadable, fall through to the tty check rather
      # than silently failing to register a real session.
      [ -n "$kind" ] && [ "$kind" != "interactive" ] && exit 0
    fi

    if [ -n "${CLAUDE_PID:-}" ]; then
      tty=$(ps -o tty= -p "$CLAUDE_PID" 2>/dev/null | tr -d ' ')
      case "$tty" in ""|"??"|"-") exit 0 ;; esac
    fi

    mkdir -p "$REG" 2>/dev/null || exit 0

    # Name: the hook payload carries session_title once the session is named
    # (-n / --name / /rename). Fall back to Claude's own registry, and finally
    # keep whatever name we already had.
    title=$(printf '%s' "$input" | jq -r '.session_title // empty' 2>/dev/null)
    if [ -z "$title" ] && [ -f "$live" ]; then
      title=$(jq -r 'select(.nameSource == "user") | .name // empty' "$live" 2>/dev/null)
    fi

    prev=$(jq -c . "$entry" 2>/dev/null) || prev='{}'
    printf '%s' "$prev" | jq -c \
      --arg sid "$sid" --arg name "$title" --arg now "$now" --arg pid "${CLAUDE_PID:-}" \
      --argjson in "$input" '
      {
        session_id: $sid,
        name: (if $name != "" then $name else (.name // "") end),
        cwd: ($in.cwd // .cwd // ""),
        transcript_path: ($in.transcript_path // .transcript_path // ""),
        first_seen: (.first_seen // $now),
        last_seen: $now,
        last_event: ([$in.hook_event_name, $in.source] | map(select(. != null)) | join(":")),
        pid: (($pid | tonumber?) // null)
      }' > "$entry.tmp.$$" 2>/dev/null && mv -f "$entry.tmp.$$" "$entry"
    rm -f "$entry.tmp.$$" 2>/dev/null
    ;;

  end)
    reason=$(printf '%s' "$input" | jq -r '.reason // "other"' 2>/dev/null)
    case "$reason" in
      prompt_input_exit|logout|clear)
        rm -f "$entry" ;;
      *)
        # HUP / crash / reboot: keep it (that is the whole point), just note it.
        if [ -f "$entry" ]; then
          jq -c --arg now "$now" --arg r "$reason" '. + {ended_at: $now, end_reason: $r}' \
            "$entry" > "$entry.tmp.$$" 2>/dev/null && mv -f "$entry.tmp.$$" "$entry"
          rm -f "$entry.tmp.$$" 2>/dev/null
        fi ;;
    esac
    ;;
esac
exit 0
