#!/usr/bin/env bash
# hu: Az `absence-check.sh` merooeszkoze. A karya (hamis-nulla-pozitiv-kontroll-20260806) negy
#     fuggetlen esetet mert, ahol egy hianyt allito grep NULLA talalata teves volt -- mert a mero
#     (minta/kapcsolo) vak volt, nem mert a dolog tenyleg hianyzott. A T1 a delphi-esetet
#     (CRLF-szamlalo a literal escape-szoveget kereste bajtok helyett) reprodukalja: ha a
#     pozitiv kontrollt UGYANAZZAL a (hibas) mechanizmussal valasztjuk, a kontroll IS 0-t ad,
#     es a szkriptnek PIROSAT kell adnia -- nem szabad zoldkent atengednie a hiany-allitast.
#
# 🛑 MUTACIO-ESET (T6): a kontroll-ellenorzo blokkot kivesszuk egy masolatbol, es elvarjuk, hogy
#    a T1 VISSZAJOJJON (a mutans hamisan HIANY IGAZOLVA-t adjon). Ha a mutans is piros marad, a
#    T1 vak -- nem a szkript kontroll-kenyszeritese mukodik.
#
# en: Measuring harness for absence-check.sh. T1 reproduces the delphi CRLF false-zero case;
#     T6 is a mutation test proving T1 actually exercises the control-enforcement logic.
#
# EXIT: 0 = minden eset a vart eredmenyt adta | 1 = legalabb egy eset elter

set -uo pipefail

CDir="$(cd "$(dirname "$0")" && pwd)"
CScript="$CDir/absence-check.sh"

FTmp=$(mktemp -d "${TMPDIR:-/tmp}/absence-check-teszt.XXXXXX")
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

# ── Fixture: valodi CRLF bajtok (0d0a), xxd-vel igazolva -- NEM a literal "\r\n" szoveg ────────
FFixture="$FTmp/crlf-fixture.txt"
printf 'first line\r\nsecond line\r\nMARKER third\r\nMARKER fourth\r\n' > "$FFixture"

echo "── T1 (a delphi-eset): mindket minta a HIBAS literal-escape mechanizmust hasznalja ─────"
# A celminta ('\r\n' szo szerint: backslash-r-backslash-n) SOHA nem talal valodi CRLF-et BSD
# grep-pel -- ez maga a mert bug. Ha a kontrollt UGYANEZZEL a mechanizmussal valasztjuk (azt
# allitva, hogy CRLF letezik a fajlban), annak IS 0-t kell adnia -- ez a helyes viselkedes.
"$CScript" "$FFixture" '\r\n' '\r\n' >"$FTmp/t1.out" 2>&1
rc=$?
check "T1 kilepesi kod 1 (KONTROLL BUKOTT)" "1" "$rc"
check "T1 kimenetben szerepel a KONTROLL BUKOTT jelzes" "1" \
  "$(grep -qi 'KONTROLL BUKOTT' "$FTmp/t1.out" && echo 1 || echo 0)"
check "T1 NEM allitja, hogy a hiany igazolva" "0" \
  "$(grep -qi 'HIANY IGAZOLVA' "$FTmp/t1.out" && echo 1 || echo 0)"

echo "── T2 (helyes hasznalat, valodi hiany): kontroll talal, celminta nem ─────────────────"
"$CScript" "$FFixture" 'NEM_LETEZO_MINTA_XYZ' 'MARKER' >"$FTmp/t2.out" 2>&1
rc=$?
check "T2 kilepesi kod 0 (HIANY IGAZOLVA)" "0" "$rc"
check "T2 kimenetben szerepel a pozitiv kontroll sor" "1" \
  "$(grep -qi 'pozitiv kontroll: MARKER -> 2' "$FTmp/t2.out" && echo 1 || echo 0)"

echo "── T3 (a celminta valojaban jelen van): a hiany-allitas HAMIS ─────────────────────────"
"$CScript" "$FFixture" 'MARKER' 'first' >"$FTmp/t3.out" 2>&1
rc=$?
check "T3 kilepesi kod 3 (JELEN VAN)" "3" "$rc"
check "T3 kimenetben szerepel a JELEN VAN jelzes" "1" \
  "$(grep -qi 'JELEN VAN' "$FTmp/t3.out" && echo 1 || echo 0)"

echo "── T4 (hasznalati hiba): hianyzo kontroll-parameter ───────────────────────────────────"
"$CScript" "$FFixture" 'MARKER' >"$FTmp/t4.out" 2>&1
rc=$?
check "T4 kilepesi kod 2 (HASZNALATI HIBA)" "2" "$rc"

echo "── T5 (hasznalati hiba): nem letezo fajl ───────────────────────────────────────────────"
"$CScript" "$FTmp/nemletezik-xyz.txt" 'x' 'y' >"$FTmp/t5.out" 2>&1
rc=$?
check "T5 kilepesi kod 2 (HASZNALATI HIBA)" "2" "$rc"

echo "── T6 (MUTACIO): a kontroll-ellenorzes kivetele -> a T1 BUKJON vissza ─────────────────"
CMutans="$FTmp/absence-check-mutans.sh"
awk '
  /^if \[ "\$FControlCount" -eq 0 \]; then/ { skip = 1 }
  !skip { print }
  skip && /^fi$/ { skip = 0; next }
' "$CScript" > "$CMutans"
chmod +x "$CMutans"
if cmp -s "$CScript" "$CMutans"; then
  echo "  ❌ T6 a mutacio NEM valtoztatott a szkripten -- a minta elavult, a T6 vak"
  FFail=$((FFail + 1))
else
  "$CMutans" "$FFixture" '\r\n' '\r\n' >"$FTmp/t6.out" 2>&1
  rc=$?
  check "T6 a mutansnal a T1-eset TEVESEN zoldet ad (HIANY IGAZOLVA)" "0" "$rc"
fi

echo
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "  ✅ $FPass  ❌ $FFail"
[ "$FFail" -eq 0 ] || exit 1
