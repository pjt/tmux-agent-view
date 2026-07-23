#!/usr/bin/env bash
# tmux-agent-view — register agent-hook.sh as a lifecycle hook in whichever of
# Claude Code / Codex / Kimi Code are installed. Idempotent: safe to re-run.
# Every config it touches is backed up first (<file>.bak.<timestamp>).
#
#   scripts/install-hooks.sh            # register for all detected CLIs
#
# The hooks write per-pane agent state that agent-view.sh reads (and, on macOS
# with terminal-notifier, send a clickable banner). See README.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/agent-hook.sh"
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

# 2) ensure state-driving events are registered (async, state-only for the
#    non-attention ones — the script itself decides whether to notify)
added = []
for event in ("Stop", "Notification", "UserPromptSubmit", "SessionEnd"):
    if has_ours(event):
        continue
    entry = {"hooks": [{"type": "command", "command": cmd, "async": True}]}
    if event == "Notification":
        entry["matcher"] = "*"
    h.setdefault(event, []).append(entry); added.append(event)

json.dump(d, open(cfg, "w"), indent=2); open(cfg, "a").write("\n")
json.load(open(cfg))  # re-validate
print(f"  claude: migrated {migrated} legacy ref(s); added events: {added or 'none (already present)'}")
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

echo "Registering agent-hook.sh: $HOOK"
[ -x "$HOOK" ] || chmod +x "$HOOK" 2>/dev/null
install_claude
install_codex
install_kimi
echo "Done."
