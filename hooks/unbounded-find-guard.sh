#!/bin/bash
# hu: PreToolUse hook — blokkolja a gyökérből ("/") vagy a felhasználó
#     home-jából ("~", "$HOME") induló, -maxdepth nélküli `find`/`bfs`
#     hívásokat. Eredet: 2026-08-17 éjszaka HÁROM független runaway esemény
#     (ordog: find, akka 2x: bfs) -- 10+ perc CPU-t evett mindegyik,
#     iCloud-szinkronizált mappák alatt órákig futhatott volna (bizonyított
#     korábbi eset: 13 óra 39 perc). A döntési logika: unbounded_find_guard.py.
#     Mérő: Marveen/scripts/test-unbounded-find-guard.sh
# en: PreToolUse hook — blocks `find`/`bfs` invocations starting at the
#     filesystem root or the user's home with no `-maxdepth` bound. Decision
#     logic lives in unbounded_find_guard.py; test suite in
#     Marveen/scripts/test-unbounded-find-guard.sh

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGIC="$HOOK_DIR/unbounded_find_guard.py"

input=$(cat)

if [ ! -f "$LOGIC" ]; then
    # hu: A logika hianyzik -- a kapu nem tud merni. FAIL-CLOSED: ha a
    #     parancs find/bfs szot tartalmaz, blokkolunk (lasd
    #     destructive-git-guard.sh azonos donteset, 2026-08-14).
    if printf '%s' "$input" | grep -qE '\b(find|bfs)\b'; then
        echo "[hook: unbounded-find-guard] BLOCK — hiányzik a döntési logika ($LOGIC)," >&2
        echo "  és a parancs veszélyes szót tartalmaz. Fail-closed: nem engedem át." >&2
        exit 2
    fi

    echo "[hook: unbounded-find-guard] FIGYELEM: hiányzik a döntési logika ($LOGIC) — a kapu NEM véd." >&2
    exit 0
fi

# hu: Olcso eloszuro -- a hook MINDEN Bash-hivaskor lefut. Aminek a
#     szovegeben nincs "find" es nincs "bfs", az nem tud runaway keresest
#     inditani, tehat a python el sem indul.
if ! printf '%s' "$input" | grep -qE '\b(find|bfs)\b'; then
    exit 0
fi

printf '%s' "$input" | python3 "$LOGIC"
exit $?
