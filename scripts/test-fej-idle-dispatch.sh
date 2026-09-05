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
  # Sikeres kiosztasnal a VALODI kartya-kiosztas.sh az assignee-t beallitja es in_progress-re
  # viszi a kartyat (6-8. lepes) -- ezt a mock is elvegzi, kulonben egy delegalatlan/marveen
  # kartyat a soron kovetkezo tetlen fej is UJRA szabadnak latna es ujra megprobalna (T16/T18).
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
else
  sqlite3 "$MOCK_DIR/root/store/claudeclaw.db" \
    "update kanban_cards set assignee='$2', status='in_progress' where id='$1';"
fi
exit "$FKod"
MOCKEOF
  chmod +x "$FTmp/root/scripts/kartya-kiosztas.sh"

  # A kvota-kapu mock: a kimenetet egy vezerlo-fajlbol olvassa. Alapertelmezetten "FAGYASZTVA",
  # hogy a regi tesztek (egyikuk sem allit be waiting kartyat) erintetlenek maradjanak -- a mock
  # meg sem hivodik meg naluk.
  cat > "$FTmp/root/scripts/quota-gate.sh" <<'MOCKEOF'
#!/usr/bin/env bash
if [ -f "$MOCK_DIR/quota-gate-kimenet" ]; then
  cat "$MOCK_DIR/quota-gate-kimenet"
else
  echo "FAGYASZTVA"
fi
MOCKEOF
  chmod +x "$FTmp/root/scripts/quota-gate.sh"
  rm -f "$FTmp/quota-gate-kimenet"

  rm -rf "$FTmp/kilepokod"
  mkdir -p "$FTmp/kilepokod"
  : > "$FTmp/hivasok"
}

