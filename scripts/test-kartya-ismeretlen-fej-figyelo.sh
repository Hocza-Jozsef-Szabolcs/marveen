#!/usr/bin/env bash
# hu: A kartya-ismeretlen-fej-figyelo.sh MEROESZKOZE. Kartya 35225c7c: egy nyitott
#     (in_progress/testing/waiting) kartya olyan assignee-vel allhat, ami nem letezo fej --
#     ezt merte a 96645657 kartya (jokerq-22 nevu, nem letezo assignee, hataridos kartyan).
#
#     A TESZT AZ ALABBI ESETEKET FEDI EGY KOZOS DB-BEN:
#       T1  ismert fej (akka), in_progress          -> NEM szerepel a kimenetben
#       T2  nem letezo fej (jokerq-22), in_progress -> SZEREPEL, "ISMERETLEN FEJ" cimke alatt
#       T3  'marveen' assignee, waiting              -> NEM szerepel (koordinator, ervenyes)
#       T4  ures assignee, testing                   -> SZEREPEL, "URES ASSIGNEE" cimke alatt,
#                                                        KULON az ismeretlen-fejtol
#       T5  nem letezo fej, DE status='planned'      -> NEM szerepel (hatokoron kivuli statusz)
#       T6  nem letezo fej, DE archived_at kitoltve   -> NEM szerepel (archivalt)
#     Kulon DB-vel: T7 -- csupa ervenyes/hatokoron-kivuli sor eseten a kimenet TELJESEN URES
#     (a "nulla talalatnal ne irjon semmit" kovetelmeny).
#
# 🛑 MIERT VAN BENNE MUTACIO-ESET: a zold keszlet onmagaban NEM mondja meg, hogy a teszt mer-e.
#     M1 a szkript egy MASOLATABAN kiveszi az "ismeretlen fej" szurest (mindig ervenyesnek
#     latja az assignee-t) -- elvarjuk, hogy T2 ELTuNJON a kimenetbol (a teszt ezt buktatja).
#     M2 a masolatbol kiveszi a 'marveen' hozzaadasat az ervenyes fejek halmazahoz -- elvarjuk,
#     hogy T3 (marveen assignee) HAMISAN "ISMERETLEN FEJ"-kent jelenjen meg (pontosan azt a
#     hamis-pozitiv arasztast igazolva, amit a fix elkerul).
#
# EXIT: 0 = minden eset a vart eredmenyt adta | 1 = legalabb egy eset elter

set -uo pipefail

CDir="$(cd "$(dirname "$0")" && pwd)"
CScript="$CDir/kartya-ismeretlen-fej-figyelo.sh"

FTmp=$(mktemp -d "${TMPDIR:-/tmp}/kartya-ismeretlen-fej-figyelo-teszt.XXXXXX")
trap 'rm -rf "$FTmp"' EXIT

FPass=0
FFail=0

# ── Mock curl: kizarolag a GET /api/agents hivast valaszolja meg, a $MOCK_AGENTS_JSON fajlbol ──
make_mock_curl() {
  mkdir -p "$FTmp/bin"
  cat > "$FTmp/bin/curl" <<'MOCKEOF'
#!/usr/bin/env bash
cat "$MOCK_AGENTS_JSON"
MOCKEOF
  chmod +x "$FTmp/bin/curl"
}
make_mock_curl

echo '[{"name":"akka"},{"name":"backend"},{"name":"rendezo"}]' > "$FTmp/agents.json"
echo "teszt-token" > "$FTmp/token"

FDb="$FTmp/claudeclaw.db"
sqlite3 "$FDb" <<'SQL'
CREATE TABLE kanban_cards (
  id TEXT PRIMARY KEY, title TEXT, status TEXT, assignee TEXT,
  updated_at INTEGER, archived_at INTEGER
);
INSERT INTO kanban_cards VALUES ('t1-ismert',      'T1 ismert fej',           'in_progress', 'akka',      0, NULL);
INSERT INTO kanban_cards VALUES ('t2-ismeretlen',  'T2 nem letezo fej',       'in_progress', 'jokerq-22', 0, NULL);
INSERT INTO kanban_cards VALUES ('t3-marveen',     'T3 marveen assignee',     'waiting',     'marveen',   0, NULL);
INSERT INTO kanban_cards VALUES ('t4-ures',        'T4 ures assignee',        'testing',     NULL,        0, NULL);
INSERT INTO kanban_cards VALUES ('t5-planned',     'T5 hatokoron kivuli',     'planned',     'jokerq-22', 0, NULL);
INSERT INTO kanban_cards VALUES ('t6-archivalt',   'T6 archivalt',            'in_progress', 'jokerq-22', 0, 12345);
SQL

