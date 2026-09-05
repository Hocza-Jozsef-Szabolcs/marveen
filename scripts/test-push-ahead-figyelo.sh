#!/bin/bash
# hu: A PUSH-AHEAD-FIGYELo merooeszkoze. Szintetikus bare+clone repo-parokat epit (halozat- es
#     allapot-fuggetlen), es azt meri, hogy a szkript PONTOSAN azokra a repokra ir sort, amelyeknek
#     van nem-pusholt commitja -- helyes ahead-szammal es a LEGREGEBBI nem-pusholt commit datumaval --
#     es NEMA marad a szinkronban levo, valamint a VAN-tavoli-de-az-ag-nincs-ra-kotve repokra.
#
#     🛑 KARTYA 35d8a1ea (2026-09-05, fel orava a bekotes utan): az alapertelmezett bejaras
#     `$HOME/Source`-ra szukult, es a `/Users/ceo/Marveen` + `~/Work` fa kimaradt -- pontosan
#     ott allt a legnagyobb nyitott tetel (57 nem-pusholt commit a Marveen repon). A T7/M3 ezt
#     a hatokort fedi (alapertelmezett harom gyoker), a T8 a POZITIV KONTROLLT a bejart repo-
#     szamra, a T4/M4 pedig azt, hogy egy TAVOLI NELKULI repo (VrMobile 2.0 tipusu eset) mostantol
#     SZEREPEL a kimenetben -- korabban ez is csendben kimaradt.
#
# 🛑 MIERT VAN BENNE MUTACIO-ESET: a zold keszlet onmagaban NEM mondja meg, hogy a teszt mer-e.
#    A T5 a szkript egy MASOLATABOL kiveszi a nulla-ahead orzest (kontrollnak keszult T2-t
#    varhatoan visszahozza), a T6 pedig a "legregebbi commit" kivalasztasat forditja meg
#    (tail -1 -> head -1), es elvarja, hogy a T3 datuma emiatt a LEGUJABBRA valtson. Az M3 az
#    alapertelmezett gyokeret szukiti vissza `$HOME/Source`-ra (a T7 Marveen/Work soranak el
#    kell tunnie), az M4 pedig a tavoli-nelkuli-ag felvetelet veszi ki (a T4-nek el kell tunnie).
#
# en: Measuring harness for the push-ahead monitor. Builds synthetic bare+clone repo pairs
#     (network- and state-independent) and measures that the script prints EXACTLY for repos with
#     unpushed commits -- correct ahead-count and OLDEST unpushed commit date -- and stays silent
#     for a synced repo and for a repo that HAS a remote but whose checked-out branch isn't tracked.
#     A repo with NO remote at all is a different case (card 35d8a1ea) and must now appear.
#
# EXIT: 0 = minden eset a vart eredmenyt adta | 1 = legalabb egy eset elter

set -uo pipefail

CDir="$(cd "$(dirname "$0")" && pwd)"
CScript="$CDir/push-ahead-figyelo.sh"

FTmp=$(mktemp -d "${TMPDIR:-/tmp}/push-ahead-figyelo-teszt.XXXXXX")
trap 'rm -rf "$FTmp"' EXIT

FPass=0
FFail=0

# 🛑 FAIL-CLOSED oR A MEROESZKOZON -- lasd test-buildszam-utkozes-kapu.sh azonos vedelme: `git -C ""`
#    NEM hiba, hanem a JELENLEGI munkakonyvtar repojaban fut. Minden git-hivas utvonala KOTELEZoEN
#    a teszt sajat ideiglenes mappaja alatt kell legyen.
gitq() {
  local dir="$1"

  if [ -z "$dir" ] || [ "${dir#$FTmp/}" = "$dir" ]; then
    echo "🛑 A MERoESZKOZ MEGALLT: git-hivas a teszt-mappan KIVUL: '[$dir]'" >&2
    exit 2
  fi

  git -C "$dir" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "${@:2}"
}

