#!/usr/bin/env bash
# 02-phpenv.sh — Install phpenv + php-build plugin
# Does NOT compile PHP versions — use install-versions.sh for that

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../common.sh"

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
    if [[ -d "${HOME}/.phpenv" ]]; then
        info "phpenv already installed at ~/.phpenv — skipping"
        return 0
    fi

    info "Installing phpenv..."
    run git clone https://github.com/phpenv/phpenv.git "${HOME}/.phpenv"

    info "Installing php-build plugin..."
    run git clone https://github.com/php-build/php-build.git "${HOME}/.phpenv/plugins/php-build"

    success "phpenv installed"
}

configure_shell() {
    local bashrc="${HOME}/.bashrc"
    local marker="# vps-wm:phpenv"

    if grep -q "${marker}" "${bashrc}" 2>/dev/null; then
        info "phpenv shell config already present — skipping"
        return 0
    fi

    info "Adding phpenv to shell config..."
    run tee -a "${bashrc}" >/dev/null <<EOF

${marker}
export PHPENV_ROOT="\${HOME}/.phpenv"
export PATH="\${PHPENV_ROOT}/bin:\${PATH}"
eval "\$(phpenv init -)"
EOF
    success "Shell config updated for phpenv"
}

# Main
assert_not_root
install_phpenv
configure_shell
success "Module 02 complete: phpenv ready"
