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

# ── Fixture: PREV snapshot -- mindharom fej ugyanazzal a ctx-szel indul, mtime = PREV_MTIME ────
FPrev="$FTmp/prev.txt"
cat > "$FPrev" <<EOF
stuck1 202030 1 1 in_progress 0
wait1 337835 1 1 in_progress 0
oldcomment1 120280 1 1 in_progress 0
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
  /if ki > prev_mtime:/ { print "        if False:"; next }
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

echo
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "  ✅ $FPass  ❌ $FFail"
[ "$FFail" -eq 0 ] || exit 1
