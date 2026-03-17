# Rename claude-relay to clay

## Context

The upstream project [claude-relay](https://github.com/chadbyte/claude-relay) has been renamed to [clay](https://github.com/chadbyte/clay). The npm package is now `clay-server` and the CLI command is `clay-server`.

Module `09-clay.sh` has already been renamed and its contents updated, but the changes are unstaged. Several other files still reference the old name.

## Scope

Live/operational files only. Historical plan documents (`docs/plans/`) are left as-is.

## Files to update

### 1. `README.md` (~10 occurrences across 6 lines)

- GitHub links: `chadbyte/claude-relay` -> `chadbyte/clay`
- Display text: "claude-relay" -> "clay"
- "Claude Relay PWA" -> "Clay PWA"
- Caddy vhost in examples: `claude-relay.underdev.cloud` -> `clay.underdev.cloud`
- Directory tree listing: `claude-relay` -> `clay`
- Module label: `09  claude-relay` -> `09  clay`

### 2. `install.sh` (1 reference)

- Module label: `09  claude-relay (auto-install)` -> `09  clay (auto-install)`

### 3. `scripts/modules/09-clay.sh` (1 bug fix)

- Already mostly updated in unstaged changes. Needs staging.
- Bug fix: detection check uses `npm list -g clay` but actual package is `clay-server`. Change to `npm list -g clay-server`.

## Out of scope

- `docs/plans/2026-03-07-vps-worktree-manager-implementation.md` — historical plan doc, left unchanged.
- `docs/plans/2026-03-07-vps-worktree-manager-design.md` — historical design doc, left unchanged.
