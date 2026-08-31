#!/bin/bash
# hu: Üzenet küldése egy MÁSIK, kézzel/függetlenül indított Claude Code
#     terminál-session-nek (más projekt-könyvtár). NEM az Agent Teams
#     SendMessage-e (az csak lead → spawnolt teammate-ek között működik,
#     már futó, függetlenül indított session-ök nem tudnak vele
#     kommunikálni) — ez egy fájl-alapú postaláda: a célprojekt a KÖVETKEZŐ
#     prompt-jánál (UserPromptSubmit hook) vagy session-indításnál
#     (SessionStart hook) kapja meg, nem valós időben.
#
# Használat:
#   send-teammate-message.sh <cel-projekt-nev> <uzenet szovege...>
#
# A cel-projekt-nev ugyanaz a nevesítés, mint amit a load-vault-context.sh
# használ (<CWD>/.claude/.vault-project-name felülírás, egyébként a CWD
# basename-je) — kis/nagybetű-érzéketlenül egyeztetve.
set -euo pipefail

MAILBOX_ROOT="$HOME/Work/Claude/Mailbox"

if [ $# -lt 2 ]; then
  echo "Hasznalat: send-teammate-message.sh <cel-projekt-nev> <uzenet szovege...>" >&2
  exit 1
fi

TARGET_RAW="$1"
shift
MESSAGE="$*"

# hu: Kis/nagybetű-érzéketlen normalizálás a mappanévhez (elkerüli a
#     "VrMobile" vs "vrmobile" vs "VRMOBILE" szétcsúszást).
TARGET_NORM="$(echo "$TARGET_RAW" | tr '[:upper:]' '[:lower:]')"

# hu: Küldő projekt-név — ugyanaz a felülírás/basename logika, mint
#     load-vault-context.sh-ban, a JELENLEGI munkakönyvtárból (nem hook,
#     nincs stdin JSON — Claude/felhasználó közvetlenül hívja).
CWD="$PWD"
OVERRIDE_FILE="$CWD/.claude/.vault-project-name"
if [ -f "$OVERRIDE_FILE" ]; then
  FROM_PROJECT="$(head -n1 "$OVERRIDE_FILE" | tr -d '[:space:]')"
else
  FROM_PROJECT="$(basename "$CWD")"
fi

TARGET_DIR="$MAILBOX_ROOT/$TARGET_NORM"
mkdir -p "$TARGET_DIR"
INBOX="$TARGET_DIR/inbox.jsonl"

TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

jq -nc \
  --arg from "$FROM_PROJECT" \
  --arg to "$TARGET_RAW" \
  --arg ts "$TIMESTAMP" \
  --arg msg "$MESSAGE" \
  '{from: $from, to: $to, timestamp: $ts, message: $msg}' >> "$INBOX"

echo "Uzenet elkuldve -> $TARGET_RAW postaladajaba ($INBOX). A cimzett a kovetkezo prompt-janal vagy session-inditasnal kapja meg."
