#!/bin/bash
# hu: SessionStart ÉS UserPromptSubmit hook — a jelenlegi projekt
#     postaládájában (~/Work/Claude/Mailbox/<projekt>/inbox.jsonl) várakozó
#     üzeneteket beinjektálja a model context-jébe, majd archiválja
#     (archive.jsonl) és üríti az inbox-ot. Lásd send-teammate-message.sh —
#     ez a párja (küldés).
#
# Kontraktus: mindkét hook-esemény ugyanazt a
#   {hookSpecificOutput: {hookEventName, additionalContext}} JSON-t várja,
# a hookEventName-t a stdin bemenetből (.hook_event_name) tükrözzük vissza,
# így ugyanez a szkript regisztrálható mindkét hook-listában.
#
# Ha nincs uzenet: csendben, kimenet nélkül, exit 0 (ne zajongjon minden
# prompt-nal).
set -uo pipefail

MAILBOX_ROOT="$HOME/Work/Claude/Mailbox"

INPUT="$(cat 2>/dev/null || true)"
CWD=""
HOOK_EVENT_NAME="SessionStart"
if [ -n "$INPUT" ]; then
  CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
  HOOK_EVENT_NAME="$(echo "$INPUT" | jq -r '.hook_event_name // "SessionStart"' 2>/dev/null || echo "SessionStart")"
fi
[ -z "$CWD" ] && CWD="$PWD"

OVERRIDE_FILE="$CWD/.claude/.vault-project-name"
if [ -f "$OVERRIDE_FILE" ]; then
  PROJECT_NAME="$(head -n1 "$OVERRIDE_FILE" | tr -d '[:space:]')"
else
  PROJECT_NAME="$(basename "$CWD")"
fi
PROJECT_NORM="$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]')"

INBOX="$MAILBOX_ROOT/$PROJECT_NORM/inbox.jsonl"

# hu: Nincs postaláda vagy üres -> csendes exit, nincs context-zaj.
if [ ! -s "$INBOX" ]; then
  exit 0
fi

# hu: Atomikus "lefoglalás" — átnevezzük, mielőtt feldolgoznánk, hogy egy
#     közben érkező uj send-teammate-message.sh hívás ne veszejtsen el
#     üzenetet (az újra létrejövő inbox.jsonl-be ír).
PROCESSING="$MAILBOX_ROOT/$PROJECT_NORM/inbox.processing.$$"
mv "$INBOX" "$PROCESSING" 2>/dev/null || exit 0

ARCHIVE="$MAILBOX_ROOT/$PROJECT_NORM/archive.jsonl"
cat "$PROCESSING" >> "$ARCHIVE"

# hu: Ember-olvasható context-blokk összeállítása a JSONL sorokból. Minden
#     üzenet KÜLÖN, egyértelműen elhatárolt blokk (fejléc + teljes, több-soros
#     tartalom natívan, NEM egy sorba zsúfolva) — hosszú, dokumentum-jellegű
#     üzenetekre (pl. feladat-átadás) is olvasható marad, nem csak rövid
#     jegyzetekre.
CONTEXT="## 📬 Uzenet(ek) masik projektbol"$'\n'
CONTEXT+="_A ~/Work/Claude/Mailbox postaladan keresztul, send-teammate-message.sh / /tell paranccsal kuldve._"$'\n\n'

while IFS= read -r line; do
  [ -z "$line" ] && continue
  FROM="$(echo "$line" | jq -r '.from // "ismeretlen"')"
  TS="$(echo "$line" | jq -r '.timestamp // ""')"
  MSG="$(echo "$line" | jq -r '.message // ""')"
  CONTEXT+="---"$'\n\n'
  CONTEXT+="### Uzenet innen: $FROM ($TS)"$'\n\n'
  CONTEXT+="$MSG"$'\n\n'
done < "$PROCESSING"

CONTEXT+="---"$'\n'

rm -f "$PROCESSING"

jq -n --arg event "$HOOK_EVENT_NAME" --arg ctx "$CONTEXT" \
  '{hookSpecificOutput: {hookEventName: $event, additionalContext: $ctx}}'
