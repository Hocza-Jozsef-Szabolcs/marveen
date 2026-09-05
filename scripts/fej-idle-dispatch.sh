#!/bin/bash
# Tétlen (running, de NULLA in_progress/testing kártyás) fejek gépies felderítése
# és -- ha van hozzájuk rendelt planned kártya -- automatikus kiosztása.
#
# Eredet (2026-08-21): a fej-kapacitas-figyelo heartbeat prózában írta elő ugyanezt
# a lépést ("vesd össze a futó fejek listáját az aktív assignee-kkel"), és ez
# LEGALÁBB EGYSZER kimaradt -- lefutott a heartbeat, az "aktív assignee" lista
# nem tartalmazta akkát, DE ez nem lett észrevéve/kiértékelve, és egy urgent
# kártya (05b69f09) dispatch nélkül állt, amíg Józsi rá nem kérdezett.
# Ugyanaz a hibaosztály, mint a nalam-all.sh / agent-activity-snapshot.sh /
# csatorna-igeret-figyelo.sh születése: a szöveg nem elég, mert a diffelést
# ki lehet hagyni figyelmetlenségből -- a szkript nem hagyhatja ki.
set -euo pipefail
cd "$(dirname "$0")/.."

TOKEN=$(cat store/.dashboard-token)
DB=store/claudeclaw.db

# 🛑 MINDEN FEJNEK LEGYEN ITT BEJEGYZESE (kartya 22372f05) -- ZART repo-halmaz, vagy a
#    "OPEN" jelzo a SZANDEKOSAN tobb-projektes, skill-alapu fejekre (forras: a fej sajat
#    dashboard-leirasa, "MINDEN X-hez/projekthez tartozol" alaku onmegfogalmazas). MERT
#    ESET: a delphi itt NEM szerepelt (a `*)` agra esett), a regi kod az URES visszaterest
#    "nincs korlatozas"-kent olvasta, es a delphi egy JokerQ-kartyat kapott -- pedig a
#    sajat leirasa szerint "MINDEN Delphi-repohoz tartozol", ami a JokerQ-t (C#/.NET)
#    kizarja. A `*)` ag mostantol a VALODI hianyt jelenti (egy jovoben felvett fejet,
#    amit meg nem vezettek at ide) -- lasd fej_domain_illik.
fej_sajat_projektek() {
  case "$1" in
    backend)  echo "Marveen" ;;
    clicpu)   echo "CLI-CPU OctaCIL Obsivel Symphact" ;;
    design)   echo "JokerQ QuantumAE QCassa" ;;
    delphi)   echo "VHR VHR5" ;;
    pascal)   echo "VHR VHR5" ;;
    rendezo)  echo "VHR5" ;;
    javacard) echo "BitIce QCassa" ;;
    akka)     echo "OPEN" ;;
    avalonia) echo "OPEN" ;;
    ereceipt) echo "OPEN" ;;
    kutato)   echo "OPEN" ;;
    lms)      echo "OPEN" ;;
    mag)      echo "OPEN" ;;
    ordog)    echo "OPEN" ;;
    sejt)     echo "OPEN" ;;
    teszt)    echo "OPEN" ;;
    vaszon)   echo "OPEN" ;;
    *) echo "" ;;
  esac
}

# hu: HAROM kimenet, NEM ketto -- ezt hivja a set -e alatt ALLTALAN, nem bare statementkent
#     (lasd lejjebb, a `|| illik_rc=$?` minta):
#       rc=0  a kartya illik (nyilt fej, VAGY deklaralt es egyezik, VAGY nincs projekt-cimke)
#       rc=1  DEKLARALT fej, de a kartya projektje NEM egyezik -- "nem illik"
#       rc=2  NINCS DEKLARACIO (a fej_sajat_projektek `*)` agara esett) -- kulon jelzendo, mert
#             a hallgatas ADDIG engedelynek szamitott (kartya 22372f05); ez NEM ugyanaz, mint
#             az 1-es eset, mert itt a hivonak MAST kell irnia a kimenetbe (hianyzo deklaracio,
#             nem "nem illik").
fej_domain_illik() {
  local fej="$1" projekt="$2"
  local engedett p
  engedett=$(fej_sajat_projektek "$fej")
  [ "$engedett" = "OPEN" ] && return 0
  [ -z "$projekt" ] && return 0
  if [ -z "$engedett" ]; then
    return 2
  fi
  for p in $engedett; do
    [ "$p" = "$projekt" ] && return 0
  done
  return 1
}

