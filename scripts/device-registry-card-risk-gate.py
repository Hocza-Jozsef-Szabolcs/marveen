#!/usr/bin/env python3
"""
hu: A `device-registry.sh check` KOCKAZAT-JELZES-KAPUJA. MERT ESET (kartya
    telepitesi-kapu-megvalaszolatlan-kockazat-jelzes-20260905, ordog merese): 2026-09-01
    16:13-kor az akka fej mert, dokumentalt figyelmeztetest irt a daa61441 kartyara az
    avalonia aznapi commitjara -- egy uj kapu AE Release-en NFC-erintest fog kerni egy
    olyan uton, ami ott PIN-alapu. A jelzesre nem erkezett valasz. 2026-09-03-an a hibas
    kodot tartalmazo build MASIK okbol (nyomtato-plugin) vegzett forditasbol felkerult
    egy eles eszkozre -- a device-registry.sh check addig KIZAROLAG munkafa-allapotot
    mert (branch/dirty/build-szam), kartya-adatot sehol nem kerdezett.

    MECHANIZMUS (marveen dontese, 2026-09-05): a telepitendo build kartya-hivatkozasait
    NEM a hivo adja meg -- a git-tortenetbol jonnek, a kotelezo "Kartya: #<seq> <id>" sor
    alapjan, minden `--repo` ADOTT AGANAK commitjaibol, a REFERENCIAPONT (e szkript
    bevezetesenek idopontja) OTA. Visszamenoleges blokkolas tilos: a mar meglevo, sosem
    "KOCKAZAT:" alakban irt figyelmeztetesek (pl. maga a daa61441-en allo, ami ezt a
    kartyat inditotta) nem allithatjak meg orokre a flottat. Egy kartya NYITOTT kockazatot
    hordoz, ha van rajta egy "KOCKAZAT:"-tal kezdodo komment, amit UGYANAZON a kartyan nem
    kovet kesobbi "KOCKAZAT-LEZARVA:"-val kezdodo komment.

    A "megvalaszolt" ez NEM kikovetkeztetett (nem "irt-e utana barki barmit") -- az ordog
    mert ellenvetese szerint ez hamis-negativ (a temat nem nezi). A lezarasnak EXPLICIT
    kell lennie, a jelzessel egyezo, felismerheto alakban.

    KIMENET: a jelentes soronkent a stdout-ra.
    KILEPESI KOD: 0 = a kapu nem blokkol, 1 = ALLJ MEG, 2 = hasznalati/meresi hiba.
"""
import os
import re
import sqlite3
import subprocess
import sys

# hu: A mechanizmus BEVEZETESENEK idopontja (2026-09-05 00:00:00 Europe/Budapest) -- csak
#     EZUTAN szuletett commitok esnek a kockazat-ellenorzes ala. Felulirhato tesztekhez
#     (DRCR_REFERENCE_EPOCH), ugyanaz a minta, mint a buildszam-utkozes-kapu.sh
#     referenciapontja.
REFERENCE_EPOCH = int(os.environ.get("DRCR_REFERENCE_EPOCH", "1788559200"))

# hu: A kanban DB utvonala -- felulirhato tesztekhez (DRCR_KANBAN_DB).
DEFAULT_DB_PATH = "/Users/ceo/Marveen/store/claudeclaw.db"

CARD_LINE_RE = re.compile(r"^K[aá]rty[aá]: #\d+ ([a-z0-9][a-z0-9-]*)\s*$", re.MULTILINE)
RISK_OPEN_RE = re.compile(r"^KOCKAZAT:", re.IGNORECASE)
RISK_CLOSE_RE = re.compile(r"^KOCKAZAT-LEZARVA:", re.IGNORECASE)


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)


def commits_since(repo, branch, epoch):
    """hu: (sha, unix-epoch, teljes commit-uzenet) harmasok a referenciapont OTA, az adott
       agon. None, ha a git-hivas maga sikertelen (nem ag-hiany -- azt a hivo kulon merte)."""
    r = git(repo, "log", "--format=%H%x01%ct%x01%B%x02", "refs/heads/%s" % branch)
    if r.returncode != 0:
        return None
    out = []
    for rec in r.stdout.split("\x02"):
        rec = rec.strip("\n")
        if not rec:
            continue
        sha, _, rest = rec.partition("\x01")
        ct_raw, _, msg = rest.partition("\x01")
        try:
            ct = int(ct_raw)
        except ValueError:
            continue
        if ct >= epoch:
            out.append((sha, ct, msg))
    return out


def card_for_commit(msg):
    """hu: a commit-uzenet 'Kartya: #<seq> <id>' sorabol az id, vagy None."""
    m = CARD_LINE_RE.search(msg)
    return m.group(1) if m else None


