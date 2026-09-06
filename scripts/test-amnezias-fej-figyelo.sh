#!/usr/bin/env bash
# hu: Az `amnezias-fej-figyelo.sh` MEROESZKOZE (kartya fe2d2a70). MERT ESET (2026-09-05 18:0x):
#     a `kartya-kiosztas.sh` a 29e584e3-at a delphi fejnek adta, FRISS ABLAKKAL. A KOVETKEZO
#     heartbeat -- 1,1 perccel kesobb -- meg NULL contextTokens-t latott, es a REGI szkript
#     AMNEZIAS FEJKENT jelezte -- holott a fej a pane szerint MAR dolgozott. A ket allapot
#     kivulrol AZONOS: (a) a fej ujraindult es elvesztette a feladatot, (b) EPP MOST kapott
#     friss ablakot. A javitas a nyitott kartya STATUSZ-BELEPESENEK IDEJET nezi
#     (kanban_card_events, ugyanaz a minta mint a munka-motor-precheck.sh URGENT-KOR merojenel):
#     ha a kuszobnel frissebb, a jel targytalan.
#
# 🛑 IZOLACIO: a valodi szkriptet futtatjuk, de a `curl`-t PATH-mockkal cserejuk (csak a
#    GET /api/agents hivast valaszolja meg), es a DB-t/tokent env-valtozoval (AMNEZIA_DB,
#    AMNEZIA_TOKEN) iranyitjuk egy eldobhato sqlite peldanyra -- a szkript maga NEM masolando
#    (a fix DB-utat a szkript env-fallbackkal oldja fel, lasd amnezias-fej-figyelo.sh).
#
# 🛑 A MUTACIO-ESET (T2): a frissesseg-ellenorzes ELTAVOLITASA -- ha a mutans is zold marad
#    a T1-en, a T1 vak, nem a javitas jo.
#
# EXIT: 0 = minden eset a vart eredmenyt adta | 1 = legalabb egy eset elter

set -uo pipefail

CDir="$(cd "$(dirname "$0")" && pwd)"
CScript="$CDir/amnezias-fej-figyelo.sh"

FTmp=$(mktemp -d "${TMPDIR:-/tmp}/amnezias-fej-figyelo-teszt.XXXXXX")
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

# ── A mock curl: kizarolag a GET /api/agents hivast valaszolja meg ─────────────────────────
make_mock_curl() {
  mkdir -p "$FTmp/bin"
  cat > "$FTmp/bin/curl" <<'MOCKEOF'
#!/usr/bin/env bash
cat "$MOCK_DIR/agents.json"
MOCKEOF
  chmod +x "$FTmp/bin/curl"
}

setup_db() {
  rm -f "$FTmp/claudeclaw.db"
  sqlite3 "$FTmp/claudeclaw.db" <<'SQL'
CREATE TABLE kanban_cards (
  id TEXT PRIMARY KEY,
  title TEXT,
  status TEXT,
  assignee TEXT,
  priority TEXT,
  created_at INTEGER,
  updated_at INTEGER,
  archived_at INTEGER,
  description TEXT
);
CREATE TABLE kanban_card_events (
  id INTEGER PRIMARY KEY,
  card_id TEXT,
  from_status TEXT,
  to_status TEXT,
  actor TEXT,
  created_at INTEGER
);
SQL
}

# hu: kartya beszurasa -- created_at a letrehozas ideje (esemeny hianyaban ez a fallback-forras,
#     ugyanaz a minta mint a munka-motor-precheck.sh URGENT-KOR merojenel).
seed_card() {
  local id="$1" status="$2" assignee="$3" created_at="$4"
  sqlite3 "$FTmp/claudeclaw.db" \
    "insert into kanban_cards (id,title,status,assignee,priority,created_at,updated_at,archived_at,description) values ('$id','Teszt kartya','$status','$assignee','normal',$created_at,$created_at,NULL,'');"
}

# hu: a kartya JELENLEGI statuszaba lepesenek esemenye -- ez a mero elsodleges forrasa.
seed_status_event() {
  local card="$1" to_status="$2" created_at="$3"
  sqlite3 "$FTmp/claudeclaw.db" \
    "insert into kanban_card_events (card_id,from_status,to_status,actor,created_at) values ('$card','planned','$to_status','marveen',$created_at);"
}

agents_json_delphi_amneziagyanus() {
  cat <<'JSON'
[{"name":"marveen","running":true,"contextTokens":123456},
 {"name":"delphi","running":true,"contextTokens":null},
 {"name":"rendezo","running":true,"contextTokens":9999}]
JSON
}

run_script() {
  local kuszob="${1:-60}"
  make_mock_curl
  MOCK_DIR="$FTmp" PATH="$FTmp/bin:$PATH" \
    AMNEZIA_DB="$FTmp/claudeclaw.db" AMNEZIA_TOKEN="teszt-token" AMNEZIA_KUSZOB_SEC="$kuszob" \
    bash "$CScript" 2>&1
}

FNow=$(date +%s)

