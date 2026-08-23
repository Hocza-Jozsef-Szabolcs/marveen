#!/usr/bin/env bash
# hu: A fej-idle-dispatch.sh MEROESZKOZE. A szkript `set -euo pipefail` alatt fut, es a 38. soron
#     a `bash scripts/kartya-kiosztas.sh "$card" "$fej"` hivas VEDTELEN -- egy nemnulla visszateresi
#     kod (a fej blokkolt kiadasa) AZONNAL megszakitja a `for fej in $idle` ciklust, tehat az
#     ABECEBEN a blokkolt fej UTAN kovetkezo fejek egyetlen kore sem jutnak el kiosztasig.
#     Elesben mert eset (2026-08-23, 0ed37c77 kartya 2966-os kommentje): a delphi blokkolt
#     kiosztasa utan design/ereceipt/kutato/ordog/pascal/sejt/teszt/backend egyike sem kapott
#     eselyt aznap -- pascal sajat kartyajat kezzel kellett kiosztani.
#
# en: Measuring harness for the idle-agent dispatch loop's resilience to one blocked dispatch.
#
# 🛑 IZOLACIO: a szkript ELES agat merjuk -- egy MASOLATBAN futtatjuk (nem a repo peldanyaban),
#    a `curl`-t es a `scripts/kartya-kiosztas.sh`-t a masolat sajat konyvtaraban csereljuk le
#    naplozo/valaszolo mockra. A `sqlite3` VALODI, egy eldobhato ideiglenes DB-n dolgozik.
#
# 🛑 T3 A MUTACIO-ESET: a javitott szkriptbol KIVESSZUK az `if`-védelmet, es elvarjuk, hogy a
#    T1 VISSZAJOJJON (bukjon). Ha a mutans is zold, a T1 vak -- nem a javitas jo.
#
# EXIT: 0 = minden eset a vart eredmenyt adta | 1 = legalabb egy eset elter

set -uo pipefail

CDir="$(cd "$(dirname "$0")" && pwd)"
CScript="$CDir/fej-idle-dispatch.sh"

FTmp=$(mktemp -d "${TMPDIR:-/tmp}/fej-idle-dispatch-teszt.XXXXXX")
trap 'rm -rf "$FTmp"' EXIT

FPass=0
FFail=0

# ── A mock curl: kizarolag a GET /api/agents hivast valaszolja meg ─────────────────────────────
make_mock_curl() {
  mkdir -p "$FTmp/bin"
  cat > "$FTmp/bin/curl" <<'MOCKEOF'
#!/usr/bin/env bash
cat "$MOCK_DIR/agents.json"
MOCKEOF
  chmod +x "$FTmp/bin/curl"
}

# hu: egy teszt-eset elokeszitese -- friss projekt-gyoker (script-masolat, mock kartya-kiosztas,
#     eldobhato sqlite DB), a valodi szkript melle igazitva.
setup_case() {
  rm -rf "$FTmp/root"
  mkdir -p "$FTmp/root/scripts" "$FTmp/root/store"

  cp "$CScript" "$FTmp/root/scripts/fej-idle-dispatch.sh"
  chmod +x "$FTmp/root/scripts/fej-idle-dispatch.sh"

  echo "teszt-token" > "$FTmp/root/store/.dashboard-token"

  sqlite3 "$FTmp/root/store/claudeclaw.db" <<'SQLEOF'
CREATE TABLE kanban_cards (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT,
  status TEXT NOT NULL DEFAULT 'planned',
  assignee TEXT,
  priority TEXT NOT NULL DEFAULT 'normal',
  project TEXT,
  due_date INTEGER,
  sort_order REAL NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  archived_at INTEGER,
  parent_id TEXT,
  dispatched_at INTEGER
);
SQLEOF

  # A kiosztas-mock: naplozza a hivast, es kilepesi kodot ad. A kod forrasa elsobbseggel:
  # $FTmp/kilepokod/<fej>-<kartya> (kartyankent eltero eredmenyhez), majd $FTmp/kilepokod/<fej>
  # (a regi, fejenkenti minta), hianyzo fajl -> 0, sikeres kiosztas.
  cat > "$FTmp/root/scripts/kartya-kiosztas.sh" <<'MOCKEOF'
#!/usr/bin/env bash
echo "KIOSZTAS: $1 $2" >> "$MOCK_DIR/hivasok"
FKod=0
if [ -f "$MOCK_DIR/kilepokod/$2-$1" ]; then
  FKod=$(cat "$MOCK_DIR/kilepokod/$2-$1")
elif [ -f "$MOCK_DIR/kilepokod/$2" ]; then
  FKod=$(cat "$MOCK_DIR/kilepokod/$2")
fi
if [ "$FKod" != "0" ]; then
  echo "MEGALLT" >&2
fi
exit "$FKod"
MOCKEOF
  chmod +x "$FTmp/root/scripts/kartya-kiosztas.sh"

  rm -rf "$FTmp/kilepokod"
  mkdir -p "$FTmp/kilepokod"
  : > "$FTmp/hivasok"
}

