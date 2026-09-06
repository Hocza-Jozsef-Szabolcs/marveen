#!/bin/bash
# hu: PISZKOS-MUNKAFA-FIGYELo -- kartya 2830d9aa: a meglevo ket mero (push-ahead-figyelo.sh,
#     amnezias-fej-figyelo.sh) COMMITOT nez -- a COMMITOLATLAN munkafa mindkettonek vak folt.
#     Ez a szkript a repo-felderitesen (push-ahead-figyelo.sh mintajara harom+egy gyokerrel)
#     VEGIGJARJA a `git status --porcelain` allapotot, repo/ag/darabszam bontasban kiirja a
#     PISZKOS (commitolatlan) munkafakat, es KIEMELI azt az esetet, amikor egy `done`/`waiting`
#     kartya munkaja UGY nez ki, hogy meg mindig ott ul commitolatlanul.
#
#     🛑 VHR8 KIZARVA -- SEM MERES: a `/Users/ceo/Marveen/CLAUDE.md` fleet-szabalya szerint a
#     VHR8 (`VHR-8.0`, `__VHR8__`) semmilyen onkezdemenyezett figyelmet nem kaphat, amig Jozsi
#     nev szerint nem keri. A repo-felderites ELSo lepesben szuri ki -- meg a `--stats` szamlalo
#     sem latja, mert a kizaras a FGitDirs listabol torli, nem utolagosan a kimenetbol.
#
#     HARMATLAN VS ERDEMI (a 2026-09-06-i sweep merte -- ~/Source ~/Marveen ~/Work bejarasa,
#     11 talalat): a `git status --porcelain` soronkent ERDEMI vagy HARMATLAN. HARMATLAN, azaz
#     NEM piszkos-jelzesre valo (futasi mellektermek vagy build-kimenet, nem KOD/SZABALY):
#       - untracked `.worktrees/` konyvtar-bejegyzes (a beagyazott worktree-tarolo maga infra)
#       - `*.apk` / `*.ipa` / `*.aab` (build-kimenet)
#       - `mockoon/**/*.json` modositas (a mockoon szerver a sajat fixture-jet irja futas kozben)
#       - `Thumbs.db` / `.DS_Store` (OS-szemet)
#       - egy `/backups/` utvonal-szegmenst tartalmazo repo EGESZE (regi mentes-munkafa -- lasd
#         kartya tpm2-commit-nelkuli-mentes-2026-08-04: a teljes fa "A" allapotu, sosem lesz
#         commitolva, mert maga a mentes)
#     Ha egy repoban MINDEN piszkos sor harmatlan, a repo CSENDBEN marad (nulla ahead csendje,
#     push-ahead-figyelo.sh mintajara) -- csak akkor ir sort, ha van legalabb egy ERDEMI bejegyzes.
#
#     KARTYA-GYANU (kiemelt sor): ha egy repo ERDEMI piszkos bejegyzest hordoz, a szkript
#     megnezi a kanban `kanban_cards` tablat -- a repo konyvtarnevehez (+ nehany ismert alias,
#     lasd get_project_candidates) illeszkedo `project` mezovel, `done`/`waiting` statusszal,
#     a --recency-hours ablakon beluli `updated_at`-tal rendelkezo kartyakat. HAROM felteteltol
#     fugg a jelzes, MINDHaROM egyszerre:
#       1. `project`-egyezes (fent),
#       2. a kartya CIME (normalva: kisbetu, "-"/"_"->szokoz) tartalmazza legalabb EGY erdemi
#          piszkos fajl nevet (kiterjesztes nelkul, normalva, min. 5 karakter),
#       3. a kartya-id NEM szerepel EGYETLEN commit-uzenetben sem a repo teljes tortenetében
#          (`git log --all --grep=<id>`).
#     A 2. FELTETEL ELo MERES ALAPJAN KERULT BE (2026-09-06, ~/Marveen repo, sajat fut): a puszta
#     project-egyezes ONMAGABAN eleg volt 4 ALTALZAJT adni ugyanabban a percben -- egy koordinacios
#     kartya, aminek a commitja EGY MASIK fizikai repoban (`~/Work/Claude`) all, egy duplikatumkent
#     lezart kartya, aminek a munkajat egy MASIK kartya-id commitolta, es egy meg dontesre varo
#     `waiting` kartya, aminek meg NEM IS KELL commit. Egyik sem volt hamis a projekt-mezo szerint,
#     de EGYIK cime sem hivatkozott a ténylegesen piszkos fajlokra -- a cim-atfedes ezt a harom
#     esetet mind kiszurte, csak azt engedi at, amikor a kartya SAJAT cime a piszkos fajlra utal.
#     Ha NEM mind a harom teljesul, nincs jelzes -- a hianyzo jelzes lehet, hogy valodi kartya-
#     vesztest rejt (heurisztika, nem bizonyitas -- ezert "gyanu", nem "tenyleg"), de ez szandekos:
#     a "tobbsegeben zaj" allapot nezhetetlenne teszi a jovoben, ha a jel arany rossz.
#
#     A KUSZOB (--recency-hours, alapertelmezes 72) DONTES, NEM MERT TENY -- a ket 2026-09-05-i
#     mert eset (8 ora, illetve egy ejszaka) belefer, de a szam maga valasztott hatar.
#
# en: DIRTY-WORKTREE MONITOR -- the existing two monitors (push-ahead-figyelo.sh,
#     amnezias-fej-figyelo.sh) look at COMMITS -- an UNCOMMITTED working tree is a blind spot for
#     both. This script walks the same repo discovery (push-ahead-figyelo.sh style, four roots),
#     reports dirty (uncommitted) working trees broken down by repo/branch/count, and HIGHLIGHTS
#     the case where a `done`/`waiting` card's work looks like it is still sitting there uncommitted.
#
# Hasznalat / Usage: piszkos-munkafa-figyelo.sh [--root DIR]... [--db FILE] [--recency-hours N] [--stats]
#   --root DIR         Repo-felderites gyokere, tobbszor is adhato. Alapertelmezes:
#                       $HOME/Source $HOME/Marveen $HOME/Work $HOME/.worktrees.
#   --db FILE           A kanban SQLite adatbazis utja. Alapertelmezes: $HOME/Marveen/store/claudeclaw.db.
#                       Ha a fajl nem letezik, a KARTYA-GYANU lepes csendben kimarad (a piszkos-fa
#                       jelzes attol fuggetlenul mukodik).
#   --recency-hours N   A kartya-korrelacio idoablaka orakban. Alapertelmezes: 72.
#   --stats             Extra sor a vegen: "bejaras: <n> egyedi repo" (VHR8 nelkul).
#   --help              Ez a sugo.
#
# Kornyezeti valtozo teszthez / Env var for tests:
#   PMF_NOW_EPOCH        A "most" idopont unix-epochban -- determinisztikus recency-teszthez.
#
# EXIT: mindig 0 -- ez meres, nem kapu. A hivo a KIMENETBoL dont (ures kimenet = nincs tennivalo).

