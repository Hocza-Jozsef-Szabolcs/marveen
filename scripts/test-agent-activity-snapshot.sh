#!/usr/bin/env bash
# hu: A `agent-activity-snapshot.sh` --diff-only ereben mert eset: a VERDIKT-logika (ALL:) nem
#     kulonboztette meg a VALODI beakadast a SZANDEKOSAN leallitott fejtol -- mindket eset
#     ugyanazt a harom feltetelt (ctx valtozatlan + ures prompt + nyitott kartya) teljesitette.
#     T1 a valodi beakadast reprodukalja (nincs friss komment a nyitott kartyan -> ALL: kell).
#     T2 a szandekos leallast reprodukalja (a nyitott kartyan az ELOZO meres OTA erkezett komment
#     -> NEM ALL:, hanem "var:" jelzes kell). T3 igazolja, hogy egy REGI (a prev-meres ELOTTI)
#     komment NEM fojtja el az ALL:-t -- kulonben minden valaha kommentelt kartya orokre nemava.
#
# 🛑 MUTACIO-ESET (T4): a frisseseg-ellenorzest kivesszuk egy masolatbol, es elvarjuk, hogy a T2
#    VISSZAJOJJON (a mutans tevesen ALL:-t adjon a szandekosan leallitott fejre). Ha a mutans is
#    helyesen "var:"-ot ad, a T2 vak -- nem a frissesseg-logika mukodik.
#
# en: Measuring harness for agent-activity-snapshot.sh --diff-only. T2 is the false-positive case
#     from card activity-snapshot-hamis-pozitiv-szandekos-leallas-20260814; T4 is a mutation test
#     proving T2 actually exercises the freshness-suppression logic.
#
# EXIT: 0 = minden eset a vart eredmenyt adta | 1 = legalabb egy eset elter

set -uo pipefail

CDir="$(cd "$(dirname "$0")" && pwd)"
CScript="$CDir/agent-activity-snapshot.sh"

FTmp=$(mktemp -d "${TMPDIR:-/tmp}/agent-activity-snapshot-teszt.XXXXXX")
trap 'rm -rf "$FTmp"' EXIT

FPass=0
FFail=0

check() {
  local nev="$1"
  local vart="$2"
  local kapott="$3"

  if [ "$vart" = "$kapott" ]; then
    echo "  ✅ $nev"
    FPass=$((FPass + 1))
  else
    echo "  ❌ $nev -- vart: [$vart], kapott: [$kapott]"
    FFail=$((FFail + 1))
  fi
}

epoch_set() {
  # hu: fajl mtime-jat allitja a megadott epoch-ra (BSD/GNU-fuggetlen, python3-mal).
  python3 -c "import os,sys; os.utime(sys.argv[1], (float(sys.argv[2]), float(sys.argv[2])))" "$1" "$2"
}

NOW=$(date +%s)
PREV_MTIME=$((NOW - 3600))   # a legutobbi meres 1 oraja volt

# ── Fixture: PREV snapshot -- mindharom fej ugyanazzal a ctx-szel indul, a plato kezdete
#    (7. mezo) = PREV_MTIME, hogy a forgatokonyv ekvivalens maradjon a korabbi mtime-alapu
#    szemantikaval ────────────────────────────────────────────────────────────────────────
FPrev="$FTmp/prev.txt"
cat > "$FPrev" <<EOF
stuck1 202030 1 1 in_progress 0 $PREV_MTIME
wait1 337835 1 1 in_progress 0 $PREV_MTIME
oldcomment1 120280 1 1 in_progress 0 $PREV_MTIME
EOF
epoch_set "$FPrev" "$PREV_MTIME"

echo "── T1 (valodi beakadas): nincs komment a nyitott kartyan -> ALL: ─────────────────────"
FNew="$FTmp/new-t1.txt"
cat > "$FNew" <<EOF
stuck1 202030 1 1 in_progress 0
EOF
"$CScript" --diff-only "$FPrev" "$FNew" >"$FTmp/t1.out" 2>&1
check "T1 ALL: szerepel stuck1-re" "1" \
  "$(grep -qE '^ *ALL: *stuck1' "$FTmp/t1.out" && echo 1 || echo 0)"