# hu: uj bare "remote" + clone-szeru munkafa parost hoz letre, elso commit push-olva -- ez a
#     "szinkronban" kezdoallapot minden esethez.
new_synced_repo() {
  local name="$1" root="$2"
  local bare="$FTmp/remotes/$name.git"
  local work="$root/$name"

  git init -q --bare "$bare" >/dev/null
  mkdir -p "$work"
  git -C "$work" init -q
  git -C "$work" symbolic-ref HEAD refs/heads/main
  gitq "$work" remote add origin "$bare"
  echo "init" > "$work/README.md"
  gitq "$work" add README.md
  gitq "$work" commit -q -m "init"
  gitq "$work" push -q origin main
  gitq "$work" branch -q --set-upstream-to=origin/main main

  git -C "$work" rev-parse --verify HEAD >/dev/null 2>&1 || {
    echo "🛑 A MERoESZKOZ VAK: a szintetikus repo ($name) nem jott letre." >&2
    exit 2
  }

  echo "$work"
}

# hu: egy unpushed commitot ad a munkafahoz, rogzitett commiter-datummal (determinisztikus "legregebbi").
add_unpushed_commit() {
  local work="$1" date="$2" msg="$3"

  echo "$msg" >> "$work/README.md"
  gitq "$work" add README.md
  GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" gitq "$work" commit -q -m "$msg"
}

expect_contains() { # cimke  varhato(IGEN|NEM)  minta  kimenet
  local label="$1" want="$2" pattern="$3" out="$4"
  local got="NEM"
  echo "$out" | grep -qF "$pattern" && got="IGEN"

  if [ "$got" = "$want" ]; then
    echo "  ✅ $label"
    FPass=$((FPass + 1))
  else
    echo "  ❌ $label -- '$pattern' szerepel: $got (vart: $want)"
    echo "$out" | sed 's/^/       | /'
    FFail=$((FFail + 1))
  fi
}

FRoot="$FTmp/root"
mkdir -p "$FRoot"

echo "T1-T4 -- alap esetek (ahead, szinkron, felso-nyomkovetes nelkul, tobb unpushed commit)"

# T1: egy unpushed commit -- pozitiv eset.
R1=$(new_synced_repo t1-ahead "$FRoot")
add_unpushed_commit "$R1" "2026-09-04T10:00:00" "unpushed valtozas"

# T2: szinkronban -- FALS POZITIV IRANYU KONTROLL, a kapu erre NE szoljon.
R2=$(new_synced_repo t2-synced "$FRoot")

# T3: harom unpushed commit, kulon datummal -- a LEGREGEBBI szamit, nem a legujabb.
R3=$(new_synced_repo t3-tobb "$FRoot")
add_unpushed_commit "$R3" "2026-09-01T10:00:00" "elso unpushed"
add_unpushed_commit "$R3" "2026-09-02T10:00:00" "masodik unpushed"
add_unpushed_commit "$R3" "2026-09-03T10:00:00" "harmadik unpushed"

# T4: a REPONAK EGYETLEN tavoli sincs (VrMobile 2.0 tipusu eset, kartya 35d8a1ea) -- ez NEM
#     meretlen allapot, hanem BACKUP NELKULI: az ag EGYETLEN peldanyban letezik, EPP EZERT
#     kell szerepelnie a kimenetben, nem ezert kell kimaradnia.
R4="$FRoot/t4-nincs-tavoli"
mkdir -p "$R4"
git -C "$R4" init -q
git -C "$R4" symbolic-ref HEAD refs/heads/main
echo "init" > "$R4/README.md"
gitq "$R4" add README.md
gitq "$R4" commit -q -m "init, tavoli nelkul"

# T4b: a REPONAK VAN tavolija, DE a kivalasztott ag nincs ra kotve -- ez TOVABBRA IS meretlen
#     allapot marad (nem ez a kartya hatokore), csendben kimarad.
R4b=$(new_synced_repo t4b-van-tavoli-nincs-kotes "$FRoot")
gitq "$R4b" checkout -q -b masik-ag

OUT=$(bash "$CScript" --root "$FRoot" 2>&1)

