# VPS Worktree Manager — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a complete VPS worktree management system — 11 install modules, core scripts, monitoring, and CLI — ready for deployment on a 4GB KVM1 VPS.

**Architecture:** Bottom-up script-by-script approach. Shared `common.sh` preamble sourced by all scripts. Install modules numbered 01-11 run in order. Core scripts (port-manager, init-worktree, cleanup, monitoring) provide worktree lifecycle management. SQLite as central registry.

**Tech Stack:** Bash, SQLite3, ShellCheck, PHP-FPM, Caddy, Supervisor, phpenv, nvm, Tailscale, claude-relay

**Design Doc:** `docs/plans/2026-03-07-vps-worktree-manager-design.md`

---

## Task 1: Project Scaffolding

**Files:**
- Create: `.gitignore`
- Create: `.shellcheckrc`
- Create: `Makefile`
- Create: `scripts/common.sh`

**Step 1: Create .gitignore**

```gitignore
*.db
*.db-journal
*.log
*.bak
.env
node_modules/
.DS_Store
```

**Step 2: Create .shellcheckrc**

```ini
shell=bash
enable=all
# Don't warn about printf-style format strings used in color codes
disable=SC2059
```

**Step 3: Create Makefile**

```makefile
SHELL := /bin/bash
SCRIPTS := $(shell find . -name '*.sh' -not -path './node_modules/*')

.PHONY: lint validate dry-run test

lint:
	@echo "=== ShellCheck ==="
	@shellcheck $(SCRIPTS)
	@echo "All scripts passed ShellCheck."

validate:
	@echo "=== Structural Validation ==="
	@fail=0; \
	for f in $(SCRIPTS); do \
		if [[ "$$f" == "./scripts/common.sh" ]]; then continue; fi; \
		if ! head -1 "$$f" | grep -q '^#!/usr/bin/env bash'; then \
			echo "FAIL: $$f missing shebang"; fail=1; \
		fi; \
		if ! grep -q '\-\-help' "$$f" 2>/dev/null; then \
			echo "WARN: $$f missing --help support"; \
		fi; \
		if [[ "$$f" == ./scripts/modules/* ]] && ! grep -q 'common.sh' "$$f"; then \
			echo "FAIL: $$f does not source common.sh"; fail=1; \
		fi; \
	done; \
	if [[ $$fail -eq 1 ]]; then exit 1; fi
	@echo "All structural checks passed."

dry-run:
	@echo "=== Dry Run ==="
	DRY_RUN=true bash install.sh

test: lint validate
	@echo "=== All checks passed ==="
```

**Step 4: Create scripts/common.sh**

```bash
# common.sh — sourced by all scripts, not executed directly
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
#   or:  source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Dry-run mode
DRY_RUN="${DRY_RUN:-false}"

info()    { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
success() { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC} %s\n" "$*" >&2; }
error()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }

# Run a command, or print it in dry-run mode
run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] $*"
    else
        "$@"
    fi
}

# Parse common flags (call at top of every script)
parse_common_flags() {
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=true ;;
            --help)    return 1 ;;  # Caller should handle
        esac
    done
    return 0
}

# Check if running as root (should not be)
assert_not_root() {
    if [[ "$EUID" -eq 0 ]]; then
        error "Do not run this script as root. Run as your regular user — sudo is used where needed."
        exit 1
    fi
}

# Check Ubuntu
assert_ubuntu() {
    if [[ ! -f /etc/os-release ]] || ! grep -qi 'ubuntu' /etc/os-release; then
        error "This script requires Ubuntu."
        exit 1
    fi
}

# Check minimum RAM (in MB)
assert_min_ram() {
    local min_mb="${1:-4000}"
    local total_mb
    total_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
    if [[ "$total_mb" -lt "$min_mb" ]]; then
        error "Minimum ${min_mb}MB RAM required. Found: ${total_mb}MB."
        exit 1
    fi
}
```

**Step 5: Run ShellCheck on common.sh**

Run: `shellcheck scripts/common.sh`
Expected: No warnings

**Step 6: Commit**

```bash
git add .gitignore .shellcheckrc Makefile scripts/common.sh
git commit -m "scaffold: add project config and shared common.sh preamble"
```

---

## Task 2: Module 01 — System Dependencies

**Files:**
- Create: `scripts/modules/01-system-deps.sh`

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
# 01-system-deps.sh — Install system packages, build dependencies, and database clients
# Part of vps-worktree-manager install sequence

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

show_help() {
    cat <<'HELP'
Usage: 01-system-deps.sh [--dry-run] [--help]

Installs system packages required by vps-worktree-manager:
  - Build tools (build-essential, autoconf, bison, re2c, etc.)
  - PHP compilation dependencies (libxml2-dev, libssl-dev, etc.)
  - SQLite3
  - Database clients (mysql, mariadb, psql, sqlcmd)
HELP
}

parse_common_flags "$@" || { show_help; exit 0; }

install_build_deps() {
    local packages=(
        git curl wget vim unzip
        build-essential pkg-config autoconf bison re2c
        libxml2-dev libssl-dev libreadline-dev libzip-dev
        libonig-dev libpq-dev libsqlite3-dev libcurl4-openssl-dev
        libpng-dev libjpeg-dev libfreetype-dev
        sqlite3
    )

    info "Installing build dependencies..."
    run sudo apt update
    run sudo apt install -y "${packages[@]}"
    success "Build dependencies installed"
}

install_mysql_client() {
    if command -v mysql &>/dev/null; then
        info "MySQL client already installed — skipping"
        return 0
    fi
    info "Installing MySQL 8 client..."
    run sudo apt install -y mysql-client-8.0
    success "MySQL client installed"
}

install_mariadb_client() {
    if command -v mariadb &>/dev/null; then
        info "MariaDB client already installed — skipping"
        return 0
    fi
    info "Installing MariaDB client..."
    run sudo apt install -y mariadb-client
    success "MariaDB client installed"
}

install_pgsql_client() {
    if command -v psql &>/dev/null; then
        info "PostgreSQL client already installed — skipping"
        return 0
    fi
    info "Installing PostgreSQL client..."
    run sudo apt install -y postgresql-client
    success "PostgreSQL client installed"
}

install_sqlcmd() {
    if command -v sqlcmd &>/dev/null; then
        info "sqlcmd already installed — skipping"
        return 0
    fi
    info "Installing SQL Server client (sqlcmd)..."
    if [[ ! -f /usr/share/keyrings/microsoft-prod.gpg ]]; then
        run curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | \
            sudo gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg
        run sudo sh -c 'echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/$(lsb_release -rs)/prod $(lsb_release -cs) main" > /etc/apt/sources.list.d/mssql-release.list'
        run sudo apt update
    fi
    run sudo ACCEPT_EULA=Y apt install -y mssql-tools18 unixodbc-dev
    success "sqlcmd installed"
}

# Main
assert_not_root
install_build_deps
install_mysql_client
install_mariadb_client
install_pgsql_client
install_sqlcmd
success "Module 01 complete: all system dependencies installed"
```

**Step 2: ShellCheck + dry-run test**

Run: `shellcheck scripts/modules/01-system-deps.sh`
Expected: No warnings

Run: `DRY_RUN=true bash scripts/modules/01-system-deps.sh`
Expected: Prints `[DRY-RUN]` lines for each apt install

**Step 3: Commit**

```bash
git add scripts/modules/01-system-deps.sh
git commit -m "feat: add module 01 — system dependencies and database clients"
```

---

## Task 3: Module 02 — phpenv

**Files:**
- Create: `scripts/modules/02-phpenv.sh`

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
# 02-phpenv.sh — Install phpenv + php-build plugin
# Does NOT compile PHP versions — use install-versions.sh for that

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

show_help() {
    cat <<'HELP'
Usage: 02-phpenv.sh [--dry-run] [--help]

Installs phpenv and the php-build plugin to ~/.phpenv.
Does NOT compile any PHP versions — run install-versions.sh after install.
Idempotent: skips if ~/.phpenv already exists.
HELP
}

parse_common_flags "$@" || { show_help; exit 0; }

install_phpenv() {
    if [[ -d "$HOME/.phpenv" ]]; then
        info "phpenv already installed at ~/.phpenv — skipping"
        return 0
    fi

    info "Installing phpenv..."
    run git clone https://github.com/phpenv/phpenv.git "$HOME/.phpenv"

    info "Installing php-build plugin..."
    run git clone https://github.com/php-build/php-build.git "$HOME/.phpenv/plugins/php-build"

    success "phpenv installed"
}

configure_shell() {
    local bashrc="$HOME/.bashrc"
    local marker="# vps-wm:phpenv"

    if grep -q "$marker" "$bashrc" 2>/dev/null; then
        info "phpenv shell config already present — skipping"
        return 0
    fi

    info "Adding phpenv to shell config..."
    run tee -a "$bashrc" >/dev/null <<EOF

$marker
export PHPENV_ROOT="\$HOME/.phpenv"
export PATH="\$PHPENV_ROOT/bin:\$PATH"
eval "\$(phpenv init -)"
EOF
    success "Shell config updated for phpenv"
}

# Main
assert_not_root
install_phpenv
configure_shell
success "Module 02 complete: phpenv ready"
```

**Step 2: ShellCheck + dry-run test**

Run: `shellcheck scripts/modules/02-phpenv.sh`
Run: `DRY_RUN=true bash scripts/modules/02-phpenv.sh`

**Step 3: Commit**

```bash
git add scripts/modules/02-phpenv.sh
git commit -m "feat: add module 02 — phpenv and php-build plugin"
```

---

## Task 4: Module 03 — nvm + Node.js

**Files:**
- Create: `scripts/modules/03-nvm-node.sh`

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
# 03-nvm-node.sh — Install nvm and Node.js LTS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

NVM_VERSION="0.39.7"

show_help() {
    cat <<'HELP'
Usage: 03-nvm-node.sh [--dry-run] [--help]

Installs nvm and Node.js LTS. Node is installed immediately
(not deferred) because Claude Code and claude-relay require it.
HELP
}

parse_common_flags "$@" || { show_help; exit 0; }

install_nvm() {
    if [[ -d "$HOME/.nvm" ]]; then
        info "nvm already installed — skipping"
        return 0
    fi

    info "Installing nvm v${NVM_VERSION}..."
    run bash -c "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh | bash"
    success "nvm installed"
}

