# Rename claude-relay to clay — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the rename of claude-relay to clay across all live/operational files.

**Architecture:** Find-and-replace across 3 files. One bug fix in the detection check. Stage existing unstaged work. Single commit at the end.

**Tech Stack:** Bash, ShellCheck

---

## Task 1: Fix bug and stage 09-clay.sh

**Files:**
- Modify: `scripts/modules/09-clay.sh` (line with `npm list -g clay`)

- [ ] **Step 1: Fix the npm detection check**

Change `npm list -g clay` to `npm list -g clay-server` on the detection line:

```bash
# Before (broken):
if command -v clay-server &>/dev/null || npm list -g clay &>/dev/null 2>&1; then

# After (fixed):
if command -v clay-server &>/dev/null || npm list -g clay-server &>/dev/null 2>&1; then
```

- [ ] **Step 2: Stage the file**

Run: `git add scripts/modules/09-clay.sh`

---

## Task 2: Update README.md

**Files:**
- Modify: `README.md` (lines 20, 41, 49, 52, 81, 88, 112)

- [ ] **Step 1: Replace all occurrences**

Apply these replacements across the file:

| Line | Old | New |
|------|-----|-----|
| 20 | `[claude-relay](https://github.com/chadbyte/claude-relay)` | `[clay](https://github.com/chadbyte/clay)` |
| 41 | `Open Claude Relay PWA on your phone or tablet` | `Open Clay PWA on your phone or tablet` |
| 49 | `**[claude-relay](https://github.com/chadbyte/claude-relay)**` | `**[clay](https://github.com/chadbyte/clay)**` |
| 52 | `Open Claude Relay PWA on your phone or tablet, select root project folder, and create worktrees via [claude-relay](https://github.com/chadbyte/claude-relay) terminal.` | `Open Clay PWA on your phone or tablet, select root project folder, and create worktrees via [clay](https://github.com/chadbyte/clay) terminal.` |
| 81 | `claude-relay.underdev.cloud      -> localhost:2633` | `clay.underdev.cloud              -> localhost:2633` |
| 88 | `├── claude-relay` | `├── clay` |
| 112 | `09  claude-relay` | `09  clay` |

- [ ] **Step 2: Stage the file**

Run: `git add README.md`

---

## Task 3: Update install.sh

**Files:**
- Modify: `install.sh:34`

- [ ] **Step 1: Replace the module label**

```bash
# Before:
  09  claude-relay (auto-install)

# After:
  09  clay (auto-install)
```

- [ ] **Step 2: Stage the file**

Run: `git add install.sh`

---

## Task 4: Validate and commit

- [ ] **Step 1: Run ShellCheck on modified scripts**

Run: `shellcheck scripts/modules/09-clay.sh install.sh`
Expected: No errors

- [ ] **Step 2: Verify no remaining claude-relay references in live files**

Run: `grep -ri 'claude.relay\|claude-relay' README.md install.sh scripts/`
Expected: No output (no matches)

- [ ] **Step 3: Commit all changes**

```bash
git add README.md install.sh scripts/modules/09-clay.sh
git commit -m "feat: rename claude-relay to clay across all live files

- Update GitHub links to chadbyte/clay
- Update npm package to clay-server
- Update Caddy vhost to clay.underdev.cloud
- Fix npm detection check (clay -> clay-server)"
```
