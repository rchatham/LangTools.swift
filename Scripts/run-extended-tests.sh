#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <swift-test-arguments>" >&2
  echo "Example: $0 --filter PerformanceRatioGateTests -v" >&2
  exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_root="$(cd "${script_dir}/.." && pwd)"

export LANGTOOLS_ENABLE_EXTENDED_TESTS=1
cd "${package_root}"
exec swift test "$@"
