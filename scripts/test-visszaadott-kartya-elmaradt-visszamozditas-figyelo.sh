#!/usr/bin/env bash
# hu: Bukas-eloallito teszt a visszaadott-kartya-elmaradt-visszamozditas-figyelo.sh-hoz.
#     A mag-logika HAROM egyutt kotelezo feltetel: (1) az utolso kanban_card_events sor
#     in_progress -> waiting, (2) ME kommentelt utana (valasz megvan), (3) van ME -> fej
#     inter-agent uzenet az esemeny utan, aminek a SZOVEGE tartalmazza a kartya hex id-jet
#     (a melle-iras / mas-kartyarol-szolo-uzenet kizarasa).
# en: Failure-producing test suite for visszaadott-kartya-elmaradt-visszamozditas-figyelo.sh.

set -uo pipefail

CDir="$(cd "$(dirname "$0")" && pwd)"
CScript="$CDir/visszaadott-kartya-elmaradt-visszamozditas-figyelo.sh"

FTmp=$(mktemp -d "${TMPDIR:-/tmp}/visszamozditas-figyelo-teszt.XXXXXX")
trap 'rm -rf "$FTmp"' EXIT

FPass=0
FFail=0

check() {
  local nev="$1" vart="$2" kapott="$3"
  if [ "$vart" = "$kapott" ]; then
    echo "  OK    $nev"
    FPass=$((FPass + 1))
  else
    echo "  BUKIK $nev -- vart: [$vart], kapott: [$kapott]"
    FFail=$((FFail + 1))
  fi
}

FDb="$FTmp/claudeclaw.db"

seed() {
  rm -f "$FDb"
  sqlite3 "$FDb" <<'SQL'
CREATE TABLE kanban_cards (id TEXT PRIMARY KEY, title TEXT, status TEXT, assignee TEXT, updated_at INTEGER, archived_at INTEGER);
CREATE TABLE kanban_comments (id INTEGER PRIMARY KEY, card_id TEXT, author TEXT, created_at INTEGER, content TEXT);
CREATE TABLE kanban_card_events (id INTEGER PRIMARY KEY, card_id TEXT, from_status TEXT, to_status TEXT, actor TEXT, created_at INTEGER);
CREATE TABLE agent_messages (id INTEGER PRIMARY KEY, from_agent TEXT, to_agent TEXT, content TEXT, created_at INTEGER);
SQL
}

run() {
  MARVEEN_DB="$FDb" bash "$CScript" "$@"
}

echo "── T1: fej visszaadta, ME valaszolt ES a valaszban hivatkozott uzenetet kuldott -- MEGJELENIK (78520d90 mintaja) ──"
seed
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k1','cim1','waiting','marveen',2000,NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_card_events VALUES (1,'k1','in_progress','waiting',NULL,1000);"
sqlite3 "$FDb" "INSERT INTO kanban_comments (id, card_id, author, created_at) VALUES (1,'k1','javacard',995);"
sqlite3 "$FDb" "INSERT INTO kanban_comments (id, card_id, author, created_at) VALUES (2,'k1','marveen',1050);"
sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (1,'marveen','javacard','A hatokor-dontes fent van a k1-en, lasd az 5530-as kommentet.',1060);"
OUT="$(run marveen)"
check "T1 talalja a k1-et"                   "1" "$(echo "$OUT" | grep -c '^  k1 ')"
check "T1 a fej neve (javacard) all a soron" "1" "$(echo "$OUT" | grep '^  k1 ' | grep -c 'javacard')"

echo "── T2: fej sajat maga zarta waiting-re, ME csak melle irt -- NEM jelenik meg (06b9edae mintaja) ──"
seed
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k2','cim2','waiting','marveen',2200,NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_card_events VALUES (1,'k2','in_progress','waiting',NULL,2000);"
sqlite3 "$FDb" "INSERT INTO kanban_comments (id, card_id, author, created_at) VALUES (1,'k2','avalonia',2000);"
sqlite3 "$FDb" "INSERT INTO kanban_comments (id, card_id, author, created_at) VALUES (2,'k2','marveen',2100);"
sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (1,'marveen','avalonia','semmi koze ehhez a kartyahoz',2105);"
OUT="$(run marveen)"
check "T2 nem talalja a k2-t" "0" "$(echo "$OUT" | grep -c '^  k2 ')"

