#!/bin/bash
# hu: PUSH-AHEAD-FIGYELo -- minden ismert repora kiirja az ahead-szamot (nem-pusholt commit-szam)
#     az upstreamhez kepest, es a LEGREGEBBI nem-pusholt commit datumat. NEM push-ol, csak mer --
#     lasd kartya 2593bcc7: a push-dontes a lathatosagtol fugg (PRIVATE mehet, PUBLIC
#     jovahagyas-koteles), es az marveen dontese marad.
#
#     A REPO-FELDERITES a mar meglevo flotta-konvenciot hasznalja (~/.claude/commands/push-all.md /
#     ~/Work/Claude/scripts/push-all.sh): `find $HOME/Source -maxdepth 10 -name ".git"`. A repo-lista
#     NINCS a szkriptbe egetve -- uj repo felvetelekor nem kell ket helyen atirni, eleg a
#     `git clone`-t a $HOME/Source ala tenni.
#
#     CSENDES KOR: nulla ahead eseten a repo NEM ir sort -- a napi/heartbeat kor csak akkor szoljon,
#     ha van tennivalo. Kulonben egy sor repnkent: "<repo-ut> <ag> ahead=<szam> legregebbi=<datum>".
#
#     Csak a KIVALASZTOTT (checkout-olt) ag szamit -- ugyanaz a hatokor, mint a push-all.sh-e. Egy
#     branch, aminek nincs felso-nyomkovetese (nincs `branch.<ag>.remote` config), csendben kimarad:
#     nincs mibol "ahead"-et szamolni, es ez nem hianyzo teendo, csak meretlen allapot.
#
# en: PUSH-AHEAD MONITOR -- prints, for every known repo, the ahead-count (unpushed commits) vs.
#     its upstream, and the date of the OLDEST unpushed commit. Never pushes -- see card 2593bcc7:
#     the push decision depends on visibility (PRIVATE can go, PUBLIC needs approval), and stays
#     marveen's call.
#
#     REPO DISCOVERY reuses the existing fleet convention (~/.claude/commands/push-all.md /
#     ~/Work/Claude/scripts/push-all.sh): `find $HOME/Source -maxdepth 10 -name ".git"`. The repo
#     list is not baked into this script -- adding a repo means cloning it under $HOME/Source, not
#     editing two places.
#
#     SILENT ROUND: zero ahead prints nothing -- the daily/heartbeat round should only speak up when
#     there is something to act on. Otherwise one line per repo: "<repo-path> <branch> ahead=<n>
#     legregebbi=<date>".
#
#     Only the CURRENTLY CHECKED-OUT branch counts -- same scope as push-all.sh. A branch with no
#     upstream tracking (no `branch.<name>.remote` config) is silently skipped: there is nothing to
#     compute "ahead" against, and that is unmeasured state, not a missed action item.
#
# Hasznalat / Usage: push-ahead-figyelo.sh [--root DIR]...
#   --root DIR   Repo-felderites gyokere, tobbszor is adhato (teszthez / szukebb hatokorhoz).
#                Alapertelmezes: $HOME/Source -- ugyanaz a gyoker, mint a push-all.sh/pull-all.sh.
#
# EXIT: mindig 0 -- ez meres, nem kapu. A hivo a KIMENETBoL dont (ures kimenet = nincs tennivalo),
#       nem a kilepesi kodbol.

set -uo pipefail

CMaxDepth=10

FRoots=()

while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ $# -ge 2 ] || { echo "HIBA: a --root ertek nelkul all" >&2; exit 2; }
      FRoots+=("$2")
      shift 2
      ;;
    -h|--help)
      sed -n '2,40p' "$0"
      exit 0
      ;;
    *)
      echo "HIBA: ismeretlen kapcsolo: $1 (a kapcsolok: --root --help)" >&2
      exit 2
      ;;
  esac
done

if [ ${#FRoots[@]} -eq 0 ]; then
  FRoots=("$HOME/Source")
fi

while IFS= read -r gitdir; do
  repo="${gitdir%/.git}"

  branch=$(git -C "$repo" branch --show-current 2>/dev/null)
  [ -n "$branch" ] || continue

  remote=$(git -C "$repo" config "branch.$branch.remote" 2>/dev/null)
  [ -n "$remote" ] || continue

  ahead=$(git -C "$repo" rev-list --count "$remote/$branch..HEAD" 2>/dev/null)
  [ -n "$ahead" ] && [ "$ahead" != "0" ] || continue

  oldest=$(git -C "$repo" rev-list "$remote/$branch..HEAD" 2>/dev/null | tail -1)
  oldest_date=$(git -C "$repo" show -s --date=short --format=%cd "$oldest" 2>/dev/null)

  echo "$repo $branch ahead=$ahead legregebbi=$oldest_date"
done < <(
  for r in "${FRoots[@]}"; do
    [ -d "$r" ] || continue
    find "$r" -maxdepth "$CMaxDepth" -name ".git" \( -type d -o -type f \) 2>/dev/null
  done | sort -u
)

exit 0
