# Replace clay with Happy Coder — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the ToS-violating `clay-server` module with `happy-coder`, a ToS-compliant mobile interface using Happy's public relay.

**Architecture:** Delete `09-clay.sh` and create `09-happy.sh` in its place — same module slot, much simpler script (install only, no Supervisor/Caddy/port). Update `install.sh` to run `happy --auth` interactively as the final step after all modules complete. Update README and a comment in `03-nvm-node.sh`.

**Tech Stack:** Bash, `happy-coder` npm package, nvm

---

## File Map

| Action | File |
|--------|------|
| **Delete** | `scripts/modules/09-clay.sh` |
| **Create** | `scripts/modules/09-happy.sh` |
| **Modify** | `install.sh` — line 34 (module description) + lines 122-126 (post-install steps + auth) |
| **Modify** | `README.md` — 7 occurrences of clay/Clay across 7 lines |
| **Modify** | `scripts/modules/03-nvm-node.sh` — line 15 (help comment) |

---

## Task 1: Create `09-happy.sh`

**Files:**
- Create: `scripts/modules/09-happy.sh`

- [ ] **Step 1: Create the new module file**

```bash
#!/usr/bin/env bash
# 09-happy.sh — Install Happy Coder for mobile access

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/../common.sh"

show_help() {
    cat <<'HELP'
Usage: 09-happy.sh [--dry-run] [--help]

Installs happy-coder for mobile access to Claude Code:
  - Installs happy-coder globally via npm
  - Auth (QR pairing) is run by install.sh at the end
HELP
}

parse_common_flags "$@" || { show_help; exit 0; }

# Source nvm so npm is available
export NVM_DIR="${HOME}/.nvm"
# shellcheck source=/dev/null
[[ -s "${NVM_DIR}/nvm.sh" ]] && source "${NVM_DIR}/nvm.sh"

install_happy() {
    if command -v happy &>/dev/null || npm list -g happy-coder &>/dev/null 2>&1; then
        info "happy-coder already installed — skipping"
        return 0
    fi

    if ! command -v npm &>/dev/null; then
        error "npm not found. Run module 03 (nvm-node) first."
        exit 1
    fi

    info "Installing happy-coder..."
    run npm install -g happy-coder
    success "happy-coder installed"
}

# Main
assert_not_root
install_happy
success "Module 09 complete: happy-coder installed"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/modules/09-happy.sh
```

- [ ] **Step 3: Verify dry-run works**

```bash
bash scripts/modules/09-happy.sh --dry-run
```

Expected output: Module runs without error, prints "happy-coder installed" or "already installed — skipping".

---

## Task 2: Delete `09-clay.sh`

**Files:**
- Delete: `scripts/modules/09-clay.sh`

> **Critical:** Must be deleted, not left alongside `09-happy.sh`. The `install.sh` glob `[0-9][0-9]-*.sh` sorts lexicographically — both files present would cause clay to execute before happy.

- [ ] **Step 1: Delete the file**

```bash
git rm scripts/modules/09-clay.sh
```

- [ ] **Step 2: Verify only one module 09 exists**

```bash
ls scripts/modules/09-*.sh
```

Expected: Only `scripts/modules/09-happy.sh` listed.

---

## Task 3: Update `install.sh`

**Files:**
- Modify: `install.sh`

Two changes: module description line (line 34) + post-install block (lines 122-126).

- [ ] **Step 1: Update module 09 description in the help text**

In `install.sh`, find line 34:
```
  09  clay (auto-install)
```

Replace with:
```
  09  happy-coder (mobile access)
```

- [ ] **Step 2: Update the post-install steps and add happy --auth**

Find lines 122-126:
```bash
info "Next steps:"
info "  1. Source your shell:  source ~/.bashrc"
info "  2. Install PHP/Node versions:  bash scripts/install-versions.sh"
info "  3. Start building!"
echo ""
```

Replace with:
```bash
info "Next steps:"
info "  1. Source your shell:  source ~/.bashrc"
info "  2. Install PHP/Node versions:  bash scripts/install-versions.sh"
info "  3. Start building!"
echo ""

# Happy Coder auth — run interactively after all modules complete
# Skip in dry-run: this is an interactive QR pairing step, not idempotent
if [[ "${DRY_RUN}" != "true" ]]; then
    # nvm must be sourced: the parent shell doesn't inherit it from module subprocesses
    export NVM_DIR="${HOME}/.nvm"
    [[ -s "${NVM_DIR}/nvm.sh" ]] && source "${NVM_DIR}/nvm.sh"
    info "Pairing Happy Coder with your mobile app..."
    info "Scan the QR code below with the Happy app on your phone."
    echo ""
    happy --auth || true
fi
```

