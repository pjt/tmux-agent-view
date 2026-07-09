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

# Owning .app bundle of a tmux client, found by walking its process ancestry.
term_app() {
  pid="${1:-}"
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    case "$(ps -o comm= -p "$pid" 2>/dev/null)" in
      *.app/Contents/MacOS/*)
        app="$(ps -o comm= -p "$pid")"
        printf '%s.app\n' "${app%%.app/Contents/MacOS/*}"
        return 0 ;;
    esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  done
  return 1
}

# Bundle path of whatever app is frontmost on the Mac right now.
frontmost_app() {
  asn="$(lsappinfo front 2>/dev/null)"
  [ -n "$asn" ] || return 1
  lsappinfo info -only bundlepath "$asn" 2>/dev/null |
    sed -n 's/.*"LSBundlePath"="\(.*\)".*/\1/p'
}

# Prefer a client watching this very session; fall back to any client so a
# click can still raise the terminal for a session nobody has attached.
client_pid="$("$TMUX_BIN" list-clients -t "$session" -F '#{client_pid}' 2>/dev/null | head -n 1)"
app="$(term_app "${client_pid:-$("$TMUX_BIN" list-clients -F '#{client_pid}' 2>/dev/null | head -n 1)}")" || app=''

# Skip the banner only when the user is genuinely looking at this pane: it is
# the active pane of an attached session *and* that terminal is frontmost.
# tmux's own focused flag is useless here — it is hardwired on unless the
# focus-events option is set, which it is not by default.
if [ "$visible" = "1" ] && [ -n "$client_pid" ] && [ -n "$app" ]; then
  [ "$(frontmost_app)" = "$app" ] && exit 0
fi

case "$event" in
  Stop)         title='✔ 任务完成'; body="${message:-Claude 已完成任务}" ;;
  Notification) title='▲ 等待输入'; body="${message:-Claude 需要你的确认}" ;;
  *)            title='✻ Claude';   body="${message:-$event}" ;;
esac
title="$title · $session:$win_idx $win_name"

exec_cmd="PATH=\"$(dirname "$TMUX_BIN"):\$PATH\"; '$DIR/agent-view.sh' jump '$pane'"
[ -n "$app" ] && exec_cmd="open '$app'; $exec_cmd"

terminal-notifier \
  -title "$title" \
  -message "$body" \
  -group "agent-view-$pane" \
  -sound default \
  -execute "$exec_cmd" >/dev/null 2>&1 &

exit 0