echo "── T2b: fej sajat maga zarta waiting-re, egy MASIK kartya dispatch-uzenete csak MELLESLEG hivatkozik erre -- NEM jelenik meg (06b9edae/9294 mintaja) ──"
seed
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k2b','cim2b','waiting','marveen',2200,NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_card_events VALUES (1,'k2b','in_progress','waiting',NULL,2000);"
sqlite3 "$FDb" "INSERT INTO kanban_comments (id, card_id, author, created_at) VALUES (1,'k2b','avalonia',2000);"
sqlite3 "$FDb" "INSERT INTO kanban_comments (id, card_id, author, created_at) VALUES (2,'k2b','marveen',2100);"
sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (1,'marveen','avalonia','[Kanban feladat #aa11bb22]: uj kartya, a k2b kartya melleklelete',2105);"
OUT="$(run marveen)"
check "T2b nem talalja a k2b-t" "0" "$(echo "$OUT" | grep -c '^  k2b ')"

echo "── T3: fej visszaadta, ME MEG NEM valaszolt -- NEM jelenik meg (a nalam-all.sh dolga) ──"
seed
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k3','cim3','waiting','marveen',3000,NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_card_events VALUES (1,'k3','in_progress','waiting',NULL,3000);"
sqlite3 "$FDb" "INSERT INTO kanban_comments (id, card_id, author, created_at) VALUES (1,'k3','delphi',3000);"
OUT="$(run marveen)"
check "T3 nem talalja a k3-at" "0" "$(echo "$OUT" | grep -c '^  k3 ')"

echo "── T4: utolso esemeny NEM in_progress->waiting (planned->waiting) -- NEM jelenik meg ──"
seed
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k4','cim4','waiting','marveen',4100,NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_card_events VALUES (1,'k4','planned','waiting',NULL,4000);"
sqlite3 "$FDb" "INSERT INTO kanban_comments (id, card_id, author, created_at) VALUES (1,'k4','ordog',4000);"
sqlite3 "$FDb" "INSERT INTO kanban_comments (id, card_id, author, created_at) VALUES (2,'k4','marveen',4050);"
sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (1,'marveen','ordog','k4-rol van szo, hivatkozva',4060);"
OUT="$(run marveen)"
check "T4 nem talalja a k4-et" "0" "$(echo "$OUT" | grep -c '^  k4 ')"

echo "── T5: a fej nem azonosithato (csak ME kommentelt az esemeny elott) -- NEM jelenik meg ──"
seed
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k5','cim5','waiting','marveen',5100,NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_card_events VALUES (1,'k5','in_progress','waiting',NULL,5000);"
sqlite3 "$FDb" "INSERT INTO kanban_comments (id, card_id, author, created_at) VALUES (1,'k5','marveen',4990);"
sqlite3 "$FDb" "INSERT INTO kanban_comments (id, card_id, author, created_at) VALUES (2,'k5','marveen',5050);"
sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (1,'marveen','akka','k5-rol van szo',5060);"
OUT="$(run marveen)"
check "T5 nem talalja a k5-ot" "0" "$(echo "$OUT" | grep -c '^  k5 ')"

echo "── T6: ME valaszolt, DE nincs egyetlen kimeno uzenet sem a fejnek erre a kartyara hivatkozva -- NEM jelenik meg ──"
seed
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k6','cim6','waiting','marveen',6100,NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_card_events VALUES (1,'k6','in_progress','waiting',NULL,6000);"
sqlite3 "$FDb" "INSERT INTO kanban_comments (id, card_id, author, created_at) VALUES (1,'k6','sejt',5995);"
sqlite3 "$FDb" "INSERT INTO kanban_comments (id, card_id, author, created_at) VALUES (2,'k6','marveen',6050);"
OUT="$(run marveen)"
check "T6 nem talalja a k6-ot" "0" "$(echo "$OUT" | grep -c '^  k6 ')"

