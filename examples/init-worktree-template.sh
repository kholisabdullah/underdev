#!/usr/bin/env bash
# init-worktree-template.sh — Per-project worktree initialization template
# Copy this to your project and set PROJECT variable below.

set -euo pipefail

##############################
# CUSTOMIZE THIS PER PROJECT #
##############################
PROJECT="my-project"
DOMAIN="underdev.cloud"
##############################

PROJECTS_DIR="${HOME}/projects"
SCRIPTS_DIR="${PROJECTS_DIR}/scripts"

# Source shared libraries
# shellcheck source=scripts/common.sh
source "${SCRIPTS_DIR}/common.sh"
# shellcheck source=scripts/port-manager.sh
source "${SCRIPTS_DIR}/port-manager.sh"

show_help() {
    cat <<HELP
Usage: init-worktree-template.sh <branch-name> [--dry-run] [--help]

Creates a new worktree for ${PROJECT}:
  1. Git worktree at .worktrees/{folder}/
  2. PHP/Node version detection
  3. Environment + Claude settings copy
  4. Database strategy (shared vs copy)
  5. Dependency install + asset build
  6. Caddy vhost + SQLite registration

Environment variables:
  DB_COPY_STRATEGY=shared|copy   Skip interactive database prompt
HELP
}

for arg in "$@"; do
    case "${arg}" in
        --help)    show_help; exit 0 ;;
        --dry-run) DRY_RUN=true ;;
        *)         ;;
    esac
done

BRANCH="${1:?Usage: init-worktree-template.sh <branch-name>}"

# Sanitize branch name for folder: feature/auth -> feat-auth
FOLDER=$(echo "${BRANCH}" | sed 's|/|-|g' | sed 's|feature|feat|g')
SUBDOMAIN="${FOLDER}-${PROJECT}"
PROJECT_DIR="${PROJECTS_DIR}/${PROJECT}"
WORKTREE_DIR="${PROJECT_DIR}/.worktrees/${FOLDER}"

# Initialize DB tracking variables
DB_DRIVER=""
DB_NAME=""
DB_ISOLATION="shared"

if [[ -d "${WORKTREE_DIR}" ]]; then
    error "Worktree already exists: ${WORKTREE_DIR}"
    exit 1
fi

info "Creating worktree: ${PROJECT}/${BRANCH} -> ${FOLDER}"

# Step 1: Create git worktree
create_worktree() {
    info "Creating git worktree..."
    run mkdir -p "${PROJECT_DIR}/.worktrees"
    run git -C "${PROJECT_DIR}" worktree add "${WORKTREE_DIR}" -b "${BRANCH}" 2>/dev/null || \
        run git -C "${PROJECT_DIR}" worktree add "${WORKTREE_DIR}" "${BRANCH}"
    success "Git worktree created"
}

# Step 2: Detect and set versions
setup_versions() {
    # PHP version
    if [[ -f "${PROJECT_DIR}/.php-version" ]]; then
        run cp "${PROJECT_DIR}/.php-version" "${WORKTREE_DIR}/.php-version"
        local php_version
        php_version=$(cat "${WORKTREE_DIR}/.php-version")
        info "PHP version: ${php_version}"

        # Activate phpenv version
        if command -v phpenv &>/dev/null; then
            export PHPENV_VERSION="${php_version}"
        fi
    fi

    # Node version
    if [[ -f "${PROJECT_DIR}/.nvmrc" ]]; then
        run cp "${PROJECT_DIR}/.nvmrc" "${WORKTREE_DIR}/.nvmrc"
        local node_version
        node_version=$(cat "${WORKTREE_DIR}/.nvmrc")
        info "Node version: ${node_version}"

        # Activate nvm version
        export NVM_DIR="${HOME}/.nvm"
        # shellcheck source=/dev/null
        [[ -s "${NVM_DIR}/nvm.sh" ]] && source "${NVM_DIR}/nvm.sh"
        nvm use "${node_version}" 2>/dev/null || nvm install "${node_version}"
    fi
}

# Step 3: Copy environment files
copy_env() {
    if [[ -f "${PROJECT_DIR}/.env" ]]; then
        info "Copying .env..."
        run cp "${PROJECT_DIR}/.env" "${WORKTREE_DIR}/.env"
        success ".env copied"
    else
        warn "No .env found in main checkout"
    fi

    # Copy Claude settings
    if [[ -d "${PROJECT_DIR}/.claude" ]]; then
        info "Copying .claude/ settings..."
        run cp -r "${PROJECT_DIR}/.claude" "${WORKTREE_DIR}/.claude"
        success "Claude settings copied"
    fi
}

