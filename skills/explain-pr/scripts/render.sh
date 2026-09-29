#!/usr/bin/env bash
# Wraps the article Claude wrote in the report template, then opens it.
#
# usage: render.sh <bundle-dir>
#   reads  <bundle-dir>/article.html and <bundle-dir>/title.txt
#   writes <bundle-dir>.html
set -euo pipefail

die() { echo "explain-pr: $*" >&2; exit 1; }

DIR="${1:?usage: render.sh <bundle-dir>}"
DIR="${DIR%/}"
TEMPLATE="$(cd "$(dirname "$0")/.." && pwd)/templates/report.html"
ARTICLE="$DIR/article.html"
OUT="$DIR.html"

[ -s "$ARTICLE" ] || die "no article at $ARTICLE, write it first"
[ -f "$TEMPLATE" ] || die "template missing at $TEMPLATE"
if grep -qiE '<(html|head|body)[ >]' "$ARTICLE"; then
  die "article.html must be a fragment (header + sections), not a full page; drop <html>/<head>/<body>"
fi

TITLE=$(sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' "$DIR/title.txt" 2>/dev/null || echo "explain-pr")
GENERATED=$(date '+%Y-%m-%d %H:%M')
export TITLE GENERATED ARTICLE

# Plain string replacement (no regex), so titles with & or \ survive intact.
awk '
  function fill(s, key, val,   out, i) {
    out = ""
    while ((i = index(s, key)) > 0) { out = out substr(s, 1, i - 1) val; s = substr(s, i + length(key)) }
    return out s
  }
  index($0, "{{ARTICLE}}") { while ((getline line < ENVIRON["ARTICLE"]) > 0) print line; next }
  { $0 = fill($0, "{{TITLE}}", ENVIRON["TITLE"]); print fill($0, "{{GENERATED}}", ENVIRON["GENERATED"]) }
' "$TEMPLATE" > "$OUT"

if [ -z "${EXPLAIN_PR_NO_OPEN:-}" ]; then
  if command -v open >/dev/null; then open "$OUT"
  elif command -v xdg-open >/dev/null; then xdg-open "$OUT" >/dev/null 2>&1 &
  fi
fi
echo "$OUT"