echo "── T7: mas ME-re (delphi) futtatva a marveen-neven-allo kartya nem jelenik meg ──"
seed
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k1','cim1','waiting','marveen',2000,NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_card_events VALUES (1,'k1','in_progress','waiting',NULL,1000);"
sqlite3 "$FDb" "INSERT INTO kanban_comments (id, card_id, author, created_at) VALUES (1,'k1','javacard',995);"
sqlite3 "$FDb" "INSERT INTO kanban_comments (id, card_id, author, created_at) VALUES (2,'k1','marveen',1050);"
sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (1,'marveen','javacard','k1-rol van szo',1060);"
OUT="$(run delphi)"
check "T7 delphi nezopontbol ures kimenet" "" "$OUT"

echo "── T8: pozitiv kontroll -- ures adatbazis, teljesen ures kimenet, exit 0 ──"
seed
OUT="$(run marveen)"
FRc=$?
check "T8 ures adatbazis -> ures kimenet" "" "$OUT"
check "T8 exit kod 0" "0" "$FRc"

echo "── T9: a szkript nem kuld uzenetet, csak olvas es kiir ──"
if grep -qiE 'curl|reply_to|api/messages|mcp__.*reply' "$CScript"; then
  echo "  BUKIK a szkript forrasa halozati/kuldo hivast tartalmaz"
  FFail=$((FFail + 1))
else
  echo "  OK    nincs kuldo/halozati hivas a forrasban"
  FPass=$((FPass + 1))
fi

# ---------------------------------------------------------------------------
# T10 -- MERT TENY (2026-09-06, kartya ee8119ee): a haromfeltetelesen a nyolcbol nyolc
#        talalat HAMIS POZITIV volt -- mindegyik olyan `waiting` kartya, ahol a ME-valasz
#        NEM a fejet oldja fel, hanem egy KULSo felre (Jozsi, Zoli, eszkoz) forditja tovabb
#        a dontest, es a valodi blokkolo tovabbra is all. KET jelolt mechanikus megkulon-
#        bozteto merve (ugyanezen a nyolc kartyan): a valaszolatlan-dontes-keres-figyelo.sh
#        kimenetevel valo atfedes (0/8 -- egyik kartya sem szerepel ott, mert az csak a
#        Jozsi-nak szolo, {NNNN}-cimkes ES "elkuldve: {NNNN}" kommenttel dokumentalt esetet
#        fedi), es a nyers `{NNNN}` Telegram-sorszam jelenlete a ME-valaszban barhol (4/8 --
#        az eszkozre, digestbe sorolasra vagy sajat dontesre hivatkozo valaszokban nincs
#        ilyen szam). EGYIK JELOLT SEM ERI EL A NYOLCBOL NYOLCAT, tehat SZURES NEM VEZETHETo
#        BE -- a valasztott ut DUSITAS: minden sor mellett megjelenik az utolso ME-valasz
#        elso kb. 150 karaktere, hogy egy hamis pozitiv egy sor olvasasaval eldontheto legyen,
#        kartya-lekerdezes nelkul. A nyolc kartya itt a ma mert nyolc alakjat kovetve, egy
#        futasban egyutt szerepel (ahogy elesben is egyutt jelentek meg).
# ---------------------------------------------------------------------------
echo "── T10: a mai nyolc hamis-pozitiv alaku kartya -- minden sor tartalmazza az utolso ME-valasz reszletet ──"
seed
FCid="(id, card_id, author, created_at, content)"

sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k10','cim10','waiting','marveen',10200,NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_card_events VALUES (101,'k10','in_progress','waiting',NULL,10000);"
sqlite3 "$FDb" "INSERT INTO kanban_comments $FCid VALUES (101,'k10','avalonia',9995,'Kesz, tesztelve.');"
sqlite3 "$FDb" "INSERT INTO kanban_comments $FCid VALUES (102,'k10','marveen',10050,'Atveve, mar targyaltuk inter-agent uzenetben. Tovabbra is eszkozos igazolasra var.');"
sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (101,'marveen','avalonia','k10-rol van szo, eszkozre var',10060);"

sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k11','cim11','waiting','marveen',11200,NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_card_events VALUES (111,'k11','in_progress','waiting',NULL,11000);"
sqlite3 "$FDb" "INSERT INTO kanban_comments $FCid VALUES (111,'k11','delphi',10995,'Kesz, tesztelve.');"
sqlite3 "$FDb" "INSERT INTO kanban_comments $FCid VALUES (112,'k11','marveen',11050,'Tetel-visszakerdezes kiment Zolinak, FenySoft csoport, valaszara var.');"
sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (111,'marveen','delphi','k11-rol van szo, Zolira var',11060);"

sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k12','cim12','waiting','marveen',12200,NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_card_events VALUES (121,'k12','in_progress','waiting',NULL,12000);"
sqlite3 "$FDb" "INSERT INTO kanban_comments $FCid VALUES (121,'k12','design',11995,'Kesz, tesztelve.');"
sqlite3 "$FDb" "INSERT INTO kanban_comments $FCid VALUES (122,'k12','marveen',12050,'A pont Jozsinak elkuldve Telegramon, valaszra var.');"
sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (121,'marveen','design','k12-rol van szo, Jozsira var',12060);"

sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k13','cim13','waiting','marveen',13200,NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_card_events VALUES (131,'k13','in_progress','waiting',NULL,13000);"
sqlite3 "$FDb" "INSERT INTO kanban_comments $FCid VALUES (131,'k13','lms',12995,'Kesz, tesztelve.');"
sqlite3 "$FDb" "INSERT INTO kanban_comments $FCid VALUES (132,'k13','marveen',13050,'Atveve. A kerdes sorba allitva Jozsi fele digestbe, most mas temaban dolgozom.');"
sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (131,'marveen','lms','k13-rol van szo, digestbe sorolva',13060);"

sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k14','cim14','waiting','marveen',14200,NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_card_events VALUES (141,'k14','in_progress','waiting',NULL,14000);"
sqlite3 "$FDb" "INSERT INTO kanban_comments $FCid VALUES (141,'k14','lms',13995,'Kesz, tesztelve.');"
sqlite3 "$FDb" "INSERT INTO kanban_comments $FCid VALUES (142,'k14','marveen',14050,'A blokkolo elindult, Telegramon kiment Jozsinak, a valasz meg nem erkezett.');"
sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (141,'marveen','lms','k14 blokkoloja elindult Jozsi fele',14060);"

sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k15','cim15','waiting','marveen',15200,NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_card_events VALUES (151,'k15','in_progress','waiting',NULL,15000);"
sqlite3 "$FDb" "INSERT INTO kanban_comments $FCid VALUES (151,'k15','delphi',14995,'Kesz, tesztelve.');"
sqlite3 "$FDb" "INSERT INTO kanban_comments $FCid VALUES (152,'k15','marveen',15050,'A terv kesz, kiment Jozsinak. Waiting marad.');"
sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (151,'marveen','delphi','k15-rol van szo, terv Jozsinak',15060);"

sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k16','cim16','waiting','marveen',16200,NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_card_events VALUES (161,'k16','in_progress','waiting',NULL,16000);"
sqlite3 "$FDb" "INSERT INTO kanban_comments $FCid VALUES (161,'k16','javacard',15995,'Kesz, tesztelve.');"
sqlite3 "$FDb" "INSERT INTO kanban_comments $FCid VALUES (162,'k16','marveen',16050,'A blokkolo elindult, Telegramon ot tetel Jozsinak.');"
sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (161,'marveen','javacard','k16-rol van szo, tetelek Jozsinak',16060);"

sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k17','cim17','waiting','marveen',17200,NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_card_events VALUES (171,'k17','in_progress','waiting',NULL,17000);"
sqlite3 "$FDb" "INSERT INTO kanban_comments $FCid VALUES (171,'k17','backend',16995,'Kesz, tesztelve.');"
sqlite3 "$FDb" "INSERT INTO kanban_comments $FCid VALUES (172,'k17','marveen',17050,'A meresed megcafolta a kartya sajat feltetelezeset. A dontesem: most nem valtunk.');"
sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (171,'marveen','backend','k17-rol van szo, sajat dontes',17060);"