echo "── T1: friss ablak ES a kuszobnel frissebb kiosztas (30s) -> NINCS jelzes ─────────────"
setup_db
agents_json_delphi_amneziagyanus > "$FTmp/agents.json"
seed_card K-delphi in_progress delphi $(( FNow - 3600 ))
seed_status_event K-delphi in_progress $(( FNow - 30 ))
OUT="$(run_script 60)"
check "T1 nincs AMNEZIAS jelzes"        "0" "$(echo "$OUT" | grep -c 'AMNEZIAS FEJ')"
check "T1 delphi nincs megnevezve"      "0" "$(echo "$OUT" | grep -c 'delphi')"
check "T1 az alap 'nincs' uzenet all"   "1" "$(echo "$OUT" | grep -c '^amnezias-fej: nincs')"

echo "── T2 (MUTACIO): a frissesseg-ellenorzes eltavolitasa -> a T1 BUKJON vissza ────────────"
CMutans="$FTmp/amnezias-fej-figyelo-mutans.sh"
python3 - "$CScript" "$CMutans" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = "        if most-int(ota)<kuszob:\n            continue\n"
if old in text:
    open(dst, 'w').write(text.replace(old, '', 1))
PYEOF
if [ ! -s "$CMutans" ] || cmp -s "$CScript" "$CMutans" 2>/dev/null; then
  echo "  ⚠️  T2 elohivo minta nem talalt (a javitas meg nem kesz) -- mutacio egyelore kihagyva"
else
  setup_db
  agents_json_delphi_amneziagyanus > "$FTmp/agents.json"
  seed_card K-delphi in_progress delphi $(( FNow - 3600 ))
  seed_status_event K-delphi in_progress $(( FNow - 30 ))
  make_mock_curl
  OUT_MUTANS="$(MOCK_DIR="$FTmp" PATH="$FTmp/bin:$PATH" \
    AMNEZIA_DB="$FTmp/claudeclaw.db" AMNEZIA_TOKEN="teszt-token" AMNEZIA_KUSZOB_SEC="60" \
    bash "$CMutans" 2>&1)"
  check "T2 mutansnal a T1 JELZEST ad (a regi hiba visszajon)" "1" "$(echo "$OUT_MUTANS" | grep -c 'AMNEZIAS FEJ')"
fi

echo "── T3: friss ablak, DE a kartya REGEN (kuszob felett, 10 perc) all a fejen -> JELZES ──"
setup_db
agents_json_delphi_amneziagyanus > "$FTmp/agents.json"
seed_card K-delphi-regi in_progress delphi $(( FNow - 3600 ))
seed_status_event K-delphi-regi in_progress $(( FNow - 600 ))
OUT="$(run_script 60)"
check "T3 AMNEZIAS jelzes megjelenik"     "1" "$(echo "$OUT" | grep -c 'AMNEZIAS FEJ')"
check "T3 delphi megnevezve"              "1" "$(echo "$OUT" | grep -c 'delphi')"
check "T3 a kartya id megnevezve"         "1" "$(echo "$OUT" | grep -c 'K-delphi-regi')"

echo "── T4: nincs esemeny a kartyan -> a created_at a fallback-forras (regi, kuszob felett) -> JELZES ──"
setup_db
agents_json_delphi_amneziagyanus > "$FTmp/agents.json"
seed_card K-delphi-esemeny-nelkul in_progress delphi $(( FNow - 600 ))
OUT="$(run_script 60)"
check "T4 AMNEZIAS jelzes esemeny nelkuli, regi kartyanal" "1" "$(echo "$OUT" | grep -c 'AMNEZIAS FEJ')"

echo "── T5: nincs esemeny a kartyan, DE a created_at friss (kuszob alatt) -> NINCS jelzes ──"
setup_db
agents_json_delphi_amneziagyanus > "$FTmp/agents.json"
seed_card K-delphi-uj in_progress delphi $(( FNow - 10 ))
OUT="$(run_script 60)"
check "T5 nincs AMNEZIAS jelzes friss, esemeny nelkuli kartyanal" "0" "$(echo "$OUT" | grep -c 'AMNEZIAS FEJ')"

echo "── T6 (a mai delphi-eset UJRAMERESE elo adaton): delphi jelenleg NEM ad jelzest ────────"
# A 79480150/fe2d2a70 kartyan leirt mert eset (29e584e3) idokozben lezarult (status=done) -- a
# fejnek MA nincs nyitott kartyaja ES kontextusa is van. Ez maga az elfogadasi feltetel 3.
# pontjanak elo-adaton torteno igazolasa, nem szintetikus fixture.
if [ -r /Users/ceo/Marveen/store/.dashboard-token ] && curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $(cat /Users/ceo/Marveen/store/.dashboard-token)" \
    http://localhost:3420/api/agents 2>/dev/null | grep -q '^200$'; then
  OUT_ELO="$(bash "$CScript" 2>&1)"
  check "T6 az elo delphi-eset ma NEM ad AMNEZIAS jelzest" "0" "$(echo "$OUT_ELO" | grep -c 'delphi')"
else
  echo "  ⚠️  T6 kihagyva -- a dashboard API nem erheto el errol a gepről"
fi

echo
echo "Osszegzes: $FPass zold, $FFail piros"
[ "$FFail" -eq 0 ]
