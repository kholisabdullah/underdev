#!/usr/bin/env bash
# migrate-add-resource-snapshots.sh — Add resource_snapshots table to existing DB

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

DB_PATH="${DB_PATH:-${HOME}/projects/worktrees.db}"

show_help() {
    cat <<'HELP'
Usage: migrate-add-resource-snapshots.sh [--dry-run] [--help]

Adds the resource_snapshots table to an existing worktrees.db.
Safe to re-run (uses CREATE TABLE IF NOT EXISTS).
HELP
}

parse_common_flags "$@" || { show_help; exit 0; }

if [[ ! -f "${DB_PATH}" ]]; then
    error "Database not found: ${DB_PATH}"
    exit 1
fi

info "Running migration on ${DB_PATH}..."
run sqlite3 "${DB_PATH}" <<'SQL'
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

success "Migration complete: resource_snapshots table ready"
