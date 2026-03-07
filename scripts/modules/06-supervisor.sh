#!/usr/bin/env bash
# 06-supervisor.sh — Install Supervisor, disable system instance, set up user-level

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../common.sh"

show_help() {
    cat <<'HELP'
Usage: 06-supervisor.sh [--dry-run] [--help]

Installs Supervisor via apt, disables the system-level instance,
and sets up a user-level Supervisor at ~/.config/supervisor/.
HELP
}

parse_common_flags "$@" || { show_help; exit 0; }

SUPERVISOR_DIR="${HOME}/.config/supervisor"

install_supervisor() {
    if command -v supervisord &>/dev/null; then
        info "Supervisor already installed — skipping"
    else
        info "Installing Supervisor..."
        run sudo apt install -y supervisor
        success "Supervisor installed"
    fi

    # Disable system instance
    if systemctl is-enabled supervisor &>/dev/null; then
        info "Disabling system-level Supervisor..."
        run sudo systemctl disable --now supervisor
        success "System Supervisor disabled"
    fi
}

setup_user_supervisor() {
    if [[ -f "${SUPERVISOR_DIR}/supervisord.conf" ]]; then
        info "User-level Supervisor already configured — skipping"
        return 0
    fi

    info "Setting up user-level Supervisor..."
    run mkdir -p "${SUPERVISOR_DIR}/conf.d" "${SUPERVISOR_DIR}/logs"

    run tee "${SUPERVISOR_DIR}/supervisord.conf" >/dev/null <<CONF
[unix_http_server]
file=${SUPERVISOR_DIR}/supervisor.sock

[supervisord]
logfile=${SUPERVISOR_DIR}/logs/supervisord.log
pidfile=${SUPERVISOR_DIR}/supervisord.pid
nodaemon=false

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix://${SUPERVISOR_DIR}/supervisor.sock

[include]
files = ${SUPERVISOR_DIR}/conf.d/*.conf
CONF
    success "User-level Supervisor configured at ${SUPERVISOR_DIR}"
}

start_user_supervisor() {
    if [[ -S "${SUPERVISOR_DIR}/supervisor.sock" ]]; then
        info "User Supervisor already running — skipping"
        return 0
    fi

    info "Starting user-level Supervisor..."
    run supervisord -c "${SUPERVISOR_DIR}/supervisord.conf"
    success "User Supervisor started"
}

# Main
assert_not_root
install_supervisor
setup_user_supervisor
start_user_supervisor
success "Module 06 complete: user-level Supervisor ready"
