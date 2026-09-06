#!/usr/bin/env bash
# Fej-aktivitas pillanatkep -- a MUNKA-MOTOR hianyzo emlekezete.
#
# Kimenet: soronkent egy fej,
#   `<nev> <contextTokens> <in_progress+testing kartyak szama> <ures-prompt 0/1> <statuszok> <utolso_komment_epoch>`,
#          ES a KULONBSEG az elozo korhoz kepest a STDERR-re, emberi alakban.
#          A "ALL:" sorok azok a fejek, akiket meg kell nezni.
#
# 🛑 AZ "ALL:" NEM JELENT AUTOMATIKUSAN BEAKADAST, HA A NYITOTT KARTYAN AZ ELOZO MERES OTA
#   FRISS KOMMENT ERKEZETT -- ez SZANDEKOSAN leallitott fejre utal (gazda leallitotta, a fej
#   dontesre var), nem beakadasra. Ilyenkor a sor "var:"-tal indul, NEM "ALL:"-lal. A kulonbseg
#   a nyitott kartya(k) legfrissebb kommentjenek EPOCH-ja es a JELENLEGI ctx-PLATO KEZDETENEK
#   (a store 7. mezoje, "valtozatlan_ota") osszevetese -- STRUKTURALT jel (idobelyeg), nem
#   szoveg-egyezes a komment tartalmara (merve 2026-08-14:
#   activity-snapshot-hamis-pozitiv-szandekos-leallas-20260814).
#
# 🛑 A REFERENCIAPONT NEM A SNAPSHOT-FAJL MTIME-JA -- az egy KORABBI valtozat volt, es CSAK
#   az ELSO osszehasonlitasnal helyes: a store MINDEN futtataskor felulirodik, a mtime tehat
#   MINDEN korben elorecsuszik, mikozben a komment epoch-ja fix marad. A MASODIK (es minden
#   tovabbi) kortol a valtozatlan komment mar "reginek" szamitott volna a friss mtime-hoz
#   kepest, es a mero visszavaltott ALL:-ra egy TARTOSAN, szandekosan allo fejre -- ugyanaz a
#   hibaosztaly, amiert ez a kartya szuletett, csak egy korrel elhalasztva (merve 2026-09-06).
#   A "valtozatlan_ota" AKKOR es CSAK AKKOR ugrik MOST-ra, ha a ctx TENYLEGESEN valtozott az
#   elozo korhoz kepest -- kulonben oroklodik, tehat tetszoleges szamu korig stabil marad.
#
# 🛑 A "form:" SOROK NEM "uj"-kent kezelt fejek -- az ELOZO snapshot-fajlban a soruk MAR
#   letezett, de NEM hatmezos (a store formatumot valtott azota, hogy a sor irodott). Ha ezt
#   csendben "uj: nincs elozo meres"-kent kezelnenk, MINDEN fej ALL:/var: dontese elmaradna
#   ugyanabban a korben, es a kimenet egy legitim elso futastol lathatatlanul kulonbozne
#   (merve 2026-08-24: az `activity-snapshot-hamis-pozitiv-szandekos-leallas-20260814` kartya
#   fuggetlen atmeresenel, ordog).
#
# MIERT LETEZIK (merve 2026-08-14 00:2x):
#   Az `akka` a cleartext-jelentese vegen kiirta, hogy "Visszaallok a 0ab6e3d2-re" -- es a kor
#   OTT VEGET ERT. NEGYVEN PERCIG allt ures prompton, 202 030 tokennel VALTOZATLANUL, mikozben a
#   tablan a kartyaja `in_progress` volt.
#   EGYIK MEGLEVo DETEKTOR SEM FOGTA MEG:
#     * pending-sor kora        -> ures sor (senki nem irt neki)
#     * pane-szelesseg / footer -> a footer teljes volt
#     * friss-ablak jel         -> a contextTokens 202k, NEM None
#     * nulla-komment `waiting` -> a kartya `in_progress`, es van rajta komment
#   AZ EGYETLEN JEL: a contextTokens KET MERES KOZOTT valtozatlan + ures prompt + nyitott kartya.
#   Es epp ehhez hianyzott az ELoZo ERTEK -- a heartbeat minden kort nullarol kezd.
#
# 🛑 A `contextTokens` KULCSA A `name`, NEM `id` -- a `/api/agents` rekordban nincs `id` mezo.
#   Aki `id`-vel kulcsol, minden fejre None-t kap, es MINDEN fej "valtozott"-nak latszik --
#   vagyis epp a nema fejet tunteti el. Az elaltato irany.
#
# Onteszt: bash scripts/agent-activity-snapshot.sh --self-test

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAP_FILE="${AGENT_SNAPSHOT_FILE:-$REPO_ROOT/store/agent-activity-snapshot.txt}"
DB="${CLAUDECLAW_DB:-$REPO_ROOT/store/claudeclaw.db}"
TOKEN_FILE="${DASHBOARD_TOKEN_FILE:-$REPO_ROOT/store/.dashboard-token}"