seed_card() {
  local id="$1" status="$2" assignee="$3" priority="${4:-normal}" created_at="${5:-0}"
  sqlite3 "$FTmp/root/store/claudeclaw.db" \
    "insert into kanban_cards (id,title,status,assignee,priority,created_at,updated_at) values ('$id','Teszt','$status','$assignee','$priority',$created_at,0);"
}

# hu: a futo fejek listaja -- delphi ABECEBEN design es ereceipt ELOTT all, ahogy elesben is.
FAgentsJson='[{"name":"marveen","running":true},{"name":"delphi","running":true},{"name":"design","running":true},{"name":"ereceipt","running":true},{"name":"rendezo","running":true}]'

run_script() {
  make_mock_curl
  MOCK_DIR="$FTmp" PATH="$FTmp/bin:$PATH" \
    bash "$FTmp/root/scripts/fej-idle-dispatch.sh" >"$FTmp/kimenet" 2>&1
  echo $?
}

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

hivas_szam() {
  local n
  n=$(grep -c "$1" "$FTmp/hivasok" 2>/dev/null) || n=0
  echo "${n:-0}"
}

echo "── T1: delphi kiosztasa MEGALLT (rc=1) -> design es ereceipt is sort keruljon ──"
echo "$FAgentsJson" > "$FTmp/agents.json.tmp" # elokeszites, setup_case felulirja a gyokeret
setup_case
printf '%s' "$FAgentsJson" > "$FTmp/agents.json"
seed_card K-delphi planned delphi
seed_card K-design planned design
seed_card K-ereceipt planned ereceipt
echo "1" > "$FTmp/kilepokod/delphi"
rc=$(run_script)
check "T1 delphi megprobalva"           "1" "$(hivas_szam 'KIOSZTAS: K-delphi delphi')"
check "T1 design IS megprobalva"        "1" "$(hivas_szam 'KIOSZTAS: K-design design')"
check "T1 ereceipt IS megprobalva"      "1" "$(hivas_szam 'KIOSZTAS: K-ereceipt ereceipt')"
check "T1 a szkript vegigfut (rc=0)"    "0" "$rc"

echo "── T2: minden fej sikeresen kiosztva -> nincs regresszio ──────────────────────"
setup_case
printf '%s' "$FAgentsJson" > "$FTmp/agents.json"
seed_card K-delphi planned delphi
seed_card K-design planned design
seed_card K-ereceipt planned ereceipt
rc=$(run_script)
check "T2 delphi kiosztva"    "1" "$(hivas_szam 'KIOSZTAS: K-delphi delphi')"
check "T2 design kiosztva"    "1" "$(hivas_szam 'KIOSZTAS: K-design design')"
check "T2 ereceipt kiosztva"  "1" "$(hivas_szam 'KIOSZTAS: K-ereceipt ereceipt')"
check "T2 kilepesi kod 0"     "0" "$rc"

echo "── T4: delphi elso kartyaja MEGALLT, a masodik MEHET -> a masodikat kiosztja ──"
# Elo eset (2026-08-23 20:44): delphi ket urgent kartyaja is elegtelen meressel volt felirva --
# a `limit 1` csak az elsot probalta, es MEGALLT-nal leallt DELPHIRE nezve, holott a masodik
# menne. A javitasnak MINDEGYIK planned kartyat probalnia kell, amig egy sikerul.
setup_case
printf '%s' "$FAgentsJson" > "$FTmp/agents.json"
seed_card K-delphi-1 planned delphi urgent 0
seed_card K-delphi-2 planned delphi urgent 1
seed_card K-design   planned design
echo "1" > "$FTmp/kilepokod/delphi-K-delphi-1"
rc=$(run_script)
check "T4 az elso delphi-kartya megprobalva"  "1" "$(hivas_szam 'KIOSZTAS: K-delphi-1 delphi')"
check "T4 a masodik delphi-kartya IS probalva" "1" "$(hivas_szam 'KIOSZTAS: K-delphi-2 delphi')"
check "T4 design zavartalanul kiosztva"        "1" "$(hivas_szam 'KIOSZTAS: K-design design')"
check "T4 kilepesi kod 0"                      "0" "$rc"

