#!/usr/bin/env bash
# 09-clay.sh — Auto-install developer clay instance

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/../common.sh"

CLAY_PORT=2633
CLAY_SUBDOMAIN="clay"
DOMAIN="underdev.cloud"
SUPERVISOR_DIR="${HOME}/.config/supervisor"

show_help() {
    cat <<'HELP'
Usage: 09-clay.sh [--dry-run] [--help]

Installs clay and sets up a single developer instance:
  - Supervisor process on port 2633
  - Caddy vhost at clay.underdev.cloud
  - Auto-registers all git projects in ~/projects/
  - NO PIN by default (warns user to set one)
HELP
}

parse_common_flags "$@" || { show_help; exit 0; }

# Source nvm
export NVM_DIR="${HOME}/.nvm"
# shellcheck source=/dev/null
[[ -s "${NVM_DIR}/nvm.sh" ]] && source "${NVM_DIR}/nvm.sh"

install_clay() {
    if command -v clay-server &>/dev/null || npm list -g clay-server &>/dev/null 2>&1; then
        info "clay already installed — skipping"
        return 0
    fi

    if ! command -v npm &>/dev/null; then
        error "npm not found. Run module 03 (nvm-node) first."
        exit 1
    fi

    info "Installing clay-server..."
    run npm install -g clay-server
    success "clay installed"
}

create_supervisor_config() {
    local conf="${SUPERVISOR_DIR}/conf.d/clay.conf"

    if [[ -f "${conf}" ]]; then
        info "clay Supervisor config already exists — skipping"
        return 0
    fi

    info "Creating Supervisor config for clay..."
    run mkdir -p "${SUPERVISOR_DIR}/conf.d"
    run tee "${conf}" >/dev/null <<CONF
[program:clay]
command=npx clay-server --headless --no-https --port ${CLAY_PORT} --yes
directory=${HOME}
autostart=true
autorestart=true
stdout_logfile=${HOME}/projects/logs/clay.log
stderr_logfile=${HOME}/projects/logs/clay-error.log
CONF
    success "Supervisor config created"
}

create_caddy_vhost() {
    local vhost="/etc/caddy/sites/${CLAY_SUBDOMAIN}.caddy"

    if [[ -f "${vhost}" ]]; then
        info "Caddy vhost for clay already exists — skipping"
        return 0
    fi

    info "Creating Caddy vhost for clay..."
    run sudo tee "${vhost}" >/dev/null <<CADDY
${CLAY_SUBDOMAIN}.${DOMAIN} {
    reverse_proxy localhost:${CLAY_PORT}
}
CADDY
    run sudo caddy reload --config /etc/caddy/Caddyfile
    success "Caddy vhost created: ${CLAY_SUBDOMAIN}.${DOMAIN}"
}

register_projects() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        info "[DRY-RUN] Would register all git projects in ~/projects/"
        return 0
    fi

    info "Registering projects with clay..."
    for project_dir in "${HOME}/projects"/*/; do
        if [[ -d "${project_dir}/.git" ]]; then
            local project_name
            project_name="$(basename "${project_dir}")"
            info "Registering ${project_name}..."
            npx clay-server --add "${project_dir}" 2>/dev/null || true
        fi
    done
    success "Projects registered"
}

start_clay() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        info "[DRY-RUN] Would start clay via Supervisor"
        return 0
    fi

    info "Starting clay..."
    supervisorctl -c "${SUPERVISOR_DIR}/supervisord.conf" reread
    supervisorctl -c "${SUPERVISOR_DIR}/supervisord.conf" update
    success "clay started"
}

print_pin_warning() {
    echo ""
    warn "==================================================================="
    warn "  Clay is running WITHOUT a PIN!"
    warn "  URL: https://${CLAY_SUBDOMAIN}.${DOMAIN}"
    warn ""
    warn "  To set a PIN, edit the Supervisor config:"
    warn "    vim ${SUPERVISOR_DIR}/conf.d/clay.conf"
    warn ""
    warn "  Change the command line to include --pin <your-pin>:"
    warn "    command=npx clay-server --headless --no-https --port ${CLAY_PORT} --pin 123456 --yes"
    warn ""
    warn "  Then restart:"
    warn "    supervisorctl restart clay"
    warn "==================================================================="
}

# Main
assert_not_root
install_clay
create_supervisor_config
create_caddy_vhost
start_clay
register_projects
print_pin_warning
success "Module 09 complete: clay running at ${CLAY_SUBDOMAIN}.${DOMAIN}"