- [ ] **Step 3: Verify dry-run still works**

```bash
bash install.sh --dry-run
```

Expected: All modules listed, no errors, script completes without launching `happy --auth`.

---

## Task 4: Update `README.md`

**Files:**
- Modify: `README.md`

Seven occurrences across seven lines. Make all changes in one pass.

- [ ] **Step 1: Update the feature bullet (line 20)**

Find:
```
- **[clay](https://github.com/chadbyte/clay)** for mobile development — control Claude Code from your phone or tablet via a PIN-protected PWA
```

Replace with:
```
- **[Happy Coder](https://happy.engineering)** for mobile development — control Claude Code from your phone or tablet via a native Android app with E2E encryption
```

- [ ] **Step 2: Update the "how it works" paragraph (line 49)**

Find:
```
Claude Code runs on the VPS. You connect via **[clay](https://github.com/chadbyte/clay)** — a zero-install PWA with PIN auth and push notifications for permission prompts
```

Replace with:
```
Claude Code runs on the VPS. You connect via **[Happy Coder](https://happy.engineering)** — a native Android/iOS app with E2E encryption, push notifications, and voice coding support
```

- [ ] **Step 3: Update the mobile workflow code block (line 41)**

Find:
```
Open Clay PWA on your phone or tablet
```

Replace with:
```
Open the Happy app on your phone or tablet
```

- [ ] **Step 4: Update the Usage line (line 52)**

Find:
```
Open Clay PWA on your phone or tablet, select root project folder, and create worktrees via [clay](https://github.com/chadbyte/clay) terminal.
```

Replace with:
```
Open the Happy app on your phone or tablet, select a session, and start coding with Claude Code.
```

- [ ] **Step 5: Update the architecture diagram (line 81)**

Find:
```
  └── clay.underdev.cloud              -> localhost:2633
```

Delete this line entirely (Happy uses public relay — no Caddy vhost).

- [ ] **Step 6: Update the Supervisor process list (line 88)**

Find:
```
  ├── clay
```

Delete this line entirely (Happy needs no Supervisor daemon).

- [ ] **Step 7: Update the modules list (line 112)**

Find:
```
09  clay
```

Replace with:
```
09  happy-coder
```

- [ ] **Step 8: Verify no clay references remain (case-insensitive)**

```bash
grep -ni "clay" README.md
```

Expected: zero results.

---

## Task 5: Update `03-nvm-node.sh`

**Files:**
- Modify: `scripts/modules/03-nvm-node.sh`

- [ ] **Step 1: Update the help comment (line 15)**

Find:
```
(not deferred) because Claude Code and clay require it.
```

Replace with:
```
(not deferred) because Claude Code and happy-coder require it.
```

---

## Task 6: Commit

- [ ] **Step 1: Stage all changes**

```bash
git add scripts/modules/09-happy.sh
git add scripts/modules/09-clay.sh   # already removed via git rm in Task 2
git add install.sh
git add README.md
git add scripts/modules/03-nvm-node.sh
```

- [ ] **Step 2: Verify staged diff looks right**

```bash
git diff --cached --stat
```

Expected:
```
 README.md                        | ...
 install.sh                       | ...
 scripts/modules/03-nvm-node.sh   | ...
 scripts/modules/09-clay.sh       | ... (deleted)
 scripts/modules/09-happy.sh      | ... (new file)
 5 files changed, ...
```

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat: replace clay with Happy Coder for mobile access

Removes clay (ToS violation — uses Agent SDK) and replaces with
happy-coder (ToS-compliant PTY relay). Public relay used — no
Supervisor daemon, no Caddy vhost needed. Auth runs interactively
at end of install.sh via happy --auth.

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Verification Checklist

After all tasks complete, verify:

- [ ] `ls scripts/modules/09-*.sh` → only `09-happy.sh` exists
- [ ] `grep -r "clay" scripts/` → zero results
- [ ] `grep -ni "clay" README.md` → zero results
- [ ] `bash install.sh --dry-run` → completes without error
- [ ] `bash scripts/modules/09-happy.sh --dry-run` → completes without error
