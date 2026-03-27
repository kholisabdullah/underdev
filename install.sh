#!/usr/bin/env bash
# install.sh — VPS Worktree Manager installer
# Usage: curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash
#    or: bash install.sh [--dry-run] [--help]

set -euo pipefail

# When piped via `curl | bash`, BASH_SOURCE[0] is unbound and no other files
# exist on disk. Clone the repo to a temp dir and re-execute from there.
if [[ -z "${BASH_SOURCE[0]:-}" ]] || [[ "$(basename "${BASH_SOURCE[0]:-bash}")" == "bash" ]]; then
    REPO_URL="https://github.com/kholisabdullah/underdev"
    TMP_DIR="$(mktemp -d)"
    echo "Cloning installer to ${TMP_DIR} ..."
    git clone --depth=1 "${REPO_URL}" "${TMP_DIR}/underdev"
    exec bash "${TMP_DIR}/underdev/install.sh" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/scripts/common.sh"

show_help() {
    cat <<'HELP'
Usage: install.sh [--dry-run] [--help]

VPS Worktree Manager installer. Runs 11 modules in sequence to set up
a complete development environment with PHP-FPM, Caddy, Supervisor,
and worktree management on Ubuntu.

Requirements:
  - Ubuntu (any recent version)
  - 4GB+ RAM
  - Not running as root (sudo used where needed)

Modules:
  01  System dependencies + database clients
  02  phpenv (PHP version manager)
  03  nvm + Node.js LTS
  04  PHP-FPM pool configuration
  05  Caddy reverse proxy
  06  Supervisor (user-level)
  07  Tailscale VPN
  08  Claude Code
  09  clay (auto-install)
  10  Project structure + SQLite init
  11  Shell integration (PATH, aliases)

Post-install:
  - Run install-versions.sh to compile PHP versions
HELP
}

parse_common_flags "$@" || { show_help; exit 0; }

# Validation
assert_not_root
assert_ubuntu
assert_min_ram 4000

# Banner
echo ""
echo "=========================================================="
echo "       VPS Worktree Manager -- Installer                  "
echo "=========================================================="
echo "  11 modules will be installed in sequence.               "
echo "  Estimated time: 10-30 minutes.                          "
echo "  Idempotent: safe to re-run.                             "
echo "=========================================================="
echo ""

if [[ "${DRY_RUN}" == "true" ]]; then
    warn "DRY-RUN MODE — no changes will be made"
    echo ""
fi

# Confirm
if [[ "${DRY_RUN}" != "true" ]]; then
    read -rp "Proceed with installation? (y/N) " confirm
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        info "Installation cancelled."
        exit 0
    fi
fi

# Module runner
MODULES_DIR="${SCRIPT_DIR}/scripts/modules"
PASSED=0
FAILED=0
FAILED_MODULES=()

run_module() {
    local module="$1"
    local name
    name=$(basename "${module}" .sh)

    echo ""
    echo "--------------------------------------------------"
    info "Running module: ${name}"
    echo "--------------------------------------------------"

    local -a module_args=()
    [[ "${DRY_RUN}" == "true" ]] && module_args+=("--dry-run")

    if bash "${module}" "${module_args[@]+"${module_args[@]}"}"; then
        success "Module ${name} completed"
        PASSED=$((PASSED + 1))
    else
        error "Module ${name} FAILED"
        FAILED=$((FAILED + 1))
        FAILED_MODULES+=("${name}")
        return 1
    fi
}

# Run all modules in order
for module in "${MODULES_DIR}"/[0-9][0-9]-*.sh; do
    if ! run_module "${module}"; then
        error "Installation stopped at module: $(basename "${module}" .sh)"
        error "Fix the issue and re-run install.sh (idempotent — completed modules will skip)."
        exit 1
    fi
done

# Summary
echo ""
echo "=========================================================="
echo "       Installation Complete!                             "
echo "=========================================================="
echo "  Modules passed: ${PASSED}/11                            "
echo "=========================================================="
echo ""
info "Next steps:"
info "  1. Source your shell:  source ~/.bashrc"
info "  2. Install PHP/Node versions:  bash scripts/install-versions.sh"
info "  3. Start building!"
echo ""

if [[ "${FAILED}" -gt 0 ]]; then
    warn "Failed modules: ${FAILED_MODULES[*]}"
    exit 1
fi
