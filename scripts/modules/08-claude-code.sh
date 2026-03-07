#!/usr/bin/env bash
# 08-claude-code.sh — Install Claude Code globally

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/../common.sh"

show_help() {
    cat <<'HELP'
Usage: 08-claude-code.sh [--dry-run] [--help]

Installs Claude Code globally via npm.
Requires Node.js (installed by module 03).
HELP
}

parse_common_flags "$@" || { show_help; exit 0; }

# Source nvm
export NVM_DIR="${HOME}/.nvm"
# shellcheck source=/dev/null
[[ -s "${NVM_DIR}/nvm.sh" ]] && source "${NVM_DIR}/nvm.sh"

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
