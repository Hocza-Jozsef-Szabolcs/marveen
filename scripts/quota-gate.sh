#!/usr/bin/env bash
# Kvota-fagyasztas kapu -- EGYETLEN igazsag-forras minden utemezett feladatnak.
#
# Kimenet: "FAGYASZTVA" vagy "fut" (plusz indoklas a masodik soron, ha lejart).
#
# MIERT LETEZIK (2026-08-08, sajat hiba):
#   A regi, SKILL.md-kbe MASOLT egysoros CSAK az `active` mezot nezte, a `resets_at`-ot NEM.
#   Ezert a fagyasztas TULELTE a sajat lejaratat: a reset 14:00-kor megvolt, es a heartbeatek
#   14:52-kor MEG MINDIG kileptek. A lejarati ido vegig ott allt a fajlban -- senki nem olvasta.
#   Jozsinak kellett szolnia ("14:50 van!!!").
#
#   Ez ugyanaz a hibaosztaly, amit aznap egesz nap masokban kerestunk: EGY JELZES, AMI A SAJAT
#   HATOKOREN (itt: ervenyessegi idejen) KIVUL IS ALLITJA MAGAT. A "zold, mert nem neztem oda".
#
#   ES AMIERT SCRIPT LETT BELoLE, NEM JAVITOTT EGYSOROS: a regi valtozat HAT SKILL.md-be volt
#   MASOLVA. Hat masodpeldany = hat hely, ahol szet tud csuszni, es ahol a javitas kimaradhat.
#   Innentol a logika EGY helyen el; a SKILL.md-k csak hivjak.
#
# Hasznalat a SKILL.md-kben:
#   bash /Users/ceo/Marveen/scripts/quota-gate.sh
#
# AUTOMATA FAGYASZTAS 80% FOLOTT (Jozsi 2026-08-06-i kuszobe, gazda-dontessel bekotve
# 2026-08-24-en): ha a kezi `active` false vagy hianyzik, a kapu megnezi a
# `store/quota-status.json` heti felhasznalasat (`seven_day_used_percentage`) is. Ha az FRISS
# (max `QUOTA_STATUS_MAX_AGE_SEC`, alap 6 ora) ES eleri a kuszobot (`QUOTA_FREEZE_THRESHOLD_PERCENT`,
# alap 80), a kapu maga irja vissza a `quota-freeze.json`-t `active: true`-ra, a `reason` mezobe
# a mert erteket es az idobelyeget. ELAVULT vagy hianyzo/serult meres SOHA nem fagyaszt -- a
# fagyasztas maga a koltseges lepes, ezert csak megbizhato adatra epul; hianyzo adat eseten a
# gazda kezi eszlelese marad a halo, nem egy tobblet-tiltas.
#
# Onteszt (5/e -- a kaput bukas-eloallitassal kell igazolni, nem feltetelezessel):
#   bash /Users/ceo/Marveen/scripts/quota-gate.sh --self-test

set -uo pipefail

GATE_FILE="${QUOTA_GATE_FILE:-/Users/ceo/Marveen/store/quota-freeze.json}"
STATUS_FILE="${QUOTA_STATUS_FILE:-/Users/ceo/Marveen/store/quota-status.json}"
FREEZE_THRESHOLD_PERCENT="${QUOTA_FREEZE_THRESHOLD_PERCENT:-80}"
STATUS_MAX_AGE_SEC="${QUOTA_STATUS_MAX_AGE_SEC:-21600}"   # 6 ora

