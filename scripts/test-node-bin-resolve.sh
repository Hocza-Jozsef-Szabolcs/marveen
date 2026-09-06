#!/usr/bin/env bash
# hu: A `scripts/node-bin.sh` resolve_node_bin() fuggvenyet meri. A kartya
#     channel-state-dir-per-install-20260831 UJ lelete (Jarvis, 2026-09-02):
#     launchd alol a PATH gyakran nem tartalmazza a node konyvtarat, es a
#     korabbi `command -v node` hivas ilyenkor csendben ures stringet adott --
#     ezert az azt hasznalo CLAUDE_CONFIG_DIR-elkulonites feloldasa is
#     nesztelenul kimaradt. T1 a normal (PATH-bol talalhato) esetet fedi, T2 a
#     PATH-fuggetlen fallback-agat, T3 a teljes sikertelenseg esetet (sem PATH,
#     sem jelolt nem talal node-ot -- ures kimenet, nemnulla kilepokod).
#
# 🛑 MUTACIO-ESET (T4): a fallback-agat (a jelolt-lista bejarasat) egy
#    masolatban semlegesitjuk, es elvarjuk, hogy T2 VISSZAJOJJON hibasan
#    (ures kimenettel terjen vissza annak ellenere, hogy van elerheto
#    jelolt). Ha a mutans is helyesen talalja meg a jeloltet, T2 vak.
#
# en: Measuring harness for scripts/node-bin.sh's resolve_node_bin(). T1
#     covers the PATH-resolved case, T2 the PATH-independent fallback (the new
#     finding from card channel-state-dir-per-install-20260831), T3 total
#     failure (neither PATH nor any candidate finds node). T4 is a mutation
#     test proving T2 actually exercises the fallback loop, not something else.
#
# EXIT: 0 = minden eset a vart eredmenyt adta | 1 = legalabb egy eset elter

set -uo pipefail

CDir="$(cd "$(dirname "$0")" && pwd)"
CLib="$CDir/node-bin.sh"
InstallDir="$(cd "$CDir/.." && pwd)"
CChannels="$CDir/channels.sh"

# shellcheck source=/dev/null
. "$CLib"

FTmp=$(mktemp -d "${TMPDIR:-/tmp}/node-bin-resolve-teszt.XXXXXX")
trap 'rm -rf "$FTmp"' EXIT

FPass=0
FFail=0

check() {
  local nev="$1" vart="$2" kapott="$3"

  if [ "$vart" = "$kapott" ]; then
    echo "  ✅ $nev"
    FPass=$((FPass + 1))
  else
    echo "  ❌ $nev -- vart: [$vart], kapott: [$kapott]"
    FFail=$((FFail + 1))
  fi
}

# --- fixture-ek ---------------------------------------------------------
FPathBin="$FTmp/pathbin"
mkdir -p "$FPathBin"
cat > "$FPathBin/node" <<'EOF'
#!/bin/sh
echo "stub-node"
EOF
chmod +x "$FPathBin/node"

FFallbackNode="$FTmp/fallback-home/.local/bin/node"
mkdir -p "$(dirname "$FFallbackNode")"
printf '#!/bin/sh\necho stub\n' > "$FFallbackNode"
chmod +x "$FFallbackNode"

NoPath="$FTmp/nincs-ilyen-konyvtar-802"

echo "── T1 PATH-bol talalhato node -- a command -v ag gyoz ─────────────────────────"
out="$(PATH="$FPathBin:/usr/bin:/bin" resolve_node_bin)"
check "T1 a PATH-beli stub node utvonalat adja" "$FPathBin/node" "$out"

echo "── T2 PATH nem talal node-ot -- a fallback-jelolt gyoz ─────────────────────────"
out="$(PATH="$NoPath" NODE_BIN_CANDIDATES="$FFallbackNode" resolve_node_bin)"
check "T2 a fallback-jelolt utvonalat adja" "$FFallbackNode" "$out"

echo "── T3 sem PATH, sem jelolt nem talal node-ot -- ures kimenet, hibakod ──────────"
out="$(PATH="$NoPath" NODE_BIN_CANDIDATES="$FTmp/nincs1/node $FTmp/nincs2/node" resolve_node_bin)"
rc=$?
check "T3 kimenet ures" "" "$out"
check "T3 nemnulla kilepokod" "1" "$rc"

