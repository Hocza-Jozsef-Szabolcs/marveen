#!/bin/bash
# hu: BUILD-SZAM FOGLALAS-JELZES -- gepies jelzes arrol, hogy egy KOZOS munkafan (nem kulon
#     worktree-ken, hanem UGYANABBAN a konyvtarban dolgozo fejek) valaki MAS mar stage-elt egy uj
#     build-szamot, meg MIELoTT commitolna.
#
# MERT ESET (delphi, 2026-09-05, VHR5 7.4.1.61, kartya 800bd00c): a delphi commitolni keszult, es
# a munkafaban a `pascal` INDEXE allt -- `DVrMobile.pas` + `BuildNumberV2.txt` 229-cel STAGE-ELVE.
# A delphi ezt KIZAROLAG a masik fej tmux pane-jerol latta meg -- figyelem-alapu, nem gepies. Ket
# parhuzamos commit eseten (vagy ha a ket fej percnel kozelebb dolgozik) ez a vedelem NEM all fenn.
#
# MIERT MAS EZ, MINT A buildszam-utkozes-kapu.sh: az a TORTENETET (commitok) es a WORKTREE-KET
# (kulon konyvtarak, kulon index) hasonlitja ossze. Egy KOZOS munkafan, ahol KET fej UGYANAZT az
# indexet osztja meg egymas UTAN, egyetlen worktree van -- a worktree-detektor nem lat semmit, a
# masodik fej meg nem is commitolt. Az EGYETLEN jel, ami MAR MOST, COMMIT ELoTT is latszik: az
# INDEX (a staged tartalom) eltér a HEAD-tol. Ez a kapu EZT olvassa ki.
#
# 🛑 A KAPU CSAK OLVAS, ES NEM GIT-HOOKKENT FUT. Szandekosan NEM `git add`/`git commit` ele van
#    kotve: egy fej a SAJAT masodik/harmadik `git add`-ja (iteralas, javitas a stage-elt tartalmon)
#    UGYANUGY "index != HEAD"-et adna, mint egy IDEGEN foglalas -- git-allapotbol a ketto NEM
#    kulonbozteto (nincs per-fej metaadat az indexben). A helyes hasznalati pont ezert: FUTTASD
#    EZT A KAPUT, MIELoTT a SAJAT build-szam-valtoztatasodat eloszor stage-elned -- ha akkor ZOLDET
#    ad, a sajat kesobbi ujra-add-jaid mar nem szamitanak (nincs ok ujra futtatni ugyanazon korben).
#
# HASZNALAT / USAGE:
#   buildszam-foglalas-jelzes.sh                        # a HIVO repoja, BuildNumberV2.txt
#   buildszam-foglalas-jelzes.sh --repo /path/to/repo   # adott repo
#   buildszam-foglalas-jelzes.sh --file MasFajl.txt     # nem-alapertelmezett build-szam-fajl
#
# EXIT: 0 = nincs elo foglalas | 1 = Elo FOGLALAS (valaki mas mar stage-elte, HEAD-tol eltero
#       ertekkel -- varj a commitjara vagy egyeztess, MIELoTT te magad stage-elnel) | 2 = hasznalati
#       hiba (nem git repo, ismeretlen kapcsolo, stb.)

set -uo pipefail

CBuildFile="BuildNumberV2.txt"

FRepoArg=""
FFile="$CBuildFile"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || { echo "HIBA: a --repo ertek nelkul all"; exit 2; }; FRepoArg="$2"; shift 2 ;;
    --file) [ $# -ge 2 ] || { echo "HIBA: a --file ertek nelkul all"; exit 2; }; FFile="$2"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "HIBA: ismeretlen kapcsolo: $1"; echo "      (a kapcsolok: --repo --file --help)"; exit 2 ;;
  esac
done

# hu: A HATOKOR ALAPERTELMEZESE A HIVO REPOJA -- ugyanaz a dontes, mint a buildszam-utkozes-kapu.sh-ban.
if [ -n "$FRepoArg" ]; then
  if [ ! -d "$FRepoArg" ]; then
    echo "HIBA: a --repo utvonal nem letezik: $FRepoArg"
    exit 2
  fi
  FRepo=$(cd "$FRepoArg" && git rev-parse --show-toplevel 2>/dev/null)
else
  FRepo=$(git rev-parse --show-toplevel 2>/dev/null)
fi

if [ -z "$FRepo" ]; then
  echo "HIBA: nem git-repoban allsz, es nincs ervenyes --repo megadva."
  exit 2
fi

# hu: A "NEM HASZNAL BUILD-SZAMOT" allapot -- a fajl a HEAD-en nincs jelen. Ez NEM foglalas-kerdes:
#     ha a fejlecben MAGA a HEAD sem hordoz erteket, nincs mihez viszonyitani.
if ! git -C "$FRepo" cat-file -e "HEAD:$FFile" 2>/dev/null; then
  echo "⏭️  A $FFile a HEAD-en nincs jelen ($FRepo) -- ez a repo nem hasznal build-szamot (meg), nincs mit merni."
  exit 0
fi

# ── A DONTo LEPES: STAGE-ELT (INDEX) ELTER-E A HEAD-toL ──────────────────────
# hu: `git diff --cached --quiet -- <fajl>` NEM ir semmit, csak a kilepesi koddal jelez: 0 = nincs
#     elteres (a stage-elt tartalom BAJTRA egyezik a HEAD-del -- akkor is, ha kozben valaki ujra
#     `git add`-olta ugyanazt a tartalmat), 1 = van elteres. Ket felteteles allapot van, harmadik
#     nincs -- ez a git sajat, tartalom-cimzett index-osszevetese, nincs kulon allapot-fajl.
if git -C "$FRepo" diff --cached --quiet -- "$FFile"; then
  echo "✅ Nincs elo foglalas ($FRepo/$FFile) -- a stage-elt ertek egyezik a HEAD-del."
  exit 0
fi

FHeadVal=$(git -C "$FRepo" show "HEAD:$FFile" 2>/dev/null | tr -d '[:space:]')
FStagedVal=$(git -C "$FRepo" show ":$FFile" 2>/dev/null | tr -d '[:space:]')

echo "🛑 ELo FOGLALAS ($FRepo/$FFile): a HEAD erteke $FHeadVal, a STAGE-ELT (meg nem commitolt) erteke $FStagedVal."
echo "   Valaki MAS mar kivalasztott es stage-elt egy uj build-szamot ebben a kozos munkafaban."
echo "   NE stage-eld a sajat erteked ra -- varj a masik fej commitjara, vagy egyeztess vele."
exit 1
