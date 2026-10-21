#!/usr/bin/env bash
# Release archives run only help/version in disposable directories.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'SKIP: release packaging requires Python 3'; exit 0; }
PACKAGE_TEST_BASH="$BASH"
if command -v cygpath >/dev/null 2>&1; then PACKAGE_TEST_BASH="$(cygpath -m "$BASH")"; fi
exec python3 "$REPO/tests/release_package_cases.py" "$REPO" "$PACKAGE_TEST_BASH"
