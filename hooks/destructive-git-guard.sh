#!/bin/bash
# hu: PreToolUse hook — blokkolja a visszafordíthatatlan git/fájl-eldobó
#     parancsokat (git restore, git checkout -- <path>, git clean -f, git
#     reset --hard), HA az eldobandó tartalom nincs elmentve git stash-be.
#     Eredet: 2026-07-22, QuantumAE — egy uncommitted, sosem git-add-olt
#     módosítást `git restore` + `rm`-mel véglegesen eldobtam; kiderült, hogy
#     az egy párhuzamos session valós, folyamatban lévő munkája volt, és
#     sehol nem volt visszaállítható (lásd Vault/Shared/
#     never-destructively-discard-uncommitted-changes.md).
#     A döntési logika: destructive_git_guard.py (tokenizált felismerés, hogy
#     a `git -C <út>` alak se csússzon át, és blob-hash szintű fedettség-mérés
#     a stash-ekben). Mérő: Marveen/scripts/test-destructive-git-guard.sh
# en: PreToolUse hook — blocks irreversible git/file-discard commands unless
#     the content about to be discarded is actually present in a git stash.
#     Decision logic lives in destructive_git_guard.py; test suite in
#     Marveen/scripts/test-destructive-git-guard.sh

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGIC="$HOOK_DIR/destructive_git_guard.py"

input=$(cat)

if [ ! -f "$LOGIC" ]; then
    # hu: A logika hiányzik — a kapu nem tud mérni. FAIL-CLOSED: ha a parancs
    #     veszélyes igét tartalmaz, blokkolunk. Az ördög mérte ki (2026-08-14),
    #     hogy a korábbi `exit 0` itt csendben átengedte a `git clean -fd`-t egy
    #     piszkos repóban: egy stderr-figyelmeztetést nem biztos, hogy bárki olvas,
    #     a végrehajtott törlés viszont visszafordíthatatlan.
    if printf '%s' "$input" | grep -qE '\b(restore|checkout|clean|reset)\b'; then
        echo "[hook: destructive-git-guard] BLOCK — hiányzik a döntési logika ($LOGIC)," >&2
        echo "  és a parancs veszélyes igét tartalmaz. Fail-closed: nem engedem át." >&2
        exit 2
    fi

    echo "[hook: destructive-git-guard] FIGYELEM: hiányzik a döntési logika ($LOGIC) — a kapu NEM véd." >&2
    exit 0
fi

# hu: Olcsó előszűrő — a hook MINDEN Bash-híváskor lefut, a python indítása
#     ~100 ms. Aminek a szövegében nincs "git", az nem tud git-tartalmat
#     eldobni, tehát a python el sem indul. A hatókört ez NEM szűkíti: a
#     felismerés amúgy is a parancs szövegére épül.
if ! printf '%s' "$input" | grep -q 'git'; then
    exit 0
fi

printf '%s' "$input" | python3 "$LOGIC"
exit $?
