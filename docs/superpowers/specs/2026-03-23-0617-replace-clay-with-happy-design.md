---
title: Replace clay with Happy Coder
date: 2026-03-23
status: approved
---

# Replace clay with Happy Coder

## Context

The current mobile interface is clay (`clay-server`), which violates Anthropic's ToS (Feb 2026 crackdown — it uses the Agent SDK internally). Happy Coder is a ToS-compliant PTY-relay tool with a native Android app, E2E encryption, and push notifications. Public relay is used (no self-hosted relay server).

## Scope

One file deleted, one new file created (net module count unchanged at 11). Three existing files updated.

| File | Change |
|------|--------|
| `scripts/modules/09-clay.sh` | **Deleted** — replaced by `09-happy.sh` (new file) |
| `scripts/modules/09-happy.sh` | New file — installs happy-coder |
| `install.sh` | Update module 09 description; source nvm then run `happy --auth` as final step |
| `README.md` | Replace all clay references with Happy Coder |
| `scripts/modules/03-nvm-node.sh` | Update inline comment mentioning clay |

> **Note:** `09-clay.sh` must be deleted (not just renamed by copy). `install.sh` discovers modules via glob `[0-9][0-9]-*.sh` sorted lexicographically — leaving both files present would cause both to execute, with clay running before happy.

## Out of Scope

- Clay teardown/cleanup — module assumes a fresh VPS
- Self-hosted Happy relay server setup
- Supervisor config for Happy (no daemon needed)
- Caddy vhost for Happy (public relay is outbound-only)

## Design

### `09-happy.sh` (replaces `09-clay.sh`)

Two responsibilities only:

1. **Install happy-coder globally**
   - Check npm is available; error with "Run module 03 (nvm-node) first" if not
   - `npm install -g happy-coder`
   - Skip if already installed — check both `command -v happy &>/dev/null` and `npm list -g happy-coder &>/dev/null 2>&1` (same compound pattern as clay module, handles cases where binary is installed but not on current PATH)

2. **No auth step** — auth is handled by `install.sh` at the end

No Supervisor config. No Caddy vhost. No port. No project registration.

> **Verified:** `npm install -g happy-coder` places a `happy` binary on PATH (confirmed by quick start docs: `npm install -g happy-coder` then `happy --auth`). The `command -v happy` check is reliable as the primary skip condition.

> **Verified:** A repo-wide grep for `clay` confirms exactly four files require changes: `09-clay.sh` (deleted), `install.sh`, `README.md`, `03-nvm-node.sh`.

### `install.sh`

- Update module 09 description line from `clay (auto-install)` to `happy (install)`
- After all modules complete, source nvm before running `happy --auth`:
  ```bash
  export NVM_DIR="${HOME}/.nvm"
  [[ -s "${NVM_DIR}/nvm.sh" ]] && source "${NVM_DIR}/nvm.sh"
  happy --auth || true
  ```
  Two notes:
  - nvm must be sourced explicitly: `npm install -g happy-coder` runs inside the module subprocess so the parent shell does not inherit the nvm PATH.
  - `|| true` is required: `install.sh` runs under `set -euo pipefail`. If `happy --auth` exits non-zero (user presses Ctrl-C, terminal can't render QR, etc.) the whole install would report as failed. Since all modules already succeeded at this point, auth failure must not mask that.

### `README.md`

Replace all clay references:

- Feature list: `clay` → `Happy Coder` with updated description (native Android app, E2E encrypted, public relay)
- Architecture diagram: remove `clay.underdev.cloud → localhost:2633` line; remove `clay` from Supervisor process list
- Usage steps: "Open Clay PWA on your phone" → "Open Happy app on your phone"
- Any other inline mentions of clay or `clay.underdev.cloud`

### `03-nvm-node.sh`

Update the inline comment that says clay requires Node — replace with happy-coder.

## Auth Flow (Post-Install)

After `install.sh` completes all modules, it runs `happy --auth`. This:

- Displays a QR code in the terminal
- User scans with Happy mobile app
- One-time setup — not scripted, intentionally interactive
- After pairing, sessions are started from the mobile app directly (no daemon required)
