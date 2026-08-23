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
  card=$(sqlite3 "$DB" "select id from kanban_cards where assignee='$fej' and status='planned' and archived_at is null order by case priority when 'urgent' then 0 when 'high' then 1 when 'normal' then 2 else 3 end, created_at asc limit 1;")
  if [ -n "$card" ]; then
    echo "TETLEN: $fej -> $card kiosztasa..."
    # `if` az egyetlen `set -e`-kivetel: egy blokkolt fej (nemnulla rc) NE szakitsa meg a ciklust,
    # kulonben az abecerendben UTANA kovetkezo fejek egyike sem kap eselyt kiosztasra.
    if ! ki=$(bash scripts/kartya-kiosztas.sh "$card" "$fej" 2>&1); then
      echo "  $ki"
    else
      echo "  $ki"
    fi
  else
    echo "TETLEN: $fej -- nincs sajat nevre allitott planned kartyaja"
  fi
done