install_node_lts() {
    # Source nvm so we can use it
    export NVM_DIR="$HOME/.nvm"
    # shellcheck source=/dev/null
    [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"

    if command -v node &>/dev/null; then
        local current
        current="$(node --version)"
        info "Node.js already installed ($current) — skipping"
        return 0
    fi

    info "Installing Node.js LTS..."
    run nvm install --lts
    run nvm alias default lts/*
    success "Node.js LTS installed"
}

# Main
assert_not_root
install_nvm
install_node_lts
success "Module 03 complete: nvm + Node.js ready"
```

**Step 2: ShellCheck + dry-run test**

Run: `shellcheck scripts/modules/03-nvm-node.sh`
Run: `DRY_RUN=true bash scripts/modules/03-nvm-node.sh`

**Step 3: Commit**

```bash
git add scripts/modules/03-nvm-node.sh
git commit -m "feat: add module 03 — nvm and Node.js LTS"
```

---

## Task 5: Module 04 — PHP-FPM

**Files:**
- Create: `scripts/modules/04-php-fpm.sh`

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
# 04-php-fpm.sh — Install PHP-FPM (single pool per version, Caddy routes)
# Replaces FrankenPHP from original Notion design

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

show_help() {
    cat <<'HELP'
Usage: 04-php-fpm.sh [--dry-run] [--help]

Installs PHP-FPM via phpenv-compiled versions. Each PHP version gets
its own FPM master process listening on a unix socket. Caddy routes
requests to the correct socket based on .php-version.

Sockets:
  PHP 8.3 → /run/php/php8.3-fpm.sock
  PHP 8.2 → /run/php/php8.2-fpm.sock

NOTE: PHP versions must be compiled first via install-versions.sh.
      This module configures FPM pool templates and socket directories.
HELP
}

parse_common_flags "$@" || { show_help; exit 0; }

setup_fpm_directories() {
    info "Creating FPM directories..."

    run sudo mkdir -p /run/php
    run sudo chown "$USER":"$USER" /run/php

    local fpm_conf_dir="$HOME/.phpenv/fpm"
    run mkdir -p "$fpm_conf_dir"

    success "FPM directories created"
}

create_fpm_pool_template() {
    local fpm_conf_dir="$HOME/.phpenv/fpm"
    local template="$fpm_conf_dir/pool-template.conf"

    if [[ -f "$template" ]]; then
        info "FPM pool template already exists — skipping"
        return 0
    fi

    info "Creating FPM pool template..."
    run tee "$template" >/dev/null <<'POOL'
[www]
user = __USER__
group = __USER__
listen = /run/php/php__VERSION__-fpm.sock
listen.owner = __USER__
listen.group = __USER__
listen.mode = 0660

pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
pm.max_requests = 500

; Logging
php_admin_value[error_log] = /home/__USER__/projects/logs/php__VERSION__-fpm-error.log
php_admin_flag[log_errors] = on
POOL
    success "FPM pool template created at $template"
}

create_fpm_launcher() {
    local launcher="$HOME/.phpenv/fpm/start-fpm.sh"

    if [[ -f "$launcher" ]]; then
        info "FPM launcher already exists — skipping"
        return 0
    fi

    info "Creating FPM launcher script..."
    run tee "$launcher" >/dev/null <<'LAUNCHER'
#!/usr/bin/env bash
# start-fpm.sh — Start PHP-FPM for a specific version
# Usage: start-fpm.sh 8.3
set -euo pipefail

VERSION="${1:?Usage: start-fpm.sh <php-version> (e.g. 8.3)}"
PHPENV_ROOT="$HOME/.phpenv"
FPM_DIR="$PHPENV_ROOT/fpm"
TEMPLATE="$FPM_DIR/pool-template.conf"
CONF="$FPM_DIR/php${VERSION}-fpm.conf"
PHP_FPM="$PHPENV_ROOT/versions/${VERSION}/sbin/php-fpm"

if [[ ! -x "$PHP_FPM" ]]; then
    echo "ERROR: php-fpm not found for PHP $VERSION at $PHP_FPM"
    exit 1
fi

# Generate config from template
sed -e "s|__USER__|$USER|g" -e "s|__VERSION__|$VERSION|g" "$TEMPLATE" > "$CONF"

echo "Starting PHP-FPM $VERSION (socket: /run/php/php${VERSION}-fpm.sock)"
exec "$PHP_FPM" --nodaemonize --fpm-config "$CONF"
LAUNCHER
    run chmod +x "$launcher"
    success "FPM launcher created"
}

# Main
assert_not_root
setup_fpm_directories
create_fpm_pool_template
create_fpm_launcher
success "Module 04 complete: PHP-FPM configured (run install-versions.sh to compile PHP)"
```

**Step 2: ShellCheck + dry-run test**

Run: `shellcheck scripts/modules/04-php-fpm.sh`
Run: `DRY_RUN=true bash scripts/modules/04-php-fpm.sh`

**Step 3: Commit**

```bash
git add scripts/modules/04-php-fpm.sh
git commit -m "feat: add module 04 — PHP-FPM pool template and launcher"
```

---

## Task 6: Module 05 — Caddy

**Files:**
- Create: `scripts/modules/05-caddy.sh`

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
# 05-caddy.sh — Install Caddy, configure sites directory and sudoers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

show_help() {
    cat <<'HELP'
Usage: 05-caddy.sh [--dry-run] [--help]

Installs Caddy via apt, creates /etc/caddy/sites/ for per-worktree
config snippets, adds import directive to Caddyfile, and configures
passwordless sudoers for Caddy operations.
HELP
}

parse_common_flags "$@" || { show_help; exit 0; }

install_caddy() {
    if command -v caddy &>/dev/null; then
        info "Caddy already installed — skipping"
        return 0
    fi

    info "Installing Caddy..."
    run sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
    run curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
        sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    run curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
        sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    run sudo apt update
    run sudo apt install -y caddy
    success "Caddy installed"
}

configure_sites_directory() {
    if [[ -d /etc/caddy/sites ]]; then
        info "/etc/caddy/sites/ already exists — skipping"
    else
        info "Creating /etc/caddy/sites/..."
        run sudo mkdir -p /etc/caddy/sites
    fi

    local caddyfile="/etc/caddy/Caddyfile"
    local import_line="import /etc/caddy/sites/*.caddy"

    if grep -q "$import_line" "$caddyfile" 2>/dev/null; then
        info "Import directive already in Caddyfile — skipping"
        return 0
    fi

    info "Adding import directive to Caddyfile..."
    run sudo sh -c "echo '$import_line' >> $caddyfile"
    success "Caddy sites directory configured"
}

configure_sudoers() {
    local sudoers_file="/etc/sudoers.d/caddy-worktrees"

    if [[ -f "$sudoers_file" ]]; then
        info "Caddy sudoers already configured — skipping"
        return 0
    fi

    info "Configuring passwordless sudo for Caddy operations..."
    run sudo tee "$sudoers_file" >/dev/null <<SUDOERS
# Allow worktree manager to reload Caddy and manage site configs
$USER ALL=(ALL) NOPASSWD: /usr/bin/caddy reload *
$USER ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/caddy/sites/*
$USER ALL=(ALL) NOPASSWD: /bin/rm /etc/caddy/sites/*
SUDOERS
    run sudo chmod 0440 "$sudoers_file"
    success "Caddy sudoers configured"
}

enable_caddy_service() {
    info "Enabling Caddy service..."
    run sudo systemctl enable caddy
    run sudo systemctl start caddy
    success "Caddy service enabled"
}

# Main
assert_not_root
install_caddy
configure_sites_directory
configure_sudoers
enable_caddy_service
success "Module 05 complete: Caddy ready with sites directory"
```

**Step 2: ShellCheck + dry-run test**

Run: `shellcheck scripts/modules/05-caddy.sh`
Run: `DRY_RUN=true bash scripts/modules/05-caddy.sh`

**Step 3: Commit**

```bash
git add scripts/modules/05-caddy.sh
git commit -m "feat: add module 05 — Caddy with sites directory and sudoers"
```

---

## Task 7: Module 06 — Supervisor (User-Level)

**Files:**
- Create: `scripts/modules/06-supervisor.sh`

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
# 06-supervisor.sh — Install Supervisor, disable system instance, set up user-level

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

show_help() {
    cat <<'HELP'
Usage: 06-supervisor.sh [--dry-run] [--help]

Installs Supervisor via apt, disables the system-level instance,
and sets up a user-level Supervisor at ~/.config/supervisor/.
HELP
}

parse_common_flags "$@" || { show_help; exit 0; }

SUPERVISOR_DIR="$HOME/.config/supervisor"

install_supervisor() {
    if command -v supervisord &>/dev/null; then
        info "Supervisor already installed — skipping"
    else
        info "Installing Supervisor..."
        run sudo apt install -y supervisor
        success "Supervisor installed"
    fi

    # Disable system instance
    if systemctl is-enabled supervisor &>/dev/null; then
        info "Disabling system-level Supervisor..."
        run sudo systemctl disable --now supervisor
        success "System Supervisor disabled"
    fi
}

setup_user_supervisor() {
    if [[ -f "$SUPERVISOR_DIR/supervisord.conf" ]]; then
        info "User-level Supervisor already configured — skipping"
        return 0
    fi

    info "Setting up user-level Supervisor..."
    run mkdir -p "$SUPERVISOR_DIR"/{conf.d,logs}

    run tee "$SUPERVISOR_DIR/supervisord.conf" >/dev/null <<CONF
[unix_http_server]
file=$SUPERVISOR_DIR/supervisor.sock

[supervisord]
logfile=$SUPERVISOR_DIR/logs/supervisord.log
pidfile=$SUPERVISOR_DIR/supervisord.pid
nodaemon=false

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix://$SUPERVISOR_DIR/supervisor.sock

[include]
files = $SUPERVISOR_DIR/conf.d/*.conf
CONF
    success "User-level Supervisor configured at $SUPERVISOR_DIR"
}

start_user_supervisor() {
    if [[ -S "$SUPERVISOR_DIR/supervisor.sock" ]]; then
        info "User Supervisor already running — skipping"
        return 0
    fi

    info "Starting user-level Supervisor..."
    run supervisord -c "$SUPERVISOR_DIR/supervisord.conf"
    success "User Supervisor started"
}

# Main
assert_not_root
install_supervisor
setup_user_supervisor
start_user_supervisor
success "Module 06 complete: user-level Supervisor ready"
```

**Step 2: ShellCheck + dry-run test**

Run: `shellcheck scripts/modules/06-supervisor.sh`
Run: `DRY_RUN=true bash scripts/modules/06-supervisor.sh`

**Step 3: Commit**

```bash
git add scripts/modules/06-supervisor.sh
git commit -m "feat: add module 06 — user-level Supervisor"
```

---

## Task 8: Module 07 — Tailscale

**Files:**
- Create: `scripts/modules/07-tailscale.sh`

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
# 07-tailscale.sh — Install Tailscale for VPN-based SSH and DB access

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

show_help() {
    cat <<'HELP'
Usage: 07-tailscale.sh [--dry-run] [--help]

Installs Tailscale for secure SSH access and KVM2 database connectivity.
Optionally prompts to authenticate immediately.
HELP
}

parse_common_flags "$@" || { show_help; exit 0; }

install_tailscale() {
    if command -v tailscale &>/dev/null; then
        info "Tailscale already installed — skipping"
        return 0
    fi

    info "Installing Tailscale..."
    run curl -fsSL https://tailscale.com/install.sh | run sh
    success "Tailscale installed"
}

prompt_auth() {
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would prompt for Tailscale authentication"
        return 0
    fi

    echo ""
    echo "Would you like to authenticate Tailscale now? (y/N)"
    read -r answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        info "Starting Tailscale authentication..."
        sudo tailscale up
        success "Tailscale authenticated"
    else
        info "Skipping Tailscale auth. Run 'sudo tailscale up' later."
    fi
}

# Main
assert_not_root
install_tailscale
prompt_auth
success "Module 07 complete: Tailscale ready"
```

**Step 2: ShellCheck + dry-run test**

Run: `shellcheck scripts/modules/07-tailscale.sh`
Run: `DRY_RUN=true bash scripts/modules/07-tailscale.sh`

**Step 3: Commit**

```bash
git add scripts/modules/07-tailscale.sh
git commit -m "feat: add module 07 — Tailscale"
```

---

## Task 9: Module 08 — Claude Code

**Files:**
- Create: `scripts/modules/08-claude-code.sh`

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
# 08-claude-code.sh — Install Claude Code globally

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

show_help() {
    cat <<'HELP'
Usage: 08-claude-code.sh [--dry-run] [--help]

Installs Claude Code globally via npm.
Requires Node.js (installed by module 03).
HELP
}

parse_common_flags "$@" || { show_help; exit 0; }

# Source nvm
export NVM_DIR="$HOME/.nvm"
# shellcheck source=/dev/null
[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"

install_claude_code() {
    if command -v claude &>/dev/null; then
        info "Claude Code already installed — skipping"
        return 0
    fi

    if ! command -v npm &>/dev/null; then
        error "npm not found. Run module 03 (nvm-node) first."
        exit 1
    fi

    info "Installing Claude Code..."
    run npm install -g @anthropic-ai/claude-code
    success "Claude Code installed"
}

# Main
assert_not_root
install_claude_code
success "Module 08 complete: Claude Code ready"
```

**Step 2: ShellCheck + dry-run test**

Run: `shellcheck scripts/modules/08-claude-code.sh`
Run: `DRY_RUN=true bash scripts/modules/08-claude-code.sh`

**Step 3: Commit**

```bash
git add scripts/modules/08-claude-code.sh
git commit -m "feat: add module 08 — Claude Code"
```

---

## Task 10: Module 09 — Claude Relay

**Files:**
- Create: `scripts/modules/09-claude-relay.sh`

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
# 09-claude-relay.sh — Auto-install developer claude-relay instance

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

RELAY_PORT=2633
RELAY_SUBDOMAIN="claude-relay"
DOMAIN="underdev.cloud"
SUPERVISOR_DIR="$HOME/.config/supervisor"

show_help() {
    cat <<'HELP'
Usage: 09-claude-relay.sh [--dry-run] [--help]

Installs claude-relay and sets up a single developer instance:
  - Supervisor process on port 2633
  - Caddy vhost at claude-relay.underdev.cloud
  - Auto-registers all git projects in ~/projects/
  - NO PIN by default (warns user to set one)
HELP
}

parse_common_flags "$@" || { show_help; exit 0; }

# Source nvm
export NVM_DIR="$HOME/.nvm"
# shellcheck source=/dev/null
[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"

install_relay() {
    if command -v claude-relay &>/dev/null || npm list -g claude-relay &>/dev/null 2>&1; then
        info "claude-relay already installed — skipping"
        return 0
    fi

    if ! command -v npm &>/dev/null; then
        error "npm not found. Run module 03 (nvm-node) first."
        exit 1
    fi

    info "Installing claude-relay..."
    run npm install -g claude-relay
    success "claude-relay installed"
}

create_supervisor_config() {
    local conf="$SUPERVISOR_DIR/conf.d/claude-relay.conf"

    if [[ -f "$conf" ]]; then
        info "claude-relay Supervisor config already exists — skipping"
        return 0
    fi

    info "Creating Supervisor config for claude-relay..."
    run mkdir -p "$SUPERVISOR_DIR/conf.d"
    run tee "$conf" >/dev/null <<CONF
[program:claude-relay]
command=npx claude-relay --headless --no-https --port $RELAY_PORT --yes
directory=$HOME
autostart=true
autorestart=true
stdout_logfile=$HOME/projects/logs/claude-relay.log
stderr_logfile=$HOME/projects/logs/claude-relay-error.log
CONF
    success "Supervisor config created"
}

create_caddy_vhost() {
    local vhost="/etc/caddy/sites/${RELAY_SUBDOMAIN}.caddy"

    if [[ -f "$vhost" ]]; then
        info "Caddy vhost for claude-relay already exists — skipping"
        return 0
    fi

    info "Creating Caddy vhost for claude-relay..."
    run sudo tee "$vhost" >/dev/null <<CADDY
${RELAY_SUBDOMAIN}.${DOMAIN} {
    reverse_proxy localhost:${RELAY_PORT}
}
CADDY
    run sudo caddy reload --config /etc/caddy/Caddyfile
    success "Caddy vhost created: ${RELAY_SUBDOMAIN}.${DOMAIN}"
}

register_projects() {
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would register all git projects in ~/projects/"
        return 0
    fi

    info "Registering projects with claude-relay..."
    for project_dir in "$HOME/projects"/*/; do
        if [[ -d "$project_dir/.git" ]]; then
            local project_name
            project_name="$(basename "$project_dir")"
            info "Registering $project_name..."
            npx claude-relay --add "$project_dir" 2>/dev/null || true
        fi
    done
    success "Projects registered"
}

start_relay() {
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would start claude-relay via Supervisor"
        return 0
    fi

    info "Starting claude-relay..."
    supervisorctl -c "$SUPERVISOR_DIR/supervisord.conf" reread
    supervisorctl -c "$SUPERVISOR_DIR/supervisord.conf" update
    success "claude-relay started"
}

print_pin_warning() {
    echo ""
    warn "════════════════════════════════════════════════════════════"
    warn "  Claude Relay is running WITHOUT a PIN!"
    warn "  URL: https://${RELAY_SUBDOMAIN}.${DOMAIN}"
    warn ""
    warn "  To set a PIN, edit the Supervisor config:"
    warn "    vim $SUPERVISOR_DIR/conf.d/claude-relay.conf"
    warn ""
    warn "  Change the command line to include --pin <your-pin>:"
    warn "    command=npx claude-relay --headless --no-https --port $RELAY_PORT --pin 123456 --yes"
    warn ""
    warn "  Then restart:"
    warn "    supervisorctl restart claude-relay"
    warn "════════════════════════════════════════════════════════════"
}

# Main
assert_not_root
install_relay
create_supervisor_config
create_caddy_vhost
start_relay
register_projects
print_pin_warning
success "Module 09 complete: claude-relay running at ${RELAY_SUBDOMAIN}.${DOMAIN}"
```

**Step 2: ShellCheck + dry-run test**

Run: `shellcheck scripts/modules/09-claude-relay.sh`
Run: `DRY_RUN=true bash scripts/modules/09-claude-relay.sh`

**Step 3: Commit**

```bash
git add scripts/modules/09-claude-relay.sh
git commit -m "feat: add module 09 — claude-relay auto-install with PIN warning"
```

---

## Task 11: Module 10 — Project Structure + SQLite Init

**Files:**
- Create: `scripts/modules/10-project-structure.sh`

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
# 10-project-structure.sh — Create ~/projects/ dirs, copy scripts, init SQLite

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

PROJECTS_DIR="$HOME/projects"
DB_PATH="$PROJECTS_DIR/worktrees.db"

show_help() {
    cat <<'HELP'
Usage: 10-project-structure.sh [--dry-run] [--help]

Creates ~/projects/ directory structure, copies worktree management
scripts, and initializes the SQLite database.
HELP
}

parse_common_flags "$@" || { show_help; exit 0; }

create_directories() {
    info "Creating project directories..."
    run mkdir -p "$PROJECTS_DIR"/{scripts,backups,logs}
    success "Directories created"
}

copy_scripts() {
    local src_dir
    src_dir="$(cd "$SCRIPT_DIR/.." && pwd)"

    info "Copying worktree management scripts..."

    local scripts=(
        port-manager.sh
        worktree-cli.sh
        cleanup-worktree.sh
        db-copy-helper.sh
        monitor-resources.sh
        migrate-add-resource-snapshots.sh
        install-versions.sh
        common.sh
    )

    for script in "${scripts[@]}"; do
        if [[ -f "$src_dir/$script" ]]; then
            run cp "$src_dir/$script" "$PROJECTS_DIR/scripts/$script"
            run chmod +x "$PROJECTS_DIR/scripts/$script"
        else
            warn "Script not found: $script — skipping"
        fi
    done

    success "Scripts copied to ~/projects/scripts/"
}

init_database() {
    if [[ -f "$DB_PATH" ]]; then
        info "SQLite database already exists — skipping"
        return 0
    fi

    info "Initializing SQLite database..."
    run sqlite3 "$DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS worktrees (
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

CREATE INDEX IF NOT EXISTS idx_project_branch ON worktrees(project, branch);
CREATE INDEX IF NOT EXISTS idx_status ON worktrees(status);

CREATE TRIGGER IF NOT EXISTS update_timestamp
    AFTER UPDATE ON worktrees
    BEGIN UPDATE worktrees SET updated_at=CURRENT_TIMESTAMP WHERE id=NEW.id; END;

CREATE TABLE IF NOT EXISTS resource_snapshots (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    recorded_at      DATETIME DEFAULT CURRENT_TIMESTAMP,
    ram_used_pct     INTEGER NOT NULL,
    ram_available_mb INTEGER NOT NULL,
    data             JSON
);

CREATE INDEX IF NOT EXISTS idx_snapshots_recorded_at
    ON resource_snapshots(recorded_at);
SQL
    success "SQLite database initialized at $DB_PATH"
}

setup_monitoring_cron() {
    if crontab -l 2>/dev/null | grep -q "monitor-resources.sh"; then
        info "Monitoring cron already configured — skipping"
        return 0
    fi

    info "Setting up monitoring cron (every 5 min)..."
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would add cron: */5 * * * * monitor-resources.sh"
        return 0
    fi

    (crontab -l 2>/dev/null; echo "*/5 * * * * /bin/bash $PROJECTS_DIR/scripts/monitor-resources.sh >> $PROJECTS_DIR/logs/monitor.log 2>&1") | crontab -
    success "Monitoring cron configured"
}

# Main
assert_not_root
create_directories
copy_scripts
init_database
setup_monitoring_cron
success "Module 10 complete: project structure ready"
```

**Step 2: ShellCheck + dry-run test**

Run: `shellcheck scripts/modules/10-project-structure.sh`
Run: `DRY_RUN=true bash scripts/modules/10-project-structure.sh`

**Step 3: Commit**

```bash
git add scripts/modules/10-project-structure.sh
git commit -m "feat: add module 10 — project structure and SQLite init"
```

---

## Task 12: Module 11 — Shell Integration

**Files:**
- Create: `scripts/modules/11-shell-integration.sh`

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
# 11-shell-integration.sh — Add PATH, aliases to ~/.bashrc

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

SUPERVISOR_DIR="$HOME/.config/supervisor"

show_help() {
    cat <<'HELP'
Usage: 11-shell-integration.sh [--dry-run] [--help]

Adds to ~/.bashrc:
  - ~/projects/scripts to PATH
  - `wt` alias for worktree-cli.sh
  - `supervisorctl` alias pointing to user-level config
HELP
}

parse_common_flags "$@" || { show_help; exit 0; }

configure_bashrc() {
    local bashrc="$HOME/.bashrc"
    local marker="# vps-wm:shell-integration"

    if grep -q "$marker" "$bashrc" 2>/dev/null; then
        info "Shell integration already present — skipping"
        return 0
    fi

    info "Adding shell integration to ~/.bashrc..."
    run tee -a "$bashrc" >/dev/null <<EOF

$marker
export PATH="\$HOME/projects/scripts:\$PATH"
alias wt='worktree-cli.sh'
alias supervisorctl='supervisorctl -c $SUPERVISOR_DIR/supervisord.conf'
EOF
    success "Shell integration configured"
}

# Main
assert_not_root
configure_bashrc
success "Module 11 complete: shell integration ready (source ~/.bashrc or open new terminal)"
```

**Step 2: ShellCheck + dry-run test**

Run: `shellcheck scripts/modules/11-shell-integration.sh`
Run: `DRY_RUN=true bash scripts/modules/11-shell-integration.sh`

**Step 3: Commit**

```bash
git add scripts/modules/11-shell-integration.sh
git commit -m "feat: add module 11 — shell integration (PATH, wt alias)"
```

---

## Task 13: port-manager.sh (SQLite Library)

**Files:**
- Create: `scripts/port-manager.sh`

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
# port-manager.sh — SQLite worktree registry library
# Usage: source this file, then call functions directly
# Not meant to be executed standalone

DB_PATH="${DB_PATH:-$HOME/projects/worktrees.db}"
PORT_MIN=8001
PORT_MAX=8999

query() {
    sqlite3 "$DB_PATH" "$1"
}

init_db() {
    sqlite3 "$DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS worktrees (
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
CREATE INDEX IF NOT EXISTS idx_project_branch ON worktrees(project, branch);
CREATE INDEX IF NOT EXISTS idx_status ON worktrees(status);
CREATE TRIGGER IF NOT EXISTS update_timestamp
    AFTER UPDATE ON worktrees
    BEGIN UPDATE worktrees SET updated_at=CURRENT_TIMESTAMP WHERE id=NEW.id; END;
SQL
}

find_next_port() {
    local max_port
    max_port=$(query "SELECT COALESCE(MAX(port), $((PORT_MIN - 1))) FROM worktrees;")

    local next=$((max_port + 1))
    if [[ $next -le $PORT_MAX ]]; then
        echo "$next"
        return 0
    fi

    # Range exhausted — find gaps using recursive CTE
    local gap
    gap=$(query "
        WITH RECURSIVE ports(p) AS (
            SELECT $PORT_MIN
            UNION ALL
            SELECT p+1 FROM ports WHERE p < $PORT_MAX
        )
        SELECT p FROM ports
        WHERE p NOT IN (SELECT port FROM worktrees)
        LIMIT 1;
    ")

    if [[ -n "$gap" ]]; then
        echo "$gap"
        return 0
    fi

    echo "ERROR: No available ports in range $PORT_MIN-$PORT_MAX" >&2
    return 1
}

add_worktree() {
    local project="$1" branch="$2" folder_name="$3" subdomain="$4"
    local pid="${5:-}" db_driver="${6:-}" db_name="${7:-}" db_isolation="${8:-shared}"

    local port
    port=$(find_next_port) || return 1

    query "INSERT INTO worktrees (project, branch, folder_name, port, subdomain, pid, db_driver, db_name, db_isolation)
           VALUES ('$project', '$branch', '$folder_name', $port, '$subdomain', ${pid:-NULL}, ${db_driver:+\"$db_driver\"}, ${db_name:+\"$db_name\"}, '$db_isolation');"

    echo "$port"
}

remove_worktree() {
    local project="$1" branch="$2"
    query "DELETE FROM worktrees WHERE project='$project' AND branch='$branch';"
}

get_port() {
    local project="$1" branch="$2"
    query "SELECT port FROM worktrees WHERE project='$project' AND branch='$branch';"
}

get_pid() {
    local project="$1" branch="$2"
    query "SELECT pid FROM worktrees WHERE project='$project' AND branch='$branch';"
}

get_subdomain() {
    local project="$1" branch="$2"
    query "SELECT subdomain FROM worktrees WHERE project='$project' AND branch='$branch';"
}

get_folder() {
    local project="$1" branch="$2"
    query "SELECT folder_name FROM worktrees WHERE project='$project' AND branch='$branch';"
}

get_db_info() {
    local project="$1" branch="$2"
    query "SELECT db_driver, db_name, db_isolation FROM worktrees WHERE project='$project' AND branch='$branch';"
}

get_worktree_info() {
    local project="$1" branch="$2"
    query -header -column "SELECT * FROM worktrees WHERE project='$project' AND branch='$branch';"
}

mark_stopped() {
    local project="$1" branch="$2"
    query "UPDATE worktrees SET status='stopped', pid=NULL WHERE project='$project' AND branch='$branch';"
}

mark_failed() {
    local project="$1" branch="$2"
    query "UPDATE worktrees SET status='failed' WHERE project='$project' AND branch='$branch';"
}

mark_db_deleted() {
    local project="$1" branch="$2"
    query "UPDATE worktrees SET db_isolation='deleted' WHERE project='$project' AND branch='$branch';"
}

list_active() {
    query -header -column "SELECT project, branch, port, subdomain, status FROM worktrees WHERE status='active' ORDER BY project, branch;"
}

list_all() {
    query -header -column "SELECT project, branch, port, subdomain, status, db_isolation FROM worktrees ORDER BY project, branch;"
}

list_by_project() {
    local project="$1"
    query -header -column "SELECT branch, port, subdomain, status FROM worktrees WHERE project='$project' ORDER BY branch;"
}

check_orphans() {
    local found=0
    while IFS='|' read -r project branch pid; do
        if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
            echo "ORPHAN: $project/$branch (PID $pid is dead)"
            found=1
        fi
    done < <(query "SELECT project, branch, pid FROM worktrees WHERE status='active' AND pid IS NOT NULL;")

    if [[ $found -eq 0 ]]; then
        echo "No orphaned worktrees found."
    fi
}

cleanup_stopped() {
    local count
    count=$(query "SELECT COUNT(*) FROM worktrees WHERE status IN ('stopped','failed');")

    if [[ "$count" -eq 0 ]]; then
        echo "No stopped/failed worktrees to clean up."
        return 0
    fi

    echo "Found $count stopped/failed worktrees:"
    query -header -column "SELECT project, branch, status FROM worktrees WHERE status IN ('stopped','failed');"

    echo ""
    echo "Remove these entries from the database? (y/N)"
    read -r answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        query "DELETE FROM worktrees WHERE status IN ('stopped','failed');"
        echo "Cleaned up $count entries."
    else
        echo "Cancelled."
    fi
}

show_stats() {
    echo "=== Worktree Statistics ==="
    query -header -column "
        SELECT
            COUNT(*) as total,
            SUM(CASE WHEN status='active' THEN 1 ELSE 0 END) as active,
            SUM(CASE WHEN status='stopped' THEN 1 ELSE 0 END) as stopped,
            SUM(CASE WHEN db_isolation='isolated' THEN 1 ELSE 0 END) as isolated_dbs,
            SUM(CASE WHEN db_isolation='shared' THEN 1 ELSE 0 END) as shared_dbs,
            COUNT(DISTINCT project) as projects
        FROM worktrees;
    "

    # RAM trend (if resource_snapshots table exists)
    local has_snapshots
    has_snapshots=$(query "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='resource_snapshots';")

    if [[ "$has_snapshots" -eq 1 ]]; then
        local snapshot_count
        snapshot_count=$(query "SELECT COUNT(*) FROM resource_snapshots WHERE recorded_at > datetime('now', '-1 hour');")

        if [[ "$snapshot_count" -gt 0 ]]; then
            echo ""
            echo "=== RAM (last hour) ==="
            query -header -column "
                SELECT
                    strftime('%H:%M', recorded_at) as time,
                    ram_used_pct || '%' as used,
                    ram_available_mb || 'MB' as free,
                    json_extract(data, '$.cpu_load_1m') as load,
                    json_extract(data, '$.active_worktrees') as wt_count
                FROM resource_snapshots
                WHERE recorded_at > datetime('now', '-1 hour')
                ORDER BY recorded_at;
            "
        fi

        echo ""
        echo "=== RAM Peak (last 24h) ==="
        query -header -column "
            SELECT
                MAX(ram_used_pct) || '%' as peak_ram,
                MIN(ram_available_mb) || 'MB' as lowest_free,
                ROUND(AVG(ram_used_pct)) || '%' as avg_ram,
                COUNT(*) as snapshots,
                SUM(CASE WHEN ram_used_pct >= 90 THEN 1 ELSE 0 END) as critical_events,
                SUM(CASE WHEN ram_used_pct >= 80 AND ram_used_pct < 90 THEN 1 ELSE 0 END) as warn_events
            FROM resource_snapshots
            WHERE recorded_at > datetime('now', '-24 hours');
        "
    fi
}

show_oldest() {
    query -header -column "
        SELECT project, branch, created_at,
            ROUND((julianday('now') - julianday(created_at)) * 24, 1) as age_hours
        FROM worktrees
        WHERE status='active'
        ORDER BY created_at ASC
        LIMIT 1;
    "
}

search_worktrees() {
    local term="$1"
    query -header -column "
        SELECT project, branch, port, subdomain, status
        FROM worktrees
        WHERE project LIKE '%$term%' OR branch LIKE '%$term%' OR subdomain LIKE '%$term%'
        ORDER BY project, branch;
    "
}

export_csv() {
    local file="${1:-worktrees-export.csv}"
    query -header -csv "SELECT * FROM worktrees;" > "$file"
    echo "Exported to $file"
}

backup_db() {
    local backup_dir="${1:-$HOME/projects/backups}"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="$backup_dir/worktrees-${timestamp}.db"
    cp "$DB_PATH" "$backup_file"
    echo "Backup saved to $backup_file"
}

optimize_db() {
    query "VACUUM;"
    query "ANALYZE;"
    echo "Database optimized."
}
```

**Step 2: ShellCheck**

Run: `shellcheck scripts/port-manager.sh`
Expected: No warnings

**Step 3: Commit**

```bash
git add scripts/port-manager.sh
git commit -m "feat: add port-manager.sh — SQLite worktree registry library"
```

---

## Task 14: worktree-cli.sh (`wt` Command)

**Files:**
- Create: `scripts/worktree-cli.sh`

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
# worktree-cli.sh — CLI wrapper for port-manager.sh
# Aliased as `wt` via shell integration

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/port-manager.sh"

show_help() {
    cat <<'HELP'
Usage: wt <command> [args]

Commands:
  list                     List active worktrees
  list-all                 List all worktrees (including stopped/failed)
  list-project <project>   List worktrees for a specific project
  info <project> <branch>  Show detailed info for a worktree
  search <term>            Search worktrees by project/branch/subdomain
  check                    Find orphaned processes
  cleanup                  Remove stopped/failed entries (interactive)
  stats                    Show statistics and RAM trend
  oldest                   Show the oldest active worktree
  export [file]            Export all data to CSV
  backup [dir]             Backup database
  optimize                 Run VACUUM and ANALYZE on database
  init                     Initialize/reset the database schema
  help                     Show this help message
HELP
}

case "${1:-help}" in
    list)           list_active ;;
    list-all)       list_all ;;
    list-project)   list_by_project "${2:?Usage: wt list-project <project>}" ;;
    info)           get_worktree_info "${2:?Usage: wt info <project> <branch>}" "${3:?Usage: wt info <project> <branch>}" ;;
    search)         search_worktrees "${2:?Usage: wt search <term>}" ;;
    check)          check_orphans ;;
    cleanup)        cleanup_stopped ;;
    stats)          show_stats ;;
    oldest)         show_oldest ;;
    export)         export_csv "${2:-}" ;;
    backup)         backup_db "${2:-}" ;;
    optimize)       optimize_db ;;
    init)           init_db ;;
    help|--help|-h) show_help ;;
    *)              echo "Unknown command: $1"; show_help; exit 1 ;;