# 🛑 MASODIK SZURO -- NYELVI JEL (kartya 3915d094): a fenti fej_domain_illik() CSAK a projekt-
#    cimket nezi, de egy projekt TOBB technologiat is fedhet (a JokerQ = Delphi VHR5-resz ES C#
#    QuantumAE-resz egyutt), es ha a kartya PROJEKT MEZOJE URES, a fenti fuggveny `[ -z "$projekt"
#    ] && return 0` miatt MINDIG atenged -- fuggetlenul a fejtol. Mert eset (be220cd8,
#    2026-09-03): egy C# fajlokat (QuantumAE/plugins/QCassa.Plugin.EscPos/*.cs) nevezo,
#    delegalatlan kartya a delphi fejhez kerult volna, ha nem all meg egy masik ok miatt (Jozsi
#    kifejezett kiosztas-tilalma) -- a projekt-cimke (JokerQ) MOST MAR (T32) kiszurne, de URES
#    projekt-cimke mellett a hezag ma is fennall.
#
#    A szuro CSAK a KIZAROLAG egy nyelvhez kotott, zart domainu fejekre fut -- a nyitott domainu
#    (OPEN) fejek szandekosan tobb-projektesek/skill-alapuak, azokra nyelvi tiltas nem indokolt.
CSHARP_NYELVI_MINTA='\.cs([^a-zA-Z0-9]|$)|\.csproj|QuantumAE'
DELPHI_NYELVI_MINTA='\.pas([^a-zA-Z0-9]|$)|\.dfm|\.dpr|\.inc([^a-zA-Z0-9]|$)|VHR5'

# hu: igaz, ha a fej deklaralt szakterulete KIZAROLAG VHR/VHR5 -- azaz Delphi-only (delphi,
#     pascal, rendezo). Nem OPEN es nem deklaralatlan fejre.
fej_delphi_only() {
  local fej="$1" engedett p
  engedett=$(fej_sajat_projektek "$fej")
  [ -z "$engedett" ] && return 1
  [ "$engedett" = "OPEN" ] && return 1
  for p in $engedett; do
    case "$p" in
      VHR|VHR5) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# hu: igaz, ha a fej ZART domainu (van deklaracioja, nem OPEN), DE a listaja NEM tartalmaz
#     VHR/VHR5-ot -- azaz Delphi-tol biztosan fuggetlen szakterulet.
fej_delphi_mentes_zart() {
  local fej="$1" engedett p
  engedett=$(fej_sajat_projektek "$fej")
  [ -z "$engedett" ] && return 1
  [ "$engedett" = "OPEN" ] && return 1
  for p in $engedett; do
    case "$p" in
      VHR|VHR5) return 1 ;;
    esac
  done
  return 0
}

# hu: rc=0 ha a kartya LEIRASA nem mond ellent a fej nyelvi szakteruletenek, rc=1 ha ellentmond.
fej_nyelv_illik() {
  local fej="$1" leiras="$2"
  local van_cs=0 van_delphi=0
  echo "$leiras" | grep -qiE "$CSHARP_NYELVI_MINTA" && van_cs=1
  echo "$leiras" | grep -qiE "$DELPHI_NYELVI_MINTA" && van_delphi=1

  if fej_delphi_only "$fej"; then
    [ "$van_cs" = "1" ] && [ "$van_delphi" = "0" ] && return 1
  elif fej_delphi_mentes_zart "$fej"; then
    [ "$van_delphi" = "1" ] && [ "$van_cs" = "0" ] && return 1
  fi
  return 0
}

