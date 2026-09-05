#!/bin/bash
# Amnezias fej: FRISS ablak (contextTokens=None) UGY, hogy nyitott (in_progress/testing) kartyaja van.
# A fej ilyenkor NEM tetlen -- a tabla szerint dolgozik --, de a feladat a beszelgetesben volt,
# es az elveszett. A fej-idle-dispatch.sh ezeket NEM latja, mert "van kartyaja".
# Merve 2026-09-05: het fej allt igy egyszerre, es a gazdanak kellett szolnia.
set -euo pipefail
TOK="$(cat /Users/ceo/Marveen/store/.dashboard-token)"
DB=/Users/ceo/Marveen/store/claudeclaw.db

curl -s -H "Authorization: Bearer $TOK" http://localhost:3420/api/agents \
| python3 -c "
import json,sys,sqlite3
ags=[a for a in json.load(sys.stdin) if a.get('running')]
db=sqlite3.connect('$DB')
rows=dict()
for asg,cnt,ids in db.execute(\"select assignee,count(*),group_concat(id,' ') from kanban_cards where status in ('in_progress','testing') and archived_at is null group by assignee\"):
    rows[asg]=(cnt,ids)
hit=[]
for a in ags:
    n=a.get('name')
    if n in ('marveen','rendezo'): continue
    if a.get('contextTokens') is None and n in rows:
        hit.append((n,)+rows[n])
if not hit:
    print('amnezias-fej: nincs (minden nyitott kartyaju fejnek van kontextusa)')
else:
    print('AMNEZIAS FEJ -- friss ablak UGY, hogy nyitott kartyaja van:')
    for n,cnt,ids in hit:
        print('  %-10s %d kartya: %s' % (n,cnt,ids))
    print()
    print('A HELYES LEPES: folytatas-uzenet, ami a KARTYARA MUTAT (ne emlekezetbol idezz).')
    print('NEM uj feladat, es NEM restart -- a kartya mar ki van osztva.')
"
