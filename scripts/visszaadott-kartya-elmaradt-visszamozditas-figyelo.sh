#!/bin/bash
# hu: VISSZAADOTT KARTYA, VALASZ MEGVAN, A STATUSZ-VISSZAMOZDITAS ELMARADT -- kiegeszito
#     mero a nalam-all.sh melle, ANNAK PONTOS VAKFOLTJARA.
#
#     A nalam-all.sh azokat a `waiting` kartyakat mutatja, ahol az UTOLSO KOMMENT szerzoje
#     NEM ME (`marveen`) -- vagyis meg nem valaszoltam. Ez a szkript a MASIK oldalt nezi:
#     olyan `waiting` kartyat, amit egy fej `in_progress` -> `waiting` lepessel adott vissza,
#     ES amire ME MAR VALASZOLTAM kommenttel -- de a statuszt elfelejtettem `in_progress`-re
#     visszatenni. EZ A HALMAZ A NALAM-ALL.SH-BOL SZERKEZETILEG HIANYZIK: amint valaszolok,
#     a sajat kommentem lesz az utolso, es a sor kiesik onnan -- pontosan az esetben, amikor
#     a legfontosabb lenne latni.
#
#     MERT TENY (2026-09-06 07:27:54-07:45:57, `78520d90`): a `javacard` visszaadta a kartyat
#     egy hatokor-kerdessel (`in_progress` -> `waiting`, 07:27:54, komment #5528). A valasz
#     megerkezett kommentben (07:33:34, #5530) ES inter-agent uzenetben (10304, 07:34:01) --
#     de a statusz csak 07:45:57-kor mozdult vissza, KOZBEN a `lms` mar tovabb is kommentelt
#     (07:40:24, #5534). Hat percen at a kartya `waiting`+`assignee=marveen` allapotban allt
#     annak ellenere, hogy a fej mar dolgozhatott volna -- es a `fej-idle-dispatch.sh` ebben
#     az allapotban ugy latja, a fejnek NINCS nyitott kartyaja.
#
#     A HAROMFELTETELES SZURES ES AZ OKA:
#       (1) a kartya utolso `kanban_card_events` sora `in_progress` -> `waiting`, ES
#           azota van legalabb egy ME-szerzoju komment -- ez maga a "valasz megvan, statusz
#           nem mozdult" allapot.
#       (2) a fejet (aki visszaadta) a legutolso, az esemenynel NEM kesobbi, NEM ME-szerzoju
#           kommentbol azonositjuk -- az esemeny `actor` mezeje URES marad, ha a fej
#           kozvetlenul az API-t hivta (nem a kartya-kiosztas.sh-n at), lasd a
#           `kanban_cards_status_audit` trigger definicioja (src/db.ts): a triggernek
#           nincs kulon "ki hivta" bemenete, csak a `kanban_audit_actor_ctx` context-tabla,
#           amit a fejek kozvetlen `/move` hivasa nem tolt ki.
#
#     🛑 HAMIS POZITIV, AMIT KI KELL ZARNI (ELO PELDA, `06b9edae`, MERVE 2026-09-06): a `waiting`
#     TOVABBRA IS HELYES, ha a ME-komment nem VALASZ, hanem MELLE IRAS (pl. egy nyugtazas,
#     mig a valodi blokkolo mashol -- itt Jozsi -- all). A `06b9edae`-n az `avalonia` sajat
#     maga zarta `waiting`-re a kartyat ("csak Jozsi elo visszaigazolasa van hatra"), ME csak
#     nyugtaztam ("Atveve, vilagos").
#
#     🛑 MERT CAFOLAT AZ IDoABLAK-HEURISZTIKARA: az elso valtozat azt nezte, hogy a ME-valasz-
#     komment koruli N masodperces ablakban ment-e BARMILYEN ME->fej uzenet. Az ELES adaton
#     lefuttatva (2026-09-06) ez 19 talalatot adott 300 mp-es ablakkal, KOZTUK a `06b9edae`-t --
#     mert ME es `avalonia` kozott percenkent megy uzenet (napi tobb tucat, teljesen MAS
#     kartyakrol), es a ME-valasz-komment (16:16:54) 50 masodpercre esett egy MASIK kartyarol
#     (#8e78d004) szolo uzenettol (9294, 16:15:36-16:16:04). Az idobeli kozelseg oncelu jel,
#     ha a fej naponta tobb tucat uzenetet kap.
#
#     🛑 ES A PUSZTA TARTALOM-EGYEZES SEM ELEG ONMAGABAN: a fenti 9294-es uzenet SZO SZERINT
#     tartalmazza a "06b9edae" hex-azonositot is ("avalonia, 06b9edae kartya melleklelete,
#     2026-09-01"), MERT egy UJ, MASIK kartyat (#8e78d004) ad ki, aminek a leirasa a
#     06b9edae-t mint ELoZMENYT emliti -- ez tartalom-egyezessel is hamis pozitiv maradna.
#     A megkulonbozteto jel: az uzenet a `[Kanban feladat #<hash>]:` dispatch-elotaggal
#     kezdodik, es az a hash MASIK kartyara mutat -- vagyis az uzenet ELSoDLEGES targya nem
#     ez a kartya, csak MELLESLEG hivatkozik ra. EZERT A HARMADIK FELTETEL KET RESZBoL ALL:
#       (3a) letezik ME->fej inter-agent uzenet az esemeny UTAN, aminek a SZOVEGE tartalmazza
#            EZT a kartya-azonositot (8 hex karakteres `id`), ES
#       (3b) az uzenet NEM egy MASIK kartyara szolo `[Kanban feladat #<mashash>]:` dispatch --
#            ha az, a hivatkozas melleklelet, nem valasz.
#     A `78520d90`-re szolo 10304-es uzenet NEM dispatch-elotaggal kezdodik (szabad szoveg),
#     tehat (3b) nem zarja ki; a `06b9edae`-re "hivatkozo" 9294-es uzenet `[Kanban feladat
#     #8e78d004]:`-vel kezdodik -- MAS hash -- tehat (3b) kizarja.
#
#     ISMERT MELLEKHATAS: ha egy fej a kartyara valo hivatkozast KIZAROLAG a human-facing
#     `#<seq>` alakban kapja (nem a hex `id`-vel), ez a feltetel hamis negativot ad -- a
#     mert flotta-konvencio szerint (CLAUDE.md) az API-hivasok es a legtobb prozai hivatkozas
#     is a hex `id`-t hasznalja, de garancia nincs ra. Ez a mero JELZES, nem KAPU -- a
#     talalatot at kell olvasni, nem automatikusan cselekedni ra; hamis negativ eseten a
#     `nalam-all.sh` (ami a "meg valaszolatlan" oldalt fedi) es a kezi kartya-atolvasas marad
#     a halo.
#
#     HOVA TARTOZIK A MUNKA-MOTOR KORBEN: KOZVETLENUL a nalam-all.sh UTAN, ugyanabban a
#     korben, ugyanazon okbol -- a ket szkript egyutt fedi a `waiting`+`assignee=marveen`
#     kartyak MINDKET oldalat (nalam-all.sh: meg nem valaszoltam; ez a szkript: valaszoltam,
#     de a statuszt nem mozditottam).
#
# en: RETURNED CARD, ANSWER GIVEN, STATUS MOVE-BACK MISSING -- companion to nalam-all.sh,
#     covering exactly its blind spot: cards where a fej handed a card back with a question
#     (in_progress -> waiting) and the answer has already been given as a ME-authored
#     comment, but the status was never moved back to in_progress. This set is structurally
#     invisible to nalam-all.sh, because that script filters on "last comment author is NOT
#     ME" -- the moment ME answers, the card drops off that list. The third condition matches
#     on message CONTENT (the card's hex id appearing in an outgoing message), not on time
#     proximity -- a live-data run disproved the time-window version (19 false positives,
#     including the documented false-positive card, because busy agent pairs exchange
#     messages every few minutes about unrelated cards).
#
# Hasznalat / Usage: visszaadott-kartya-elmaradt-visszamozditas-figyelo.sh [ME]
#   ME alapertelmezese: marveen.
#   Kornyezeti valtozok (tesztekhez / eltero telepiteshez):
#     MARVEEN_DB   sqlite adatbazis utvonala (alap: /Users/ceo/Marveen/store/claudeclaw.db)
#
# EXIT: mindig 0 -- ez meres, nem kapu (kiveve DB-olvasasi hiba: 2). Nulla talalatnal a
#       szkript NEM ir semmit (csendes kor, mint a valaszolatlan-dontes-keres-figyelo.sh).

