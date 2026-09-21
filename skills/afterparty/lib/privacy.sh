# shellcheck shell=bash
# Best-effort redaction for persisted display text. Never use this to derive
# process identity. Avoid putting secrets in argv; unknown formats cannot be
# recognized reliably. Live CLI output remains unchanged.
privacy_redact() {
  awk '
    function scrub(line, out, prefix, rest, quote, n, i, ch, escaped, replacement) {
      out=""
      while (match(tolower(line), /(^|[[:space:]\042\047])(--?)?([a-z_-]*token|api[-_]?key|private[-_]?key|password|passwd|[a-z_-]*secret|authorization)[\042\047]?(=|:[[:space:]]*|[[:space:]]+)/)) {
        prefix=substr(line,1,RSTART+RLENGTH-1)
        rest=substr(line,RSTART+RLENGTH)
        if (tolower(prefix) ~ /authorization/ && tolower(rest) ~ /^bearer[[:space:]]+/) {
          sub(/^[^[:space:]]+[[:space:]]+/, "", rest)
        }
        quote=substr(rest,1,1)
        if (quote == "\047" || quote == "\042") {
          n=length(rest); escaped=0
          for (i=2; i<=length(rest); i++) {
            ch=substr(rest,i,1)
            if (escaped) {escaped=0; continue}
            if (ch == "\\") {escaped=1; continue}
            if (ch == quote) {n=i; break}
          }
          replacement=quote "[REDACTED]" quote
        } else {
          replacement="[REDACTED]"
          n=match(rest,/[[:space:],&]/)
          if (n) n--; else n=length(rest)
        }
        out=out prefix replacement
        line=substr(rest,n+1)
      }
      line=out line
      out=""
      while (match(line, /[a-zA-Z]+:\/\/[^ \/@:]+:[^ \/@]+@/)) {
        prefix=substr(line,RSTART,RLENGTH)
        sub(/:\/\/.*/, "://[REDACTED]@", prefix)
        out=out substr(line,1,RSTART-1) prefix
        line=substr(line,RSTART+RLENGTH)
      }
      return out line
    }
    {print scrub($0)}'
}
