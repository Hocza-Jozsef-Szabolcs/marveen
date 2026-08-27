#!/bin/bash
# hu: Futtatja a kapott parancsot a launchd-szolgaltatasok node@22-jevel, ha az elerheto --
#     kulonben figyelmeztet es a PATH-on levo node-dal folytatja (nem allitja meg a hivot). Ezt
#     hasznalja az `npm test`, hogy a vitest-keszlet UGYANAZT az ABI-t lassa, mint az elo
#     szolgaltatas -- kartya de2018e3: enelkul egy worktree-ben futtatott teszt a PATH-on elso
#     (Homebrew generic, gyakran ujabb major) node-ot kapja, ami NODE_MODULE_VERSION-hibaval bukik
#     a mar node@22-re lefordult better-sqlite3-on. `npm rebuild better-sqlite3` a rossz node-dal
#     futtatva EZT a hibat okozna elo, csak forditva -- lasd install-macos.sh 581-592.
# en: Runs the given command with the launchd services' node@22 if available -- otherwise warns
#     and continues with whatever node is on PATH. Used by `npm test` so the suite sees the same
#     ABI as the live service.
#
# HASZNALAT: scripts/run-with-service-node.sh <parancs> [argumentumok...]
set -uo pipefail

CScriptDir="$(cd "$(dirname "$0")" && pwd)"

if BIN_DIR="$("$CScriptDir/service-node-bin-dir.sh" 2>&2)"; then
  PATH="$BIN_DIR:$PATH"
fi

exec "$@"
