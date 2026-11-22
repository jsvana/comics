#!/bin/bash
# Saves real site pages into ComicsTests/Fixtures for offline parser tests.
# Fetched pages are data only; nothing from them is executed.
# Uses the generic client name from HTTPClientIdentity.
# smbc-strip.webp is kept as a generic WebP sample; SMBC is not in the catalog (its site
# refuses the generic client name), so its pages are no longer fetched.
set -euo pipefail

UA="Comics/1.0"
OUT="$(cd "$(dirname "$0")/.." && pwd)/ComicsTests/Fixtures"
mkdir -p "$OUT"

fetch() { # fetch <user-agent> <url> <file>
  sleep 1
  curl -sL -A "$1" -o "$OUT/$3" -w "%{http_code} %{size_download} $3\n" "$2"
  [ -s "$OUT/$3" ] || { echo "empty: $3" >&2; exit 1; }
}

fetch "$UA" "https://xkcd.com/info.0.json" xkcd-latest.json
fetch "$UA" "https://xkcd.com/1/info.0.json" xkcd-1.json
fetch "$UA" "https://xkcd.com/1110/info.0.json" xkcd-1110.json

fetch "$UA" "https://www.questionablecontent.net/" qc-front.html
fetch "$UA" "https://www.questionablecontent.net/view.php?comic=100" qc-100.html
fetch "$UA" "https://www.questionablecontent.net/view.php?comic=4000" qc-4000.html

DOA="https://www.dumbingofage.com/wp-json/wp/v2/comic?per_page=100&order=asc&orderby=date&_fields=id,slug,date,title,link"
sleep 1
curl -sL -A "$UA" -D "$OUT/doa-headers.tmp" -o "$OUT/doa-page1.json" "$DOA"
grep -i '^x-wp-total:' "$OUT/doa-headers.tmp" | tr -d '\r' | awk '{print $2}' > "$OUT/doa-total.txt"
rm "$OUT/doa-headers.tmp"
DOA_LINK="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["link"])' "$OUT/doa-page1.json")"
fetch "$UA" "$DOA_LINK" doa-strip.html

fetch "$UA" "https://pbfcomics.com/comics/" pbf-archive.html
# The archive lists newest first (checked 2026-11-22), so the oldest comic is the last link.
PBF_OLDEST="$(grep -o 'href="https://pbfcomics\.com/comics/[^"/]*/"' "$OUT/pbf-archive.html" | grep -Ev 'page|feed' | awk '!s[$0]++' | tail -1 | sed 's/^href="//; s/"$//')"
fetch "$UA" "$PBF_OLDEST" pbf-strip.html
