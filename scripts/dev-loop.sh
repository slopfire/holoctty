#!/usr/bin/env bash
set -euo pipefail

workspace="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$workspace/scripts/prune-build-cache.sh"
cd "$workspace"
exec zig build "$@"