gyujt() {
  local tok; tok="$(cat "$TOKEN_FILE" 2>/dev/null)"
  curl -s -H "Authorization: Bearer $tok" http://localhost:3420/api/agents 2>/dev/null \
    | AGENT_DB="$DB" python3 -c '
import json, os, sqlite3, subprocess, sys

try:
    agents = json.load(sys.stdin)
except Exception:
    sys.exit(0)                      # nincs adat -> ures kimenet, a hivo latja

db = os.environ["AGENT_DB"]
for a in agents:
    n = a.get("name")                # 🛑 name, NEM id -- a rekordban nincs id mezo
    if not n or not a.get("running"):
        continue
    ctx = a.get("contextTokens")
    ctx = "None" if ctx is None else str(ctx)

    # 🛑 KOTOTT PARAMETER, NEM STRING-BEHELYETTESITES. Az elso valtozat a nevet a SQL-be
    # illesztette (`q.replace("?", "\x27"+n+"\x27")`). A gyakorlati kockazat NEM a tamadas --
    # a nev a sajat API-nkbol jon --, hanem hogy EGY APOSZTROF a nevben eltori a lekerdezest,
    # a kivetel-ag "?"-et ad, es az `ALL:` feltetel (`nyitott not in ("0","?")`) EPP EZERT NEM
    # SUL EL: a sajat detektorom NEMAN elnyeli a beakadt fejet. (A `design` fogta meg, 2026-08-14.)
    try:
        with sqlite3.connect(db) as con:
            rows = con.execute(
                "select status from kanban_cards where assignee=? and archived_at is null "
                "and status in (\x27in_progress\x27,\x27testing\x27)", (n,)).fetchall()
            nyitott = str(len(rows))
            statuszok = ",".join(sorted(set(r[0] for r in rows))) if rows else "-"
            komment = con.execute(
                "select max(c.created_at) from kanban_comments c "
                "join kanban_cards k on k.id = c.card_id "
                "where k.assignee=? and k.archived_at is null "
                "and k.status in (\x27in_progress\x27,\x27testing\x27)", (n,)).fetchone()[0]
            komment_ido = str(komment) if komment is not None else "0"
    except Exception:
        nyitott, statuszok, komment_ido = "?", "?", "0"

    try:
        pane = subprocess.run(["tmux", "capture-pane", "-p", "-t", "agent-" + n],
                              capture_output=True, text=True).stdout
        sorok = [s for s in pane.split("\n") if s.strip()]
        # ures prompt: a footer FOLOTTI utolso erdemi sor maga a `❯` prompt
        ures = "1" if any(s.strip() == "❯" for s in sorok[-6:]) else "0"
    except Exception:
        ures = "?"

    print(n, ctx, nyitott, ures, statuszok, komment_ido)
'
}

