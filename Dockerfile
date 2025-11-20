# Multi-stage Dockerfile for LangTools Swift Framework
# Supports building, testing, and running on Linux

# Build stage
FROM swift:6.2.1-jammy AS builder

# Set working directory
WORKDIR /workspace

# Copy package manifest files
COPY Package.swift .

# Fetch dependencies first (for better caching)
RUN swift package resolve

# Copy source code and tests (needed for TestUtils target)
COPY Sources ./Sources
COPY Tests ./Tests

# Build only the products (not test targets)
RUN swift build -c release --product ChatCLI

# Test stage (optional, can be skipped for production builds)
FROM swift:6.2.1-jammy AS tester

# Set working directory
WORKDIR /workspace

# Copy package manifest
COPY Package.swift .

# Fetch dependencies
RUN swift package resolve

# Copy source and test code
COPY Sources ./Sources
COPY Tests ./Tests

# Run tests
RUN swift test

# Runtime stage for the ChatCLI executable
FROM swift:6.2.1-jammy-slim AS runtime

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    libcurl4 \
    libxml2 \
    && rm -rf /var/lib/apt/lists/*

# Create a non-root user
RUN useradd -m -u 1000 langtools

# Set working directory
WORKDIR /app

# Copy built executable from builder
COPY --from=builder /workspace/.build/release/ChatCLI /app/ChatCLI

# Change ownership
RUN chown -R langtools:langtools /app

# Switch to non-root user
USER langtools

# Set entrypoint
ENTRYPOINT ["/app/ChatCLI"]

# Development stage with full build tools
FROM swift:6.2.1-jammy AS development

# Install additional development tools
RUN apt-get update && apt-get install -y \
    git \
    vim \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /workspace

# Create a non-root user for development
RUN useradd -m -u 1000 developer && \
    chown -R developer:developer /workspace

# Switch to developer user
USER developer

# Default command for development
CMD ["/bin/bash"]