OUT="$(run marveen)"
check "T10 mind a nyolc kartyat megtalalja"           "8" "$(echo "$OUT" | grep -cE '^  k1[0-7] ')"
check "T10 k10 sora tartalmazza az eszkoz-varast"     "1" "$(echo "$OUT" | grep '^  k10 ' | grep -c 'eszkozos igazolasra')"
check "T10 k11 sora tartalmazza a Zoli-hivatkozast"   "1" "$(echo "$OUT" | grep '^  k11 ' | grep -c 'Zolinak')"
check "T10 k12 sora tartalmazza a Jozsi-Telegramot"   "1" "$(echo "$OUT" | grep '^  k12 ' | grep -c 'Jozsinak elkuldve Telegramon')"
check "T10 k13 sora tartalmazza a digest-hivatkozast" "1" "$(echo "$OUT" | grep '^  k13 ' | grep -c 'digestbe')"
check "T10 k14 sora tartalmazza a valasz-hianyat"     "1" "$(echo "$OUT" | grep '^  k14 ' | grep -c 'meg nem erkezett')"
check "T10 k15 sora tartalmazza a Waiting marad zarast" "1" "$(echo "$OUT" | grep '^  k15 ' | grep -c 'Waiting marad')"
check "T10 k16 sora tartalmazza az ot tetelt"         "1" "$(echo "$OUT" | grep '^  k16 ' | grep -c 'ot tetel Jozsinak')"
check "T10 k17 sora tartalmazza a sajat-dontest"      "1" "$(echo "$OUT" | grep '^  k17 ' | grep -c 'most nem valtunk')"

# ---------------------------------------------------------------------------
# EL1 -- ELO ADATON valo ellenorzes: a claudeclaw.db egy MASOLATAN (sose az elesen)
#        futtatva a szkriptnek a DOKUMENTALT hamis pozitivot (06b9edae) NEM szabad
#        talalnia, HA az meg mindig 'waiting'+'marveen' allapotban all ott.
# ---------------------------------------------------------------------------
FElesDb="/Users/ceo/Marveen/store/claudeclaw.db"
if [ -r "$FElesDb" ]; then
  echo "── EL1: elo adat masolatan a dokumentalt hamis pozitiv (06b9edae) nem jelenik meg ──"
  FElesMasolat="$FTmp/eles-masolat.db"
  cp "$FElesDb" "$FElesMasolat"
  FElesAllapot=$(sqlite3 "$FElesMasolat" "SELECT status||'|'||assignee FROM kanban_cards WHERE id='06b9edae';")
  if [ "$FElesAllapot" = "waiting|marveen" ]; then
    FElesOut=$(MARVEEN_DB="$FElesMasolat" bash "$CScript" marveen)
    check "EL1 06b9edae nem szerepel az elo-adat futtatasban" "0" "$(echo "$FElesOut" | grep -c '^  06b9edae ')"
  else
    echo "  KIHAGYVA -- 06b9edae mar nem waiting/marveen az elo adatban (kozben lezarult), a mert allapot elavult"
  fi
else
  echo "── EL1 kihagyva -- elo adatbazis nem olvashato ebbol a sessionbol ──"
fi

# ---------------------------------------------------------------------------
# M1 -- BUKAS-ELOALLITAS: a (3) feltetel (hivatkozo uzenet) kivetele egy MASOLATBAN --
#       az ervenyes_hivatkozas() hivas mindig True-t ad. Elvarjuk, hogy T3 (ME meg nem
#       valaszolt -- de a mutalt valtozatban a (3) feltetel mar nem szuri semmire, csak
#       ez az egy feltetel maradna) NE valtozzon (nincs komment), viszont egy uj, csak
#       (2)-t teljesito eset MEGJELENJEN, ami baseline-on (3) miatt bukna.
# ---------------------------------------------------------------------------
echo "M1 -- a (3) feltetel (hivatkozo uzenet) eltavolitasa utan a csak-melle-irt T2-nek MEG KELL jelennie"
FMut="$FTmp/figyelo.mutalt.sh"
cp "$CScript" "$FMut"
python3 - "$FMut" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "    if not any(ervenyes_hivatkozas(u['content'], card_id) for u in uzenetek):\n        continue\n"
n = s.count(old)
assert n == 1, "A MUTACIO NEM ALKALMAZHATO: a minta %d-szer illeszkedik" % n
open(p, 'w').write(s.replace(old, ""))
PYEOF

if diff -q "$CScript" "$FMut" >/dev/null 2>&1; then
  echo "  BUKIK a mutacio nem valtoztatta a fajlt"
  FFail=$((FFail + 1))
