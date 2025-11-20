# Docker Guide for LangTools

This guide explains how to build, test, and deploy LangTools using Docker on Linux.

## Prerequisites

- Docker 20.10 or later
- Docker Compose 2.0 or later (optional, for simplified commands)

## Quick Start

### Using Docker Compose (Recommended)

#### Development Environment
Start an interactive development container with all build tools:

```bash
docker-compose run --rm langtools-dev
```

This mounts your local directory into the container, allowing you to edit code locally and build/test inside the container.

#### Build the Project
```bash
docker-compose run --rm langtools-builder
```

#### Run Tests
```bash
docker-compose run --rm langtools-test
```

#### Run ChatCLI
```bash
# Set your API keys first
export OPENAI_API_KEY=your_key_here
export ANTHROPIC_API_KEY=your_key_here

# Run the CLI
docker-compose run --rm chatcli
```

### Using Docker Directly

#### Build Development Image
```bash
docker build --target development -t langtools-dev .
```

#### Build and Test
```bash
# Build the project
docker build --target builder -t langtools-builder .

# Run tests
docker build --target tester -t langtools-test .
```

#### Build Runtime Image
```bash
docker build --target runtime -t langtools-chatcli .
```

#### Run ChatCLI
```bash
docker run -it --rm \
  -e OPENAI_API_KEY=your_key_here \
  -e ANTHROPIC_API_KEY=your_key_here \
  langtools-chatcli
```

## Docker Image Stages

The Dockerfile uses a multi-stage build with the following targets:

### 1. `builder`
- Based on `swift:6.2.1-jammy`
- Contains full Swift toolchain
- Resolves dependencies and builds the project in release mode
- Use for: Building the project

### 2. `tester`
- Extends the `builder` stage
- Runs the complete test suite
- Use for: CI/CD test execution

### 3. `runtime`
- Based on `swift:6.2.1-jammy-slim`
- Minimal runtime environment with only necessary libraries
- Contains only the built ChatCLI executable
- Runs as non-root user for security
- Use for: Production deployment of ChatCLI

### 4. `development`
- Based on `swift:6.2.1-jammy`
- Includes full Swift toolchain and development tools
- Mounts source code as volume for live editing
- Use for: Interactive development on Linux

## Development Workflow

### Interactive Development

1. Start the development container:
```bash
docker-compose run --rm langtools-dev
```

2. Inside the container, you can:
```bash
# Build the project
swift build

# Run tests
swift test

# Run specific tests
swift test --filter LangToolsTests

# Build in release mode
swift build -c release

# Run the ChatCLI
.build/debug/ChatCLI
```

3. Your local changes are automatically reflected in the container.

### Building and Testing

To build and test in one command:
```bash
docker-compose run --rm langtools-test
```

Or separately:
```bash
# Build only
docker-compose run --rm langtools-builder

# Test only (requires prior build)
docker-compose run --rm langtools-dev swift test
```

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Docker Build and Test

on: [push, pull_request]

jobs:
  docker-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Build and Test
        run: |
          docker build --target tester -t langtools-test .
      
      - name: Build Runtime
        run: |
          docker build --target runtime -t langtools-chatcli .
```

### GitLab CI Example

```yaml
docker-test:
  image: docker:latest
  services:
    - docker:dind
  script:
    - docker build --target tester -t langtools-test .
    - docker build --target runtime -t langtools-chatcli .
```

## Performance Tips

### Build Cache

Docker will cache layers to speed up rebuilds. The Dockerfile is optimized to:
1. Copy and resolve dependencies first (cached unless Package.swift changes)
2. Copy source code later (invalidates cache only when code changes)

### Use Build Cache Volume

Docker Compose uses a named volume for build cache:
```bash
docker volume ls | grep langtools-build-cache
```

To clear the cache:
```bash
docker-compose down -v
```

### Multi-Architecture Builds

To build for different architectures (e.g., ARM64 for Apple Silicon):
```bash
docker buildx build --platform linux/amd64,linux/arm64 -t langtools-dev .
```

## Environment Variables

The following environment variables can be passed to containers:

- `OPENAI_API_KEY`: OpenAI API key for ChatCLI
- `ANTHROPIC_API_KEY`: Anthropic API key for ChatCLI
- `XAI_API_KEY`: X.AI API key for ChatCLI
- `GEMINI_API_KEY`: Google Gemini API key for ChatCLI
- `SWIFT_DETERMINISTIC_HASHING`: Set to `1` for reproducible builds

Example:
```bash
docker run -it --rm \
  -e OPENAI_API_KEY=$OPENAI_API_KEY \
  -e ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY \
  langtools-chatcli
```

## Troubleshooting

### Build Fails Due to Network Issues

If dependency resolution fails:
```bash
# Clean build cache
docker-compose down -v

# Rebuild without cache
docker-compose build --no-cache langtools-builder
```

### Permission Issues

If you encounter permission issues with mounted volumes:
```bash
# Check user ID inside container
docker-compose run --rm langtools-dev id

# Adjust user if needed by rebuilding with build args
docker-compose build --build-arg USER_ID=$(id -u) langtools-dev
```

### Container Exits Immediately

For ChatCLI, ensure you're using interactive mode:
```bash
docker run -it langtools-chatcli  # Note: -it not -d
```

## Integration with Your Application

### Using LangTools as a Library

If you're building an application that uses LangTools:

1. Add LangTools to your `Package.swift`:
```swift
dependencies: [
    .package(url: "https://github.com/rchatham/langtools.swift.git", from: "0.2.0")
]
```

2. Create a Dockerfile similar to the one in this repository
3. Use the `builder` stage pattern to compile your application
4. Create a minimal `runtime` stage with just your executable

### Example Application Dockerfile

```dockerfile
FROM swift:6.2.1-jammy AS builder

WORKDIR /app
COPY Package.swift .
RUN swift package resolve
COPY Sources ./Sources
RUN swift build -c release

FROM swift:6.2.1-jammy-slim AS runtime
WORKDIR /app
COPY --from=builder /app/.build/release/YourApp .
CMD ["./YourApp"]
```

## Additional Resources

- [Swift Official Docker Images](https://hub.docker.com/_/swift)
- [Docker Best Practices](https://docs.docker.com/develop/dev-best-practices/)
- [Docker Compose Documentation](https://docs.docker.com/compose/)

## Support

For issues related to:
- **Docker setup**: Open an issue on the LangTools repository
- **Swift on Linux**: Check the [Swift Forums](https://forums.swift.org/)
- **Docker**: Check [Docker Documentation](https://docs.docker.com/)
