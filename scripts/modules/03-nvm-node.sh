#!/usr/bin/env bash
# 03-nvm-node.sh — Install nvm and Node.js LTS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/../common.sh"

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
    if [[ -d "${HOME}/.nvm" ]]; then
        info "nvm already installed — skipping"
        return 0
    fi

    info "Installing nvm v${NVM_VERSION}..."
    run bash -c "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh | bash"
    success "nvm installed"
}

install_node_lts() {
    # Source nvm so we can use it
    export NVM_DIR="${HOME}/.nvm"
    # shellcheck source=/dev/null
    [[ -s "${NVM_DIR}/nvm.sh" ]] && source "${NVM_DIR}/nvm.sh"

    if command -v node &>/dev/null; then
        local current
        current="$(node --version)"
        info "Node.js already installed (${current}) — skipping"
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
