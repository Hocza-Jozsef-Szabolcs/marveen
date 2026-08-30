#!/bin/bash
# hu: Bukas-eloallito teszt a tg-digest-queue.sh-hoz -- add/count/flush ciklus, es hogy a
#     flush TENYLEG uriti a sort (kulonben ugyanaz a tetel tobbszor menne ki kotegben).
# en: Failure-producing test suite for tg-digest-queue.sh -- add/count/flush cycle, and that
#     flush ACTUALLY empties the queue (otherwise the same item would go out repeatedly).
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tg-digest-queue.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
FAILED_NAMES=()

check() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    PASS=$((PASS + 1))
    printf '  ✅ %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
    printf '  ❌ %s -- vart: %s, kapott: %s\n' "$name" "$want" "$got"
  fi
}

# hu: a szkript a QUEUE utat fixen a sajat torzsebe irja -- egy futtathato masolatot keszitunk,
#     amiben a QUEUE valtozo a teszt munkakonyvtarara mutat, hogy ne az eles sort piszkaljuk.
TEST_SCRIPT="$WORK/tg-digest-queue.sh"
sed "s#^QUEUE=.*#QUEUE=\"$WORK/queue.jsonl\"#" "$SCRIPT" > "$TEST_SCRIPT"
chmod +x "$TEST_SCRIPT"

echo "── T1: ures sor -- count 0 ──────────────────────────────────────────────"
check "T1 count 0 ures sornal" "0" "$("$TEST_SCRIPT" count)"

echo "── T2: add ket tetelt -- count 2 ────────────────────────────────────────"
"$TEST_SCRIPT" add "elso uzenet" >/dev/null
"$TEST_SCRIPT" add "masodik uzenet" >/dev/null
check "T2 count 2 ket add utan" "2" "$("$TEST_SCRIPT" count)"

echo "── T3: flush -- mindket tetel megjelenik, sorszamozva ──────────────────"
OUT="$("$TEST_SCRIPT" flush)"
check "T3 flush tartalmazza az elsot" "1" "$(printf '%s\n' "$OUT" | grep -c '1\. elso uzenet')"
check "T3 flush tartalmazza a masodikat" "1" "$(printf '%s\n' "$OUT" | grep -c '2\. masodik uzenet')"

echo "── T4 (BUKAS-ELoALLITAS): flush UTAN a sor URES -- ismetelt flush nem ad ki ujra ─"
check "T4 count 0 flush utan" "0" "$("$TEST_SCRIPT" count)"
OUT2="$("$TEST_SCRIPT" flush)"
check "T4 masodik flush URES-t jelez" "URES" "$OUT2"

echo "── T5: ismeretlen parancs -- hasznalati hiba, exit 1 ────────────────────"
"$TEST_SCRIPT" rossz-parancs >/dev/null 2>&1
check "T5 exit 1 ismeretlen parancsnal" "1" "$?"

echo
echo "═══════════════════════════════════════════════════════════════════════"
echo "  ✅ $PASS  ❌ $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Bukott esetek: ${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
