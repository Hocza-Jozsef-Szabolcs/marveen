#!/usr/bin/env bash
# hu: A valaszolatlan-dontes-keres-figyelo.sh MEROESZKOZE. Kartya 0e7dab4a: a {3041} negy
#     dontes-kerese 2026-09-04 15:32-kor ment ki, 65 bejovo uzenet erkezett azota, es egyetlen
#     meglevo mero sem jelezte -- a hivatkozo kartyakon VAN komment ("... elkuldve: {3041}"),
#     tehat a nulla-komment mero es a 3/b ket kerdese ("meg van nevezve a blokkolo?",
#     "bizonyithato, hogy elindult?") mindketto IGEN-t ad, pedig valasz nem jott.
#
#     A TESZT AZ ALABBI ESETEKET FEDI EGY KOZOS DB-BEN (kuszob = 5 bejovo uzenet):
#       T1  {9001} szamozott lista + kerdojel, 6 bejovo uzenet azota, a hivatkozo kartya
#           UTOLSO kommentje meg mindig a jelolo komment  -> SZEREPEL a kimeneten
#       T2  {9002} szamozott lista + kerdojel, 6 bejovo uzenet azota, DE a hivatkozo kartyan
#           a jelolo komment UTAN egy ujabb (marveen-eredetu) komment is all -- ez a valasz
#           nyoma -> NEM szerepel (a (c) feltetel megallitja)
#       T5  {9005} EGYETLEN kerdes, szamozott lista NELKUL, egyebkent T1-hez hasonlo
#           -> NEM szerepel ((a) feltetel: nincs szamozott tetel)
#       T6  {9006} szamozott lista + kerdojel, DE csak 2 bejovo uzenet azota (kuszob alatt)
#           -> NEM szerepel ((b) feltetel: kuszob alatt)
#     Kulon DB-vel: T7 -- csupa valaszolt/hatokoron-kivuli sor eseten a kimenet TELJESEN URES.
#
# 🛑 MIERT VAN BENNE MUTACIO-ESET: a zold keszlet onmagaban NEM mondja meg, hogy a teszt meri-e
#     a (c) feltetelt. Az M1 a szkript egy MASOLATABAN kiveszi a "van-e ujabb komment" orzest
#     (a (c) feltetel mindig igaznak latszik) -- ekkor a T2 kartyanak IS meg kell jelennie,
#     pontosan azt igazolva, hogy a baseline futasban a (c) feltetel tartotta vissza.
#
# EXIT: 0 = minden eset a vart eredmenyt adta | 1 = legalabb egy eset elter

set -uo pipefail

CDir="$(cd "$(dirname "$0")" && pwd)"
CScript="$CDir/valaszolatlan-dontes-keres-figyelo.sh"

FTmp=$(mktemp -d "${TMPDIR:-/tmp}/valaszolatlan-dontes-keres-figyelo-teszt.XXXXXX")
trap 'rm -rf "$FTmp"' EXIT

FPass=0
FFail=0

expect_contains() { # cimke  varhato(IGEN|NEM)  minta  kimenet
  local label="$1" want="$2" pattern="$3" out="$4"
  local got="NEM"
  echo "$out" | grep -qF "$pattern" && got="IGEN"

  if [ "$got" = "$want" ]; then
    echo "  OK    $label"
    FPass=$((FPass + 1))
  else
    echo "  BUKIK $label -- '$pattern' szerepel: $got (vart: $want)"
    echo "$out" | sed 's/^/       | /'
    FFail=$((FFail + 1))
  fi
}

# ---------------------------------------------------------------------------
# Kozos DB: T1, T2, T5, T6
# ---------------------------------------------------------------------------
FDb="$FTmp/claudeclaw.db"
sqlite3 "$FDb" <<'SQL'
CREATE TABLE conversation_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent_id TEXT NOT NULL,
  chat_id TEXT NOT NULL,
  direction TEXT NOT NULL,
  message_id TEXT,
  text TEXT,
  ts TEXT,
  created_at INTEGER NOT NULL
);
CREATE TABLE kanban_cards (
  id TEXT PRIMARY KEY, title TEXT, status TEXT, assignee TEXT,
  priority TEXT, updated_at INTEGER, created_at INTEGER, archived_at INTEGER
);
CREATE TABLE kanban_comments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  card_id TEXT NOT NULL,
  author TEXT NOT NULL,
  content TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

