#!/usr/bin/env bash
# 09-claude-relay.sh — Auto-install developer claude-relay instance

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/../common.sh"

RELAY_PORT=2633
RELAY_SUBDOMAIN="claude-relay"
DOMAIN="underdev.cloud"
SUPERVISOR_DIR="${HOME}/.config/supervisor"

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
export NVM_DIR="${HOME}/.nvm"
# shellcheck source=/dev/null
[[ -s "${NVM_DIR}/nvm.sh" ]] && source "${NVM_DIR}/nvm.sh"

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
    local conf="${SUPERVISOR_DIR}/conf.d/claude-relay.conf"

    if [[ -f "${conf}" ]]; then
        info "claude-relay Supervisor config already exists — skipping"
        return 0
    fi

    info "Creating Supervisor config for claude-relay..."
    run mkdir -p "${SUPERVISOR_DIR}/conf.d"
    run tee "${conf}" >/dev/null <<CONF
[program:claude-relay]
command=npx claude-relay --headless --no-https --port ${RELAY_PORT} --yes
directory=${HOME}
autostart=true
autorestart=true
stdout_logfile=${HOME}/projects/logs/claude-relay.log
stderr_logfile=${HOME}/projects/logs/claude-relay-error.log
CONF
    success "Supervisor config created"
}

create_caddy_vhost() {
    local vhost="/etc/caddy/sites/${RELAY_SUBDOMAIN}.caddy"

    if [[ -f "${vhost}" ]]; then
        info "Caddy vhost for claude-relay already exists — skipping"
        return 0
    fi

    info "Creating Caddy vhost for claude-relay..."
    run sudo tee "${vhost}" >/dev/null <<CADDY
${RELAY_SUBDOMAIN}.${DOMAIN} {
    reverse_proxy localhost:${RELAY_PORT}
}
CADDY
    run sudo caddy reload --config /etc/caddy/Caddyfile
    success "Caddy vhost created: ${RELAY_SUBDOMAIN}.${DOMAIN}"
}

register_projects() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        info "[DRY-RUN] Would register all git projects in ~/projects/"
        return 0
    fi

    info "Registering projects with claude-relay..."
    for project_dir in "${HOME}/projects"/*/; do
        if [[ -d "${project_dir}/.git" ]]; then
            local project_name
            project_name="$(basename "${project_dir}")"
            info "Registering ${project_name}..."
            npx claude-relay --add "${project_dir}" 2>/dev/null || true
        fi
    done
    success "Projects registered"
}

start_relay() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        info "[DRY-RUN] Would start claude-relay via Supervisor"
        return 0
    fi

    info "Starting claude-relay..."
    supervisorctl -c "${SUPERVISOR_DIR}/supervisord.conf" reread
    supervisorctl -c "${SUPERVISOR_DIR}/supervisord.conf" update
    success "claude-relay started"
}

print_pin_warning() {
    echo ""
    warn "==================================================================="
    warn "  Claude Relay is running WITHOUT a PIN!"
    warn "  URL: https://${RELAY_SUBDOMAIN}.${DOMAIN}"
    warn ""
    warn "  To set a PIN, edit the Supervisor config:"
    warn "    vim ${SUPERVISOR_DIR}/conf.d/claude-relay.conf"
    warn ""
    warn "  Change the command line to include --pin <your-pin>:"
    warn "    command=npx claude-relay --headless --no-https --port ${RELAY_PORT} --pin 123456 --yes"
    warn ""
    warn "  Then restart:"
    warn "    supervisorctl restart claude-relay"
    warn "==================================================================="
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
