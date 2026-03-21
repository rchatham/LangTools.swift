# Docker Setup for Linux Testing

This directory contains Docker configuration for testing LangTools.swift on Linux with multiple Swift versions.

## Prerequisites

- Docker installed and running
- Docker Compose (included with Docker Desktop)
- Make (optional, for convenient commands)

## Quick Start

```bash
# Run tests with Swift 5.9 (default)
make docker-test

# Run tests with all Swift versions (5.9, 5.10, 6.0)
make docker-test-all

# View all available commands
make help
```

## Available Commands

### Testing Commands

```bash
# Test with default Swift version (5.9)
make docker-test

# Test with all Swift versions
make docker-test-all

# Test with specific Swift versions
make docker-swift-5-9
make docker-swift-5-10
make docker-swift-6-0
```

### Build Commands

```bash
# Build Docker image
make docker-build

# Build package in release mode
make docker-build-release
```

### Development Commands

```bash
# Start interactive shell in container
make docker-shell

# Clean up Docker resources
make docker-clean
```

## Manual Docker Commands

If you prefer not to use Make, you can use docker-compose directly:

```bash
# Run tests with Swift 5.9
docker-compose run --rm langtools-swift-5-9

# Run tests with Swift 5.10
docker-compose run --rm langtools-swift-5-10

# Run tests with Swift 6.0
docker-compose run --rm langtools-swift-6-0

# Build release
docker-compose run --rm langtools-build

# Interactive shell
docker-compose run --rm langtools-shell

# Run specific test suite
docker-compose run --rm langtools-swift-5-9 swift test --filter OpenAITests
```

## Docker Configuration

### Dockerfile

The `Dockerfile` supports multiple Swift versions via build arguments:
- Swift 5.9 (default, matches Package.swift requirement)
- Swift 5.10 (forward compatibility)
- Swift 6.0 (future compatibility)

Base image: `swift:X.Y-jammy` (Ubuntu 22.04 Jammy)

### docker-compose.yml

Defines multiple services for different use cases:
- `langtools-swift-5-9`: Test with Swift 5.9
- `langtools-swift-5-10`: Test with Swift 5.10
- `langtools-swift-6-0`: Test with Swift 6.0
- `langtools-build`: Build without running tests
- `langtools-shell`: Interactive shell for debugging

### .dockerignore

Optimizes Docker builds by excluding:
- Build artifacts (`.build`, `DerivedData/`)
- IDE files (`.vscode/`, `.idea/`)
- macOS-specific files (`.DS_Store`)
- Documentation (except Package.swift)
- Git files

## Linux Compatibility

The library includes compatibility shims for Linux in `Sources/LangTools/URL+Compatibility.swift`:

1. **URLSession.data(for:)**: Wraps `dataTask` for async/await support
2. **URL.appending(path:)**: Uses `appendingPathComponent` on Swift < 5.10
3. **URL.appending(queryItems:)**: Uses `URLComponents` on Swift < 5.10
4. **URL(filePath:)**: Uses `URL(fileURLWithPath:)` on Swift < 5.10

These extensions are conditionally compiled with `#if !canImport(Darwin)` to ensure they only apply to Linux.

## Troubleshooting

### Build fails with "value of type 'URL' has no member 'appending'"

This indicates the compatibility shim isn't being applied. Ensure:
1. `URL+Compatibility.swift` is included in the LangTools target
2. The `#if swift(<5.10)` condition matches your Swift version

### Tests hang or timeout

Some tests may take longer on Linux. You can:
- Run specific test suites: `swift test --filter TestSuiteName`
- Increase timeout in Makefile if needed
- Use `make docker-shell` to debug interactively

### Docker build is slow

First build will download the Swift base image (1-2GB) and install dependencies. Subsequent builds use Docker's cache and are much faster.

To speed up builds:
- Use `make docker-build` to rebuild only when needed
- Don't modify `Package.swift` frequently as it invalidates the dependency cache

## CI/CD Integration

Example GitHub Actions workflow:

```yaml
name: Linux Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Run tests
        run: make docker-test
```

## Platform Support

- **Linux**: Full support with compatibility shims
- **macOS**: Uses native Foundation APIs
- **Swift 5.9+**: Minimum supported version
- **Swift 6.0**: Forward compatibility tested

## Known Issues

- `TestUtils` target may show errors in release builds due to `@testable import`
  - This doesn't affect functionality, only release builds
  - Tests run fine in debug mode
- Some tests may take longer on Linux due to different Foundation implementation
