#!/usr/bin/env bash
# tmux-agent-view — register agent-hook.sh as a lifecycle hook in whichever of
# Claude Code / Codex / Kimi Code / Pi are installed. Idempotent: safe to re-run.
# Every config it touches is backed up first (<file>.bak.<timestamp>).
#
#   scripts/install-hooks.sh            # register for all detected CLIs
#
# The hooks write per-pane agent state that agent-view.sh reads (and, on macOS
# with terminal-notifier, send a clickable banner). See README.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/agent-hook.sh"
PI_EXTENSION="$DIR/pi-extension.ts"
TS="$(date +%Y%m%d-%H%M%S)"

backup() { [ -f "$1" ] && cp "$1" "$1.bak.$TS" && echo "  backed up $1 -> $1.bak.$TS"; }

# ---------------------------------------------------------------- Claude Code
install_claude() {
  local cfg="$HOME/.claude/settings.json"
  [ -f "$cfg" ] || { echo "claude: no $cfg — skipped"; return; }
  command -v python3 >/dev/null 2>&1 || { echo "claude: needs python3 — skipped"; return; }
  backup "$cfg"
  HOOK="$HOOK" python3 - "$cfg" <<'PY'
import json, os, sys
cfg = sys.argv[1]; hook = os.environ["HOOK"]; cmd = hook + " claude"
d = json.load(open(cfg)); h = d.setdefault("hooks", {})

def has_ours(event):
    for grp in h.get(event, []):
        for e in grp.get("hooks", []):
            if e.get("command", "").startswith(hook):
                return True
    return False

# 1) migrate any legacy agent-notify.sh reference to agent-hook.sh
migrated = 0
for grp in [g for arr in h.values() for g in arr]:
    for e in grp.get("hooks", []):
        c = e.get("command", "")
        if "agent-notify.sh" in c:
            e["command"] = cmd; migrated += 1

# Notification fires for several types; only these genuinely need you. Crucially
# this EXCLUDES idle_prompt — Claude waiting after a finished turn — which the
# old catch-all "*" matcher mislabeled as needs_input on completed panes.
NOTIFY_MATCHER = "permission_prompt|elicitation_dialog|agent_needs_input"

# 2a) retune any existing Notification hook of ours off the old "*" matcher.
retuned = 0
for grp in h.get("Notification", []):
    if any(e.get("command", "").startswith(hook) for e in grp.get("hooks", [])):
        if grp.get("matcher") != NOTIFY_MATCHER:
            grp["matcher"] = NOTIFY_MATCHER; retuned += 1

# 2b) ensure state-driving events are registered (async, state-only for the
#    non-attention ones — the script itself decides whether to notify)
# PreToolUse is the earliest signal that work resumed after a permission/
# question prompt was answered — there is no dedicated "answered" hook.
added = []
for event in ("Stop", "Notification", "UserPromptSubmit", "PreToolUse", "SessionEnd"):
    if has_ours(event):
        continue
    entry = {"hooks": [{"type": "command", "command": cmd, "async": True}]}
    if event == "Notification":
        entry["matcher"] = NOTIFY_MATCHER
    h.setdefault(event, []).append(entry); added.append(event)

json.dump(d, open(cfg, "w"), indent=2); open(cfg, "a").write("\n")
json.load(open(cfg))  # re-validate
print(f"  claude: migrated {migrated} legacy ref(s); retuned {retuned} Notification matcher(s); added events: {added or 'none (already present)'}")
PY
}

