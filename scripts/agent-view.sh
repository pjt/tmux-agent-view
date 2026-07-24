#!/usr/bin/env bash
# tmux-agent-view — list AI agent panes across all tmux sessions and jump to them.
# bash 3.2 compatible (macOS system bash). Pane status comes from hook-written
# state files (see agent-hook.sh); no screen scraping.

set -u
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# The Kimi Code CLI runs as argv0 "kimi" (older sessions) or "kimi-code"
# (newer ones). `kimi(-code)?([^-]|$)` matches both while excluding the
# kimi-webbridge daemon that shares the "kimi" prefix.
DEFAULT_PATTERN='claude|codex|opencode|aider|kimi(-code)?([^-]|$)'

# Per-pane state written by agent-hook.sh (hook-driven), the sole source of
# each pane's status. Kept in sync with agent-hook.sh's STATE_DIR.
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tmux-agent-view"

opt() { # opt <@option> <default>
  local v
  v="$(tmux show-option -gqv "$1" 2>/dev/null)"
  printf '%s' "${v:-$2}"
}

# ---------------------------------------------------------------- detection

# Drop stale state files: those untouched for over a day, and those whose pane
# no longer exists (covers closed panes, agent exits without a SessionEnd hook,
# and pane-id reuse after a tmux server restart).
gc_state() {
  [ -d "$STATE_DIR" ] || return 0
  find "$STATE_DIR" -name '*.state' -mtime +1 -delete 2>/dev/null
  local live f pid
  live="$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null)"
  [ -n "$live" ] || return 0
  for f in "$STATE_DIR"/*.state; do
    [ -e "$f" ] || continue
    pid="$(basename "$f")"; pid="${pid%.state}"
    case "
$live
" in
      *"
$pid
"*) ;;                        # pane still alive
      *)  rm -f "$f" 2>/dev/null ;;  # orphan
    esac
  done
}

# Emit one line per agent pane:
#   pane_id \t rank \t status \t session \t win_idx \t win_name \t title \t path
#   \t session_last_attached \t window_stack_index
# Within a state group, order is LRU by user visits: sessions by most recent
# attach/switch, windows by the session's window stack (0 = most recently
# visited). Both are driven only by user navigation, never by agent output.
scan() {
  local pattern
  pattern="$(opt @agent-view-pattern "$DEFAULT_PATTERN")"
  gc_state

  tmux list-panes -a \
    -F '#{pane_id}	#{pane_pid}	#{session_name}	#{window_index}	#{window_name}	#{pane_title}	#{pane_current_path}	#{session_last_attached}	#{window_stack_index}' |
  awk -v pat="$pattern" '
    BEGIN {
      FS = OFS = "\t"
      # one ps call: build pid -> ppid and pid -> command maps
      cmd = "ps -axo pid=,ppid=,command="
      while ((cmd | getline line) > 0) {
        sub(/^[ \t]+/, "", line)
        split(line, f, /[ \t]+/)
        pid = f[1]; par = f[2]
        ppid[pid] = par
        kids[par] = kids[par] " " pid
        # keep only the first two tokens (executable + first arg) for matching,
        # so `nvim CLAUDE.md` does not false-positive but
        # `node /x/claude/cli.js` and `/x/claude/versions/2.1.198 --flag` do.
        head = f[3] (f[4] != "" ? " " f[4] : "")
        exe[pid] = head
      }
      close(cmd)
    }
    {
      # BFS the pane pid subtree looking for an agent process
      n = 1; queue[1] = $2; found = 0
      for (i = 1; i <= n && !found; i++) {
        p = queue[i]
        if (i > 1 && tolower(exe[p]) ~ tolower(pat)) { found = 1; break }
        m = split(kids[p], ch, " ")
        for (j = 1; j <= m; j++) if (ch[j] != "") queue[++n] = ch[j]
        if (n > 512) break
      }
      if (found) print $1, $3, $4, $5, $6, $7, $8, $9
      delete queue
    }
  ' |
  while IFS='	' read -r pane_id session win_idx win_name title path attached stack; do
    local status rank
    status="$(pane_status "$pane_id")"
    case "$status" in
      needs_input) rank=0 ;;
      failed)      rank=1 ;;
      stopped)     rank=2 ;;
      working)     rank=3 ;;
      completed)   rank=4 ;;
      *)           rank=5 ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$pane_id" "$rank" "$status" "$session" "$win_idx" "$win_name" "$title" "$path" \
      "$attached" "$stack"
  done | sort -t '	' -k2,2n -k9,9nr -k10,10n -k5,5n
}

# State is hook-driven: agent-hook.sh writes a per-pane state file on each
# lifecycle event. A pane with no state file yet — an agent started before the
# hooks were installed, or a CLI without hook support — reads as idle.
pane_status() { # <pane_id> -> needs_input|failed|stopped|working|completed|idle
  local sf="$STATE_DIR/$1.state" st
  if [ -f "$sf" ]; then
    IFS='	' read -r st _ < "$sf" 2>/dev/null
    if [ -n "${st:-}" ]; then printf '%s\n' "$st"; return; fi
  fi
  printf 'idle\n'
}

# ---------------------------------------------------------------- rendering

# Display width: non-ASCII counts as 2 columns, except common narrow
# punctuation/symbols (…·—–‘’“”) which render 1 column wide.
dwidth() {
  local wide="${1//[[:ascii:]]/}"
  wide="${wide//[…·—–‘’“”]/}"
  printf '%s' "$(( ${#1} + ${#wide} ))"
}

# Truncate to <width> display columns (… suffix) and pad with spaces.
fit() { # <str> <width>
  local s="$1" max="$2" w
  w="$(dwidth "$s")"
  if [ "$w" -gt "$max" ]; then
    while s="${s%?}"; [ "$(dwidth "$s")" -gt "$((max - 1))" ]; do :; done
    s="${s}…"
    w="$(dwidth "$s")"
  fi
  printf '%s%*s' "$s" "$((max - w))" ''
}

style() { # <status> -> "icon<TAB>label<TAB>ansi color"
  case "$1" in
    needs_input) printf '▲\tneeds input\t\033[1;33m' ;;
    failed)      printf '✖\tfailed\t\033[1;31m' ;;
    stopped)     printf '■\tstopped\t\033[1;35m' ;;
    working)     printf '✻\tworking\t\033[1;36m' ;;
    completed)   printf '✔\tcompleted\t\033[1;32m' ;;
    *)           printf '○\tidle\t\033[2m' ;;
  esac
}

# Colored fzf lines: "pane_id \t <display>", grouped under one header per state.
# Header lines have an empty pane_id field; picker() skips them on enter.
# AGENT_JUMP_CURRENT (optional) marks the pane the popup was opened from.
list() {
  local prev_status='' host hshort
  host="$(hostname 2>/dev/null)"   # e.g. PeixiangdeMacBook-Pro.local
  hshort="${host%%.*}"             # e.g. PeixiangdeMacBook-Pro
  scan | while IFS='	' read -r pane_id rank status session win_idx win_name title path attached stack; do
    local icon label color branch here
    IFS='	' read -r icon label color <<EOF
$(style "$status")
EOF

    if [ "$status" != "$prev_status" ]; then
      [ -n "$prev_status" ] && printf '\t\n'
      printf '\t%b%s %s\033[0m\n' "$color" "$icon" "$label"
      prev_status="$status"
    fi

    # Claude Code sets pane_title to the conversation topic; a plain shell
    # leaves the OS default — "user@host: path" or a bare hostname — which
    # tells us nothing. Fall back to the window name in those cases.
    case "$title" in
      *@*:* | "$host" | "$hshort") title="$win_name" ;;
    esac

    branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    here='  '; [ "$pane_id" = "${AGENT_JUMP_CURRENT:-}" ] && here='◂ '

    printf '%s\t%s%b%s\033[0m  \033[1m%s\033[0m  %s  \033[2m%s%s\033[0m\n' \
      "$pane_id" "$here" "$color" "$icon" \
      "$(fit "$session:$win_idx" 14)" "$(fit "$title" 34)" \
      "${branch:+⎇ $branch · }" "${path/#"$HOME"/\~}"
  done
}

counts() { # -> "needs_input failed stopped working completed idle"
  scan | awk -F '\t' '{ c[$3]++ }
    END { printf "%d %d %d %d %d %d\n",
          c["needs_input"], c["failed"], c["stopped"],
          c["working"], c["completed"], c["idle"] }'
}

# status-right segment (tmux format markup)
status_line() {
  local n f s w c i out=''
  read -r n f s w c i <<EOF
$(counts)
EOF
  [ "$((n + f + s + w + c + i))" -eq 0 ] && return 0
  [ "$n" -gt 0 ] && out="$out#[fg=yellow,bold]▲$n#[default] "
  [ "$f" -gt 0 ] && out="$out#[fg=red,bold]✖$f#[default] "
  [ "$s" -gt 0 ] && out="$out#[fg=magenta]■$s#[default] "
  [ "$w" -gt 0 ] && out="$out#[fg=cyan]✻$w#[default] "
  [ "$c" -gt 0 ] && out="$out#[fg=green]✔$c#[default] "
  [ "$i" -gt 0 ] && out="$out#[fg=colour244]○$i#[default] "
  printf '%s' "${out% }"
}

# ---------------------------------------------------------------- picker

picker() {
  local lines sel pane_id
  if ! command -v fzf >/dev/null 2>&1; then
    printf '\n   tmux-agent-view needs fzf:  brew install fzf\n\n   press any key to close'
    read -rsn1
    return 0
  fi

  while :; do
    lines="$(list)"

    if [ -z "$lines" ]; then
      printf '\n   No agent panes found.\n\n   (pattern: %s)\n\n   press any key to close' \
        "$(opt @agent-view-pattern "$DEFAULT_PATTERN")"
      read -rsn1
      return 0
    fi

    sel="$(printf '%s\n' "$lines" | fzf \
      --ansi --reverse --no-info --cycle \
      --delimiter='\t' --with-nth=2.. \
      --prompt='  ' --pointer='▌' \
      --header='enter jump · ctrl-r refresh · esc close' \
      --header-first \
      --color='header:dim,pointer:cyan,hl:cyan,hl+:cyan,bg+:236,gutter:-1,border:240' \
      --preview="tmux capture-pane -ep -t {1}" \
      --preview-window='right,55%,border-left' \
      --bind="ctrl-r:reload('$SELF' list)")" || return 0

    pane_id="${sel%%	*}"
    if [ -n "$pane_id" ]; then
      jump "$pane_id"
      return 0
    fi
    # a group header / separator was selected — reopen the picker
  done
}

jump() { # <pane_id>
  local target session win_idx
  target="$(tmux display-message -p -t "$1" '#{session_name}:#{window_index}' 2>/dev/null)" || return 0
  session="${target%%:*}"
  win_idx="${target##*:}"
  tmux select-pane -t "$1" 2>/dev/null
  tmux select-window -t "$session:$win_idx" 2>/dev/null
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "$session" 2>/dev/null
  else
    # called from outside tmux (e.g. a notification click): no current
    # client, so retarget every attached client explicitly
    tmux list-clients -F '#{client_name}' 2>/dev/null |
    while IFS= read -r client; do
      tmux switch-client -c "$client" -t "$session" 2>/dev/null
    done
  fi
}

popup() {
  local w h cur
  w="$(opt @agent-view-width 90%)"
  h="$(opt @agent-view-height 75%)"
  # run-shell context: resolves to the pane the keybinding was pressed in
  cur="$(tmux display-message -p '#{pane_id}' 2>/dev/null)"
  tmux display-popup -E -b rounded -S 'fg=colour240' -T ' ✻ agents ' \
    -w "$w" -h "$h" "AGENT_JUMP_CURRENT='$cur' '$SELF' picker"
}

# ---------------------------------------------------------------- main

case "${1:-popup}" in
  scan)   scan ;;
  list)   list ;;
  counts) counts ;;
  status) status_line ;;
  picker) picker ;;
  jump)   jump "${2:?pane_id required}" ;;
  popup)  popup ;;
  *)      echo "usage: agent-view.sh [popup|picker|list|counts|status|jump <pane_id>]" >&2; exit 1 ;;
esac
