#!/bin/bash
# hu: PUSH-AHEAD-FIGYELo -- minden ismert repora kiirja az ahead-szamot (nem-pusholt commit-szam)
#     az upstreamhez kepest, es a LEGREGEBBI nem-pusholt commit datumat. NEM push-ol, csak mer --
#     lasd kartya 2593bcc7: a push-dontes a lathatosagtol fugg (PRIVATE mehet, PUBLIC
#     jovahagyas-koteles), es az marveen dontese marad.
#
#     A REPO-FELDERITES harom gyokeret jar be alapertelmezesben: $HOME/Source, $HOME/Marveen,
#     $HOME/Work (kartya 35d8a1ea -- a csak-Source bejaras vak volt a sajat flotta-infrastrukturara
#     es a Work alatti egypeldanyos repokra). A repo-lista NINCS a szkriptbe egetve -- uj repo
#     felvetelekor nem kell ket helyen atirni, eleg a `git clone`-t valamelyik gyoker ala tenni.
#
#     CSENDES KOR: nulla ahead eseten a repo NEM ir sort -- a napi/heartbeat kor csak akkor szoljon,
#     ha van tennivalo. Kulonben egy sor repnkent: "<repo-ut> <ag> ahead=<szam> legregebbi=<datum>".
#
#     Csak a KIVALASZTOTT (checkout-olt) ag szamit -- ugyanaz a hatokor, mint a push-all.sh-e. Harom
#     kulon eset van, amikor az agnak nincs felso-nyomkovetese (nincs `branch.<ag>.remote` config):
#
#     1) a REPONAK VAN olyan tavolija, amelynel LETEZIK azonos nevu tavoli-ag (`<remote>/<ag>`), csak
#        a lokalis config nincs hozza kotve -- MERT TENY (elo futtatas, kartya 35d8a1ea): a Marveen
#        repo sajat aga pontosan ez az eset, ket remote-tal es kotetlen configgal. Ez szerepel,
#        "ahead=NINCS-KOTVE(<n>)" cimkevel, a talalt tavoli-aghoz kepest szamolt <n>-nel.
#     2) a REPONAK VAN tavolija, de SEHOL nincs azonos nevu tavoli-ag -- ez valodi meretlen allapot
#        (nincs mihez kepest szamolni), csendben kimarad.
#     3) a REPONAK EGYETLEN tavolija sincs (pl. csak lokalisan letezo VrMobile 2.0-tipusu ag) -- ez
#        NEM meretlen allapot, hanem BACKUP NELKULI -- ez szerepel, "ahead=NINCS-TAVOLI(<n>)"
#        cimkevel, ahol <n> a HEAD-en levo osszes commit szama (minden commit "ahead", nincs
#        mihez kepest szamolni).
#
# en: PUSH-AHEAD MONITOR -- prints, for every known repo, the ahead-count (unpushed commits) vs.
#     its upstream, and the date of the OLDEST unpushed commit. Never pushes -- see card 2593bcc7:
#     the push decision depends on visibility (PRIVATE can go, PUBLIC needs approval), and stays
#     marveen's call.
#
#     REPO DISCOVERY walks three roots by default: $HOME/Source, $HOME/Marveen, $HOME/Work (card
#     35d8a1ea -- the Source-only walk was blind to the fleet's own infrastructure repo and to
#     single-copy repos under Work). The repo list is not baked into this script -- adding a repo
#     means cloning it under one of the roots, not editing two places.
#
#     SILENT ROUND: zero ahead prints nothing -- the daily/heartbeat round should only speak up when
#     there is something to act on. Otherwise one line per repo: "<repo-path> <branch> ahead=<n>
#     legregebbi=<date>".
#
#     Only the CURRENTLY CHECKED-OUT branch counts -- same scope as push-all.sh. Three distinct
#     cases when the branch has no upstream tracking (no `branch.<name>.remote` config):
#
#     1) the REPO HAS a remote for which a same-named remote branch (`<remote>/<branch>`) EXISTS,
#        just the local config isn't wired to it -- measured fact (live run, card 35d8a1ea): the
#        Marveen repo's own branch is exactly this case, two remotes and an unwired config. This
#        prints, tagged "ahead=NINCS-KOTVE(<n>)", counted against the remote branch found.
#     2) the REPO HAS a remote but NO same-named remote branch exists anywhere -- genuinely
#        unmeasured state (nothing to compare against), silently skipped.
#     3) the REPO HAS NO remote at all (e.g. a locally-only VrMobile 2.0-style branch) -- that is
#        NOT unmeasured state but UNBACKED -- it prints, tagged "ahead=NINCS-TAVOLI(<n>)", where
#        <n> is the total commit count on HEAD (every commit counts, nothing to compare against).
#
# Hasznalat / Usage: push-ahead-figyelo.sh [--root DIR]... [--stats]
#   --root DIR   Repo-felderites gyokere, tobbszor is adhato (teszthez / szukebb hatokorhoz).
#                Alapertelmezes: $HOME/Source $HOME/Marveen $HOME/Work.
#   --stats      Extra sor a vegen: "bejaras: <n> egyedi repo" -- pozitiv kontroll a bejart
#                hatokorre. Az <n> a KOZOS git-konyvtar (`git rev-parse --git-common-dir`,
#                abszolut utra hozva) szerint dedupe-olt szam, NEM a nyers .git-bejegyzes-szam --
#                egy repo TOBB worktree-vel egy kozos git-adatbazist oszt meg, es csak EGYSZER
#                szamit (a FO CIKLUS ettol fuggetlenul minden worktree-t KULON vizsgal, mert
#                mindegyiknek sajat checkout-olt aga es "ahead" allapota lehet).
#
# EXIT: mindig 0 -- ez meres, nem kapu. A hivo a KIMENETBoL dont (ures kimenet = nincs tennivalo),
#       nem a kilepesi kodbol.