# 🛑 VALASZTAS ELOTT: a fej WAITING kartyai kozott lehet olyan, aminek a blokkoloja MAR NEM
#    all -- ezt a valasztas (a "cards=" lekerdezes lent) SOHA nem latja, mert csak
#    status='planned'-ot nez, es a waiting -> planned visszaallitas nincs automatizalva
#    (kartya 79480150). KET gepiesen merheto alak van, csak azokra jelzunk -- a tobbi (kulso
#    valasz, gazda-dontes, eszkoz) NEM merheto:
#      (a) a leiras kvota-/plafon-varakozast mond, ES a quota-gate 'fut'-ot ad
#      (b) a leiras egy MASIK kartyara hivatkozik blokkolokent (8 hex karakteres ID a
#          "blokkol" szotovet tartalmazo soron), ES az a kartya mar 'done'
#    A fuggveny CSAK JELEZ (echo) -- a waiting -> planned atallitas dontes, nem meres, ezt
#    nem vegzi el.
waiting_blokkolo_jelzes() {
  local fej="$1" wcard wleiras kvota_kimenet candidate cstatus
  local waiting_cards
  waiting_cards=$(sqlite3 "$DB" "select id from kanban_cards where assignee='$fej' and status='waiting' and archived_at is null;")
  for wcard in $waiting_cards; do
    wleiras=$(sqlite3 "$DB" "select description from kanban_cards where id='$wcard';")

    if echo "$wleiras" | grep -qiE 'kv[óo]ta|plafon'; then
      kvota_kimenet=$(bash scripts/quota-gate.sh 2>/dev/null | head -1)
      if [ "$kvota_kimenet" = "fut" ]; then
        echo "JELZES: $fej -- a(z) $wcard waiting kartya kvota-/plafon-varakozast mond, de a quota-gate 'fut'-ot ad -- ELLENORIZD, lehet hogy planned-re kell allitani"
      fi
    fi

    for candidate in $(echo "$wleiras" | grep -iE 'blokkol' | grep -oE '[0-9a-f]{8}' | grep -v "^${wcard}\$" | sort -u); do
      cstatus=$(sqlite3 "$DB" "select status from kanban_cards where id='$candidate' and archived_at is null;")
      if [ "$cstatus" = "done" ]; then
        echo "JELZES: $fej -- a(z) $wcard waiting kartya a(z) $candidate kartyara hivatkozik blokkolokent, de az mar 'done' -- ELLENORIZD, lehet hogy planned-re kell allitani"
      fi
    done
  done
}

running=$(curl -s -H "Authorization: Bearer $TOKEN" http://localhost:3420/api/agents \
  | python3 -c "import json,sys
for a in json.load(sys.stdin):
    if a.get('running') and a['name'] not in ('marveen','rendezo'):
        print(a['name'])")

# 🛑 MODELL-ALAPU TESTVER-ATIRANYITAS (kartya 1f613c94, Jozsi 2026-09-05: "az Opus fejek
#    lehetoleg csak nehez feladatot kapjanak a koltseghatekonysag miatt"). A fenti `running`
#    lekerdezes csak a nevet adja vissza, a modellt nem -- ezert egy masodik lekerdezessel a
#    fej->modell parokat is beolvassuk (a mock curl teszt ugyanazt a statikus valaszt adja
#    vissza tobbszori hivasra is, tehat ez nem uj elesben-mert kockazat).
agents_modellek=$(curl -s -H "Authorization: Bearer $TOKEN" http://localhost:3420/api/agents \
  | python3 -c "import json,sys
for a in json.load(sys.stdin):
    print(a['name'], a.get('model') or '')")

fej_modellje() {
  echo "$agents_modellek" | awk -v f="$1" '$1==f{print $2; exit}'
}

# hu: numerikus koltseg-rang -- 0 = ismeretlen modell (SEM forras-, SEM celoldalon nem valt ki
#     atiranyitast), 1=haiku (legolcsobb) .. 3=opus (legdragabb).
modell_rang() {
  case "$1" in
    *opus*)   echo 3 ;;
    *sonnet*) echo 2 ;;
    *haiku*)  echo 1 ;;
    *)        echo 0 ;;
  esac
}

