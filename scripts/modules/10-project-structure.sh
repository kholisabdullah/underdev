#!/usr/bin/env bash
# 10-project-structure.sh — Create ~/projects/ dirs, copy scripts, init SQLite

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/../common.sh"

PROJECTS_DIR="${HOME}/projects"
DB_PATH="${PROJECTS_DIR}/worktrees.db"

show_help() {
    cat <<'HELP'
Usage: 10-project-structure.sh [--dry-run] [--help]

Creates ~/projects/ directory structure, copies worktree management
scripts, and initializes the SQLite database.
HELP
}

parse_common_flags "$@" || { show_help; exit 0; }

create_directories() {
    info "Creating project directories..."
    run mkdir -p "${PROJECTS_DIR}/scripts" "${PROJECTS_DIR}/backups" "${PROJECTS_DIR}/logs"
    success "Directories created"
}

copy_scripts() {
    local src_dir
    src_dir="$(cd "${SCRIPT_DIR}/.." && pwd)"

    info "Copying worktree management scripts..."

    local scripts=(
        port-manager.sh
        worktree-cli.sh
        cleanup-worktree.sh
        db-copy-helper.sh
        monitor-resources.sh
        migrate-add-resource-snapshots.sh
        install-versions.sh
        common.sh
    )

    for script in "${scripts[@]}"; do
        if [[ -f "${src_dir}/${script}" ]]; then
            run cp "${src_dir}/${script}" "${PROJECTS_DIR}/scripts/${script}"
            run chmod +x "${PROJECTS_DIR}/scripts/${script}"
        else
            warn "Script not found: ${script} — skipping"
        fi
    done

    success "Scripts copied to ~/projects/scripts/"
}

init_database() {
    if [[ -f "${DB_PATH}" ]]; then
        info "SQLite database already exists — skipping"
        return 0
    fi

    info "Initializing SQLite database..."
    run sqlite3 "${DB_PATH}" <<'SQL'
CREATE TABLE IF NOT EXISTS worktrees (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project TEXT NOT NULL,
    branch TEXT NOT NULL,
    folder_name TEXT NOT NULL,
    port INTEGER UNIQUE NOT NULL,
    subdomain TEXT NOT NULL,
    pid INTEGER,
    status TEXT DEFAULT 'active' CHECK(status IN ('active','stopped','failed')),
    db_driver TEXT,
    db_name TEXT,
    db_isolation TEXT DEFAULT 'shared' CHECK(db_isolation IN ('isolated','shared','deleted','none')),
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(project, branch)
);

CREATE INDEX IF NOT EXISTS idx_project_branch ON worktrees(project, branch);
CREATE INDEX IF NOT EXISTS idx_status ON worktrees(status);

CREATE TRIGGER IF NOT EXISTS update_timestamp
    AFTER UPDATE ON worktrees
    BEGIN UPDATE worktrees SET updated_at=CURRENT_TIMESTAMP WHERE id=NEW.id; END;

CREATE TABLE IF NOT EXISTS resource_snapshots (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    recorded_at      DATETIME DEFAULT CURRENT_TIMESTAMP,
    ram_used_pct     INTEGER NOT NULL,
    ram_available_mb INTEGER NOT NULL,
    data             JSON
);

CREATE INDEX IF NOT EXISTS idx_snapshots_recorded_at
    ON resource_snapshots(recorded_at);
SQL
    success "SQLite database initialized at ${DB_PATH}"
}

setup_monitoring_cron() {
    if crontab -l 2>/dev/null | grep -q "monitor-resources.sh"; then
        info "Monitoring cron already configured — skipping"
        return 0
    fi

    info "Setting up monitoring cron (every 5 min)..."
    if [[ "${DRY_RUN}" == "true" ]]; then
        info "[DRY-RUN] Would add cron: */5 * * * * monitor-resources.sh"
        return 0
    fi

    (crontab -l 2>/dev/null; echo "*/5 * * * * /bin/bash ${PROJECTS_DIR}/scripts/monitor-resources.sh >> ${PROJECTS_DIR}/logs/monitor.log 2>&1") | crontab -
    success "Monitoring cron configured"
}

# Main
assert_not_root
create_directories
copy_scripts
init_database
setup_monitoring_cron
success "Module 10 complete: project structure ready"