esac
```

**Step 2: ShellCheck**

Run: `shellcheck scripts/worktree-cli.sh`

**Step 3: Commit**

```bash
git add scripts/worktree-cli.sh
git commit -m "feat: add worktree-cli.sh — wt command wrapper"
```

---

## Task 15: db-copy-helper.sh

**Files:**
- Create: `scripts/db-copy-helper.sh`

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
# db-copy-helper.sh — Universal database copy utility
# Exit codes: 0=success, 1=failure, 10=no CREATE privilege

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

show_help() {
    cat <<'HELP'
Usage: db-copy-helper.sh <source-env-file> <target-db-name> [--dry-run] [--help]

Reads database credentials from a .env file, auto-detects the engine,
and creates a copy of the database with the given target name.

Supported engines: mysql, pgsql, sqlite, sqlsrv

Exit codes:
  0  — Success
  1  — General failure
  10 — No CREATE DATABASE privilege
HELP
}

for arg in "$@"; do
    case "$arg" in
        --help) show_help; exit 0 ;;
        --dry-run) DRY_RUN=true ;;
    esac
done

SOURCE_ENV="${1:?Usage: db-copy-helper.sh <source-env-file> <target-db-name>}"
TARGET_DB="${2:?Usage: db-copy-helper.sh <source-env-file> <target-db-name>}"

# Read .env file
read_env() {
    local env_file="$1"
    if [[ ! -f "$env_file" ]]; then
        error ".env file not found: $env_file"
        exit 1
    fi

    DB_CONNECTION=$(grep -E '^DB_CONNECTION=' "$env_file" | cut -d= -f2 | tr -d '"' | tr -d "'")
    DB_HOST=$(grep -E '^DB_HOST=' "$env_file" | cut -d= -f2 | tr -d '"' | tr -d "'")
    DB_PORT=$(grep -E '^DB_PORT=' "$env_file" | cut -d= -f2 | tr -d '"' | tr -d "'")
    DB_DATABASE=$(grep -E '^DB_DATABASE=' "$env_file" | cut -d= -f2 | tr -d '"' | tr -d "'")
    DB_USERNAME=$(grep -E '^DB_USERNAME=' "$env_file" | cut -d= -f2 | tr -d '"' | tr -d "'")
    DB_PASSWORD=$(grep -E '^DB_PASSWORD=' "$env_file" | cut -d= -f2 | tr -d '"' | tr -d "'")

    # Admin credentials (optional, for CREATE DATABASE)
    DB_ADMIN_USERNAME=$(grep -E '^DB_ADMIN_USERNAME=' "$env_file" | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
    DB_ADMIN_PASSWORD=$(grep -E '^DB_ADMIN_PASSWORD=' "$env_file" | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
}

check_client() {
    case "$DB_CONNECTION" in
        mysql)  command -v mysql    &>/dev/null || { error "MySQL client not found. Run module 01."; exit 1; } ;;
        pgsql)  command -v psql     &>/dev/null || { error "psql not found. Run module 01."; exit 1; } ;;
        sqlite) command -v sqlite3  &>/dev/null || { error "sqlite3 not found. Run module 01."; exit 1; } ;;
        sqlsrv) command -v sqlcmd   &>/dev/null || { error "sqlcmd not found. Run module 01."; exit 1; } ;;
        *)      error "Unsupported DB_CONNECTION: $DB_CONNECTION"; exit 1 ;;
    esac
}

copy_mysql() {
    local admin_user="${DB_ADMIN_USERNAME:-$DB_USERNAME}"
    local admin_pass="${DB_ADMIN_PASSWORD:-$DB_PASSWORD}"

    info "Creating MySQL database: $TARGET_DB"
    if ! run mysql -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$admin_user" -p"$admin_pass" \
        -e "CREATE DATABASE \`$TARGET_DB\`;" 2>/dev/null; then
        error "Failed to create database. Check admin credentials."
        exit 10
    fi

    info "Copying data from $DB_DATABASE to $TARGET_DB..."
    run bash -c "mysqldump -h '$DB_HOST' -P '${DB_PORT:-3306}' -u '$DB_USERNAME' -p'$DB_PASSWORD' '$DB_DATABASE' | mysql -h '$DB_HOST' -P '${DB_PORT:-3306}' -u '$admin_user' -p'$admin_pass' '$TARGET_DB'"
    success "MySQL database copied: $TARGET_DB"
}

copy_pgsql() {
    local admin_user="${DB_ADMIN_USERNAME:-$DB_USERNAME}"

    info "Creating PostgreSQL database: $TARGET_DB"
    if ! run PGPASSWORD="${DB_ADMIN_PASSWORD:-$DB_PASSWORD}" createdb \
        -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$admin_user" \
        -T "$DB_DATABASE" "$TARGET_DB" 2>/dev/null; then
        error "Failed to create database. Check admin credentials."
        exit 10
    fi

    success "PostgreSQL database copied: $TARGET_DB (template clone)"
}

copy_sqlite() {
    local source_path="$DB_DATABASE"
    local target_path
    target_path="$(dirname "$source_path")/$TARGET_DB.sqlite"

    if [[ ! -f "$source_path" ]]; then
        error "SQLite file not found: $source_path"
        exit 1
    fi

    info "Copying SQLite database..."
    run cp "$source_path" "$target_path"
    success "SQLite database copied: $target_path"
}

copy_sqlsrv() {
    local admin_user="${DB_ADMIN_USERNAME:-$DB_USERNAME}"
    local admin_pass="${DB_ADMIN_PASSWORD:-$DB_PASSWORD}"

    info "Creating SQL Server database: $TARGET_DB"
    if ! run sqlcmd -S "$DB_HOST,${DB_PORT:-1433}" -U "$admin_user" -P "$admin_pass" \
        -Q "CREATE DATABASE [$TARGET_DB];" 2>/dev/null; then
        error "Failed to create database. Check admin credentials."
        exit 10
    fi

    info "Backing up and restoring..."
    local backup_file="/tmp/${DB_DATABASE}_backup.bak"
    run sqlcmd -S "$DB_HOST,${DB_PORT:-1433}" -U "$admin_user" -P "$admin_pass" \
        -Q "BACKUP DATABASE [$DB_DATABASE] TO DISK='$backup_file';"
    run sqlcmd -S "$DB_HOST,${DB_PORT:-1433}" -U "$admin_user" -P "$admin_pass" \
        -Q "RESTORE DATABASE [$TARGET_DB] FROM DISK='$backup_file' WITH MOVE '$DB_DATABASE' TO '/var/opt/mssql/data/${TARGET_DB}.mdf', MOVE '${DB_DATABASE}_log' TO '/var/opt/mssql/data/${TARGET_DB}_log.ldf';"
    rm -f "$backup_file"
    success "SQL Server database copied: $TARGET_DB"
}

# Main
read_env "$SOURCE_ENV"
check_client

case "$DB_CONNECTION" in
    mysql)  copy_mysql ;;
    pgsql)  copy_pgsql ;;
    sqlite) copy_sqlite ;;
    sqlsrv) copy_sqlsrv ;;
esac
```