set -uo pipefail

DB="${MARVEEN_DB:-/Users/ceo/Marveen/store/claudeclaw.db}"
ME="${1:-marveen}"

if [ ! -r "$DB" ]; then
  echo "visszaadott-kartya-elmaradt-visszamozditas-figyelo: az adatbazis nem olvashato: $DB" >&2
  exit 2
fi

python3 -c "
import re, sqlite3, sys

db_path = '$DB'
me = '$ME'
dispatch_re = re.compile(r'^\[Kanban feladat #([0-9a-fA-F-]{6,})\]')

def ervenyes_hivatkozas(content, card_id):
    if card_id.lower() not in (content or '').lower():
        return False
    m = dispatch_re.match(content or '')
    if m and m.group(1).lower() != card_id.lower():
        # masik kartya dispatch-uzenete, ami csak melleklelet-kent hivatkozik a mienkre
        return False
    return True

conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row

cards = conn.execute('''
    SELECT id, title FROM kanban_cards
    WHERE status='waiting' AND assignee=? AND archived_at IS NULL
''', (me,)).fetchall()

flagged = []
for card in cards:
    card_id = card['id']

    ev = conn.execute('''
        SELECT from_status, to_status, created_at FROM kanban_card_events
        WHERE card_id=? ORDER BY created_at DESC, id DESC LIMIT 1
    ''', (card_id,)).fetchone()
    if ev is None:
        continue
    if ev['to_status'] != 'waiting' or ev['from_status'] != 'in_progress':
        continue
    ev_ts = ev['created_at']

    fej_row = conn.execute('''
        SELECT author FROM kanban_comments
        WHERE card_id=? AND author != ? AND created_at <= ?
        ORDER BY created_at DESC LIMIT 1
    ''', (card_id, me, ev_ts)).fetchone()
    if fej_row is None:
        continue
    fej = fej_row['author']

    valaszolt = conn.execute('''
        SELECT 1 FROM kanban_comments
        WHERE card_id=? AND author=? AND created_at > ?
        LIMIT 1
    ''', (card_id, me, ev_ts)).fetchone()
    if valaszolt is None:
        continue

    uzenetek = conn.execute('''
        SELECT content FROM agent_messages
        WHERE from_agent=? AND to_agent=? AND created_at > ?
    ''', (me, fej, ev_ts)).fetchall()
    if not any(ervenyes_hivatkozas(u['content'], card_id) for u in uzenetek):
        continue

    flagged.append((card_id, fej, ev_ts, card['title']))

if not flagged:
    sys.exit(0)

now = conn.execute(\"SELECT CAST(strftime('%s','now') AS INTEGER)\").fetchone()[0]
print('VISSZAADOTT KARTYA, VALASZ MEGVAN, A STATUSZ-VISSZAMOZDITAS ELMARADT (%s neven):' % me)
for card_id, fej, ev_ts, title in flagged:
    perc = round((now - ev_ts) / 60.0)
    print('  %-12s %-10s %5d perc a visszaadas ota -- %s' % (card_id, fej, perc, title[:80]))
"
