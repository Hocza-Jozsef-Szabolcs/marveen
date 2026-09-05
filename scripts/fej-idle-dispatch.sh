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

running=$(curl -s -H "Authorization: Bearer $TOKEN" http://localhost:3420/api/agents \
  | python3 -c "import json,sys
for a in json.load(sys.stdin):
    if a.get('running') and a['name'] not in ('marveen','rendezo'):
        print(a['name'])")

active=$(sqlite3 "$DB" "select assignee from kanban_cards where status in ('in_progress','testing') and archived_at is null and assignee is not null group by assignee;")

idle=$(comm -23 <(echo "$running" | sort -u) <(echo "$active" | sort -u))

if [ -z "$idle" ]; then
  echo "nincs tetlen fej (mindenkinek van aktiv kartyaja)"
  exit 0
fi

for fej in $idle; do
  # A VHR-kapacitas-korlatozast Jozsi megszuntette (2026-08-25, Telegram: "A korlatozast regen
  # eltoroltem!") -- a VHR-projektu planned kartyak mostantol ugyanugy kioszthatok, mint barmely
  # mas kartya. A korabbi kizaro szures (project='VHR' vagy cim/leiras VHR-emlites) itt megszunt.
  cards=$(sqlite3 "$DB" "select id from kanban_cards where assignee='$fej' and status='planned' and archived_at is null order by case priority when 'urgent' then 0 when 'high' then 1 when 'normal' then 2 else 3 end, created_at asc;")
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
    cards=$(sqlite3 "$DB" "select id from kanban_cards where (assignee is null or assignee='marveen') and status='planned' and archived_at is null order by case priority when 'urgent' then 0 when 'high' then 1 when 'normal' then 2 else 3 end, created_at asc;")
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
    fi
    # A leiras VEGE lezaro-jelzot hordozhat (mar kesz/eldontott munka, a status planned maradt
    # egy korabbi kanban-adatvesztes/elmaradt statusz-valtas miatt -- 2026-08-24, ot eset egy
    # oran belul). Ilyenkor NE ossza ki automatikusan: a koordinator ellenorzese kell elotte.
    leiras=$(sqlite3 "$DB" "select description from kanban_cards where id='$card';")
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
    echo "TETLEN: $fej -> $card kiosztasa..."
    # `if` az egyetlen `set -e`-kivetel: egy blokkolt fej (nemnulla rc) NE szakitsa meg a ciklust,
    # kulonben az abecerendben UTANA kovetkezo fejek egyike sem kap eselyt kiosztasra.
    if ki=$(bash scripts/kartya-kiosztas.sh "$card" "$fej" 2>&1); then
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