set -uo pipefail

CMaxDepth=10
# 🛑 A MINTA SZANDEKOSAN TAGABB, MINT A CLAUDE.md KET PELDANEVE ("__VHR8__", "VHR-8.0") -- elo
#    meres (2026-09-06) mutatta, hogy a tenyleges checkout `.../VHR8/Projects/VHR8` (kotojel es
#    pont NELKUL) volt, es a szukebb minta ATENGEDTE. A biztonsagos irany a TULzott kizaras, nem
#    a pontos egyezes -- egy felesleges kihagyas ara nulla, egy elmaradt kizarasnak nincs ara.
CVhr8Pattern='[Vv][Hh][Rr]-?8([/._-]|$)'

FRoots=()
FDb="${HOME}/Marveen/store/claudeclaw.db"
FRecencyHours=72
FStats=0
FNow="${PMF_NOW_EPOCH:-$(date +%s)}"

while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ $# -ge 2 ] || { echo "HIBA: a --root ertek nelkul all" >&2; exit 2; }
      FRoots+=("$2")
      shift 2
      ;;
    --db)
      [ $# -ge 2 ] || { echo "HIBA: a --db ertek nelkul all" >&2; exit 2; }
      FDb="$2"
      shift 2
      ;;
    --recency-hours)
      [ $# -ge 2 ] || { echo "HIBA: a --recency-hours ertek nelkul all" >&2; exit 2; }
      FRecencyHours="$2"
      shift 2
      ;;
    --stats)
      FStats=1
      shift
      ;;
    -h|--help)
      sed -n '2,70p' "$0"
      exit 0
      ;;
    *)
      echo "HIBA: ismeretlen kapcsolo: $1 (a kapcsolok: --root --db --recency-hours --stats --help)" >&2
      exit 2
      ;;
  esac