# ---------------------------------------------------------------- Codex
install_codex() {
  local cfg="$HOME/.codex/hooks.json"
  [ -d "$HOME/.codex" ] || { echo "codex: no ~/.codex — skipped"; return; }
  command -v python3 >/dev/null 2>&1 || { echo "codex: needs python3 — skipped"; return; }
  [ -f "$cfg" ] || echo '{"hooks":{}}' > "$cfg"
  backup "$cfg"
  HOOK="$HOOK" python3 - "$cfg" <<'PY'
import json, os, sys
cfg = sys.argv[1]; hook = os.environ["HOOK"]; cmd = hook + " codex"
d = json.load(open(cfg)); h = d.setdefault("hooks", {})

def has_ours(event):
    for grp in h.get(event, []):
        for e in grp.get("hooks", []):
            if e.get("command", "").startswith(hook):
                return True
    return False

added = []
for event in ("Stop", "PermissionRequest", "UserPromptSubmit"):
    if has_ours(event):
        continue
    h.setdefault(event, []).append(
        {"hooks": [{"type": "command", "command": cmd, "timeout": 10}]})
    added.append(event)

json.dump(d, open(cfg, "w"), indent=2); open(cfg, "a").write("\n")
json.load(open(cfg))
print(f"  codex: added events: {added or 'none (already present)'}")
PY
  echo "  codex: NOTE — Codex requires you to TRUST hooks. Next time you start"
  echo "         codex interactively it will prompt once to trust this hook."
}

# ---------------------------------------------------------------- Kimi Code
install_kimi() {
  local cfg="$HOME/.kimi-code/config.toml"
  [ -f "$cfg" ] || { echo "kimi: no $cfg — skipped"; return; }
  if grep -q 'agent-hook.sh' "$cfg" 2>/dev/null; then
    echo "  kimi: already registered — skipped"; return
  fi
  backup "$cfg"
  {
    echo ""
    echo "# --- tmux-agent-view hooks (added by install-hooks.sh) ---"
    for ev in UserPromptSubmit Notification PermissionRequest Stop StopFailure Interrupt SessionEnd; do
      echo "[[hooks]]"
      echo "event = \"$ev\""
      echo "command = \"$HOOK kimi\""
      echo "timeout = 10"
      echo ""
    done
  } >> "$cfg"
  if command -v kimi >/dev/null 2>&1; then
    if kimi doctor >/dev/null 2>&1; then
      echo "  kimi: added 7 hooks; kimi doctor OK"
    else
      echo "  kimi: added 7 hooks but 'kimi doctor' reported an issue — check $cfg"
    fi
  else
    echo "  kimi: added 7 hooks (kimi CLI not on PATH, skipped doctor)"
  fi
}

# ---------------------------------------------------------------- Pi
install_pi() {
  local agent_dir="$HOME/.pi/agent"
  local extension_dir="$agent_dir/extensions"
  local dst="$extension_dir/tmux-agent-view.ts"
  local tmp

  if [ ! -d "$agent_dir" ] && ! command -v pi >/dev/null 2>&1; then
    echo "pi: not installed — skipped"
    return
  fi
  command -v python3 >/dev/null 2>&1 || { echo "pi: needs python3 — skipped"; return; }
  [ -f "$PI_EXTENSION" ] || { echo "pi: missing $PI_EXTENSION — skipped"; return; }
  mkdir -p "$extension_dir" 2>/dev/null || {
    echo "pi: cannot create $extension_dir — skipped"
    return
  }
  tmp="$(mktemp "$extension_dir/.tmux-agent-view.XXXXXX")" || {
    echo "pi: cannot create temporary extension — skipped"
    return
  }

  python3 - "$PI_EXTENSION" "$tmp" "$HOOK" <<'PY'
import json, sys

src, dst, hook = sys.argv[1:]
text = open(src).read()
placeholder = '"__AGENT_VIEW_HOOK__"'
if text.count(placeholder) != 1:
    raise SystemExit("unexpected Pi extension hook placeholder count")
text = text.replace(placeholder, json.dumps(hook))
with open(dst, "w") as f:
    f.write(text)
PY
  if [ "$?" -ne 0 ]; then
    rm -f "$tmp" 2>/dev/null
    echo "pi: could not render extension — skipped"
    return
  fi

  if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then
    rm -f "$tmp" 2>/dev/null
    echo "  pi: already registered — skipped"
    return
  fi
  backup "$dst"
  if mv -f "$tmp" "$dst" 2>/dev/null; then
    echo "  pi: installed extension -> $dst"
  else
    rm -f "$tmp" 2>/dev/null
    echo "pi: could not install $dst — skipped"
  fi
}

echo "Registering agent-hook.sh: $HOOK"
[ -x "$HOOK" ] || chmod +x "$HOOK" 2>/dev/null
install_claude
install_codex
install_kimi
install_pi
echo "Done."