set -uo pipefail

CMaxDepth=10

FRoots=()
FStats=0

while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ $# -ge 2 ] || { echo "HIBA: a --root ertek nelkul all" >&2; exit 2; }
      FRoots+=("$2")
      shift 2
      ;;
    --stats)
      FStats=1
      shift
      ;;
    -h|--help)
      sed -n '2,64p' "$0"
      exit 0
      ;;
    *)
      echo "HIBA: ismeretlen kapcsolo: $1 (a kapcsolok: --root --stats --help)" >&2
      exit 2
      ;;
  esac
done

if [ ${#FRoots[@]} -eq 0 ]; then
  FRoots=("$HOME/Source" "$HOME/Marveen" "$HOME/Work")
fi

FGitDirs=()
while IFS= read -r gitdir; do
  [ -n "$gitdir" ] && FGitDirs+=("$gitdir")
done < <(
  for r in "${FRoots[@]}"; do
    [ -d "$r" ] || continue
    find "$r" -maxdepth "$CMaxDepth" -name ".git" \( -type d -o -type f \) 2>/dev/null
  done | sort -u
)

if [ "$FStats" = "1" ]; then
  FCommonDirs=()
  for gitdir in "${FGitDirs[@]}"; do
    repo="${gitdir%/.git}"
    common=$(cd "$repo" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)
    if [ -n "$common" ]; then
      abscommon=$(cd "$repo" 2>/dev/null && cd "$common" 2>/dev/null && pwd -P)
      [ -n "$abscommon" ] && FCommonDirs+=("$abscommon")
    fi
  done
  FUniqueCount=$(printf '%s\n' "${FCommonDirs[@]}" | sort -u | grep -c .)
  echo "bejaras: $FUniqueCount egyedi repo"
fi

for gitdir in "${FGitDirs[@]}"; do
  repo="${gitdir%/.git}"

  branch=$(git -C "$repo" branch --show-current 2>/dev/null)
  [ -n "$branch" ] || continue

  remote=$(git -C "$repo" config "branch.$branch.remote" 2>/dev/null)

  if [ -n "$remote" ]; then
    range="$remote/$branch..HEAD"
    label_prefix=""
  else
    for r in $(git -C "$repo" remote 2>/dev/null); do
      git -C "$repo" show-ref --verify --quiet "refs/remotes/$r/$branch" || continue
      remote="$r"
      break
    done

    if [ -n "$remote" ]; then
      range="$remote/$branch..HEAD"
      label_prefix="NINCS-KOTVE"
    else
      remotes_count=$(git -C "$repo" remote 2>/dev/null | wc -l | tr -d ' ')
      [ "$remotes_count" = "0" ] || continue
      range="HEAD"
      label_prefix="NINCS-TAVOLI"
    fi
  fi

  ahead=$(git -C "$repo" rev-list --count "$range" 2>/dev/null)
  [ -n "$ahead" ] && [ "$ahead" != "0" ] || continue

  oldest=$(git -C "$repo" rev-list "$range" 2>/dev/null | tail -1)
  oldest_date=$(git -C "$repo" show -s --date=short --format=%cd "$oldest" 2>/dev/null)

  if [ -n "$label_prefix" ]; then
    echo "$repo $branch ahead=$label_prefix($ahead) legregebbi=$oldest_date"
  else
    echo "$repo $branch ahead=$ahead legregebbi=$oldest_date"
  fi
done

exit 0
