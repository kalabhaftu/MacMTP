#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "scripts/package.sh is kept as a compatibility entry point."
if [[ $# -eq 0 ]]; then
    set -- release --arch "$(uname -m)"
fi
exec bash "$SCRIPT_DIR/build.sh" "$@"
