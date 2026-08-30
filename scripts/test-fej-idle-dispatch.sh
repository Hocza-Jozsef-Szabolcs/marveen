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
  local id="$1" status="$2" assignee="$3" priority="${4:-normal}" created_at="${5:-0}" description="${6:-}" project="${7:-}" title="${8:-Teszt}"
  sqlite3 "$FTmp/root/store/claudeclaw.db" \
    "insert into kanban_cards (id,title,description,status,assignee,priority,created_at,updated_at,project) values ('$id','$title','$description','$status','$assignee','$priority',$created_at,0,nullif('$project',''));"
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

echo "── T7: leiras vegen lezaro-jelzo (MEGOLDVA:) -> NE ossza ki, GYANUS jelzes, a masik kartya menjen ─"
# Elo eset (2026-08-24, negy kartya egy oran belul: sorvegellenor, freesdrv, dfmtimeoutstale,
# tcpwin7timeout, majd vhrtesztnev) -- a leiras VEGE mar tartalmazta a lezaras jelet egy korabbi
# kanban-adatvesztes/elmaradt statusz-valtas miatt, a status megis planned maradt.
setup_case
printf '%s' "$FAgentsJson" > "$FTmp/agents.json"
seed_card K-delphi-1 planned delphi urgent 0 "Resz 1.\n\nMEGOLDVA: mar kesz, commit abc123."
seed_card K-delphi-2 planned delphi urgent 1 "Meg nyitott munka, normal leiras."
rc=$(run_script)
check "T7 a lezart kartya NEM lett kiosztva"     "0" "$(hivas_szam 'KIOSZTAS: K-delphi-1 delphi')"
check "T7 a nyitott kartya IGEN kiosztva"        "1" "$(hivas_szam 'KIOSZTAS: K-delphi-2 delphi')"
check "T7 GYANUS jelzes a kimenetben"            "1" "$(grep -c 'GYANUS' "$FTmp/kimenet" || true)"
check "T7 kilepesi kod 0"                        "0" "$rc"

echo "── T9: minden planned kartya lezart -> a fej MINDEGYIK-en fennakad, nincs kiosztas ─────"
setup_case
printf '%s' "$FAgentsJson" > "$FTmp/agents.json"
seed_card K-delphi-1 planned delphi urgent 0 "TARGYTALAN -- lezarva 2026-08-04."
rc=$(run_script)
check "T9 a lezart kartya NEM lett kiosztva"     "0" "$(hivas_szam 'KIOSZTAS: K-delphi-1 delphi')"
check "T9 GYANUS jelzes a kimenetben"            "1" "$(grep -c 'GYANUS' "$FTmp/kimenet" || true)"
check "T9 kilepesi kod 0"                        "0" "$rc"

echo "── T10: HAMIS POZITIV -- 'marveen dontese' egy AKTIV feladat kozepen, nem lezaras ──"
# Elo eset (2026-08-24, `vhrkapuhatokor`): a leiras egy KOZBULSO szakasz fejleceben tartalmazza
# a "marveen dontese" szot ("=== ELJARAS (marveen dontese, 2026-08-06) ==="), de a szakasz maga
# egy AKTIV munka-utasitas (ket kez, nem egyszerre), nem lezaras -- a kartya VALODI nyitott munka.
# A "marveen dontese" onmagaban tul tag minta, a tobbi (MEGOLDVA:/TARGYTALAN/KESZ ES COMMITOLVA/
# LEZARVA) mind a NEGY korabbi valos esetben (freesdrv/sorvegellenor/dfmtimeoutstale/tcpwin7timeout)
# ONMAGABAN is jelen volt -- a "marveen dontese" eltavolitasa nem gyengiti a valodi detektalast.
setup_case
printf '%s' "$FAgentsJson" > "$FTmp/agents.json"
seed_card K-delphi-1 planned delphi urgent 0 "=== ELJARAS (marveen dontese, 2026-08-06) ===
A kapu MODOSITASA es az ELLENORZESE ket kezben marad, de NEM egyidoben."
rc=$(run_script)
check "T10 az aktiv kartya IGEN kiosztva (nincs hamis GYANUS)" "1" "$(hivas_szam 'KIOSZTAS: K-delphi-1 delphi')"
check "T10 kilepesi kod 0"                                     "0" "$rc"