done

if [ ${#FRoots[@]} -eq 0 ]; then
  FRoots=("$HOME/Source" "$HOME/Marveen" "$HOME/Work" "$HOME/.worktrees")
fi

# ── Repo-felderites -- VHR8 MEG ITT kizarva, meg a --stats sem latja ────────────────────
FGitDirs=()
while IFS= read -r gitdir; do
  [ -n "$gitdir" ] || continue
  echo "$gitdir" | grep -Eq "$CVhr8Pattern" && continue
  FGitDirs+=("$gitdir")
done < <(
  for r in "${FRoots[@]}"; do
    [ -d "$r" ] || continue
    find "$r" -maxdepth "$CMaxDepth" -name ".git" \( -type d -o -type f \) 2>/dev/null
  done | sort -u
)

if [ "$FStats" = "1" ]; then
  echo "bejaras: ${#FGitDirs[@]} egyedi repo"
fi

# hu: EGY status-sor (pl. "?? .worktrees/" vagy " M mockoon/x.json") HARMATLAN-e -- azaz
#     futasi mellektermek/build-kimenet, nem KOD/SZABALY. Igaz (0) = harmatlan, hamis (1) = erdemi.
# en: is ONE status line (e.g. "?? .worktrees/") HARMLESS -- a run-time side effect / build
#     output, not CODE/RULE. True (0) = harmless, false (1) = meaningful.
is_harmless_entry() {
  local path="$1"

  case "$path" in
    */.worktrees/|.worktrees/) return 0 ;;
    *.apk|*.ipa|*.aab) return 0 ;;
    */mockoon/*.json|mockoon/*.json) return 0 ;;
    */Thumbs.db|Thumbs.db|*/.DS_Store|.DS_Store) return 0 ;;
    *) return 1 ;;
  esac
}

# hu: a repo konyvtarnevebol (+ ismert aliasok) adja a lehetseges kanban `project` ertekeket.
#     HEURISZTIKA -- bovitheto, ha uj eltero elnevezesu repo kerul be.
# en: derives candidate kanban `project` values from the repo directory name (+ known aliases).
get_project_candidates() {
  local repo_path="$1" base="$2"
  local out=("$base")

  case "$repo_path" in
    *VHR*Delphi*|*Delphi*VHR*) out+=("VHR5" "VHR") ;;
  esac
  case "$base" in
    VrMobile-*|VrMoblie-*) out+=("VrMobile") ;;
  esac

  printf '%s\n' "${out[@]}" | sort -u
}

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

# hu: kisbetus, "-"/"_" -> szokoz normalalak -- a fajlnev-toke es a kartya-cim osszevetesehez.
# en: lowercase, "-"/"_" -> space normal form -- for comparing a filename token to a card title.
normalize_text() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '_-' '  ' | tr -s ' '
}

