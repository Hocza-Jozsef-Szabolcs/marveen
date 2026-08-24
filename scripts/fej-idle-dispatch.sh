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
  # A VHR-projektu kartyakat a dispatch NEM oszthatja ki onkezdemenyezetten -- nevesitett,
  # vissza nem vont korlatozas (CLAUDE.md, "VHR-ugyben Zoli a cimzett, a flotta az
  # e-penztargepen", 2026-08-15): a VHR-munkat Zoli kerese tartja mozgasban, nem automatikus
  # heartbeat. Bizonyitottan megismetlodott HAROM egymast koveto heartbeat-korben (2026-08-24,
  # delphi + pascal, mindannyiszor percekig futo munkat kellett visszavonni).
  # A puszta project='VHR' NEM eleg: 226 kartyan URES a project mezo (kanban-project-mezo-226-
  # kartyan-ures-20260808), ezert a cim/leiras VHR-emlitese IS kizaro ok.
  # coalesce KOTELEZO: SQL harom-erteku logikaban a `project='VHR'` NULL project eseten NULL-t
  # ad (nem FALSE-t), es a `not (NULL or ...)` is NULL marad -- a WHERE ekkor a sort KIHAGYJA,
  # nem befogadja. Enelkul MINDEN ures project-u, nem-VHR kartya csendben eltunt volna a listabol.
  #
  # A cim/leiras-szoveges fallback CSAK URES project mezonel fut -- ha a project explicit ki van
  # toltve valami MASSAL, azt kell hinni, nem a szoveget (2026-08-24, sajat hiba: a 98f3b15e,
  # project='MARVEEN', a leirasaban parhuzamos peldakent felsorolta a "VHR5"-ot is, ez a regi
  # `or title/description like '%VHR%'` miatt VHR-korlatozottnak latszott, es a backend orakig
  # tetlenul allt tole -- holott Jozsi sajat, nem-VHR feladata volt).
  vhr_feltetel="(coalesce(project,'')='VHR' or (coalesce(project,'')='' and (title like '%VHR%' or coalesce(description,'') like '%VHR%')))"
  cards=$(sqlite3 "$DB" "select id from kanban_cards where assignee='$fej' and status='planned' and archived_at is null and not $vhr_feltetel order by case priority when 'urgent' then 0 when 'high' then 1 when 'normal' then 2 else 3 end, created_at asc;")
  if [ -z "$cards" ]; then
    vhr_count=$(sqlite3 "$DB" "select count(*) from kanban_cards where assignee='$fej' and status='planned' and archived_at is null and $vhr_feltetel;")
    if [ "$vhr_count" != "0" ]; then
      echo "TETLEN: $fej -- csak VHR-projektu planned kartyaja van, korlatozva (Zoli kerese kell)"
    else
      echo "TETLEN: $fej -- nincs sajat nevre allitott planned kartyaja"
    fi
    continue
  fi
  kiosztva=0
  for card in $cards; do
    # A leiras VEGE lezaro-jelzot hordozhat (mar kesz/eldontott munka, a status planned maradt
    # egy korabbi kanban-adatvesztes/elmaradt statusz-valtas miatt -- 2026-08-24, ot eset egy
    # oran belul). Ilyenkor NE ossza ki automatikusan: a koordinator ellenorzese kell elotte.
    leiras=$(sqlite3 "$DB" "select description from kanban_cards where id='$card';")
    # "MARVEEN DONTESE" ONMAGABAN NINCS a listaban: tul tag (barmilyen koordinatori
    # ELJARAS-donteshez illeszkedik, nem csak lezarashoz -- lasd T10 / vhrkapuhatokor,
    # ahol egy AKTIV feladat kozbulso szakaszcime volt, nem lezaras). A negy korabbi
    # valos eset mindegyikeben ONMAGABAN is jelen volt legalabb egy a lenti mintak kozul.
    if echo "$leiras" | grep -qiE "MEGOLDVA:|TARGYTALAN|KESZ ES COMMITOLVA|LEZARVA"; then
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
    echo "TETLEN: $fej -- MINDEGYIK planned kartyaja elbukott a kiosztas-kapun"
  fi
done
