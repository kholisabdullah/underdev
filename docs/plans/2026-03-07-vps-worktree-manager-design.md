# VPS Worktree Manager — Design Document

**Date**: 2026-03-07
**Status**: Approved
**Source**: [Notion — Idea 2: Agentic Development Environment](https://www.notion.so/Idea-2-Agentic-Development-Environment-30f070e81b8181fa9ebfd631a20fc26d)

## Vision

Cloud-based development environment on a 4GB KVM1 VPS with AI-powered workflows. Git worktrees with automatic preview environments, mobile development via claude-relay, multi-project support with subdomain routing, and shared workspace for CEO.

## Key Decisions

| Decision | Choice | Rationale |
|---|---|---|
| PHP runtime | PHP-FPM (single pool per version, Caddy routes) | Skip FrankenPHP entirely — fewer processes, less RAM, simpler init/cleanup |
| Version management | phpenv + nvm | 1s switch vs 4-8min Docker rebuild, 0MB overhead |
| Reverse proxy | Caddy (file-based config snippets) | Auto-HTTPS, simple vhost per worktree |
| Port tracking | SQLite | ACID, one-line queries, joins with monitoring data |
| Process manager | Supervisor (user-level) | Auto-restart, no root needed for process ops |
| Database hosting | KVM2 via Tailscale | Frees RAM on KVM1 |
| Mobile access | claude-relay only | No Happy app, single dev relay auto-installed |
| Implementation order | Script-by-script, bottom-up | Matches module numbering, each script testable before next |
| Testing | ShellCheck + dry-run + Makefile validation | Verify locally before deploying to VPS |

## Repository Structure

```
vps-worktree-manager/
├── install.sh                    # Curl-able entry point
├── Makefile                      # lint, dry-run, validate targets
├── .shellcheckrc                 # ShellCheck config
├── .gitignore
├── README.md
├── docs/
│   └── plans/
├── scripts/
│   ├── common.sh                 # Shared preamble (logging, run(), dry-run)
│   ├── modules/
│   │   ├── 01-system-deps.sh     # apt packages, sqlite3, DB clients
│   │   ├── 02-phpenv.sh          # phpenv + php-build plugin
│   │   ├── 03-nvm-node.sh        # nvm + Node.js LTS
│   │   ├── 04-php-fpm.sh         # PHP-FPM per-version pools
│   │   ├── 05-caddy.sh           # Caddy + /etc/caddy/sites/ + sudoers
│   │   ├── 06-supervisor.sh      # User-level Supervisor
│   │   ├── 07-tailscale.sh       # Tailscale install + optional auth
│   │   ├── 08-claude-code.sh     # npm install -g @anthropic-ai/claude-code
│   │   ├── 09-claude-relay.sh    # Auto-install dev relay, warn about PIN
│   │   ├── 10-project-structure.sh  # ~/projects/ dirs + scripts + SQLite init
│   │   └── 11-shell-integration.sh  # PATH, aliases in ~/.bashrc
│   ├── port-manager.sh           # SQLite registry library (sourced)
│   ├── worktree-cli.sh           # `wt` CLI wrapper
│   ├── cleanup-worktree.sh       # Full worktree teardown
│   ├── db-copy-helper.sh         # Database copy utility
│   ├── monitor-resources.sh      # Cron-based monitoring + Discord alerts
│   ├── migrate-add-resource-snapshots.sh  # One-time migration
│   ├── setup-claude-relay.sh     # Add additional relay instances
│   └── install-versions.sh       # Interactive PHP/Node version picker
└── examples/
    └── init-worktree-template.sh # Per-project init template
```

## Script Conventions

All scripts follow these patterns:

- `#!/usr/bin/env bash` + `set -euo pipefail`
- Source `common.sh` for logging (`info`, `warn`, `error`, `success`) and `run()` wrapper
- Support `--help` and `--dry-run` flags
- Idempotent — safe to re-run using guards (`command -v`, `[ -d ... ]`, `grep -q`)
- ShellCheck clean
- Exit codes: `0` success, `1` general failure, `10` privilege issue (db-copy-helper)
- No hardcoded usernames or paths — use `$HOME`, `$USER`

### common.sh

Sourced by all scripts. Provides:

```bash
DRY_RUN="${DRY_RUN:-false}"

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] $*"
    else
        "$@"
    fi
}
```

## install.sh Entry Point

Curl-able: `curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash`

1. Validates: Ubuntu OS, >=4GB RAM, not running as root
2. Prompts: confirms before proceeding
3. Runs modules 01-11 in order, tracking pass/fail
4. Idempotent — completed modules skip cleanly on re-run

Runs as regular user. Uses `sudo` only for specific privileged operations:

| Operation | Why sudo |
|---|---|
| `apt install ...` | System packages |
| `tee /etc/caddy/sites/*` | Caddy vhost configs |
| `caddy reload` | Reload reverse proxy |
| `tee /etc/sudoers.d/caddy-worktrees` | One-time sudoers setup |
| `systemctl disable supervisor` | Disable system Supervisor (once) |
| `systemctl enable caddy` | Enable Caddy service (once) |

## Installation Modules

### 01-system-deps.sh

Installs apt packages: git, curl, wget, build-essential, SSL/XML/readline/zip/oniguruma/pq/sqlite dev libs, pkg-config, autoconf, bison, re2c, sqlite3.

Database clients for `db-copy-helper.sh`:

| Client | Package |
|---|---|
| MySQL 8 | `mysql-client-8.0` |
| MariaDB 10 | `mariadb-client-10` |
| PostgreSQL (LTS) | `postgresql-client` |
| SQL Server (sqlcmd) | `mssql-tools18` via Microsoft repo |

### 02-phpenv.sh

Clones phpenv + php-build plugin to `~/.phpenv`. Does NOT compile PHP versions — deferred to `install-versions.sh` (10-20 min per version). Idempotent: skips if `~/.phpenv` exists.

### 03-nvm-node.sh

Installs nvm v0.39.7 + Node.js LTS immediately (required by Claude Code and claude-relay).

### 04-php-fpm.sh

Installs PHP-FPM. One FPM master process per PHP version, each listening on its own socket:

```
PHP 8.3 → /run/php/php8.3-fpm.sock
PHP 8.2 → /run/php/php8.2-fpm.sock
PHP 8.1 → /run/php/php8.1-fpm.sock
```

Caddy routes to the correct socket based on the project's `.php-version` file. No per-worktree FPM processes — Caddy handles isolation via `root` directive:

```caddyfile
feat-auth-project1.underdev.cloud {
    root * /home/user/projects/project1/.worktrees/feat-auth/public
    php_fastcgi unix//run/php/php8.3-fpm.sock
    file_server
}
```

Implications:
- No Supervisor config per worktree for PHP
- ~50MB RAM for one FPM master vs ~400MB per FrankenPHP instance
- Multiple PHP versions supported via different sockets
- Worktree init/cleanup only touches Caddy configs

### 05-caddy.sh

Installs Caddy via apt. Creates `/etc/caddy/sites/` directory. Adds `import /etc/caddy/sites/*.caddy` to global Caddyfile. Configures passwordless sudoers at `/etc/sudoers.d/caddy-worktrees` for three operations: caddy reload, tee config files, rm config files.

### 06-supervisor.sh

Installs Supervisor via apt, immediately disables system instance. Sets up user-level Supervisor:

- Config: `~/.config/supervisor/supervisord.conf`
- Socket: `~/.config/supervisor/supervisor.sock`
- Logs: `~/.config/supervisor/logs/`
- Per-process configs: `~/.config/supervisor/conf.d/`

With PHP-FPM, Supervisor manages: claude-relay and any Node.js dev servers (Next.js, Vite). NOT PHP processes.

### 07-tailscale.sh

Installs Tailscale. Optionally prompts to authenticate immediately. Needed for SSH access and KVM2 database connectivity.

### 08-claude-code.sh

`npm install -g @anthropic-ai/claude-code`.

### 09-claude-relay.sh

Auto-installs a single developer relay instance:

1. Installs: `npm install -g claude-relay`
2. Creates Supervisor config: `npx claude-relay --headless --no-https --port 2633 --yes`
3. Creates Caddy vhost: `claude-relay.underdev.cloud`
4. Starts the relay
5. Auto-registers all `~/projects/*/` directories that have `.git`
6. Prints warning to set PIN via `RELAY_PIN` + supervisor restart

No PIN by default — works immediately out of the box. User sets PIN later by editing Supervisor config to add `--pin <pin>` and restarting.

Additional relays for CEO or others: user creates Supervisor config + Caddy vhost manually (the pattern is clear from the dev relay). No wrapper script needed.

### 10-project-structure.sh

Creates `~/projects/{scripts,backups,logs}`. Copies all core scripts. Initializes SQLite database with worktrees table, indexes, trigger, and resource_snapshots table. Sets up monitoring cron job.

### 11-shell-integration.sh

Appends to `~/.bashrc` (with idempotent marker):
- `~/projects/scripts` added to PATH
- `wt` alias to `worktree-cli.sh`
- `supervisorctl` alias pointing to user-level config

## Core Scripts

### port-manager.sh (sourced library)

SQLite interface at `~/projects/worktrees.db`. Port range 8001-8999. Key functions:

| Function | Purpose |
|---|---|
| `find_next_port` | MAX(port) + 1, gap-finding CTE fallback |
| `add_worktree` | Insert entry, return allocated port |
| `remove_worktree` | Delete by project + branch |
| `get_port/pid/subdomain` | Single-value lookups |
| `mark_stopped/failed/db_deleted` | Status transitions |
| `list_active/all/by_project` | Filtered listing |
| `check_orphans` | PID in DB but process dead |
| `show_stats` | Counts + RAM trend from resource_snapshots |

SQLite schema:

```sql
CREATE TABLE worktrees (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project TEXT NOT NULL,
    branch TEXT NOT NULL,
    folder_name TEXT NOT NULL,
    port INTEGER UNIQUE NOT NULL,
    subdomain TEXT NOT NULL,
    pid INTEGER,
    status TEXT DEFAULT 'active' CHECK(status IN ('active','stopped','failed')),
    db_driver TEXT,
    db_name TEXT,
    db_isolation TEXT DEFAULT 'shared' CHECK(db_isolation IN ('isolated','shared','deleted','none')),
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(project, branch)
);
```

### worktree-cli.sh (`wt` command)

Thin case-statement wrapper sourcing `port-manager.sh`. Commands: `list`, `list-all`, `list-project`, `info`, `search`, `check`, `cleanup`, `stats`, `oldest`, `export`, `backup`, `optimize`, `init`, `help`.

### init-worktree-template.sh (per-project, in examples/)

Copy into each project and set `PROJECT` variable. Flow:

1. Create git worktree at `.worktrees/{folder}/`
2. Read `.php-version` → pick correct FPM socket
3. Read `.nvmrc` → nvm use for asset builds
4. Copy `.env` from main checkout
5. Copy `.claude/` settings + skills
6. Database strategy prompt (shared vs copy) — automatable via `DB_COPY_STRATEGY` env var
7. `composer install` + `npm install` + `npm run build`
8. `php artisan key:generate` + `config:clear`
9. Allocate port via port-manager.sh
10. Generate Caddy vhost at `/etc/caddy/sites/{subdomain}.caddy`
11. `sudo caddy reload`
12. Register in SQLite
13. Print preview URL

No Supervisor involvement for Laravel projects — PHP-FPM is already running.

### cleanup-worktree.sh

Reverse of init:

1. Remove Caddy config + reload
2. Drop database if isolation = "isolated" (MySQL/PostgreSQL/SQLite/SQL Server)
3. Remove git worktree (force + prune fallback)
4. Remove from SQLite registry
5. Stop Supervisor process only if one exists (Node.js projects)

### db-copy-helper.sh

Reads `.env`, auto-detects engine, copies database. Target naming: `{original}_{worktree_folder}`. Validates required client exists before attempting copy.

Exit codes: `0` success, `1` failure, `10` no CREATE privilege (triggers "fix later" prompt in init template).

Supported engines: MySQL/MariaDB (mysqldump), PostgreSQL (pg_dump + createdb), SQLite (file copy), SQL Server (sqlcmd backup/restore).

## Monitoring & Alerting

### monitor-resources.sh

Cron-based (every 5 min). Records snapshots to `resource_snapshots` table in `worktrees.db`.

Collects: `ram_used_pct`, `ram_available_mb`, JSON data (cpu_load_1m, disk_used_pct, active_worktrees, worktree_list).

Thresholds from `~/projects/.env`:

```env
DISCORD_WEBHOOK=https://discord.com/api/webhooks/...
RAM_WARN_PCT=80
RAM_CRIT_PCT=90
```

Discord alerts include RAM %, free MB, CPU load, disk %, active worktree list. 30-minute cooldown per alert level.

Modes: default (cron), `--status` (last 10 snapshots + trend), `--test` (test Discord webhook).

### wt stats integration

Shows worktree statistics + RAM trend (last hour) + RAM peak (last 24h) with critical/warn event counts.

## Resource Budget (4GB RAM)

| Component | RAM |
|---|---|
| System | ~450MB |
| Caddy | ~50MB |
| Supervisor | ~30MB |
| PHP-FPM (per version) | ~50MB |
| **Fixed total** | **~580MB** |

Per worktree (served by shared FPM): minimal additional RAM per request, not ~400MB per FrankenPHP instance. Capacity: 5-8 concurrent worktrees comfortably.

## Network & Security

- Worktree previews: public (anyone with URL)
- SSH: Tailscale-only (port 22 blocked publicly)
- Hostinger firewall: ALLOW 443, ALLOW 80, ALLOW UDP 41641, DENY all else
- Databases: KVM2 via Tailscale private network (`100.x.x.x:3306`)

## Testing Infrastructure

### ShellCheck

All scripts must pass with zero warnings. Config in `.shellcheckrc`.

### Makefile

```makefile
lint:       # ShellCheck all .sh files
validate:   # Check permissions, shebangs, common.sh sourced, --help support
dry-run:    # DRY_RUN=true bash install.sh
test:       # lint + validate
```

### --dry-run

Every script respects `DRY_RUN=true` via the `run()` wrapper. Prints what would execute without touching the system. Full install sequence verifiable from local machine before deploying.

## What's NOT in v1.0

- MCPHub shared MCP process (v1.1 — RAM optimization)
- GitLab MR automation (post v1.1)
- Auto-cleanup of merged/idle worktrees (post v1.1)
- Backup automation (post v1.1)
- Docker dev container support (v2.0, separate repo)
