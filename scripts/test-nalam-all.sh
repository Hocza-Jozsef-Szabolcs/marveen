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
CREATE TABLE agent_messages (id INTEGER PRIMARY KEY, from_agent TEXT, to_agent TEXT, created_at INTEGER);
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

echo "── T8: MAS FEJ neven allo done kartya, a zaro komment ota SEMMI reakcio -- MEGJELENIK ──"
echo "   (a 6783a107 mintaja: assignee=backend, backend zart le, marveen meg nem reagalt)"
seed
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k8','cim8','done','backend',1000,NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_comments VALUES (1,'k8','backend',1000);"
OUT="$(run marveen)"
check "T8 talalja a k8-at" "1" "$(echo "$OUT" | grep -c '^  k8 ')"
check "T8 az assignee is lathato a soron" "1" "$(echo "$OUT" | grep '^  k8 ' | grep -c 'backend')"

echo "── T9: MAS FEJ done kartyaja, DE a fej uzent marveennek a zaras utan -- NEM jelenik meg ─"
echo "   (a 79480150 mintaja: backend->marveen agent_messages a zaro komment UTAN, id 10282)"
seed
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k9','cim9','done','backend',1000,NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_comments VALUES (1,'k9','backend',1000);"
sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (1,'backend','marveen',1010);"
OUT="$(run marveen)"
check "T9 nem talalja a k9-et (van uzenet a zaras utan)" "0" "$(echo "$OUT" | grep -c '^  k9 ')"

echo "── T10: MAS FEJ done kartyaja, DE marveen mar kommentelt a zaras utan -- NEM jelenik meg ─"
seed
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k10','cim10','done','backend',1000,NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_comments VALUES (1,'k10','backend',1000);"
sqlite3 "$FDb" "INSERT INTO kanban_comments VALUES (2,'k10','marveen',1010);"
OUT="$(run marveen)"
check "T10 nem talalja a k10-et (marveen mar reagalt)" "0" "$(echo "$OUT" | grep -c '^  k10 ')"

echo "── T11: uzenet a zaras ELoTT (regi, nem szamit) -- MEGJELENIK ─────────────────────────"
seed
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k11','cim11','done','backend',1000,NULL);"
sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (1,'backend','marveen',500);"
sqlite3 "$FDb" "INSERT INTO kanban_comments VALUES (1,'k11','backend',1000);"
OUT="$(run marveen)"
check "T11 talalja a k11-et (a regi uzenet a zaras elott volt)" "1" "$(echo "$OUT" | grep -c '^  k11 ')"

echo "── T12: MAS FEJRE futtatva -- az idegen-fej blokk NEM aktivalodik (csak marveen nezet) ─"
seed
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k12','cim12','done','backend',1000,NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_comments VALUES (1,'k12','backend',1000);"
OUT="$(run backend)"
check "T12 delphi/backend nezetbol nem jelenik meg a sajat maga zarta kartya" "0" "$(echo "$OUT" | grep -c '^  k12 ')"

echo "── T13: sajat (assignee=marveen) ES idegen talalat EGYUTT -- mindketto megjelenik ─────"
seed
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k1','cim1','waiting','marveen',$(date +%s),NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_comments VALUES (1,'k1','delphi',$(date +%s));"
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k8','cim8','done','backend',1000,NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_comments VALUES (2,'k8','backend',1000);"
OUT="$(run marveen)"
check "T13 a sajat k1 megjelenik" "1" "$(echo "$OUT" | grep -c '^  k1 ')"
check "T13 az idegen k8 is megjelenik" "1" "$(echo "$OUT" | grep -c '^  k8 ')"

echo "── T14 (BUKAS-ELoALLITAS): a (b) feltetel eltavolitasa utan a k9-hasonlo eset MEGJELENIK ─"
echo "   (igazolja, hogy T9 tenylegesen az agent_messages ellenorzest meri, nem mellekkorulmenyt)"
seed
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k9','cim9','done','backend',1000,NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_comments VALUES (1,'k9','backend',1000);"
sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (1,'backend','marveen',1010);"
FMut="$FTmp/mutant-nincs-uzenet-ellenorzes.sh"
sed "/NOT EXISTS (SELECT 1 FROM agent_messages/,/lac.zaro_ts)$/d" "$CScript" > "$FMut"
chmod +x "$FMut"
OUT_MUT="$(MARVEEN_DB="$FDb" bash "$FMut" marveen)"
check "T14 mutans mellett a k9 MEGJELENIK (a (b) ellenorzes valoban aktiv)" "1" "$(echo "$OUT_MUT" | grep -c '^  k9 ')"

echo
echo "═══════════════════════════════════════════════════════════════════════"
echo "  OK: $FPass  BUKIK: $FFail"
if [ "$FFail" -gt 0 ]; then
  echo "Bukott esetek: ${FFailedNames[*]}"
  exit 1
fi
exit 0