# Step 4: Database strategy
setup_database() {
    local strategy="${DB_COPY_STRATEGY:-}"

    # Read DB driver from .env
    local db_driver=""
    if [[ -f "${WORKTREE_DIR}/.env" ]]; then
        db_driver=$(grep -E '^DB_CONNECTION=' "${WORKTREE_DIR}/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" || echo "")
    fi

    if [[ -z "${db_driver}" ]]; then
        info "No DB_CONNECTION found — skipping database setup"
        DB_ISOLATION="none"
        return 0
    fi

    # Interactive prompt if strategy not set
    if [[ -z "${strategy}" ]]; then
        echo ""
        echo "Database strategy for this worktree?"
        echo "  [1] Shared — Use main database (fast, no isolation)"
        echo "  [2] Copy  — Isolated database (safe for migrations)"
        echo ""
        read -rp "Choice [1]: " choice
        strategy=$([[ "${choice}" == "2" ]] && echo "copy" || echo "shared")
    fi

    if [[ "${strategy}" == "copy" ]]; then
        local source_db
        source_db=$(grep -E '^DB_DATABASE=' "${WORKTREE_DIR}/.env" | cut -d= -f2 | tr -d '"' | tr -d "'")
        local target_db="${source_db}_${FOLDER}"

        info "Copying database: ${source_db} -> ${target_db}"
        if bash "${SCRIPTS_DIR}/db-copy-helper.sh" "${WORKTREE_DIR}/.env" "${target_db}"; then
            # Update .env with new database name
            sed -i "s|^DB_DATABASE=.*|DB_DATABASE=${target_db}|" "${WORKTREE_DIR}/.env"
            DB_NAME="${target_db}"
            DB_ISOLATION="isolated"
            success "Isolated database created: ${target_db}"
        else
            local exit_code=$?
            if [[ ${exit_code} -eq 10 ]]; then
                warn "Database copy failed (no admin credentials)."
                echo ""
                echo "How to proceed?"
                echo "  [1] Use shared database instead"
                echo "  [2] Create worktree anyway, fix database later"
                echo ""
                read -rp "Choice [2]: " fallback
                DB_ISOLATION="shared"
                if [[ "${fallback}" == "1" ]]; then
                    info "Using shared database"
                else
                    info "Continuing without database setup — fix later"
                fi
            else
                error "Database copy failed"
                DB_ISOLATION="shared"
            fi
        fi
    else
        info "Using shared database"
        DB_ISOLATION="shared"
    fi

    DB_DRIVER="${db_driver}"
}

# Step 5: Install dependencies
install_deps() {
    cd "${WORKTREE_DIR}"

    if [[ -f "composer.json" ]]; then
        info "Running composer install..."
        run composer install --no-interaction --prefer-dist
    fi

    if [[ -f "package.json" ]]; then
        info "Running npm install..."
        run npm install

        if grep -q '"build"' package.json 2>/dev/null; then
            info "Building assets..."
            run npm run build
        fi
    fi

    # Laravel-specific
    if [[ -f "artisan" ]]; then
        info "Running Laravel setup..."
        run php artisan key:generate --force 2>/dev/null || true
        run php artisan config:clear 2>/dev/null || true
    fi

    success "Dependencies installed"
}

# Step 6: Allocate port and register
register_worktree() {
    info "Allocating port..."
    local port
    port=$(add_worktree "${PROJECT}" "${BRANCH}" "${FOLDER}" "${SUBDOMAIN}" "" "${DB_DRIVER}" "${DB_NAME}" "${DB_ISOLATION}")
    info "Port allocated: ${port}"

    # Detect PHP version for FPM socket
    local php_version
    php_version=$(cat "${WORKTREE_DIR}/.php-version" 2>/dev/null || echo "8.3")
    local fpm_socket="/run/php/php${php_version}-fpm.sock"

    # Create Caddy vhost
    local vhost="/etc/caddy/sites/${SUBDOMAIN}.caddy"
    info "Creating Caddy vhost: ${SUBDOMAIN}.${DOMAIN}"
    run sudo tee "${vhost}" >/dev/null <<CADDY
${SUBDOMAIN}.${DOMAIN} {
    root * ${WORKTREE_DIR}/public
    php_fastcgi unix/${fpm_socket}
    file_server
}
CADDY

    info "Reloading Caddy..."
    run sudo caddy reload --config /etc/caddy/Caddyfile

    success "Worktree registered and accessible"

    echo ""
    success "==============================================="
    success "  Worktree ready!"
    success "  URL: https://${SUBDOMAIN}.${DOMAIN}"
    success "  Port: ${port}"
    success "  Path: ${WORKTREE_DIR}"
    success "==============================================="
}

# Execute all steps
create_worktree
setup_versions
copy_env
setup_database
install_deps
register_worktree