**Step 2: ShellCheck + dry-run test**

Run: `shellcheck scripts/db-copy-helper.sh`
Run: `DRY_RUN=true bash scripts/db-copy-helper.sh --help`

**Step 3: Commit**

```bash
git add scripts/db-copy-helper.sh
git commit -m "feat: add db-copy-helper.sh — universal database copy utility"
```

---

## Task 16: cleanup-worktree.sh

**Files:**
- Create: `scripts/cleanup-worktree.sh`

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
# cleanup-worktree.sh — Full worktree teardown

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/port-manager.sh"

SUPERVISOR_DIR="$HOME/.config/supervisor"

show_help() {
    cat <<'HELP'
Usage: cleanup-worktree.sh <project> <branch> [--dry-run] [--help]

Full worktree teardown:
  1. Remove Caddy config + reload
  2. Drop database (if isolated)
  3. Remove git worktree
  4. Remove from SQLite registry
  5. Stop Supervisor process (if exists)
HELP
}

for arg in "$@"; do
    case "$arg" in
        --help) show_help; exit 0 ;;
        --dry-run) DRY_RUN=true ;;
    esac
done

PROJECT="${1:?Usage: cleanup-worktree.sh <project> <branch>}"
BRANCH="${2:?Usage: cleanup-worktree.sh <project> <branch>}"

