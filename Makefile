.PHONY: help codex-helper helper-app helper-app-open docker-build docker-test docker-test-all docker-build-release docker-shell docker-clean docker-swift-5-9 docker-swift-5-10 docker-swift-6-0

# Default Swift version for single-version commands
SWIFT_VERSION ?= 5.9
CODEX_HELPER_PORT ?= 8765
CODEX_HELPER_TOKEN_FILE ?= $(HOME)/.langtools/helper-token
HELPER_APP ?= build/LangTools Helper.app

help:
	@echo "LangTools.swift Commands"
	@echo "================================"
	@echo ""
	@echo "Testing Commands:"
	@echo "  make docker-test           - Run tests with Swift $(SWIFT_VERSION) (default)"
	@echo "  make docker-test-all       - Run tests with all Swift versions (5.9, 5.10, 6.0)"
	@echo "  make docker-swift-5-9      - Run tests with Swift 5.9"
	@echo "  make docker-swift-5-10     - Run tests with Swift 5.10"
	@echo "  make docker-swift-6-0      - Run tests with Swift 6.0"
	@echo ""
	@echo "Build Commands:"
	@echo "  make docker-build          - Build Docker image with Swift $(SWIFT_VERSION)"
	@echo "  make docker-build-release  - Build package in release mode"
	@echo ""
	@echo "Development Commands:"
	@echo "  make codex-helper          - Start the local Codex helper (port $(CODEX_HELPER_PORT))"
	@echo "  make helper-app            - Build the menu-bar helper app ($(HELPER_APP))"
	@echo "  make helper-app-open       - Build if needed and launch the helper app"
	@echo "  make docker-shell          - Start interactive shell in container"
	@echo "  make docker-clean          - Remove all Docker containers and images"
	@echo ""
	@echo "Examples:"
	@echo "  make docker-test SWIFT_VERSION=5.10"
	@echo "  make docker-test-all"

# Keep the helper token out of argv and the repository; reuse it across restarts.
codex-helper:
	@set -eu; \
	 token_file='$(CODEX_HELPER_TOKEN_FILE)'; \
	 if [ ! -e "$$token_file" ] && [ ! -L "$$token_file" ]; then \
	   (umask 077; mkdir -p "$$(dirname "$$token_file")"; token=$$(openssl rand -hex 32); set -C; printf '%s' "$$token" > "$$token_file"); \
	   echo "Created helper token: $$token_file"; \
	 fi; \
	 echo "Set the helper URL to http://127.0.0.1:$(CODEX_HELPER_PORT) in Settings → Model Access → Codex Subscription."; \
	 echo "Copy the token from $$token_file into the app's helper-token field."; \
	 swift run --package-path cli LangToolsCLI serve --host 127.0.0.1 --port $(CODEX_HELPER_PORT) --token-file "$$token_file"

# Build the double-clickable, ad-hoc signed menu-bar helper app.
helper-app:
	swift build --package-path cli -c release --product LangToolsHelper
	rm -rf "$(HELPER_APP)"
	mkdir -p "$(HELPER_APP)/Contents/MacOS"
	cp cli/.build/release/LangToolsHelper "$(HELPER_APP)/Contents/MacOS/LangToolsHelper"
	printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>CFBundleName</key>\n\t<string>LangTools Helper</string>\n\t<key>CFBundleIdentifier</key>\n\t<string>com.reidchatham.langtools.helper</string>\n\t<key>CFBundleExecutable</key>\n\t<string>LangToolsHelper</string>\n\t<key>CFBundlePackageType</key>\n\t<string>APPL</string>\n\t<key>CFBundleShortVersionString</key>\n\t<string>1.0</string>\n\t<key>CFBundleVersion</key>\n\t<string>1</string>\n\t<key>CFBundleInfoDictionaryVersion</key>\n\t<string>6.0</string>\n\t<key>LSUIElement</key>\n\t<true/>\n\t<key>NSHighResolutionCapable</key>\n\t<true/>\n\t<key>LSMinimumSystemVersion</key>\n\t<string>14.0</string>\n</dict>\n</plist>\n' > "$(HELPER_APP)/Contents/Info.plist"
	codesign --force --deep -s - "$(HELPER_APP)"
	@echo "Built helper app: $(HELPER_APP)"

# One-command build, quit any running instance, and launch.
helper-app-open: helper-app
	@pkill -f 'LangTools Helper.app/Contents/MacOS/LangToolsHelper' 2>/dev/null || true
	@sleep 0.5
	open "$(HELPER_APP)"

# Build Docker image
docker-build:
	docker-compose build langtools-swift-$(shell echo $(SWIFT_VERSION) | tr . -)

# Run tests with default Swift version
docker-test:
	docker-compose run --rm langtools-swift-$(shell echo $(SWIFT_VERSION) | tr . -)

# Run tests with all Swift versions
docker-test-all:
	@echo "Running tests with Swift 5.9..."
	docker-compose run --rm langtools-swift-5-9
	@echo ""
	@echo "Running tests with Swift 5.10..."
	docker-compose run --rm langtools-swift-5-10
	@echo ""
	@echo "Running tests with Swift 6.0..."
	docker-compose run --rm langtools-swift-6-0

# Run tests with specific Swift versions
docker-swift-5-9:
	docker-compose run --rm langtools-swift-5-9

docker-swift-5-10:
	docker-compose run --rm langtools-swift-5-10

docker-swift-6-0:
	docker-compose run --rm langtools-swift-6-0

# Build in release mode
docker-build-release:
	docker-compose run --rm langtools-build

# Interactive shell for debugging
docker-shell:
	docker-compose run --rm langtools-shell

# Clean up Docker resources
docker-clean:
	docker-compose down --rmi all --volumes --remove-orphans
	docker system prune -f