echo "── T19: HAMIS POZITIV -- a ZARO-jelzo a 4. ELFOGADASI FELTETEL pontban egy MASIK ─"
echo "        dokumentum/kartya jovobeli celallapotarol szol, nem a sajat kartyaerol ─"
# Elo eset (3a79324c): a leiras 4. pontja ("...doksi 5. pontja frissitve/lezarva.") egy MASIK
# dokumentum jovobeli lezarasarol szol, nem a sajat negy tetel allapotarol -- a kartyanak
# 0 kommentje volt, egyik tetele sem volt elkezdve, a regi detektor megis GYANUS-kent
# jelezte, mert a TELJES leirast atvizsgalta, nem csak az 1-3. pontokat.
setup_case
printf '%s' "$FAgentsJson" > "$FTmp/agents.json"
seed_card K-delphi-1 planned delphi urgent 0 "1. MERT TENY: negy hatralevo tetel, a hordozo kartya mar done.
2. KOVETKEZMENY: arva marad kartya nelkul.
3. MIT KELL TENNI: mind a negy tetel megvalositasa.
4. ELFOGADASI FELTETEL: mind a negy tetel implementalva, a masik doksi 5. pontja frissitve/lezarva."
rc=$(run_script)
check "T19 a nyitott kartya IGEN kiosztva (nincs hamis GYANUS)" "1" "$(hivas_szam 'KIOSZTAS: K-delphi-1 delphi')"
check "T19 kilepesi kod 0"                                     "0" "$rc"

echo "── T20 (MUTACIO): az ELFOGADASI FELTETEL-szukites kivetele -> a T19 BUKJON vissza ─"
CMutans6="$FTmp/fej-idle-dispatch-mutans6.sh"
python3 - "$CScript" "$CMutans6" <<'PYEOF'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
# A leiras_sajat-szukito blokkot (shopt nocasematch + ELFOGADASI FELTETEL vagas) kihagyjuk,
# es a lezaro-jelzo grep-et visszakotjuk a TELJES leirasra -- ha a szukites meg nincs kesz,
# a fajl valtozatlan marad, a hivo ezt eszreveszi.
new = re.sub(
    r"\n *shopt -s nocasematch\n.*?\n *shopt -u nocasematch\n( *if echo )\"\$leiras_sajat\"",
    r"\n\1\"$leiras\"",
    text, count=1, flags=re.S,
)
if new != text:
    open(dst, 'w').write(new)
PYEOF
if [ ! -s "$CMutans6" ] || cmp -s "$CScript" "$CMutans6" 2>/dev/null; then
  echo "  ⚠️  T20 elohivo minta nem talalt (a javitas meg nem kesz) -- mutacio egyelore kihagyva"
else
  setup_case
  printf '%s' "$FAgentsJson" > "$FTmp/agents.json"
  seed_card K-delphi-1 planned delphi urgent 0 "1. MERT TENY: negy hatralevo tetel, a hordozo kartya mar done.
2. KOVETKEZMENY: arva marad kartya nelkul.
3. MIT KELL TENNI: mind a negy tetel megvalositasa.
4. ELFOGADASI FELTETEL: mind a negy tetel implementalva, a masik doksi 5. pontja frissitve/lezarva."
  cp "$CMutans6" "$FTmp/root/scripts/fej-idle-dispatch.sh"
  chmod +x "$FTmp/root/scripts/fej-idle-dispatch.sh"
  rc=$(run_script)
  check "T20 mutansnal a kartya NEM lett kiosztva (a T19 visszajon)" "0" "$(hivas_szam 'KIOSZTAS: K-delphi-1 delphi')"
fi

echo "── T11: CSAK VHR-projektu planned kartya -> NEM kioszthato, korlatozva-jelzes ──"
# Elo eset (2026-08-24): a fej-idle-dispatch.sh delphi-nek es pascal-nak project=VHR kartyat
# osztott ki onkezdemenyezetten, holott a VHR-vonalra nevesitett korlatozas van (CLAUDE.md,
# "VHR-ugyben Zoli a cimzett, a flotta az e-penztargepen", 2026-08-15): a VHR-munkat Zoli
# kerese tartja mozgasban, nem automatikus dispatch. Ket egymast koveto heartbeat-korben is
# megismetlodott, mielott eszrevettem.
setup_case
printf '%s' "$FAgentsJson" > "$FTmp/agents.json"
seed_card K-vhr planned delphi normal 0 "" VHR
rc=$(run_script)
check "T11 a VHR-kartya NEM lett kiosztva"        "0" "$(hivas_szam 'KIOSZTAS: K-vhr delphi')"
check "T11 korlatozva-jelzes a kimenetben"        "1" "$(grep -c 'VHR' "$FTmp/kimenet" || true)"
check "T11 kilepesi kod 0"                        "0" "$rc"

echo "── T12: VHR ES nem-VHR kartya egyutt -> a nem-VHR kioszthato, a VHR kimarad ────"
setup_case
printf '%s' "$FAgentsJson" > "$FTmp/agents.json"
seed_card K-vhr    planned delphi urgent 0 "" VHR
seed_card K-normal planned delphi normal 1 "" QCassa
rc=$(run_script)
check "T12 a VHR-kartya NEM lett kiosztva"        "0" "$(hivas_szam 'KIOSZTAS: K-vhr delphi')"
check "T12 a nem-VHR kartya kiosztva"             "1" "$(hivas_szam 'KIOSZTAS: K-normal delphi')"
check "T12 kilepesi kod 0"                        "0" "$rc"

