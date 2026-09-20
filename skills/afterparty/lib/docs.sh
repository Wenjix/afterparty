#!/usr/bin/env bash
# Collect documentation evidence; the invoking agent supplies the review.
set -euo pipefail
umask 077
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/state.sh"
command -v python3 >/dev/null 2>&1 || { echo 'docs: Python 3 is required' >&2; exit 1; }
DOCS_ROOT="$PWD"
ARGS=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ $# -gt 1 ] || { echo 'docs: --root requires a directory' >&2; exit 2; }
      DOCS_ROOT="$2"; shift ;;
    --root=*) DOCS_ROOT="${1#--root=}" ;;
  esac
  shift
done
DOCS_STATE="$(state_docs_dir "$DOCS_ROOT")" || exit 1
exec python3 "$DIR/docs.py" "$DOCS_STATE" "$BASH" ${ARGS[@]+"${ARGS[@]}"}
