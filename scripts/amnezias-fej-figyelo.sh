#!/bin/bash
# Amnezias fej: FRISS ablak (contextTokens=None) UGY, hogy nyitott (in_progress/testing) kartyaja van.
# A fej ilyenkor NEM tetlen -- a tabla szerint dolgozik --, de a feladat a beszelgetesben volt,
# es az elveszett. A fej-idle-dispatch.sh ezeket NEM latja, mert "van kartyaja".
# Merve 2026-09-05: het fej allt igy egyszerre, es a gazdanak kellett szolnia.
#
# 🛑 MINDEN FRISS KIOSZTAS UTAN HAMIS JELZEST ADOTT (merve 2026-09-05, delphi/29e584e3): a
#    kartya-kiosztas.sh friss ablakot adott a fejnek, es a KOVETKEZO heartbeat -- 1,1 perccel
#    kesobb -- meg NULL contextTokens-t latott, holott a fej a pane szerint MAR dolgozott. A ket
#    allapot kivulrol AZONOS -- (a) a fej ujraindult es elvesztette a feladatot, (b) EPP MOST
#    kapott friss ablakot es meg nem termelt eleg kimenetet a contextTokens frissuleshez --, es a
#    masodik MINDEN szabalyos kiosztas utan eloall. A megkulonbozteto jel: MIKOR lepett a fej
#    nyitott kartyaja a jelenlegi (in_progress/testing) statuszaba. Ha ez a kuszobnel frissebb, a
#    jel targytalan -- a fej nem amnezias, epp most indult.
#
#    A forras a kanban_card_events (a kanban_cards_status_audit trigger irja MINDEN
#    statuszvaltasnal, src/db.ts), NEM a kanban_cards.dispatched_at -- az utobbi write-once (csak
#    a kartya ELSo valaha tortent in_progress-be lepesekor all be, src/web/routes/kanban.ts:89
#    `if (!card || card.dispatched_at) return`), tehat egy ujra-kiosztott/folytatott kartyanal
#    regi, hamis idot adna vissza.
set -euo pipefail

FDb="${AMNEZIA_DB:-/Users/ceo/Marveen/store/claudeclaw.db}"

FTok="${AMNEZIA_TOKEN:-}"
if [ -z "$FTok" ]; then
  FTok="$(cat /Users/ceo/Marveen/store/.dashboard-token)"
fi

# 🛑 A KUSZOB DONTES, NEM MERT TENY (mint a munka-motor-precheck.sh tobbi kuszobje) -- env-
#    valtozoval felulirhato. Az alapertelmezes a mert esethez igazodik: a delphi-fej a dispatch
#    utan mar dolgozott, amikor a kovetkezo heartbeat (kb. egy perccel kesobb) meg NULL
#    contextTokens-t latott.
FKuszobSec="${AMNEZIA_KUSZOB_SEC:-60}"

curl -s -H "Authorization: Bearer $FTok" http://localhost:3420/api/agents \
| DB="$FDb" KUSZOB_SEC="$FKuszobSec" python3 -c "
import json,sys,sqlite3,os,time
ags=[a for a in json.load(sys.stdin) if a.get('running')]
db=sqlite3.connect(os.environ['DB'])
kuszob=int(os.environ['KUSZOB_SEC'])
most=int(time.time())
rows=dict()
for asg,cnt,ids,ota in db.execute('''
    WITH s AS (
      SELECT k.id, k.assignee,
             COALESCE(
               (SELECT MAX(e.created_at) FROM kanban_card_events e
                WHERE e.card_id = k.id AND e.to_status = k.status),
               k.created_at
             ) AS since
      FROM kanban_cards k
      WHERE k.status IN ('in_progress','testing') AND k.archived_at IS NULL
    )
    SELECT assignee, COUNT(*), GROUP_CONCAT(id,' '), MAX(since)
    FROM s GROUP BY assignee
'''):
    rows[asg]=(cnt,ids,ota)
hit=[]
for a in ags:
    n=a.get('name')
    if n in ('marveen','rendezo'): continue
    if a.get('contextTokens') is None and n in rows:
        cnt,ids,ota=rows[n]
        if most-int(ota)<kuszob:
            continue
        hit.append((n,cnt,ids))
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