echo "── T14: project URES, de a CIM VHR-t emlit -> NEM kioszthato (adatminosegi res) ──"
# Elo eset (2026-08-24, 1a87d194): a project mezo 226 kartyan URES (kanban-project-mezo-226-
# kartyan-ures-20260808) -- egy VHR5-os kartyan is, cimben egyertelmuen VHR5, project mezoben
# semmi. A puszta project='VHR' szures ezt nem fogta ki, delphi elkezdte, vissza kellett vonni.
setup_case
printf '%s' "$FAgentsJson" > "$FTmp/agents.json"
seed_card K-vhr-notag planned delphi normal 0 "" "" "VHR5-60: cim alapjan VHR, project ures"
rc=$(run_script)
check "T14 a project nelkuli VHR-cimu kartya NEM lett kiosztva" "0" "$(hivas_szam 'KIOSZTAS: K-vhr-notag delphi')"
check "T14 korlatozva-jelzes a kimenetben"                      "1" "$(grep -c 'korlatozva' "$FTmp/kimenet" || true)"
check "T14 kilepesi kod 0"                                      "0" "$rc"

echo "── T15: project URES, cim VHR-t emlit, DE van masik, valodi nem-VHR kartya is ──"
setup_case
printf '%s' "$FAgentsJson" > "$FTmp/agents.json"
seed_card K-vhr-notag planned delphi urgent 0 "" "" "VHR5-60: cim alapjan VHR, project ures"
seed_card K-normal    planned delphi normal 1 "" QCassa "QCassa: sima kioszthato munka"
rc=$(run_script)
check "T15 a VHR-cimu kartya NEM lett kiosztva" "0" "$(hivas_szam 'KIOSZTAS: K-vhr-notag delphi')"
check "T15 a nem-VHR kartya kiosztva"           "1" "$(hivas_szam 'KIOSZTAS: K-normal delphi')"

echo "── T13 (MUTACIO): a VHR-szures kivetele -> a T11 BUKJON vissza ────────────────"
CMutans4="$FTmp/fej-idle-dispatch-mutans4.sh"
python3 - "$CScript" "$CMutans4" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = "and not $vhr_feltetel"
new = ""
if old in text:
    open(dst, 'w').write(text.replace(old, new, 1))
PYEOF
if [ ! -s "$CMutans4" ] || cmp -s "$CScript" "$CMutans4" 2>/dev/null; then
  echo "  ⚠️  T13 elohivo minta nem talalt (a javitas meg nem kesz) -- mutacio egyelore kihagyva"
else
  setup_case
  printf '%s' "$FAgentsJson" > "$FTmp/agents.json"
  seed_card K-vhr planned delphi normal 0 "" VHR
  cp "$CMutans4" "$FTmp/root/scripts/fej-idle-dispatch.sh"
  chmod +x "$FTmp/root/scripts/fej-idle-dispatch.sh"
  rc=$(run_script)
  check "T13 mutansnal a VHR-kartya IS kiosztva (a T11 visszajon)" "1" "$(hivas_szam 'KIOSZTAS: K-vhr delphi')"
fi

echo "── T8 (MUTACIO): a lezaro-jelzo szures kivetele -> a T7 BUKJON vissza ─────────"
CMutans3="$FTmp/fej-idle-dispatch-mutans3.sh"
python3 - "$CScript" "$CMutans3" <<'PYEOF'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
# A vedelmi blokkot (a "MEGOLDVA|TARGYTALAN|..." elleni grep-et) kihagyjuk -- ha nincs ilyen
# blokk meg (a javitas nincs kesz), a fajl valtozatlan marad, a hivo ezt eszreveszi.
new = re.sub(
    r"\n *if echo \"\$leiras_sajat\".*?\n *fi\n",
    "\n",
    text, count=1, flags=re.S,
)
if new != text:
    open(dst, 'w').write(new)
PYEOF
if [ ! -s "$CMutans3" ] || cmp -s "$CScript" "$CMutans3" 2>/dev/null; then
  echo "  ⚠️  T8 elohivo minta nem talalt (a javitas meg nem kesz) -- mutacio egyelore kihagyva"
else
  setup_case
  printf '%s' "$FAgentsJson" > "$FTmp/agents.json"
  seed_card K-delphi-1 planned delphi urgent 0 "Resz 1.\n\nMEGOLDVA: mar kesz, commit abc123."
  seed_card K-delphi-2 planned delphi urgent 1 "Meg nyitott munka, normal leiras."
  cp "$CMutans3" "$FTmp/root/scripts/fej-idle-dispatch.sh"
  chmod +x "$FTmp/root/scripts/fej-idle-dispatch.sh"
  rc=$(run_script)
  check "T8 mutansnal a lezart kartya IS kiosztva (a T7 visszajon)" "1" "$(hivas_szam 'KIOSZTAS: K-delphi-1 delphi')"
fi

echo
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "  ✅ $FPass  ❌ $FFail"
[ "$FFail" -eq 0 ] || exit 1