evaluate() {
  QUOTA_GATE_FILE="$1" QUOTA_STATUS_FILE="$2" QUOTA_FREEZE_THRESHOLD_PERCENT="$3" \
    QUOTA_STATUS_MAX_AGE_SEC="$4" python3 - <<'PYEOF'
import json, os, sys, time, datetime

path = os.environ['QUOTA_GATE_FILE']
status_path = os.environ['QUOTA_STATUS_FILE']
threshold = float(os.environ['QUOTA_FREEZE_THRESHOLD_PERCENT'])
status_max_age = float(os.environ['QUOTA_STATUS_MAX_AGE_SEC'])


def szam(value):
    """hu: Veges szamma alakit, vagy None-t ad. A bool NEM szam (Pythonban a bool az int
        alosztalya) -- lasd qcassa-priority-gate.sh, ugyanez a mintaja.
    <br />
    en: Converts to a finite number or returns None. A bool is NOT a number (bool subclasses
        int in Python) -- see qcassa-priority-gate.sh, same pattern.
    """
    if isinstance(value, bool):
        return None
    try:
        f = float(value)
    except (TypeError, ValueError):
        return None
    if f != f or f in (float('inf'), float('-inf')):
        return None
    return f


def auto_freeze_due():
    """hu: Ha a kezi kapcsolo NINCS bekapcsolva, megnezi, kell-e AUTOMATA fagyasztas a heti
        kereten (Jozsi 2026-08-06-i 80%-os kuszobe). CSAK FRISS, ertelmezheto meresre epul --
        elavult/serult/hianyzo status-fajl SOHA nem fagyaszt, mert a fagyasztas maga a
        koltseges lepes (leallitja az egesz flottat); a hianyzo adat eseten a status quo
        (a gazda kezi eszlelese) marad a halo, nem egy tobblet-tiltas.
    <br />
    en: When the manual switch is off, checks whether the weekly quota calls for an AUTOMATIC
        freeze (Jozsi's 2026-08-06 80% threshold). Acts only on FRESH, well-formed data --
        stale/corrupt/missing status data never freezes, because freezing itself is the costly
        action (halts the whole fleet); missing data falls back to the status quo (the owner's
        manual observation), not an extra restriction.
    """
    try:
        with open(status_path) as fh:
            s = json.load(fh)
    except Exception:
        return None

    if not isinstance(s, dict):
        return None

    used = szam(s.get('seven_day_used_percentage'))
    measured_at = szam(s.get('measured_at'))
    resets_at_epoch = szam(s.get('seven_day_resets_at'))

    if used is None or not (0.0 <= used <= 100.0):
        return None

    if measured_at is None:
        return None

    kor = time.time() - measured_at

    if kor < -120 or kor > status_max_age:
        return None

    if used < threshold:
        return None

    return (used, measured_at, resets_at_epoch)


def write_auto_freeze(d, used, measured_at, resets_at_epoch):
    """hu: A meglevo fagyaszto-fajl mezoit FRISSITI, nem cimet ir felul mindent -- a tortenetit
        (pl. `elore_besorolas`) erintetlenul hagyja, csak az aktiv allapotot es az okot allitja.
    <br />
    en: UPDATES the existing freeze-file fields, not a blank overwrite -- leaves history
        (e.g. `elore_besorolas`) untouched, only sets the active state and reason.
    """
    resets_str = None
    if resets_at_epoch is not None:
        rt = datetime.datetime.fromtimestamp(resets_at_epoch)
        nap = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][rt.weekday()]
        resets_str = f"{nap} {rt:%H:%M}"

    measured_str = datetime.datetime.fromtimestamp(measured_at).strftime('%Y-%m-%d %H:%M')

    d['active'] = True
    d['activated_at'] = int(time.time())
    d['resets_at'] = resets_str
    d['reason'] = (f"AUTOMATA FAGYASZTAS: heti felhasznalas {used:.0f}% >= kuszob {threshold:.0f}% "
                   f"(merve {measured_str})")
    d.pop('deactivated_at', None)
    d.pop('deactivated_reason', None)

    tmp = path + '.tmp'
    with open(tmp, 'w') as fh:
        json.dump(d, fh, indent=2, ensure_ascii=False)
    os.replace(tmp, path)


# FAIL-CLOSED: ha a fajl olvashatatlan vagy serult, FAGYASZTVA-t mondunk. Egy kimaradt
# heartbeat-kor olcso; egy fagyasztas alatt elegetett keret nem az.
try:
    with open(path) as fh:
        d = json.load(fh)
