#!/usr/bin/env bash
# hu: Bukas-eloallito teszt a nalam-all.sh-hoz. A szures mag-logikaja: waiting/done kartya,
#     ahol az UTOLSO KOMMENT szerzoje NEM a lekerdezett fej -- es a ket pozitiv-kontroll ag
#     (0 talalat: hatokor ures VS hatokor nem-ures, de mindenhol en irtam utoljara).
# en: Failure-producing test suite for nalam-all.sh -- last-comment-author filtering on
#     waiting/done cards, plus the two positive-control branches for the empty-result case.

set -uo pipefail

CDir="$(cd "$(dirname "$0")" && pwd)"
CScript="$CDir/nalam-all.sh"

FTmp=$(mktemp -d "${TMPDIR:-/tmp}/nalam-all-teszt.XXXXXX")
trap 'rm -rf "$FTmp"' EXIT

FPass=0
FFail=0
FFailedNames=()

check() {
  local nev="$1" vart="$2" kapott="$3"
  if [ "$vart" = "$kapott" ]; then
    echo "  OK    $nev"
    FPass=$((FPass + 1))
  else
    echo "  BUKIK $nev -- vart: [$vart], kapott: [$kapott]"
    FFail=$((FFail + 1))
    FFailedNames+=("$nev")
  fi
}

FDb="$FTmp/claudeclaw.db"

seed() {
  FDb="$FTmp/claudeclaw.db"
  rm -f "$FDb"
  sqlite3 "$FDb" <<'SQL'
CREATE TABLE kanban_cards (id TEXT PRIMARY KEY, title TEXT, status TEXT, assignee TEXT, updated_at INTEGER, archived_at INTEGER);
CREATE TABLE kanban_comments (id INTEGER PRIMARY KEY, card_id TEXT, author TEXT, created_at INTEGER);
SQL
}

run() {
  MARVEEN_DB="$FDb" bash "$CScript" "$@"
}

echo "── T1: waiting kartya, utolso komment MAS fejtol -- megjelenik ────────────────────────"
seed
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k1','cim1','waiting','marveen',$(date +%s),NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_comments VALUES (1,'k1','delphi',$(date +%s));"
OUT="$(run marveen)"
check "T1 talalja a k1-et" "1" "$(echo "$OUT" | grep -c '^  k1 ')"

echo "── T2: waiting kartya, utolso komment SAJAT -- NEM jelenik meg ────────────────────────"
seed
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k2','cim2','waiting','marveen',$(date +%s),NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_comments VALUES (1,'k2','marveen',$(date +%s));"
OUT="$(run marveen)"
check "T2 nem talalja a k2-t" "0" "$(echo "$OUT" | grep -c '^  k2 ')"
check "T2 pozitiv-kontroll szoveg (hatokor nem ures, mind sajat)" "1" "$(echo "$OUT" | grep -c 'de MINDEGYIKEN')"

echo "── T3: done kartya, utolso komment MAS fejtol -- megjelenik (a done kiterjesztes) ─────"
seed
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k3','cim3','done','marveen',$(date +%s),NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_comments VALUES (1,'k3','ereceipt',$(date +%s));"
OUT="$(run marveen)"
check "T3 talalja a k3-at (done, mas fejtol)" "1" "$(echo "$OUT" | grep -c '^  k3 ')"

echo "── T4: planned kartya -- a szures NEM terjed ki ra, akkor sem, ha mas kommentelt ──────"
seed
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k4','cim4','planned','marveen',$(date +%s),NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_comments VALUES (1,'k4','akka',$(date +%s));"
OUT="$(run marveen)"
check "T4 nem talalja a k4-et (planned nem szurt statusz)" "0" "$(echo "$OUT" | grep -c '^  k4 ')"

echo "── T5: pozitiv kontroll -- SEMMILYEN waiting/done kartya nincs a nevre -- targytalan ──"
seed
OUT="$(run marveen)"
check "T5 targytalan-jelzes" "1" "$(echo "$OUT" | grep -c 'targytalan')"

echo "── T6: mas fejre futtatva -- a cimke iranya megfordul (masik szoveg) ──────────────────"
seed
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k6','cim6','waiting','delphi',$(date +%s),NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_comments VALUES (1,'k6','marveen',$(date +%s));"
OUT="$(run delphi)"
check "T6 talalja a k6-ot delphi nezopontjabol" "1" "$(echo "$OUT" | grep -c '^  k6 ')"
check "T6 nem a marveen-fejlecet hasznalja" "0" "$(echo "$OUT" | grep -c 'MAS FEJ TETTE LE NALAM')"

echo "── T7 (BUKAS-ELoALLITAS): archivalt kartya -- KIMARAD, meg ha mas kommentelt is ────────"
seed
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k7','cim7','waiting','marveen',$(date +%s),$(date +%s));"
sqlite3 "$FDb" "INSERT INTO kanban_comments VALUES (1,'k7','akka',$(date +%s));"
OUT="$(run marveen)"
check "T7 nem talalja az archivalt k7-et" "0" "$(echo "$OUT" | grep -c '^  k7 ')"

echo
echo "═══════════════════════════════════════════════════════════════════════"
echo "  OK: $FPass  BUKIK: $FFail"
if [ "$FFail" -gt 0 ]; then
  echo "Bukott esetek: ${FFailedNames[*]}"
  exit 1
fi
exit 0