seed_card() {
  local id="$1" status="$2" assignee="$3" priority="${4:-normal}" created_at="${5:-0}" description="${6:-}" project="${7:-}" title="${8:-Teszt}"
  sqlite3 "$FTmp/root/store/claudeclaw.db" \
    "insert into kanban_cards (id,title,description,status,assignee,priority,created_at,updated_at,project) values ('$id','$title','$description','$status',nullif('$assignee',''),'$priority',$created_at,0,nullif('$project',''));"
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

echo "── T16: nincs sajat kartya, DE van delegalatlan es marveen-nevu planned -> kiosztja ─"
# Elo eset (c928b7c7): a "cards" lekerdezes csak assignee='$fej'-et nezett, ezert az
# assignee=NULL (delegalatlan) es assignee='marveen' planned kartyak SOHA nem kerultek
# kiosztasra egyetlen tetlen fejnek sem, akkor sem, ha volt tetlen kapacitas.
setup_case
printf '%s' "$FAgentsJson" > "$FTmp/agents.json"
seed_card K-delegalatlan planned "" normal 0
seed_card K-marveen      planned marveen  normal 1
rc=$(run_script)
check "T16 a delegalatlan kartya kiosztva valamelyik tetlen fejnek" \
  "1" "$(( $(hivas_szam 'KIOSZTAS: K-delegalatlan delphi') + $(hivas_szam 'KIOSZTAS: K-delegalatlan design') + $(hivas_szam 'KIOSZTAS: K-delegalatlan ereceipt') ))"
check "T16 kilepesi kod 0" "0" "$rc"

echo "── T17: SAJAT planned kartya ELSoBBSEGET elvezi a delegalatlan/marveen kartyaval szemben ─"
setup_case
printf '%s' "$FAgentsJson" > "$FTmp/agents.json"
seed_card K-delphi-sajat planned delphi normal 0
seed_card K-delegalatlan planned ""     normal 1
rc=$(run_script)
check "T17 a sajat kartya kiosztva delphinek"        "1" "$(hivas_szam 'KIOSZTAS: K-delphi-sajat delphi')"
check "T17 a delegalatlan kartyat delphi NEM probalta" "0" "$(hivas_szam 'KIOSZTAS: K-delegalatlan delphi')"
check "T17 kilepesi kod 0"                            "0" "$rc"

echo "── T18 (MUTACIO): a delegalatlan/marveen fallback kivetele -> a T16 BUKJON vissza ──"
CMutans5="$FTmp/fej-idle-dispatch-mutans5.sh"
python3 - "$CScript" "$CMutans5" <<'PYEOF'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
new = re.sub(
    r"\n *if \[ -z \"\$cards\" \]; then\n.*?cards=\$\(sqlite3.*?assignee='marveen'.*?\n *fi\n",
    "\n",
    text, count=1, flags=re.S,
)
if new != text:
    open(dst, 'w').write(new)
PYEOF
if [ ! -s "$CMutans5" ] || cmp -s "$CScript" "$CMutans5" 2>/dev/null; then
  echo "  ⚠️  T18 elohivo minta nem talalt (a javitas meg nem kesz) -- mutacio egyelore kihagyva"
else
  setup_case
  printf '%s' "$FAgentsJson" > "$FTmp/agents.json"
  seed_card K-delegalatlan planned "" normal 0
  cp "$CMutans5" "$FTmp/root/scripts/fej-idle-dispatch.sh"
  chmod +x "$FTmp/root/scripts/fej-idle-dispatch.sh"
  rc=$(run_script)
  check "T18 mutansnal a delegalatlan kartya SENKINEK nem kiosztva (a T16 visszajon)" \
    "0" "$(( $(hivas_szam 'KIOSZTAS: K-delegalatlan delphi') + $(hivas_szam 'KIOSZTAS: K-delegalatlan design') + $(hivas_szam 'KIOSZTAS: K-delegalatlan ereceipt') ))"
fi

# ── T21-T26: SZAKTERULET-EGYEZTETES a delegalatlan/marveen fallback-kartyaknal (72df44eb) ──────
# Elo eset: backend ketszer JokerQ/VHR temaju delegalatlan kartyat kapott (2ad01092, a HANDOFF
# ket korabbi esete), clicpu Marveen-sajat infra-javitast kapott (8cb34e1b) -- a fallback-ag
# szakterulet-egyezes nelkul valasztott. A sajat nevre mar allitott kartyakra (T26) a szures NEM
# vonatkozik -- azok mar meghozott dontest hordoznak (pl. backend sajat 'QCassa'-projektu
# kartyai a QCassa build-szamat MERo sajat szkriptjeirol szolnak).
FAgentsJsonBackend='[{"name":"marveen","running":true},{"name":"backend","running":true},{"name":"rendezo","running":true}]'
FAgentsJsonClicpu='[{"name":"marveen","running":true},{"name":"clicpu","running":true},{"name":"rendezo","running":true}]'

echo "── T21: backend NEM kaphat JokerQ-projektu delegalatlan kartyat (2ad01092-eset) ──"
setup_case
printf '%s' "$FAgentsJsonBackend" > "$FTmp/agents.json"
seed_card K-jokerq planned "" normal 0 "" JokerQ
rc=$(run_script)
check "T21 a JokerQ-kartyat backend NEM probalta" "0" "$(hivas_szam 'KIOSZTAS: K-jokerq backend')"
check "T21 kilepesi kod 0"                        "0" "$rc"

echo "── T22: backend TOVABBRA IS megkapja a sajat (Marveen-projektu) delegalatlan kartyat ──"
setup_case
printf '%s' "$FAgentsJsonBackend" > "$FTmp/agents.json"
seed_card K-marveenproj planned "" normal 0 "" Marveen
rc=$(run_script)
check "T22 a Marveen-projektu kartyat backend kiosztotta" "1" "$(hivas_szam 'KIOSZTAS: K-marveenproj backend')"
check "T22 kilepesi kod 0"                                "0" "$rc"

echo "── T23: clicpu NEM kaphat QCassa-projektu delegalatlan kartyat (8cb34e1b-eset) ──"
setup_case
printf '%s' "$FAgentsJsonClicpu" > "$FTmp/agents.json"
seed_card K-qcassa planned "" normal 0 "" QCassa
rc=$(run_script)
check "T23 a QCassa-kartyat clicpu NEM probalta" "0" "$(hivas_szam 'KIOSZTAS: K-qcassa clicpu')"
check "T23 kilepesi kod 0"                       "0" "$rc"

echo "── T24: clicpu TOVABBRA IS megkapja a sajat (Symphact-projektu) delegalatlan kartyat ──"
setup_case
printf '%s' "$FAgentsJsonClicpu" > "$FTmp/agents.json"
seed_card K-symphact planned "" normal 0 "" Symphact
rc=$(run_script)
check "T24 a Symphact-projektu kartyat clicpu kiosztotta" "1" "$(hivas_szam 'KIOSZTAS: K-symphact clicpu')"
check "T24 kilepesi kod 0"                                "0" "$rc"

echo "── T25: a hatokorbe NEM illo kartya kihagyasa utan a KOVETKEZO delegalatlan kartya megy ──"
setup_case
printf '%s' "$FAgentsJsonBackend" > "$FTmp/agents.json"
seed_card K-vhr        planned "" urgent 0 "" VHR
seed_card K-marveenproj planned "" normal 1 "" Marveen
rc=$(run_script)
check "T25 a VHR-kartyat backend NEM probalta"            "0" "$(hivas_szam 'KIOSZTAS: K-vhr backend')"
check "T25 a Marveen-projektu kartyat backend kiosztotta" "1" "$(hivas_szam 'KIOSZTAS: K-marveenproj backend')"
check "T25 kilepesi kod 0"                                "0" "$rc"

echo "── T26: a SZURES a SAJAT NEVRE allitott kartyakra NEM vonatkozik (mas-projektu is megy) ──"
setup_case
printf '%s' "$FAgentsJsonBackend" > "$FTmp/agents.json"
seed_card K-backend-qcassa planned backend normal 0 "" QCassa
rc=$(run_script)
check "T26 a sajat nevre allitott QCassa-kartyat backend kiosztotta" "1" "$(hivas_szam 'KIOSZTAS: K-backend-qcassa backend')"
check "T26 kilepesi kod 0"                                           "0" "$rc"

FAgentsJsonDesign='[{"name":"marveen","running":true},{"name":"design","running":true},{"name":"rendezo","running":true}]'

echo "── T28: design NEM kaphat VHR5-projektu delegalatlan kartyat (b6956b10-eset) ──"
# Elo eset (2026-08-31, b6956b10): a fallback-ag design fejnek osztott ki egy VHR5 (Delphi)
# projektu kartyat. A design/CLAUDE.md SCOPE szakasza zartan felsorolja: "A QCassa projektek
# feluletei: JokerQ, QuantumAE, Barmely tovabbi Avalonia vagy webes felulet" -- VHR5 (Delphi/BDE)
# nem tartozik ide, de a fej_sajat_projektek() design-ra uresen (= nincs korlatozas) tert vissza.
setup_case
printf '%s' "$FAgentsJsonDesign" > "$FTmp/agents.json"
seed_card K-vhr5 planned "" normal 0 "" VHR5
rc=$(run_script)
check "T28 a VHR5-kartyat design NEM probalta" "0" "$(hivas_szam 'KIOSZTAS: K-vhr5 design')"
check "T28 kilepesi kod 0"                     "0" "$rc"

echo "── T29: design TOVABBRA IS megkapja a sajat (JokerQ-projektu) delegalatlan kartyat ──"
setup_case
printf '%s' "$FAgentsJsonDesign" > "$FTmp/agents.json"
seed_card K-jokerqui planned "" normal 0 "" JokerQ
rc=$(run_script)
check "T29 a JokerQ-projektu kartyat design kiosztotta" "1" "$(hivas_szam 'KIOSZTAS: K-jokerqui design')"
check "T29 kilepesi kod 0"                              "0" "$rc"

echo "── T30: design TOVABBRA IS megkapja a sajat (QuantumAE-projektu) delegalatlan kartyat ──"
setup_case
printf '%s' "$FAgentsJsonDesign" > "$FTmp/agents.json"
seed_card K-quantumae planned "" normal 0 "" QuantumAE
rc=$(run_script)
check "T30 a QuantumAE-projektu kartyat design kiosztotta" "1" "$(hivas_szam 'KIOSZTAS: K-quantumae design')"
check "T30 kilepesi kod 0"                                 "0" "$rc"

echo "── T31 (MUTACIO): design kivetele a fej_sajat_projektek()-bol -> a T28 BUKJON vissza ──"
CMutans8="$FTmp/fej-idle-dispatch-mutans8.sh"
python3 - "$CScript" "$CMutans8" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = '    design)  echo "JokerQ QuantumAE" ;;\n'
if old in text:
    open(dst, 'w').write(text.replace(old, '', 1))
PYEOF
if [ ! -s "$CMutans8" ] || cmp -s "$CScript" "$CMutans8" 2>/dev/null; then
  echo "  ⚠️  T31 elohivo minta nem talalt (a javitas meg nem kesz) -- mutacio egyelore kihagyva"
else
  setup_case
  printf '%s' "$FAgentsJsonDesign" > "$FTmp/agents.json"
  seed_card K-vhr5 planned "" normal 0 "" VHR5
  cp "$CMutans8" "$FTmp/root/scripts/fej-idle-dispatch.sh"
  chmod +x "$FTmp/root/scripts/fej-idle-dispatch.sh"
  rc=$(run_script)
  check "T31 mutansnal a VHR5-kartya IS kiosztva (a T28 visszajon)" "1" "$(hivas_szam 'KIOSZTAS: K-vhr5 design')"
fi

echo "── T27 (MUTACIO): a szakterulet-szures kivetele -> a T21 BUKJON vissza ────────"
CMutans7="$FTmp/fej-idle-dispatch-mutans7.sh"
python3 - "$CScript" "$CMutans7" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
# Sztring-hatarokkal vagjuk ki a teljes fallback-kaput (nem regex-egyensullyal), mert a blokk
# BELUL egy MASIK if/fi-t is tartalmaz (fej_domain_illik hivasa) -- egy naiv nem-mohu "elso fi"
# regex a BELSO fi-nel allna meg, es szintaktikai hibas mutanst hagyna hatra.
start = '    if [ "$fallback" = "1" ]; then\n'
stop = '    # A leiras VEGE lezaro-jelzot hordozhat'
si, ei = text.find(start), text.find(stop)
if si != -1 and ei != -1 and si < ei:
    open(dst, 'w').write(text[:si] + text[ei:])
PYEOF
if [ ! -s "$CMutans7" ] || cmp -s "$CScript" "$CMutans7" 2>/dev/null; then
  echo "  ⚠️  T27 elohivo minta nem talalt (a javitas meg nem kesz) -- mutacio egyelore kihagyva"
else
  setup_case
  printf '%s' "$FAgentsJsonBackend" > "$FTmp/agents.json"
  seed_card K-jokerq planned "" normal 0 "" JokerQ
  cp "$CMutans7" "$FTmp/root/scripts/fej-idle-dispatch.sh"
  chmod +x "$FTmp/root/scripts/fej-idle-dispatch.sh"
  rc=$(run_script)
  check "T27 mutansnal a JokerQ-kartya IS kiosztva (a T21 visszajon)" "1" "$(hivas_szam 'KIOSZTAS: K-jokerq backend')"
fi

echo

# ── T32-T35: DEKLARALT-DE-NEM-ILLO vs NINCS-DEKLARACIO megkulonboztetese (22372f05) ─────────────
# Elo eset: a delphi fej (a fej_sajat_projektek()-ben korabban NEM szerepelt -- a `*)` uresen
# hagyo agra esett) egy JokerQ-projektu delegalatlan kartyat kapott, mert a regi kod az URES
# deklaraciot "nincs korlatozas"-kent olvasta. Ugyanez a kioszto a clicpu fejnel (VAN
# deklaracioja) MEGFOGTA ugyanezt (lasd T23). A javitas utan a delphi MAR deklaralt (VHR/VHR5),
# a "nincs deklaracio" agat egy MEG mindig deklaralatlan (a case-agban SEHOL nem szereplo) fej
# fedi le, kulon uzenettel -- a hallgatas ettol kezdve NEM szamit engedelynek.
FAgentsJsonDelphi='[{"name":"marveen","running":true},{"name":"delphi","running":true},{"name":"rendezo","running":true}]'
FAgentsJsonKiserleti='[{"name":"marveen","running":true},{"name":"kiserleti-fej","running":true},{"name":"rendezo","running":true}]'

echo "── T32: delphi NEM kaphat JokerQ-projektu delegalatlan kartyat (a MERT ESET, most mar deklaralt) ──"
setup_case
printf '%s' "$FAgentsJsonDelphi" > "$FTmp/agents.json"
seed_card K-jokerq2 planned "" normal 0 "" JokerQ
rc=$(run_script)
check "T32 a JokerQ-kartyat delphi NEM probalta"           "0" "$(hivas_szam 'KIOSZTAS: K-jokerq2 delphi')"
check "T32 az uzenet 'nem illik' (deklaralt, DE eltero), nem 'nincs deklaracio'" "1" \
  "$(grep -c "a kartya projektje \[JokerQ\] nem illik a(z) delphi deklaralt szakteruletehez" "$FTmp/kimenet")"
check "T32 kilepesi kod 0"                                 "0" "$rc"

echo "── T33: delphi TOVABBRA IS megkapja a sajat (VHR5-projektu) delegalatlan kartyat ──"
setup_case
printf '%s' "$FAgentsJsonDelphi" > "$FTmp/agents.json"
seed_card K-vhr5proj planned "" normal 0 "" VHR5
rc=$(run_script)
check "T33 a VHR5-projektu kartyat delphi kiosztotta" "1" "$(hivas_szam 'KIOSZTAS: K-vhr5proj delphi')"
check "T33 kilepesi kod 0"                            "0" "$rc"

echo "── T34: MEG DEKLARALATLAN fej (a case-agban SEHOL nem szerepel) NEM kap hatokorbe nem illo kartyat, KULON jelzessel ──"
setup_case
printf '%s' "$FAgentsJsonKiserleti" > "$FTmp/agents.json"
seed_card K-jokerq3 planned "" normal 0 "" JokerQ
rc=$(run_script)
check "T34 a JokerQ-kartyat a deklaralatlan fej NEM probalta" "0" "$(hivas_szam 'KIOSZTAS: K-jokerq3 kiserleti-fej')"
check "T34 az uzenet KULON jelzi a hianyzo deklaraciot (nem 'nem illik')" "1" \
  "$(grep -c "kiserleti-fej fejnek NINCS deklaralt szakterulete" "$FTmp/kimenet")"
check "T34 a 'nem illik' uzenet NEM jelenik meg (a ket eset nem keverendo)" "0" \
  "$(grep -c "nem illik a(z) kiserleti-fej deklaralt szakteruletehez" "$FTmp/kimenet")"
check "T34 kilepesi kod 0"                                     "0" "$rc"

echo "── T35 (MUTACIO): a 'nincs deklaracio' ag (rc=2) visszavetele a REGI 'mindig illik'-re -> a T34 BUKJON vissza ──"
# hu: A puszta ELTAVOLITAS NEM eleg mutacio: az `if/return 2/fi` blokk nelkul a fuggveny meg
#     mindig `return 1`-re esne (a `for p in $engedett` egy URES valtozon nem fut le egyszer
#     sem), tehat a kihagyas TOVABBRA IS blokkolna -- csak a rossz uzenettel. A hiteles mutacio
#     a REGI sort allitja vissza (`[ -z "$engedett" ] && return 0`), pontosan azt a viselkedest
#     reprodukalva, amit a kartya 22372f05 mert hibaja leirt.
CMutans35="$FTmp/fej-idle-dispatch-mutans35.sh"
python3 - "$CScript" "$CMutans35" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
needle = "  if [ -z \"$engedett\" ]; then\n    return 2\n  fi\n"
old_form = "  [ -z \"$engedett\" ] && return 0\n"
if needle in text:
    open(dst, 'w').write(text.replace(needle, old_form, 1))
PYEOF
if [ ! -s "$CMutans35" ] || cmp -s "$CScript" "$CMutans35" 2>/dev/null; then
  echo "  ⚠️  T35 elohivo minta nem talalt -- mutacio egyelore kihagyva"
else
  setup_case
  printf '%s' "$FAgentsJsonKiserleti" > "$FTmp/agents.json"
  seed_card K-jokerq3 planned "" normal 0 "" JokerQ
  cp "$CMutans35" "$FTmp/root/scripts/fej-idle-dispatch.sh"
  chmod +x "$FTmp/root/scripts/fej-idle-dispatch.sh"
  rc=$(run_script)
  check "T35 mutansnal a deklaralatlan fej IS megkapja a kartyat (a T34 visszajon)" "1" "$(hivas_szam 'KIOSZTAS: K-jokerq3 kiserleti-fej')"
fi

echo

# ── T36-T41: a fej WAITING kartyai kozott a feloldodott blokkolo JELZESE (79480150) ─────────────
# Elo eset (2026-09-05 16:46): a backend fejnek a bf0c6ecc kartyat osztotta ki (priority=normal)
# a kioszto, mikozben HAROM `high` kartyaja allt `waiting`-ben, es az egyiknek a blokkoloja
# (kvota-/keret-plafon-varakozas) mar megszunt. A kioszto a `status='planned'`-ot nezte, a
# `waiting`-et sosem -- a javitas KET gepiesen merheto alakra JELEZ (nem allit statuszt), a
# valasztas (a `cards=` lekerdezes) ELOTT.
FAgentsJsonBackendSolo='[{"name":"marveen","running":true},{"name":"backend","running":true},{"name":"rendezo","running":true}]'

echo "── T36: waiting kartya kvota-/plafon-varakozast mond, a quota-gate FUT -> JELZES, a tobbi kartya kiosztasa valtozatlan ──"
setup_case
printf '%s' "$FAgentsJsonBackendSolo" > "$FTmp/agents.json"
echo "fut" > "$FTmp/quota-gate-kimenet"
seed_card K-backend-waiting-kvota waiting backend high 0 "MERT TENY: kvota-/plafon-varakozas all fenn, a keret meg nem szabadult fel."
seed_card K-backend-planned      planned backend normal 1 "Sima nyitott feladat."
rc=$(run_script)
check "T36 JELZES a kimenetben"                     "1" "$(grep -c 'JELZES' "$FTmp/kimenet")"
check "T36 a JELZES a helyes kartyat nevezi meg"    "1" "$(grep -c 'K-backend-waiting-kvota' "$FTmp/kimenet")"
check "T36 a masik kartya meg is kiosztasra kerult" "1" "$(hivas_szam 'KIOSZTAS: K-backend-planned backend')"
check "T36 a waiting kartya statusza valtozatlan (waiting)" "waiting" \
  "$(sqlite3 "$FTmp/root/store/claudeclaw.db" "select status from kanban_cards where id='K-backend-waiting-kvota';")"
check "T36 kilepesi kod 0"                          "0" "$rc"

echo "── T37: waiting kartya kvota-/plafon-varakozast mond, DE a quota-gate MEG FAGYASZTVA -> NINCS jelzes (hamis pozitiv kizarva) ──"
setup_case
printf '%s' "$FAgentsJsonBackendSolo" > "$FTmp/agents.json"
echo "FAGYASZTVA" > "$FTmp/quota-gate-kimenet"
seed_card K-backend-waiting-kvota2 waiting backend high 0 "MERT TENY: kvota-/plafon-varakozas all fenn, a keret meg nem szabadult fel."
rc=$(run_script)
check "T37 NINCS JELZES, amig a quota-gate FAGYASZTVA-t ad" "0" "$(grep -c 'K-backend-waiting-kvota2' "$FTmp/kimenet")"
check "T37 kilepesi kod 0"                                   "0" "$rc"

echo "── T38: waiting kartya blokkolokent egy MASIK kartyara hivatkozik, az MAR done -> JELZES, a tobbi kartya kiosztasa valtozatlan ──"
setup_case
printf '%s' "$FAgentsJsonBackendSolo" > "$FTmp/agents.json"
seed_card deadbeef done "" normal 0 "Regen lezart segedkartya."
seed_card K-backend-waiting-blk waiting backend high 1 "MERT TENY: BLOKKOLO: deadbeef -- meg mindig waiting, pedig a blokkolo kartya mar kesz."
seed_card K-backend-planned2    planned backend normal 2 "Sima nyitott feladat 2."
rc=$(run_script)
check "T38 JELZES a kimenetben"                     "1" "$(grep -c 'JELZES' "$FTmp/kimenet")"
check "T38 a JELZES a helyes kartyat nevezi meg"    "1" "$(grep -c 'K-backend-waiting-blk' "$FTmp/kimenet")"
check "T38 a JELZES a blokkolo kartyat is nevezi"   "1" "$(grep -c 'deadbeef' "$FTmp/kimenet")"
check "T38 a masik kartya meg is kiosztasra kerult" "1" "$(hivas_szam 'KIOSZTAS: K-backend-planned2 backend')"
check "T38 a waiting kartya statusza valtozatlan (waiting)" "waiting" \
  "$(sqlite3 "$FTmp/root/store/claudeclaw.db" "select status from kanban_cards where id='K-backend-waiting-blk';")"
check "T38 kilepesi kod 0"                          "0" "$rc"

echo "── T39: waiting kartya blokkolokent egy MASIK kartyara hivatkozik, AZ MEG NEM done -> NINCS jelzes (hamis pozitiv kizarva) ──"
setup_case
printf '%s' "$FAgentsJsonBackendSolo" > "$FTmp/agents.json"
seed_card deadbee2 in_progress "" normal 0 "Meg folyamatban."
seed_card K-backend-waiting-blk2 waiting backend high 1 "MERT TENY: BLOKKOLO: deadbee2 -- meg dolgoznak rajta."
rc=$(run_script)
check "T39 NINCS JELZES, amig a blokkolo kartya nem done" "0" "$(grep -c 'K-backend-waiting-blk2' "$FTmp/kimenet")"
check "T39 kilepesi kod 0"                                 "0" "$rc"

echo "── T40 (MUTACIO): a kvota-/plafon-jelzes ag eltavolitasa -> a T36 BUKJON vissza ────"
CMutans40="$FTmp/fej-idle-dispatch-mutans40.sh"
python3 - "$CScript" "$CMutans40" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding='utf-8').read()
old = '''    if echo "$wleiras" | grep -qiE 'kv[óo]ta|plafon'; then
      kvota_kimenet=$(bash scripts/quota-gate.sh 2>/dev/null | head -1)
      if [ "$kvota_kimenet" = "fut" ]; then
        echo "JELZES: $fej -- a(z) $wcard waiting kartya kvota-/plafon-varakozast mond, de a quota-gate 'fut'-ot ad -- ELLENORIZD, lehet hogy planned-re kell allitani"
      fi
    fi

'''
if old in text:
    open(dst, 'w', encoding='utf-8').write(text.replace(old, '', 1))
