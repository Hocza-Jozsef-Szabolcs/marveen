#!/bin/bash
# hu: A launchd-szolgaltatasok (dashboard, channels) node@22-re vannak rogzitve
#     (install-macos.sh resolve_service_node, 593-618. sor), mert a Homebrew generic `node`
#     szimlink barmikor uj majorra frissulhet, ami ELToRI a mar lefordult better-sqlite3 natic
#     modult (NODE_MODULE_VERSION-eltere -- lasd install-macos.sh 581-592, mar egyszer megtortent
#     eset). Ez a szkript UGYANAZT az utat adja vissza, hogy a teszt-futtatas is ugyanazt az ABI-t
#     lassa, mint az elo szolgaltatas -- kulonben a hiba UGY nez ki, mintha a modult kellene
#     ujraforditani, pedig csak a rossz node-dal futtattak.
# en: The launchd services are pinned to node@22 (install-macos.sh resolve_service_node) because
#     Homebrew's generic `node` symlink can auto-upgrade to a new major that breaks the already-
#     built better-sqlite3 native module. This script returns the same path so tests see the same
#     ABI as the live service.
#
# KIMENET: a node@22 bin konyvtaranak utvonala stdout-ra, exit 0.
# HIBA: figyelmeztetes stderr-re, exit 1 -- a hivo dontse el, mit kezd a hianyzo node@22-vel
#       (a run-with-service-node.sh wrapper pl. tovabb fut a PATH-on levo node-dal).
set -uo pipefail

prefix="$(brew --prefix node@22 2>/dev/null)"

if [ -n "$prefix" ] && [ -x "$prefix/bin/node" ]; then
  echo "$prefix/bin"
  exit 0
fi

echo "service-node-bin-dir.sh: node@22 nem talalhato (brew --prefix node@22) -- a hivo a PATH-on levo node-ot fogja hasznalni, ami eltero ABI-t adhat a szolgaltatasokehoz kepest." >&2
exit 1