else
  echo "  OK    a mutacio tenyleg megvaltoztatta a szkriptet (hash-kulonbseg)"
  FPass=$((FPass + 1))
  seed
  sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k2','cim2','waiting','marveen',2200,NULL);"
  sqlite3 "$FDb" "INSERT INTO kanban_card_events VALUES (1,'k2','in_progress','waiting',NULL,2000);"
  sqlite3 "$FDb" "INSERT INTO kanban_comments (id, card_id, author, created_at) VALUES (1,'k2','avalonia',2000);"
  sqlite3 "$FDb" "INSERT INTO kanban_comments (id, card_id, author, created_at) VALUES (2,'k2','marveen',2100);"
  sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (1,'marveen','avalonia','semmi koze ehhez a kartyahoz',2105);"
  FOutMut=$(MARVEEN_DB="$FDb" bash "$FMut" marveen)
  check "M1 mutalt szkript: k2 MOST mar megjelenik" "1" "$(echo "$FOutMut" | grep -c '^  k2 ')"
fi

# ---------------------------------------------------------------------------
# M3 -- BUKAS-ELOALLITAS: a (3b) dispatch-elotag-kizaras eltavolitasa az
#       ervenyes_hivatkozas()-bol (csak a puszta tartalom-egyezes marad). Elvarjuk, hogy
#       T2b (masik kartya dispatch-uzenete, ami csak melleklelet-kent hivatkozik) EZUTAN
#       megjelenjen -- ez igazolja, hogy a baseline futasban valoban a (3b) zarta ki.
# ---------------------------------------------------------------------------
echo "M3 -- a (3b) dispatch-elotag-kizaras eltavolitasa utan T2b-nek MEG KELL jelennie"
FMut3="$FTmp/figyelo.mutalt3.sh"
cp "$CScript" "$FMut3"
python3 - "$FMut3" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "    m = dispatch_re.match(content or '')\n    if m and m.group(1).lower() != card_id.lower():\n        # masik kartya dispatch-uzenete, ami csak melleklelet-kent hivatkozik a mienkre\n        return False\n"
n = s.count(old)
assert n == 1, "A MUTACIO NEM ALKALMAZHATO: a minta %d-szer illeszkedik" % n
open(p, 'w').write(s.replace(old, ""))
PYEOF

if diff -q "$CScript" "$FMut3" >/dev/null 2>&1; then
  echo "  BUKIK a mutacio nem valtoztatta a fajlt"
  FFail=$((FFail + 1))
else
  echo "  OK    a mutacio tenyleg megvaltoztatta a szkriptet (hash-kulonbseg)"
  FPass=$((FPass + 1))
  seed
  sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k2b','cim2b','waiting','marveen',2200,NULL);"
  sqlite3 "$FDb" "INSERT INTO kanban_card_events VALUES (1,'k2b','in_progress','waiting',NULL,2000);"
  sqlite3 "$FDb" "INSERT INTO kanban_comments (id, card_id, author, created_at) VALUES (1,'k2b','avalonia',2000);"
  sqlite3 "$FDb" "INSERT INTO kanban_comments (id, card_id, author, created_at) VALUES (2,'k2b','marveen',2100);"
  sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (1,'marveen','avalonia','[Kanban feladat #aa11bb22]: uj kartya, a k2b kartya melleklelete',2105);"
  FOutMut3=$(MARVEEN_DB="$FDb" bash "$FMut3" marveen)
  check "M3 mutalt szkript: k2b MOST mar megjelenik" "1" "$(echo "$FOutMut3" | grep -c '^  k2b ')"
fi

# ---------------------------------------------------------------------------
# M2 -- BUKAS-ELOALLITAS: a from_status='in_progress' feltetel kivetele. Elvarjuk, hogy
#       T4 (planned -> waiting) EZUTAN megjelenjen.
# ---------------------------------------------------------------------------
echo "M2 -- az from_status=='in_progress' feltetel eltavolitasa utan T4-nek MEG KELL jelennie"
FMut2="$FTmp/figyelo.mutalt2.sh"
cp "$CScript" "$FMut2"
python3 - "$FMut2" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "if ev['to_status'] != 'waiting' or ev['from_status'] != 'in_progress':"
n = s.count(old)
assert n == 1, "A MUTACIO NEM ALKALMAZHATO: a minta %d-szer illeszkedik" % n
new = "if ev['to_status'] != 'waiting':"
open(p, 'w').write(s.replace(old, new))
PYEOF

