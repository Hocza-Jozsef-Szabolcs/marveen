#!/bin/bash
# hu: A `tg-seq.sh` merooeszkoze. A szkript ELOSZOR csak a FAJL-bol olvasott, a conversation_log
#     tenyleges MAX kiadott sorszamat nem nezte -- HANDOFF/restart-atmeneti uzenetek a fajl
#     leptetese nelkul mennek ki, es az elso hivas utanuk mar-kiadott szamot ad vissza
#     (kartya 883ff1f5, elozmeny 81eb5b34). A T1/T2 ezt az esetet allitja elo: a FAJL regi
#     erteket tartalmaz, a conversation_log-ban egy UJABB (mar kikuldott) sorszam all --
#     sima `{N}` es MarkdownV2-escapelt `\{N\}` alakban is, mert mindket forma elofordul
#     eles adatban (mert 2026-08-25: 1543 sima, 11 escapelt sor a conversation_log-ban).
#
# en: Measuring harness for tg-seq.sh. T1/T2 reproduce the already-issued-number bug: the FILE
#     holds a stale value while conversation_log already has a HIGHER issued number, in both
#     plain `{N}` and MarkdownV2-escaped `\{N\}` form.
#
# EXIT: 0 = minden eset a vart eredmenyt adta | 1 = legalabb egy eset elter

set -uo pipefail

CDir="$(cd "$(dirname "$0")" && pwd)"
CScript="$CDir/tg-seq.sh"

FTmp=$(mktemp -d "${TMPDIR:-/tmp}/tg-seq-teszt.XXXXXX")
trap 'rm -rf "$FTmp"' EXIT

FPass=0
FFail=0

check() {
  local nev="$1" vart="$2" kapott="$3"

  if [ "$vart" = "$kapott" ]; then
    echo "  ✅ $nev"
    FPass=$((FPass + 1))
  else
    echo "  ❌ $nev -- vart: [$vart], kapott: [$kapott]"
    FFail=$((FFail + 1))
  fi
}

# hu: sajat, eldobhato fajl+db par esethez -- soha nem az eles store/*-ot piszkalja.
new_case() {
  local nev="$1" fajl_ertek="$2"
  local dir="$FTmp/$nev"
  mkdir -p "$dir"

  local f="$dir/seq.txt"
  local db="$dir/conv.db"

  if [ -n "$fajl_ertek" ]; then
    printf '%s\n' "$fajl_ertek" > "$f"
  fi

  sqlite3 "$db" "CREATE TABLE conversation_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent_id TEXT NOT NULL,
    chat_id TEXT NOT NULL,
    direction TEXT NOT NULL,
    message_id TEXT,
    text TEXT,
    ts TEXT,
    created_at INTEGER NOT NULL
  );"

  echo "$f|$db"
}

run() {
  local f="$1" db="$2"
  TG_SEQ_FILE="$f" TG_SEQ_DB="$db" "$CScript"
}

echo "── T1: sima {N} alak a conversation_log-ban ELOZI a fajlt -- a nagyobb+1 jojjon ─────"
IFS='|' read -r F1 DB1 <<< "$(new_case t1 1287)"
sqlite3 "$DB1" "INSERT INTO conversation_log (agent_id,chat_id,direction,message_id,text,ts,created_at)
  VALUES ('marveen','0','out',NULL,'{1288} korabban kikuldott handoff-uzenet','2026-08-24T05:20:00Z',1);"
OUT1=$(run "$F1" "$DB1")
check "T1 kimenet 1289" "1289" "$OUT1"
check "T1 fajl frissult 1289-re" "1289" "$(cat "$F1")"

echo "── T2: MarkdownV2-escapelt \\{N\\} alak a conversation_log-ban ─────────────────────"
IFS='|' read -r F2 DB2 <<< "$(new_case t2 1287)"
sqlite3 "$DB2" "INSERT INTO conversation_log (agent_id,chat_id,direction,message_id,text,ts,created_at)
  VALUES ('marveen','0','out',NULL,'\\{1288\\} *bold napindito*','2026-08-24T05:20:00Z',1);"
OUT2=$(run "$F2" "$DB2")
check "T2 kimenet 1289" "1289" "$OUT2"
check "T2 fajl frissult 1289-re" "1289" "$(cat "$F2")"

echo "── T3: a fajl mar a log elott jar (normal eset) -- a viselkedes valtozatlan ────────"
IFS='|' read -r F3 DB3 <<< "$(new_case t3 50)"
sqlite3 "$DB3" "INSERT INTO conversation_log (agent_id,chat_id,direction,message_id,text,ts,created_at)
  VALUES ('marveen','0','out',NULL,'{10} regi uzenet','2026-08-01T00:00:00Z',1);"
OUT3=$(run "$F3" "$DB3")
check "T3 kimenet 51 (a fajl a mervado)" "51" "$OUT3"

echo "── T4: DB hianyzik/elerhetetlen -- a szkript ne omoljon ossze, a fajl-ertek maradjon merveado"
F4="$FTmp/t4-seq.txt"
printf '5\n' > "$F4"
OUT4=$(TG_SEQ_FILE="$F4" TG_SEQ_DB="$FTmp/nincs-ilyen.db" "$CScript")
check "T4 kimenet 6 (DB nelkul is mukodik)" "6" "$OUT4"

echo "── T5: bemenet ('in') iranyu sor nem szamit bele ───────────────────────────────────"
IFS='|' read -r F5 DB5 <<< "$(new_case t5 1287)"
sqlite3 "$DB5" "INSERT INTO conversation_log (agent_id,chat_id,direction,message_id,text,ts,created_at)
  VALUES ('marveen','0','in',NULL,'{9999} egy BEJOVO uzenet, ez nem sorszam-kiadas','2026-08-24T05:20:00Z',1);"
OUT5=$(run "$F5" "$DB5")
check "T5 kimenet 1288 (a bejovo sor figyelmen kivul)" "1288" "$OUT5"

echo
echo "Osszesitve: ${FPass} zold, ${FFail} piros"
[ "$FFail" -eq 0 ]
