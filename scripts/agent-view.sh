#!/usr/bin/env bash
# tmux-agent-view — list AI agent panes across all tmux sessions and jump to them.
# bash 3.2 compatible (macOS system bash). Pane status comes from hook-written
# state files (see agent-hook.sh); no screen scraping.

set -u
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# The Kimi Code CLI runs as argv0 "kimi" (older sessions) or "kimi-code"
# (newer ones). `kimi(-code)?([^-]|$)` matches both while excluding the
# kimi-webbridge daemon that shares the "kimi" prefix.
# Pi normally appears as `node .../pi-coding-agent/dist/cli.js`; `(^|/)pi$`
# covers launchers that preserve `pi` as argv0. scan() applies the pattern to
# argv0 separately so the anchored alternative cannot match an unrelated arg.
DEFAULT_PATTERN='claude|codex|opencode|aider|kimi(-code)?([^-]|$)|pi-coding-agent|(^|/)pi$'

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
        arg0[pid] = f[3]
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
        if (i > 1 && (tolower(exe[p]) ~ tolower(pat) ||
                      tolower(arg0[p]) ~ tolower(pat))) { found = 1; break }
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
    pane_status "$pane_id"
    status="$PANE_STATUS_RESULT"
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
pane_status() { # <pane_id> -> sets PANE_STATUS_RESULT
  local sf="$STATE_DIR/$1.state" st
  if [ -f "$sf" ]; then
    IFS='	' read -r st _ < "$sf" 2>/dev/null
    if [ -n "${st:-}" ]; then
      # A pane that completed long ago is no longer interesting: age it down to
      # idle so it sinks below active agents. TTL in seconds (0 disables).
      # Only `completed` ages — `working`/`needs_input` have no safe timeout
      # (a long turn or an unanswered prompt is legitimately old).
      if [ "$st" = "completed" ]; then
        local ttl mt now
        ttl="$(opt @agent-view-completed-ttl 1800)"
        if [ "${ttl:-0}" -gt 0 ] 2>/dev/null; then
          # GNU stat (-c %Y) first, BSD/macOS stat (-f %m) as fallback. The
          # reverse order breaks on GNU/Linux: `stat -f %m` there means
          # "filesystem status", which prints fs info to stdout AND exits 1, so
          # the `||` fallback appends the real mtime to that text. `$((now-mt))`
          # then parses the word "File" as a variable and, under `set -u`,
          # aborts the whole scan whenever any completed state file exists.
          mt="$(stat -c %Y "$sf" 2>/dev/null || stat -f %m "$sf" 2>/dev/null)"
          now="$(date +%s 2>/dev/null)"
          [ -n "$mt" ] && [ -n "$now" ] && [ "$((now - mt))" -ge "$ttl" ] && st='idle'
        fi
      fi
      PANE_STATUS_RESULT="$st"
      return 0
    fi
  fi
  PANE_STATUS_RESULT='idle'
}

# ---------------------------------------------------------------- rendering

# Display width: non-ASCII counts as 2 columns, except common narrow
# punctuation/symbols (…·—–‘’“”) which render 1 column wide.
dwidth() { # <str> -> sets DWIDTH_RESULT
  local wide="${1//[[:ascii:]]/}"
  wide="${wide//[…·—–‘’“”]/}"
  DWIDTH_RESULT="$(( ${#1} + ${#wide} ))"
}

# Truncate to <width> display columns (… suffix), pad, and set FIT_RESULT.
fit() { # <str> <width> -> sets FIT_RESULT
  local s="$1" max="$2" w
  dwidth "$s"
  w="$DWIDTH_RESULT"
  if [ "$w" -gt "$max" ]; then
    while s="${s%?}"; do
      dwidth "$s"
      [ "$DWIDTH_RESULT" -le "$((max - 1))" ] && break
    done
    s="${s}…"
    dwidth "$s"
    w="$DWIDTH_RESULT"
  fi
  printf -v FIT_RESULT '%s%*s' "$s" "$((max - w))" ''
}