except Exception as exc:
    print("FAGYASZTVA")
    print(f"a kapu-fajl nem olvashato ({exc}) -- fail-closed", file=sys.stderr)
    sys.exit(0)

if d.get('manual_hold'):
    # A gazda kifejezetten kerte, hogy a feloldas utan az AUTOMATA fagyasztas se all-itsa
    # vissza, amig o maga ujra nem keri -- ez a kezi tartas kapcsolja ki az auto_freeze_due()
    # agat teljesen, fuggetlenul az `active` mezotol.
    print("fut")
    print("figyelem: manual_hold aktiv -- az automata fagyasztas ki van kapcsolva, amig a gazda ujra nem keri",
          file=sys.stderr)
    sys.exit(0)

if not d.get('active'):
    hit = auto_freeze_due()
    if hit is not None:
        used, measured_at, resets_at_epoch = hit
        write_auto_freeze(d, used, measured_at, resets_at_epoch)
        print("FAGYASZTVA")
        print(f"AUTOMATA fagyasztas: heti felhasznalas {used:.0f}% >= kuszob {threshold:.0f}%",
              file=sys.stderr)
        sys.exit(0)
    print("fut")
    sys.exit(0)

# --- A LENYEGI RESZ, AMI A REGI EGYSORESBoL HIANYZOTT: lejart-e mar? ---
resets_at = (d.get('resets_at') or '').strip()
activated = d.get('activated_at')

if not resets_at or not activated:
    # Nincs mihez merni -> marad a fagyasztas, de MONDJUK KI, hogy nem tudtuk ellenorizni.
    print("FAGYASZTVA")
    print("figyelem: nincs resets_at vagy activated_at -- a lejarat NEM ellenorizheto", file=sys.stderr)
    sys.exit(0)

DAYS = {'mon':0, 'tue':1, 'wed':2, 'thu':3, 'fri':4, 'sat':5, 'sun':6}
parts = resets_at.split()

try:
    weekday = DAYS[parts[0][:3].lower()]
    hh, mm = (int(x) for x in parts[1].split(':'))
except Exception:
    print("FAGYASZTVA")
    print(f"figyelem: a resets_at ('{resets_at}') nem ertelmezheto -- a lejarat NEM ellenorizheto",
          file=sys.stderr)
    sys.exit(0)

start = datetime.datetime.fromtimestamp(activated)
# Az aktivalas UTANI elso ilyen napu idopont. A 0 nap elorelepes is jo, ha az ido meg hatravan.
delta = (weekday - start.weekday()) % 7
reset = (start + datetime.timedelta(days=delta)).replace(hour=hh, minute=mm, second=0, microsecond=0)

if reset <= start:
    reset += datetime.timedelta(days=7)

now = datetime.datetime.now()

if now >= reset:
    print("fut")
    print(f"a fagyasztas LEJART: a reset ({reset:%Y-%m-%d %H:%M}) mar elmult, most {now:%Y-%m-%d %H:%M} van.",
          file=sys.stderr)
    print("az active mezo MEG MINDIG true -- allitsd false-ra, es szolj a gazdanak.", file=sys.stderr)
    sys.exit(0)

print("FAGYASZTVA")
hatra = reset - now
print(f"lejarat: {reset:%Y-%m-%d %H:%M} ({hatra.seconds // 3600} ora {hatra.seconds % 3600 // 60} perc mulva)",
      file=sys.stderr)
PYEOF
}

if [ "${1:-}" = "--self-test" ]; then
  # 5/e: NEM feltetelezzuk, hogy mukodik -- ELoALLITJUK a hibat, amit el kell kapnia.
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  fail=0

  check() {  # nev, elvart, kapott
    if [ "$2" = "$3" ]; then echo "  OK    $1 -> $3"; else echo "  BUKIK $1 -> vart:$2 kapott:$3"; fail=1; fi
  }

  # A BUKAS, AMI MA ELESBEN MEGTORTENT: aktiv fagyasztas, LEJART resettel.
  # A regi egysoros erre FAGYASZTVA-t mondott. Ha ez a sor zold, a javitas ervenyes.
  python3 - "$TMP/lejart.json" <<'PY'
