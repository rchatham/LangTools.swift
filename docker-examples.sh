#!/bin/bash
# Example commands for using LangTools with Docker
# This script is for demonstration purposes - copy and run the commands you need

set -e

echo "=== LangTools Docker Examples ==="
echo

# Example 1: Build the project
echo "Example 1: Build the project"
echo "Command: docker compose run --rm langtools-builder"
echo

# Example 2: Run tests
echo "Example 2: Run tests"
echo "Command: docker compose run --rm langtools-test"
echo

# Example 3: Start an interactive development environment
echo "Example 3: Start an interactive development environment"
echo "Command: docker compose run --rm langtools-dev"
echo "Inside the container, you can run:"
echo "  - swift build"
echo "  - swift test"
echo "  - swift run ChatCLI"
echo

# Example 4: Build Docker images directly
echo "Example 4: Build Docker images directly"
echo "Commands:"
echo "  docker build --target builder -t langtools-builder ."
echo "  docker build --target tester -t langtools-test ."
echo "  docker build --target runtime -t langtools-chatcli ."
echo "  docker build --target development -t langtools-dev ."
echo

# Example 5: Run ChatCLI with API keys
echo "Example 5: Run ChatCLI with API keys"
echo "First, set your API keys:"
echo "  export OPENAI_API_KEY=your_key_here"
echo "  export ANTHROPIC_API_KEY=your_key_here"
echo "Then run:"
echo "  docker compose run --rm chatcli"
echo "Or with docker run:"
echo "  docker run -it --rm -e OPENAI_API_KEY=\$OPENAI_API_KEY langtools-chatcli"
echo

# Example 6: Clean up Docker resources
echo "Example 6: Clean up Docker resources"
echo "Commands:"
echo "  docker compose down -v  # Remove containers and volumes"
echo "  docker image prune -f   # Remove unused images"
echo

echo "For more information, see DOCKER.md"