PYEOF
if [ ! -s "$CMutans40" ] || cmp -s "$CScript" "$CMutans40" 2>/dev/null; then
  echo "  ⚠️  T40 elohivo minta nem talalt (a javitas meg nem kesz) -- mutacio egyelore kihagyva"
else
  setup_case
  printf '%s' "$FAgentsJsonBackendSolo" > "$FTmp/agents.json"
  echo "fut" > "$FTmp/quota-gate-kimenet"
  seed_card K-backend-waiting-kvota waiting backend high 0 "MERT TENY: kvota-/plafon-varakozas all fenn, a keret meg nem szabadult fel."
  seed_card K-backend-planned      planned backend normal 1 "Sima nyitott feladat."
  cp "$CMutans40" "$FTmp/root/scripts/fej-idle-dispatch.sh"
  chmod +x "$FTmp/root/scripts/fej-idle-dispatch.sh"
  rc=$(run_script)
  check "T40 mutansnal NINCS JELZES (a T36 visszajon)" "0" "$(grep -c 'JELZES' "$FTmp/kimenet")"
fi

echo "── T41 (MUTACIO): a blokkolo-kartya-hivatkozas jelzes ag eltavolitasa -> a T38 BUKJON vissza ─"
CMutans41="$FTmp/fej-idle-dispatch-mutans41.sh"
python3 - "$CScript" "$CMutans41" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding='utf-8').read()
old = '''    for candidate in $(echo "$wleiras" | grep -iE 'blokkol' | grep -oE '[0-9a-f]{8}' | grep -v "^${wcard}\\$" | sort -u); do
      cstatus=$(sqlite3 "$DB" "select status from kanban_cards where id='$candidate' and archived_at is null;")
      if [ "$cstatus" = "done" ]; then
        echo "JELZES: $fej -- a(z) $wcard waiting kartya a(z) $candidate kartyara hivatkozik blokkolokent, de az mar 'done' -- ELLENORIZD, lehet hogy planned-re kell allitani"
      fi
    done
'''
if old in text:
    open(dst, 'w', encoding='utf-8').write(text.replace(old, '', 1))
