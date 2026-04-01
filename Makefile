LAUNCH_AGENT_DIR = $(HOME)/Library/LaunchAgents
BINARY = ForceHiDPI
PLIST = com.force-hidpi.plist

# Find a user-writable bin directory on PATH, fall back to /usr/local/bin
INSTALL_DIR := $(shell \
	for d in $(HOME)/.local/bin $(HOME)/bin $(HOME)/.bin; do \
		echo "$$PATH" | tr ':' '\n' | grep -qx "$$d" && [ -d "$$d" -o -w "$$(dirname "$$d")" ] && echo "$$d" && break; \
	done)
ifeq ($(INSTALL_DIR),)
	INSTALL_DIR = /usr/local/bin
	NEEDS_SUDO = sudo
endif

.PHONY: help build build-debug release clean install uninstall start stop lint logs
.DEFAULT_GOAL := help

help:
	@echo "force-hidpi - 3840x2160 HiDPI menu bar app for M4/M5 Macs"
	@echo ""
	@echo "  make build          Build (release, optimised)"
	@echo "  make build-debug    Build (debug)"
	@echo "  make install        Install binary and LaunchAgent"
	@echo "  make uninstall      Stop, remove binary and LaunchAgent"
	@echo "  make start          Start the LaunchAgent"
	@echo "  make stop           Stop the LaunchAgent"
	@echo "  make logs           Show recent logs and crash reports"
	@echo "  make lint           Lint and fix Swift sources"
	@echo "  make clean          Remove build artifacts"

build release:
	swift build -c release
	@echo "Built: .build/release/$(BINARY)"

build-debug:
	swift build
	@echo "Built: .build/debug/$(BINARY)"

install:
	@test -f .build/release/$(BINARY) || { echo "error: run 'make build' first"; exit 1; }
	$(NEEDS_SUDO) install -d $(INSTALL_DIR)
	$(NEEDS_SUDO) install -m 755 .build/release/$(BINARY) $(INSTALL_DIR)/force-hidpi
	$(NEEDS_SUDO) xattr -c $(INSTALL_DIR)/force-hidpi
	install -d $(LAUNCH_AGENT_DIR)
	sed 's|/usr/local/bin/force-hidpi|$(INSTALL_DIR)/force-hidpi|g' $(PLIST) > $(LAUNCH_AGENT_DIR)/$(PLIST)
	chmod 644 $(LAUNCH_AGENT_DIR)/$(PLIST)
	@was_running=false; \
	if pgrep -x force-hidpi >/dev/null 2>&1; then \
		was_running=true; \
		echo "Stopping running instance..."; \
		launchctl bootout gui/$$(id -u)/com.force-hidpi 2>/dev/null || true; \
		sleep 1; \
	fi; \
	launchctl bootout gui/$$(id -u)/com.force-hidpi 2>/dev/null || true; \
	launchctl bootstrap gui/$$(id -u) $(LAUNCH_AGENT_DIR)/$(PLIST); \
	if [ "$$was_running" = "true" ]; then \
		echo "Installed force-hidpi to $(INSTALL_DIR) (restarted)"; \
	else \
		echo "Installed force-hidpi to $(INSTALL_DIR) (started)"; \
	fi

uninstall:
	launchctl bootout gui/$$(id -u)/com.force-hidpi 2>/dev/null || true
	$(NEEDS_SUDO) rm -f $(INSTALL_DIR)/force-hidpi
	rm -f $(LAUNCH_AGENT_DIR)/$(PLIST)
	@echo "Uninstalled force-hidpi"

start:
	@launchctl bootout gui/$$(id -u)/com.force-hidpi 2>/dev/null || true
	@sleep 0.5
	launchctl bootstrap gui/$$(id -u) $(LAUNCH_AGENT_DIR)/$(PLIST)
	@echo "Started"

stop:
	launchctl bootout gui/$$(id -u)/com.force-hidpi 2>/dev/null || true
	@echo "Stopped"

logs:
	@echo "=== Recent logs ==="
	@tail -30 /tmp/force-hidpi.log 2>/dev/null || echo "(no log file)"
	@echo ""
	@echo "=== Latest crash report ==="
	@ls -t $(HOME)/Library/Logs/DiagnosticReports/force-hidpi-*.ips 2>/dev/null | head -1 || echo "(none)"

lint:
	swiftlint lint --fix Sources/

clean:
	swift package clean
	rm -rf .build
