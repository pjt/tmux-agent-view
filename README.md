# tmux-agent-view

[Claude Code's agent view](https://code.claude.com/docs/en/agent-view), for tmux —
see every AI agent across all your sessions and jump to any of them in one keystroke.
Zero configuration.

```
┌────────────────────────── ✻ agents ───────────────────────────┐
│  enter jump · ctrl-r refresh · esc close        ┌─────────────┤
│ ▲ needs input                                   │             │
│▌  ▲  proj-a:1   fix login bug       ⎇ fix/login │  (live view │
│ ✻ working                                       │   of the    │
│   ✻  proj-b:0   refactor api        ⎇ main      │   selected  │
│   ✻  proj-b:2   write e2e tests     ⎇ tests     │   agent's   │
│ ✔ completed                                     │   screen)   │
│   ✔  proj-c:1   migrate db schema   ⎇ main      │             │
│ ○ idle                                          │             │
│◂  ○  proj-c:3   …                               │             │
└─────────────────────────────────────────────────┴─────────────┘
```

You run one tmux session per project, each window split into an agent pane plus
nvim/shell panes. `prefix + a` pops up a picker of every agent pane in every session —
grouped by live status, with git branch, conversation topic, and a live preview of each
agent's screen. Press enter (or click) and tmux switches session → window → pane. Your
window layouts stay exactly as they were.

## Why not a sidebar?

Plugins like [tmux-agent-sidebar](https://github.com/hiroppy/tmux-agent-sidebar) and
[tmux-agent-status](https://github.com/samleeney/tmux-agent-status) keep a persistent
sidebar pane fed by agent hooks. tmux-agent-view takes the opposite approach:

- **On-demand, nothing docked.** A single bash script scans panes when you press the
  key — no sidebar eating your layout, no daemon, no binary.
- **Zero-config discovery.** Agents are found by scanning pane processes, so every
  agent shows up with no setup at all.
- **Hooks are opt-in and lightweight.** For rock-solid state, [one command](#hooks--accurate-state--clickable-notifications)
  wires each agent CLI to write a tiny per-pane state file — no long-running process.
  Without them, state falls back to reading the screen.
- **macOS system bash is enough** (bash 3.2 compatible).

## Agent states

Six states, mirroring [Claude Code's agent view](https://code.claude.com/docs/en/agent-view).
With [hooks](#hooks--accurate-state--clickable-notifications) installed, each agent CLI
reports its own state as it changes — accurate, instant, and the only way to catch agents
(like Kimi Code) that leave no "done" marker on screen. Without hooks, state is read from
the pane's screen content as a fallback. The picker groups agents by state; states that
need you sort first. Within a group, agents are ordered by your most recent visits (LRU):
tmux's session attach times and per-session window stacks, both driven only by your
navigation — an agent spamming output never jumps the queue.

| state | meaning | hook event → / screen fallback matches |
|---|---|---|
| `▲ needs input` | waiting on a permission decision or a question | `Notification` / `PermissionRequest` · `Do you want …` / a numbered `❯ 1.` choice |
| `✖ failed` | turn ended with an API/tool error | `StopFailure` (Kimi) · `API Error`, rate limit / timeout / auth messages |
| `■ stopped` | you interrupted it (esc / ctrl-c) | `Interrupt` (Kimi) · `Interrupted` marker |
| `✻ working` | generating or running tools | `UserPromptSubmit` / `PreToolUse` · spinner line `✻ Doing… (…)` / `esc to interrupt` |
| `✔ completed` | last turn finished normally | `Stop` · turn summary `✻ Worked for 1m 5s` / `※ recap:` line |
| `○ idle` | sitting at the prompt | `SessionStart` · none of the above |

In the screen-scrape fallback, the marker closest to the bottom of the screen wins, so a
permission dialog below a spinner reads as *needs input*, and a fresh spinner below an old
turn summary reads as *working*.

## Features

- **All sessions, one picker** — every pane running Claude Code / Codex / OpenCode /
  aider / Kimi Code, grouped by state, agents that need you first
- **Live preview** — the right half of the picker shows the selected agent's screen,
  in color, as it is right now
- **Context at a glance** — conversation topic (from the pane title Claude Code sets),
  git branch of the pane's cwd, working directory; `◂` marks where you came from
- **Status-line summary** — `▲1 ✻2 ✔3 ○1` in `status-right`; the yellow `▲` tells you
  an agent is blocked on you without opening anything

## Hooks — accurate state + clickable notifications

Run once to wire every installed agent CLI:

```sh
scripts/install-hooks.sh
```

It registers one hook, `scripts/agent-hook.sh`, in whichever configs it finds (each is
backed up first; re-running is safe and idempotent):

| CLI | config it edits |
|---|---|
| Claude Code | `~/.claude/settings.json` |
| Codex | `~/.codex/hooks.json` |
| Kimi Code | `~/.kimi-code/config.toml` |

On each turn boundary the hook writes the agent's state to
`${XDG_CACHE_HOME:-~/.cache}/tmux-agent-view/<pane>.state`, which the picker reads instead
of scraping the screen. Stale files are garbage-collected when the picker runs (pane gone,
or older than a day). The event → state mapping is in the
[Agent states](#agent-states) table above.

**Codex only:** Codex requires you to *trust* hooks. The first time you start Codex
interactively after installing, it prompts once to trust `agent-hook.sh` — accept it.
Sessions already running when you install won't pick up the hooks until restarted.

**Clickable notifications (macOS):** when an agent needs input or finishes, the hook also
sends a desktop banner — **clicking it focuses your terminal and jumps straight to that
pane**, reusing the picker's jump logic. Banners are skipped when the pane is already on
screen in a focused client. Needs [terminal-notifier](https://github.com/julienXX/terminal-notifier)
(`brew install terminal-notifier`); silently skipped if absent.

## Requirements

- tmux ≥ 3.2 (popups) — 3.3+ recommended for rounded borders
- [fzf](https://github.com/junegunn/fzf)

## Install

With [TPM](https://github.com/tmux-plugins/tpm):

```tmux
set -g @plugin 'luopeixiang/tmux-agent-view'
```

Or manually — clone anywhere and add to `~/.tmux.conf`:

```tmux
run-shell /path/to/tmux-agent-view/agent-view.tmux
```

Reload tmux (`tmux source ~/.tmux.conf`), then press `prefix + a`.

## Options

Set in `~/.tmux.conf` before the plugin line:

| option | default | description |
|---|---|---|
| `@agent-view-key` | `a` | key after prefix that opens the picker |
| `@agent-view-status` | `on` | prepend the agent summary to `status-right` |
| `@agent-view-pattern` | `claude\|codex\|opencode\|aider\|kimi(-code)?([^-]\|$)` | regex matched against pane child processes |
| `@agent-view-width` | `90%` | popup width |
| `@agent-view-height` | `75%` | popup height |

Example:

```tmux
set -g @agent-view-key 'g'
set -g @agent-view-status 'off'
set -g @agent-view-pattern 'claude|goose'
```

## Keys inside the picker

| key | action |
|---|---|
| `enter` / mouse click | jump to the agent's window & pane |
| `ctrl-r` | refresh the list |
| `esc` | close |
| type anything | fuzzy-filter by session, topic, branch, path |

## How it works

1. `tmux list-panes -a` + one `ps` call; a pane is an agent pane if any process in its
   subtree matches the agent pattern (matched against the executable, so editing
   `CLAUDE.md` in nvim doesn't count).
2. State comes from the per-pane state file that agent CLIs write via
   [hooks](#hooks--accurate-state--clickable-notifications); with no state file it falls
   back to `tmux capture-pane` screen heuristics — see [Agent states](#agent-states) above.
3. Jumping is plain `switch-client` + `select-window` + `select-pane`.

With hooks installed, state is reported directly by Claude Code, Codex, and Kimi Code. The
screen-scrape fallback is tuned for Claude Code; unhooked agents of other kinds are still
detected and listed but may show as idle.

## License

MIT