PYEOF
if [ ! -s "$CMutans41" ] || cmp -s "$CScript" "$CMutans41" 2>/dev/null; then
  echo "  ⚠️  T41 elohivo minta nem talalt (a javitas meg nem kesz) -- mutacio egyelore kihagyva"
else
  setup_case
  printf '%s' "$FAgentsJsonBackendSolo" > "$FTmp/agents.json"
  seed_card deadbeef done "" normal 0 "Regen lezart segedkartya."
  seed_card K-backend-waiting-blk waiting backend high 1 "MERT TENY: BLOKKOLO: deadbeef -- meg mindig waiting, pedig a blokkolo kartya mar kesz."
  seed_card K-backend-planned2    planned backend normal 2 "Sima nyitott feladat 2."
  cp "$CMutans41" "$FTmp/root/scripts/fej-idle-dispatch.sh"
  chmod +x "$FTmp/root/scripts/fej-idle-dispatch.sh"
  rc=$(run_script)
  check "T41 mutansnal NINCS JELZES (a T38 visszajon)" "0" "$(grep -c 'JELZES' "$FTmp/kimenet")"
fi

echo

# ── T42-T47: NYELVI JEL alapu masodik szuro, ha a projekt-cimke ures vagy tobb technologiat fed
#    (3915d094) ────────────────────────────────────────────────────────────────────────────────
# Elo eset (be220cd8, 2026-09-03): egy JokerQ-projektu, C# fajlokat (QuantumAE/plugins/...)
# nevezo delegalatlan kartya delphi-hez kerult, amikor a delphi meg nem szerepelt a
# fej_sajat_projektek()-ben (a `*)` uresen hagyo agara esett). Az azota bevezetett projekt-alapu
# szures (delphi='VHR VHR5', T32) MAR kiszurne a projekt='JokerQ' esetet -- DE ha a kartya
# PROJEKT MEZOJE URES marad (a `[ -z "$projekt" ] && return 0` mindig atenged), a hezag MEG MOST
# IS fennall: egy projekt-cimke NELKULI, de C#/QuantumAE-jelu delegalatlan kartya delphinek
# (vagy pascal/rendezo-nek) menne. A masodik szuro a LEIRAS fajlutvonalai/nyelvi jelei alapjan
# dont pontosan erre az esetre.
FAgentsJsonDelphiSolo='[{"name":"marveen","running":true},{"name":"delphi","running":true},{"name":"rendezo","running":true}]'

