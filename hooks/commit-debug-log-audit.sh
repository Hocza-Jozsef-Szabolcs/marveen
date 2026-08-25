#!/bin/bash
# hu: PreToolUse hook — git commit blokkolása, ha a staged diff
#     hibakereséshez használt debug log instrumentálást tartalmaz.
#     Csak a HOZZÁADOTT (+) sorokra szűr — a debug log eltávolítása
#     (cleanup commit) engedélyezett.
# en: PreToolUse hook — block git commit when the staged diff contains
#     debug log instrumentation that should be stripped first.
#     Only ADDED (+) lines are scanned — removing debug logs (cleanup
#     commits) is allowed.
#
# Szabály: Shared/strip-debug-logs-before-commit.md

set -uo pipefail

input=$(cat)
tool_name=$(echo "$input" | jq -r '.tool_name // empty')

if [ "$tool_name" != "Bash" ]; then
    exit 0
fi

command=$(echo "$input" | jq -r '.tool_input.command // empty')

# hu: Csak `git commit`-tel kezdődő parancsokra reagálunk
if ! echo "$command" | grep -qE '^[[:space:]]*git[[:space:]]+commit\b'; then
    exit 0
fi

# hu: Staged diff hozzáadott (+) sorai — fájl-header (+++) kihagyva
added_lines=$(git diff --cached 2>/dev/null | grep -E '^\+[^+]' || true)

if [ -z "$added_lines" ]; then
    exit 0
fi

# hu: Diagnosztikus debug log minták
#     - C# / .NET: Console.WriteLine, Debug.WriteLine, Trace.WriteLine
#     - Java:      System.out.println
#     - JS/TS:     console.log, debugger;
#     - Rust:      println!, dbg!
#     - Ruby:      binding.pry
#     - Python:    pdb.set_trace, breakpoint()
#     - PHP:       var_dump, print_r, dd()
#     - Prefixek:  [BUG], [BUG\d+], [DEBUG], [FEATURE-...] — instrument-first session-marker
patterns='Console\.WriteLine[[:space:]]*\(|Debug\.WriteLine[[:space:]]*\(|Trace\.WriteLine[[:space:]]*\(|System\.out\.println[[:space:]]*\(|console\.log[[:space:]]*\(|[[:space:]]debugger[[:space:]]*;|^\+[[:space:]]*debugger[[:space:]]*;|println![[:space:]]*\(|dbg![[:space:]]*\(|binding\.pry|pdb\.set_trace|var_dump[[:space:]]*\(|print_r[[:space:]]*\(|\[BUG[0-9]*\]|\[DEBUG\]|\[FEATURE-[A-Z]'

hits=$(echo "$added_lines" | grep -iE -o "$patterns" | sort -u | head -8 | tr '\n' ',' | sed 's/,$//')

if [ -z "$hits" ]; then
    exit 0
fi

# hu: Mintasorok (max 5) — segít látni hol vannak
sample=$(echo "$added_lines" | grep -iE "$patterns" | head -5 | sed 's/^/    /')

cat >&2 <<EOF
[hook: commit-debug-log-audit] BLOCK

A staged diff hibakereséshez használt debug log instrumentálást tartalmaz.
A 'strip-debug-logs-before-commit' szabály ezt tiltja:
  → A bug-fix commit CSAK a megoldást tartalmazza
  → A diagnosztikus log (Console.WriteLine, console.log, [BUG] prefix stb.)
    commit ELŐTT törlendő, hogy a fix diff olvasható maradjon

Talált minták: ${hits}

Példa sorok:
${sample}

Lépések:
  1. Töröld a hibakereséshez használt log-okat a working tree-ből
  2. \`git add -u\` és próbáld újra a commit-ot
  3. Ha permanens log valóban kell (pl. production error log), tedd külön
     commitba: \`fix: <a valódi javítás>\` + \`chore: add error logging for X\`

Kivétel (szűk): ha a log MAGA a fix (pl. hiányzó error log egy critical
catch-ben), akkor a commit message-ben mondd ki explicit:
  \`fix: add missing error log in <method>\`
és kérj override-ot a felhasználótól.
EOF
exit 2