# Get worktree info from SQLite
FOLDER=$(get_folder "$PROJECT" "$BRANCH")
SUBDOMAIN=$(get_subdomain "$PROJECT" "$BRANCH")
PORT=$(get_port "$PROJECT" "$BRANCH")

if [[ -z "$FOLDER" ]]; then
    error "Worktree not found: $PROJECT/$BRANCH"
    exit 1
fi

info "Cleaning up worktree: $PROJECT/$BRANCH (port $PORT)"

# Step 1: Remove Caddy config
remove_caddy_config() {
    local vhost="/etc/caddy/sites/${SUBDOMAIN}.caddy"

    if [[ -f "$vhost" ]]; then
        info "Removing Caddy config..."
        run sudo rm "$vhost"
        run sudo caddy reload --config /etc/caddy/Caddyfile
        success "Caddy config removed"
    else
        info "No Caddy config found — skipping"
    fi
}

# Step 2: Drop database (if isolated)
drop_database() {
    local db_info
    db_info=$(get_db_info "$PROJECT" "$BRANCH")

    local db_driver db_name db_isolation
    IFS='|' read -r db_driver db_name db_isolation <<< "$db_info"

    if [[ "$db_isolation" != "isolated" ]]; then
        info "Database is $db_isolation — skipping drop"
        return 0
    fi

    info "Dropping isolated database: $db_name ($db_driver)..."
    local project_dir="$HOME/projects/$PROJECT"
    local env_file="$project_dir/.env"

    case "$db_driver" in
        mysql)
            local db_host db_port db_user db_pass
            db_host=$(grep -E '^DB_HOST=' "$env_file" | cut -d= -f2 | tr -d '"' | tr -d "'")
            db_port=$(grep -E '^DB_PORT=' "$env_file" | cut -d= -f2 | tr -d '"' | tr -d "'")
            db_user=$(grep -E '^DB_ADMIN_USERNAME=' "$env_file" | cut -d= -f2 | tr -d '"' | tr -d "'" || grep -E '^DB_USERNAME=' "$env_file" | cut -d= -f2 | tr -d '"' | tr -d "'")
            db_pass=$(grep -E '^DB_ADMIN_PASSWORD=' "$env_file" | cut -d= -f2 | tr -d '"' | tr -d "'" || grep -E '^DB_PASSWORD=' "$env_file" | cut -d= -f2 | tr -d '"' | tr -d "'")
            run mysql -h "$db_host" -P "${db_port:-3306}" -u "$db_user" -p"$db_pass" -e "DROP DATABASE IF EXISTS \`$db_name\`;"
            ;;
        pgsql)
            local db_host db_port db_user db_pass
            db_host=$(grep -E '^DB_HOST=' "$env_file" | cut -d= -f2 | tr -d '"' | tr -d "'")
            db_port=$(grep -E '^DB_PORT=' "$env_file" | cut -d= -f2 | tr -d '"' | tr -d "'")
            db_user=$(grep -E '^DB_ADMIN_USERNAME=' "$env_file" | cut -d= -f2 | tr -d '"' | tr -d "'" || grep -E '^DB_USERNAME=' "$env_file" | cut -d= -f2 | tr -d '"' | tr -d "'")
            db_pass=$(grep -E '^DB_ADMIN_PASSWORD=' "$env_file" | cut -d= -f2 | tr -d '"' | tr -d "'" || grep -E '^DB_PASSWORD=' "$env_file" | cut -d= -f2 | tr -d '"' | tr -d "'")
            run PGPASSWORD="$db_pass" dropdb -h "$db_host" -p "${db_port:-5432}" -U "$db_user" "$db_name" --if-exists
            ;;
        sqlite)
            run rm -f "$db_name"
            ;;
    esac

    mark_db_deleted "$PROJECT" "$BRANCH"
    success "Database dropped: $db_name"
}

