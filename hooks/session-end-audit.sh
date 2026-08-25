#!/bin/bash
# hu: Stop hook — session-vége audit. A módosított fájlokban megnézi,
#     hogy nincsenek-e új TODO/FIXME/workaround/deferred minták, amiket a
#     többi hook esetleg kihagyott (pl. korábbi session-ből áthozott
#     állapot, vagy edge case).
# en: Stop hook — end-of-session audit. Greps modified files for new
#     TODO/FIXME/workaround/deferred markers that other hooks may have
#     missed (e.g., carried-over state, edge cases).

set -uo pipefail

# hu: Csak akkor, ha git repón belül vagyunk
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    exit 0
fi

# hu: Módosított fájlok a session során (HEAD-hez képest, staged + unstaged + untracked)
changed_files=$(git status --porcelain 2>/dev/null | awk '{print $NF}' | grep -vE '^$|\.md$|\.markdown$|\.txt$|\.log$|BuildNumberV2\.txt$|/Vault/|/docs/' | head -50)

if [ -z "$changed_files" ]; then
    exit 0
fi

pattern='workaround|\bTODO\b|\bFIXME\b|\bHACK\b|\bXXX\b|\bdeferred\b|known[[:space:]]+bug|ismert[[:space:]]+bug|majd[[:space:]]+kés[őo]bb'

findings=""
while IFS= read -r file; do
    [ -f "$file" ] || continue
    matches=$(grep -niE "$pattern" "$file" 2>/dev/null | head -3)
    if [ -n "$matches" ]; then
        findings="$findings
$file:
$matches
"
    fi
done <<< "$changed_files"

if [ -z "$findings" ]; then
    exit 0
fi

cat >&2 <<EOF
[hook: session-end-audit] FIGYELMEZTETÉS

A session során módosított kódfájlokban TODO/FIXME/workaround/deferred minták:
$findings

Ezek szándékosak? Ha igen, érdemes:
  • Vault-bejegyzést írni róluk (Projects/<projekt>/Bug-Debug-Log/)
  • Roadmap-be felvett külön taszk
  • Vagy a hook-ot kifejezetten override-olni a felhasználói jóváhagyással
EOF

# hu: A Stop hookok nem blokkolnak — csak jelzünk
exit 0
