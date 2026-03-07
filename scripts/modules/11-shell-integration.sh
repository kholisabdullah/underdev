#!/usr/bin/env bash
# 11-shell-integration.sh — Add PATH, aliases to ~/.bashrc

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/../common.sh"

SUPERVISOR_DIR="${HOME}/.config/supervisor"

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
    local bashrc="${HOME}/.bashrc"
    local marker="# vps-wm:shell-integration"

    if grep -q "${marker}" "${bashrc}" 2>/dev/null; then
        info "Shell integration already present — skipping"
        return 0
    fi

    info "Adding shell integration to ~/.bashrc..."
    run tee -a "${bashrc}" >/dev/null <<EOF

${marker}
export PATH="\${HOME}/projects/scripts:\${PATH}"
alias wt='worktree-cli.sh'
alias supervisorctl='supervisorctl -c ${SUPERVISOR_DIR}/supervisord.conf'
EOF
    success "Shell integration configured"
}

# Main
assert_not_root
configure_bashrc
success "Module 11 complete: shell integration ready (source ~/.bashrc or open new terminal)"