run_script() {
  PATH="$FTmp/bin:$PATH" \
  MOCK_AGENTS_JSON="$FTmp/agents.json" \
  MARVEEN_DB="$FDb" \
  MARVEEN_TOKEN_FILE="$FTmp/token" \
  MARVEEN_DASHBOARD_URL="http://ignored.invalid" \
  bash "$1"
}

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

echo "T1-T6 -- egy kozos DB-n (vegyes esetek)"
FOut=$(run_script "$CScript")

expect_contains "T1 ismert fej NEM szerepel"           NEM "t1-ismert"     "$FOut"
expect_contains "T2 ismeretlen fej SZEREPEL"           IGEN "t2-ismeretlen" "$FOut"
expect_contains "T2 az 'ISMERETLEN FEJ' cimke alatt"   IGEN "ISMERETLEN FEJ" "$FOut"
expect_contains "T3 marveen assignee NEM szerepel"     NEM "t3-marveen"    "$FOut"
expect_contains "T4 ures assignee SZEREPEL"            IGEN "t4-ures"      "$FOut"
expect_contains "T4 az 'URES ASSIGNEE' cimke alatt"    IGEN "URES ASSIGNEE" "$FOut"
expect_contains "T5 (planned, hatokoron kivul) NEM szerepel"  NEM "t5-planned"   "$FOut"
expect_contains "T6 (archivalt) NEM szerepel"                 NEM "t6-archivalt" "$FOut"

echo "T7 -- csupa ervenyes/hatokoron-kivuli sor -> a kimenet TELJESEN URES"
FDbUres="$FTmp/claudeclaw-ures.db"
sqlite3 "$FDbUres" <<'SQL'
CREATE TABLE kanban_cards (
  id TEXT PRIMARY KEY, title TEXT, status TEXT, assignee TEXT,
  updated_at INTEGER, archived_at INTEGER
);
INSERT INTO kanban_cards VALUES ('t7-ismert',    'T7 ismert fej',      'in_progress', 'backend', 0, NULL);
INSERT INTO kanban_cards VALUES ('t7-marveen',   'T7 marveen assignee','waiting',     'marveen', 0, NULL);
INSERT INTO kanban_cards VALUES ('t7-planned',   'T7 planned',         'planned',     'jokerq-22', 0, NULL);
SQL
FOutUres=$(
  PATH="$FTmp/bin:$PATH" \
  MOCK_AGENTS_JSON="$FTmp/agents.json" \
  MARVEEN_DB="$FDbUres" \
  MARVEEN_TOKEN_FILE="$FTmp/token" \
  MARVEEN_DASHBOARD_URL="http://ignored.invalid" \
  bash "$CScript"
)
if [ -z "$FOutUres" ]; then
  echo "  OK    T7 nulla talalatnal a kimenet ures"
  FPass=$((FPass + 1))
else
  echo "  BUKIK T7 nulla talalatnal a kimenet NEM ures:"
  echo "$FOutUres" | sed 's/^/       | /'
  FFail=$((FFail + 1))
fi

echo "M1 -- mutacio: az 'ismeretlen fej' szures kivetele -> T2-nek EL KELL TuNNIE"
FMutant1="$FTmp/mutant1.sh"
sed "s/r\[2\] not in agents/False/" "$CScript" > "$FMutant1"
chmod +x "$FMutant1"
FOutM1=$(run_script "$FMutant1")
expect_contains "M1 mutacioval T2 mar NEM szerepel (a teszt biteni tud)" NEM "t2-ismeretlen" "$FOutM1"

echo "M2 -- mutacio: a 'marveen' hozzaadasanak kivetele -> T3-nak HAMISAN meg KELL jelennie"
FMutant2="$FTmp/mutant2.sh"
sed "s/agents.add('marveen')//" "$CScript" > "$FMutant2"
chmod +x "$FMutant2"
FOutM2=$(run_script "$FMutant2")
expect_contains "M2 mutacioval T3 (marveen) HAMIS-POZITIVKENT megjelenik" IGEN "t3-marveen" "$FOutM2"

echo
echo "Osszegzes: $FPass OK, $FFail BUKIK"
[ "$FFail" -eq 0 ]
