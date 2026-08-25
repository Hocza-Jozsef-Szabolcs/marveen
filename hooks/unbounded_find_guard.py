#!/usr/bin/env python3
"""
hu: A unbounded-find-guard PreToolUse hook döntési logikája. A wrapper
    (unbounded-find-guard.sh) a stdin-en kapott JSON-t adja át ide.
    Kimenet: exit 0 = átenged, exit 2 = blokk (az indoklás a stderr-en).

    Eredet: 2026-08-17 éjszaka HÁROM független runaway esemény -- `find /`
    (ordog, fleet.py), `bfs /` kétszer (akka: fleet.py, majd SQLite-net.dll)
    -- mindegyik 10+ perc CPU-t evett, iCloud-szinkronizált mappák alatt
    (~/Downloads, ~/Documents, ~/Desktop) órákig futhatott volna (bizonyított
    korábbi eset: 13 óra 39 perc, 2026-08-05).

    A felismerés TOKENIZÁLT (shlex): egy `find`/`bfs` hívás a parancs elején
    vagy egy shell-elválasztó (&&, ||, ;, |, ...) UTÁN kezdődik, és a
    KÖVETKEZŐ elválasztóig tartó tokenek az argumentumai.

    A kockázatos kiinduló út KIZÁRÓLAG a szó szerinti gyökér ("/") vagy a
    felhasználó home-ja ("~", "$HOME", "${HOME}", vagy a tényleges home
    abszolút útja BÁRAN) -- egy home ALATTI vagy repó-alatti út (pl.
    ~/Marveen/agents/backend) NEM esik ide, mert az már bekorlátozott
    hatókör, ugyanúgy, mint egy sima `find <repo>/...`.

    Az egyetlen elfogadott korlátozó jelző a `-maxdepth <szám>` -- ezt
    nevezi meg a kártya "MIT KELL TENNI" és "ELFOGADASI FELTETEL" szakasza
    is egyértelműen. Egy fuzzy "korlátozó path-minta" heurisztika könnyen
    kijátszható lenne (bármilyen `-name`/`-path` kapcsoló "mintának"
    nézhető), ezért nem került be.
en: Decision logic for the unbounded-find-guard PreToolUse hook. Blocks
    `find`/`bfs` invocations that start at the filesystem root ("/") or the
    user's home ("~", "$HOME") with no `-maxdepth` bound. Detection is
    tokenized (shlex); the only accepted bound is `-maxdepth <n>`, per the
    card's own acceptance criterion.
"""

import json
import os
import re
import shlex
import sys

SHELL_SEPARATORS = {"&&", "||", ";", "|", "&", "\n", ">", ">>", "<"}
RISKY_COMMANDS = {"find", "bfs"}


def home_variants():
    """hu: minden szoveges alak, ami a felhasznalo home-jat jelenti."""
    home = os.path.expanduser("~")
    variants = {"~", "~/", "$HOME", "${HOME}", home}

    if not home.endswith("/"):
        variants.add(home + "/")

    return variants


def is_risky_root(path):
    """hu: szo szerint gyoker (egy vagy tobb "/") vagy a home barjan."""
    if re.fullmatch(r"/+", path):
        return True

    return path in home_variants()


def find_invocations(tokens):
    """hu: (parancs, argumentumok) parok -- egy find/bfs hivas es a hozza
    tartozo, a kovetkezo shell-elvalasztoig tarto tokenjei."""
    invocations = []
    i = 0
    n = len(tokens)

    while i < n:
        tok = tokens[i]
        is_start = (i == 0) or (tokens[i - 1] in SHELL_SEPARATORS)

        if is_start and tok in RISKY_COMMANDS:
            args = []
            j = i + 1

            while j < n and tokens[j] not in SHELL_SEPARATORS:
                args.append(tokens[j])
                j += 1

            invocations.append((tok, args))
            i = j
            continue

        i += 1

    return invocations


def leading_paths(args):
    """hu: a hivas ELSO, "-"-tal nem kezdodo tokenjei -- ezek az utak,
    mielott az elso kapcsolo/kifejezes kezdodik."""
    paths = []

    for a in args:
        if a.startswith("-"):
            break
        paths.append(a)

    return paths


def has_maxdepth(args):
    return any(a == "-maxdepth" or a.startswith("-maxdepth=") for a in args)


def block(command, tool, path):
    sys.stderr.write(
        "[hook: unbounded-find-guard] BLOCK\n\n"
        "A '%s' hivas a gyokerbol/home-bol indul ('%s'), -maxdepth nelkul --\n"
        "orakig futhat iCloud-szinkronizalt mappak alatt (bizonyitott korabbi\n"
        "eset: 13 ora 39 perc CPU).\n"
        "Parancs: %s\n\n"
        "Hatarold a kereshez a konkret repo/mappa utjat, vagy adj hozza\n"
        "'-maxdepth <szam>'-ot.\n" % (tool, path, command)
    )
    sys.exit(2)


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    if payload.get("tool_name") != "Bash":
        sys.exit(0)

    command = (payload.get("tool_input") or {}).get("command") or ""

    if not command.strip():
        sys.exit(0)

    try:
        tokens = shlex.split(command, posix=True)
    except ValueError:
        # hu: idezojel-hiba stb -- a parancs igy sem futna le ertelmesen a
        #     shellben. Fail-closed csak akkor, ha veszelyes szot tartalmaz.
        if re.search(r"\b(find|bfs)\b", command):
            sys.stderr.write(
                "[hook: unbounded-find-guard] BLOCK\n\n"
                "A parancs ertelmezese nem sikerult (idezojel-hiba), es\n"
                "'find'/'bfs' szot tartalmaz. Fail-closed: nem engedem at.\n"
                "Parancs: %s\n" % command
            )
            sys.exit(2)

        sys.exit(0)

    for tool, args in find_invocations(tokens):
        if has_maxdepth(args):
            continue

        for path in leading_paths(args):
            if is_risky_root(path):
                block(command, tool, path)

    sys.exit(0)


if __name__ == "__main__":
    main()