echo "── T42: delphi (Delphi-only) NEM kaphat C#/QuantumAE-jelu delegalatlan kartyat, meg URES projekt-cimkevel sem ──"
setup_case
printf '%s' "$FAgentsJsonDelphiSolo" > "$FTmp/agents.json"
seed_card K-nyelvi-cs planned "" normal 0 "TEscPosPrinterPlugin.cs:583 QuantumAE/plugins/QCassa.Plugin.EscPos modositas."
rc=$(run_script)
check "T42 a C#-jelu kartyat delphi NEM probalta" "0" "$(hivas_szam 'KIOSZTAS: K-nyelvi-cs delphi')"
check "T42 kilepesi kod 0"                        "0" "$rc"

echo "── T43: delphi TOVABBRA IS megkapja a Delphi-jelu (.pas/.dfm) delegalatlan kartyat, URES projekt-cimkevel ──"
setup_case
printf '%s' "$FAgentsJsonDelphiSolo" > "$FTmp/agents.json"
seed_card K-nyelvi-pas planned "" normal 0 "DUpgrade.pas modositas, uj mezo a Datamodule1.dfm-ben."
rc=$(run_script)
check "T43 a Delphi-jelu kartyat delphi kiosztotta" "1" "$(hivas_szam 'KIOSZTAS: K-nyelvi-pas delphi')"
check "T43 kilepesi kod 0"                          "0" "$rc"

