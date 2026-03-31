PREFIX ?= /usr/local
INSTALL_DIR = $(PREFIX)/bin
LAUNCH_AGENT_DIR = $(HOME)/Library/LaunchAgents

CXX = clang++
CXXFLAGS = -std=c++17 -ObjC++ -fobjc-arc -mmacosx-version-min=14.0 -Wall -Wextra -Wno-unused-parameter
CXXFLAGS_NO_ARC = -std=c++17 -ObjC++ -fno-objc-arc -mmacosx-version-min=14.0 -Wall -Wextra -Wno-unused-parameter
FRAMEWORKS = -framework CoreGraphics -framework Foundation -framework IOKit
LDFLAGS = -ldl $(FRAMEWORKS)

BUILD_DIR = build
SRC_DIR = src
TEST_DIR = tests

SRCS = $(wildcard $(SRC_DIR)/*.mm)
OBJS = $(patsubst $(SRC_DIR)/%.mm,$(BUILD_DIR)/%.o,$(SRCS))
TEST_SRCS = $(TEST_DIR)/test_main.mm

BINARY = force-hidpi
TEST_BINARY = $(BUILD_DIR)/test-runner

.PHONY: help all clean test install uninstall start-daemon stop-daemon lint
.DEFAULT_GOAL := help

help:
	@echo "force-hidpi - 3840x2160 HiDPI on M4/M5 Macs"
	@echo ""
	@echo "  make build          Build the binary"
	@echo "  make test           Run unit tests"
	@echo "  make install        Install binary and LaunchAgent (prompts for sudo)"
	@echo "  make uninstall      Stop daemon, remove binary and LaunchAgent"
	@echo "  make start-daemon   Start the LaunchAgent"
	@echo "  make stop-daemon    Stop the LaunchAgent"
	@echo "  make clean          Remove build artifacts"

all build: $(BINARY)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# virtual_display.mm must be compiled without ARC - NSInvocation's
# getReturnValue and setArgument for struct/error pointer types are
# incompatible with ARC's automatic retain/release semantics
$(BUILD_DIR)/virtual_display.o: $(SRC_DIR)/virtual_display.mm | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS_NO_ARC) -I$(SRC_DIR) -c $< -o $@

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.mm | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -I$(SRC_DIR) -c $< -o $@

$(BINARY): $(OBJS)
	$(CXX) $(CXXFLAGS) $(LDFLAGS) $^ -o $@

# Tests: compile test sources + all src except main.mm
TEST_OBJS = $(filter-out $(BUILD_DIR)/main.o,$(OBJS))

$(TEST_BINARY): $(TEST_SRCS) $(TEST_OBJS) | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -I$(SRC_DIR) $(LDFLAGS) $(TEST_SRCS) $(TEST_OBJS) -o $@

test: $(TEST_BINARY)
	./$(TEST_BINARY)

install: $(BINARY)
	sudo install -d $(INSTALL_DIR)
	sudo install -m 755 $(BINARY) $(INSTALL_DIR)/$(BINARY)
	install -d $(LAUNCH_AGENT_DIR)
	install -m 644 -o $$(id -u) -g $$(id -g) com.force-hidpi.plist $(LAUNCH_AGENT_DIR)/com.force-hidpi.plist
	launchctl bootout gui/$$(id -u)/com.force-hidpi 2>/dev/null || true
	launchctl bootstrap gui/$$(id -u) $(LAUNCH_AGENT_DIR)/com.force-hidpi.plist
	@echo "Installed $(BINARY) to $(INSTALL_DIR)"
	@echo "Installed LaunchAgent (enabled at login)"

uninstall:
	launchctl bootout gui/$$(id -u)/com.force-hidpi 2>/dev/null || true
	sudo rm -f $(INSTALL_DIR)/$(BINARY)
	rm -f $(LAUNCH_AGENT_DIR)/com.force-hidpi.plist
	@echo "Uninstalled $(BINARY)"

start-daemon:
	launchctl bootstrap gui/$$(id -u) $(LAUNCH_AGENT_DIR)/com.force-hidpi.plist
	@echo "Daemon started"

stop-daemon:
	launchctl bootout gui/$$(id -u)/com.force-hidpi
	@echo "Daemon stopped"

clean:
	rm -rf $(BUILD_DIR) $(BINARY)

lint:
	@echo "No linter configured (private API code)"
