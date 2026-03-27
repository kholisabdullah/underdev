# UnderDev

Agentic development environment for Laravel or Node.js projects in VPS. Spin up isolated preview environments in 1-2 minutes, manage them via mobile, and let Claude do the heavy lifting — all on a RAM-constrained VPS with no Docker overhead.

```bash
# On your Ubuntu VPS (4GB+ RAM):
curl -fsSL https://raw.githubusercontent.com/kholisabdullah/underdev/main/install.sh | bash

# Then install PHP/Node versions:
bash scripts/install-versions.sh
```

## What It Does

You talk to Claude from your phone. Claude creates worktrees, spins up preview environments, and manages your entire dev workflow — no laptop required.

- **Git worktrees** with automatic preview environments (e.g. `feat-auth-project.underdev.cloud`)
- **[phpenv](https://github.com/phpenv/phpenv) + [nvm](https://github.com/nvm-sh/nvm)** for instant version switching — 1 second vs 4-8 min Docker rebuild, 0MB overhead vs 200MB per container
- **PHP-FPM** with per-version socket routing via Caddy
- **[clay](https://github.com/chadbyte/clay)** for mobile development — control Claude Code from your phone or tablet via a PIN-protected PWA
- **SQLite registry** for worktree state, port allocation, and resource monitoring
- **Database isolation** — copy or share databases per worktree, with a "fix later" escape hatch
- **Discord alerts** when RAM exceeds configurable thresholds

## Why Not Docker

We explored Docker thoroughly — per-worktree containers, single dev container, remote dev container pattern. All rejected for this use case:

| | phpenv/nvm (UnderDev) | Docker per worktree |
|---|---|---|
| Worktree creation | ~1-2 min | 4-8 min |
| RAM overhead | 0MB | ~200MB per container |
| Version switching | 1 second | Rebuild |
| Filesystem | Direct | Volume mounts |

Docker is great for production. We use it on our database VPS via Coolify. But for rapid dev iteration on RAM-constrained VPS (4GB), native tooling wins.

## Mobile Workflow

```
Open Clay PWA on your phone or tablet
Select root project folder

You (phone): "Create worktree for project1 branch feat-auth"
Claude:       [Runs init script]
Claude:       "Done — https://feat-auth-project1.underdev.cloud (port 8001)"
```

Claude Code runs on the VPS. You connect via **[clay](https://github.com/chadbyte/clay)** — a zero-install PWA with PIN auth and push notifications for permission prompts

## Usage
Open Clay PWA on your phone or tablet, select root project folder, and create worktrees via [clay](https://github.com/chadbyte/clay) terminal.

```bash
# Create a worktree (or ask Claude to do it)
cd ~/projects/my-project
./init-worktree.sh feature/auth

# List active worktrees
wt list

# Get worktree details
wt info my-project feature/auth

# View system stats + RAM trend
wt stats

# Find orphaned worktrees
wt check

# Clean up a worktree
cleanup-worktree.sh my-project feature/auth
```

## Architecture

```
Caddy (reverse proxy, auto-HTTPS)
  ├── feat-auth-project1.underdev.cloud -> PHP-FPM 8.3 -> worktree/public
  ├── fix-bug-project2.underdev.cloud  -> PHP-FPM 8.2 -> worktree/public
  └── clay.underdev.cloud              -> localhost:2633

PHP-FPM (one pool per version)
  ├── php8.3-fpm.sock
  └── php8.2-fpm.sock

Supervisor (user-level, no root)
  ├── clay
  └── node dev servers (if needed)

SQLite (~/projects/worktrees.db)
  ├── worktrees        — ports, subdomains, status, db isolation
  └── resource_snapshots — RAM/CPU/disk metrics every 5 min

Network
  ├── Public:    port 80/443 (preview environments)
  ├── Tailscale: SSH access (port 22 blocked publicly)
  └── Database:  Other VPS via Tailscale private network
```

## Installation Modules

```
01  System dependencies + database clients
02  phpenv (PHP version manager)
03  nvm + Node.js LTS
04  PHP-FPM pool configuration
05  Caddy reverse proxy
06  Supervisor (user-level)
07  Tailscale VPN
08  Claude Code
09  clay
10  Project structure + SQLite init
11  Shell integration (PATH, aliases)
```

All modules are idempotent — safe to re-run.

## Development

```bash
# Lint all scripts
make lint

# Structural validation
make validate

# All checks
make test
```

## Requirements

- Ubuntu (any recent version)
- 4GB+ RAM
- Not running as root
