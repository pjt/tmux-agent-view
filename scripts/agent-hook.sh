#!/usr/bin/env bash
# tmux-agent-view — unified agent hook.
#
# Registered as a lifecycle hook in Claude Code / Codex / Kimi Code / Pi. On each
# event it (1) writes the agent's current state to a per-pane state file that
# agent-view.sh reads instead of scraping the screen, and (2) on the events
# that need you (input/done/failed/stopped) sends a clickable macOS banner that
# jumps to the pane.
#
# Usage (registered by install-hooks.sh):
#   agent-hook.sh <kind>        # kind = claude | codex | kimi | pi
# Reads the hook event JSON on stdin. Exits silently when not inside tmux.
#
# State file: $XDG_CACHE_HOME/tmux-agent-view/<pane_id>.state  (default ~/.cache)
#   one line, tab-separated:  status <TAB> kind <TAB> session_id
# The file's mtime is the timestamp; agent-view.sh garbage-collects orphans.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
KIND="${1:-agent}"

pane="${TMUX_PANE:-}"
[ -n "$pane" ] || exit 0   # not inside tmux — nothing to attribute state to

STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tmux-agent-view"
statefile="$STATE_DIR/${pane}.state"

payload="$(cat 2>/dev/null || true)"
field() { # <json_key> -> value ("" if absent)
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
  else
    printf '%s' "$payload" |
      sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
  fi
}
event="$(field hook_event_name)"
session_id="$(field session_id)"
message="$(field message)"

# ---------------------------------------------------------------- event → state
# Mostly turn-boundary events, so states arrive in order without thrashing the
# file. The one exception is PreToolUse: Claude Code has no hook that fires when
# a permission/question prompt is answered and work resumes (answering isn't a
# UserPromptSubmit — it's a tool response, not a new user message), so the pane
# would otherwise stay stuck on needs_input until the whole turn ends at Stop.
# The next tool call is the earliest reliable signal that work has resumed.
# Unmapped events are ignored.
status=''
case "$event" in
  UserPromptSubmit|PreToolUse)  status='working' ;;
  Notification|PermissionRequest) status='needs_input' ;;
  Stop)                        status='completed' ;;
  StopFailure)                 status='failed' ;;      # Kimi / Pi adapter
  Interrupt)                   status='stopped' ;;     # Kimi / Pi adapter
  SessionStart)                status='idle' ;;
  SessionEnd)                  rm -f "$statefile" 2>/dev/null; exit 0 ;;
  *)                           exit 0 ;;
esac

# Atomic write (tmp + rename) so a concurrent reader never sees a half line.
mkdir -p "$STATE_DIR" 2>/dev/null
tmp="$statefile.$$"
printf '%s\t%s\t%s\n' "$status" "$KIND" "$session_id" > "$tmp" 2>/dev/null &&
  mv -f "$tmp" "$statefile" 2>/dev/null

# ---------------------------------------------------------------- notification
# Only the states that need your attention get a banner; working/idle stay quiet.
case "$status" in
  needs_input|completed|failed|stopped) ;;
  *) exit 0 ;;
esac
command -v terminal-notifier >/dev/null 2>&1 || exit 0
TMUX_BIN="$(command -v tmux)" || exit 0

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

# Capitalize the agent kind for the banner (claude -> Claude).
kind_label="$(printf '%s' "$KIND" | cut -c1 | tr '[:lower:]' '[:upper:]')${KIND:1}"

case "$status" in
  needs_input) title='▲ 等待输入'; body="${message:-$kind_label 需要你的确认}" ;;
  completed)   title='✔ 任务完成'; body="${message:-$kind_label 已完成任务}" ;;
  failed)      title='✖ 任务失败'; body="${message:-$kind_label 回合出错}" ;;
  stopped)     title='■ 已中断';   body="${message:-$kind_label 被中断}" ;;
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