echo "── T44 (FORDITVA): backend (nem Delphi-domainu, zart) NEM kaphat .pas/.dfm-jelu delegalatlan kartyat ──"
setup_case
printf '%s' "$FAgentsJsonBackendSolo" > "$FTmp/agents.json"
seed_card K-nyelvi-pas2 planned "" normal 0 "DUpgrade.pas modositas, VHR5 tabla-migracio."
rc=$(run_script)
check "T44 a Delphi-jelu kartyat backend NEM probalta" "0" "$(hivas_szam 'KIOSZTAS: K-nyelvi-pas2 backend')"
check "T44 kilepesi kod 0"                             "0" "$rc"

echo "── T45: backend TOVABBRA IS megkapja a semleges (nyelvi jel nelkuli) delegalatlan kartyat ──"
setup_case
printf '%s' "$FAgentsJsonBackendSolo" > "$FTmp/agents.json"
seed_card K-nyelvi-semleges planned "" normal 0 "Dashboard API vegpont hibakezelese, teszt hozzaadva."
rc=$(run_script)
check "T45 a semleges kartyat backend kiosztotta" "1" "$(hivas_szam 'KIOSZTAS: K-nyelvi-semleges backend')"
check "T45 kilepesi kod 0"                        "0" "$rc"

echo "── T46 (MUTACIO): a nyelvi szuro kivetele -> a T42 BUKJON vissza ───────────────"
CMutans42="$FTmp/fej-idle-dispatch-mutans42.sh"
python3 - "$CScript" "$CMutans42" <<'PYEOF'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding='utf-8').read()
new = re.sub(
    r"\n *if ! fej_nyelv_illik.*?\n *fi\n",
    "\n",
    text, count=1, flags=re.S,
)
if new != text:
    open(dst, 'w', encoding='utf-8').write(new)
