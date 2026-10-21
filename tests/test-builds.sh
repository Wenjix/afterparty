#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'SKIP: builds fixtures require Python 3'; exit 0; }
case "$(uname -s)" in
  Darwin|Linux)
    if command -v go >/dev/null 2>&1; then
      bash "$REPO/skills/afterparty/bin/build-review"
    fi
    ;;
esac
BUILD_TEST_REPO="$REPO"
BUILD_TEST_BASH="$BASH"
if command -v cygpath >/dev/null 2>&1; then
  BUILD_TEST_REPO="$(cygpath -m "$REPO")"
  BUILD_TEST_BASH="$(cygpath -m "$BASH")"
fi
python3 "$REPO/tests/build_inventory_cases.py" "$BUILD_TEST_REPO"
exec python3 "$REPO/tests/builds_cli_cases.py" "$BUILD_TEST_REPO" "$BUILD_TEST_BASH"
