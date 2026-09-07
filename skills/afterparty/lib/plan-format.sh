# shellcheck shell=bash
# Validate every checked item before any mutation; emit normalized TSV records.
# Legacy two-line process/worktree plans remain readable, but malformed checked
# entries, unknown versions, ambiguous paths and duplicate targets are errors.
plan_read_checked() {
  LC_ALL=C awk '
    function bad(message) { print "apply: invalid plan at line " NR ": " message > "/dev/stderr"; errors++ }
    function emit(type, target, fp, category, root, key) {
      if (type != "process-group" && target !~ /^(\/|[A-Za-z]:\/)/) { bad("target must be an absolute path"); return }
      if (type == "artifact" && root !~ /^(\/|[A-Za-z]:\/)/) { bad("scope must be an absolute path"); return }
      key = type SUBSEP target
      if (seen[key]++) { bad("duplicate checked target " target); return }
      if (target ~ /[\t\r]/ || root ~ /[\t\r]/) { bad("unsupported control character in path"); return }
      print type "\t" target "\t" fp "\t" category "\t" root
    }
    /^# afterparty plan schema:/ {
      if ($0 != "# afterparty plan schema: 1") bad("unsupported schema; regenerate the plan")
      next
    }
    /^- \[[xX]\]/ {
      if (pending != "") bad("checked item has no valid metadata")
      pending = $0
      next
    }
    {
      if (pending == "") next
      header = pending; pending = ""
      if ($0 ~ /^      category: (tests|dev|browser)  fingerprint: [0-9a-f]+$/) {
        if (header !~ / pgid [0-9]+([[:space:]]|$)/) { bad("process item needs a pgid"); next }
        pg = header; sub(/^.* pgid /, "", pg); sub(/[[:space:]].*$/, "", pg)
        if (pg + 0 <= 1) { bad("invalid process group"); next }
        category = $0; sub(/^      category: /, "", category); sub(/  fingerprint:.*/, "", category)
        fp = $0; sub(/^.*fingerprint: /, "", fp)
        emit("process-group", pg, fp, category, "-")
      } else if ($0 ~ /^      type: worktree  fingerprint: [0-9a-f]+  path: /) {
        fp = $0; sub(/^      type: worktree  fingerprint: /, "", fp); sub(/  path:.*/, "", fp)
        target = $0; sub(/^      type: worktree  fingerprint: [0-9a-f]+  path: /, "", target)
        prefix = header; sub(/ path .*/, "", prefix)
        prefix = prefix " path " target
        if (target == "" || (header != prefix && index(header, prefix "  ") != 1)) {
          bad("displayed worktree path disagrees with metadata"); next
        }
        emit("worktree", target, fp, "-", "-")
      } else if ($0 ~ /^      type: artifact  fingerprint: [0-9a-f]+  root: /) {
        if (header !~ /^- \[[xX]\] artifact path /) { bad("invalid artifact row"); next }
        target = header; sub(/^- \[[xX]\] artifact path /, "", target)
        fp = $0; sub(/^      type: artifact  fingerprint: /, "", fp); sub(/  root:.*/, "", fp)
        root = $0; sub(/^      type: artifact  fingerprint: [0-9a-f]+  root: /, "", root)
        if (target == "" || root == "") { bad("artifact needs target and root"); next }
        emit("artifact", target, fp, "-", root)
      } else bad("checked item has malformed or unsupported metadata")
    }
    END {
      if (pending != "") bad("checked item has no metadata")
      if (errors) exit 2
    }
  ' "$1"
}