# hu: a "nehezseg" NINCS mert mezokent a kartyan -- a fuggveny ezert NEM a kartya cimebol vagy
#     leirasabol talal ki heurisztikat, az EGYETLEN gepiesen mert jel egy OLCSOBB, SZABAD (azaz
#     a hivaskori $idle listaban allo) testver-fej letezese, ahol "testver" = fej_sajat_projektek()
#     szerint AZONOS (nem OPEN, nem ures) szakterulet. Ha nincs ilyen, a kartya marad, ahol van.
fej_olcsobb_szabad_testver() {
  local fej="$1" engedett_fej rang_fej masik engedett_masik rang_masik
  engedett_fej=$(fej_sajat_projektek "$fej")
  [ -z "$engedett_fej" ] && return 1
  [ "$engedett_fej" = "OPEN" ] && return 1
  rang_fej=$(modell_rang "$(fej_modellje "$fej")")
  [ "$rang_fej" = "0" ] && return 1
  for masik in $idle; do
    [ "$masik" = "$fej" ] && continue
    engedett_masik=$(fej_sajat_projektek "$masik")
    [ "$engedett_masik" != "$engedett_fej" ] && continue
    rang_masik=$(modell_rang "$(fej_modellje "$masik")")
    [ "$rang_masik" = "0" ] && continue
    if [ "$rang_masik" -lt "$rang_fej" ]; then
      echo "$masik"
      return 0
    fi
  done
  return 1
}

active=$(sqlite3 "$DB" "select assignee from kanban_cards where status in ('in_progress','testing') and archived_at is null and assignee is not null group by assignee;")

idle=$(comm -23 <(echo "$running" | sort -u) <(echo "$active" | sort -u))

if [ -z "$idle" ]; then
  echo "nincs tetlen fej (mindenkinek van aktiv kartyaja)"
  exit 0
fi

