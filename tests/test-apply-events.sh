#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'SKIP: apply receipt fixtures require Python 3'; exit 0; }
exec python3 "$REPO/tests/apply_event_cases.py" "$REPO" "$BASH"
