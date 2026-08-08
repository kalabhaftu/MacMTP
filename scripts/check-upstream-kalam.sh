#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_DIR="$PROJECT_ROOT/Vendor/Kalam/native"
REMOTE_URL="${KALAM_UPSTREAM_REMOTE:-https://github.com/kalabhaftu/openmtp.git}"
REMOTE_REF="${KALAM_UPSTREAM_REF:-master}"

usage() {
    cat <<'EOF'
Usage: scripts/check-upstream-kalam.sh [--strict]

Downloads only ffi/kalam/native into a temporary directory and compares it
with the vendored Kalam source. The repository is never modified.

Environment:
  KALAM_UPSTREAM_REMOTE  Git URL to inspect
  KALAM_UPSTREAM_REF     Branch or tag to inspect (default: master)
EOF
}

strict=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --strict)
            strict=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ ! -d "$LOCAL_DIR" ]]; then
    echo "ERROR: Vendored Kalam source not found at $LOCAL_DIR" >&2
    exit 1
fi

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/macmtp-kalam-upstream.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

echo "Fetching $REMOTE_URL ($REMOTE_REF) into a temporary directory..."
git clone --quiet --filter=blob:none --no-checkout --depth 1 --branch "$REMOTE_REF" "$REMOTE_URL" "$TEMP_ROOT/openmtp"
git -C "$TEMP_ROOT/openmtp" sparse-checkout init --cone
git -C "$TEMP_ROOT/openmtp" sparse-checkout set ffi/kalam/native
git -C "$TEMP_ROOT/openmtp" checkout --quiet

UPSTREAM_DIR="$TEMP_ROOT/openmtp/ffi/kalam/native"
UPSTREAM_COMMIT="$(git -C "$TEMP_ROOT/openmtp" rev-parse HEAD)"
UPSTREAM_DATE="$(git -C "$TEMP_ROOT/openmtp" show -s --format=%cs HEAD)"

echo "Upstream commit: $UPSTREAM_COMMIT ($UPSTREAM_DATE)"
echo "Local baseline:  $(sed -n 's/^- Adapter baseline: `\([^`]*\)`.*/\1/p' "$PROJECT_ROOT/Vendor/Kalam/MAINTENANCE.md" | head -1)"
echo ""

set +e
diff -ru \
    --exclude='.git' \
    --exclude='vendor' \
    --exclude='libkalam.a' \
    "$UPSTREAM_DIR" "$LOCAL_DIR"
diff_status=$?
set -e

if [[ "$diff_status" -eq 0 ]]; then
    echo "Kalam source matches upstream."
elif [[ "$diff_status" -eq 1 ]]; then
    echo "Kalam source differs. Review the diff before importing anything."
    if [[ "$strict" == true ]]; then
        exit 1
    fi
else
    echo "ERROR: Unable to compare Kalam source." >&2
    exit "$diff_status"
fi
