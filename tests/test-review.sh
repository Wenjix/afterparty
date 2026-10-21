#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'SKIP: review fixtures require Python 3'; exit 0; }
case "$(uname -s)" in
  Darwin|Linux)
    python3 -c 'import pyte' || { echo 'Review PTY tests require: pip install -r tests/requirements.txt' >&2; exit 1; }
    bash "$REPO/skills/afterparty/bin/build-review"
    (cd "$REPO/skills/afterparty/ui" && go test ./...)
    ;;
esac
REVIEW_TEST_BASH="$BASH"
if command -v cygpath >/dev/null 2>&1; then REVIEW_TEST_BASH="$(cygpath -m "$BASH")"; fi
python3 "$REPO/tests/review_backend_cases.py" "$REPO"
exec python3 "$REPO/tests/review_cases.py" "$REPO" "$REVIEW_TEST_BASH"
