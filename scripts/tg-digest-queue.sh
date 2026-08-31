#!/bin/bash
# Nem-sürgős, nem közvetlen-válasz Telegram-tartalom sorba állítása kötegelt küldéshez.
# Használat:
#   tg-digest-queue.sh add "<szöveg>"   -> hozzáfűzi a sorhoz, nem küld semmit
#   tg-digest-queue.sh count            -> hány tétel vár
#   tg-digest-queue.sh flush            -> kiírja a sort számozva stdout-ra, majd ÜRÍTI a fájlt
#                                           (a küldés a hívó dolga -- ez a script nem hív Telegramot)
set -euo pipefail
QUEUE="/Users/ceo/Marveen/store/telegram-digest-queue.jsonl"
touch "$QUEUE"

case "${1:-}" in
  add)
    [ -z "${2:-}" ] && { echo "hasznalat: $0 add \"<szoveg>\"" >&2; exit 1; }
    python3 -c "
import json, time, sys
with open('$QUEUE', 'a') as f:
    f.write(json.dumps({'ts': int(time.time()), 'text': sys.argv[1]}, ensure_ascii=False) + '\n')
" "$2"
    echo "sorba allitva"
    ;;
  count)
    wc -l < "$QUEUE" | tr -d ' '
    ;;
  flush)
    if [ ! -s "$QUEUE" ]; then
      echo "URES"
      exit 0
    fi
    python3 -c "
import json
with open('$QUEUE') as f:
    items = [json.loads(l) for l in f if l.strip()]
for i, it in enumerate(items, 1):
    print(f'{i}. {it[\"text\"]}')
"
    : > "$QUEUE"
    ;;
  *)
    echo "hasznalat: $0 {add \"szoveg\"|count|flush}" >&2
    exit 1
    ;;
esac
