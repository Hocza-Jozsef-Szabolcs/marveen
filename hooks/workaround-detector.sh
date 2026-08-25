#!/bin/bash
# hu: PreToolUse hook — workaround/deferred jelzések blokkolása kódfájlokban.
#     Engedélyezett: .md, .txt, docs/**, *.log
#     Blokkolt: kódfájlok (mindenhol máshol)
# en: PreToolUse hook — blocks workaround/deferred markers in code files.
#     Allowed: .md, .txt, docs/**, *.log
#     Blocked: code files (everywhere else)

set -uo pipefail

input=$(cat)
tool_name=$(echo "$input" | jq -r '.tool_name // empty')

# hu: Csak Edit, Write, MultiEdit-re érvényes
case "$tool_name" in
    Edit|Write|MultiEdit) ;;
    *) exit 0 ;;
esac

file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')

# hu: Engedélyezett kiterjesztések — dokumentáció, log, hook-mechanizmusok
#     A hook-szkriptek maguk a halasztás-felügyelet implementációja, így
#     a fájlnév-referenciák és regex-minták engedélyezettek. Ide tartozik a
#     Claude-konfiguráció is (settings.json), mert az a nevükkel hivatkozik
#     a hook-szkriptekre, és a megosztott hooks/ mappa új helye is.
case "$file_path" in
    *.md|*.markdown|*.txt|*.rst|*.adoc) exit 0 ;;
    *.log|*CHANGELOG*|*ROADMAP*|*roadmap*) exit 0 ;;
    */docs/*|*/Docs/*|*/documentation/*) exit 0 ;;
    */Vault/*) exit 0 ;;
    */.claude/hooks/*) exit 0 ;;
    */Work/Claude/hooks/*) exit 0 ;;
    */settings.json|*/settings.local.json) exit 0 ;;
esac

# hu: Új tartalom kinyerése — Edit: new_string, Write: content, MultiEdit: edits[].new_string
new_content=$(echo "$input" | jq -r '
    if .tool_input.new_string then .tool_input.new_string
    elif .tool_input.content then .tool_input.content
    elif .tool_input.edits then (.tool_input.edits | map(.new_string) | join("\n"))
    else empty
    end
')

if [ -z "$new_content" ]; then
    exit 0
fi

# hu: Pattern keresés case-insensitive (HU + EN)
#     workaround | TODO | FIXME | HACK | XXX
#     "later" / "deferred" / "Known bug"
#     "majd később" / "ismert bug"
if echo "$new_content" | grep -qiE 'workaround|\bTODO\b|\bFIXME\b|\bHACK\b|\bXXX\b|\bdeferred\b|\blater\b|known[[:space:]]+bug|majd[[:space:]]+kés[őo]bb|ismert[[:space:]]+bug'; then
    matched=$(echo "$new_content" | grep -iE -o 'workaround|\bTODO\b|\bFIXME\b|\bHACK\b|\bXXX\b|\bdeferred\b|\blater\b|known[[:space:]]+bug|majd[[:space:]]+kés[őo]bb|ismert[[:space:]]+bug' | head -3 | tr '\n' ',' | sed 's/,$//')

    cat >&2 <<EOF
[hook: workaround-detector] BLOCK

Workaround/deferred jelzés a kódba: $matched
File: $file_path

A 'no-compromise-fixes-for-architectural-bugs' szabály ezt tiltja:
  → Javítsd a gyökeret a kódban, ne a tüneteket
  → Ha tudatos halasztás: kérj explicit override-ot a felhasználótól

Ha a felhasználó már jóváhagyta a halasztást, érveld meg
egy-két mondatban, és próbáld újra a tool-hívást.
EOF
    exit 2
fi

exit 0
