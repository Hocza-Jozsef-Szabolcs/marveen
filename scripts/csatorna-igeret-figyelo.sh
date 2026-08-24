#!/bin/bash
# hu: Csatornán tett szóbeli ígéretek gépies figyelése (kártya:
#     csatornan-tett-igeret-nincs-nyilvantartva-20260811). Egy ígéret ("szólok, ha
#     megvan") eddig sehol nem került nyilvántartásba -- ez a mechanizmus fogja meg,
#     ha a beszélgetésben tett ígéret elmarad, anélkül hogy bárkinek emlékeznie kellene rá.
#
# Használat:
#   csatorna-igeret-figyelo.sh scan                    -> ígéret-gyanús, MÉG ÁT NEM VIZSGÁLT kimenő üzenetek
#   csatorna-igeret-figyelo.sh review <id> <kimenetel>  -> jelöli átvizsgáltként (kimenetel: kartya_letrehozva|mar_teljesult|nem_igeret)
#   csatorna-igeret-figyelo.sh baseline                 -> a MOST létező sorokat egy csapásra 'baseline'-ként jelöli
#
# A `scan` a conversation_log-ból (direction='out', agent_id='marveen') listázza azokat
# a sorokat, amik ígéret-mintára illeszkednek, ÉS még nincsenek a channel_promise_reviews
# táblában -- vagyis senki nem döntött még róluk. `review` után a sor nem jelenik meg többé.
#
# A `baseline` EGYSZER kell, a mechanizmus bevezetésekor: a conversation_log ekkor már
# hetek/hónapok anyagát tartalmazza, és a promise-minták (szólok/jelzem/megmondom) ezekben
# TÖMEGESEN, hamis pozitívként ütnek (mérve: 1132 kimenő sorból ~30 illeszkedik egyetlen
# gyors mintára is, túlnyomó többségük már rég lezárt ügy). A `baseline` ezt a meglévő
# zajt egy körben elnyeli -- a mechanizmus MOSTANTÓL véd, nem a teljes múltat auditálja.
set -euo pipefail
DB="/Users/ceo/Marveen/store/claudeclaw.db"

sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS channel_promise_reviews (
  conversation_log_id INTEGER PRIMARY KEY,
  reviewed_at INTEGER NOT NULL,
  outcome TEXT NOT NULL
);"

case "${1:-}" in
  scan)
    sqlite3 -separator '|' "$DB" "
      SELECT cl.id, datetime(cl.created_at,'unixepoch','localtime'), substr(cl.text,1,200)
      FROM conversation_log cl
      WHERE cl.direction='out'
        AND cl.agent_id='marveen'
        AND cl.text IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM channel_promise_reviews r WHERE r.conversation_log_id=cl.id)
        AND (
          cl.text LIKE '%szólok%' OR cl.text LIKE '%szolok%' OR
          cl.text LIKE '%jelzem%' OR cl.text LIKE '%jelentkezem%' OR
          cl.text LIKE '%megmondom%' OR cl.text LIKE '%visszajelzek%' OR
          cl.text LIKE '%visszajelentkezem%' OR
          cl.text LIKE '%értesítelek%' OR cl.text LIKE '%ertesitelek%' OR
          cl.text LIKE '%szólni fogok%' OR cl.text LIKE '%szolni fogok%' OR
          cl.text LIKE '%írok, ha%' OR cl.text LIKE '%irok, ha%'
        )
      ORDER BY cl.id ASC;"
    ;;
  review)
    id="${2:?hasznalat: $0 review <conversation_log_id> <kimenetel>}"
    outcome="${3:?hasznalat: $0 review <conversation_log_id> <kimenetel>}"
    sqlite3 "$DB" "INSERT OR REPLACE INTO channel_promise_reviews (conversation_log_id, reviewed_at, outcome) VALUES ($id, strftime('%s','now'), '$outcome');"
    echo "atvizsgalva: $id -> $outcome"
    ;;
  baseline)
    n=$(sqlite3 "$DB" "SELECT COUNT(*) FROM conversation_log WHERE direction='out' AND agent_id='marveen' AND id NOT IN (SELECT conversation_log_id FROM channel_promise_reviews);")
    sqlite3 "$DB" "INSERT OR IGNORE INTO channel_promise_reviews (conversation_log_id, reviewed_at, outcome)
      SELECT id, strftime('%s','now'), 'baseline_2026-08-20' FROM conversation_log
      WHERE direction='out' AND agent_id='marveen';"
    echo "baseline: $n sor jelolve"
    ;;
  *)
    echo "hasznalat: $0 {scan|review <id> <kimenetel>|baseline}" >&2
    exit 1
    ;;
esac
