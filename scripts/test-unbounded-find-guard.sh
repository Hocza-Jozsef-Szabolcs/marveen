#!/bin/bash
# hu: Bukas-eloallito teszt a ~/.claude/hooks/unbounded-find-guard.sh hookhoz.
#     A hook egy KAPU: sajat magat nem igazolhatja, ezert minden eset a hivas
#     JSON-payloadjan mer, es a POZITIV KONTROLL (amit at KELL engednie) is
#     benne van.
# en: Failure-producing test suite for the unbounded-find-guard PreToolUse
#     hook. The hook is a gate: every case runs against a synthetic payload,
#     and the positive controls (commands it MUST let through) are part of
#     the suite.

set -uo pipefail

HOOK="${HOOK_PATH:-$HOME/.claude/hooks/unbounded-find-guard.sh}"
PASS=0
FAIL=0
FAILED_NAMES=()

if [ ! -x "$HOOK" ]; then
    echo "HIBA: a hook nem futtathato: $HOOK" >&2
    exit 1
fi

# hu: Egy eset lefuttatasa. $1=nev, $2=elvart exit (0=atenged, 2=blokk),
#     $3=parancs
run_case() {
    local name="$1" expected="$2" command="$3"
    local payload actual

    payload=$(COMMAND="$command" python3 -c '
import json, os
print(json.dumps({"tool_name": "Bash",
                  "tool_input": {"command": os.environ["COMMAND"]}}))')

    echo "$payload" | "$HOOK" >/dev/null 2>&1
    actual=$?

    if [ "$actual" -eq "$expected" ]; then
        PASS=$((PASS + 1))
        printf '  ok    %-58s (exit %d)\n' "$name" "$actual"
    else
        FAIL=$((FAIL + 1))
        FAILED_NAMES+=("$name")
        printf '  BUKIK %-58s (vart %d, kapott %d)\n' "$name" "$expected" "$actual"
    fi
}

BLOCK=2
ALLOW=0

echo "=== A) A HAROM BIZONYITOTT RUNAWAY-MINTA (2026-08-17 ejszaka) -- blokkolva ==="
run_case "find / -name fleet.py (ordog)"          $BLOCK 'find / -name "fleet.py"'
run_case "bfs / -name fleet.py (akka 1.)"         $BLOCK 'bfs / -name "fleet.py"'
run_case "bfs / -iname SQLite-net.dll (akka 2.)"  $BLOCK 'bfs / -iname "SQLite-net.dll"'

echo "=== B) TOVABBI BIZONYITOTT MINTA (negyedik elofordulas, avalonia) ==="
run_case "find / -iname hu.json (avalonia)"       $BLOCK 'find / -iname "hu.json"'

echo "=== C) HOME-BOL INDULO VARIANSOK (a kartya 3. pontja szerint) ==="
run_case "find ~ (bare home)"                     $BLOCK 'find ~ -name "secrets.env"'
run_case "find \$HOME (env-valtozo, literal)"     $BLOCK 'find $HOME -name "x"'
run_case "bfs ~/ (trailing slash)"                $BLOCK 'bfs ~/ -name "x"'

echo "=== D) TOKENIZALT FELISMERES -- shell-elvalasztok utan is ==="
run_case "cd /tmp && find / -name x"              $BLOCK 'cd /tmp && find / -name "x"'
run_case "true ; find / -name x"                  $BLOCK 'true ; find / -name "x"'

echo "=== E) POZITIV KONTROLL -- hatarolt utak, athaladnak ==="
run_case "find <repo> -maxdepth N (kartya elfogadasi feltetele)" \
    $ALLOW 'find /Users/ceo/Marveen/agents/backend -maxdepth 3 -name "*.ts"'
run_case "find . -maxdepth 2 (relativ, hatarolt)" \
    $ALLOW 'find . -maxdepth 2 -iname "*.md"'
run_case "find ~/Marveen/... (home ALATTI, hatarolt reszut)" \
    $ALLOW 'find ~/Marveen/agents/backend -name "*.ts"'
run_case "find /repo/path (abszolut, hatarolt, maxdepth nelkul is)" \
    $ALLOW 'find /repo/path -type f'
run_case "find / -maxdepth 3 (gyoker, DE korlatozott melyseg)" \
    $ALLOW 'find / -maxdepth 3 -name "x"'
run_case "cd repo && find . -maxdepth 1 (hatarolt, elvalasztott hivas)" \
    $ALLOW 'cd /Users/ceo/Marveen && find . -maxdepth 1'
run_case "find szo idezett szovegben, nem valodi hivas" \
    $ALLOW 'echo "run find / -name x if needed"'
run_case "sima ls -la / (nem find/bfs)" \
    $ALLOW 'ls -la /'

echo ""
echo "=== OSSZESITES: $PASS ok, $FAIL bukik ==="

if [ "$FAIL" -gt 0 ]; then
    echo "Bukott esetek: ${FAILED_NAMES[*]}"
    exit 1
fi

exit 0
