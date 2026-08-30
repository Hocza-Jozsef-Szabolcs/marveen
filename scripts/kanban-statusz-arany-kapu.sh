#!/usr/bin/env bash
# hu: A napi-db-mentes heartbeat statusz-arany ellenorzese. A regi szabaly ("egyetlen statusz a
#     kartyak 90%-a folott") egy erett, javareszt lezart kanban-tablan STRUKTURALISAN mindig igazza
#     valik -- a done-arany csak nohet, ahogy a kartyak lezarulnak (mert teny 2026-08-30: 1051/1130
#     = 93,0%, miutan minden fuggetlen jelzo -- cim-arany, id-cim, archivalt, komment/memoria --
#     tiszta volt). Ez a kapu ezert nem az ABSZOLUT aranyt nezi, hanem a NAPI UGRAST a
#     `backup-metrics.jsonl` ket legutobbi sora kozott: egy tomeges statusz-felulirás egyetlen nap
#     alatt sokkal nagyobb ugrast okoz, mint a szokasos kartya-lezarasi utem.
#
# en: Status-ratio gate for the napi-db-mentes heartbeat. Alerts on a large day-over-day jump in
#     the dominant status's share (or a dominant-status name change landing high), not on its
#     absolute level -- a mature table's ratio only grows.
#
# Bemenet: KSAK_METRICS env (alap: store/backup-metrics.jsonl), amelynek sorai
#          "statusz_dominans_nev" es "statusz_dominans_arany" mezot tartalmaznak.
# Kimenet: "OK ..." vagy "ALERT: ..." az elso sorban, stdoutra. EXIT mindig 0 -- ez jelzo, nem
#          folyamat-megszakito kapu; a hivo dontse el, mit kezd az "ALERT"-tel kezdodo szoveggel.
# Kuszob: KSAK_UGRAS_KUSZOB env (alap: 15) -- ennyi SZAZALEKPONT napi ugras felett ALERT.

set -uo pipefail

FMetrics="${KSAK_METRICS:-$(cd "$(dirname "$0")/.." && pwd)/store/backup-metrics.jsonl}"
FKuszob="${KSAK_UGRAS_KUSZOB:-15}"

if [ ! -f "$FMetrics" ]; then
  echo "OK -- nincs meg metrika-fajl, nincs mihez viszonyitani"
  exit 0
fi

FSorok=$(wc -l < "$FMetrics" | tr -d ' ')
if [ "$FSorok" -lt 2 ]; then
  echo "OK -- egyetlen mert nap van, nincs elozo ertek az ugras-szamitashoz"
  exit 0
fi

FUtolso=$(tail -1 "$FMetrics")
FElozo=$(tail -2 "$FMetrics" | head -1)

python3 - "$FUtolso" "$FElozo" "$FKuszob" <<'PYEOF'
import json
import sys

utolso = json.loads(sys.argv[1])
elozo = json.loads(sys.argv[2])
kuszob = float(sys.argv[3])

nev_u = utolso.get("statusz_dominans_nev")
arany_u = utolso.get("statusz_dominans_arany")
nev_e = elozo.get("statusz_dominans_nev")
arany_e = elozo.get("statusz_dominans_arany")

if nev_u is None or arany_u is None:
    print(f"OK -- a legutolso sorban nincs statusz_dominans mezo, nincs mit ellenorizni")
    sys.exit(0)

if nev_e is None or arany_e is None:
    print(f"OK -- az elozo sorban meg nincs statusz_dominans mezo, nincs viszonyitasi alap (ma: {nev_u} {arany_u}%)")
    sys.exit(0)

if nev_u != nev_e and arany_u >= 90:
    print(f"ALERT: a dominans statusz megvaltozott ({nev_e} -> {nev_u}), es az uj dominans mar {arany_u}%-on all")
    sys.exit(0)

ugras = arany_u - arany_e
if ugras > kuszob:
    print(f"ALERT: a(z) '{nev_u}' statusz aranya egy nap alatt {arany_e}%-rol {arany_u}%-ra ugrott (+{ugras:.1f} szazalekpont, kuszob: {kuszob})")
    sys.exit(0)

print(f"OK -- '{nev_u}' statusz aranya {arany_e}% -> {arany_u}% ({ugras:+.1f} szazalekpont, kuszob alatt)")
PYEOF