style() { # <status> -> sets STYLE_ICON, STYLE_LABEL, and STYLE_COLOR
  case "$1" in
    needs_input) STYLE_ICON='▲'; STYLE_LABEL='needs input'; STYLE_COLOR=$'\033[1;33m' ;;
    failed)      STYLE_ICON='✖'; STYLE_LABEL='failed';      STYLE_COLOR=$'\033[1;31m' ;;
    stopped)     STYLE_ICON='■'; STYLE_LABEL='stopped';     STYLE_COLOR=$'\033[1;35m' ;;
    working)     STYLE_ICON='✻'; STYLE_LABEL='working';     STYLE_COLOR=$'\033[1;36m' ;;
    completed)   STYLE_ICON='✔'; STYLE_LABEL='completed';   STYLE_COLOR=$'\033[1;32m' ;;
    *)           STYLE_ICON='○'; STYLE_LABEL='idle';        STYLE_COLOR=$'\033[2m' ;;
  esac
}

# Read the current branch from Git's HEAD metadata instead of spawning git for
# every pane. Linked worktrees expose their private gitdir through a .git file,
# so handle both directory and file forms. The tiny indexed-array cache (Bash
# 3.2 has no associative arrays) avoids repeating even that directory walk.
branch_for_path() { # <path> -> sets BRANCH_RESULT
  local path="$1" i=0 dir gitdir='' head
  while [ "$i" -lt "${#BRANCH_PATHS[@]}" ]; do
    if [ "${BRANCH_PATHS[$i]}" = "$path" ]; then
      BRANCH_RESULT="${BRANCH_NAMES[$i]}"
      return 0
    fi
    i=$((i + 1))
  done

  BRANCH_RESULT=''
  dir="$path"
  while [ -n "$dir" ]; do
    if [ -d "$dir/.git" ]; then
      gitdir="$dir/.git"
      break
    fi
    if [ -f "$dir/.git" ]; then
      IFS= read -r gitdir < "$dir/.git" 2>/dev/null || gitdir=''
      case "$gitdir" in
        'gitdir: '*) gitdir="${gitdir#gitdir: }" ;;
        *) gitdir='' ;;
      esac
      case "$gitdir" in
        /* | '') ;;
        *) gitdir="$dir/$gitdir" ;;
      esac
      break
    fi
    [ "$dir" = '/' ] && break
    dir="${dir%/*}"
    [ -n "$dir" ] || dir='/'
  done

  if [ -n "$gitdir" ] && IFS= read -r head < "$gitdir/HEAD" 2>/dev/null; then
    case "$head" in
      'ref: refs/heads/'*) BRANCH_RESULT="${head#ref: refs/heads/}" ;;
      ?*)                  BRANCH_RESULT='HEAD' ;;
    esac
  fi
  BRANCH_PATHS[${#BRANCH_PATHS[@]}]="$path"
  BRANCH_NAMES[${#BRANCH_NAMES[@]}]="$BRANCH_RESULT"
}

# Claude Code sets pane_title to the conversation topic; a plain shell leaves
# the OS default — "user@host: path" or a bare hostname — which tells us
# nothing. The window name is shown alongside it, so just blank a generic
# title rather than duplicating the window name into it. -> sets CLEAN_TITLE
clean_title() { # <title> <host> <hshort>
  case "$1" in
    *@*:* | "$2" | "$3") CLEAN_TITLE='' ;;
    *)                   CLEAN_TITLE="$1" ;;
  esac
}

# Render scan rows as colored fzf lines: "pane_id \t <display>", exactly one
# line per agent pane. State is shown inline as a fixed-width label column
# (rather than as group headers) so every fzf line is a selectable agent — this
# makes the picker's up/down move agent-to-agent instead of stepping onto
# headers/blank separators. Rows stay grouped visually via the rank sort in
# scan(). AGENT_JUMP_CURRENT marks the pane the popup was opened from.
#
# session/window-name/title column widths are sized to content, not guessed:
# pass 1 measures each column's widest value across every row, capped per
# column so one long outlier can't dominate the layout. session and window
# name then always get their full (capped) width — they're short, structured
# identifiers, not worth truncating over. title is the free-text column, so
# it absorbs whatever's left of @agent-view-columns-pct of the popup's width,
# down to a floor of 10 and up to its own cap, and truncates with an ellipsis
# via fit() when content doesn't fit. Pass 2 renders using the widths pass 1
# settled on. Buffering the whole input first (rather than streaming
# row-by-row) is what makes measuring content ahead of render possible;
# picker() already buffers scan()'s output for the same reason.
render_list() {
  local host hshort buf pane_id rank status session win_idx win_name title path attached stack
  local session_w=0 winname_w=0 title_w=0
  local session_cap=20 winname_cap=28 title_cap=60
  local popup_cols budget title_budget
  BRANCH_PATHS=()
  BRANCH_NAMES=()
  host="$(hostname 2>/dev/null)"   # e.g. PeixiangdeMacBook-Pro.local
  hshort="${host%%.*}"             # e.g. PeixiangdeMacBook-Pro

  buf="$(cat)"
  [ -z "$buf" ] && return 0

  while IFS='	' read -r pane_id rank status session win_idx win_name title path attached stack; do
    clean_title "$title" "$host" "$hshort"
    dwidth "$session:$win_idx";  [ "$DWIDTH_RESULT" -gt "$session_w" ] && session_w="$DWIDTH_RESULT"
    dwidth "$win_name";          [ "$DWIDTH_RESULT" -gt "$winname_w" ] && winname_w="$DWIDTH_RESULT"
    dwidth "$CLEAN_TITLE";       [ "$DWIDTH_RESULT" -gt "$title_w" ]   && title_w="$DWIDTH_RESULT"
  done <<<"$buf"
  [ "$session_w" -gt "$session_cap" ] && session_w="$session_cap"
  [ "$winname_w" -gt "$winname_cap" ] && winname_w="$winname_cap"
  [ "$title_w" -gt "$title_cap" ] && title_w="$title_cap"

  popup_cols="$(tput cols 2>/dev/null)"; popup_cols="${popup_cols:-100}"
  budget=$(( popup_cols * $(opt @agent-view-columns-pct 60) / 100 ))
  title_budget=$(( budget - session_w - winname_w ))
  [ "$title_budget" -lt 10 ] && title_budget=10
  [ "$title_w" -gt "$title_budget" ] && title_w="$title_budget"

  while IFS='	' read -r pane_id rank status session win_idx win_name title path attached stack; do
    local icon label color branch here session_col winname_col title_col label_col
    style "$status"
    icon="$STYLE_ICON"
    label="$STYLE_LABEL"
    color="$STYLE_COLOR"

    clean_title "$title" "$host" "$hshort"
    title="$CLEAN_TITLE"

    branch_for_path "$path"
    branch="$BRANCH_RESULT"
    here='  '; [ "$pane_id" = "${AGENT_JUMP_CURRENT:-}" ] && here='◂ '
    # Widest label is "needs input" (11); pad so the following columns align.
    printf -v label_col '%-11s' "$label"
    fit "$session:$win_idx" "$session_w"
    session_col="$FIT_RESULT"
    fit "$win_name" "$winname_w"
    winname_col="$FIT_RESULT"
    fit "$title" "$title_w"
    title_col="$FIT_RESULT"

    printf '%s\t%s%b%s %s\033[0m  \033[1m%s\033[0m  %s  %s  \033[2m%s%s\033[0m\n' \
      "$pane_id" "$here" "$color" "$icon" "$label_col" \
      "$session_col" "$winname_col" "$title_col" \
      "${branch:+⎇ $branch · }" "${path/#"$HOME"/\~}"
  done <<<"$buf"
}

list() {
  scan | render_list
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
  local rows sel pane_id
  if ! command -v fzf >/dev/null 2>&1; then
    printf '\n   tmux-agent-view needs fzf:  brew install fzf\n\n   press any key to close'
    read -rsn1
    return 0
  fi

  # Buffer only the fast discovery phase so we can preserve the friendly empty
  # state. Rendering then streams into fzf, letting the picker appear before
  # branch/path decoration for every row has finished.
  rows="$(scan)"

  if [ -z "$rows" ]; then
    printf '\n   No agent panes found.\n\n   (pattern: %s)\n\n   press any key to close' \
      "$(opt @agent-view-pattern "$DEFAULT_PATTERN")"
    read -rsn1
    return 0
  fi

  # Every rendered line is exactly one agent pane (state is an inline column,
  # not a header), so up/down move agent-to-agent and enter always jumps.
  sel="$(printf '%s\n' "$rows" | render_list | fzf \
    --ansi --reverse --no-info --cycle \
    --delimiter='\t' --with-nth=2.. \
    --prompt='  ' --pointer='▌' \
    --header='enter jump · ctrl-r refresh · esc close' \
    --header-first \
    --color='header:dim,pointer:cyan,hl:cyan,hl+:cyan,bg+:236,gutter:-1,border:240' \
    --preview="tmux capture-pane -ep -t {1}" \
    --preview-window='bottom,55%,border-top' \
    --bind="ctrl-r:reload('$SELF' list)")" || return 0

  pane_id="${sel%%	*}"
  [ -n "$pane_id" ] && jump "$pane_id"
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
