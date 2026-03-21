.PHONY: help docker-build docker-test docker-test-all docker-build-release docker-shell docker-clean docker-swift-5-9 docker-swift-5-10 docker-swift-6-0

# Default Swift version for single-version commands
SWIFT_VERSION ?= 5.9

help:
	@echo "LangTools.swift Docker Commands"
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
	@echo "  make docker-shell          - Start interactive shell in container"
	@echo "  make docker-clean          - Remove all Docker containers and images"
	@echo ""
	@echo "Examples:"
	@echo "  make docker-test SWIFT_VERSION=5.10"
	@echo "  make docker-test-all"

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
