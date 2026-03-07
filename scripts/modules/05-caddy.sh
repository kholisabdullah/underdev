#!/usr/bin/env bash
# 05-caddy.sh — Install Caddy, configure sites directory and sudoers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/../common.sh"

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

    local caddy_gpg_key
    caddy_gpg_key=$(curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key')
    run printf '%s' "${caddy_gpg_key}" | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    local caddy_deb_txt
    caddy_deb_txt=$(curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt')
    run printf '%s\n' "${caddy_deb_txt}" | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null

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

    if grep -q "${import_line}" "${caddyfile}" 2>/dev/null; then
        info "Import directive already in Caddyfile — skipping"
        return 0
    fi

    info "Adding import directive to Caddyfile..."
    run sudo sh -c "echo '${import_line}' >> ${caddyfile}"
    success "Caddy sites directory configured"
}

configure_sudoers() {
    local sudoers_file="/etc/sudoers.d/caddy-worktrees"

    if [[ -f "${sudoers_file}" ]]; then
        info "Caddy sudoers already configured — skipping"
        return 0
    fi

    info "Configuring passwordless sudo for Caddy operations..."
    run sudo tee "${sudoers_file}" >/dev/null <<SUDOERS
# Allow worktree manager to reload Caddy and manage site configs
${USER} ALL=(ALL) NOPASSWD: /usr/bin/caddy reload *
${USER} ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/caddy/sites/*
${USER} ALL=(ALL) NOPASSWD: /bin/rm /etc/caddy/sites/*
SUDOERS
    run sudo chmod 0440 "${sudoers_file}"
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