echo "── T4 (MUTACIO): a fallback-jelolt bejarasat semlegesitjuk -> T2 BUKJON vissza ─"
CMutans="$FTmp/node-bin-mutans.sh"
awk '
  /if \[ -x "\$candidate" \]; then/ { print "    if [ -x \"/nincs-ilyen-utvonal-soha-802\" ]; then"; next }
  { print }
' "$CLib" > "$CMutans"
if cmp -s "$CLib" "$CMutans"; then
  echo "  ❌ T4 a mutacio NEM valtoztatott a szkripten -- a minta elavult, a T4 vak"
  FFail=$((FFail + 1))
else
  (
    unset -f resolve_node_bin
    # shellcheck source=/dev/null
    . "$CMutans"
    PATH="$NoPath" NODE_BIN_CANDIDATES="$FFallbackNode" resolve_node_bin
  ) >"$FTmp/t4.out" 2>/dev/null
  check "T4 a mutansnal T2 kimenete ures (a fallback nem talal semmit)" "" "$(cat "$FTmp/t4.out")"
fi

echo "── T5 channels.sh --resolve-node-bin -- a hivo tenylegesen ezt a fuggvenyt hasznalja ─"
# hu: node NELKULI, de egyebkent hasznalhato PATH (a channels.sh setup-resze
#     grep/sed/mkdir-t hasznal a seam elereseig) -- a NoPath-al ellentetben ez
#     nem a teljes szkript-inditast akadalyozza, csak a node-keresest.
out="$(PATH="/usr/bin:/bin" NODE_BIN_CANDIDATES="$FFallbackNode" bash "$CChannels" --resolve-node-bin 2>/dev/null)"
check "T5 channels.sh a fallback-jelolt utvonalat adja vissza" "$FFallbackNode" "$out"

echo "── T6 (MUTACIO): channels.sh visszaallitva nyers 'command -v node'-ra -> T5 BUKJON ─"
CChannelsMutans="$FTmp/channels-mutans.sh"
sed 's/_node_bin="\$(resolve_node_bin || true)"/_node_bin="$(command -v node || true)"/' \
  "$CChannels" > "$CChannelsMutans"
if cmp -s "$CChannels" "$CChannelsMutans"; then
  echo "  ❌ T6 a mutacio NEM valtoztatott a szkripten -- a minta elavult, a T6 vak"
  FFail=$((FFail + 1))
else
  chmod +x "$CChannelsMutans"
  out="$(PATH="/usr/bin:/bin" NODE_BIN_CANDIDATES="$FFallbackNode" bash "$CChannelsMutans" --resolve-node-bin 2>/dev/null)"
  check "T6 a mutans nyers command -v node-ja ures kimenetet ad (a fallback nem fut le)" "" "$out"
fi

echo "── T7 channel-watchdog.sh -- ugyanaz a CFG_ENV-felodas, ugyanaz a fix kell ─────"
# hu: channel-watchdog.sh a channels.sh-eval AZONOS izolalt-config feloldast
#     ismetli meg (respawn-eskor), tehat ugyanaz a hibaosztaly. Nincs sajat
#     tesztkeretrendszere (nulla meglevo teszt-fajl a fejlesztes elott), ezert
#     itt strukturalis ellenorzes: forrasazza-e a lib-et, es NEM marad-e
#     nyers `command -v node` a NODE_BIN-feloldasban.
CWatchdog="$CDir/channel-watchdog.sh"
check "T7 channel-watchdog.sh forrasazza a node-bin.sh-t" "1" \
  "$(grep -qE '^\. "\$INSTALL_DIR/scripts/node-bin\.sh"' "$CWatchdog" && echo 1 || echo 0)"
check "T7 channel-watchdog.sh resolve_node_bin-t hasznal NODE_BIN-hez, nem nyers command -v node-ot" "1" \
  "$(grep -qE '^NODE_BIN="\$\(resolve_node_bin \|\| true\)"' "$CWatchdog" && echo 1 || echo 0)"

echo
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "  ✅ $FPass  ❌ $FFail"
[ "$FFail" -eq 0 ] || exit 1