import json, sys, time, datetime
# aktivalas: 2 nappal ezelott; reset: az azt koveto szombat 14:00 -- ha ma mar tulvagyunk rajta, lejart
start = datetime.datetime.now() - datetime.timedelta(days=9)
json.dump({"active": True, "activated_at": int(start.timestamp()), "resets_at": "Sat 14:00"},
          open(sys.argv[1], 'w'))
PY
  check "aktiv + LEJART reset (a mai eles bukas)" "fut" \
    "$(evaluate "$TMP/lejart.json" "$TMP/nincs-status.json" 80 21600 2>/dev/null)"

  # Ellen-proba: aktiv, de a reset MEG HATRAVAN -> maradjon FAGYASZTVA.
  # Enelkul a "fut" johetne abbol is, hogy a script mindenre fut-ot mond.
  python3 - "$TMP/el.json" <<'PY'
import json, sys, datetime
start = datetime.datetime.now() - datetime.timedelta(minutes=5)
nap = ['mon','tue','wed','thu','fri','sat','sun'][(datetime.datetime.now() + datetime.timedelta(days=3)).weekday()]
json.dump({"active": True, "activated_at": int(start.timestamp()),
           "resets_at": f"{nap.capitalize()} {datetime.datetime.now():%H}:00"}, open(sys.argv[1], 'w'))