# Step 3: Remove git worktree
remove_git_worktree() {
    local worktree_path="$HOME/projects/$PROJECT/.worktrees/$FOLDER"

    if [[ -d "$worktree_path" ]]; then
        info "Removing git worktree..."
        run git -C "$HOME/projects/$PROJECT" worktree remove "$worktree_path" --force 2>/dev/null || {
            warn "git worktree remove failed, falling back to rm + prune"
            run rm -rf "$worktree_path"
            run git -C "$HOME/projects/$PROJECT" worktree prune
        }
        success "Git worktree removed"
    else
        info "Worktree directory not found — skipping"
    fi
}

# Step 4: Remove from SQLite
remove_registry() {
    info "Removing from SQLite registry..."
    remove_worktree "$PROJECT" "$BRANCH"
    success "Registry entry removed"
}

# Step 5: Stop Supervisor process (if exists)
stop_supervisor_process() {
    local process_name="${FOLDER}-${PROJECT}"
    local conf="$SUPERVISOR_DIR/conf.d/${process_name}.conf"

    if [[ -f "$conf" ]]; then
        info "Stopping Supervisor process: $process_name..."
        run supervisorctl -c "$SUPERVISOR_DIR/supervisord.conf" stop "$process_name" 2>/dev/null || true
        run rm "$conf"
        run supervisorctl -c "$SUPERVISOR_DIR/supervisord.conf" reread
        run supervisorctl -c "$SUPERVISOR_DIR/supervisord.conf" update
        success "Supervisor process stopped and config removed"
    fi
}

# Execute cleanup
remove_caddy_config
drop_database
remove_git_worktree
remove_registry
stop_supervisor_process

success "Worktree $PROJECT/$BRANCH fully cleaned up"
```

**Step 2: ShellCheck + dry-run test**

Run: `shellcheck scripts/cleanup-worktree.sh`
Run: `bash scripts/cleanup-worktree.sh --help`

**Step 3: Commit**

```bash
git add scripts/cleanup-worktree.sh
git commit -m "feat: add cleanup-worktree.sh — full worktree teardown"
```

---

## Task 17: init-worktree-template.sh

**Files:**
- Create: `examples/init-worktree-template.sh`

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
# init-worktree-template.sh — Per-project worktree initialization template
# Copy this to your project and set PROJECT variable below.

set -euo pipefail

##############################
# CUSTOMIZE THIS PER PROJECT #
##############################
PROJECT="my-project"
DOMAIN="underdev.cloud"
##############################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECTS_DIR="$HOME/projects"
SCRIPTS_DIR="$PROJECTS_DIR/scripts"
SUPERVISOR_DIR="$HOME/.config/supervisor"

# Source shared libraries
source "$SCRIPTS_DIR/common.sh"
source "$SCRIPTS_DIR/port-manager.sh"

show_help() {
    cat <<HELP
Usage: init-worktree-template.sh <branch-name> [--dry-run] [--help]

Creates a new worktree for $PROJECT:
  1. Git worktree at .worktrees/{folder}/
  2. PHP/Node version detection
  3. Environment + Claude settings copy
  4. Database strategy (shared vs copy)
  5. Dependency install + asset build
  6. Caddy vhost + SQLite registration

Environment variables:
  DB_COPY_STRATEGY=shared|copy   Skip interactive database prompt
HELP
}

for arg in "$@"; do
    case "$arg" in
        --help) show_help; exit 0 ;;
        --dry-run) DRY_RUN=true ;;
    esac
done

BRANCH="${1:?Usage: init-worktree-template.sh <branch-name>}"

# Sanitize branch name for folder: feature/auth → feat-auth
FOLDER=$(echo "$BRANCH" | sed 's|/|-|g' | sed 's|feature|feat|g')
SUBDOMAIN="${FOLDER}-${PROJECT}"
PROJECT_DIR="$PROJECTS_DIR/$PROJECT"
WORKTREE_DIR="$PROJECT_DIR/.worktrees/$FOLDER"

if [[ -d "$WORKTREE_DIR" ]]; then
    error "Worktree already exists: $WORKTREE_DIR"
    exit 1
fi

info "Creating worktree: $PROJECT/$BRANCH → $FOLDER"

# Step 1: Create git worktree
create_worktree() {
    info "Creating git worktree..."
    run mkdir -p "$PROJECT_DIR/.worktrees"
    run git -C "$PROJECT_DIR" worktree add "$WORKTREE_DIR" -b "$BRANCH" 2>/dev/null || \
        run git -C "$PROJECT_DIR" worktree add "$WORKTREE_DIR" "$BRANCH"
    success "Git worktree created"
}

# Step 2: Detect and set versions
setup_versions() {
    # PHP version
    if [[ -f "$PROJECT_DIR/.php-version" ]]; then
        run cp "$PROJECT_DIR/.php-version" "$WORKTREE_DIR/.php-version"
        local php_version
        php_version=$(cat "$WORKTREE_DIR/.php-version")
        info "PHP version: $php_version"

        # Activate phpenv version
        if command -v phpenv &>/dev/null; then
            export PHPENV_VERSION="$php_version"
        fi
    fi

    # Node version
    if [[ -f "$PROJECT_DIR/.nvmrc" ]]; then
        run cp "$PROJECT_DIR/.nvmrc" "$WORKTREE_DIR/.nvmrc"
        local node_version
        node_version=$(cat "$WORKTREE_DIR/.nvmrc")
        info "Node version: $node_version"

        # Activate nvm version
        export NVM_DIR="$HOME/.nvm"
        # shellcheck source=/dev/null
        [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"
        nvm use "$node_version" 2>/dev/null || nvm install "$node_version"
    fi
}

# Step 3: Copy environment files
copy_env() {
    if [[ -f "$PROJECT_DIR/.env" ]]; then
        info "Copying .env..."
        run cp "$PROJECT_DIR/.env" "$WORKTREE_DIR/.env"
        success ".env copied"
    else
        warn "No .env found in main checkout"
    fi

    # Copy Claude settings
    if [[ -d "$PROJECT_DIR/.claude" ]]; then
        info "Copying .claude/ settings..."
        run cp -r "$PROJECT_DIR/.claude" "$WORKTREE_DIR/.claude"
        success "Claude settings copied"
    fi
}

# Step 4: Database strategy
setup_database() {
    local strategy="${DB_COPY_STRATEGY:-}"
    local db_driver db_name db_isolation

    # Read DB driver from .env
    db_driver=$(grep -E '^DB_CONNECTION=' "$WORKTREE_DIR/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" || echo "")

    if [[ -z "$db_driver" ]]; then
        info "No DB_CONNECTION found — skipping database setup"
        db_isolation="none"
        echo "$db_driver" "$db_name" "$db_isolation"
        return 0
    fi

    # Interactive prompt if strategy not set
    if [[ -z "$strategy" ]]; then
        echo ""
        echo "Database strategy for this worktree?"
        echo "  [1] Shared — Use main database (fast, no isolation)"
        echo "  [2] Copy  — Isolated database (safe for migrations)"
        echo ""
        read -rp "Choice [1]: " choice
        strategy=$([[ "$choice" == "2" ]] && echo "copy" || echo "shared")
    fi

    if [[ "$strategy" == "copy" ]]; then
        local source_db
        source_db=$(grep -E '^DB_DATABASE=' "$WORKTREE_DIR/.env" | cut -d= -f2 | tr -d '"' | tr -d "'")
        local target_db="${source_db}_${FOLDER}"

        info "Copying database: $source_db → $target_db"
        if bash "$SCRIPTS_DIR/db-copy-helper.sh" "$WORKTREE_DIR/.env" "$target_db"; then
            # Update .env with new database name
            sed -i "s|^DB_DATABASE=.*|DB_DATABASE=$target_db|" "$WORKTREE_DIR/.env"
            db_name="$target_db"
            db_isolation="isolated"
            success "Isolated database created: $target_db"
        else
            local exit_code=$?
            if [[ $exit_code -eq 10 ]]; then
                warn "Database copy failed (no admin credentials)."
                echo ""
                echo "How to proceed?"
                echo "  [1] Use shared database instead"
                echo "  [2] Create worktree anyway, fix database later"
                echo ""
                read -rp "Choice [2]: " fallback
                db_isolation="shared"
                if [[ "$fallback" == "1" ]]; then
                    info "Using shared database"
                else
                    info "Continuing without database setup — fix later"
                fi
            else
                error "Database copy failed"
                db_isolation="shared"
            fi
        fi
    else
        info "Using shared database"
        db_isolation="shared"
    fi

    # Export for later use
    DB_DRIVER="$db_driver"
    DB_NAME="${db_name:-}"
    DB_ISOLATION="$db_isolation"
}

# Step 5: Install dependencies
install_deps() {
    cd "$WORKTREE_DIR"

    if [[ -f "composer.json" ]]; then
        info "Running composer install..."
        run composer install --no-interaction --prefer-dist
    fi

    if [[ -f "package.json" ]]; then
        info "Running npm install..."
        run npm install

        if grep -q '"build"' package.json 2>/dev/null; then
            info "Building assets..."
            run npm run build
        fi
    fi

    # Laravel-specific
    if [[ -f "artisan" ]]; then
        info "Running Laravel setup..."
        run php artisan key:generate --force 2>/dev/null || true
        run php artisan config:clear 2>/dev/null || true
    fi

    success "Dependencies installed"
}

# Step 6: Allocate port and register
register_worktree() {
    info "Allocating port..."
    local port
    port=$(add_worktree "$PROJECT" "$BRANCH" "$FOLDER" "$SUBDOMAIN" "" "${DB_DRIVER:-}" "${DB_NAME:-}" "${DB_ISOLATION:-shared}")
    info "Port allocated: $port"

    # Detect PHP version for FPM socket
    local php_version
    php_version=$(cat "$WORKTREE_DIR/.php-version" 2>/dev/null || echo "8.3")
    local fpm_socket="/run/php/php${php_version}-fpm.sock"

    # Create Caddy vhost
    local vhost="/etc/caddy/sites/${SUBDOMAIN}.caddy"
    info "Creating Caddy vhost: ${SUBDOMAIN}.${DOMAIN}"
    run sudo tee "$vhost" >/dev/null <<CADDY
${SUBDOMAIN}.${DOMAIN} {
    root * ${WORKTREE_DIR}/public
    php_fastcgi unix/${fpm_socket}
    file_server
}
CADDY

    info "Reloading Caddy..."
    run sudo caddy reload --config /etc/caddy/Caddyfile

    success "Worktree registered and accessible"

    echo ""
    success "═══════════════════════════════════════════════"
    success "  Worktree ready!"
    success "  URL: https://${SUBDOMAIN}.${DOMAIN}"
    success "  Port: $port"
    success "  Path: $WORKTREE_DIR"
    success "═══════════════════════════════════════════════"
}

# Execute all steps
create_worktree
setup_versions
copy_env
setup_database
install_deps
register_worktree
```

