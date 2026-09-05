#!/bin/bash
# hu: KARTYA ISMERETLEN FEJ NEVEN -- egy nyitott (in_progress/testing/waiting) kartya olyan
#     assignee-vel allhat, ami NEM letezo fej a flottaban, es egyik mero sem veszi eszre:
#     a fej-idle-dispatch.sh a FUTO fejekre iteral (a nem letezo nev sosem fut, tehat sosem
#     kerul listaba), a nalam-all.sh csak a marveen neven allo kartyakat nezi, az
#     amnezias-fej-figyelo.sh pedig a fej KONTEXTUSAT meri -- de itt nincs fej, aminek
#     kontextusa lenne. Egy ilyen kartya tetszoleges ideig allhat, es semmi nem jelzi.
#     Merve 2026-09-05: a 96645657 kartya a letrehozasa ota (14:51) 'jokerq-22' nevu,
#     NEM LETEZo assignee-vel allt in_progress-ben -- hataridos kartya volt.
#
#     A "LETEZo FEJ" a GET /api/agents lista NEVEI, KIEGESZITVE 'marveen'-nel: a koordinator
#     maga nem szerepel a fej-listaban (nem "fej", hanem a flotta gazdaja), de ervenyes
#     assignee -- nyitott kartyat rendszeresen visel (merve 2026-09-05: 37 db in_progress/
#     waiting kartya allt 'marveen' neven). Enelkul a mero minden futasnal hamis-pozitivot
#     adna MINDEN marveen-kartyara.
#
#     CSENDES KOR: nulla talalatnal a szkript NEM ir semmit. A mero NEM javit -- az
#     ujraosztas (melyik fej a terulet gazdaja) marveen dontese marad.
#
# en: CARD ON A NONEXISTENT AGENT NAME -- an open (in_progress/testing/waiting) card can carry
#     an assignee that is not a real fleet agent, and no existing monitor notices: fej-idle-
#     dispatch.sh iterates over RUNNING agents (a nonexistent name never runs, so it never
#     enters the loop), nalam-all.sh only looks at cards assigned to marveen, and amnezias-
#     fej-figyelo.sh measures an agent's CONTEXT -- but there is no agent here to have one.
#     Such a card can sit indefinitely with nothing flagging it.
#
#     A valid agent is any name from GET /api/agents, PLUS 'marveen': the coordinator itself
#     is not listed as a fleet agent but is a legitimate assignee -- without this the monitor
#     would false-positive on every card assigned to marveen.
#
#     SILENT ROUND: zero findings print nothing. This tool never fixes -- reassignment is
#     marveen's call.
#
# Hasznalat / Usage: kartya-ismeretlen-fej-figyelo.sh
#   Kornyezeti valtozok (tesztekhez / eltero telepiteshez):
#     MARVEEN_DB             sqlite adatbazis utvonala (alap: /Users/ceo/Marveen/store/claudeclaw.db)
#     MARVEEN_DASHBOARD_URL  dashboard API gyokere (alap: http://localhost:3420)
#     MARVEEN_TOKEN_FILE     Bearer token fajl utvonala (alap: /Users/ceo/Marveen/store/.dashboard-token)
#
# EXIT: mindig 0 -- ez meres, nem kapu. A hivo a KIMENETBoL dont.

set -euo pipefail

DB="${MARVEEN_DB:-/Users/ceo/Marveen/store/claudeclaw.db}"
URL="${MARVEEN_DASHBOARD_URL:-http://localhost:3420}"
TOKEN_FILE="${MARVEEN_TOKEN_FILE:-/Users/ceo/Marveen/store/.dashboard-token}"

if [ ! -r "$DB" ]; then
  echo "kartya-ismeretlen-fej-figyelo: az adatbazis nem olvashato: $DB" >&2
  exit 2
fi

if [ ! -r "$TOKEN_FILE" ]; then
  echo "kartya-ismeretlen-fej-figyelo: a token-fajl nem olvashato: $TOKEN_FILE" >&2
  exit 2
fi

TOK="$(cat "$TOKEN_FILE")"

curl -s -H "Authorization: Bearer $TOK" "$URL/api/agents" \
| python3 -c "
import json, sys, sqlite3

agents = set(a['name'] for a in json.load(sys.stdin))
agents.add('marveen')

db = sqlite3.connect('$DB')
rows = db.execute('''
    SELECT id, status, assignee, substr(title, 1, 60)
      FROM kanban_cards
     WHERE status IN ('in_progress', 'testing', 'waiting')
       AND archived_at IS NULL
     ORDER BY id
''').fetchall()

ismeretlen = [r for r in rows if r[2] and r[2] not in agents]
ures = [r for r in rows if not r[2]]

if not ismeretlen and not ures:
    sys.exit(0)

if ismeretlen:
    print('ISMERETLEN FEJ NEVEN ALLO KARTYA -- a nev NINCS a /api/agents listaban:')
    for cid, status, assignee, title in ismeretlen:
        print('  %-12s %-12s %-12s %s' % (cid, status, assignee, title))

if ures:
    print('URES ASSIGNEE-VEL ALLO KARTYA:')
    for cid, status, assignee, title in ures:
        print('  %-12s %-12s %s' % (cid, status, title))
"
