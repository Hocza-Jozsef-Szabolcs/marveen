#!/bin/bash
# hook-runner.sh -- resilient wrapper for Claude Code hook commands.
#
# Miert kell: 2026-08-31 ejfel utan egy hianyzo hook-fajl (telegram_progress.py)
# leallitotta a munkat -- a Python interpreter "can't open file" hibaval kilepett,
# Claude Code ezt "operation blocked by hook"-kent ertelmezte, es a session nem
# tudott tovabblepni. Egy INFRASTRUKTURALIS hiba (hianyzo/serult hook-fajl) igy
# ugyanugy blokkolt, mint egy SZANDEKOS tiltas -- pedig a ketto nem ugyanaz.
#
# Hasznalat:
#   hook-runner.sh [--fail-closed] <parancs> [argumentumok...]
#
# Ha a hivott parancs (az utolso argumentum, a tenyleges hook-fajl/script)
# NEM letezik, vagy a parancs inditasa magaban is elbukik (exit 126/127,
# "command not found" / "not executable"), az INFRASTRUKTURA hibas, nem a
# hook DONTOTT ugy, hogy blokkol:
#   - alapertelmezetten FAIL-OPEN: naplozza a hibat stderr-re, exit 0 (a
#     muvelet folytathato) -- ez a nem-biztonsagi hookokra (Telegram-jelzes,
#     kep-atmeretezes) a helyes alapertek.
#   - --fail-closed flaggel FAIL-CLOSED: exit 2 (blokkol) -- ez a
#     biztonsagi orzokre (destructive-git-guard, unbounded-find-guard) kell,
#     mert ha MAGA AZ oRZo torott, a hallgatas nem biztonsagos alapertek.
#
# Ha a hivott parancs TENYLEGESEN lefut, a sajat exit kodja es kimenete
# VALTOZATLANUL tovabbmegy -- egy hook, ami maga dont ugy, hogy blokkol
# (pl. exit 2), azt tovabbra is megteheti. Ez a wrapper csak azt a hibaosztalyt
# fogja meg, amikor a hook EL SEM TUDOTT INDULNI.
set -u

FAIL_CLOSED=0
if [ "${1:-}" = "--fail-closed" ]; then
  FAIL_CLOSED=1
  shift
fi

if [ "$#" -eq 0 ]; then
  echo "hook-runner.sh: nincs parancs megadva, nincs mit futtatni" >&2
  exit 0
fi

fail_infra() {
  echo "hook-runner.sh: $1" >&2
  if [ "$FAIL_CLOSED" -eq 1 ]; then
    echo "hook-runner.sh: FAIL-CLOSED -- a muvelet blokkolva, amig a hook nincs helyreallitva" >&2
    exit 2
  else
    echo "hook-runner.sh: fail-open -- a muvelet folytatodik, a hook kihagyva" >&2
    exit 0
  fi
}

# Az utolso argumentum a tenyleges hook-fajl, akkor is, ha egy interpreter
# (pl. "python3 /ut/script.py") elozi meg -- ${!#} portabilis alak, bash 3.2-n
# (macOS alapertelmezett) is mukodik, a negativ-indexes "${@: -1}" NEM.
TARGET="${!#}"

if [[ "$TARGET" == /* ]] && [ ! -e "$TARGET" ]; then
  fail_infra "HIANYZO HOOK-FAJL: $TARGET"
fi

"$@"
RC=$?

if [ "$RC" -eq 126 ] || [ "$RC" -eq 127 ]; then
  fail_infra "a hook nem inditHATO (exit $RC): $TARGET"
fi

exit "$RC"
