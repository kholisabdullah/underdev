SHELL := /bin/bash
SCRIPTS := $(shell find . -name '*.sh' -not -path './node_modules/*')

.PHONY: lint validate dry-run test

lint:
	@echo "=== ShellCheck ==="
	@shellcheck $(SCRIPTS)
	@echo "All scripts passed ShellCheck."

validate:
	@echo "=== Structural Validation ==="
	@fail=0; \
	for f in $(SCRIPTS); do \
		if [[ "$$f" == "./scripts/common.sh" ]]; then continue; fi; \
		if ! head -1 "$$f" | grep -q '^#!/usr/bin/env bash'; then \
			echo "FAIL: $$f missing shebang"; fail=1; \
		fi; \
		if ! grep -q '\-\-help' "$$f" 2>/dev/null; then \
			echo "WARN: $$f missing --help support"; \
		fi; \
		if [[ "$$f" == ./scripts/modules/* ]] && ! grep -q 'common.sh' "$$f"; then \
			echo "FAIL: $$f does not source common.sh"; fail=1; \
		fi; \
	done; \
	if [[ $$fail -eq 1 ]]; then exit 1; fi
	@echo "All structural checks passed."

dry-run:
	@echo "=== Dry Run ==="
	DRY_RUN=true bash install.sh

test: lint validate
	@echo "=== All checks passed ==="
