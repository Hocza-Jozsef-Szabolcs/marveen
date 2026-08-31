#!/bin/bash
# hu: BUILD-SZAM UTKOZES-KAPU -- commit ELoTTI ellenorzo, worktree-k KOZOTT is mer.
#
# MIERT LETEZIK: a BuildNumberV2.txt a $(QaeBuild)-en at a FileVersion/InformationalVersion resze,
# tehat a SZOFTVER VERZIOSZAMANAK resze. A 8/2025 NGM 23. § (1) szerint a verzioszam "a szoftver
# programverziojanak EGYEDI AZONOSITOJA". KET AGON AZONOS SZAM = KET KULONBOZo BINARIS UGYANAZZAL
# AZ AZONOSITOVAL.
#
# 🛑 A KAPU AZ AZONOS ERTEK ELoFORDULASAT NEM TILTJA -- A VISSZATERES-T TILTJA.
#    Ket lepteles kozott MINDEN commit ugyanazt a szamot mutatja: az a szam NORMALIS ELETTARTAMA.
#    Valodi utkozes az, ha a szam egy MASIK ertek utan UJRA megjelenik (9 -> 10 -> 9).
#    (Egy 2026-08-09-i audit ezt osszekeverte, es negy "duplikatumot" allitott ott, ahol nulla volt.)
#
# 🛑 KET MODSZER KELL, MERT MAST MERNEK, ES EGYIK SEM RESZHALMAZA A MASIKNAK:
#    (1) VISSZATERES: minden commiton kiolvasott ertek, egy ertek ujra megjelenik-e masik utan.
#    (2) FAJL-VALTOZAS: a fajlt ERINTo commitok kozul ketto azonos erteket mutat (pl. merge-feloldas,
#        ahol a fajl "valtozott", de az ertek maradt).
#    A JokerQ-n a (2) adta a 620-at, az (1) a 602/729/777-et -- a teljes kep a kettojuk unioja.
#
# EGY HARMADIK, KULON HIBAOSZTALY: a COMMIT-CIM mas build-szamot hirdet, mint a fajl tartalma.
#    Ez nem azonosito-utkozes, hanem HAMIS DOKUMENTACIO -- de ugyanaz a kar: a kovetkezo olvaso
#    tenykent hasznalja. Ismert eset mindket repoban (QCassa 4b5ea94/cfde0b4, JokerQ 5af6597).
#
# A KAPU SEMMIT NEM JAVIT ES NEM IR AT -- csak jelent. A tortenet valtozatlan marad.
#
# 🛑 A KAPU MONDJA KI, MELYIK KONVENCIOT FELTETELEZI (avalonia merese, JokerQ-SDK, 2026-08-14):
#    egy repo vagy MINDEN commiton lepteti a szamot, vagy csak KIADASONKENT -- ez a repobol nem
#    szarmaztathato, repo-szinten kapcsolhato a `scripts/build-number-conventions.json`-ban. EZT A
#    KONVENCIOT OLVASSA A build-number-commit-gate.mjs (PreToolUse hard-gate) IS -- egy kozos fajl,
#    kulonben a hook ott is leptetest kenyszeritene, ahol ez a mero szerint nem is kell.
#
# en: BUILD NUMBER COLLISION GATE -- pre-commit check that also measures ACROSS worktrees.
#     It does NOT forbid a repeated value (that is a number's normal lifetime between bumps); it
#     forbids a RETURNING value. Two detectors are needed because they measure different things and
#     neither is a subset of the other. A third, separate class: the commit SUBJECT announcing a
#     different build number than the file holds.
#
# 🛑 NINCS "GYORS MOD", ES EZ MERT DONTES -- NEM EGYSZERuSITESI KENYELEM:
#   (a) A LELET-KOR nem szukitheto INGYEN: a koltseg a BEJARAS (egy `git log` + egy
#       `git cat-file --batch`), nem a detektorok. MERVE a JokerQ-n: log 33 ms, first-parent 13 ms,
#       batch 38 ms, worktree-lista 9 ms; mind a negy detektor EBBoL AZ EGY beolvasott adathalmazbol
#       szamol, tiszta pythonban. Egy detektor kihagyasa nulla masodpercet sporolna, cserebe egy MAR
#       KISZAMOLT sertest rejtene el. A cim-elteres raadasul az EGYETLEN lelet, amit kizarolag
#       COMMIT-IDoBEN lehet javitani -- utana be van egetve a tortenetbe.
#   (b) A MELYSEG sem szukitheto: a VISSZATERES-detektor a leghosszabb memoriara epul, es van olyan
#       valos alak, amit CSAK o lat -- oldalagon ujra kiadott szam, ahol az elso-szulo lancon NINCS
#       csokkenes. Barmely veges ablak epp ezt a detektort vakitja el. MERVE (JokerQ): 60 commit
#       187 ms · 200 commit 206 ms · 500 commit 216 ms · TELJES tortenet (838 commit) 252 ms;
#       QuantumAE teljes (1363 commit) 293 ms. *** A melyseg nem szuk keresztmetszet. ***
#   Ezert az alapertelmezes a TELJES tortenet, es `--quick` kapcsolo NINCS: egy kapcsolo, amirol a
#   hivo azt hiszi, hogy szukebb modban fut, ugyanaz a nema csapda, mint amit a kapu keres.
#   Ha valaha kell valodi gyors mod, az UJ kapcsolo lesz, mert lesz mit sporolnia.
#
# HASZNALAT / USAGE:
#   buildszam-utkozes-kapu.sh                          # a HIVO repoja, TELJES tortenet
#   buildszam-utkozes-kapu.sh --repo /path/to/repo     # adott repo (tobbszor is adhato)
#   buildszam-utkozes-kapu.sh --all                    # MINDEN repo a gyokerek alatt (lassu, opt-in)
#   buildszam-utkozes-kapu.sh --root /Users/ceo/Source # sajat gyoker (--all-lal ertelmes)
#   buildszam-utkozes-kapu.sh --limit 200              # SEKELYEBB bejaras (alap: teljes tortenet)
#
# EXIT: 0 = nincs lelet | 1 = LELET (utkozes, hamis cim vagy ERTELMEZHETETLEN ertek) | 2 = hasznalati hiba

set -uo pipefail

