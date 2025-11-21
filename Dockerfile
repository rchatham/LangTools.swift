# Dockerfile for testing LangTools.swift on Linux
# Supports multiple Swift versions for compatibility testing

ARG SWIFT_VERSION=5.9
FROM swift:${SWIFT_VERSION}-jammy

# Install additional dependencies if needed
RUN apt-get update && apt-get install -y \
    libsqlite3-dev \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /workspace

# Copy package manifest first for dependency resolution
COPY Package.swift Package.resolved* ./

# Resolve dependencies (cached layer)
RUN swift package resolve

# Copy source code
COPY Sources ./Sources
COPY Tests ./Tests

# Build the package
RUN swift build

# Default command runs tests
CMD ["swift", "test", "--parallel"]