echo "── T5: delphi MINDKET kartyaja MEGALLT -> vegleges leallas, de a ciklus folytatodik ─"
setup_case
printf '%s' "$FAgentsJson" > "$FTmp/agents.json"
seed_card K-delphi-1 planned delphi urgent 0
seed_card K-delphi-2 planned delphi urgent 1
seed_card K-design   planned design
echo "1" > "$FTmp/kilepokod/delphi-K-delphi-1"
echo "1" > "$FTmp/kilepokod/delphi-K-delphi-2"
rc=$(run_script)
check "T5 mindket delphi-kartya probalva (1.)" "1" "$(hivas_szam 'KIOSZTAS: K-delphi-1 delphi')"
check "T5 mindket delphi-kartya probalva (2.)" "1" "$(hivas_szam 'KIOSZTAS: K-delphi-2 delphi')"
check "T5 design meg ekkor is kiosztva"        "1" "$(hivas_szam 'KIOSZTAS: K-design design')"
check "T5 kilepesi kod 0"                      "0" "$rc"

echo "── T3 (MUTACIO): a vedelem kivetele -> a T1 BUKJON vissza ─────────────────────"
CMutans="$FTmp/fej-idle-dispatch-mutans.sh"
python3 - "$CScript" "$CMutans" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = '    if ki=$(bash scripts/kartya-kiosztas.sh "$card" "$fej" 2>&1); then'
new = '    bash scripts/kartya-kiosztas.sh "$card" "$fej"; if true; then'
if old in text:
    open(dst, 'w').write(text.replace(old, new, 1))
PYEOF
if [ ! -s "$CMutans" ] || cmp -s "$CScript" "$CMutans" 2>/dev/null; then
  echo "  ⚠️  T3 elohivo minta nem talalt (a javitas meg nem kesz) -- mutacio egyelore kihagyva"
else
  setup_case
  printf '%s' "$FAgentsJson" > "$FTmp/agents.json"
  seed_card K-delphi planned delphi
  seed_card K-design planned design
  cp "$CMutans" "$FTmp/root/scripts/fej-idle-dispatch.sh"
  chmod +x "$FTmp/root/scripts/fej-idle-dispatch.sh"
  echo "1" > "$FTmp/kilepokod/delphi"
  rc=$(run_script)
  check "T3 mutansnal design MAR NEM erhetu el (a T1 visszajon)" "0" "$(hivas_szam 'KIOSZTAS: K-design design')"
fi

echo "── T6 (MUTACIO): a 'limit 1' visszavetele -> a T4 BUKJON vissza ───────────────"
CMutans2="$FTmp/fej-idle-dispatch-mutans2.sh"
python3 - "$CScript" "$CMutans2" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = "created_at asc;\")"
new = "created_at asc limit 1;\")"
if old in text:
    open(dst, 'w').write(text.replace(old, new, 1))
PYEOF
if [ ! -s "$CMutans2" ] || cmp -s "$CScript" "$CMutans2" 2>/dev/null; then
  echo "  ⚠️  T6 elohivo minta nem talalt (a javitas meg nem kesz) -- mutacio egyelore kihagyva"
else
  setup_case
  printf '%s' "$FAgentsJson" > "$FTmp/agents.json"
  seed_card K-delphi-1 planned delphi urgent 0
  seed_card K-delphi-2 planned delphi urgent 1
  cp "$CMutans2" "$FTmp/root/scripts/fej-idle-dispatch.sh"
  chmod +x "$FTmp/root/scripts/fej-idle-dispatch.sh"
  echo "1" > "$FTmp/kilepokod/delphi-K-delphi-1"
  rc=$(run_script)
  check "T6 mutansnal a masodik kartya MAR NEM probalt (a T4 visszajon)" "0" "$(hivas_szam 'KIOSZTAS: K-delphi-2 delphi')"
fi

echo
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "  ✅ $FPass  ❌ $FFail"
[ "$FFail" -eq 0 ] || exit 1
