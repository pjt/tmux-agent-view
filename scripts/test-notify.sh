#!/bin/bash
# Regression probe for agent-notify.sh's "is the user actually looking at this
# pane?" logic. Drives real focus changes and inspects Notification Center, so
# it needs a live tmux server and a GUI session.
#
#   bash scripts/test-notify.sh
#
# Absolute paths throughout: the hook runs in whatever environment Claude Code
# hands it, and a stray PATH must not silently turn a probe green.
set -u

TMUX_BIN=/opt/homebrew/bin/tmux   # NB: never name this $TMUX — tmux reads it as a socket path
TN=/opt/homebrew/bin/terminal-notifier
OSA=/usr/bin/osascript
PY=/usr/bin/python3

HOOK="$(cd "$(dirname "$0")" && pwd)/agent-notify.sh"
TERM_APP=Ghostty
pass=0 fail=0

nap()   { "$PY" -c "import time;time.sleep($1)"; }
focus() { "$OSA" -e "tell application \"$1\" to activate" >/dev/null 2>&1; nap 1.2; }
vis()   { "$TMUX_BIN" display-message -p -t "$1" '#{&&:#{pane_active},#{window_active}}'; }

# Fire the hook for a pane, then ask Notification Center whether it landed.
probe() { # $1=pane $2=expect(fire|skip) $3=description
  local g="agent-view-$1" got
  "$TN" -remove "$g" >/dev/null 2>&1; nap 0.5
  echo '{"hook_event_name":"Stop","message":"test-notify"}' | TMUX_PANE="$1" /bin/bash "$HOOK"
  nap 1.5
  if "$TN" -list "$g" 2>/dev/null | /usr/bin/grep -q "^$g"; then got=fire; else got=skip; fi
  "$TN" -remove "$g" >/dev/null 2>&1
  if [ "$got" = "$2" ]; then
    pass=$((pass + 1)); printf '  ✅ %-38s (expect=%s got=%s)\n' "$3" "$2" "$got"
  else
    fail=$((fail + 1)); printf '  ❌ %-38s (expect=%s got=%s)\n' "$3" "$2" "$got"
  fi
}

focus "$TERM_APP"
sess="$("$TMUX_BIN" display-message -p '#{session_name}')"
cur="$("$TMUX_BIN" display-message -p -t "$sess" '#{pane_id}')"

# A pane in the same session that is NOT the one on screen.
other=''
for p in $("$TMUX_BIN" list-panes -s -t "$sess" -F '#{pane_id}'); do
  [ "$p" != "$cur" ] && [ "$(vis "$p")" = "0" ] && { other="$p"; break; }
done

"$TMUX_BIN" kill-session -t nt-test 2>/dev/null
"$TMUX_BIN" new-session -d -s nt-test
bg="$("$TMUX_BIN" list-panes -t nt-test -F '#{pane_id}' | head -1)"

echo "session=$sess  on-screen=$cur  off-screen=${other:-<none>}  detached=$bg"
echo

echo "$TERM_APP frontmost:"
probe "$cur" skip "on-screen pane — user is watching"
[ -n "$other" ] && probe "$other" fire "off-screen pane in same session"
probe "$bg"  fire "pane in detached session"

echo
echo "Finder frontmost (terminal lost focus):"
focus Finder
probe "$cur" fire "on-screen pane — user walked away"
focus "$TERM_APP"

"$TMUX_BIN" kill-session -t nt-test 2>/dev/null
echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