for fej in $idle; do
  waiting_blokkolo_jelzes "$fej"

  # A VHR-kapacitas-korlatozast Jozsi megszuntette (2026-08-25, Telegram: "A korlatozast regen
  # eltoroltem!") -- a VHR-projektu planned kartyak mostantol ugyanugy kioszthatok, mint barmely
  # mas kartya. A korabbi kizaro szures (project='VHR' vagy cim/leiras VHR-emlites) itt megszunt.
  cards=$(sqlite3 "$DB" "select id from kanban_cards where assignee='$fej' and status='planned' and archived_at is null order by case priority when 'urgent' then 0 when 'high' then 1 when 'normal' then 2 else 3 end, created_at asc;")

  # 🛑 Ha VAN sajat kartyaja, de olcsobb+szabad testver all rendelkezesre (lasd
  #    fej_olcsobb_szabad_testver fent), a kiosztas CELJE a testver, nem $fej -- CSAK a sajat
  #    (nem fallback) agra vonatkozik, a delegalatlan/marveen fallback-kartyakra nem.
  cel_fej="$fej"
  if [ -n "$cards" ]; then
    testver=$(fej_olcsobb_szabad_testver "$fej") || testver=""
    [ -n "$testver" ] && cel_fej="$testver"
  fi

  # Ha a fejnek nincs SAJAT nevere allitott planned kartyaja, a delegalatlan (assignee NULL)
  # es a marveen-nevu planned kartyak is jelolt kiosztasi celok -- a szures korabban CSAK
  # assignee='$fej'-et nezte, ezert ezek strukturalisan sosem kaptak kiosztast (c928b7c7).
  # A sajat nevre allitott kartya ELSoBBSEGET elvezi: ez a fallback csak akkor fut, ha a
  # fenti lekerdezes ures -- a prioritas-sorrend (urgent/high/normal/low, created_at asc)
  # valtozatlan marad.
  #
  # 🛑 A "fallback" JELZo ITT DoL EL, hogy a SZAKTERULET-EGYEZTETES (lentebb) fusson-e: a SAJAT
  #    nevre mar allitott kartyak (fenti lekerdezes) egy MAR MEGHOZOTT dontest hordoznak, azt a
  #    dispatch nem kerdojelezi meg -- pl. backend sajat 'QCassa'-projektu kartyai a QCassa
  #    build-szamat MERo SAJAT szkriptjeirol szolnak (device-registry-record-repo-hash-20260826),
  #    a szures ott HAMIS BLOKKOT adna.
  fallback=0
  if [ -z "$cards" ]; then
    fallback=1
    # 🛑 MARVEEN SAJAT KOORDINACIOS KARTYAJA KIZARVA (kartya 11ce879a) -- ket eltero jelleg
    #    keveredik a status='planned', assignee='marveen' halmazban: (a) valoban delegalatlan,
    #    barki altal elveheto kartya (ld. T16/c928b7c7), es (b) marveen SAJAT, nem-delegalando
    #    koordinacios/elemzo feladata, amit csak a `status` mezo alapjan a fallback
    #    megkulonboztethetetlennek lat a delegalatlantol. Mert eset (c5636788, 2026-09-03): egy
    #    ilyen sajat kartyat delphi kapott, vissza kellett venni. A `MARVEEN-SAJAT-KOORDINACIOS-
    #    KARTYA` jelzo a LEIRASBAN zarja ki a kartyat a fallback-halmazbol -- KIZAROLAG az
    #    assignee='marveen' agra vonatkozik, a valoban delegalatlan (assignee NULL) kartyakra nem,
    #    meg akkor sem, ha a leirasuk veletlenul ugyanezt a szoveget tartalmazza.
    cards=$(sqlite3 "$DB" "select id from kanban_cards where (assignee is null or (assignee='marveen' and (description is null or description not like '%MARVEEN-SAJAT-KOORDINACIOS-KARTYA%'))) and status='planned' and archived_at is null order by case priority when 'urgent' then 0 when 'high' then 1 when 'normal' then 2 else 3 end, created_at asc;")
  fi
  if [ -z "$cards" ]; then
    echo "TETLEN: $fej -- nincs sajat nevre, delegalatlan vagy marveen-nevu planned kartyaja"
    continue
  fi
  kiosztva=0
  hatokor_kihagyva=0
  for card in $cards; do
    # 🛑 SZAKTERULET-EGYEZTETES (72df44eb, szigoritva 22372f05) -- CSAK a fallback-agon
    #    (delegalatlan/marveen-nevu kartyan), ahol a SZKRIPT dont a cimzettrol. Mert eset:
    #    backend ketszer JokerQ/VHR temaju delegalatlan kartyat kapott (2ad01092), clicpu
    #    Marveen-sajat infra-javitast kapott (8cb34e1b), delphi egy JokerQ-kartyat kapott
    #    (harmadik elofordulas egy napon, 22372f05) -- egyik sem illett a fej szakteruletehez.
    #    A fej_sajat_projektek() MINDEN fejre bejegyzest ad: "OPEN" a szandekosan
    #    tobb-projektes, skill-alapu fejeknek, egy zart lista a repo-hoz kotott fejeknek. A
    #    `*)` ag (URES visszateres) mostantol a VALODI hianyt jelenti -- egy jovoben felvett,
    #    ide meg at nem vezetett fejet --, es fej_domain_illik ezt KULON kilepesi kodon (2)
    #    jelzi: a hallgatas TOBBE NEM szamit engedelynek.
    # A leiras VEGE lezaro-jelzot hordozhat (mar kesz/eldontott munka, a status planned maradt
    # egy korabbi kanban-adatvesztes/elmaradt statusz-valtas miatt -- 2026-08-24, ot eset egy
    # oran belul). Ilyenkor NE ossza ki automatikusan: a koordinator ellenorzese kell elotte.
    leiras=$(sqlite3 "$DB" "select description from kanban_cards where id='$card';")
    if [ "$fallback" = "1" ]; then
      projekt=$(sqlite3 "$DB" "select project from kanban_cards where id='$card';")
      illik_rc=0
      fej_domain_illik "$fej" "$projekt" || illik_rc=$?
      if [ "$illik_rc" = "1" ]; then
        echo "KIHAGYVA: $fej -> $card -- a kartya projektje [$projekt] nem illik a(z) $fej deklaralt szakteruletehez"
        hatokor_kihagyva=1
        continue
      elif [ "$illik_rc" = "2" ]; then
        echo "KIHAGYVA: $fej -> $card -- a(z) $fej fejnek NINCS deklaralt szakterulete a fej_sajat_projektek()-ben (kartya projektje: [$projekt]) -- a kiosztas kezi ellenorzest igenyel, add fel a fej deklaraciojat, mielott automatikusan kiosztod"
        hatokor_kihagyva=1
        continue
      fi
      if ! fej_nyelv_illik "$fej" "$leiras"; then
        echo "KIHAGYVA: $fej -> $card -- a kartya leirasa a(z) $fej szakteruletevel ELLENTETES nyelvi jelet tartalmaz (a projekt-cimke [$projekt] tobb technologiat is fedhet, vagy ures)"
        hatokor_kihagyva=1
        continue
      fi
    fi
    # "MARVEEN DONTESE" ONMAGABAN NINCS a listaban: tul tag (barmilyen koordinatori
    # ELJARAS-donteshez illeszkedik, nem csak lezarashoz -- lasd T10 / vhrkapuhatokor,
    # ahol egy AKTIV feladat kozbulso szakaszcime volt, nem lezaras). A negy korabbi
    # valos eset mindegyikeben ONMAGABAN is jelen volt legalabb egy a lenti mintak kozul.
    #
    # A "4. ELFOGADASI FELTETEL" szakasz (kartya-format, CLAUDE.md) egy JOVOBELI
    # celallapotot ir le, nem a kartya JELENLEGI allapotat -- ide gyakran kerul zaro-jellegu
    # szo egy MASIK dokumentum/kartya lezarasarol. Elo eset (3a79324c): a "...doksi 5. pontja
    # frissitve/lezarva." mondat a 4. pontban allt, a sajat negy tetel egyike sem volt
    # elkezdve (0 komment), a regi detektor megis GYANUS-kent jelezte, mert a TELJES leirast
    # atvizsgalta. A zaro-jelzo keresest ezert csak az ELFOGADASI FELTETEL szakasz ELOTTI
    # reszre szukitjuk -- ha a kartya sajat 1-3. pontjaban all zaro-jelzo, az tovabbra is fog.
    shopt -s nocasematch
    if [[ "$leiras" =~ (.*)ELFOGADASI[[:space:]]+FELTETEL ]]; then
      leiras_sajat="${BASH_REMATCH[1]}"
    else
      leiras_sajat="$leiras"
    fi
    shopt -u nocasematch
    if echo "$leiras_sajat" | grep -qiE "MEGOLDVA:|TARGYTALAN|KESZ ES COMMITOLVA|LEZARVA"; then
      echo "GYANUS: $fej -> $card mar keszen allhat (a leirasban lezaro jelzo all) -- ELLENORIZD"
      continue
    fi
    if [ "$cel_fej" != "$fej" ]; then
      echo "ATIRANYITVA: $fej -> $cel_fej (kartya $card) -- $fej modellje ($(fej_modellje "$fej")) dragabb, $cel_fej ($(fej_modellje "$cel_fej")) tetlen es olcsobb, azonos szakterulet [$(fej_sajat_projektek "$fej")]"
    fi
    echo "TETLEN: $fej -> $card kiosztasa..."
    # `if` az egyetlen `set -e`-kivetel: egy blokkolt fej (nemnulla rc) NE szakitsa meg a ciklust,
    # kulonben az abecerendben UTANA kovetkezo fejek egyike sem kap eselyt kiosztasra.
    if ki=$(bash scripts/kartya-kiosztas.sh "$card" "$cel_fej" 2>&1); then
      echo "  $ki"
      kiosztva=1
      break
    else
      # Ez a kartya elbukott a kapun -- a kovetkezo planned kartyaval probalkozunk, mielott
      # veglegesen MEGALLT-ot irnank az egesz fejre.
      echo "  $ki"
    fi
  done
  if [ "$kiosztva" = "0" ]; then
    if [ "$hatokor_kihagyva" = "1" ]; then
      echo "TETLEN: $fej -- csak hatokorbe nem illo delegalatlan/marveen kartya volt, hatokor-egyezes hijan egyet sem oszt ki"
    else
      echo "TETLEN: $fej -- MINDEGYIK planned kartyaja elbukott a kiosztas-kapun"
    fi
  fi
done