# hu: A KULONBSEG-logika (verdikt: ALL: / var: / megy / uj / --- / form:) KULON fuggveny --
#   fajlokbol dolgozik (nincs curl, nincs tmux, nincs sqlite), ezert onmagaban tesztelheto. A
#   `--diff-only` CLI-mod pontosan EZT hivja, ugyanazt a kodutat, amit az eles futas is hasznal.
#   MELLEKTERMEKKENT a DUSITOTT (het mezos) sorokat is kiirja egy fajlba (3. parameter) -- ezt
#   menti a hivo a kovetkezo kor PREV fajljakent.
#
# 🛑 A 7. MEZO ("valtozatlan_ota") A JELENLEGI ctx-PLATO KEZDETE, NEM A FAJL MTIME-JA. A regi
#   valtozat a PREV FAJL MTIME-JAHOZ hasonlitotta a komment epoch-jat -- ez CSAK az ELSO
#   osszehasonlitasnal helyes, mert a store MINDEN futtataskor felulirodik, a mtime tehat
#   MINDEN korben elorecsuszik, mikozben a komment epoch-ja fix marad. A MASODIK (es minden
#   tovabbi) kortol a REGI, valtozatlan komment mar "reginek" szamitott volna a friss
#   mtime-hoz kepest, es a mero visszavaltott ALL:-ra egy TARTOSAN, szandekosan allo fejre
#   (merve 2026-09-06: ket egymas utani --diff-only hivassal reprodukalva, ugyanaz a hibaosztaly,
#   mint amiert ez a kartya szuletett -- a var: csak egy ciklusig vedett).
#   A plato kezdete AKKOR es CSAK AKKOR frissul MOST-ra, ha a ctx TENYLEGESEN valtozott az
#   elozo korhoz kepest -- kulonben oroklodik a PREV sorbol, tehat tetszoleges szamu korig
#   stabil marad, amig a fej allapota valtozatlan.
# en: Verdict logic factored out so it is testable in isolation. The 7th field records when the
#   current ctx-plateau began, not the snapshot file's mtime -- the mtime approach only worked
#   for a single comparison cycle, because the store file is rewritten every run.
osszehasonlit() {
  local prev="$1" uj="$2" dusitott="${3:-}"
  AGENT_PREV="$prev" AGENT_NEW="$uj" AGENT_ENRICHED="$dusitott" python3 - <<'PYEOF'
import os
import time

prev_file = os.environ["AGENT_PREV"]
prev = {}
malformed = set()
try:
    for s in open(prev_file):
        r = s.split()
        if not r:
            continue
        if len(r) == 7:
            prev[r[0]] = r
        else:
            # 🛑 REGI/ISMERETLEN FORMATUMU SOR (pl. a korabbi hatmezos alak) -- ez NEM
            #   "nincs elozo meres" (uj), hanem a store formatumot valtott. Csendben
            #   "uj"-kent kezelve MINDEN fej ALL:/var: dontese elmarad ugyanabban a korben,
            #   es a kimenet egy legitim elso futastol lathatatlanul kulonbozik
            #   (merve 2026-08-24, ordog fuggetlen atmerese).
            malformed.add(r[0])
except FileNotFoundError:
    pass

NOW = int(time.time())
enriched = []

for s in open(os.environ["AGENT_NEW"]):
    r = s.split()
    if len(r) != 6:
        continue
    nev, ctx, nyitott, ures, statuszok, komment_ido = r
    p = prev.get(nev)
    if not p:
        if nev not in malformed:
            print(f"  uj    {nev}: nincs elozo meres")
        else:
            print(f"  form: {nev}: elozo meres regi/ismeretlen formatumu -- ALL:/var: dontes nem allapithato meg")
        valtozatlan_ota = NOW
        enriched.append(f"{nev} {ctx} {nyitott} {ures} {statuszok} {komment_ido} {valtozatlan_ota}")
        continue

    if ctx == p[1]:
        try:
            valtozatlan_ota = int(p[6])
        except ValueError:
            valtozatlan_ota = NOW
    else:
        valtozatlan_ota = NOW

    if ctx == p[1] and ures == "1" and nyitott not in ("0", "?"):
        try:
            ki = int(komment_ido)
        except ValueError:
            ki = 0
        if ki > valtozatlan_ota:
            print(f"  var:  {nev} -- {statuszok}, {nyitott} nyitott kartya, "
                  f"FRISS komment a jelenlegi allapot-plato kezdete ota -- NEM beakadas")
        else:
            print(f"  ALL:  {nev} -- ctx VALTOZATLAN ({ctx}), ures prompt, "
                  f"{nyitott} nyitott kartya ({statuszok})")
    elif ctx != p[1]:
        print(f"  megy  {nev}: {p[1]} -> {ctx}")
    else:
        print(f"  ---   {nev}: ctx valtozatlan, de nem all (ures={ures}, nyitott={nyitott})")

    enriched.append(f"{nev} {ctx} {nyitott} {ures} {statuszok} {komment_ido} {valtozatlan_ota}")

enriched_out = os.environ.get("AGENT_ENRICHED")
if enriched_out:
    with open(enriched_out, "w") as f:
        for sor in enriched:
            f.write(sor + "\n")
PYEOF
}

