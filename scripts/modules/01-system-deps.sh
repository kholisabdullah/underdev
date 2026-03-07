#!/usr/bin/env bash
# 01-system-deps.sh — Install system packages, build dependencies, and database clients
# Part of vps-worktree-manager install sequence

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/../common.sh"

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
        local ms_key
        ms_key=$(curl -fsSL https://packages.microsoft.com/keys/microsoft.asc)
        run printf '%s' "${ms_key}" | sudo gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg
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
