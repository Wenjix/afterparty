#!/usr/bin/env bash
# plan.sh - write a proposal for what could be cleaned, one checkbox per
# target, for a person to edit.
#
# Every actionable item starts unchecked and carries a fingerprint. Process
# groups require old agent transcript activity and low observed CPU; in-use,
# busy and unknown groups are withheld. Worktree transcript age is context,
# not an eligibility gate. Worktree and artifact proposals instead require
# their filesystem, identity and occupancy checks.
#
# Usage:
#   plan.sh [--root DIR] [--all] [--artifacts-only] [--caches-only]
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/style.sh"
. "$DIR/workspace.sh"
. "$DIR/eligible.sh"
. "$DIR/fingerprint.sh"
. "$DIR/categories.sh"
. "$DIR/vetoes.sh"
. "$DIR/privacy.sh"
. "$DIR/protect.sh"
. "$DIR/state.sh"
. "$DIR/plan-capture.sh"
. "$DIR/plan-render.sh"

ROOT="$PWD" ALL=0 ARTIFACTS_ONLY=0 CACHES_ONLY=0 JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || { echo "plan: --root needs a directory" >&2; exit 2; }; ROOT="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    --all) ALL=1; shift ;;
    --artifacts-only) ARTIFACTS_ONLY=1; shift ;;
    --caches-only) CACHES_ONLY=1; shift ;;
    -h|--help) echo 'Usage: afterparty plan [--root DIR] [--all] [--artifacts-only] [--caches-only] [--json]';
      echo 'Create a plan with unchecked targets. Check the targets you approve before you run afterparty apply.'; exit 0 ;;
    *) echo "plan: unknown option: $1" >&2
       echo 'plan creates a proposal. Run afterparty apply to act on checked targets.' >&2
       exit 2 ;;
  esac
done

[ -d "$ROOT" ] || { echo "plan: scope is not a directory: $ROOT" >&2; exit 2; }
ROOT="$(cd "$ROOT" && pwd -P)"
case "$ROOT" in *$'\n'*|*$'\r'*|*$'\t'*) echo "plan: unsupported control character in root" >&2; exit 2 ;; esac
if top="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)"; then ROOT="$(veto_phys "$top")"; fi
if [ "$JSON" -eq 1 ] && ! command -v python3 >/dev/null 2>&1; then
  echo 'plan: --json requires Python 3. Run afterparty plan without --json for a Markdown plan.' >&2
  exit 2
fi
umask 077
NOW="$(date +%s)"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT
plan_capture_init "$T/capture" || exit 1
. "$DIR/plan-collect.sh"
PLAN_RC=0
if [ "$ARTIFACTS_ONLY" -eq 1 ]; then
  plan_collect_artifacts > "$PLAN_DOCUMENT" || PLAN_RC=$?
else
  plan_collect > "$PLAN_DOCUMENT" || PLAN_RC=$?
fi
if [ "$JSON" -eq 1 ]; then
  PYTHONUTF8=1 PYTHONDONTWRITEBYTECODE=1 python3 "$DIR/plan_data.py" "$PLAN_CAPTURE" "$ROOT" "$ALL" "$ARTIFACTS_ONLY" "$CACHES_ONLY" "$NOW" "$PLAN_RC"
  exit $?
fi
plan_render_markdown "$PLAN_CAPTURE"
exit "$PLAN_RC"