# hu: egy `git status` sor UTVONALABOL kivont fajlnev-toke (kiterjesztes nelkul, normalva) -- ez
#     a KARTYA-GYANU masodik feltetele: a puszta `project`-egyezes ONMAGABAN kevesnek bizonyult
#     (elo meres, kartya 2830d9aa): a `project` mezo tobb fizikai repot is lefedhet (pl. "Marveen"
#     mind a `~/Marveen` repora, mind a kulon git-repo `~/Work/Claude`-ra hasznalatos), es egy
#     regi/duplikalt/koordinacios kartya project-e egyezhet anelkul, hogy barmi koze lenne a
#     JELENLEGI piszkos fajlokhoz. Rovid (5 karakternel rovidebb) tokent nem hasznalunk -- az
#     ilyen ("main", "test", "app") tul sok cimmel veletlenul egyezne.
file_token() {
  local base
  base="$(basename "$1")"
  normalize_text "${base%.*}"
}

FCutoff=$((FNow - FRecencyHours * 3600))
FHaveDb=0
[ -f "$FDb" ] && FHaveDb=1

for gitdir in "${FGitDirs[@]}"; do
  repo="${gitdir%/.git}"

  case "$repo" in
    */backups/*) continue ;;
  esac

  status=$(git -C "$repo" status --porcelain 2>/dev/null)
  [ -n "$status" ] || continue

  branch=$(git -C "$repo" branch --show-current 2>/dev/null)
  [ -n "$branch" ] || branch="(detached)"

  meaningful=()
  tokens=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line:3}"
    path="${path##* -> }"
    is_harmless_entry "$path" && continue
    meaningful+=("$line")
    tok="$(file_token "$path")"
    [ ${#tok} -ge 5 ] && tokens+=("$tok")
  done <<< "$status"

  [ ${#meaningful[@]} -gt 0 ] || continue

  echo "$repo $branch piszkos=${#meaningful[@]}"
  for line in "${meaningful[@]}"; do
    echo "  $line"
  done

  [ "$FHaveDb" = "1" ] || continue

  base="$(basename "$repo")"
  candidates=()
  while IFS= read -r c; do
    [ -n "$c" ] && candidates+=("$c")
  done < <(get_project_candidates "$repo" "$base")
  in_list=""
  for c in "${candidates[@]}"; do
    [ -n "$in_list" ] && in_list="$in_list,"
    in_list="$in_list'$(sql_escape "$c")'"
  done

  rows=$(sqlite3 -separator '|' "$FDb" \
    "SELECT id, status, title, updated_at FROM kanban_cards
     WHERE status IN ('done','waiting') AND project IN ($in_list) AND updated_at > $FCutoff
     ORDER BY updated_at DESC;" 2>/dev/null)

  [ -n "$rows" ] || continue

  since_days=$(( (FRecencyHours + 23) / 24 ))
  [ "$since_days" -ge 1 ] || since_days=1

  while IFS='|' read -r cid cstatus ctitle cupdated; do
    [ -n "$cid" ] || continue

    title_norm="$(normalize_text "$ctitle")"
    overlap=1
    for tok in "${tokens[@]:-}"; do
      [ -n "$tok" ] || continue
      case "$title_norm" in
        *"$tok"*) overlap=0; break ;;
      esac
    done
    [ "$overlap" = "0" ] || continue

    found=$(git -C "$repo" log --all --since="${since_days} days ago" --grep="$cid" --fixed-strings --oneline -1 2>/dev/null)
    [ -z "$found" ] || continue
    cdate=$(date -r "$cupdated" '+%Y-%m-%d %H:%M' 2>/dev/null)
    echo "  KARTYA-GYANU: $cid ($cstatus, frissitve $cdate) -- nincs commit a repoban erre a kartyara, a fenti piszkos fajlok az o munkaja lehetnek: $ctitle"
  done <<< "$rows"
done

exit 0
