#!/bin/bash
# hu: PostToolUse hook — ha a Bash kimenete teszt FAIL-t jelez, figyelmeztet
#     az 'instrument-first-dont-speculate' szabályra.
# en: PostToolUse hook — when Bash output indicates a test FAIL, warns
#     about the 'instrument-first-dont-speculate' rule.

set -uo pipefail

input=$(cat)
tool_name=$(echo "$input" | jq -r '.tool_name // empty')

if [ "$tool_name" != "Bash" ]; then
    exit 0
fi

# hu: Kimenet kinyerése — PostToolUse-ban a tool_response.stdout
stdout=$(echo "$input" | jq -r '.tool_response.stdout // empty')
stderr=$(echo "$input" | jq -r '.tool_response.stderr // empty')
combined="$stdout
$stderr"

# hu: FAIL minták felismerése
# en: FAIL pattern detection
if echo "$combined" | grep -qE '\bFAIL\b|\bFAILED\b|AssertionError|Test.*[Ee]rror|FAIL=[1-9]|Failed:[[:space:]]+[1-9]|Error:[[:space:]]+Test'; then
    # hu: Néhány jellegzetes találat
    sample=$(echo "$combined" | grep -E '\bFAIL\b|\bFAILED\b|AssertionError' | head -3)

    cat >&2 <<EOF
[hook: instrument-first-after-fail] FIGYELMEZTETÉS

Teszt FAIL detektálva.

Minta a kimenetből:
$sample

Az 'instrument-first-dont-speculate' szabály szerint a következő lépés:
  1) Diagnosztika hozzáadása (Console.WriteLine, \$display, VCD trace,
     cocotb print, logger) a feltételezett hibás kódhoz
  2) Újrafuttatás és a tényleges állapot megfigyelése
  3) CSAK ekkor jön a kódjavítás — a megfigyelt adat alapján

Ha kihagyod a diagnosztikát és egyenesen módosítod a kódot, az "blind trial"
('no-blind-trial' szabály). Megfontolt kódjavításhoz fogalmazz meg egy-két
mondatos indoklást: miért világos a hiba diagnosztika nélkül is.
EOF
fi

# hu: PostToolUse warning — nem blokkol, csak figyelmeztet
exit 0
