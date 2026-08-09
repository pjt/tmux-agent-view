# Repository Guidelines

## Project Structure & Module Organization

This repository is a small Bash-based tmux plugin with no compiled build step. `agent-view.tmux` is the TPM entry point: it registers the key binding and status-line command. `scripts/agent-view.sh` contains pane discovery, state rendering, the fzf picker, and jump behavior. `scripts/agent-hook.sh` translates agent lifecycle events into cached pane state and macOS notifications, while `scripts/install-hooks.sh` registers that hook with supported agent CLIs. `scripts/test-notify.sh` is a manual notification/focus probe. User-facing setup belongs in `README.md`; historical design context lives under `docs/superpowers/specs/`.

## Build, Test, and Development Commands

There is no package manager or build command. Use these checks from the repository root:

```sh
bash -n agent-view.tmux scripts/*.sh
./scripts/agent-view.sh list
./scripts/agent-view.sh counts
./scripts/agent-view.sh status
tmux source-file ~/.tmux.conf
```

The first command checks shell syntax. The next three exercise read-only output against a live tmux server. Reload tmux configuration before manually testing `prefix + a`, selection, preview, and pane jumping. `scripts/install-hooks.sh` modifies user configuration files, so run it only when intentionally testing installation behavior; it creates timestamped backups.

## Coding Style & Naming Conventions

Keep runtime scripts compatible with macOS Bash 3.2. Use two-space indentation, `snake_case` function and local-variable names, and uppercase names for constants such as `STATE_DIR`. Quote expansions, prefer `printf` over shell-specific output behavior, and preserve graceful handling of missing panes or optional tools. New executable scripts should use a Bash shebang and retain executable permissions. No formatter or linter is configured, so match nearby code and run `bash -n` before committing.

## Testing Guidelines

There is no automated framework or coverage threshold. Test status ordering, empty-state behavior, fzf refresh, and cross-session jumps with a live tmux server. Name future probes `scripts/test-<feature>.sh`. The notification probe is macOS-specific; inspect its hard-coded tmux, terminal-notifier, terminal app, and hook paths before running `bash scripts/test-notify.sh`.

## Commit & Pull Request Guidelines

Recent history favors focused Conventional Commit subjects, for example `feat: support Kimi Code agent panes`, `fix: exclude idle_prompt`, and `refactor: drop screen-scraping fallback`. Use an imperative, scoped subject and keep unrelated changes separate. Pull requests should explain user-visible behavior, list manual checks, call out config or dependency changes, and include a screenshot for picker or status-line UI changes.
