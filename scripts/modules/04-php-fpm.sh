#!/usr/bin/env bash
# 04-php-fpm.sh — Install PHP-FPM (single pool per version, Caddy routes)
# Replaces FrankenPHP from original Notion design

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/../common.sh"

show_help() {
    cat <<'HELP'
Usage: 04-php-fpm.sh [--dry-run] [--help]

Installs PHP-FPM via phpenv-compiled versions. Each PHP version gets
its own FPM master process listening on a unix socket. Caddy routes
requests to the correct socket based on .php-version.

Sockets:
  PHP 8.3 -> /run/php/php8.3-fpm.sock
  PHP 8.2 -> /run/php/php8.2-fpm.sock

NOTE: PHP versions must be compiled first via install-versions.sh.
      This module configures FPM pool templates and socket directories.
HELP
}

parse_common_flags "$@" || { show_help; exit 0; }

setup_fpm_directories() {
    info "Creating FPM directories..."

    run sudo mkdir -p /run/php
    run sudo chown "${USER}":"${USER}" /run/php

    local fpm_conf_dir="${HOME}/.phpenv/fpm"
    run mkdir -p "${fpm_conf_dir}"

    success "FPM directories created"
}

create_fpm_pool_template() {
    local fpm_conf_dir="${HOME}/.phpenv/fpm"
    local template="${fpm_conf_dir}/pool-template.conf"

    if [[ -f "${template}" ]]; then
        info "FPM pool template already exists — skipping"
        return 0
    fi

    info "Creating FPM pool template..."
    run tee "${template}" >/dev/null <<'POOL'
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
    success "FPM pool template created at ${template}"
}

create_fpm_launcher() {
    local launcher="${HOME}/.phpenv/fpm/start-fpm.sh"

    if [[ -f "${launcher}" ]]; then
        info "FPM launcher already exists — skipping"
        return 0
    fi

    info "Creating FPM launcher script..."
    run tee "${launcher}" >/dev/null <<'LAUNCHER'
#!/usr/bin/env bash
# start-fpm.sh — Start PHP-FPM for a specific version
# Usage: start-fpm.sh 8.3
set -euo pipefail

VERSION="${1:?Usage: start-fpm.sh <php-version> (e.g. 8.3)}"
PHPENV_ROOT="${HOME}/.phpenv"
FPM_DIR="${PHPENV_ROOT}/fpm"
TEMPLATE="${FPM_DIR}/pool-template.conf"
CONF="${FPM_DIR}/php${VERSION}-fpm.conf"
PHP_FPM="${PHPENV_ROOT}/versions/${VERSION}/sbin/php-fpm"

if [[ ! -x "${PHP_FPM}" ]]; then
    echo "ERROR: php-fpm not found for PHP ${VERSION} at ${PHP_FPM}"
    exit 1
fi

# Generate config from template
sed -e "s|__USER__|${USER}|g" -e "s|__VERSION__|${VERSION}|g" "${TEMPLATE}" > "${CONF}"

echo "Starting PHP-FPM ${VERSION} (socket: /run/php/php${VERSION}-fpm.sock)"
exec "${PHP_FPM}" --nodaemonize --fpm-config "${CONF}"
LAUNCHER
    run chmod +x "${launcher}"
    success "FPM launcher created"
}

# Main
assert_not_root
setup_fpm_directories
create_fpm_pool_template
create_fpm_launcher
success "Module 04 complete: PHP-FPM configured (run install-versions.sh to compile PHP)"