PYEOF
if [ ! -s "$CMutans42" ] || cmp -s "$CScript" "$CMutans42" 2>/dev/null; then
  echo "  ⚠️  T46 elohivo minta nem talalt (a javitas meg nem kesz) -- mutacio egyelore kihagyva"
else
  setup_case
  printf '%s' "$FAgentsJsonDelphiSolo" > "$FTmp/agents.json"
  seed_card K-nyelvi-cs planned "" normal 0 "TEscPosPrinterPlugin.cs:583 QuantumAE/plugins/QCassa.Plugin.EscPos modositas."
  cp "$CMutans42" "$FTmp/root/scripts/fej-idle-dispatch.sh"
  chmod +x "$FTmp/root/scripts/fej-idle-dispatch.sh"
  rc=$(run_script)
  check "T46 mutansnal a C#-jelu kartya IS kiosztva (a T42 visszajon)" "1" "$(hivas_szam 'KIOSZTAS: K-nyelvi-cs delphi')"
fi

echo "── T47 (MUTACIO): a forditott iranyu nyelvi szuro kivetele -> a T44 BUKJON vissza ─"
CMutans44="$FTmp/fej-idle-dispatch-mutans44.sh"
python3 - "$CScript" "$CMutans44" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding='utf-8').read()
# Az egesz elif-agat toroljuk (nem csak a belso sort) -- ures if-then blokk szintaktikai hibat
# adna, ami a TELJES scriptet leallitana parse-idoben, es nem a valodi viselkedest merne.
old = '  elif fej_delphi_mentes_zart "$fej"; then\n    [ "$van_delphi" = "1" ] && [ "$van_cs" = "0" ] && return 1\n'
if old in text:
    open(dst, 'w', encoding='utf-8').write(text.replace(old, '', 1))
PYEOF
if [ ! -s "$CMutans44" ] || cmp -s "$CScript" "$CMutans44" 2>/dev/null; then
  echo "  ⚠️  T47 elohivo minta nem talalt (a javitas meg nem kesz) -- mutacio egyelore kihagyva"
else
  setup_case
  printf '%s' "$FAgentsJsonBackendSolo" > "$FTmp/agents.json"
  seed_card K-nyelvi-pas2 planned "" normal 0 "DUpgrade.pas modositas, VHR5 tabla-migracio."
  cp "$CMutans44" "$FTmp/root/scripts/fej-idle-dispatch.sh"
  chmod +x "$FTmp/root/scripts/fej-idle-dispatch.sh"
  rc=$(run_script)
  check "T47 mutansnal a Delphi-jelu kartya IS kiosztva (a T44 visszajon)" "1" "$(hivas_szam 'KIOSZTAS: K-nyelvi-pas2 backend')"
fi

