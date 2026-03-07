#!/usr/bin/env bash
# db-copy-helper.sh — Universal database copy utility
# Exit codes: 0=success, 1=failure, 10=no CREATE privilege

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

show_help() {
    cat <<'HELP'
Usage: db-copy-helper.sh <source-env-file> <target-db-name> [--dry-run] [--help]

Reads database credentials from a .env file, auto-detects the engine,
and creates a copy of the database with the given target name.

Supported engines: mysql, pgsql, sqlite, sqlsrv

Exit codes:
  0  — Success
  1  — General failure
  10 — No CREATE DATABASE privilege
HELP
}

for arg in "$@"; do
    case "${arg}" in
        --help)    show_help; exit 0 ;;
        --dry-run) DRY_RUN=true ;;
        *)         ;;
    esac
done

SOURCE_ENV="${1:?Usage: db-copy-helper.sh <source-env-file> <target-db-name>}"
TARGET_DB="${2:?Usage: db-copy-helper.sh <source-env-file> <target-db-name>}"

# Read .env file
read_env() {
    local env_file="$1"
    if [[ ! -f "${env_file}" ]]; then
        error ".env file not found: ${env_file}"
        exit 1
    fi

    DB_CONNECTION=$(grep -E '^DB_CONNECTION=' "${env_file}" | cut -d= -f2 | tr -d '"' | tr -d "'")
    DB_HOST=$(grep -E '^DB_HOST=' "${env_file}" | cut -d= -f2 | tr -d '"' | tr -d "'")
    DB_PORT=$(grep -E '^DB_PORT=' "${env_file}" | cut -d= -f2 | tr -d '"' | tr -d "'")
    DB_DATABASE=$(grep -E '^DB_DATABASE=' "${env_file}" | cut -d= -f2 | tr -d '"' | tr -d "'")
    DB_USERNAME=$(grep -E '^DB_USERNAME=' "${env_file}" | cut -d= -f2 | tr -d '"' | tr -d "'")
    DB_PASSWORD=$(grep -E '^DB_PASSWORD=' "${env_file}" | cut -d= -f2 | tr -d '"' | tr -d "'")

    # Admin credentials (optional, for CREATE DATABASE)
    DB_ADMIN_USERNAME=$(grep -E '^DB_ADMIN_USERNAME=' "${env_file}" | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
    DB_ADMIN_PASSWORD=$(grep -E '^DB_ADMIN_PASSWORD=' "${env_file}" | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
}

check_client() {
    case "${DB_CONNECTION}" in
        mysql)  command -v mysql    &>/dev/null || { error "MySQL client not found. Run module 01."; exit 1; } ;;
        pgsql)  command -v psql     &>/dev/null || { error "psql not found. Run module 01."; exit 1; } ;;
        sqlite) command -v sqlite3  &>/dev/null || { error "sqlite3 not found. Run module 01."; exit 1; } ;;
        sqlsrv) command -v sqlcmd   &>/dev/null || { error "sqlcmd not found. Run module 01."; exit 1; } ;;
        *)      error "Unsupported DB_CONNECTION: ${DB_CONNECTION}"; exit 1 ;;
    esac
}

copy_mysql() {
    local admin_user="${DB_ADMIN_USERNAME:-${DB_USERNAME}}"
    local admin_pass="${DB_ADMIN_PASSWORD:-${DB_PASSWORD}}"

    info "Creating MySQL database: ${TARGET_DB}"
    if ! run mysql -h "${DB_HOST}" -P "${DB_PORT:-3306}" -u "${admin_user}" -p"${admin_pass}" \
        -e "CREATE DATABASE \`${TARGET_DB}\`;" 2>/dev/null; then
        error "Failed to create database. Check admin credentials."
        exit 10
    fi

    info "Copying data from ${DB_DATABASE} to ${TARGET_DB}..."
    run bash -c "mysqldump -h '${DB_HOST}' -P '${DB_PORT:-3306}' -u '${DB_USERNAME}' -p'${DB_PASSWORD}' '${DB_DATABASE}' | mysql -h '${DB_HOST}' -P '${DB_PORT:-3306}' -u '${admin_user}' -p'${admin_pass}' '${TARGET_DB}'"
    success "MySQL database copied: ${TARGET_DB}"
}

copy_pgsql() {
    local admin_user="${DB_ADMIN_USERNAME:-${DB_USERNAME}}"

    info "Creating PostgreSQL database: ${TARGET_DB}"
    if ! run PGPASSWORD="${DB_ADMIN_PASSWORD:-${DB_PASSWORD}}" createdb \
        -h "${DB_HOST}" -p "${DB_PORT:-5432}" -U "${admin_user}" \
        -T "${DB_DATABASE}" "${TARGET_DB}" 2>/dev/null; then
        error "Failed to create database. Check admin credentials."
        exit 10
    fi

    success "PostgreSQL database copied: ${TARGET_DB} (template clone)"
}

copy_sqlite() {
    local source_path="${DB_DATABASE}"
    local target_path
    target_path="$(dirname "${source_path}")/${TARGET_DB}.sqlite"

    if [[ ! -f "${source_path}" ]]; then
        error "SQLite file not found: ${source_path}"
        exit 1
    fi

    info "Copying SQLite database..."
    run cp "${source_path}" "${target_path}"
    success "SQLite database copied: ${target_path}"
}

copy_sqlsrv() {
    local admin_user="${DB_ADMIN_USERNAME:-${DB_USERNAME}}"
    local admin_pass="${DB_ADMIN_PASSWORD:-${DB_PASSWORD}}"

    info "Creating SQL Server database: ${TARGET_DB}"
    if ! run sqlcmd -S "${DB_HOST},${DB_PORT:-1433}" -U "${admin_user}" -P "${admin_pass}" \
        -Q "CREATE DATABASE [${TARGET_DB}];" 2>/dev/null; then
        error "Failed to create database. Check admin credentials."
        exit 10
    fi

    info "Backing up and restoring..."
    local backup_file="/tmp/${DB_DATABASE}_backup.bak"
    run sqlcmd -S "${DB_HOST},${DB_PORT:-1433}" -U "${admin_user}" -P "${admin_pass}" \
        -Q "BACKUP DATABASE [${DB_DATABASE}] TO DISK='${backup_file}';"
    run sqlcmd -S "${DB_HOST},${DB_PORT:-1433}" -U "${admin_user}" -P "${admin_pass}" \
        -Q "RESTORE DATABASE [${TARGET_DB}] FROM DISK='${backup_file}' WITH MOVE '${DB_DATABASE}' TO '/var/opt/mssql/data/${TARGET_DB}.mdf', MOVE '${DB_DATABASE}_log' TO '/var/opt/mssql/data/${TARGET_DB}_log.ldf';"
    rm -f "${backup_file}"
    success "SQL Server database copied: ${TARGET_DB}"
}

# Main
read_env "${SOURCE_ENV}"
check_client

case "${DB_CONNECTION}" in
    mysql)  copy_mysql ;;
    pgsql)  copy_pgsql ;;
    sqlite) copy_sqlite ;;
    sqlsrv) copy_sqlsrv ;;
    *)      error "Unsupported DB_CONNECTION: ${DB_CONNECTION}"; exit 1 ;;
esac