**Step 2: ShellCheck + dry-run test**

Run: `shellcheck examples/init-worktree-template.sh`
Run: `bash examples/init-worktree-template.sh --help`

**Step 3: Commit**

```bash
git add examples/init-worktree-template.sh
git commit -m "feat: add init-worktree-template.sh — per-project worktree init"
```

---

## Task 18: Monitoring Scripts

**Files:**
- Create: `scripts/monitor-resources.sh`
- Create: `scripts/migrate-add-resource-snapshots.sh`

**Step 1: Write monitor-resources.sh**

```bash
#!/usr/bin/env bash
# monitor-resources.sh — Record RAM/CPU/disk snapshots and alert via Discord

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

DB_PATH="$HOME/projects/worktrees.db"
ENV_FILE="$HOME/projects/.env"
COOLDOWN_DIR="$HOME/projects/logs"

show_help() {
    cat <<'HELP'
Usage: monitor-resources.sh [--status] [--test] [--dry-run] [--help]

Modes:
  (default)   Record snapshot + alert if threshold breached (cron mode)
  --status    Show last 10 snapshots + 1hr trend
  --test      Force send a test Discord alert

Config (~/projects/.env):
  DISCORD_WEBHOOK=https://discord.com/api/webhooks/...
  RAM_WARN_PCT=80
  RAM_CRIT_PCT=90
HELP
}

MODE="record"
for arg in "$@"; do
    case "$arg" in
        --help)    show_help; exit 0 ;;
        --dry-run) DRY_RUN=true ;;
        --status)  MODE="status" ;;
        --test)    MODE="test" ;;
    esac
done

# Load config
load_config() {
    if [[ -f "$ENV_FILE" ]]; then
        DISCORD_WEBHOOK=$(grep -E '^DISCORD_WEBHOOK=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d "'" || echo "")
        RAM_WARN_PCT=$(grep -E '^RAM_WARN_PCT=' "$ENV_FILE" | cut -d= -f2 | tr -d '"' | tr -d "'" || echo "80")
        RAM_CRIT_PCT=$(grep -E '^RAM_CRIT_PCT=' "$ENV_FILE" | cut -d= -f2 | tr -d '"' | tr -d "'" || echo "90")
    else
        DISCORD_WEBHOOK=""
        RAM_WARN_PCT=80
        RAM_CRIT_PCT=90
    fi
}

# Collect system metrics
collect_metrics() {
    RAM_TOTAL=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    RAM_AVAILABLE=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)
    RAM_USED=$((RAM_TOTAL - RAM_AVAILABLE))
    RAM_PCT=$((RAM_USED * 100 / RAM_TOTAL))
    CPU_LOAD=$(awk '{print $1}' /proc/loadavg)
    DISK_PCT=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}')

    # Active worktrees
    ACTIVE_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM worktrees WHERE status='active';" 2>/dev/null || echo "0")
    WORKTREE_LIST=$(sqlite3 "$DB_PATH" "SELECT project || '/' || branch || ':' || port FROM worktrees WHERE status='active';" 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
}

# Record snapshot to SQLite
record_snapshot() {
    local json_data
    json_data=$(cat <<JSON
{"cpu_load_1m": $CPU_LOAD, "disk_used_pct": $DISK_PCT, "ram_total_mb": $RAM_TOTAL, "ram_used_mb": $RAM_USED, "active_worktrees": $ACTIVE_COUNT, "worktree_list": "$WORKTREE_LIST"}
JSON
    )

    sqlite3 "$DB_PATH" "INSERT INTO resource_snapshots (ram_used_pct, ram_available_mb, data) VALUES ($RAM_PCT, $RAM_AVAILABLE, '$json_data');"
}

# Send Discord alert
send_alert() {
    local level="$1" color="$2" message="$3"

    if [[ -z "$DISCORD_WEBHOOK" ]]; then
        warn "No DISCORD_WEBHOOK configured — skipping alert"
        return 0
    fi

    # Check cooldown (30 minutes)
    local cooldown_file="$COOLDOWN_DIR/.last_alert_${level}"
    if [[ -f "$cooldown_file" ]]; then
        local last_alert
        last_alert=$(cat "$cooldown_file")
        local now
        now=$(date +%s)
        local diff=$((now - last_alert))
        if [[ $diff -lt 1800 ]]; then
            return 0  # Still in cooldown
        fi
    fi

    local payload
    payload=$(cat <<JSON
{
    "embeds": [{
        "title": "$message",
        "description": "RAM: ${RAM_PCT}% used (${RAM_AVAILABLE}MB free) | Load: ${CPU_LOAD} | Disk: ${DISK_PCT}%\nActive worktrees: \`${WORKTREE_LIST:-none}\`\n\nRun \`wt list\` to see active worktrees.",
        "color": $color
    }]
}
JSON
    )

    run curl -s -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK"
    date +%s > "$cooldown_file"
}

# Check thresholds and alert
check_thresholds() {
    if [[ "$RAM_PCT" -ge "$RAM_CRIT_PCT" ]]; then
        send_alert "crit" "16711680" "🚨 KVM1 RAM CRITICAL — RAM at ${RAM_PCT}%"
    elif [[ "$RAM_PCT" -ge "$RAM_WARN_PCT" ]]; then
        send_alert "warn" "16776960" "⚠️ KVM1 RAM Alert — RAM at ${RAM_PCT}% — approaching limit"
    fi
}

# Show status
show_status() {
    echo "=== Last 10 Snapshots ==="
    sqlite3 -header -column "$DB_PATH" "
        SELECT strftime('%Y-%m-%d %H:%M', recorded_at) as time,
               ram_used_pct || '%' as ram,
               ram_available_mb || 'MB' as free,
               json_extract(data, '$.cpu_load_1m') as load,
               json_extract(data, '$.active_worktrees') as wts
        FROM resource_snapshots
        ORDER BY recorded_at DESC
        LIMIT 10;
    "

    echo ""
    echo "=== 1hr Trend ==="
    sqlite3 -header -column "$DB_PATH" "
        SELECT strftime('%H:%M', recorded_at) as time,
               ram_used_pct || '%' as used,
               ram_available_mb || 'MB' as free
        FROM resource_snapshots
        WHERE recorded_at > datetime('now', '-1 hour')
        ORDER BY recorded_at;
    "
}

# Test alert
test_alert() {
    collect_metrics
    info "Sending test alert to Discord..."
    DISCORD_WEBHOOK="${DISCORD_WEBHOOK:?Set DISCORD_WEBHOOK in ~/projects/.env}"

    local payload
    payload=$(cat <<JSON
{
    "embeds": [{
        "title": "🧪 KVM1 Test Alert — This is a test",
        "description": "RAM: ${RAM_PCT}% used (${RAM_AVAILABLE}MB free) | Load: ${CPU_LOAD} | Disk: ${DISK_PCT}%\nActive worktrees: \`${WORKTREE_LIST:-none}\`",
        "color": 3447003
    }]
}
JSON
    )

    curl -s -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK"
    success "Test alert sent"
}

# Main
load_config

case "$MODE" in
    record)
        collect_metrics
        record_snapshot
        check_thresholds
        ;;
    status)
        show_status
        ;;
    test)
        test_alert
        ;;
esac
```

**Step 2: Write migrate-add-resource-snapshots.sh**

```bash
#!/usr/bin/env bash
# migrate-add-resource-snapshots.sh — Add resource_snapshots table to existing DB

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

DB_PATH="${DB_PATH:-$HOME/projects/worktrees.db}"

show_help() {
    cat <<'HELP'
Usage: migrate-add-resource-snapshots.sh [--dry-run] [--help]

Adds the resource_snapshots table to an existing worktrees.db.
Safe to re-run (uses CREATE TABLE IF NOT EXISTS).
HELP
}

parse_common_flags "$@" || { show_help; exit 0; }

if [[ ! -f "$DB_PATH" ]]; then
    error "Database not found: $DB_PATH"
    exit 1
fi

info "Running migration on $DB_PATH..."
run sqlite3 "$DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS resource_snapshots (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    recorded_at      DATETIME DEFAULT CURRENT_TIMESTAMP,
    ram_used_pct     INTEGER NOT NULL,
    ram_available_mb INTEGER NOT NULL,
    data             JSON
);

CREATE INDEX IF NOT EXISTS idx_snapshots_recorded_at
    ON resource_snapshots(recorded_at);
SQL

success "Migration complete: resource_snapshots table ready"
```

**Step 3: ShellCheck both**

