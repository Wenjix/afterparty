#!/usr/bin/env bash
# Run every suite; nonzero exit if any fails.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILED=0
for t in "$DIR"/test-*.sh; do
  echo "===== $(basename "$t") ====="
  if bash "$t"; then
    echo
  else
    echo "SUITE FAILED: $(basename "$t")"
    FAILED=1
    echo
  fi
done
if [ "$FAILED" -eq 0 ]; then echo "ALL SUITES PASS"; fi
exit "$FAILED"
