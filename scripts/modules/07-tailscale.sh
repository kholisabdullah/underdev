#!/usr/bin/env bash
# 07-tailscale.sh — Install Tailscale for VPN-based SSH and DB access

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/../common.sh"

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
    local ts_install
    ts_install=$(curl -fsSL https://tailscale.com/install.sh)
    run sh -c "${ts_install}"
    success "Tailscale installed"
}

prompt_auth() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        info "[DRY-RUN] Would prompt for Tailscale authentication"
        return 0
    fi

    echo ""
    echo "Would you like to authenticate Tailscale now? (y/N)"
    read -r answer
    if [[ "${answer}" =~ ^[Yy]$ ]]; then
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