def open_risk_for_card(db_path, card_id):
    """hu: (szerzo, letrehozva, elorezet) harmas egy NYITOTT KOCKAZAT-kommentre ezen a
       kartyan, vagy None, ha nincs (sosem volt jelzes, vagy a jelzest mar lezartak).
       A LEGUTOLSO jelzes/lezaras-par dont: egy korabbi jelzes utani lezaras nyitva hagyja
       a helyet egy UJABB jelzesnek, egy jelzes utani lezaras pedig zar, meg ha korabban is
       allt mar egy (mas) lezart jelzes ugyanazon a kartyan."""
    conn = sqlite3.connect(db_path)
    try:
        rows = conn.execute(
            "SELECT author, created_at, content FROM kanban_comments "
            "WHERE card_id=? ORDER BY created_at ASC, id ASC",
            (card_id,),
        ).fetchall()
    finally:
        conn.close()
    open_risk = None
    for author, created_at, content in rows:
        stripped = content.lstrip()
        first_line = stripped.splitlines()[0] if stripped else ""
        if RISK_OPEN_RE.match(first_line):
            open_risk = (author, created_at, content[:200])
        elif RISK_CLOSE_RE.match(first_line):
            open_risk = None
    return open_risk


def main(argv):
    want_branch = argv[1]
    db_path = argv[2] or DEFAULT_DB_PATH
    repos = argv[3:]

    out, bad = [], False
    say = out.append

    if not os.path.isfile(db_path):
        say("  KOCKAZAT-ELLENORZES: NEM MERHETo -- a kanban DB nem talalhato: %s" % db_path)
        return 2, out

    referenced_cards = {}  # card_id -> [(repo_name, short_sha), ...]
    unreferenced = []      # (repo_name, short_sha, subject)

    for r in repos:
        name = os.path.basename(os.path.normpath(r))
        if not os.path.isdir(r) or git(r, "rev-parse", "--is-inside-work-tree").returncode != 0:
            say("  KOCKAZAT-ELLENORZES: NEM MERHETo -- %s nem git munkafa." % name)
            bad = True
            continue
        if git(r, "rev-parse", "--verify", "--quiet", "refs/heads/%s" % want_branch).returncode != 0:
            say("  KOCKAZAT-ELLENORZES: NEM MERHETo -- %s: nincs `%s` nevu HELYI ag." % (name, want_branch))
            bad = True
            continue
        commits = commits_since(r, want_branch, REFERENCE_EPOCH)
        if commits is None:
            say("  KOCKAZAT-ELLENORZES: NEM MERHETo -- %s: `git log` sikertelen." % name)
            bad = True
            continue
        for sha, _ct, msg in commits:
            cid = card_for_commit(msg)
            if cid:
                referenced_cards.setdefault(cid, []).append((name, sha[:8]))
            else:
                subject = msg.splitlines()[0] if msg.strip() else "(ures uzenet)"
                unreferenced.append((name, sha[:8], subject))

    open_flags = []
    for cid, sites in referenced_cards.items():
        risk = open_risk_for_card(db_path, cid)
        if risk:
            author, at, excerpt = risk
            open_flags.append((cid, sites, author, at, excerpt))

    if unreferenced:
        say("  KOCKAZAT-ELLENORZES: %d commit a referenciapont ota kartya-hivatkozas NELKUL"
            " (nem blokkol, csak jelzes):" % len(unreferenced))
        for name, sha, subject in unreferenced[:10]:
            say("       %s %s %s" % (name, sha, subject[:70]))
        if len(unreferenced) > 10:
            say("       ... es meg %d" % (len(unreferenced) - 10))

    if open_flags:
        bad = True
        say("  \U0001f6d1 MEGVALASZOLATLAN KOCKAZAT-JELZES a telepitendo build kartyain:")
        for cid, sites, author, at, excerpt in open_flags:
            where = ", ".join("%s@%s" % (n, s) for n, s in sites)
            oneline = excerpt.replace("\n", " ")[:120]
            say("     kartya %s (%s): %s irta, lezaratlan -- \"%s\"" % (cid, where, author, oneline))
        say("  Teendo: zard le a jelzest UGYANAZON a kartyan egy 'KOCKAZAT-LEZARVA:'-val kezdodo")
        say("  kommenttel, vagy vond vissza/oldd fel a jelzett kockazatot, majd probald ujra.")
    elif referenced_cards:
        say("  KOCKAZAT-ELLENORZES: nincs megvalaszolatlan kockazat-jelzes a telepitendo build"
            " kartyain (%d kartya ellenorizve)." % len(referenced_cards))
    else:
        say("  KOCKAZAT-ELLENORZES: a referenciapont ota nincs kartyara hivatkozo commit -- nincs mit ellenorizni.")

    return (1 if bad else 0), out


if __name__ == "__main__":
    rc, lines = main(sys.argv)
    print("\n".join(lines))
    sys.exit(rc)