expect_contains "T1 az ahead repo szerepel 'ahead=1'-gyel"      IGEN "ahead=1" "$OUT"
expect_contains "T1 az ahead repo utja szerepel a kimenetben"   IGEN "$R1" "$OUT"
expect_contains "T2 a szinkron repo NEM szerepel a kimenetben"  NEM  "$R2" "$OUT"
expect_contains "T3 a harom unpushed commit 'ahead=3'-at ad"    IGEN "ahead=3" "$OUT"
expect_contains "T3 a LEGREGEBBI datum (09-01) szerepel"        IGEN "2026-09-01" "$OUT"
expect_contains "T3 a LEGUJABB datum (09-03) NEM a kiirt datum" NEM  "legregebbi=2026-09-03" "$OUT"
expect_contains "T4 tavoli nelkuli repo SZEREPEL"                    IGEN "$R4" "$OUT"
expect_contains "T4 a cimke 'ahead=NINCS-TAVOLI(1)'"                 IGEN "ahead=NINCS-TAVOLI(1)" "$OUT"
expect_contains "T4b van-tavoli-de-nincs-kotve repo NEM szerepel"    NEM  "$R4b" "$OUT"

if echo "$OUT" | grep -qE "^bash:|Traceback|szintaktikai hiba"; then
  echo "  ❌ T1-T4 a szkript hibaval allt le (varatlan kimenet)"
  echo "$OUT" | sed 's/^/       | /'
  FFail=$((FFail + 1))
fi

# ── T5: MUTACIO -- a nulla-ahead orzes eltavolitasa -- a T2 kontrollnak vissza kell jonnie ────
echo
echo "T5 -- mutacio: nulla-ahead orzes eltavolitva a szkript egy masolatabol"

FMut1="$FTmp/mutant-nulla-ahead-guard.sh"
cp "$CScript" "$FMut1"
BASE1=$(git hash-object "$CScript")

python3 - "$FMut1" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = '[ -n "$ahead" ] && [ "$ahead" != "0" ] || continue'
n = s.count(old)
assert n == 1, "A MUTACIO NEM ALKALMAZHATO: a minta %d-szer illeszkedik" % n
s = s.replace(old, '[ -n "$ahead" ] || continue')
open(p, 'w').write(s)
PYEOF

if [ "$(git hash-object "$FMut1")" = "$BASE1" ]; then
  echo "  ❌ T5 A MUTACIO NEM TORTENT MEG (a masolat hash-e valtozatlan)"
  FFail=$((FFail + 1))
else
  OUT_MUT1=$(bash "$FMut1" --root "$FRoot" 2>&1)
  if echo "$OUT_MUT1" | grep -qF "$R2"; then
    echo "  ✅ T5 a mutalt szkript most MEGSZOLAL a szinkron repora -- a T2 orzes valodi"
    FPass=$((FPass + 1))
  else
    echo "  ❌ T5 a mutans is nema maradt a szinkron repora -- a T2 orzes VAK lehet"
    echo "$OUT_MUT1" | sed 's/^/       | /'
    FFail=$((FFail + 1))
  fi
fi

[ "$(git hash-object "$CScript")" = "$BASE1" ] || {
  echo "  🛑 A MEROESZKOZ MEGALLT: az ELES szkript veletlenul modosult a mutacio soran." >&2
  exit 2
}

# ── T6: MUTACIO -- "legregebbi" kivalasztas megfordítasa (tail -1 -> head -1) ─────────────────
echo
echo "T6 -- mutacio: a legregebbi-commit kivalasztas megforditva"

FMut2="$FTmp/mutant-legregebbi-fordit.sh"
cp "$CScript" "$FMut2"
BASE2=$(git hash-object "$CScript")

python3 - "$FMut2" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "| tail -1)"
n = s.count(old)
assert n == 1, "A MUTACIO NEM ALKALMAZHATO: a minta %d-szer illeszkedik" % n
s = s.replace(old, "| head -1)")
open(p, 'w').write(s)
PYEOF

if [ "$(git hash-object "$FMut2")" = "$BASE2" ]; then
  echo "  ❌ T6 A MUTACIO NEM TORTENT MEG (a masolat hash-e valtozatlan)"
  FFail=$((FFail + 1))
else
  OUT_MUT2=$(bash "$FMut2" --root "$FRoot" 2>&1)
  if echo "$OUT_MUT2" | grep -qF "legregebbi=2026-09-03"; then
    echo "  ✅ T6 a mutalt szkript a LEGUJABB datumot adja -- a T3 datum-ellenorzes valodi"
    FPass=$((FPass + 1))
  else
    echo "  ❌ T6 a mutans is a regi datumot adta -- a T3 datum-ellenorzes VAK lehet"
    echo "$OUT_MUT2" | sed 's/^/       | /'
    FFail=$((FFail + 1))
  fi
