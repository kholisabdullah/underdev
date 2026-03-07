#!/usr/bin/env bash
# install-versions.sh — Interactive PHP and Node.js version installer

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

show_help() {
    cat <<'HELP'
Usage: install-versions.sh [--dry-run] [--help]

Interactive installer for PHP and Node.js versions.
Shows currently installed versions and recommends stable releases.

PHP: Compiled via phpenv (10-20 minutes per version)
Node: Installed via nvm (< 1 minute)
HELP
}

parse_common_flags "$@" || { show_help; exit 0; }

# Load phpenv
export PHPENV_ROOT="${HOME}/.phpenv"
export PATH="${PHPENV_ROOT}/bin:${PATH}"
eval "$(phpenv init -)" 2>/dev/null || true

# Load nvm
export NVM_DIR="${HOME}/.nvm"
# shellcheck source=/dev/null
[[ -s "${NVM_DIR}/nvm.sh" ]] && source "${NVM_DIR}/nvm.sh"

install_php_versions() {
    echo ""
    echo "=== PHP Version Installer ==="
    echo ""

    # Show installed versions
    if command -v phpenv &>/dev/null; then
        echo "Currently installed:"
        phpenv versions 2>/dev/null || echo "  (none)"
    else
        warn "phpenv not found. Run module 02 first."
        return 1
    fi

    echo ""
    echo "Recommended versions:"
    echo "  8.3  (latest stable)"
    echo "  8.2  (LTS)"
    echo "  8.1  (security fixes only)"
    echo ""
    read -rp "Enter PHP versions to install (comma-separated, e.g. 8.3,8.2): " php_input

    if [[ -z "${php_input}" ]]; then
        info "No PHP versions selected — skipping"
        return 0
    fi

    IFS=',' read -ra versions <<< "${php_input}"
    for version in "${versions[@]}"; do
        version=$(echo "${version}" | tr -d ' ')

        if phpenv versions 2>/dev/null | grep -q "${version}"; then
            info "PHP ${version} already installed — skipping"
            continue
        fi

        info "Compiling PHP ${version} (this takes 10-20 minutes)..."
        run phpenv install "${version}"

        # Set up FPM config for this version
        local fpm_dir="${PHPENV_ROOT}/fpm"
        local template="${fpm_dir}/pool-template.conf"
        if [[ -f "${template}" ]]; then
            local conf="${fpm_dir}/php${version}-fpm.conf"
            sed -e "s|__USER__|${USER}|g" -e "s|__VERSION__|${version}|g" "${template}" > "${conf}"
            info "FPM pool config generated for PHP ${version}"
        fi

        success "PHP ${version} installed"
    done

    # Set global default
    echo ""
    read -rp "Set global default PHP version (e.g. 8.3): " default_php
    if [[ -n "${default_php}" ]]; then
        run phpenv global "${default_php}"
        success "Default PHP set to ${default_php}"
    fi

    # PECL extensions
    echo ""
    echo "Install PECL extensions? (redis, imagick, xdebug, swoole)"
    read -rp "Enter extensions (comma-separated, or skip): " ext_input

    if [[ -n "${ext_input}" && "${ext_input}" != "skip" ]]; then
        IFS=',' read -ra extensions <<< "${ext_input}"
        for ext in "${extensions[@]}"; do
            ext=$(echo "${ext}" | tr -d ' ')
            info "Installing PECL extension: ${ext}"
            run pecl install "${ext}" || warn "Failed to install ${ext}"
        done
    fi
}

install_node_versions() {
    echo ""
    echo "=== Node.js Version Installer ==="
    echo ""

    if ! command -v nvm &>/dev/null; then
        warn "nvm not found. Run module 03 first."
        return 1
    fi

    echo "Currently installed:"
    nvm ls 2>/dev/null || echo "  (none)"

    echo ""
    echo "Recommended versions:"
    echo "  20  (LTS - Active)"
    echo "  18  (LTS - Maintenance)"
    echo ""
    read -rp "Enter Node versions to install (comma-separated, e.g. 20,18): " node_input

    if [[ -z "${node_input}" ]]; then
        info "No Node versions selected — skipping"
        return 0
    fi

    IFS=',' read -ra versions <<< "${node_input}"
    for version in "${versions[@]}"; do
        version=$(echo "${version}" | tr -d ' ')
        info "Installing Node.js ${version}..."
        run nvm install "${version}"
        success "Node.js ${version} installed"
    done
}

# Main
assert_not_root
install_php_versions
install_node_versions
success "Version installation complete"
