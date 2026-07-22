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

- **No hooks, no daemon, no binary, no state.** A single bash script scans panes
  on demand — the picker is always live, and there is nothing to set up or go stale.
- **Zero screen cost.** Nothing is docked; your layout is yours.
- **macOS system bash is enough** (bash 3.2 compatible).

## Agent states

Six states, mirroring [Claude Code's agent view](https://code.claude.com/docs/en/agent-view),
detected purely from each pane's screen content — no hooks needed. The picker groups
agents by state; states that need you sort first. Within a group, agents are ordered
by your most recent visits (LRU): tmux's session attach times and per-session window
stacks, both driven only by your navigation — an agent spamming output never jumps
the queue.

| state | meaning | detected by |
|---|---|---|
| `▲ needs input` | waiting on a permission decision or a question | `Do you want …` / `Would you like …` / a numbered `❯ 1.` choice |
| `✖ failed` | turn ended with an API/tool error | `API Error`, rate limit / timeout / auth messages |
| `■ stopped` | you interrupted it (esc / ctrl-c) | `Interrupted` marker |
| `✻ working` | generating or running tools | spinner line `✻ Doing… (…)` / `esc to interrupt` |
| `✔ completed` | last turn finished normally | turn summary `✻ Worked for 1m 5s` / `※ recap:` line |
| `○ idle` | sitting at the prompt | none of the above |

The marker closest to the bottom of the screen wins, so a permission dialog below a
spinner reads as *needs input*, and a fresh spinner below an old turn summary reads
as *working*.

## Features

- **All sessions, one picker** — every pane running Claude Code / Codex / OpenCode /
  aider / Kimi Code, grouped by state, agents that need you first
- **Live preview** — the right half of the picker shows the selected agent's screen,
  in color, as it is right now
- **Context at a glance** — conversation topic (from the pane title Claude Code sets),
  git branch of the pane's cwd, working directory; `◂` marks where you came from
- **Status-line summary** — `▲1 ✻2 ✔3 ○1` in `status-right`; the yellow `▲` tells you
  an agent is blocked on you without opening anything

## Clickable notifications (optional, macOS)

`scripts/agent-notify.sh` is an optional Claude Code hook: when an agent finishes
(`Stop`) or needs your input (`Notification`), it sends a desktop banner —
**clicking the banner focuses your terminal and jumps straight to that agent's
pane**, reusing the same jump logic as the picker. Banners are skipped when the
pane is already on screen in a focused client.

Needs [terminal-notifier](https://github.com/julienXX/terminal-notifier)
(`brew install terminal-notifier`). Register in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "/path/to/tmux-agent-view/scripts/agent-notify.sh", "async": true }] }],
    "Notification": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "/path/to/tmux-agent-view/scripts/agent-notify.sh", "async": true }] }]
  }
}
```

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
2. State comes from `tmux capture-pane` screen heuristics — see
   [Agent states](#agent-states) above.
3. Jumping is plain `switch-client` + `select-window` + `select-pane`.

State heuristics are tuned for Claude Code; other agents are detected and listed but
may always show as idle.

## License

MIT
