#!/usr/bin/env bash
# 09-happy.sh — Install Happy Coder for mobile access

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/../common.sh"

show_help() {
    cat <<'HELP'
Usage: 09-happy.sh [--dry-run] [--help]

Installs happy-coder for mobile access to Claude Code:
  - Installs happy-coder globally via npm
  - Auth (QR pairing) is run by install.sh at the end
HELP
}

parse_common_flags "$@" || { show_help; exit 0; }

# Source nvm so npm is available
export NVM_DIR="${HOME}/.nvm"
# shellcheck source=/dev/null
[[ -s "${NVM_DIR}/nvm.sh" ]] && source "${NVM_DIR}/nvm.sh"

install_happy() {
    if command -v happy &>/dev/null || npm list -g happy-coder &>/dev/null 2>&1; then
        info "happy-coder already installed — skipping"
        return 0
    fi

    if ! command -v npm &>/dev/null; then
        error "npm not found. Run module 03 (nvm-node) first."
        exit 1
    fi

    info "Installing happy-coder..."
    run npm install -g happy-coder
    success "happy-coder installed"
}

# Main
assert_not_root
install_happy
success "Module 09 complete: happy-coder installed"