-- T1: dontes-keres kiment, 6 bejovo uzenet azota, a jelolo komment meg mindig az utolso.
INSERT INTO conversation_log (agent_id, chat_id, direction, text, created_at) VALUES
  ('marveen', 't1chat', 'out', '{9001} Ket dontesed van:
1. Elso tetel, johet?
2. Masodik tetel, johet?', 1000);
INSERT INTO conversation_log (agent_id, chat_id, direction, text, created_at) VALUES
  ('marveen', 't1chat', 'in', 'kozbenso 1', 1001),
  ('marveen', 't1chat', 'in', 'kozbenso 2', 1002),
  ('marveen', 't1chat', 'in', 'kozbenso 3', 1003),
  ('marveen', 't1chat', 'in', 'kozbenso 4', 1004),
  ('marveen', 't1chat', 'in', 'kozbenso 5', 1005),
  ('marveen', 't1chat', 'in', 'kozbenso 6', 1006);
INSERT INTO kanban_cards VALUES ('t1-card', 'T1 valaszolatlan dontes-keres', 'waiting', 'marveen', 'urgent', 1000, 1000, NULL);
INSERT INTO kanban_comments (card_id, author, content, created_at) VALUES
  ('t1-card', 'marveen', 'Döntés-kérés Józsinak elküldve: {9001} (teszt-datum).', 1000);

-- T2: ugyanaz, mint T1, DE jott egy ujabb komment a jelolo utan -- a valasz nyoma.
INSERT INTO conversation_log (agent_id, chat_id, direction, text, created_at) VALUES
  ('marveen', 't2chat', 'out', '{9002} Ket dontesed van:
1. Harmadik tetel, johet?
2. Negyedik tetel, johet?', 2000);
INSERT INTO conversation_log (agent_id, chat_id, direction, text, created_at) VALUES
  ('marveen', 't2chat', 'in', 'kozbenso 1', 2001),
  ('marveen', 't2chat', 'in', 'kozbenso 2', 2002),
  ('marveen', 't2chat', 'in', 'kozbenso 3', 2003),
  ('marveen', 't2chat', 'in', 'kozbenso 4', 2004),
  ('marveen', 't2chat', 'in', 'kozbenso 5', 2005),
  ('marveen', 't2chat', 'in', 'kozbenso 6', 2006);
INSERT INTO kanban_cards VALUES ('t2-card', 'T2 megvalaszolt dontes-keres', 'done', 'marveen', 'urgent', 2500, 2000, NULL);
INSERT INTO kanban_comments (card_id, author, content, created_at) VALUES
  ('t2-card', 'marveen', 'Döntés-kérés Józsinak elküldve: {9002} (teszt-datum).', 2000);
INSERT INTO kanban_comments (card_id, author, content, created_at) VALUES
  ('t2-card', 'marveen', 'Jozsi valaszolt, a kartya zarhato.', 2500);

-- T5: {9005} egyetlen kerdes, szamozott lista NELKUL -- nem dontes-keres a (a) feltetel szerint.
INSERT INTO conversation_log (agent_id, chat_id, direction, text, created_at) VALUES
  ('marveen', 't5chat', 'out', '{9005} Kesz a javitas, mehet elesbe?', 5000);
INSERT INTO conversation_log (agent_id, chat_id, direction, text, created_at) VALUES
  ('marveen', 't5chat', 'in', 'kozbenso 1', 5001),
  ('marveen', 't5chat', 'in', 'kozbenso 2', 5002),
  ('marveen', 't5chat', 'in', 'kozbenso 3', 5003),
  ('marveen', 't5chat', 'in', 'kozbenso 4', 5004),
  ('marveen', 't5chat', 'in', 'kozbenso 5', 5005),
  ('marveen', 't5chat', 'in', 'kozbenso 6', 5006);
INSERT INTO kanban_cards VALUES ('t5-card', 'T5 nem szamozott lista', 'waiting', 'marveen', 'urgent', 5000, 5000, NULL);
INSERT INTO kanban_comments (card_id, author, content, created_at) VALUES
  ('t5-card', 'marveen', 'Döntés-kérés Józsinak elküldve: {9005} (teszt-datum).', 5000);

-- T6: szamozott lista + kerdojel, DE csak 2 bejovo uzenet -- a (b) kuszob alatt marad.
INSERT INTO conversation_log (agent_id, chat_id, direction, text, created_at) VALUES
  ('marveen', 't6chat', 'out', '{9006} Ket dontesed van:
1. Otodik tetel, johet?
2. Hatodik tetel, johet?', 6000);
INSERT INTO conversation_log (agent_id, chat_id, direction, text, created_at) VALUES
  ('marveen', 't6chat', 'in', 'kozbenso 1', 6001),
  ('marveen', 't6chat', 'in', 'kozbenso 2', 6002);
INSERT INTO kanban_cards VALUES ('t6-card', 'T6 kuszob alatt', 'waiting', 'marveen', 'urgent', 6000, 6000, NULL);
INSERT INTO kanban_comments (card_id, author, content, created_at) VALUES
  ('t6-card', 'marveen', 'Döntés-kérés Józsinak elküldve: {9006} (teszt-datum).', 6000);
SQL

echo "kuszob-fajl = 5" > "$FTmp/kuszob.txt"

run_script() { # $1 = szkript utvonala
  MARVEEN_DB="$FDb" \
  MARVEEN_DONTES_KUSZOB_FILE="$FTmp/kuszob.txt" \
  bash "$1"
}
# a kuszob-fajl elso sora ("kuszob-fajl = 5") szandekosan NEM tiszta szam -- ezt kulon,
# valodi ervennyel iras felul lejjebb, mielott a szkriptet elsokent futtatjuk.
echo "5" > "$FTmp/kuszob.txt"

echo "T1/T2/T5/T6 -- egy kozos DB-n"
FOut=$(run_script "$CScript")
FRc=$?

expect_contains "T1 (valaszolatlan) SZEREPEL"                    IGEN "t1-card" "$FOut"
expect_contains "T1 a {9001} sorszam is szerepel"                IGEN "{9001}" "$FOut"
expect_contains "T2 (megvalaszolt, ujabb komment) NEM szerepel"  NEM  "t2-card" "$FOut"
expect_contains "T5 (nincs szamozott lista) NEM szerepel"        NEM  "t5-card" "$FOut"
expect_contains "T6 (kuszob alatt) NEM szerepel"                 NEM  "t6-card" "$FOut"

if [ "$FRc" -eq 0 ]; then
  echo "  OK    a szkript EXIT 0-val ter vissza (meres, nem kapu)"
  FPass=$((FPass + 1))
else
  echo "  BUKIK a szkript exit kodja $FRc, vart: 0"
  FFail=$((FFail + 1))
fi

# ---------------------------------------------------------------------------
# T7 -- kulon DB-vel: csupa megvalaszolt/hatokoron-kivuli sor -> a kimenet TELJESEN URES
# ---------------------------------------------------------------------------
echo "T7 -- csupa valaszolt/hatokoron-kivuli sor -> a kimenet TELJESEN URES"
FDbUres="$FTmp/claudeclaw-ures.db"
sqlite3 "$FDbUres" <<'SQL'
CREATE TABLE conversation_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent_id TEXT NOT NULL, chat_id TEXT NOT NULL, direction TEXT NOT NULL,
  message_id TEXT, text TEXT, ts TEXT, created_at INTEGER NOT NULL
);
CREATE TABLE kanban_cards (
  id TEXT PRIMARY KEY, title TEXT, status TEXT, assignee TEXT,
  priority TEXT, updated_at INTEGER, created_at INTEGER, archived_at INTEGER
);
CREATE TABLE kanban_comments (
  id INTEGER PRIMARY KEY AUTOINCREMENT, card_id TEXT NOT NULL,
  author TEXT NOT NULL, content TEXT NOT NULL, created_at INTEGER NOT NULL
);
INSERT INTO conversation_log (agent_id, chat_id, direction, text, created_at) VALUES
  ('marveen', 't7chat', 'out', '{9007} Ket dontesed van:
1. Elso, johet?
2. Masodik, johet?', 7000);
INSERT INTO conversation_log (agent_id, chat_id, direction, text, created_at) VALUES
  ('marveen', 't7chat', 'in', 'v1', 7001), ('marveen', 't7chat', 'in', 'v2', 7002),
  ('marveen', 't7chat', 'in', 'v3', 7003), ('marveen', 't7chat', 'in', 'v4', 7004),
  ('marveen', 't7chat', 'in', 'v5', 7005), ('marveen', 't7chat', 'in', 'v6', 7006);
INSERT INTO kanban_cards VALUES ('t7-card', 'T7 megvalaszolt', 'done', 'marveen', 'urgent', 7500, 7000, NULL);
INSERT INTO kanban_comments (card_id, author, content, created_at) VALUES
  ('t7-card', 'marveen', 'Döntés-kérés Józsinak elküldve: {9007} (teszt-datum).', 7000);
INSERT INTO kanban_comments (card_id, author, content, created_at) VALUES
  ('t7-card', 'marveen', 'Jozsi valaszolt, zarva.', 7500);
SQL
FOutUres=$(MARVEEN_DB="$FDbUres" MARVEEN_DONTES_KUSZOB_FILE="$FTmp/kuszob.txt" bash "$CScript")
if [ -z "$FOutUres" ]; then
  echo "  OK    T7 kimenete teljesen ures"
  FPass=$((FPass + 1))
else
  echo "  BUKIK T7 kimenete nem ures:"
  echo "$FOutUres" | sed 's/^/       | /'
  FFail=$((FFail + 1))
fi

# ---------------------------------------------------------------------------
# M1 -- BUKAS-ELOALLITAS: a (c) feltetel (van-e ujabb komment) kivetele a szkript egy
#       MASOLATABAN. Elvarjuk, hogy T2 (megvalaszolt) EZUTAN megjelenjen -- ez igazolja,
#       hogy a baseline futasban valoban a (c) feltetel tartotta vissza, nem veletlen.
# ---------------------------------------------------------------------------
echo "M1 -- a (c) feltetel eltavolitasa utan T2-nek meg KELL jelennie"
FMut="$FTmp/valaszolatlan-dontes-keres-figyelo.mutalt.sh"
cp "$CScript" "$FMut"
# az egyetlen sor, ami a (c) feltetelt hordozza: "van-e ujabb komment a jelolo utan"
sed -i.bak "s/if max_id != c\['id'\]:/if False:/" "$FMut"

if diff -q "$CScript" "$FMut" >/dev/null 2>&1; then
  echo "  BUKIK a sed nem talalta/nem valtoztatta a (c) feltetel sorat -- a mutacio nem allt elo"
  FFail=$((FFail + 1))
else
  FOutMut=$(MARVEEN_DB="$FDb" MARVEEN_DONTES_KUSZOB_FILE="$FTmp/kuszob.txt" bash "$FMut")
  expect_contains "M1 mutalt szkript: T2 MOST mar szerepel" IGEN "t2-card" "$FOutMut"
fi

# ---------------------------------------------------------------------------
# T8 -- a mero SOHA nem kuld uzenetet magatol: nincs halozati/kuldo hivas a forrasban.
# ---------------------------------------------------------------------------
echo "T8 -- a szkript nem kuld uzenetet, csak olvas es kiir"
if grep -qiE 'curl|reply_to|api/messages|mcp__.*reply' "$CScript"; then
  echo "  BUKIK a szkript forrasa halozati/kuldo hivast tartalmaz"
  FFail=$((FFail + 1))
else
  echo "  OK    nincs kuldo/halozati hivas a forrasban"
  FPass=$((FPass + 1))
fi

echo "---"
echo "Osszesen: $FPass OK, $FFail BUKIK"
[ "$FFail" -eq 0 ]