Run: `shellcheck scripts/monitor-resources.sh scripts/migrate-add-resource-snapshots.sh`

**Step 4: Commit**

```bash
git add scripts/monitor-resources.sh scripts/migrate-add-resource-snapshots.sh
git commit -m "feat: add monitoring — resource snapshots and Discord alerts"
```

---

## Task 19: install-versions.sh

**Files:**
- Create: `scripts/install-versions.sh`

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
# install-versions.sh — Interactive PHP and Node.js version installer

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

show_help() {
    cat <<'HELP'
Usage: install-versions.sh [--dry-run] [--help]

Interactive installer for PHP and Node.js versions.
Shows currently installed versions and recommends stable releases.

PHP: Compiled via phpenv (10-20 minutes per version)
Node: Installed via nvm (< 1 minute)
HELP
}

parse_common_flags "$@" || { show_help; exit 0; }

# Load phpenv
export PHPENV_ROOT="$HOME/.phpenv"
export PATH="$PHPENV_ROOT/bin:$PATH"
eval "$(phpenv init -)" 2>/dev/null || true

# Load nvm
export NVM_DIR="$HOME/.nvm"
# shellcheck source=/dev/null
[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"

install_php_versions() {
    echo ""
    echo "=== PHP Version Installer ==="
    echo ""

    # Show installed versions
    if command -v phpenv &>/dev/null; then
        echo "Currently installed:"
        phpenv versions 2>/dev/null || echo "  (none)"
    else
        warn "phpenv not found. Run module 02 first."
        return 1
    fi

    echo ""
    echo "Recommended versions:"
    echo "  8.3  (latest stable)"
    echo "  8.2  (LTS)"
    echo "  8.1  (security fixes only)"
    echo ""
    read -rp "Enter PHP versions to install (comma-separated, e.g. 8.3,8.2): " php_input

    if [[ -z "$php_input" ]]; then
        info "No PHP versions selected — skipping"
        return 0
    fi

    IFS=',' read -ra versions <<< "$php_input"
    for version in "${versions[@]}"; do
        version=$(echo "$version" | tr -d ' ')

        if phpenv versions 2>/dev/null | grep -q "$version"; then
            info "PHP $version already installed — skipping"
            continue
        fi

        info "Compiling PHP $version (this takes 10-20 minutes)..."
        run phpenv install "$version"

        # Set up FPM config for this version
        local fpm_dir="$PHPENV_ROOT/fpm"
        local template="$fpm_dir/pool-template.conf"
        if [[ -f "$template" ]]; then
            local conf="$fpm_dir/php${version}-fpm.conf"
            sed -e "s|__USER__|$USER|g" -e "s|__VERSION__|$version|g" "$template" > "$conf"
            info "FPM pool config generated for PHP $version"
        fi

        success "PHP $version installed"
    done

    # Set global default
    echo ""
    read -rp "Set global default PHP version (e.g. 8.3): " default_php
    if [[ -n "$default_php" ]]; then
        run phpenv global "$default_php"
        success "Default PHP set to $default_php"
    fi

    # PECL extensions
    echo ""
    echo "Install PECL extensions? (redis, imagick, xdebug, swoole)"
    read -rp "Enter extensions (comma-separated, or skip): " ext_input

    if [[ -n "$ext_input" && "$ext_input" != "skip" ]]; then
        IFS=',' read -ra extensions <<< "$ext_input"
        for ext in "${extensions[@]}"; do
            ext=$(echo "$ext" | tr -d ' ')
            info "Installing PECL extension: $ext"
            run pecl install "$ext" || warn "Failed to install $ext"
        done
    fi
}

install_node_versions() {
    echo ""
    echo "=== Node.js Version Installer ==="
    echo ""

    if ! command -v nvm &>/dev/null; then
        warn "nvm not found. Run module 03 first."
        return 1
    fi

    echo "Currently installed:"
    nvm ls 2>/dev/null || echo "  (none)"

    echo ""
    echo "Recommended versions:"
    echo "  20  (LTS - Active)"
    echo "  18  (LTS - Maintenance)"
    echo ""
    read -rp "Enter Node versions to install (comma-separated, e.g. 20,18): " node_input

    if [[ -z "$node_input" ]]; then
        info "No Node versions selected — skipping"
        return 0
    fi

    IFS=',' read -ra versions <<< "$node_input"
    for version in "${versions[@]}"; do
        version=$(echo "$version" | tr -d ' ')
        info "Installing Node.js $version..."
        run nvm install "$version"
        success "Node.js $version installed"
    done
}

# Main
assert_not_root
install_php_versions
install_node_versions
success "Version installation complete"
```

**Step 2: ShellCheck**

Run: `shellcheck scripts/install-versions.sh`

**Step 3: Commit**

```bash
git add scripts/install-versions.sh
git commit -m "feat: add install-versions.sh — interactive PHP/Node version picker"
```

---

## Task 20: install.sh Entry Point

**Files:**
- Create: `install.sh`

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
# install.sh — VPS Worktree Manager installer
# Usage: curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash
#    or: bash install.sh [--dry-run] [--help]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/common.sh"

show_help() {
    cat <<'HELP'
Usage: install.sh [--dry-run] [--help]

VPS Worktree Manager installer. Runs 11 modules in sequence to set up
a complete development environment with PHP-FPM, Caddy, Supervisor,
and worktree management on Ubuntu.

Requirements:
  - Ubuntu (any recent version)
  - 4GB+ RAM
  - Not running as root (sudo used where needed)

Modules:
  01  System dependencies + database clients
  02  phpenv (PHP version manager)
  03  nvm + Node.js LTS
  04  PHP-FPM pool configuration
  05  Caddy reverse proxy
  06  Supervisor (user-level)
  07  Tailscale VPN
  08  Claude Code
  09  claude-relay (auto-install)
  10  Project structure + SQLite init
  11  Shell integration (PATH, aliases)

Post-install:
  - Run install-versions.sh to compile PHP versions
HELP
}

parse_common_flags "$@" || { show_help; exit 0; }

# Validation
assert_not_root
assert_ubuntu
assert_min_ram 4000

# Banner
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║       VPS Worktree Manager — Installer          ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  11 modules will be installed in sequence.      ║"
echo "║  Estimated time: 10-30 minutes.                 ║"
echo "║  Idempotent: safe to re-run.                    ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    warn "DRY-RUN MODE — no changes will be made"
    echo ""
fi

# Confirm
if [[ "$DRY_RUN" != "true" ]]; then
    read -rp "Proceed with installation? (y/N) " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Installation cancelled."
        exit 0
    fi
fi

# Module runner
MODULES_DIR="$SCRIPT_DIR/scripts/modules"
PASSED=0
FAILED=0
FAILED_MODULES=()

run_module() {
    local module="$1"
    local name
    name=$(basename "$module" .sh)

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "Running module: $name"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if bash "$module" ${DRY_RUN:+--dry-run}; then
        success "Module $name completed"
        PASSED=$((PASSED + 1))
    else
        error "Module $name FAILED"
        FAILED=$((FAILED + 1))
        FAILED_MODULES+=("$name")
        return 1
    fi
}

# Run all modules in order
for module in "$MODULES_DIR"/[0-9][0-9]-*.sh; do
    if ! run_module "$module"; then
        error "Installation stopped at module: $(basename "$module" .sh)"
        error "Fix the issue and re-run install.sh (idempotent — completed modules will skip)."
        exit 1
    fi
done

# Summary
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║       Installation Complete!                    ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  Modules passed: $PASSED/11                         ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
info "Next steps:"
info "  1. Source your shell:  source ~/.bashrc"
info "  2. Install PHP/Node versions:  bash scripts/install-versions.sh"
info "  3. Start building!"
echo ""

if [[ "$FAILED" -gt 0 ]]; then
    warn "Failed modules: ${FAILED_MODULES[*]}"
    exit 1
fi
```

**Step 2: ShellCheck + dry-run test**

Run: `shellcheck install.sh`
Run: `DRY_RUN=true bash install.sh`

**Step 3: Commit**

```bash
git add install.sh
git commit -m "feat: add install.sh — curl-able entry point for all 11 modules"
```

---

## Task 21: README.md

**Files:**
- Create: `README.md`

**Step 1: Write README**

```markdown
# VPS Worktree Manager

Cloud-based development environment for managing git worktrees on a VPS. Each worktree gets its own subdomain, PHP-FPM routing, and database isolation option.

## Quick Start

```bash
# On your Ubuntu VPS (4GB+ RAM):
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/vps-worktree-manager/main/install.sh | bash

# Then install PHP/Node versions:
bash scripts/install-versions.sh
```

## What It Does

- **Git worktrees** with automatic preview environments (`feat-auth-project.underdev.cloud`)
- **PHP-FPM** with per-version socket routing via Caddy
- **phpenv/nvm** for instant version switching (1 second vs 4-8 min Docker rebuild)
- **SQLite registry** for worktree state, port allocation, and resource monitoring
- **Discord alerts** when RAM exceeds thresholds
- **claude-relay** for mobile development via phone/tablet
- **Database isolation** — shared or copied databases per worktree

## Usage

```bash
# Create a worktree
cd ~/projects/my-project
./init-worktree.sh feature/auth

# List active worktrees
wt list

# Get worktree details
wt info my-project feature/auth

# View system stats + RAM trend
wt stats

# Clean up a worktree
cleanup-worktree.sh my-project feature/auth
```

## Architecture

```
Caddy (reverse proxy, auto-HTTPS)
  ├── feat-auth-project1.underdev.cloud → PHP-FPM 8.3 → worktree/public
  ├── fix-bug-project2.underdev.cloud  → PHP-FPM 8.2 → worktree/public
  └── claude-relay.underdev.cloud      → localhost:2633

PHP-FPM (one pool per version)
  ├── php8.3-fpm.sock
  └── php8.2-fpm.sock

Supervisor (user-level)
  ├── claude-relay
  └── node dev servers (if needed)

SQLite (~/projects/worktrees.db)
  ├── worktrees table (ports, subdomains, status)
  └── resource_snapshots table (RAM/CPU/disk metrics)
```

## Requirements

- Ubuntu (any recent version)
- 4GB+ RAM
- Not Docker — this is optimized for bare-metal development velocity

## Development

```bash
# Lint all scripts
make lint

# Structural validation
make validate

# Dry run the full installer
make dry-run

# All checks
make test
```
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with quick start and architecture overview"
```

---

## Task 22: Final Validation

**Step 1: Run full lint + validate**

Run: `make test`
Expected: All scripts pass ShellCheck and structural validation

**Step 2: Run dry-run**

Run: `make dry-run`
Expected: Full install sequence prints DRY-RUN messages without errors

**Step 3: Review file permissions**

Run: `find . -name '*.sh' ! -executable -not -path './.git/*'`
Expected: No results (all .sh files should be executable)

If any are not executable:
Run: `find . -name '*.sh' -not -path './.git/*' -exec chmod +x {} +`

**Step 4: Final commit if needed**

```bash
git add -A
git commit -m "chore: fix file permissions and final validation"
```