fi

[ "$(git hash-object "$CScript")" = "$BASE2" ] || {
  echo "  🛑 A MEROESZKOZ MEGALLT: az ELES szkript veletlenul modosult a mutacio soran." >&2
  exit 2
}

# ── T7: ALAPERTELMEZETT GYOKEREK -- $HOME/Source, $HOME/Marveen, $HOME/Work MIND lefedve ──────
echo
echo "T7 -- alapertelmezett bejaras: HOME alatt harom fa, mindharomban egy-egy ahead repo"

FHome="$FTmp/home"
mkdir -p "$FHome/Source" "$FHome/Marveen" "$FHome/Work"

R7S=$(new_synced_repo t7-source "$FHome/Source")
add_unpushed_commit "$R7S" "2026-09-01T09:00:00" "source-ahead"

R7M=$(new_synced_repo t7-marveen "$FHome/Marveen")
add_unpushed_commit "$R7M" "2026-09-01T09:00:00" "marveen-ahead"

R7W=$(new_synced_repo t7-work "$FHome/Work")
add_unpushed_commit "$R7W" "2026-09-01T09:00:00" "work-ahead"

OUT7=$(HOME="$FHome" bash "$CScript" 2>&1)

expect_contains "T7 Source-beli repo szerepel (alap gyoker)"    IGEN "$R7S" "$OUT7"
expect_contains "T7 Marveen-beli repo szerepel (alap gyoker)"   IGEN "$R7M" "$OUT7"
expect_contains "T7 Work-beli repo szerepel (alap gyoker)"      IGEN "$R7W" "$OUT7"

# ── M3: MUTACIO -- az alapertelmezett gyoker visszaszukitese $HOME/Source-ra ───────────────────
echo
echo "M3 -- mutacio: az alapertelmezett gyoker visszaszukitve \$HOME/Source-ra"

FMut3="$FTmp/mutant-egy-gyoker.sh"
cp "$CScript" "$FMut3"
BASE3=$(git hash-object "$CScript")

python3 - "$FMut3" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'FRoots=("$HOME/Source" "$HOME/Marveen" "$HOME/Work")'
n = s.count(old)
assert n == 1, "A MUTACIO NEM ALKALMAZHATO: a minta %d-szer illeszkedik" % n
s = s.replace(old, 'FRoots=("$HOME/Source")')
open(p, 'w').write(s)
PYEOF

if [ "$(git hash-object "$FMut3")" = "$BASE3" ]; then
  echo "  ❌ M3 A MUTACIO NEM TORTENT MEG (a masolat hash-e valtozatlan)"
  FFail=$((FFail + 1))
else
  OUT_MUT3=$(HOME="$FHome" bash "$FMut3" 2>&1)
  if echo "$OUT_MUT3" | grep -qF "$R7M"; then
    echo "  ❌ M3 a mutans is latja a Marveen-beli repot -- a T7 orzes VAK lehet"
    echo "$OUT_MUT3" | sed 's/^/       | /'
    FFail=$((FFail + 1))
  else
    echo "  ✅ M3 a mutans elnemitja a Marveen/Work-beli sort -- a T7 orzes valodi"
    FPass=$((FPass + 1))
  fi
fi

[ "$(git hash-object "$CScript")" = "$BASE3" ] || {
  echo "  🛑 A MEROESZKOZ MEGALLT: az ELES szkript veletlenul modosult a mutacio soran." >&2
  exit 2
}

# ── T8: --stats -- a bejart EGYEDI repo-szam egyezzen a fuggetlen, KOZOS-git-dir-dedupe szammal ─
#     🛑 KARTYA-KIEGESZITES (Marveen visszamerese, msg_id:10209): a nyers .git-bejegyzes-szamot
#     (find | sort -u) a worktree-k tobbszorozik -- egy repo N worktree-vel N-szer szamit. A
#     fuggetlen mero ezert NEM a nyers path-ot, hanem a KOZOS git-konyvtar (git rev-parse
#     --git-common-dir, abszolut utra hozva) szerint dedupe-ol -- ugyanazt kell tegye a szkript is.
echo
echo "T8 -- --stats: a bejart repo-szam egyezzen a fuggetlen, kozos-git-dir szerinti szamlalassal"

