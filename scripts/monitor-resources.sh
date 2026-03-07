#!/usr/bin/env bash
# monitor-resources.sh — Record RAM/CPU/disk snapshots and alert via Discord

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

DB_PATH="${HOME}/projects/worktrees.db"
ENV_FILE="${HOME}/projects/.env"
COOLDOWN_DIR="${HOME}/projects/logs"

show_help() {
    cat <<'HELP'
Usage: monitor-resources.sh [--status] [--test] [--dry-run] [--help]

Modes:
  (default)   Record snapshot + alert if threshold breached (cron mode)
  --status    Show last 10 snapshots + 1hr trend
  --test      Force send a test Discord alert

Config (~/projects/.env):
  DISCORD_WEBHOOK=https://discord.com/api/webhooks/...
  RAM_WARN_PCT=80
  RAM_CRIT_PCT=90
HELP
}

MODE="record"
for arg in "$@"; do
    case "${arg}" in
        --help)    show_help; exit 0 ;;
        --dry-run) DRY_RUN=true ;;
        --status)  MODE="status" ;;
        --test)    MODE="test" ;;
        *)         ;;
    esac
done

# Load config
load_config() {
    DISCORD_WEBHOOK=""
    RAM_WARN_PCT=80
    RAM_CRIT_PCT=90

    if [[ -f "${ENV_FILE}" ]]; then
        DISCORD_WEBHOOK=$(grep -E '^DISCORD_WEBHOOK=' "${ENV_FILE}" | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
        local warn_pct crit_pct
        warn_pct=$(grep -E '^RAM_WARN_PCT=' "${ENV_FILE}" | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
        crit_pct=$(grep -E '^RAM_CRIT_PCT=' "${ENV_FILE}" | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
        [[ -n "${warn_pct}" ]] && RAM_WARN_PCT="${warn_pct}"
        [[ -n "${crit_pct}" ]] && RAM_CRIT_PCT="${crit_pct}"
    fi
}

# Collect system metrics
collect_metrics() {
    RAM_TOTAL=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    RAM_AVAILABLE=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)
    RAM_USED=$((RAM_TOTAL - RAM_AVAILABLE))
    RAM_PCT=$((RAM_USED * 100 / RAM_TOTAL))
    CPU_LOAD=$(awk '{print $1}' /proc/loadavg)
    DISK_PCT=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}')

    # Active worktrees
    ACTIVE_COUNT=$(sqlite3 "${DB_PATH}" "SELECT COUNT(*) FROM worktrees WHERE status='active';" 2>/dev/null || echo "0")
    WORKTREE_LIST=$(sqlite3 "${DB_PATH}" "SELECT project || '/' || branch || ':' || port FROM worktrees WHERE status='active';" 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
}

# Record snapshot to SQLite
record_snapshot() {
    local json_data
    json_data="{\"cpu_load_1m\": ${CPU_LOAD}, \"disk_used_pct\": ${DISK_PCT}, \"ram_total_mb\": ${RAM_TOTAL}, \"ram_used_mb\": ${RAM_USED}, \"active_worktrees\": ${ACTIVE_COUNT}, \"worktree_list\": \"${WORKTREE_LIST}\"}"

    sqlite3 "${DB_PATH}" "INSERT INTO resource_snapshots (ram_used_pct, ram_available_mb, data) VALUES (${RAM_PCT}, ${RAM_AVAILABLE}, '${json_data}');"
}

# Send Discord alert
send_alert() {
    local level="$1" color="$2" message="$3"

    if [[ -z "${DISCORD_WEBHOOK}" ]]; then
        warn "No DISCORD_WEBHOOK configured — skipping alert"
        return 0
    fi

    # Check cooldown (30 minutes)
    local cooldown_file="${COOLDOWN_DIR}/.last_alert_${level}"
    if [[ -f "${cooldown_file}" ]]; then
        local last_alert now diff
        last_alert=$(cat "${cooldown_file}")
        now=$(date +%s)
        diff=$((now - last_alert))
        if [[ ${diff} -lt 1800 ]]; then
            return 0  # Still in cooldown
        fi
    fi

    local payload
    payload="{\"embeds\": [{\"title\": \"${message}\", \"description\": \"RAM: ${RAM_PCT}% used (${RAM_AVAILABLE}MB free) | Load: ${CPU_LOAD} | Disk: ${DISK_PCT}%\\nActive worktrees: \`${WORKTREE_LIST:-none}\`\\n\\nRun \`wt list\` to see active worktrees.\", \"color\": ${color}}]}"

    run curl -s -H "Content-Type: application/json" -d "${payload}" "${DISCORD_WEBHOOK}"
    date +%s > "${cooldown_file}"
}

# Check thresholds and alert
check_thresholds() {
    if [[ "${RAM_PCT}" -ge "${RAM_CRIT_PCT}" ]]; then
        send_alert "crit" "16711680" "KVM1 RAM CRITICAL — RAM at ${RAM_PCT}%"
    elif [[ "${RAM_PCT}" -ge "${RAM_WARN_PCT}" ]]; then
        send_alert "warn" "16776960" "KVM1 RAM Alert — RAM at ${RAM_PCT}% — approaching limit"
    fi
}

# Show status
show_status() {
    echo "=== Last 10 Snapshots ==="
    sqlite3 -header -column "${DB_PATH}" "
        SELECT strftime('%Y-%m-%d %H:%M', recorded_at) as time,
               ram_used_pct || '%' as ram,
               ram_available_mb || 'MB' as free,
               json_extract(data, '$.cpu_load_1m') as load,
               json_extract(data, '$.active_worktrees') as wts
        FROM resource_snapshots
        ORDER BY recorded_at DESC
        LIMIT 10;
    "

    echo ""
    echo "=== 1hr Trend ==="
    sqlite3 -header -column "${DB_PATH}" "
        SELECT strftime('%H:%M', recorded_at) as time,
               ram_used_pct || '%' as used,
               ram_available_mb || 'MB' as free
        FROM resource_snapshots
        WHERE recorded_at > datetime('now', '-1 hour')
        ORDER BY recorded_at;
    "
}

# Test alert
test_alert() {
    collect_metrics
    info "Sending test alert to Discord..."
    DISCORD_WEBHOOK="${DISCORD_WEBHOOK:?Set DISCORD_WEBHOOK in ~/projects/.env}"

    local payload
    payload="{\"embeds\": [{\"title\": \"KVM1 Test Alert — This is a test\", \"description\": \"RAM: ${RAM_PCT}% used (${RAM_AVAILABLE}MB free) | Load: ${CPU_LOAD} | Disk: ${DISK_PCT}%\\nActive worktrees: \`${WORKTREE_LIST:-none}\`\", \"color\": 3447003}]}"

    curl -s -H "Content-Type: application/json" -d "${payload}" "${DISCORD_WEBHOOK}"
    success "Test alert sent"
}

# Main
load_config

case "${MODE}" in
    record)
        collect_metrics
        record_snapshot
        check_thresholds
        ;;
    status)
        show_status
        ;;
    test)
        test_alert
        ;;
    *)
        error "Unknown mode: ${MODE}"
        exit 1
        ;;
esac