CScriptDir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CBuildFile="BuildNumberV2.txt"
# hu: A KONVENCIO-KAPCSOLO KOZOS FORRASA A build-number-commit-gate.mjs-szel (marveen, kartya-komment
#     1928): az a hook MINDEN release-agi commitnal megkoveteli a fajl staged-jelenletet -- ha egy
#     repo valojaban csak KIADASONKENT lep (JokerQ-SDK, avalonia merese: az utolso 8 commit mind
#     53-at hordozza), a hook ott kikenyszeriti a leptetest, ahol a mero szerint nem is kell. EGY
#     kozos JSON-t olvas mindket oldal, kulonben szetcsuszhatnak. `BSZ_CONVENTIONS_PATH` teszteknek.
# en: SHARED source for the convention switch with build-number-commit-gate.mjs -- see there. One
#     JSON file read by both sides so they cannot disagree on which repos are release-only bumpers.
CConventionsPath="${BSZ_CONVENTIONS_PATH:-$CScriptDir/build-number-conventions.json}"
# hu: 0 = NINCS MELYSEG-KORLAT (a teljes tortenet). Lasd a fejlec „a melyseg nem szukithet" reszet.
# en: 0 = NO depth limit (walk the whole history).
CDefaultLimit=0
# hu: REFERENCIAPONT (kartya ec51fef8 / #1241): a check_history csak a referenciaponton VAGY UTANA
#     szuletett commitokon alapulo leletre BLOKKOL (rc=1) -- a korabbi, mar beegett tortenelmi
#     leletek tovabbra is KIIRODNAK, de nem allitjak meg a hivot. Az alapertek a kapu tenyleges
#     bevezeto commitjanak (`7bf014f`) SAJAT masodperc-pontos idobelyege -- `git show -s
#     --format=%ct 7bf014f` -> 1788181705 (2026-08-31T15:08:25+02:00), NEM csak a napja.
#     🛑 A NAP-PONTOSSAGU alak (vaszon merese) egy UGYANAZON a napon, DE 7bf014f oraja ELoTT
#        szuletett commitot (QuantumAE `78071c54`, 00:51) is a referenciapontnal "kesobbinek"
#        latott -- tovabbra is blokkolt, holott a kapu csak aznap 15:08-kor lepett eletbe.
#     `BSZ_REFERENCE_DATE` teszteknek (lasd `build-szam-utkozes-meres`-t hasznalo szintetikus
#     repok) -- barom alakot fogad el: UNIX-masodperc, YYYY-MM-DD, vagy teljes ISO 8601 idobelyeg.
# en: REFERENCE POINT: check_history only BLOCKS on findings anchored to a commit born ON OR AFTER
#     this moment -- older, already-baked-in findings still print, they just do not stop the
#     caller. The default is the introducing commit's (`7bf014f`) own second-precision timestamp,
#     not merely its calendar day (a day-precision boundary let a same-day-but-earlier commit
#     slip through -- see the comment in check_history for the measured case).
CReferenceDate="${BSZ_REFERENCE_DATE:-1788181705}"

FRoots=()
FRepos=()
FLimit=$CDefaultLimit
FLimitGiven=0
FAll=0
FArgCount=$#

# ── Parancssor ────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --root)  [ $# -ge 2 ] || { echo "HIBA: a --root ertek nelkul all"; exit 2; }; FRoots+=("$2"); shift 2 ;;
    --repo)  [ $# -ge 2 ] || { echo "HIBA: a --repo ertek nelkul all"; exit 2; }; FRepos+=("$2"); shift 2 ;;
    --limit) [ $# -ge 2 ] || { echo "HIBA: a --limit ertek nelkul all"; exit 2; }; FLimit="$2"; FLimitGiven=1; shift 2 ;;
    --all)   FAll=1;   shift ;;
    -h|--help) sed -n '2,56p' "$0"; exit 0 ;;
    *) echo "HIBA: ismeretlen kapcsolo: $1"; echo "      (a kapcsolok: --all --repo --root --limit --help)"; exit 2 ;;
  esac
done

