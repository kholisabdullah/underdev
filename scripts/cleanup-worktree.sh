#!/usr/bin/env bash
# cleanup-worktree.sh — Full worktree teardown

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=scripts/port-manager.sh
source "${SCRIPT_DIR}/port-manager.sh"

SUPERVISOR_DIR="${HOME}/.config/supervisor"

show_help() {
    cat <<'HELP'
Usage: cleanup-worktree.sh <project> <branch> [--dry-run] [--help]

Full worktree teardown:
  1. Remove Caddy config + reload
  2. Drop database (if isolated)
  3. Remove git worktree
  4. Remove from SQLite registry
  5. Stop Supervisor process (if exists)
HELP
}

for arg in "$@"; do
    case "${arg}" in
        --help)    show_help; exit 0 ;;
        --dry-run) DRY_RUN=true ;;
        *)         ;;
    esac
done

PROJECT="${1:?Usage: cleanup-worktree.sh <project> <branch>}"
BRANCH="${2:?Usage: cleanup-worktree.sh <project> <branch>}"

# Get worktree info from SQLite
FOLDER=$(get_folder "${PROJECT}" "${BRANCH}")
SUBDOMAIN=$(get_subdomain "${PROJECT}" "${BRANCH}")
PORT=$(get_port "${PROJECT}" "${BRANCH}")

if [[ -z "${FOLDER}" ]]; then
    error "Worktree not found: ${PROJECT}/${BRANCH}"
    exit 1
fi

info "Cleaning up worktree: ${PROJECT}/${BRANCH} (port ${PORT})"

# Step 1: Remove Caddy config
remove_caddy_config() {
    local vhost="/etc/caddy/sites/${SUBDOMAIN}.caddy"

    if [[ -f "${vhost}" ]]; then
        info "Removing Caddy config..."
        run sudo rm "${vhost}"
        run sudo caddy reload --config /etc/caddy/Caddyfile
        success "Caddy config removed"
    else
        info "No Caddy config found — skipping"
    fi
}

# Step 2: Drop database (if isolated)
drop_database() {
    local db_info
    db_info=$(get_db_info "${PROJECT}" "${BRANCH}")

    local db_driver db_name db_isolation
    IFS='|' read -r db_driver db_name db_isolation <<< "${db_info}"

    if [[ "${db_isolation}" != "isolated" ]]; then
        info "Database is ${db_isolation} — skipping drop"
        return 0
    fi

    info "Dropping isolated database: ${db_name} (${db_driver})..."
    local project_dir="${HOME}/projects/${PROJECT}"
    local env_file="${project_dir}/.env"

    case "${db_driver}" in
        mysql)
            local db_host db_port db_user db_pass
            db_host=$(grep -E '^DB_HOST=' "${env_file}" | cut -d= -f2 | tr -d '"' | tr -d "'")
            db_port=$(grep -E '^DB_PORT=' "${env_file}" | cut -d= -f2 | tr -d '"' | tr -d "'")
            db_user=$(grep -E '^DB_ADMIN_USERNAME=' "${env_file}" | cut -d= -f2 | tr -d '"' | tr -d "'" || grep -E '^DB_USERNAME=' "${env_file}" | cut -d= -f2 | tr -d '"' | tr -d "'")
            db_pass=$(grep -E '^DB_ADMIN_PASSWORD=' "${env_file}" | cut -d= -f2 | tr -d '"' | tr -d "'" || grep -E '^DB_PASSWORD=' "${env_file}" | cut -d= -f2 | tr -d '"' | tr -d "'")
            run mysql -h "${db_host}" -P "${db_port:-3306}" -u "${db_user}" -p"${db_pass}" -e "DROP DATABASE IF EXISTS \`${db_name}\`;"
            ;;
        pgsql)
            local db_host db_port db_user db_pass
            db_host=$(grep -E '^DB_HOST=' "${env_file}" | cut -d= -f2 | tr -d '"' | tr -d "'")
            db_port=$(grep -E '^DB_PORT=' "${env_file}" | cut -d= -f2 | tr -d '"' | tr -d "'")
            db_user=$(grep -E '^DB_ADMIN_USERNAME=' "${env_file}" | cut -d= -f2 | tr -d '"' | tr -d "'" || grep -E '^DB_USERNAME=' "${env_file}" | cut -d= -f2 | tr -d '"' | tr -d "'")
            db_pass=$(grep -E '^DB_ADMIN_PASSWORD=' "${env_file}" | cut -d= -f2 | tr -d '"' | tr -d "'" || grep -E '^DB_PASSWORD=' "${env_file}" | cut -d= -f2 | tr -d '"' | tr -d "'")
            run PGPASSWORD="${db_pass}" dropdb -h "${db_host}" -p "${db_port:-5432}" -U "${db_user}" "${db_name}" --if-exists
            ;;
        sqlite)
            run rm -f "${db_name}"
            ;;
        *)
            warn "Unknown db_driver '${db_driver}' — skipping database drop"
            ;;
    esac

    mark_db_deleted "${PROJECT}" "${BRANCH}"
    success "Database dropped: ${db_name}"
}

# Step 3: Remove git worktree
remove_git_worktree() {
    local worktree_path="${HOME}/projects/${PROJECT}/.worktrees/${FOLDER}"

    if [[ -d "${worktree_path}" ]]; then
        info "Removing git worktree..."
        run git -C "${HOME}/projects/${PROJECT}" worktree remove "${worktree_path}" --force 2>/dev/null || {
            warn "git worktree remove failed, falling back to rm + prune"
            run rm -rf "${worktree_path}"
            run git -C "${HOME}/projects/${PROJECT}" worktree prune
        }
        success "Git worktree removed"
    else
        info "Worktree directory not found — skipping"
    fi
}

# Step 4: Remove from SQLite
remove_registry() {
    info "Removing from SQLite registry..."
    remove_worktree "${PROJECT}" "${BRANCH}"
    success "Registry entry removed"
}

# Step 5: Stop Supervisor process (if exists)
stop_supervisor_process() {
    local process_name="${FOLDER}-${PROJECT}"
    local conf="${SUPERVISOR_DIR}/conf.d/${process_name}.conf"

    if [[ -f "${conf}" ]]; then
        info "Stopping Supervisor process: ${process_name}..."
        run supervisorctl -c "${SUPERVISOR_DIR}/supervisord.conf" stop "${process_name}" 2>/dev/null || true
        run rm "${conf}"
        run supervisorctl -c "${SUPERVISOR_DIR}/supervisord.conf" reread
        run supervisorctl -c "${SUPERVISOR_DIR}/supervisord.conf" update
        success "Supervisor process stopped and config removed"
    fi
}

# Execute cleanup
remove_caddy_config
drop_database
remove_git_worktree
remove_registry
stop_supervisor_process

success "Worktree ${PROJECT}/${BRANCH} fully cleaned up"
