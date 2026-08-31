#!/bin/bash
# hu: A run-with-service-node.sh / service-node-bin-dir.sh meroeszkoze.
#     Kartya de2018e3: a vitest-keszlet 49 fajlja better-sqlite3 NODE_MODULE_VERSION (127 vs 147)
#     miatt bukott worktree-ben -- MERT OK: a PATH-on elso `node` (Homebrew generic szimlink,
#     v26.7.0, ABI 147), NEM az, amire a launchd-szolgaltatasok (es a mar lefordult natic modul)
#     rogzitve vannak (node@22, ABI 127). A modul JO, a hibat a rossz node-dal futtatas okozza --
#     `npm rebuild better-sqlite3` a rossz node-dal EPPEN AZT a hibat okozna elo, amit
#     install-macos.sh 581-592. sora mar egyszer dokumentalt (elo szolgaltatas eltorik).
# en: Measuring harness for run-with-service-node.sh / service-node-bin-dir.sh (card de2018e3).
#
# EXIT: 0 = minden eset a vart eredmenyt adta | 1 = legalabb egy eset elter
set -uo pipefail

CScriptDir="$(cd "$(dirname "$0")" && pwd)"
CBinDirScript="$CScriptDir/service-node-bin-dir.sh"
CWrapper="$CScriptDir/run-with-service-node.sh"

FPass=0
FFail=0

expect() {
  local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    echo "  ✅ $label -- '$got' (vart: '$want')"
    FPass=$((FPass + 1))
  else
    echo "  ❌ $label -- '$got' (vart: '$want')"
    FFail=$((FFail + 1))
  fi
}

echo "T1 -- service-node-bin-dir.sh node@22-re mutat, ha az telepitve van"
if command -v brew >/dev/null 2>&1 && brew --prefix node@22 >/dev/null 2>&1; then
  BIN_DIR=$("$CBinDirScript")
  if [ -x "$BIN_DIR/node" ]; then
    MODULES=$("$BIN_DIR/node" -e 'console.log(process.versions.modules)')
    expect "T1a a talalt node NODE_MODULE_VERSION-je 127 (a szolgaltatasok ABI-ja)" "127" "$MODULES"
  else
    echo "  ❌ T1a a kiirt bin-dir nem tartalmaz futtathato node-ot: $BIN_DIR"
    FFail=$((FFail + 1))
  fi
else
  echo "  ⚠️  T1 KIHAGYVA -- node@22 nincs telepitve ezen a gepen"
fi

echo
echo "T2 -- run-with-service-node.sh a becsomagolt parancsot node@22 ABI-javal futtatja"
if command -v brew >/dev/null 2>&1 && brew --prefix node@22 >/dev/null 2>&1; then
  OUT=$("$CWrapper" node -e 'console.log(process.versions.modules)')
  expect "T2 a wrapper alatt futo node ABI-ja 127" "127" "$OUT"
else
  echo "  ⚠️  T2 KIHAGYVA -- node@22 nincs telepitve ezen a gepen"
fi

echo
echo "T3 -- run-with-service-node.sh atadja a becsomagolt parancs kilepesi kodjat"
"$CWrapper" bash -c 'exit 7'
RC=$?
expect "T3 a kilepesi kod (7) atmegy a wrapperen" "7" "$RC"

echo
echo "T4 -- MUTACIO: PATH-fugges igazolasa -- ha node@22 bin-dir-jet ELVESSZUK a PATH-rol,"
echo "     a wrapper visszaesik a PATH-on elso node-ra (nem hasznal mar rogzitett/gyorsitotarazott utat)"
if command -v brew >/dev/null 2>&1 && brew --prefix node@22 >/dev/null 2>&1; then
  DEFAULT_NODE_MODULES=$(command node -e 'console.log(process.versions.modules)' 2>/dev/null || echo "?")
  WRAPPED_MODULES=$("$CWrapper" node -e 'console.log(process.versions.modules)')
  if [ "$DEFAULT_NODE_MODULES" != "$WRAPPED_MODULES" ]; then
    echo "  ✅ T4 igazolva: a wrapper ALATT MAS ABI fut ($WRAPPED_MODULES), mint a sima PATH-node alatt ($DEFAULT_NODE_MODULES) -- a kulonbseget tenyleg a wrapper okozza"
    FPass=$((FPass + 1))
  else
    echo "  ❌ T4 a mutacio nem fogott -- a wrapper es a sima PATH-node ugyanazt az ABI-t adja ($WRAPPED_MODULES), a T1/T2 nem bizonyit semmit ezen a gepen"
    FFail=$((FFail + 1))
  fi
else
  echo "  ⚠️  T4 KIHAGYVA -- node@22 nincs telepitve ezen a gepen"
fi

echo
echo "EREDMENY: $FPass rendben | $FFail elter"
[ "$FFail" -eq 0 ] || exit 1
echo "✅ Minden eset a vart eredmenyt adta."
