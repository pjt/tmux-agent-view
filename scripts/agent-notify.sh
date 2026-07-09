#!/usr/bin/env bash
# tmux-agent-view — Claude Code hook: clickable macOS banner when an agent
# finishes (Stop) or needs input/permission (Notification). Clicking the
# banner focuses the terminal app and jumps to the agent's tmux pane via
# agent-view.sh jump.
#
# Register in ~/.claude/settings.json under "Stop" and "Notification":
#   { "type": "command", "command": "<repo>/scripts/agent-notify.sh" }
#
# Needs: terminal-notifier (brew install terminal-notifier). Reads the hook
# event JSON on stdin; exits silently when not inside tmux.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"

pane="${TMUX_PANE:-}"
[ -n "$pane" ] || exit 0
command -v terminal-notifier >/dev/null 2>&1 || exit 0
TMUX_BIN="$(command -v tmux)" || exit 0

payload="$(cat 2>/dev/null || true)"
field() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
  else
    printf '%s' "$payload" |
      sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
  fi
}
event="$(field hook_event_name)"
message="$(field message)"

info="$("$TMUX_BIN" display-message -p -t "$pane" \
  '#{session_name}	#{window_index}	#{window_name}	#{&&:#{pane_active},#{window_active}}' \
  2>/dev/null)" || exit 0
[ -n "$info" ] || exit 0
IFS='	' read -r session win_idx win_name visible <<EOF
$info
EOF

# The user is already looking at this pane — no banner needed.
if [ "$visible" = "1" ]; then
  "$TMUX_BIN" list-clients -F '#{?#{m:*focused*,#{client_flags}},#{client_session},}' 2>/dev/null |
    grep -qFx "$session" && exit 0
fi

case "$event" in
  Stop)         title='✔ 任务完成'; body="${message:-Claude 已完成任务}" ;;
  Notification) title='▲ 等待输入'; body="${message:-Claude 需要你的确认}" ;;
  *)            title='✻ Claude';   body="${message:-$event}" ;;
esac
title="$title · $session:$win_idx $win_name"

# Terminal app to focus on click: walk the attached client's process
# ancestry up to the owning .app bundle.
app=''
pid="$("$TMUX_BIN" list-clients -F '#{client_pid}' 2>/dev/null | head -n 1)"
while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
  case "$(ps -o comm= -p "$pid" 2>/dev/null)" in
    *.app/Contents/MacOS/*)
      app="$(ps -o comm= -p "$pid")"
      app="${app%%.app/Contents/MacOS/*}.app"
      break ;;
  esac
  pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
done

exec_cmd="PATH=\"$(dirname "$TMUX_BIN"):\$PATH\"; '$DIR/agent-view.sh' jump '$pane'"
[ -n "$app" ] && exec_cmd="open '$app'; $exec_cmd"

terminal-notifier \
  -title "$title" \
  -message "$body" \
  -group "agent-view-$pane" \
  -sound default \
  -execute "$exec_cmd" >/dev/null 2>&1 &

exit 0