# hu: A HATOKOR ALAPERTELMEZESE A HIVO REPOJA. Parameter nelkul a kapu NEM jarja be a gepet:
#     a teljes bejaras kifejezett `--all`-ra megy. Aki gyorsan akar merni, ne kelljen tudnia,
#     hogy melyik kapcsolo vedi meg a percektol.
# en: Default scope is the CALLER'S repo; the full sweep is opt-in via --all.
if [ ${#FRepos[@]} -eq 0 ] && [ ${#FRoots[@]} -eq 0 ]; then
  if [ "$FAll" -eq 1 ]; then
    FRoots=("$HOME/Source" "$HOME/Work")
  else
    FSelf=$(git rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$FSelf" ]; then
      FRepos=("$FSelf")
    else
      echo "HIBA: nem git-repoban allsz, es nincs --repo/--root/--all megadva."
      echo "      (a hatokor alapertelmezese a HIVO repoja -- itt nincs mibol dolgozni)"
      exit 2
    fi
  fi
fi

# hu: EGYSOROS HASZNALAT-KIIRAS a parameter nelkuli futas ELEJEN. A parameterezes ne a README-bol
#     derüljon ki: egy atmero, aki a nevet FELTETELEZI, a kapu hibajat meri, nem a repoet.
if [ "$FArgCount" -eq 0 ]; then
  echo "(alap: a hivo repoja, TELJES tortenet | --limit N = sekelyebb | --all = minden repo | --help)"
fi

# ── Repo-lista osszeallitasa ──────────────────────────────────────────────────
if [ ${#FRepos[@]} -eq 0 ]; then
  while IFS= read -r f; do
    FRepos+=("$(dirname "$f")")
  done < <(
    for r in "${FRoots[@]}"; do
      [ -d "$r" ] || continue
      find "$r" -name "$CBuildFile" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null
    done | sort -u
  )
fi

if [ ${#FRepos[@]} -eq 0 ]; then
  echo "HIBA: egyetlen $CBuildFile sem talalhato a megadott hatokorben."
  echo "      (Ha ez varatlan, a hatokor a hibas -- NEM az, hogy nincs build-szam sehol.)"
  exit 2
fi

FFindings=0
FCheckedRepos=0
FCheckedCommits=0
FCheckedSubjects=0
FUnreadable=0

if [ "$FLimit" -le 0 ] 2>/dev/null; then
  FDepthText="TELJES tortenet"
else
  FDepthText="$FLimit commit"
fi
echo "BUILD-SZAM UTKOZES-KAPU -- hatokor: ${#FRepos[@]} hely, commit-melyseg: $FDepthText"
echo

# hu: EGY WORKTREE KODALLAPOTANAK UJJLENYOMATA -- A LEMEZRoL, nem a commitbol.
#     Harom resz, mert egyik sem eleg onmagaban (mindharomra van eloallitott eset a mereseszkozben):
#       (1) `git diff HEAD`                -- a kovetett fajlok TARTALMA; az UJ fajlokat nem latja
#       (2) `git status --porcelain -uall` -- nevek es statuszok; az uj fajl JELENLETET fogja,
#                                             a TARTALMAT nem (ket eltero modositas azonos nevvel
#                                             ugyanazt a kimenetet adja)
#       (3) `git hash-object` az uj fajlokra -- az azonos nevu UJ fajl eltero tartalma
#     KOLTSEG: ~20-40 ms worktree-nkent, ezert a hivo CSAK akkor keri, ha van azonos-szam +
#     azonos-HEAD par. A tipikus futasban egyetlen extra git-hivas sem tortenik.
# en: Fingerprints a worktree's code state FROM DISK. Three parts, none sufficient alone; the caller
#     invokes it only for same-number + same-HEAD pairs, so the typical run pays nothing.
FFpCache="|"
FFp=""
worktree_fingerprint() {
  local wt="$1" rest

  # hu: Gyorsitotar -- egy worktree ujjlenyomata a futason belul valtozatlan, es tobb parban is
  #     szerepelhet. Ot azonos-HEAD worktree eseten a cache nelkul 8 szamitas fut 5 helyett
  #     (MERVE a QCassa.MHMI-n: 410 ms -> a cache-sel ~250).
  # en: Cache -- one worktree can appear in several pairs; without it five worktrees cost eight probes.
  case "$FFpCache" in
    *"|$wt="*)
      rest="${FFpCache#*|$wt=}"
      FFp="${rest%%|*}"
      return 0 ;;
  esac

  FFp=$(worktree_fingerprint_compute "$wt")
  FFpCache="$FFpCache$wt=$FFp|"
}

# hu: Ket worktree kodallapota ELTER-e. Kilepesi kod: 0 = elternek (tehat utkozes).
# en: Whether two worktrees hold different code states; exit 0 means they differ.
worktrees_differ() {
  local a b

  worktree_fingerprint "$1"; a="$FFp"
  worktree_fingerprint "$2"; b="$FFp"

  [ "$a" != "$b" ]
}

worktree_fingerprint_compute() {
  local wt="$1" f

  {
    git -C "$wt" rev-parse HEAD 2>/dev/null
    git -C "$wt" diff HEAD 2>/dev/null
    git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null

    git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null \
      | sed -n 's/^?? //p' \
      | while IFS= read -r f; do
          [ -f "$wt/$f" ] && git -C "$wt" hash-object -- "$f" 2>/dev/null
        done
  } | shasum 2>/dev/null | cut -d' ' -f1
}

# ── 1. WORKTREE-K KOZOTTI UTKOZES ─────────────────────────────────────────────
# hu: A kivalto eset: a JokerQ nyolc worktree-je szetszort szamokkal, es a Fo MUNKAKONYVTAR a main
#     MOGOTT allt -- a kovetkezo commitja egy MAR FOGLALT szamot adott volna.
# hu: A FoAG (repo GYOKERE, `git worktree list --porcelain` ELSo bejegyzese) EGYENES OSE-e egy
#     masik worktree-nek -- MASODIK lelet (kartya ec51fef8 / #1241, ordog merese): a QuantumAE
#     kamera-valto-szkenneles worktree-je (52a8dd1f) a fo ag akkori HEAD-jenek (950ba836) EGYENES
#     ose, ket koztes commit (38f128fb + merge) egyike sem leptette a szamot -- ez NEM ket kodallapot
#     egy azonositon, csak egy worktree, ami MEG NEM huzta be a fo ag azota erkezett munkajat.
#
# 🛑 AZ IRANY SZAMIT -- EZ NEM ALTALANOS "os-leszarmazott = nincs utkozes" SZABALY. A T12b eset (a
#     mero sajat regressziosteszje) PONT A FORDITOTTJA: ott a FoAG az OS, es egy WORKTREE lep elore
#     sajat, uj munkaval (peldaul `oldal.txt`) anelkul, hogy leptetne a szamot -- ez VALODI utkozes
#     marad, mert a worktree FUGGETLEN munkat ad hozza, amit a fo ag meg nem lat. A kizaras tehat
#     KIZAROLAG akkor all, ha a FoAG halad ELoRE es egy MASIK worktree marad EGYENES osen (elavult
#     checkout, semmi sajat munkaja nincs) -- forditva (a worktree halad elore a fo agtol) tovabbra
#     is jelez.
# en: DIRECTION matters -- this is NOT a blanket "ancestor => no collision" rule. T12b (this file's
#     own regression test) is the mirror case: there the PRIMARY worktree is the ancestor and a
#     worktree adds its OWN new work without bumping -- that must keep flagging. The exclusion only
#     fires when the PRIMARY has moved ahead and the OTHER worktree is a stale, unmodified checkout.
worktree_stale_ancestor_of_primary() {
  local repo="$1" primary_wt="$2" wt_a="$3" head_a="$4" wt_b="$5" head_b="$6"
  local primary_head other_head

  if [ "$wt_a" = "$primary_wt" ]; then
    primary_head="$head_a"; other_head="$head_b"
  elif [ "$wt_b" = "$primary_wt" ]; then
    primary_head="$head_b"; other_head="$head_a"
  else
    return 1
  fi

  [ "$other_head" != "$primary_head" ] || return 1
  git -C "$repo" merge-base --is-ancestor "$other_head" "$primary_head" 2>/dev/null
}

check_worktrees() {
  local repo="$1"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 0
  git -C "$repo" rev-parse --git-common-dir >/dev/null 2>&1 || return 0

  local seen_values="" line wt val head prev prev_head prev_wt dup="" primary_wt=""

  # 🛑 AZONOS SZAM ONMAGABAN NEM UTKOZES -- A KODALLAPOTNAK IS ELTERoNEK KELL LENNIE.
  #    MERT HAMIS RIASZTAS: a `QCassa.MHMI` ot worktree-je mind ugyanazon a commiton all, tiszta
  #    munkafaval, mind a 113-as szammal -- a szam-alapu osszevetes NEGY "utkozest" jelentett rajta.
  #
  # 🛑 DE A HEAD ONMAGABAN SZuK: AZ ERTEKET A LEMEZRoL OLVASSUK, TEHAT AZ AZONOSSAGNAK IS A LEMEZT
  #    KELL TUKROZNIE. Ket worktree allhat ugyanazon a commiton ELTERo commitolatlan tartalommal --
  #    az ket kulonbozo binaris ugyanazzal a build-szammal. A kartya sajat tezise ugyanez:
  #    *** az APK a MUNKAFABOL fordul, nem a HEAD-boL. ***
  #    A ket kezenfekvo mechanizmus KULON-KULON mast hagy ki, ezert MINDHAROM resz kell:
  #      `git diff HEAD`                     -- a kovetett fajlok TARTALMA (uj fajlokat nem lat)
  #      `git status --porcelain -uall`      -- a nevek/statuszok, az UJ fajlok JELENLETE (tartalmat nem)
  #      `git hash-object` az uj fajlokra    -- az azonos nevu UJ fajl ELTERo tartalma
  # en: The value is read from DISK, so identity must reflect the disk too -- HEAD alone is too narrow.
  #     Each of the three parts covers what the others miss.
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        wt="${line#worktree }"
        head=""
        # hu: `git worktree list --porcelain` MINDIG a FoAGGAL (a repo gyokerevel) kezdi a listat --
        #     ez az elso "worktree " sor a primary_wt.
        # en: The porcelain listing always starts with the PRIMARY worktree (the repo root).
        [ -n "$primary_wt" ] || primary_wt="$wt"
        continue ;;
      "HEAD "*)
        head="${line#HEAD }" ;;
      *) continue ;;
    esac

    [ -n "$wt" ] || continue
    [ -f "$wt/$CBuildFile" ] || continue
    val=$(tr -d '[:space:]' < "$wt/$CBuildFile" 2>/dev/null)
    [ -n "$val" ] || continue

    prev=$(echo "$seen_values" | grep "^$val|" | head -1)

    if [ -n "$prev" ]; then
      prev_head=$(echo "$prev" | cut -d'|' -f2)
      prev_wt=$(echo "$prev" | cut -d'|' -f3)

      if [ "$prev_head" != "$head" ]; then
        if worktree_stale_ancestor_of_primary "$repo" "$primary_wt" "$wt" "$head" "$prev_wt" "$prev_head"; then
          : # elavult, egyenes-osi checkout a fo ag mogott -- nem ket kodallapot, nincs lelet
        else
          dup="$dup$val|$wt|$prev_wt
"
        fi
      elif worktrees_differ "$wt" "$prev_wt"; then
        # hu: Azonos commit, ELTERo munkafa. A dragabb meres CSAK ide fut be -- ha nincs
        #     azonos-szam + azonos-HEAD par, egyetlen extra git-hivas sem tortenik.
        # en: Same commit, different working tree. The costlier probe runs only for this narrow case.
        dup="$dup$val|$wt (munkafa)|$prev_wt (munkafa)
"
      fi
    fi

    seen_values="$seen_values$val|$head|$wt
"
  done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)

  if [ -n "$dup" ]; then
    echo "  🛑 WORKTREE-UTKOZES ($repo):"
    echo "$dup" | while IFS='|' read -r v a b; do
      [ -n "$v" ] || continue
      echo "     build $v KET helyen: $a"
      echo "                          $b"
    done
    return 1
  fi

  return 0
}

# ── 2. VISSZATERES + 3. KIADAS-DUPLIKATUM + 4. CIM-ELTERES + 5. CSOKKENES ─────
#
# 🛑 A KIADAS DEFINICIOJA -- EZ A DETEKTOR MAGVA:
#    Egy commit AKKOR ad ki uj build-szamot, ha az ertek MINDEN SZULoJEHEZ kepest valtozott.
#    Merge-nel tehat a MASODIK szulohoz kepest is. Ha a merge azert "valtoztatja" a fajlt, mert a
#    behozott ag mar a magasabb szamot hordozza, az NEM uj kiadas -- ugyanaz a kiadas erkezik meg
#    egy masik agra.
#    MERVE (QuantumAE): `5dc45e30` szulo 735 -> 736 = valodi kiadas; `20f3e366` szuloi 686 ES 736,
#    az erteke 736 -- a masodik szulohoz kepest NEM valtozott, tehat nem kiadas. E szabaly nelkul a
#    kapu 18 duplikatumot allit ott, ahol 17 van. KET FUGGETLEN MERo adta elsore ugyanezt a 18-at.
# en: A commit RELEASES a number only if the value differs from EVERY parent -- including a merge's
#     second parent. Without this the gate reports one collision too many.
#
# 🛑 MIERT PYTHON A MAG, ES MIERT NEM BASH:
#    A szulo-osszevetes commitonkent tobb ERTEK-OLVASAST kivan, es a gepen bash 3.2 fut (nincs
#    asszociativ tomb). A string-alapu gyorsitotar NEGYZETESEN skalazodik: MERVE 50/100/200/400
#    commitra 0.9 / 2.3 / 9.3 / 56 masodperc. Egy kapu, ami percekig fut, KI LESZ KAPCSOLVA.
#    A python-mag EGYETLEN `git cat-file --batch` hivassal olvassa ki az osszes erteket.
# en: The core is Python because the parent comparison needs a real hash map; the bash string cache
#     measured quadratic (56 s at 400 commits). One `git cat-file --batch` call replaces N reads.
check_history() {
  local repo="$1" out rc measured

  out=$(BSZ_REPO="$repo" BSZ_FILE="$CBuildFile" BSZ_LIMIT="$FLimit" BSZ_REFERENCE_DATE="$CReferenceDate" python3 - <<'PYEOF'
import os
import re
import subprocess
import sys
from datetime import datetime

CRepo  = os.environ["BSZ_REPO"]
CFile  = os.environ["BSZ_FILE"]
CLimit = int(os.environ["BSZ_LIMIT"])

# hu: 0 (vagy negativ) = NINCS melyseg-korlat. A `-N` kapcsolo ilyenkor EL IS MARAD a `git log`-bol --
#     egy `-0` NULLA commitot adna vissza, vagyis a "teljes tortenet" szandekbol NEMA VAKSAG lenne.
#     (Elo is allt fejlesztes kozben; a kapu sajat „A MERo VAK" jelzese fogta meg.)
# en: 0 means NO limit, and the `-N` flag must be omitted entirely: `git log -0` returns nothing, so
#     the "whole history" intent would silently become blindness.
CDepthArgs = [] if CLimit <= 0 else ["-%d" % CLimit]

CCompanion = re.compile(r"\[(deploy|kapu|release)\]")
# hu: POZITIV HORGONY (kartya ec51fef8 / #1241, clicpu merese + sajat ellenorzes): a regi,
#     horgony nelkuli minta MINDEN "build NNN" emlitest sajat kihirdetesnek vett -- MERT ESET:
#     QuantumAE 8c457ec6 cime egy MASIK repo (JokerQ) 741-es buildjere hivatkozik, a fajlban 1077
#     all, semmi nem hirdet ellentmondast, megis "CIM ELTER"-t adott. A javitas: a szam csak akkor
#     SAJAT kihirdetes, ha a cim ELEJEN egy ismert kiadas-tipusu elotag all.
# 🛑 A `merge` KOTELEZo A LISTAN, NEM CSAK `chore|fix|feat|docs` (ahogy clicpu javasolta) -- SAJAT
#    MERES: a fejlecben dokumentalt ket ismert VALODI eset egyike (JokerQ `5af6597`, "merge: main
#    (build 728, sqlite-bionic asset) -> feat/plugin-tee-decryptor") EPP `merge:`-vel kezdodik.
#    A `chore|fix|feat|docs`-ra szukitett horgony EZT a mar dokumentalt talalatot HALKITOTTA VOLNA
#    EL -- a `merge` hozzaadasaval mindharom ismert valodi eset (QCassa 4b5ea94/cfde0b4, JokerQ
#    5af6597) tovabbra is illeszkedik, a QuantumAE 8c457ec6 hamis pozitiv pedig kiesik.
# en: POSITIVE ANCHOR: the number only counts as a SELF-announcement when the subject STARTS with
#     a known release-type prefix. `merge` is REQUIRED in the list (not just chore|fix|feat|docs,
#     as first proposed) -- one of the two real historical catches documented in this file's header
#     (JokerQ 5af6597) is itself a `merge:`-prefixed subject; without `merge` that known case would
#     silently stop firing.
CSubjBuild = re.compile(r"^(?:chore|fix|feat|docs|merge)(?:\([^)]*\))?:.*?\bbuild\s+([0-9]+)", re.IGNORECASE)


def git_text(*args):
    """hu: git-hivas szoveges kimenettel. en: git call returning text."""
    r = subprocess.run(["git", "-C", CRepo, *args],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return r.stdout.decode("utf-8", "replace")


def values_for(shas):
    """hu: EGY `git cat-file --batch` hivas -- a valasz BAJT-pontosan darabolva, nem sor-szinkronnal
       (a sor-szinkron elcsuszna, ha a fajl valaha tobb soros lenne).
       en: One batch call; the reply is split by byte length, not by line, so a multi-line file
       cannot silently desynchronise the parser."""
    shas = [s for s in shas if s]
    if not shas:
        return {}

    req = "".join("%s:%s\n" % (s, CFile) for s in shas).encode()
    r = subprocess.run(["git", "-C", CRepo, "cat-file", "--batch"],
                       input=req, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    out, pos, res = r.stdout, 0, {}

    for s in shas:
        nl = out.find(b"\n", pos)
        if nl < 0:
            break
        header = out[pos:nl].decode("utf-8", "replace").split()
        pos = nl + 1

        if len(header) == 3 and header[1] == "blob":
            size = int(header[2])
            res[s] = out[pos:pos + size].decode("utf-8", "replace").strip()
            pos += size + 1
        # hu: `<sha> missing` -- nincs tartalom-blokk, a pozicio mar a kovetkezo fejlecen all

    return res


branch = git_text("rev-parse", "--abbrev-ref", "HEAD").strip()

# hu: REFERENCIAPONT (kartya ec51fef8 / #1241): a kapu 2026-08-31-i bevezetese elott mar
#     beegett tortenelmi leletek NEM blokkolhatjak orokre a `wt done`-t -- a tortenet nem
#     valtoztathato meg. Csak azok a leletek BLOKKOLNAK (rc=1), amelyeknek a KIVALTO commitja a
#     referenciaponton VAGY utana szuletett -- a korabbiak tovabbra is KIIRODNAK (a tortenet
#     lathato marad), csak nem allitjak meg a hivot.
#
# 🛑 A HATAR MASODPERC-PONTOS IDoBELYEG, NEM NAP-PONTOSSAGU DATUM (vaszon merese, ec51fef8
#    utolagos hataresete): az elso alak `--date=short`-ot hasznalt (YYYY-MM-DD, lexikalis
#    osszehasonlitas) -- egy UGYANAZON a NAPON, DE A KAPU TENYLEGES BEVEZETESE ELoTT szuletett
#    commit (a QuantumAE `78071c54`, 00:51) igy `>=`-nek szamitott a "2026-08-31" hatarhoz kepest,
#    es TOVABBRA IS blokkolt, holott a kapu csak aznap KESoBB, `7bf014f`-nel (15:08) lepett eletbe.
#    A javitas: `%ct` (masodperc-pontos, TZ-fuggetlen UNIX-idobelyeg) mindket oldalon, es az
#    alapertelmezett referenciapont `7bf014f` SAJAT commit-idopontja, nem a napja.
# en: The boundary is a second-precision timestamp, not a calendar date -- the original
#    `--date=short` form let a same-day-but-earlier commit slip past the day-string comparison.
#    Fix: `%ct` (second-precision, TZ-agnostic unix epoch) on both sides, and the default
#    reference point is the introducing commit's own moment, not its calendar day.
CReferenceDate = os.environ.get("BSZ_REFERENCE_DATE", "").strip()


def parse_reference(value):
    """hu: A referenciapont MASODPERC-pontos UNIX-idobelyegre alakitasa. Harom bemeneti alak:
       (1) puszta UNIX-masodperc szam, (2) YYYY-MM-DD (a nap KEZDETE -- visszamenoleges
       kompatibilitas a korabbi, nap-pontossagu tesztekkel, ahol a napok kozott mindig van
       tobb-orás tavolsag), (3) teljes ISO 8601 idobelyeg (a valodi hasznalat -- a bevezeto
       commit teljes idopontja). Ertelmezhetetlen bemenetre None -- a hivo ilyenkor fail-closed
       blokkol, ahogy az ures CReferenceDate is tette korabban.
       en: Normalises the reference point to second-precision unix epoch. Three accepted shapes:
       raw epoch seconds, a bare YYYY-MM-DD date (start of day, kept for the older day-precision
       tests), or a full ISO 8601 timestamp (the real usage -- the introducing commit's exact
       moment). Unparseable input returns None -- callers stay fail-closed on that, same as the
       previous empty-string handling."""
    if re.fullmatch(r"[0-9]+", value):
        return int(value)
    try:
        dt = datetime.fromisoformat(value)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.astimezone()
    return int(dt.timestamp())


CReferenceEpoch = parse_reference(CReferenceDate) if CReferenceDate else None

commits = []
for line in git_text("log", "--format=%H|%P|%ct|%s", *CDepthArgs, "HEAD").splitlines():
    if not line.strip():
        continue
    sha, _, rest = line.partition("|")
    parents, _, rest2 = rest.partition("|")
    date, _, subject = rest2.partition("|")
    commits.append((sha, parents.split(), date, subject))

commit_date = {sha: int(date) for sha, _, date, _ in commits if date.isdigit()}


def blocks(sha):
    """hu: Ez a commit a referenciaponton VAGY utana szuletett-e -- csak ez blokkol.
       en: Whether this commit was born ON or AFTER the reference point -- only that blocks."""
    if CReferenceEpoch is None:
        return True
    return commit_date.get(sha, 0) >= CReferenceEpoch


CPreReferenceNote = "A REFERENCIAPONT ELoTT -- csak jelentve, nem blokkol"


def annotate(sha, text):
    """hu: A referenciapont ELoTTI sorokat megjeloli, hogy a hivo lassa: MIERT nem blokkol.
       en: Marks pre-reference lines so the caller sees WHY this line did not block."""
    if blocks(sha):
        return text
    return text + " (%s)" % CPreReferenceNote

first_parent = [c for c in git_text("log", "--first-parent", "--format=%H",
                                    *CDepthArgs, "HEAD").split() if c]

wanted = []
for sha, parents, _, _ in commits:
    wanted.append(sha)
    wanted.extend(parents)
wanted.extend(first_parent)
values = values_for(list(dict.fromkeys(wanted)))

parent_map = {sha: parents for sha, parents, _, _ in commits}

# (a) VISSZATERES: az ertek egy MASIK ertek utan ujra megjelenik-e -- LESZARMAZAS-TUDATOSAN
#     (kartya 8ce3fb7b, avalonia+marveen merese): a KORABBI alak a TELJES tortenetet EGY, flat,
#     datum-sorrendi vonalnak nezte -- ket FUGGETLEN, PARHUZAMOS ag (KOZOS elodbol elagazva,
#     mindketto SAJAT maga leptet) igy hamis "visszateres"-t adott, amint a ket ag commitjai a
#     datumban interlaceloltak (a JokerQ main klonjan: 4b38f2a->941 es 0b3d202->942 UGYANABBOL
#     az 940-es szuloboli agazik el, es a kesobb szuletett, DE 941-et OROKLo bbc0a73 commit a flat
#     bejarasban a 942 UTAN allt -- hamis "941 visszatert" lelet).
# 🛑 A JAVITAS: TOPOLOGIKUS bejaras (szulo mindig a gyermeke ELoTT), es minden commit a SAJAT
#    OSEITOL OROKOLT ertek-halmazt viszi tovabb. Egy visszateres csak akkor valodi, ha a commit
#    ertekE ELTER MINDEN SZULoJEToL (tehat tenyleges valtozas/kiadas -- ugyanaz a felteltel, mint
#    a (b) KIADAS-DUPLIKATUM detektornal), ES az uj ertek MAR SZEREPEL valamelyik SZULo SAJAT
#    OROKSEGEBEN -- vagyis a sajat OSEI kozott, nem barmelyik parhuzamos ag oseiben.
# en: FIX: topological walk (parents before children); each commit carries forward the union of
#    values inherited from its OWN ancestors. A return only counts if the value genuinely changed
#    (differs from every parent -- same condition as the duplicate-release detector) AND the new
#    value already appears in some parent's OWN inherited history -- not merely earlier in an
#    unrelated parallel branch's timeline.
topo_order = [c for c in git_text("log", "--reverse", "--topo-order", "--format=%H",
                                  *CDepthArgs, "HEAD").split() if c]

inherited = {}   # sha -> frozenset(values seen along ANY path reaching this commit, incl. itself)
returning = []   # [(sha, value), ...]
returning_vals = set()

for sha in topo_order:
    v = values.get(sha)
    parents = parent_map.get(sha, [])
    parent_sets = [inherited[p] for p in parents if p in inherited]
    combined = frozenset().union(*parent_sets) if parent_sets else frozenset()

    if v:
        parent_vals = [values.get(p) for p in parents]
        changed = all(pv != v for pv in parent_vals) if parent_vals else True
        if changed and v in combined and v not in returning_vals:
            returning.append((sha, v))
            returning_vals.add(v)
        combined = combined | {v}

    inherited[sha] = combined

checked_commits = 0
checked_subjects = 0
release_values = {}
duplicates = []          # [(sha, value), ...]
subject_mismatch = []    # [(sha, text), ...]

for sha, parents, _date, subject in commits:
    v = values.get(sha)
    if not v:
        continue
    checked_commits += 1

    # (b) KIADAS-DUPLIKATUM: ket KIADAS-commit ugyanazt az erteket adja ki
    #
    # 🛑 A KISERo-COMMIT NEM SERTES. A `[deploy]`/`[kapu]`/`[release]` utotagu commit SZANDEKOSAN
    #    nem leptet: a build-szam KIADAS-azonosito, nem commit-azonosito. Merve (JokerQ): az utolso
    #    60 build-szamot erinto commit kozul egyetlen kisero-utotagu van, es az 0 kodot visz.
    if not CCompanion.search(subject):
        is_release = all(values.get(p) != v for p in parents)

        if is_release:
            if v in release_values:
                if v not in [dv for _, dv in duplicates]:
                    duplicates.append((sha, v))
            else:
                release_values[v] = sha

    # (c) CIM-ELTERES: a commit CIME mas build-szamot hirdet, mint a fajl tartalma
    m = CSubjBuild.search(subject)
    if m:
        checked_subjects += 1
        if m.group(1) != v:
            subject_mismatch.append((sha, "     %s: a cim 'build %s'-t hirdet, a fajlban %s | %s"
                                    % (sha[:8], m.group(1), v, subject[:52])))

# (d) CSOKKENES az elso-szulo lancon -- a legelesebb alak, es a mai valos esetet is ez fogta meg
#     (777 -> 778 -> 777: a HEAD szama KISEBB, mint a szulojee). A szam SOSEM csokkenhet.
#
# 🛑 ES ITT VOLT A HARMADIK REPO-ALLAPOT, AMI ZOLDET ADOTT: a nem-numerikus erteket ez a ciklus
#    NEMAN atugorta. Harom allapot van, nem ketto:
#      (1) nincs fajl             -> "nem hasznal build-szamot", exit 0   -- helyes
#      (2) van, de URES           -> "A MERo VAK", exit 2                 -- helyes
#      (3) van ertek, de NEM SZAM -> "Nincs lelet", exit 0                -- HIBA VOLT
#    A (3) legelesebb alakja a FELOLDATLAN MERGE-KONFLIKTUS a fajlban: a kapu a konfliktus-markert
#    ERTEKNEK szamolja (a szamlalo "nem vak"-ot mutat), a szam-alapu detektorok atugorjak, es a
#    verdikt ZOLD -- egy „megoldom kesobb" merge atmegy azon a kapun, ami epp a merge-feloldast
#    celozza. Ezert a (3) mostantol BLOKKOL: egy konfliktus-marker a build-szam fajlban nem uzemi
#    allapot, es a javitasa trivialis -- a fail-closed ara itt nulla.
# en: A THIRD repo state existed and returned green: a value that is present but NOT A NUMBER (an
#     unresolved merge conflict being the sharpest shape). The ordering detectors skipped it
#     silently while the counter reported a non-blind measurement. It now BLOCKS.
decreasing = []          # [(sha, text), ...]
prev_num = None

# hu: Az ERTELMEZHETETLEN ertekek a TELJES bejart lancrol gyulnek, nem csak az elso-szulo agrol --
#     kulonben egy oldalagon allo konfliktus-marker ugyanugy atmenne, ahogy eddig mindegyik.
# en: Unreadable values are collected from the WHOLE walked history, not just the first-parent line.
unreadable = [
    (sha, "     %s: %s" % (sha[:8], " ".join(values[sha].split())[:60]))
    for sha, _, _, _ in commits
    if values.get(sha) and not values[sha].isdigit()
]

for sha in reversed(first_parent):
    v = values.get(sha)
    if not v or not v.isdigit():
        continue

    if prev_num is not None and int(v) < prev_num:
        decreasing.append((sha, "     %s: %d -> %s (CSOKKENT)" % (sha[:8], prev_num, v)))
    prev_num = int(v)

hit = False
out = []

# 🛑 MIND A NEGY LELET MINDIG KIIRODIK -- NINCS "gyors mod", ami valamelyiket elhagyna.
#    MERVE (JokerQ): a koltseg a bejaras -- `git log` 33 ms, first-parent log 13 ms,
#    `cat-file --batch` 38 ms (60 commit). A negy detektor mind EBBoL AZ EGY beolvasott
#    adathalmazbol szamol, tiszta pythonban: *** egyetlen detektor kihagyasa nulla masodpercet
#    sporolna. *** Amit a kihagyas ezzel szemben KOLTENE: a cim-elteres az EGYETLEN a negybol, amit
#    kizarolag COMMIT-IDoBEN lehet javitani -- utana be van egetve a tortenetbe.
# en: All four findings are always reported: every detector computes from the same single read, so
#     skipping one would save nothing -- while the subject mismatch is the only finding that can be
#     fixed exclusively at commit time.
#
# 🛑 A NEGY LELET MINDEGYIKE MOST MAR KETFELE SORT ADHAT (kartya ec51fef8 / #1241): a referenciapont
#    ELoTTI sor MINDIG kiirodik (annotate() jelzi, hogy miert nem blokkol), de csak a referenciaponton
#    VAGY utana szuletett sor allitja `hit`-et igazra. Egy lelet-tipus tehat blokkolhat UGY IS, hogy
#    a listaja tobbsegeben regi -- eleg EGY friss sor.
if decreasing:
    out.append("  🛑 A BUILD-SZAM CSOKKENT (%s, ag: %s) -- a szam SOSEM csokkenhet:" % (CRepo, branch))
    out.extend(annotate(sha, text) for sha, text in decreasing)
    hit = hit or any(blocks(sha) for sha, _ in decreasing)

if unreadable:
    out.append("  🛑 %d ERTEK ERTELMEZHETETLEN (%s, ag: %s) -- a rendezettseg ezeken NEM merheto:"
               % (len(unreadable), CRepo, branch))
    out.extend(annotate(sha, text) for sha, text in unreadable)
    out.append("     (tipikus ok: FELOLDATLAN MERGE-KONFLIKTUS a build-szam fajlban)")
    hit = hit or any(blocks(sha) for sha, _ in unreadable)

if returning:
    # 🛑 A FEJLEC-SOR (":" utani ertek-lista) MARAD SZoKOZZEL-TAGOLT, ANNOTALATLAN -- ezt olvassa
    #    GEPPEL a `wt.sh` hivo ES a mero sajat T7 tesztje (`sed 's/.*: //' | tr ' ' '\n'`). Az
    #    annotaciot KULON SORRA tesszuk, nem a listaba keverve -- egy inline szoveg-toldalek a
    #    szokozzel-tagolt tokeneket szetzuzna.
    out.append("  🛑 VISSZATERo BUILD-SZAM (%s, ag: %s): %s"
               % (CRepo, branch, " ".join(v for _, v in returning)))
    out.append("     (a szam egy MASIK ertek utan ujra megjelent -- ket kodallapot egy azonositon)")
    out.extend("     (%s: %s)" % (v, CPreReferenceNote) for sha, v in returning if not blocks(sha))
    hit = hit or any(blocks(sha) for sha, _ in returning)

if duplicates:
    out.append("  🛑 AZONOS ERTEK KET FAJL-VALTOZASBAN (%s, ag: %s): %s"
               % (CRepo, branch, " ".join(v for _, v in duplicates)))
    out.append("     (ket KIADAS-commit ugyanazt a szamot adta ki -- ket kodallapot egy azonositon)")
    out.append("     (a merge, ami mar meglevo szamot HOZ AT, NEM kiadas -- ki van zarva)")
    out.append("     (a [deploy]/[kapu]/[release] kisero-commitok szinten ki vannak zarva)")
    out.extend("     (%s: %s)" % (v, CPreReferenceNote) for sha, v in duplicates if not blocks(sha))
    hit = hit or any(blocks(sha) for sha, _ in duplicates)

if subject_mismatch:
    out.append("  🛑 COMMIT-CIM ELTER A FAJLTOL (%s, ag: %s) -- hamis dokumentacio:" % (CRepo, branch))
    out.extend(annotate(sha, text) for sha, text in subject_mismatch)
    out.append("     (ez az EGYETLEN lelet, amit kizarolag COMMIT-IDoBEN lehet javitani)")
    hit = hit or any(blocks(sha) for sha, _ in subject_mismatch)

print("\n".join(out)) if out else None
print("#MERT|%d|%d|%d" % (checked_commits, checked_subjects, len(unreadable)))
sys.exit(1 if hit else 0)
PYEOF
)
  rc=$?

  measured=$(printf '%s\n' "$out" | grep '^#MERT|' | tail -1)
  if [ -n "$measured" ]; then
    FCheckedCommits=$((FCheckedCommits + $(echo "$measured" | cut -d'|' -f2)))
    FCheckedSubjects=$((FCheckedSubjects + $(echo "$measured" | cut -d'|' -f3)))
    FUnreadable=$((FUnreadable + $(echo "$measured" | cut -d'|' -f4)))
  fi

  printf '%s\n' "$out" | grep -v '^#MERT|' | grep -v '^$'

  return $rc
}

# hu: EGY repo build-szam-konvencioja -- lasd a fejlecben a CConventionsPath megjegyzeset. Az elso
#     illeszkedo override nyer, kulonben az alapertelmezes. Olvasatlan/hianyzo config eseten
#     "minden-commit-leptet"-et ad (a mai, mar ervenyben levo viselkedes -- a hiba NEM tagithatja a
#     kapu hatokoret).
#
# 🛑 FUGGETLEN ATMERES (ordog, kartya-komment 3861) HAROM fail-open alakot talalt, MINDHAROM ITT
#    JAVITVA: (1) hianyzo repoPathPattern -> Python `re.search(None, ...)` TypeErrort dobott,
#    amit a bash-hivo URES konvencio-ertekkent latott -- a build-number-commit-gate.mjs oldalan
#    ugyanez `new RegExp(undefined)` = /(?:)/, ami MINDENRE illeszkedik, tehat a KET OLDAL nemcsak
#    hibazott, hanem MASKEPP hibazott. (2) ervenytelen regex -- ugyanigy csupasz kivetel volt.
#    (3) EZERT a validacio itt UGYANAZT a szabalyt koveti, mint a .mjs oldalon: minden mezot
#    tipus/ertek szerint ellenoriz HASZNALAT ELoTT, es egy hibas szabalyt KIHAGY (nem match-all,
#    nem crash) -- igy a ket oldal UGYANARRA a torott configra UGYANAZT a dontest hozza.
# en: A repo's build-number convention -- unreadable/missing config falls back to the
#     already-enforced default, so a broken config cannot widen the gate. Every rule field is
#     validated before use and an invalid rule is SKIPPED, matching build-number-commit-gate.mjs's
#     validation exactly so the two sides cannot diverge on the same malformed config.
convention_for() {
  local repo="$1"
  BSZ_REPO_FOR_CONV="$repo" BSZ_CONV_PATH="$CConventionsPath" python3 - <<'PYEOF'
import json
import os
import re
import sys

KKnownConventions = ("minden-commit-leptet", "kiadasonkent-leptet")

# Mirrors usesOnlyCommonRegexSubset() in build-number-commit-gate.mjs --
# SAME blocklist, same reasoning: python `re` and JS RegExp accept some
# constructs that mean something DIFFERENT on the other side without either
# side erroring (card #1085 point B / Marveen decision 3871 point 2). Keep
# the two lists in sync by hand; there is no shared runtime between a .mjs
# and a python heredoc to import from.
KDivergentConstructs = (
    re.compile(r"\(\?(?!:)"),   # any special group other than (?:...)
    re.compile(r"[*+?}]\+"),    # possessive quantifier -- python 3.11+ only
    re.compile(r"\\k<"),        # named backreference (JS \k<name> syntax)
    re.compile(r"\\[AZ]"),      # python-only \A/\Z -- JS reads them as "A"/"Z" literally
    re.compile(r"\\[pP]\{"),    # unicode property escape
)


def uses_only_common_regex_subset(pattern):
    return not any(rx.search(pattern) for rx in KDivergentConstructs)


def resolve():
    repo = os.environ["BSZ_REPO_FOR_CONV"].replace("\\", "/")
    path = os.environ["BSZ_CONV_PATH"]

    try:
        with open(path, encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception:
        return "minden-commit-leptet"

    overrides = cfg.get("overrides", [])
    if not isinstance(overrides, list):
        overrides = []

    for rule in overrides:
        if not isinstance(rule, dict):
            continue
        pattern = rule.get("repoPathPattern")
        convention = rule.get("convention")
        if not isinstance(pattern, str) or not pattern:
            continue
        if convention not in KKnownConventions:
            continue
        if not uses_only_common_regex_subset(pattern):
            continue
        try:
            matched = re.search(pattern, repo)
        except re.error:
            continue
        if matched:
            return convention

    default = cfg.get("defaultConvention")
    return default if default in KKnownConventions else "minden-commit-leptet"


try:
    print(resolve())
except Exception:
    # Utolso vedovonal -- barmilyen elo nem latott hiba is a mai, mar ervenyben levo
    # viselkedesre esik vissza, nem crashel es nem hagy URES erteket.
    print("minden-commit-leptet")
PYEOF
}

# ── Futtatas ──────────────────────────────────────────────────────────────────
# hu: A "NEM HASZNAL BUILD-SZAMOT" ES A "VAK MERES" KET KULONBOZo ALLAPOT, ES UGYANUGY NEZNEK KI:
#     mindketto NULLA kiolvasott erteket ad. Ha nem valasztjuk szet, a kapu MINDEN build-szam
#     nelkuli repoban hibaval all meg -- egy commit-hookban ez fals riasztas, es a kaput
#     kikapcsoljak. A dontes MERT: letezik-e a fajl a HEAD-en VAGY barhol a tortenetben.
# en: "repo has no build number" and "the measurement was blind" both yield zero readings; the gate
#     must tell them apart, otherwise it fails on every unrelated repo it is hooked into.
FSkipped=0

for repo in "${FRepos[@]}"; do
  [ -d "$repo" ] || continue
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || continue

  if ! git -C "$repo" cat-file -e "HEAD:$CBuildFile" 2>/dev/null; then
    if [ -z "$(git -C "$repo" log --format=%H -1 --all -- "$CBuildFile" 2>/dev/null)" ]; then
      echo "  ⏭️  KIHAGYVA ($repo): ez a repo nem hasznal $CBuildFile-t -- nincs mit merni."
      FSkipped=$((FSkipped + 1))
      continue
    fi
    echo "  ⚠️  A $CBuildFile a HEAD-en NINCS, de a tortenetben VAN ($repo) -- a meres folytatodik."
  fi

  FCheckedRepos=$((FCheckedRepos + 1))
  echo "  KONVENCIO ($repo): $(convention_for "$repo")"

  check_worktrees "$repo" || FFindings=$((FFindings + 1))
  check_history   "$repo" || FFindings=$((FFindings + 1))
done

echo
echo "MERT HATOKOR: $FCheckedRepos repo | $FCheckedCommits commit-ertek | $FCheckedSubjects build-szamot allito cim | $FUnreadable ERTELMEZHETETLEN ertek | $FSkipped kihagyva (nincs build-szam)"

# hu: POZITIV KONTROLL A MEROoN. Ha volt merendo repo, de egyetlen commit-erteket sem olvastunk ki,
#     a NULLA LELET nem eredmeny, hanem VAKSAG -- a hatokor rossz, nem a valosag tiszta.
# en: POSITIVE CONTROL ON THE MEASURING TOOL. Zero readings from a non-empty scope mean blindness.
if [ "$FCheckedRepos" -gt 0 ] && [ "$FCheckedCommits" -eq 0 ]; then
  echo "🛑 A MERo VAK: egyetlen commit-erteket sem olvasott ki. A hatokor hibas -- a 'nincs lelet' NEM allitas."
  exit 2
fi

if [ "$FFindings" -gt 0 ]; then
  echo "🛑 LELET: $FFindings helyen. A kapu NEM javit semmit -- a rendezes dontes kerdese."
  exit 1
fi

echo "✅ Nincs lelet a mert hatokorben."
exit 0
