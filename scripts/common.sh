# common.sh — sourced by all scripts, not executed directly
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
#   or:  source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Dry-run mode
DRY_RUN="${DRY_RUN:-false}"

info()    { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
success() { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC} %s\n" "$*" >&2; }
error()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }

# Run a command, or print it in dry-run mode
run() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        info "[DRY-RUN] $*"
    else
        "$@"
    fi
}

# Parse common flags (call at top of every script)
parse_common_flags() {
    for arg in "$@"; do
        case "${arg}" in
            --dry-run) DRY_RUN=true ;;
            --help)    return 1 ;;  # Caller should handle
            *)         ;;
        esac
    done
    return 0
}

# Check if running as root (should not be)
assert_not_root() {
    if [[ "${EUID}" -eq 0 ]]; then
        error "Do not run this script as root. Run as your regular user — sudo is used where needed."
        exit 1
    fi
}

# Check Ubuntu
assert_ubuntu() {
    if [[ ! -f /etc/os-release ]] || ! grep -qi 'ubuntu' /etc/os-release; then
        error "This script requires Ubuntu."
        exit 1
    fi
}

# Check minimum RAM (in MB)
assert_min_ram() {
    local min_mb="${1:-4000}"
    local total_mb
    total_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
    if [[ "${total_mb}" -lt "${min_mb}" ]]; then
        warn "RAM is ${total_mb}MB (recommended: ${min_mb}MB+). Installation may be slow or fail on memory-intensive steps."
    fi
}
