#!/usr/bin/env bash
# hu: A `kanban-statusz-arany-kapu.sh` merooeszkoze (kartya #0238dc3f). A napi-db-mentes heartbeat
#     regi szabalya ("egyetlen statusz a kartyak 90%-a folott") 2026-08-30-an elavultnak
#     bizonyult: egy erett, javareszt lezart kanban-tablan a `done` arany strukturalisan CSAK
#     nohet, tehat a statikus kuszob mostantol MINDEN nap igazat adna. A T1/T2 par ezt a ket
#     esetet valasztja szet: erett tabla lassu novekedese (NEM ALERT) vs egynapi tomeges
#     statusz-felulirás (ALERT). A T3 a dominans statusz NEVENEK valtasat fedi (pl. tomeges
#     `waiting`->`done` atirás magas aranyra ugorva akkor is ALERT, ha a szazalekpont-ugras
#     onmagaban a kuszob alatt maradna).
#
# en: Measuring harness for kanban-statusz-arany-kapu.sh. Splits the mature-table (no alert) case
#     from the mass-overwrite (alert) case, plus a dominant-status-name-change case.
#
# EXIT: 0 = minden eset a vart eredmenyt adta | 1 = legalabb egy eset elter

set -uo pipefail

CDir="$(cd "$(dirname "$0")" && pwd)"
CScript="$CDir/kanban-statusz-arany-kapu.sh"

FTmp=$(mktemp -d "${TMPDIR:-/tmp}/kanban-statusz-arany-kapu-teszt.XXXXXX")
trap 'rm -rf "$FTmp"' EXIT

FPass=0
FFail=0

check() {
  local nev="$1" vart_prefix="$2" kapott="$3"

  if [[ "$kapott" == "$vart_prefix"* ]]; then
    echo "  OK    $nev"
    FPass=$((FPass + 1))
  else
    echo "  BUKIK $nev -- vart eleje: [$vart_prefix], kapott: [$kapott]"
    FFail=$((FFail + 1))
  fi
}

echo "── T0: nincs metrika-fajl -- OK, nincs mihez viszonyitani ──"
OUT="$(KSAK_METRICS="$FTmp/nincs.jsonl" bash "$CScript")"
check "T0 OK fajl hianyaban" "OK" "$OUT"

echo "── T1: egyetlen mert nap -- OK, nincs elozo ertek ──"
FEgySoros="$FTmp/egysoros.jsonl"
echo '{"measured_at":"2026-08-30T04:00:00+0200","statusz_dominans_nev":"done","statusz_dominans_arany":93.0}' > "$FEgySoros"
OUT="$(KSAK_METRICS="$FEgySoros" bash "$CScript")"
check "T1 OK egyetlen sorral" "OK" "$OUT"

echo "── T2: erett tabla, lassu novekedes (92.9% -> 93.0%) -- NEM ALERT ──"
FErett="$FTmp/erett.jsonl"
{
  echo '{"measured_at":"2026-08-29T04:00:00+0200","statusz_dominans_nev":"done","statusz_dominans_arany":92.9}'
  echo '{"measured_at":"2026-08-30T04:00:00+0200","statusz_dominans_nev":"done","statusz_dominans_arany":93.0}'
} > "$FErett"
OUT="$(KSAK_METRICS="$FErett" bash "$CScript")"
check "T2 OK erett tablan" "OK" "$OUT"

echo "── T3: tomeges felulirás, ugyanaz a nev, nagy napi ugras (40% -> 95%) -- ALERT ──"
FTomeges="$FTmp/tomeges.jsonl"
{
  echo '{"measured_at":"2026-08-29T04:00:00+0200","statusz_dominans_nev":"done","statusz_dominans_arany":40.0}'
  echo '{"measured_at":"2026-08-30T04:00:00+0200","statusz_dominans_nev":"done","statusz_dominans_arany":95.0}'
} > "$FTomeges"
OUT="$(KSAK_METRICS="$FTomeges" bash "$CScript")"
check "T3 ALERT nagy napi ugrasnal" "ALERT" "$OUT"

echo "── T4: dominans statusz NEVE valt, es az uj nev mar magas aranyon all -- ALERT ──"
FNevvaltas="$FTmp/nevvaltas.jsonl"
{
  echo '{"measured_at":"2026-08-29T04:00:00+0200","statusz_dominans_nev":"waiting","statusz_dominans_arany":30.0}'
  echo '{"measured_at":"2026-08-30T04:00:00+0200","statusz_dominans_nev":"done","statusz_dominans_arany":93.0}'
} > "$FNevvaltas"
OUT="$(KSAK_METRICS="$FNevvaltas" bash "$CScript")"
check "T4 ALERT nevvaltasnal" "ALERT" "$OUT"

echo "── T5: elozo sorban meg nincs statusz_dominans mezo (migracio elotti nap) -- OK ──"
FRegiFormatum="$FTmp/regi-formatum.jsonl"
{
  echo '{"measured_at":"2026-08-29T04:00:00+0200","kartya_osszes":1100}'
  echo '{"measured_at":"2026-08-30T04:00:00+0200","statusz_dominans_nev":"done","statusz_dominans_arany":93.0}'
} > "$FRegiFormatum"
OUT="$(KSAK_METRICS="$FRegiFormatum" bash "$CScript")"
check "T5 OK regi formatumu elozo soron" "OK" "$OUT"

echo "── T6: kis napi ingadozas, kuszob alatt (10% -> 24%, kuszob 15) -- NEM ALERT ──"
FKisIngadozas="$FTmp/kis-ingadozas.jsonl"
{
  echo '{"measured_at":"2026-08-29T04:00:00+0200","statusz_dominans_nev":"done","statusz_dominans_arany":10.0}'
  echo '{"measured_at":"2026-08-30T04:00:00+0200","statusz_dominans_nev":"done","statusz_dominans_arany":24.0}'
} > "$FKisIngadozas"
OUT="$(KSAK_METRICS="$FKisIngadozas" KSAK_UGRAS_KUSZOB=15 bash "$CScript")"
check "T6 OK kuszob alatti napi ugrasnal" "OK" "$OUT"

echo
echo "Osszesen: $FPass OK, $FFail BUKIK"
[ "$FFail" -eq 0 ]