FVart=$(
  find "$FRoot" -maxdepth 10 -name ".git" \( -type d -o -type f \) 2>/dev/null | sort -u | while IFS= read -r gd; do
    r="${gd%/.git}"
    c=$(cd "$r" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)
    [ -n "$c" ] && (cd "$r" && cd "$c" 2>/dev/null && pwd -P)
  done | sort -u | wc -l | tr -d ' '
)
OUT8=$(bash "$CScript" --root "$FRoot" --stats 2>&1)

expect_contains "T8 a --stats a fuggetlenul szamolt repo-szamot adja" IGEN "bejaras: $FVart egyedi repo" "$OUT8"

# ── T10: WORKTREE -- ugyanaz a repo KET munkafaval NEM szamit ketszer a --stats-ban ────────────
#     🛑 MERT TENY (Marveen elo merese): a nyers .git-bejegyzes-dedupe (T8 REGI alakja) a
#     worktree-ket tobbszorozta -- egy repo tobb worktree-vel annyiszor szamitott, ahany worktree-je
#     van. Ez a teszt EZT a hibaosztalyt fedi: KET munkafa, EGY kozos git-adatbazis -- a --stats
#     szama 1 legyen, NE 2. A FO CIKLUS viszont TOVABBRA IS mindket munkafat KULON vizsgalja
#     (mindegyiknek sajat checkout-olt aga, sajat "ahead" allapota lehet).
echo
echo "T10 -- worktree: egy kozos git-adatbazis ket munkafaval a --stats-ban EGYSZER szamit"

FRoot10="$FTmp/root10"
mkdir -p "$FRoot10"
R10=$(new_synced_repo t10-fo "$FRoot10")
add_unpushed_commit "$R10" "2026-09-01T10:00:00" "fo-agi unpushed"

R10W="$FRoot10/t10-worktree"
gitq "$R10" worktree add -q -b t10-masik-ag "$R10W"

NYERS10=$(find "$FRoot10" -maxdepth 10 -name ".git" \( -type d -o -type f \) 2>/dev/null | sort -u | wc -l | tr -d ' ')
[ "$NYERS10" = "2" ] || {
  echo "  🛑 A MEROESZKOZ VAK: a szintetikus worktree nem 2 nyers .git bejegyzest adott (kapott: $NYERS10)." >&2
  exit 2
}

OUT10=$(bash "$CScript" --root "$FRoot10" --stats 2>&1)

expect_contains "T10 a fo-agi repo tovabbra is szerepel a listaban" IGEN "$R10" "$OUT10"
expect_contains "T10 a --stats a DEDUPE-OLT szamot (1) adja, nem a nyerset (2)" IGEN "bejaras: 1 egyedi repo" "$OUT10"

# ── M4: MUTACIO -- a tavoli-nelkuli-ag felvetel eltavolitasa ───────────────────────────────────
echo
echo "M4 -- mutacio: a tavoli-nelkuli ag felvetele eltavolitva"

FMut4="$FTmp/mutant-nincs-tavoli.sh"
cp "$CScript" "$FMut4"
BASE4=$(git hash-object "$CScript")

python3 - "$FMut4" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = '[ "$remotes_count" = "0" ] || continue'
n = s.count(old)
assert n == 1, "A MUTACIO NEM ALKALMAZHATO: a minta %d-szer illeszkedik" % n
s = s.replace(old, 'continue')
open(p, 'w').write(s)
PYEOF

if [ "$(git hash-object "$FMut4")" = "$BASE4" ]; then
  echo "  ❌ M4 A MUTACIO NEM TORTENT MEG (a masolat hash-e valtozatlan)"
  FFail=$((FFail + 1))
