#!/usr/bin/env bash
# Public CLI integration in disposable repositories; no machine cleanup calls.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'SKIP: documentation fixtures require Python 3'; exit 0; }
DOCS_TEST_BASH="$BASH"
if command -v cygpath >/dev/null 2>&1; then DOCS_TEST_BASH="$(cygpath -m "$BASH")"; fi
exec python3 "$REPO/tests/docs_cases.py" "$REPO" "$DOCS_TEST_BASH"