# ── T48-T52: MODELL-ALAPU TESTVER-ATIRANYITAS (kartya 1f613c94) ─────────────────────────────
# Jozsi kerese (2026-09-05, Telegram): "Arra kellene figyelni, hogy az Opus fejek lehetoleg csak
# nehez feladatot kapjanak a koltseghatekonysag miatt." A fej-idle-dispatch a kiosztaskor eddig
# nem nezte a cel-fej MODELLJET -- delphi (Opus) es pascal (Sonnet) ugyanazon a szakteruleten
# (fej_sajat_projektek: "VHR VHR5") ketszeresen van lefedve, es a valasztas eddig csak azon mult,
# melyikuk volt eppen tetlen. A "nehezseg" nincs mert mezokent a kartyan -- az egyetlen gepiesen
# mert jel az OLCSOBB, SZABAD (tetlen) testver-fej letezese.
FAgentsJsonDelphiPascal='[{"name":"marveen","running":true},{"name":"delphi","running":true,"model":"claude-opus-5"},{"name":"pascal","running":true,"model":"claude-sonnet-5"},{"name":"rendezo","running":true}]'
FAgentsJsonDelphiCsak='[{"name":"marveen","running":true},{"name":"delphi","running":true,"model":"claude-opus-5"},{"name":"rendezo","running":true}]'
FAgentsJsonAzonosModell='[{"name":"marveen","running":true},{"name":"delphi","running":true,"model":"claude-sonnet-5"},{"name":"pascal","running":true,"model":"claude-sonnet-5"},{"name":"rendezo","running":true}]'

echo "── T48: delphi (Opus) sajat kartyaja -> OLCSOBB, SZABAD testver (pascal, Sonnet) kapja ──"
setup_case
printf '%s' "$FAgentsJsonDelphiPascal" > "$FTmp/agents.json"
seed_card K-delphi-opus planned delphi
rc=$(run_script)
check "T48 a kartyat PASCAL kapta"                 "1" "$(hivas_szam 'KIOSZTAS: K-delphi-opus pascal')"
check "T48 delphi NEM probalta a sajat kartyajat"  "0" "$(hivas_szam 'KIOSZTAS: K-delphi-opus delphi')"
check "T48 ATIRANYITVA jelzes a kimenetben"        "1" "$(grep -c 'ATIRANYITVA' "$FTmp/kimenet" || true)"
check "T48 kilepesi kod 0"                         "0" "$rc"

echo "── T49: a testver (pascal) FOGLALT -> delphi a sajat kartyajat kapja (nincs valtozas) ──"
setup_case
printf '%s' "$FAgentsJsonDelphiPascal" > "$FTmp/agents.json"
seed_card K-delphi-opus planned delphi
seed_card K-pascal-fut in_progress pascal
rc=$(run_script)
check "T49 delphi kapta a sajat kartyajat"  "1" "$(hivas_szam 'KIOSZTAS: K-delphi-opus delphi')"
check "T49 pascal NEM probalta"             "0" "$(hivas_szam 'KIOSZTAS: K-delphi-opus pascal')"
check "T49 kilepesi kod 0"                  "0" "$rc"

echo "── T50: NINCS testver-fej a futok kozott -> delphi a sajat kartyajat kapja ─────"
setup_case
printf '%s' "$FAgentsJsonDelphiCsak" > "$FTmp/agents.json"
seed_card K-delphi-opus planned delphi
rc=$(run_script)
check "T50 delphi kapta a sajat kartyajat"  "1" "$(hivas_szam 'KIOSZTAS: K-delphi-opus delphi')"
check "T50 kilepesi kod 0"                  "0" "$rc"

echo "── T51: delphi es pascal AZONOS modellen -> nincs 'olcsobb', nincs atiranyitas ──"
setup_case
printf '%s' "$FAgentsJsonAzonosModell" > "$FTmp/agents.json"
seed_card K-delphi-opus planned delphi
rc=$(run_script)
check "T51 delphi kapta a sajat kartyajat"  "1" "$(hivas_szam 'KIOSZTAS: K-delphi-opus delphi')"
check "T51 pascal NEM probalta"             "0" "$(hivas_szam 'KIOSZTAS: K-delphi-opus pascal')"
check "T51 kilepesi kod 0"                  "0" "$rc"

echo "── T52 (MUTACIO): az atiranyitas kivetele -> a T48 BUKJON vissza ───────────────"
CMutans48="$FTmp/fej-idle-dispatch-mutans48.sh"
python3 - "$CScript" "$CMutans48" <<'PYEOF'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding='utf-8').read()
new = re.sub(
    r"\n *cel_fej=\"\$fej\"\n *if \[ -n \"\$cards\" \]; then\n.*?\n *fi\n",
    "\n    cel_fej=\"$fej\"\n",
    text, count=1, flags=re.S,
)
if new != text:
    open(dst, 'w', encoding='utf-8').write(new)
PYEOF
if [ ! -s "$CMutans48" ] || cmp -s "$CScript" "$CMutans48" 2>/dev/null; then
  echo "  ⚠️  T52 elohivo minta nem talalt (a javitas meg nem kesz) -- mutacio egyelore kihagyva"
else
  setup_case
  printf '%s' "$FAgentsJsonDelphiPascal" > "$FTmp/agents.json"
  seed_card K-delphi-opus planned delphi
  cp "$CMutans48" "$FTmp/root/scripts/fej-idle-dispatch.sh"
  chmod +x "$FTmp/root/scripts/fej-idle-dispatch.sh"
  rc=$(run_script)
  check "T52 mutansnal delphi kapja a kartyat (a T48 visszajon)" "1" "$(hivas_szam 'KIOSZTAS: K-delphi-opus delphi')"
fi

echo
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "  ✅ $FPass  ❌ $FFail"
[ "$FFail" -eq 0 ] || exit 1
