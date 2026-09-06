#!/bin/bash
# hu: VALASZOLATLAN DONTES-KERES -- egy tobb-tetelet felsorolo, {NNNN} sorszamu dontes-kero
#     Telegram-uzenet a legjobban dokumentalt allapotban is elsullyedhet: a hivatkozo kartyan
#     ott all a "Döntés-kérés Józsinak elküldve: {NNNN}" komment, bizonyitva, hogy a kerdes
#     elindult -- es epp ez teszi minden meglevo merot vakka arra, hogy VALASZ NEM JOTT.
#     Merve 2026-09-06: a {3041} negy dontese 2026-09-04 15:32-kor ment ki, azota 65 bejovo
#     uzenet erkezett ugyanabban a chatben, es negy hivatkozo kartya (koztuk a 06b9edae, aminek
#     a javitasa kesz) utolso kommentje meg mindig csak a kikuldes tenye.
#
#     A nulla-komment mero atugorja (VAN komment), a "megvan-e nevezve a blokkolo / bizonyithato-e
#     hogy elindult" kerdesekre mindketto IGEN a valasz, a csatorna-igeret-figyelo pedig a SAJAT
#     igereteket figyeli, nem a RA VARO valaszokat -- ezert kell ez a kulon mero.
#
#     HAROM FELTETEL EGYUTT jelzi a kartyat:
#       (a) a kimeno uzenet dontes-kerest tartalmaz: {NNNN} sorszammal kezdodik, van benne
#           szamozott tetel (pl. "1. ") ES kerdojel;
#       (b) azota a chatben legalabb a kuszob-fajlban allo N bejovo uzenet erkezett;
#       (c) a hivatkozo kartya UTOLSO kommentje meg mindig a "... elkuldve: {NNNN}" jelolo
#           komment -- nincs ujabb bejegyzes utana (az ujabb komment a valasz/haladas nyoma).
#     Mindharom egyszerre kell -- ha barmelyik hianyzik, a kartya nem jelenik meg.
#
#     CSENDES KOR: nulla talalatnal a szkript nem ir semmit. A mero NEM cselekszik -- nem kuld
#     emlekeztetot, nem ismetli meg a kerdest -- csak kiirja, a dontes (emlekezteto a digestbe,
#     ujra-eszkalalas) marveen dolga.
#
# en: SUNK DECISION REQUEST -- a multi-item, {NNNN}-numbered decision-request Telegram message
#     can sink even in the best-documented state: the referencing card carries a "sent: {NNNN}"
#     comment proving the question went out, and that proof is exactly what blinds every
#     existing monitor to the fact that NO ANSWER CAME. All three conditions above must hold
#     together; the tool never acts, it only prints.
#
# Hasznalat / Usage: valaszolatlan-dontes-keres-figyelo.sh
#   Kornyezeti valtozok (tesztekhez / eltero telepiteshez):
#     MARVEEN_DB                  sqlite adatbazis utvonala
#                                  (alap: /Users/ceo/Marveen/store/claudeclaw.db)
#     MARVEEN_DONTES_KUSZOB_FILE  a kuszob-szamot (N) tartalmazo fajl utvonala
#                                  (alap: /Users/ceo/Marveen/store/valaszolatlan-dontes-keres-kuszob.txt)
#     MARVEEN_DONTES_AGENT        melyik agent_id kimeno uzeneteit nezze (alap: marveen)
#
# EXIT: mindig 0 -- ez meres, nem kapu. A hivo a KIMENETBoL dont. (Kiveve DB-olvasasi hiba: 2.)

set -euo pipefail

DB="${MARVEEN_DB:-/Users/ceo/Marveen/store/claudeclaw.db}"
KUSZOB_FILE="${MARVEEN_DONTES_KUSZOB_FILE:-/Users/ceo/Marveen/store/valaszolatlan-dontes-keres-kuszob.txt}"
AGENT="${MARVEEN_DONTES_AGENT:-marveen}"

if [ ! -r "$DB" ]; then
  echo "valaszolatlan-dontes-keres-figyelo: az adatbazis nem olvashato: $DB" >&2
  exit 2
fi

# hu: a kuszob NEM merheto tenyszam, hanem szabaly-donetes -- ha nincs kulon allitva, 10 a
#     beepitett alapertelmezes: a dokumentalt eset 65 bejovo uzenetnel buktatta le a jelzest,
#     10 mar a stagnalas elejen jelezne, jocskan e mogott.
if [ -r "$KUSZOB_FILE" ]; then
  KUSZOB="$(cat "$KUSZOB_FILE")"
else
  KUSZOB=10
fi

python3 -c "
import re, sqlite3, sys

db_path = '$DB'
agent = '$AGENT'
threshold = int('$KUSZOB')

conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row

tag_re = re.compile(r'^\{(\d+)\}')
numbered_re = re.compile(r'(?m)^\s*\d+[.)]\s')

rows = conn.execute('''
    SELECT id, chat_id, text, created_at
    FROM conversation_log
    WHERE direction='out' AND agent_id=? AND text IS NOT NULL
    ORDER BY id ASC
''', (agent,)).fetchall()

candidates = {}
for r in rows:
    text = r['text']
    m = tag_re.match(text.strip())
    if not m:
        continue
    if not numbered_re.search(text):
        continue
    if '?' not in text:
        continue
    nnnn = m.group(1)
    if nnnn not in candidates:
        candidates[nnnn] = (r['chat_id'], r['created_at'])

flagged = []
for nnnn, (chat_id, created_at) in candidates.items():
    incoming = conn.execute('''
        SELECT COUNT(*) FROM conversation_log
        WHERE chat_id=? AND direction='in' AND created_at > ?
    ''', (chat_id, created_at)).fetchone()[0]

    if incoming < threshold:
        continue

    marker_like = '%elküldve: {' + nnnn + '}%'
    comments = conn.execute('''
        SELECT id, card_id FROM kanban_comments WHERE content LIKE ?
    ''', (marker_like,)).fetchall()

    for c in comments:
        card_id = c['card_id']
        max_id = conn.execute(
            'SELECT MAX(id) FROM kanban_comments WHERE card_id=?', (card_id,)
        ).fetchone()[0]
        if max_id != c['id']:
            continue

        card = conn.execute(
            'SELECT title, status FROM kanban_cards WHERE id=?', (card_id,)
        ).fetchone()
        if card is None:
            continue

        flagged.append((nnnn, card_id, card['status'], incoming, card['title']))

if not flagged:
    sys.exit(0)

print('VALASZOLATLAN DONTES-KERES -- kikuldve, dokumentalva, valasz nincs:')
for nnnn, card_id, status, incoming, title in flagged:
    print('  {%s}  %-12s %-12s %3d bejovo uzenet azota -- %s' % (nnnn, card_id, status, incoming, title[:80]))
"
