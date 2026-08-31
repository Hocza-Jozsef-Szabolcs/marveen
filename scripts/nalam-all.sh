#!/bin/bash
# hu: MI VAR RAM -- a munka-motor kor ELSo lepese.
#
#     Kiirja azokat a `waiting` VAGY `done` kartyakat, amelyeknel az utolso komment
#     szerzoje NEM en vagyok -- akar mert egy masik fej dontest kervo kerdest tett
#     le nalam (`waiting`), akar mert lezart egy sajat kartyat anelkul, hogy engem
#     ertesitett volna (`done`). Ha ures: nincs nalam eldontendo/tudomasul-veendo tetel.
#
#     MIERT LETEZIK EZ A SZKRIPT (merve, KETSZER 24 oran belul):
#       2026-08-15 17:5x -- `ordog` + `kutato`, 72 es 45 perc
#       2026-08-16 01:00 -- `avalonia` (`a9cac1ca`), 2 ora 10 perc
#     Mindharom esetben a fej HELYESEN jart el: a dontes-kerest a KARTYARA irta,
#     uzenet nelkul (7/c "NYUGTAZAS NINCS"). Ezert a `pending` sor URES volt, es
#     egyik beakadas-detektor sem szolt. A lekerdezes ott all a munka-motor
#     SKILL.md-jeben -- es megis kimaradt, ketszer.
#
#     A KOR, AMI EBBoL BEZARUL: minel fegyelmezettebb a fej, annal csendesebb a
#     varakozas. A megoldas NEM az, hogy a fejek uzenetet is kuldjenek (az
#     visszahozna a kor-szaporitast), hanem hogy ez EGY PARANCS legyen, a kor
#     elejen, ami nem mulik az emlekezeten.
#
#     A SZuRo AZ UTOLSO KOMMENT SZERZoJE, NEM IDoABLAK. Az idoablak azt szuri,
#     MIKOR mozdult a kartya, nem azt, hogy KI mozditotta -- vagyis a sajat melle
#     irasaimat is visszaadna. Merve 2026-08-15: idoablakkal 30 sor, igy 15.
#
#     🛑 KIBoVITVE `done`-nal is (2026-08-24, Jozsi kerdesere: "ki csinalja Zolinak
#     a dokumentaciot?" -- delphi lezart egy kartyat kommenttel+statuszvaltassal,
#     uzenet nelkul, es ez KIZAROLAG azert derult ki, mert Jozsi rakerdezett).
#     A `waiting`-re irt mero NEM latta ezt: a kartya `done` volt, nem `waiting`.
#     Ugyanaz a hibaosztaly, csak a masik statuszon -- ezert ugyanaz a mero fedi,
#     nem uj szkript: egy `done` sor is "nalam all", amig en magam nem kommentelek/
#     reagalok ra (a sajat kommentem torli a sort a listarol, UGYANUGY mint a
#     waiting-nel).
#
# en: WHAT IS WAITING ON ME -- first step of the work-engine round.
#     Lists `waiting` OR `done` cards where the last comment author is NOT me --
#     either a decision request left on me (`waiting`), or a card another agent
#     closed without notifying me (`done`). Empty output means nothing is pending.

set -uo pipefail

DB="${MARVEEN_DB:-/Users/ceo/Marveen/store/claudeclaw.db}"
ME="${1:-marveen}"

if [ ! -r "$DB" ]; then
  echo "nalam-all: az adatbazis nem olvashato: $DB" >&2
  exit 2
fi

rows=$(sqlite3 -separator '|' "$DB" "
  SELECT k.id,
         k.status,
         (SELECT author FROM kanban_comments c WHERE c.card_id=k.id
           ORDER BY created_at DESC LIMIT 1) AS utolso,
         CAST(ROUND((strftime('%s','now') - k.updated_at) / 60.0) AS INTEGER) AS perc,
         substr(k.title, 1, 60)
    FROM kanban_cards k
   WHERE k.assignee = '$ME'
     AND k.status IN ('waiting','done')
     AND k.archived_at IS NULL
     AND (SELECT author FROM kanban_comments c WHERE c.card_id=k.id
           ORDER BY created_at DESC LIMIT 1) <> '$ME'
   ORDER BY k.updated_at DESC;")

if [ -z "$rows" ]; then
  echo "nalam-all: nincs nalam eldontendo/tudomasul-veendo tetel ($ME)."
  # Pozitiv kontroll a nullahoz: a szuro NELKULI szam. Ha ez is 0, a kerdes
  # targytalan; ha ez nagy es a fenti 0, akkor MINDEN waiting/done kartyan en
  # irtam utoljara -- az is ervenyes allapot, de mondjuk ki, ne latszodjon uresnek.
  osszes=$(sqlite3 "$DB" "SELECT count(*) FROM kanban_cards
             WHERE assignee='$ME' AND status IN ('waiting','done') AND archived_at IS NULL;")
  # A ket eset KULONBOZo, es a kulonbseg szamit -- egy "nincs talalat" szoveg,
  # ami nulla elemre is allit valamit, maga a nema hiba:
  if [ "${osszes:-0}" -eq 0 ]; then
    echo "  (hatokor: $ME neven EGYETLEN 'waiting'/'done' kartya sincs -- a kerdes targytalan)"
  else
    echo "  (hatokor: $osszes db 'waiting'/'done' kartya all $ME neven, de MINDEGYIKEN"
    echo "   $ME irt utoljara -- vagyis egyiket sem MAS fej tette le/zarta le csendben)"
  fi
  exit 0
fi

# 🛑 A CIMKE CSAK A SAJAT NEZoPONTRA IGAZ -- a negativ kontroll fogta meg
#    (2026-08-16 03:0x, sajat eszkoz). A szuro annyit mond, hogy az UTOLSO KOMMENT
#    SZERZoJE NEM az assignee. A `marveen`-re futtatva ez tenyleg azt jelenti,
#    hogy egy masik fej tette le nalam. DE egy MASIK fejre futtatva (`delphi`)
#    az `utolso=marveen` sorok azt jelentik, hogy EN irtam neki utoljara --
#    vagyis EN varakoztatom, nem o tette le nalam. Ugyanaz a sor, ellentetes
#    jelentes. Ezert a fejlec a SEMLEGES tenyt mondja ki, es az ertelmezes
#    csak a sajat esetre all.
if [ "$ME" = "marveen" ]; then
  echo "nalam-all: MAS FEJ TETTE LE NALAM VAGY ZART LE CSENDBEN -- olvasd el az UTOLSO KOMMENTET mindegyiken!"
  echo "  (status=waiting: dontes-keres. status=done: a fej lezarta, DE nem ertesitett -- neked kell eszrevenned.)"
else
  echo "nalam-all: '$ME' neven allo 'waiting'/'done' kartyak, ahol az UTOLSO KOMMENTET NEM $ME irta."
  echo "  (FIGYELEM: ha az 'utolso' oszlopban marveen all, azt EN irtam NEKI --"
  echo "   vagyis o var RAM, nem forditva. A cimke iranya fejenkent mas.)"
fi
printf '%s\n' "$rows" | while IFS='|' read -r id statusz utolso perc cim; do
  printf '  %-52s  %-8s  %-10s  %5s perc  %s\n' "$id" "$statusz" "$utolso" "$perc" "$cim"
done