PY
  check "aktiv + reset MEG HATRAVAN" "FAGYASZTVA" \
    "$(evaluate "$TMP/el.json" "$TMP/nincs-status.json" 80 21600 2>/dev/null)"

  echo '{"active": false}' > "$TMP/ki.json"
  check "kikapcsolt kapu" "fut" \
    "$(evaluate "$TMP/ki.json" "$TMP/nincs-status.json" 80 21600 2>/dev/null)"

  # A HIBAKEZELo AG -- a legritkabban futo ut, ezert kotelezo merni (5/e).
  echo 'ez nem json' > "$TMP/rossz.json"
  check "serult fajl (fail-closed)" "FAGYASZTVA" \
    "$(evaluate "$TMP/rossz.json" "$TMP/nincs-status.json" 80 21600 2>/dev/null)"
  check "nem letezo fajl (fail-closed)" "FAGYASZTVA" \
    "$(evaluate "$TMP/nincs.json" "$TMP/nincs-status.json" 80 21600 2>/dev/null)"

  python3 -c "import json,sys; json.dump({'active':True}, open(sys.argv[1],'w'))" "$TMP/hianyos.json"
  check "aktiv, de NINCS resets_at" "FAGYASZTVA" \
    "$(evaluate "$TMP/hianyos.json" "$TMP/nincs-status.json" 80 21600 2>/dev/null)"

  echo "-- AUTOMATA fagyasztas a heti kereten (Jozsi 2026-08-06-i 80%-os kuszobe) --"

  # Kesz status-fajl adott szazalekkal es korral (masodpercben).
  mkstatus() {  # fajl, szazalek, kor_masodpercben, [resets_at_epoch]
    python3 -c "
import json, sys, time
d = {'seven_day_used_percentage': float(sys.argv[2]), 'measured_at': time.time() - float(sys.argv[3])}
if len(sys.argv) > 4:
    d['seven_day_resets_at'] = float(sys.argv[4])
json.dump(d, open(sys.argv[1], 'w'))" "$@"
  }

  echo '{"active": false}' > "$TMP/kikapcsolva.json"
  mkstatus "$TMP/friss85.json" 85 60 "$(( $(date +%s) + 100000 ))"
  ki="$(evaluate "$TMP/kikapcsolva.json" "$TMP/friss85.json" 80 21600 2>/dev/null)"
  check "kikapcsolt kapu + FRISS 85% (kuszob felett) -> AUTO fagyaszt" "FAGYASZTVA" "$ki"
  check "  a fagyaszto-fajl active:true-ra irodott" "1" \
    "$(python3 -c "import json; print(1 if json.load(open('$TMP/kikapcsolva.json')).get('active') is True else 0)")"
  check "  a reason mezo a mert erteket hordozza" "1" \
    "$(python3 -c "import json; print(1 if '85' in json.load(open('$TMP/kikapcsolva.json')).get('reason','') else 0)")"

  echo '{"active": false}' > "$TMP/kikapcsolva2.json"
  mkstatus "$TMP/friss56.json" 56 60
  check "kikapcsolt kapu + FRISS 56% (kuszob alatt) -> nem fagyaszt" "fut" \
    "$(evaluate "$TMP/kikapcsolva2.json" "$TMP/friss56.json" 80 21600 2>/dev/null)"

  # A KARTYA SAJAT KOVETELMENYE: elavult meres SOHA ne fagyasszon, meg 95%-nal se --
  # a fagyasztas maga a koltseges lepes, csak megbizhato adatra epulhet.
  echo '{"active": false}' > "$TMP/kikapcsolva3.json"
  mkstatus "$TMP/elavult95.json" 95 30000
  check "kikapcsolt kapu + ELAVULT 95% (8,3 oras) -> NEM fagyaszt" "fut" \
    "$(evaluate "$TMP/kikapcsolva3.json" "$TMP/elavult95.json" 80 21600 2>/dev/null)"

  echo '{"active": false}' > "$TMP/kikapcsolva4.json"
  check "kikapcsolt kapu + HIANYZO status-fajl -> nem fagyaszt (fail-open erre az agra)" "fut" \
    "$(evaluate "$TMP/kikapcsolva4.json" "$TMP/nincs-status.json" 80 21600 2>/dev/null)"

  echo '{"active": false}' > "$TMP/kikapcsolva5.json"
  echo 'ez nem json' > "$TMP/serult-status.json"
  check "kikapcsolt kapu + SERULT status-fajl -> nem fagyaszt" "fut" \
    "$(evaluate "$TMP/kikapcsolva5.json" "$TMP/serult-status.json" 80 21600 2>/dev/null)"

  echo '{"active": false}' > "$TMP/kikapcsolva6.json"
  mkstatus "$TMP/pontkuszob.json" 80 60
  check "kikapcsolt kapu + PONTOSAN a kuszobon (80%, friss) -> fagyaszt (zart hatar)" "FAGYASZTVA" \
    "$(evaluate "$TMP/kikapcsolva6.json" "$TMP/pontkuszob.json" 80 21600 2>/dev/null)"

  echo '{"active": false, "manual_hold": true}' > "$TMP/hold.json"
  mkstatus "$TMP/friss90.json" 90 60
  check "manual_hold:true + FRISS 90% (kuszob folott) -> NEM fagyaszt (a gazda kerte)" "fut" \
    "$(evaluate "$TMP/hold.json" "$TMP/friss90.json" 80 21600 2>/dev/null)"
  check "  manual_hold alatt a fajl active mezoje MARAD false (nincs felulirva)" "1" \
    "$(python3 -c "import json; print(1 if json.load(open('$TMP/hold.json')).get('active') is False else 0)")"

  echo '{"active": false}' > "$TMP/kikapcsolva7.json"
  mkstatus "$TMP/kuszobalatt.json" 79 60
  check "kikapcsolt kapu + kuszob alatt eggyel (79%, friss) -> nem fagyaszt" "fut" \
    "$(evaluate "$TMP/kikapcsolva7.json" "$TMP/kuszobalatt.json" 80 21600 2>/dev/null)"

  [ "$fail" = 0 ] && echo "onteszt: MIND ZOLD" || echo "onteszt: VAN BUKO SOR"
  exit "$fail"
fi

evaluate "$GATE_FILE" "$STATUS_FILE" "$FREEZE_THRESHOLD_PERCENT" "$STATUS_MAX_AGE_SEC"
