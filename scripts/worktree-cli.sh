#!/usr/bin/env bash
# worktree-cli.sh — CLI wrapper for port-manager.sh
# Aliased as `wt` via shell integration

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/port-manager.sh
source "${SCRIPT_DIR}/port-manager.sh"

show_help() {
    cat <<'HELP'
Usage: wt <command> [args]

Commands:
  list                     List active worktrees
  list-all                 List all worktrees (including stopped/failed)
  list-project <project>   List worktrees for a specific project
  info <project> <branch>  Show detailed info for a worktree
  search <term>            Search worktrees by project/branch/subdomain
  check                    Find orphaned processes
  cleanup                  Remove stopped/failed entries (interactive)
  stats                    Show statistics and RAM trend
  oldest                   Show the oldest active worktree
  export [file]            Export all data to CSV
  backup [dir]             Backup database
  optimize                 Run VACUUM and ANALYZE on database
  init                     Initialize/reset the database schema
  help                     Show this help message
HELP
}

case "${1:-help}" in
    list)           list_active ;;
    list-all)       list_all ;;
    list-project)   list_by_project "${2:?Usage: wt list-project <project>}" ;;
    info)           get_worktree_info "${2:?Usage: wt info <project> <branch>}" "${3:?Usage: wt info <project> <branch>}" ;;
    search)         search_worktrees "${2:?Usage: wt search <term>}" ;;
    check)          check_orphans ;;
    cleanup)        cleanup_stopped ;;
    stats)          show_stats ;;
    oldest)         show_oldest ;;
    export)         export_csv "${2:-}" ;;
    backup)         backup_db "${2:-}" ;;
    optimize)       optimize_db ;;
    init)           init_db ;;
    help|--help|-h) show_help ;;
    *)              echo "Unknown command: $1"; show_help; exit 1 ;;
esac