echo "── T2 (szandekos leallas): friss komment az ELOZO meres OTA -> NEM ALL: ───────────────"
FNew="$FTmp/new-t2.txt"
FRISS_KOMMENT=$((NOW - 60))   # 1 perce, az PREV_MTIME (1 oraja) UTAN
cat > "$FNew" <<EOF
wait1 337835 1 1 in_progress $FRISS_KOMMENT
EOF
"$CScript" --diff-only "$FPrev" "$FNew" >"$FTmp/t2.out" 2>&1
check "T2 NEM ALL: wait1-re" "0" \
  "$(grep -qE '^ *ALL: *wait1' "$FTmp/t2.out" && echo 1 || echo 0)"
check "T2 a var: jelzes szerepel wait1-re" "1" \
  "$(grep -qE '^ *var: *wait1' "$FTmp/t2.out" && echo 1 || echo 0)"

echo "── T3 (regi komment, a PREV meres ELOTTROL): NEM fojtja el az ALL:-t ──────────────────"
FNew="$FTmp/new-t3.txt"
REGI_KOMMENT=$((PREV_MTIME - 3600))   # 2 oraja, meg a PREV meres ELOTT
cat > "$FNew" <<EOF
oldcomment1 120280 1 1 in_progress $REGI_KOMMENT
EOF
"$CScript" --diff-only "$FPrev" "$FNew" >"$FTmp/t3.out" 2>&1
check "T3 ALL: szerepel oldcomment1-re (a regi komment nem szamit frissnek)" "1" \
  "$(grep -qE '^ *ALL: *oldcomment1' "$FTmp/t3.out" && echo 1 || echo 0)"

echo "── T4 (MUTACIO): a frissesseg-ellenorzes kivetele -> a T2 BUKJON vissza ───────────────"
CMutans="$FTmp/agent-activity-snapshot-mutans.sh"
awk '
  /if ki > valtozatlan_ota:/ { print "        if False:"; next }
  { print }
' "$CScript" > "$CMutans"
chmod +x "$CMutans"
if cmp -s "$CScript" "$CMutans"; then
  echo "  ❌ T4 a mutacio NEM valtoztatott a szkripten -- a minta elavult, a T4 vak"
  FFail=$((FFail + 1))
else
  "$CMutans" --diff-only "$FPrev" "$FTmp/new-t2.txt" >"$FTmp/t4.out" 2>&1
  check "T4 a mutansnal wait1 TEVESEN ALL:-t kap" "1" \
    "$(grep -qE '^ *ALL: *wait1' "$FTmp/t4.out" && echo 1 || echo 0)"
fi

echo "── T5 (formatum-valtas): a PREV fajlban regi/nem-hatmezos sor -> NEM csendes 'uj' ─────"
# hu: a store/agent-activity-snapshot.txt-nek MAR VOLT negymezos formatuma (2026-08-24), a
#     `if len(r) == 6` csendben eldobja az ilyen sort a prev-szotarbol -- a fej ugy nez ki,
#     mintha meg sose merte volna senki, es SOHA nem kap ALL:/var: dontest ugyanabban a korben,
#     amikor a store formatumot valt. A hiba NEM VESZI ESZRE MAGAT: egy legitim elso futastol
#     lathatatlanul kulonbozik (ordog fuggetlen atmerese, activity-snapshot-hamis-pozitiv-
#     szandekos-leallas-20260814 kartya, 2026-08-24 23:15).
FPrevOld="$FTmp/prev-oldformat.txt"
cat > "$FPrevOld" <<EOF
oldformat1 100000 0 1
EOF
epoch_set "$FPrevOld" "$PREV_MTIME"
FNew="$FTmp/new-t5.txt"
cat > "$FNew" <<EOF
oldformat1 100000 1 1 in_progress 0
EOF
"$CScript" --diff-only "$FPrevOld" "$FNew" >"$FTmp/t5.out" 2>&1
check "T5 NEM 'uj' jelzes oldformat1-re" "0" \
  "$(grep -qE '^ *uj *oldformat1' "$FTmp/t5.out" && echo 1 || echo 0)"
check "T5 kulon formatum-jelzes szerepel oldformat1-re" "1" \
  "$(grep -qE '^ *form: *oldformat1' "$FTmp/t5.out" && echo 1 || echo 0)"