if [ "${1:-}" = "--diff-only" ]; then
  osszehasonlit "$2" "$3" "${4:-}" >&2
  exit 0
fi

if [ "${1:-}" = "--self-test" ]; then
  fail=0
  ki="$(gyujt)"
  # POZITIV KONTROLL: legalabb egy fejnek meg kell jelennie, kulonben a gyujtes hibas.
  n=$(printf '%s\n' "$ki" | grep -c . || true)
  if [ "${n:-0}" -gt 0 ]; then echo "  OK    a gyujtes $n futo fejet ert el"; else
    echo "  BUKIK a gyujtes NULLA fejet ert el -- a MEROD hibas, nem a flotta"; fail=1; fi
  # A sor-alak: hat mezo (nev, ctx, nyitott, ures, statuszok, komment_epoch)
  rossz=$(printf '%s\n' "$ki" | awk 'NF && NF!=6' | wc -l | tr -d ' ')
  if [ "$rossz" = 0 ]; then echo "  OK    minden sor hat mezos"; else
    echo "  BUKIK $rossz sor nem hat mezos"; fail=1; fi
  # ELLEN-PROBA: nem letezo fej neve NE szerepeljen
  if printf '%s\n' "$ki" | grep -q '^nincsilyenfej '; then
    echo "  BUKIK kitalalt fej a kimenetben"; fail=1; else
    echo "  OK    nincs kitalalt fej a kimenetben"; fi
  [ "$fail" = 0 ] && echo "onteszt: MIND ZOLD" || echo "onteszt: VAN BUKO SOR"
  exit "$fail"
fi

uj="$(gyujt)"
[ -z "$uj" ] && { echo "nincs adat (a dashboard nem valaszolt)" >&2; exit 1; }

if [ -f "$SNAP_FILE" ]; then
  # 🛑 A FRISS ADAT FAJLBAN MEGY AT, NEM STDIN-EN. Az elso valtozat `python3 - <<'PYEOF' <<<"$uj"`
  # alakot hasznalt: KET bemenet-atiranyitas ugyanarra a leiroa, es a MASODIK nyer -- vagyis a
  # Python a SZKRIPT helyett az ADATOT kapta, `SyntaxError`-t irt a stderr-re, es a kulonbseg-logika
  # SOHA NEM FUTOTT LE. A script kimenete es kilepesi kodja valtozatlanul jonak latszott.
  # A sajat ellen-probam is ATENGEDTE: nullat szamolt, de azert, mert semmi nem futott. (Merve.)
  UJ_TMP="$(mktemp)"
  DUSITOTT_TMP="$(mktemp)"
  printf '%s\n' "$uj" > "$UJ_TMP"
  # A KULONBSEG a lenyeg, nem a pillanatfelvetel -- lasd az `osszehasonlit()` fuggveny.
  # A store-ba a DUSITOTT (het mezos, "valtozatlan_ota" platokezdettel biroitott) sorok
  # kerulnek, NEM a nyers `$uj` -- kulonben a plato-kezdet minden korben elveszne.
  osszehasonlit "$SNAP_FILE" "$UJ_TMP" "$DUSITOTT_TMP" >&2
  rm -f "$UJ_TMP"
  cp "$DUSITOTT_TMP" "$SNAP_FILE"
  rm -f "$DUSITOTT_TMP"
else
  echo "elso futas -- nincs mihez merni, a kovetkezo kor mar osszevet" >&2
  # Elso futas: minden fej plato-ja MOST kezdodik.
  NOW="$(date +%s)"
  printf '%s\n' "$uj" | awk -v now="$NOW" 'NF { print $0, now }' > "$SNAP_FILE"
fi

printf '%s\n' "$uj"
