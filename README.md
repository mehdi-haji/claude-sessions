# claude-sessions

Reopen every named [Claude Code](https://claude.com/claude-code) session after a
reboot — same directories, same conversations, same tab names, in about 30 seconds.

If you keep a dozen Claude Code sessions open across a few projects, a restart
for OS updates means reopening each tab by hand and trying to remember what each
one was doing. This registers your sessions as you work and brings them all back
when you log in.

```
$ claude-sessions list
NAME                     STATUS                       DIRECTORY                 ID
SHE-T0                   running (pid 40024)          ~/projects/SHE            8ef6cf86
SHE-T1                   closed other @ 22:27Z        ~/projects/SHE            5bd08f50
TF-T0                    registered                   ~/projects/TradeForge     136cb54f

$ claude-sessions resume
18:16:30 skip  SHE-T0    already running (pid 40024)
18:16:30 resuming 2 session(s)
18:16:31 open  SHE-T1    ~/projects/SHE          (5bd08f50)
18:16:32 open  TF-T0     ~/projects/TradeForge   (136cb54f)
18:16:32 done: 2 opened, 0 failed
```

## How it works

Three [hooks](https://docs.claude.com/en/docs/claude-code/hooks) maintain a small
registry, and a launchd agent reads it at login:

| | |
|---|---|
| `SessionStart` | record the session's id, name, and directory |
| `UserPromptSubmit` | refresh it — this is what picks up `/rename` |
| `SessionEnd` | delete the entry **only** if you left on purpose |

The registry lives in `~/.claude/resume/sessions/<session-id>.json`, one file per
session so that a dozen sessions starting at once never race. At login the agent
runs `claude-sessions resume`, which opens one terminal tab per registered session
running `cd <dir> && claude --resume <id>`.

Claude keeps its own live session list in `~/.claude/sessions/<pid>.json`, but it
is deleted when a session exits — including at shutdown — so it cannot answer
"what was open before the reboot?". That is the gap this fills.

### What counts as "left on purpose"

This is the one thing worth understanding, because it decides what comes back:

| You do | Claude reports | Registry | After reboot |
|---|---|---|---|
| `/exit`, Ctrl-D | `prompt_input_exit` | removed | gone |
| `/clear` | `clear` | removed (a new session is registered) | comes back, cleared |
| Close the tab, quit the terminal, reboot, crash | `other` | **kept** | **comes back** |

A reboot HUPs every session, and Claude reports that as `SessionEnd` with reason
`other` — so a hook that simply deleted on `SessionEnd` would wipe the registry
seconds before the restart it is meant to survive. Only the deliberate-exit
reasons delete.

So: **`/exit` means "I'm done with this", closing the tab means "keep it".**
Changed your mind about one you closed? `claude-sessions forget SHE-T1`.

### What is not registered

Only real terminal sessions. `claude -p` runs (scripts, benchmarks, subagents)
report `entrypoint: sdk-cli`, and daemon-spawned background sessions are marked
`kind: bg` by Claude — both are skipped, as is anything with no controlling
terminal. Without the `kind` check, background sessions slip through: they have
`entrypoint: cli` and a pty just like a real tab.

## Install

Requires macOS, [jq](https://jqlang.github.io/jq/), and iTerm2 or Terminal.app.

```bash
git clone https://github.com/mehdi-haji/claude-sessions.git
cd claude-sessions
./install.sh
```

That symlinks the hook and CLI into `~/.claude`, wires the three hooks into
`~/.claude/settings.json` (backing it up first, and leaving any other hooks
alone), installs the login agent, and registers whatever you already have open.
The agent runs once as it loads, so if the registry already holds sessions that
are not running, they reopen right then — that is the install proving itself.
Sessions that were running before the install are picked up by `snapshot`; every
new one registers itself.

```bash
./install.sh --copy       # copy instead of symlink, so the repo can be deleted
./install.sh --no-agent   # no automatic resume at login; run `resume` yourself
./uninstall.sh            # remove everything (add --purge to drop the registry)
```

## Commands

| | |
|---|---|
| `claude-sessions resume` | open every registered session that is not already running |
| `claude-sessions list` | show the registry with running / closed status |
| `claude-sessions snapshot` | register the sessions running right now |
| `claude-sessions forget <name\|id>` | drop an entry so it does not come back |
| `claude-sessions prune` | drop entries whose directory or transcript is gone |

`resume` flags: `--dry-run`, `--new-window`, `--terminal iterm2\|terminal`,
and `--at-login` (what the launchd agent uses: waits for the desktop to settle
and retries while the terminal is still starting up).

Resuming is always safe to run by hand — sessions that are already running are
skipped, and tabs open in name order, so `SHE-T0 … SHE-T5`, `TF-T0 …` come back
in the same arrangement every time.

## Layout

```
bin/claude-sessions                  the CLI (python3, stdlib only)
hooks/session-registry.sh            the hook: `record` and `end`
launchagent/…plist.template          login agent, filled in by install.sh
install.sh / uninstall.sh
```

Files it touches on your machine:

```
~/.claude/resume/sessions/*.json     the registry
~/.claude/resume/resume.log          what resume did, and when
~/.claude/resume/launchd.log         what the login agent did
~/.claude/settings.json              hook wiring (backed up on every install)
~/Library/LaunchAgents/com.claude-sessions.resume.plist
```

Both scripts fail open: any error leaves the registry untouched and exits 0.
Hooks run on every prompt, so one that blocks or errors is worse than no hook at
all — and `SessionStart`/`UserPromptSubmit` stdout is injected into the session's
context, so these print nothing.

## Notes

- **Terminals.** iTerm2 gets one tab per session in a single window. Terminal.app
  opens one window per session — tabs there need Accessibility permission to
  send Cmd-T, which isn't worth the prompt. Auto-detected; override with
  `--terminal`.
- **Names.** `claude -n <name>` at launch, or `/rename` in a running session.
  Unnamed sessions are registered too; they just come back as `(unnamed 8ef6cf86)`.
  Names survive resume because `claude --resume <id>` restores the custom title.
- **New machine.** The registry stores absolute paths, so it moves with your home
  directory (Migration Assistant, same username) and your sessions reopen on the
  new Mac at first login. For a clean install, copy `~/.claude/resume/` and
  `~/.claude/projects/` (the transcripts), then run `./install.sh`.
- **Nothing is sent anywhere.** The registry holds session ids, names, and paths,
  and stays on your machine.

## Troubleshooting

| | |
|---|---|
| Nothing comes back at login | `cat ~/.claude/resume/launchd.log`; check the agent with `launchctl print gui/$(id -u)/com.claude-sessions.resume` |
| A session never registers | it must be a real terminal session; confirm with `claude-sessions list` after sending one prompt |
| An entry says `UNRESUMABLE` | the directory or transcript is gone — `claude-sessions prune` |
| Too many tabs come back | `claude-sessions forget <name>`, or `/exit` the ones you are done with |
| Hook changes not picked up | hooks are read per event; if in doubt, start a new session |

Built with [Claude Code](https://claude.com/claude-code), on Claude Code 2.1.270.
Verified against that version's hook payloads; `session_title` in the
`SessionStart`/`UserPromptSubmit` payloads and the `SessionEnd` `reason` values
are the two things a future version could change.

## License

MIT