else
  OUT_MUT4=$(bash "$FMut4" --root "$FRoot" 2>&1)
  if echo "$OUT_MUT4" | grep -qF "$R4"; then
    echo "  ❌ M4 a mutans is kiirja a tavoli-nelkuli repot -- a T4 orzes VAK lehet"
    echo "$OUT_MUT4" | sed 's/^/       | /'
    FFail=$((FFail + 1))
  else
    echo "  ✅ M4 a mutans elnemitja a tavoli-nelkuli repot -- a T4 orzes valodi"
    FPass=$((FPass + 1))
  fi
fi

[ "$(git hash-object "$CScript")" = "$BASE4" ] || {
  echo "  🛑 A MEROESZKOZ MEGALLT: az ELES szkript veletlenul modosult a mutacio soran." >&2
  exit 2
}

# ── T9: VAN tavoli, VAN azonos nevu tavoli AG, DE a lokalis ag NINCS configban kotve hozza ─────
#     🛑 MERT TENY (elo futtatas a karya bekotese utan): a Marveen repo SAJAT 57+ commitos aga
#     PONTOSAN ez az eset -- ket remote is van (origin, upstream), de a `branch.<name>.remote`
#     config hianyzik, es a T7/M3 gyoker-bovites onmagaban NEM hozza vissza a sort. Ez tehat NEM
#     a T4b-fele meretlen allapot (aminel a remote-agnak SEHOL nincs nyoma): itt LETEZIK
#     `origin/<ag>` regebbi allapotban, csak a lokalis config nem trackeli.
echo
echo "T9 -- van tavolija a repo-nak es azonos nevu tavoli-ag is, de a lokalis ag nincs kotve"

R9=$(new_synced_repo t9-nincs-kotve-van-tavoli-ag "$FRoot")
add_unpushed_commit "$R9" "2026-09-02T10:00:00" "nem kotve unpushed"
gitq "$R9" branch -q --unset-upstream

OUT9=$(bash "$CScript" --root "$FRoot" 2>&1)

expect_contains "T9 nem-kotve, de van-tavoli-ag repo SZEREPEL"      IGEN "$R9" "$OUT9"
expect_contains "T9 a cimke 'ahead=NINCS-KOTVE(1)'"                 IGEN "ahead=NINCS-KOTVE(1)" "$OUT9"
expect_contains "T9 a LEGREGEBBI (egyetlen) datum (09-02) szerepel" IGEN "2026-09-02" "$OUT9"

# ── M5: MUTACIO -- a nem-kotve-de-van-tavoli-ag felderites eltavolitasa ────────────────────────
echo
echo "M5 -- mutacio: a nem-kotve-de-van-tavoli-ag felderites kivalasztva a szkriptbol"

FMut5="$FTmp/mutant-nincs-kotve.sh"
cp "$CScript" "$FMut5"
BASE5=$(git hash-object "$CScript")

python3 - "$FMut5" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'remote="$r"'
n = s.count(old)
assert n == 1, "A MUTACIO NEM ALKALMAZHATO: a minta %d-szer illeszkedik" % n
s = s.replace(old, 'remote=""')
open(p, 'w').write(s)
PYEOF

if [ "$(git hash-object "$FMut5")" = "$BASE5" ]; then
  echo "  ❌ M5 A MUTACIO NEM TORTENT MEG (a masolat hash-e valtozatlan)"
  FFail=$((FFail + 1))
else
  OUT_MUT5=$(bash "$FMut5" --root "$FRoot" 2>&1)
  if echo "$OUT_MUT5" | grep -qF "$R9"; then
    echo "  ❌ M5 a mutans is kiirja a nem-kotve repot -- a T9 orzes VAK lehet"
    echo "$OUT_MUT5" | sed 's/^/       | /'
    FFail=$((FFail + 1))
  else
    echo "  ✅ M5 a mutans elnemitja a nem-kotve repot -- a T9 orzes valodi"
    FPass=$((FPass + 1))
  fi
fi

[ "$(git hash-object "$CScript")" = "$BASE5" ] || {
  echo "  🛑 A MEROESZKOZ MEGALLT: az ELES szkript veletlenul modosult a mutacio soran." >&2
  exit 2
}

# ── Osszegzes ─────────────────────────────────────────────────────────────────
echo
echo "EREDMENY: $FPass rendben | $FFail elter"
[ "$FFail" -eq 0 ] || exit 1
echo "✅ Minden eset a vart eredmenyt adta."
exit 0
