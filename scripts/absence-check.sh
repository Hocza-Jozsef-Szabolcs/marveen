#!/usr/bin/env bash
# hu: Mechanikus pozitiv-kontroll kenyszerito eszkoz HIANY-allitasokhoz (egy grep "0 talalat"
#     eredmenyebol "nincs X" allitas kovetkezik). A hianyt allito kereses ONMAGABAN nem
#     bizonyitek: ha a mero (minta, kapcsolo, kodolas, eszkoz) vak, a nulla nem a valosagot,
#     hanem a mero hibajat tukrozi (kartya: hamis-nulla-pozitiv-kontroll-20260806 -- negy
#     fuggetlen fej negy fuggetlen hamis nullaja egyetlen nap alatt).
#
#     A szkript EGYUTT, KOTELEZoEN ket mintat var: a HIANYZONAK ALLITOTT mintat es egy POZITIV
#     KONTROLLT, amirol bizonyosan tudni kell, hogy MEGVAN a fajlban. Ha a kontroll NEM talal,
#     a mero vak -- a szkript PIROSAT ad, meg akkor is, ha a celminta is 0-t adna. A kontrollnak
#     UGYANAZT a keresesi mechanizmust (minta-tipus, grep-opciok) kell hasznalnia, mint a
#     celmintanak -- ha a kontroll a hianyzo mintaeval AZONOS (hibas) technikaval keres, a
#     hiba maga buktatja le a kontrollt.
#
# en: Mechanical positive-control enforcer for absence claims (grep "0 hits" => "X is missing").
#     Requires two patterns together: the pattern claimed absent, and a control pattern known
#     to exist. If the control finds nothing, the tool refuses to confirm absence -- a silent
#     zero from a broken search technique is not a "not found" result.
#
# HASZNALAT / USAGE:
#   absence-check.sh <fajl> <hianyzo_minta> <pozitiv_kontroll_minta> [grep-opciok...]
#
# KILEPESI KODOK / EXIT CODES:
#   0 = HIANY IGAZOLVA    -- a kontroll talalt, a celminta nem (az allitas alatamasztott)
#   1 = KONTROLL BUKOTT   -- a kontroll NEM talalt -- a mero vak, a hiany NEM igazolhato
#   2 = HASZNALATI HIBA   -- hianyzo/ervenytelen parameter
#   3 = JELEN VAN         -- a kontroll talalt, DE a celminta IS talalt -- a hiany-allitas HAMIS

set -uo pipefail

if [ $# -lt 3 ]; then
  echo "hasznalat: absence-check.sh <fajl> <hianyzo_minta> <pozitiv_kontroll_minta> [grep-opciok...]" >&2
  exit 2
fi

FFile="$1"
FTargetPattern="$2"
FControlPattern="$3"
shift 3
FExtra=("$@")

if [ ! -f "$FFile" ]; then
  echo "HASZNALATI HIBA: a fajl nem letezik: $FFile" >&2
  exit 2
fi

# 🛑 A "${FExtra[@]+"${FExtra[@]}"}" alak KOTELEZo `set -u` mellett: ures tomb kifejtese
#    (`${FExtra[@]}`) bash 3.2-n (macOS alapertelmezett) "unbound variable"-lel bukik, ha nincs
#    ez a fallback-idioma -- pedig az extra grep-opciok tobbnyire nincsenek megadva.
FControlCount=$(grep -c "${FExtra[@]+"${FExtra[@]}"}" -- "$FControlPattern" "$FFile")
FControlCount=${FControlCount:-0}

if [ "$FControlCount" -eq 0 ]; then
  echo "KONTROLL BUKOTT: a pozitiv kontroll minta ('$FControlPattern') NEM talalhato $FFile-ban -- a mero vak, a hiany-allitas NEM igazolhato."
  echo "pozitiv kontroll: $FControlPattern -> 0 talalat"
  exit 1
fi

FTargetCount=$(grep -c "${FExtra[@]+"${FExtra[@]}"}" -- "$FTargetPattern" "$FFile")
FTargetCount=${FTargetCount:-0}

echo "pozitiv kontroll: $FControlPattern -> $FControlCount talalat"

if [ "$FTargetCount" -eq 0 ]; then
  echo "HIANY IGAZOLVA: '$FTargetPattern' -> 0 talalat $FFile-ban (a mero bizonyitottan mukodik ezen a fajlon)."
  exit 0
fi

echo "JELEN VAN: '$FTargetPattern' -> $FTargetCount talalat $FFile-ban -- a hiany-allitas HAMIS."
exit 3