echo "── T6 (MUTACIO): a formatum-eszrevetel kivetele -> a T5 BUKJON vissza ─────────────────"
CMutans2="$FTmp/agent-activity-snapshot-mutans2.sh"
awk '
  /if nev not in malformed:/ { print "        if True:"; next }
  { print }
' "$CScript" > "$CMutans2"
chmod +x "$CMutans2"
if cmp -s "$CScript" "$CMutans2"; then
  echo "  ❌ T6 a mutacio NEM valtoztatott a szkripten -- a minta elavult, a T6 vak"
  FFail=$((FFail + 1))
else
  "$CMutans2" --diff-only "$FPrevOld" "$FNew" >"$FTmp/t6.out" 2>&1
  check "T6 a mutansnal oldformat1 TEVESEN 'uj'-t kap" "1" \
    "$(grep -qE '^ *uj *oldformat1' "$FTmp/t6.out" && echo 1 || echo 0)"
fi

echo "── T7 (TOBB CIKLUS): a mtime-alapu referenciapont visszavaltana ALL:-ra, a plato-  ─────"
echo "    kezdet (7. mezo) alapu referenciapont NEM ─────────────────────────────────────────"
# hu: a T1-T4 EGYETLEN osszehasonlitast tesztelt. Ha a referenciapont a PREV FAJL MTIME-ja
#     (a regi kod), a MASODIK es minden tovabbi ciklustol a komment mar "reginek" szamit a
#     friss mtime-hoz kepest, es a fej ALL:-t kap, holott az allapota valtozatlan (merve
#     2026-09-06, ket egymas utani --diff-only hivassal). A PREV itt mar 7 mezos (a
#     "valtozatlan_ota" plato-kezdet mezovel): a komment (REGI epoch) a PLATO KEZDETE UTAN
#     keletkezett -- tehat frissnek szamit -- de a PREV FAJL MTIME-ja (amit epoch_set MOST-ra
#     allit) UTANA van a kommentnek. A regi (mtime-alapu) logika ALL:-t adna, a helyes
#     (plato-kezdet-alapu) logika var:-ot.
PLATO_KEZDETE=500000000
KOMMENT_A_PLATO_UTAN=500010000
FPrevT7="$FTmp/prev-t7.txt"
cat > "$FPrevT7" <<EOF
fejx7 100000 1 1 in_progress $KOMMENT_A_PLATO_UTAN $PLATO_KEZDETE
EOF
touch "$FPrevT7"   # mtime = MOST -- jocskan a KOMMENT_A_PLATO_UTAN epoch utan
FNewT7="$FTmp/new-t7.txt"
cat > "$FNewT7" <<EOF
fejx7 100000 1 1 in_progress $KOMMENT_A_PLATO_UTAN
EOF
"$CScript" --diff-only "$FPrevT7" "$FNewT7" >"$FTmp/t7.out" 2>&1
check "T7 NEM ALL: fejx7-re (a plato kezdete a mervado, nem a fajl mtime)" "0" \
  "$(grep -qE '^ *ALL: *fejx7' "$FTmp/t7.out" && echo 1 || echo 0)"
check "T7 var: jelzes szerepel fejx7-re" "1" \
  "$(grep -qE '^ *var: *fejx7' "$FTmp/t7.out" && echo 1 || echo 0)"

echo "── T8 (MUTACIO): a plato-kezdet oroklese kivetele -> a T7 BUKJON vissza ───────────────"
CMutans3="$FTmp/agent-activity-snapshot-mutans3.sh"
awk '
  /valtozatlan_ota = int\(p\[6\]\)/ { print "            valtozatlan_ota = NOW"; next }
  { print }
' "$CScript" > "$CMutans3"
chmod +x "$CMutans3"
if cmp -s "$CScript" "$CMutans3"; then
  echo "  ❌ T8 a mutacio NEM valtoztatott a szkripten -- a minta elavult, a T8 vak"
  FFail=$((FFail + 1))
else
  "$CMutans3" --diff-only "$FPrevT7" "$FNewT7" >"$FTmp/t8.out" 2>&1
  check "T8 a mutansnal fejx7 TEVESEN ALL:-t kap" "1" \
    "$(grep -qE '^ *ALL: *fejx7' "$FTmp/t8.out" && echo 1 || echo 0)"
fi

echo
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "  ✅ $FPass  ❌ $FFail"
[ "$FFail" -eq 0 ] || exit 1
