#!/usr/bin/env bash
# port-manager.sh — SQLite worktree registry library
# Usage: source this file, then call functions directly
# Not meant to be executed standalone

# shellcheck source=scripts/common.sh
# (sourced by callers who already source common.sh)

DB_PATH="${DB_PATH:-${HOME}/projects/worktrees.db}"
PORT_MIN=8001
PORT_MAX=8999

query() {
    sqlite3 "${DB_PATH}" "$1"
}

init_db() {
    sqlite3 "${DB_PATH}" <<'SQL'
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
SQL
}

find_next_port() {
    local max_port
    max_port=$(query "SELECT COALESCE(MAX(port), $((PORT_MIN - 1))) FROM worktrees;")

    local next=$((max_port + 1))
    if [[ ${next} -le ${PORT_MAX} ]]; then
        echo "${next}"
        return 0
    fi

    # Range exhausted — find gaps using recursive CTE
    local gap
    gap=$(query "
        WITH RECURSIVE ports(p) AS (
            SELECT ${PORT_MIN}
            UNION ALL
            SELECT p+1 FROM ports WHERE p < ${PORT_MAX}
        )
        SELECT p FROM ports
        WHERE p NOT IN (SELECT port FROM worktrees)
        LIMIT 1;
    ")

    if [[ -n "${gap}" ]]; then
        echo "${gap}"
        return 0
    fi

    echo "ERROR: No available ports in range ${PORT_MIN}-${PORT_MAX}" >&2
    return 1
}

add_worktree() {
    local project="$1" branch="$2" folder_name="$3" subdomain="$4"
    local pid="${5:-}" db_driver="${6:-}" db_name="${7:-}" db_isolation="${8:-shared}"

    local port
    port=$(find_next_port) || return 1

    local pid_val="NULL"
    [[ -n "${pid}" ]] && pid_val="${pid}"

    local db_driver_val="NULL"
    [[ -n "${db_driver}" ]] && db_driver_val="'${db_driver}'"

    local db_name_val="NULL"
    [[ -n "${db_name}" ]] && db_name_val="'${db_name}'"

    query "INSERT INTO worktrees (project, branch, folder_name, port, subdomain, pid, db_driver, db_name, db_isolation)
           VALUES ('${project}', '${branch}', '${folder_name}', ${port}, '${subdomain}', ${pid_val}, ${db_driver_val}, ${db_name_val}, '${db_isolation}');"

    echo "${port}"
}

remove_worktree() {
    local project="$1" branch="$2"
    query "DELETE FROM worktrees WHERE project='${project}' AND branch='${branch}';"
}

get_port() {
    local project="$1" branch="$2"
    query "SELECT port FROM worktrees WHERE project='${project}' AND branch='${branch}';"
}

get_pid() {
    local project="$1" branch="$2"
    query "SELECT pid FROM worktrees WHERE project='${project}' AND branch='${branch}';"
}

get_subdomain() {
    local project="$1" branch="$2"
    query "SELECT subdomain FROM worktrees WHERE project='${project}' AND branch='${branch}';"
}

get_folder() {
    local project="$1" branch="$2"
    query "SELECT folder_name FROM worktrees WHERE project='${project}' AND branch='${branch}';"
}

get_db_info() {
    local project="$1" branch="$2"
    query "SELECT db_driver, db_name, db_isolation FROM worktrees WHERE project='${project}' AND branch='${branch}';"
}

get_worktree_info() {
    local project="$1" branch="$2"
    query -header -column "SELECT * FROM worktrees WHERE project='${project}' AND branch='${branch}';"
}

mark_stopped() {
    local project="$1" branch="$2"
    query "UPDATE worktrees SET status='stopped', pid=NULL WHERE project='${project}' AND branch='${branch}';"
}

mark_failed() {
    local project="$1" branch="$2"
    query "UPDATE worktrees SET status='failed' WHERE project='${project}' AND branch='${branch}';"
}

mark_db_deleted() {
    local project="$1" branch="$2"
    query "UPDATE worktrees SET db_isolation='deleted' WHERE project='${project}' AND branch='${branch}';"
}

list_active() {
    query -header -column "SELECT project, branch, port, subdomain, status FROM worktrees WHERE status='active' ORDER BY project, branch;"
}

list_all() {
    query -header -column "SELECT project, branch, port, subdomain, status, db_isolation FROM worktrees ORDER BY project, branch;"
}

list_by_project() {
    local project="$1"
    query -header -column "SELECT branch, port, subdomain, status FROM worktrees WHERE project='${project}' ORDER BY branch;"
}

check_orphans() {
    local found=0
    while IFS='|' read -r project branch pid; do
        if [[ -n "${pid}" ]] && ! kill -0 "${pid}" 2>/dev/null; then
            echo "ORPHAN: ${project}/${branch} (PID ${pid} is dead)"
            found=1
        fi
    done < <(query "SELECT project, branch, pid FROM worktrees WHERE status='active' AND pid IS NOT NULL;" || true)

    if [[ ${found} -eq 0 ]]; then
        echo "No orphaned worktrees found."
    fi
}

cleanup_stopped() {
    local count
    count=$(query "SELECT COUNT(*) FROM worktrees WHERE status IN ('stopped','failed');")

    if [[ "${count}" -eq 0 ]]; then
        echo "No stopped/failed worktrees to clean up."
        return 0
    fi

    echo "Found ${count} stopped/failed worktrees:"
    query -header -column "SELECT project, branch, status FROM worktrees WHERE status IN ('stopped','failed');"

    echo ""
    echo "Remove these entries from the database? (y/N)"
    read -r answer
    if [[ "${answer}" =~ ^[Yy]$ ]]; then
        query "DELETE FROM worktrees WHERE status IN ('stopped','failed');"
        echo "Cleaned up ${count} entries."
    else
        echo "Cancelled."
    fi
}

show_stats() {
    echo "=== Worktree Statistics ==="
    query -header -column "
        SELECT
            COUNT(*) as total,
            SUM(CASE WHEN status='active' THEN 1 ELSE 0 END) as active,
            SUM(CASE WHEN status='stopped' THEN 1 ELSE 0 END) as stopped,
            SUM(CASE WHEN db_isolation='isolated' THEN 1 ELSE 0 END) as isolated_dbs,
            SUM(CASE WHEN db_isolation='shared' THEN 1 ELSE 0 END) as shared_dbs,
            COUNT(DISTINCT project) as projects
        FROM worktrees;
    "

    # RAM trend (if resource_snapshots table exists)
    local has_snapshots
    has_snapshots=$(query "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='resource_snapshots';")

    if [[ "${has_snapshots}" -eq 1 ]]; then
        local snapshot_count
        snapshot_count=$(query "SELECT COUNT(*) FROM resource_snapshots WHERE recorded_at > datetime('now', '-1 hour');")

        if [[ "${snapshot_count}" -gt 0 ]]; then
            echo ""
            echo "=== RAM (last hour) ==="
            query -header -column "
                SELECT
                    strftime('%H:%M', recorded_at) as time,
                    ram_used_pct || '%' as used,
                    ram_available_mb || 'MB' as free,
                    json_extract(data, '$.cpu_load_1m') as load,
                    json_extract(data, '$.active_worktrees') as wt_count
                FROM resource_snapshots
                WHERE recorded_at > datetime('now', '-1 hour')
                ORDER BY recorded_at;
            "
        fi

        echo ""
        echo "=== RAM Peak (last 24h) ==="
        query -header -column "
            SELECT
                MAX(ram_used_pct) || '%' as peak_ram,
                MIN(ram_available_mb) || 'MB' as lowest_free,
                ROUND(AVG(ram_used_pct)) || '%' as avg_ram,
                COUNT(*) as snapshots,
                SUM(CASE WHEN ram_used_pct >= 90 THEN 1 ELSE 0 END) as critical_events,
                SUM(CASE WHEN ram_used_pct >= 80 AND ram_used_pct < 90 THEN 1 ELSE 0 END) as warn_events
            FROM resource_snapshots
            WHERE recorded_at > datetime('now', '-24 hours');
        "
    fi
}

show_oldest() {
    query -header -column "
        SELECT project, branch, created_at,
            ROUND((julianday('now') - julianday(created_at)) * 24, 1) as age_hours
        FROM worktrees
        WHERE status='active'
        ORDER BY created_at ASC
        LIMIT 1;
    "
}

search_worktrees() {
    local term="$1"
    query -header -column "
        SELECT project, branch, port, subdomain, status
        FROM worktrees
        WHERE project LIKE '%${term}%' OR branch LIKE '%${term}%' OR subdomain LIKE '%${term}%'
        ORDER BY project, branch;
    "
}

export_csv() {
    local file="${1:-worktrees-export.csv}"
    query -header -csv "SELECT * FROM worktrees;" > "${file}"
    echo "Exported to ${file}"
}

backup_db() {
    local backup_dir="${1:-${HOME}/projects/backups}"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="${backup_dir}/worktrees-${timestamp}.db"
    cp "${DB_PATH}" "${backup_file}"
    echo "Backup saved to ${backup_file}"
}

optimize_db() {
    query "VACUUM;"
    query "ANALYZE;"
    echo "Database optimized."
}