if diff -q "$CScript" "$FMut2" >/dev/null 2>&1; then
  echo "  BUKIK a mutacio nem valtoztatta a fajlt"
  FFail=$((FFail + 1))
else
  echo "  OK    a mutacio tenyleg megvaltoztatta a szkriptet (hash-kulonbseg)"
  FPass=$((FPass + 1))
  seed
  sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k4','cim4','waiting','marveen',4100,NULL);"
  sqlite3 "$FDb" "INSERT INTO kanban_card_events VALUES (1,'k4','planned','waiting',NULL,4000);"
  sqlite3 "$FDb" "INSERT INTO kanban_comments (id, card_id, author, created_at) VALUES (1,'k4','ordog',4000);"
  sqlite3 "$FDb" "INSERT INTO kanban_comments (id, card_id, author, created_at) VALUES (2,'k4','marveen',4050);"
  sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (1,'marveen','ordog','k4-rol van szo',4060);"
  FOutMut2=$(MARVEEN_DB="$FDb" bash "$FMut2" marveen)
  check "M2 mutalt szkript: k4 MOST mar megjelenik" "1" "$(echo "$FOutMut2" | grep -c '^  k4 ')"
fi

# ---------------------------------------------------------------------------
# M4 -- BUKAS-ELOALLITAS: az utolso-ME-valasz reszlet kiirasanak (dusitas) eltavolitasa.
#       Elvarjuk, hogy T10 k10 sora EZUTAN NE tartalmazza tobbe az eszkoz-varas szoveget --
#       ez igazolja, hogy a T10 ellenorzesek tenyleg a dusitast merik, nem valami mellekes
#       formazast.
# ---------------------------------------------------------------------------
echo "M4 -- az utolso-ME-valasz reszlet kiirasanak eltavolitasa utan a T10 dusitas-ellenorzesnek BUKNIA KELL"
FMut4="$FTmp/figyelo.mutalt4.sh"
cp "$CScript" "$FMut4"
python3 - "$FMut4" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "print('  %-12s %-10s %5d perc a visszaadas ota -- %s -- utolso valasz: %s' % (card_id, fej, perc, title[:80], reszlet))"
n = s.count(old)
assert n == 1, "A MUTACIO NEM ALKALMAZHATO: a minta %d-szer illeszkedik" % n
new = "print('  %-12s %-10s %5d perc a visszaadas ota -- %s' % (card_id, fej, perc, title[:80]))"
open(p, 'w').write(s.replace(old, new))
PYEOF

if diff -q "$CScript" "$FMut4" >/dev/null 2>&1; then
  echo "  BUKIK a mutacio nem valtoztatta a fajlt"
  FFail=$((FFail + 1))
else
  echo "  OK    a mutacio tenyleg megvaltoztatta a szkriptet (hash-kulonbseg)"
  FPass=$((FPass + 1))
  seed
  sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('k10','cim10','waiting','marveen',10200,NULL);"
  sqlite3 "$FDb" "INSERT INTO kanban_card_events VALUES (101,'k10','in_progress','waiting',NULL,10000);"
  sqlite3 "$FDb" "INSERT INTO kanban_comments $FCid VALUES (101,'k10','avalonia',9995,'Kesz, tesztelve.');"
  sqlite3 "$FDb" "INSERT INTO kanban_comments $FCid VALUES (102,'k10','marveen',10050,'Atveve, mar targyaltuk inter-agent uzenetben. Tovabbra is eszkozos igazolasra var.');"
  sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (101,'marveen','avalonia','k10-rol van szo, eszkozre var',10060);"
  FOutMut4=$(MARVEEN_DB="$FDb" bash "$FMut4" marveen)
  check "M4 mutalt szkript: k10 sora MAR NEM tartalmazza az eszkoz-varast" "0" "$(echo "$FOutMut4" | grep '^  k10 ' | grep -c 'eszkozos igazolasra')"
fi

echo "---"
echo "Osszesen: $FPass OK, $FFail BUKIK"
[ "$FFail" -eq 0 ]
