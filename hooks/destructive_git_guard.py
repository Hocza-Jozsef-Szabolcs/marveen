#!/usr/bin/env python3
"""
hu: A destructive-git-guard PreToolUse hook dontesi logikaja. A wrapper
    (destructive-git-guard.sh) a stdin-en kapott JSON-t adja at ide.
    Kimenet: exit 0 = atenged, exit 2 = blokk (az indoklas a stderr-en).

    KET DOLGOT MER, es MINDKETTo azt jelenti, amit allit:
      1. VESZELYES-E a parancs. A felismeres TOKENIZALT: a `git` es az ige
         koze ekelodo globalis kapcsolok (-C <ut>, -c k=v, --git-dir=,
         --work-tree=, ...) nem takarjak el az iget. A `-C` erteke egyben
         a CEL REPO -- a merest ott vegezzuk, nem a CWD-ben.
      2. VAN-E VALODI VEDoHALO. Nem az, hogy letezik-e BARMILYEN stash,
         hanem hogy az ELDOBANDO TARTALOM bent van-e valamelyik stash-ben,
         BLOB-HASH szerint. Egy regi, mas fajlrol keszult stash nem old fel.

    Ha a parancs nem dob el semmit (tiszta fa, nincs untracked), atengedjuk --
    a kapu csak ott alljon utba, ahol van mit elveszteni.

en: Decision logic for the destructive-git-guard PreToolUse hook.
    Exit 0 = allow, exit 2 = block (reason on stderr).
    Detection is tokenized (git global options no longer hide the verb, and
    `-C <path>` selects the repo that gets measured), and the safety net is
    verified by blob hash: the content about to be discarded must actually be
    present in some stash, not merely "a stash exists".
"""

import json
import os
import re
import shlex
import subprocess
import sys

# hu: Globalis git-kapcsolok, amelyek KULON tokenben hordozzak az ertekuket.
GLOBAL_OPTS_WITH_VALUE = {
    "-C", "-c", "--exec-path", "--git-dir", "--work-tree",
    "--namespace", "--config-env", "--super-prefix",
}

# hu: Shell-elvalasztok -- itt ver veget egy git-hivas argumentum-listaja.
SHELL_SEPARATORS = {"&&", "||", ";", "|", "&", "\n", ">", ">>", "<"}

MAX_STASHES = 20
MAX_LISTED_FILES = 12


def git(repo, *args, timeout=15):
    """hu: git-hivas a megadott repoban. Hiba eseten None."""
    try:
        proc = subprocess.run(
            ["git", "-C", repo] + list(args),
            capture_output=True, text=True, timeout=timeout,
        )
    except Exception:
        return None

    if proc.returncode != 0:
        return None

    return proc.stdout


def resolve(base, path):
    """hu: Relativ utat a base-hez kepest old fel."""
    if os.path.isabs(path):
        return os.path.normpath(path)

    return os.path.normpath(os.path.join(base, path))


def parse_git_invocations(command, base_cwd):
    """
    hu: Vegigmegy a parancs tokenjein, es minden git-hivasra visszaadja a
        (subcommand, argumentumok, cel_konyvtar) harmast. A `cd <dir>` elotag
        lepteti a cel_konyvtar alapjat, a `-C <ut>` felulirja.
    """
    try:
        tokens = shlex.split(command, comments=False)
    except ValueError:
        tokens = command.split()

    cwd = base_cwd
    invocations = []
    i = 0

    while i < len(tokens):
        token = tokens[i]

        if token == "cd" and i + 1 < len(tokens):
            cwd = resolve(cwd, tokens[i + 1])
            i += 2
            continue

        if token == "git" or token.endswith("/git"):
            j = i + 1
            target = cwd

            while j < len(tokens):
                opt = tokens[j]

                if opt in GLOBAL_OPTS_WITH_VALUE:
                    if opt == "-C" and j + 1 < len(tokens):
                        target = resolve(target, tokens[j + 1])
                    elif opt in ("--git-dir", "--work-tree") and j + 1 < len(tokens):
                        target = resolve(target, tokens[j + 1])
                    j += 2
                    continue

                if opt.startswith("--") and "=" in opt:
                    name, _, value = opt.partition("=")
                    if name in ("--git-dir", "--work-tree"):
                        target = resolve(target, value)
                    j += 1
                    continue

                if opt.startswith("-"):
                    j += 1
                    continue

                break

            if j < len(tokens):
                args = []
                for k in range(j + 1, len(tokens)):
                    if tokens[k] in SHELL_SEPARATORS:
                        break
                    args.append(tokens[k])

                # hu: a --git-dir a .git mappara mutat; a repo-gyoker a szuloje
                if os.path.basename(target) == ".git":
                    target = os.path.dirname(target) or "/"

                invocations.append((tokens[j], args, target))
                i = j + 1
                continue

        i += 1

    return invocations


def _has_path_argument(args, work_dir):
    """
    hu: Van-e a `checkout` argumentumai kozott PATH? A `.` mindig path; egyebkent
        az dont, hogy a nev letezik-e a munkakonyvtarban. Egy puszta ag-valtas
        (`git checkout main`, `git checkout -b uj`) igy nem minosul veszelyesnek.
    """
    after_sep = False

    for arg in args:
        if arg == "--":
            after_sep = True
            continue

        if arg.startswith("-"):
            continue

        if arg in (".", "./") or after_sep:
            return True

        if work_dir and os.path.exists(os.path.join(work_dir, arg)):
            return True

    return False


def classify(subcommand, args, work_dir=None):
    """hu: Veszelyes-e ez a git-hivas? Visszateres: indok szoveg vagy None."""
    if subcommand == "restore":
        if "--staged" in args and "--worktree" not in args:
            return None

        return "git restore (working tree tartalom visszaallitasa/eldobasa)"

    if subcommand == "checkout":
        # hu: A `--` a vilagos alak, de SENKI nem gepeli. A `git checkout .` es a
        #     `git checkout <fajl>` ugyanugy eldobja a working tree modositasait --
        #     a path-argumentum jelenlete dont, nem az elvalaszto.
        #     (Az ordog merte: a `--` nelkuli alakok mind atmentek.)
        if "--" in args or _has_path_argument(args, work_dir):
            return "git checkout <path> (working tree tartalom eldobasa)"

        return None

    if subcommand == "clean":
        for arg in args:
            if arg == "--force":
                return "git clean -f (untracked fajlok vegleges torlese)"

            if arg.startswith("-") and not arg.startswith("--") and "f" in arg:
                return "git clean -f (untracked fajlok vegleges torlese)"

        return None

    if subcommand == "reset":
        if "--hard" in args:
            return "git reset --hard (working tree + staged tartalom eldobasa)"

        return None

    return None


# hu: Ujraeloallithato build-kimenet konyvtarai. Az ezek ALATT allo ignoralt tartalom
#     nem szamit elveszithetonek -- minden mas ignoralt fajl IGEN (`.env`, `*.local`,
#     kulcsok, helyi konfig). A LISTA A HEURISZTIKA HATARA, ezert ki van irva:
#     ami nincs rajta, az VESZELYEZTETETT (fail-closed irany).
#     ISMERT LYUK, kimondva: egy `obj/titkos.env` atcsuszik -- build-konyvtarban nem
#     tartunk titkot, es ezt vallaljuk. Egy `config/.env` viszont NEM csuszik at.
BUILD_DIRS = {
    "obj", "bin", "target", "dist", "build", "out", "node_modules",
    "__pycache__", ".venv", "venv", ".gradle", ".next", ".nuxt", ".parcel-cache",
    ".pytest_cache", ".mypy_cache", ".tox", "coverage", ".terraform",
}
# hu: `packages` KIVEVE (ordog merte, 2026-08-14, bukas-eloallitassal): az NEM kimeneti,
#     hanem FORRAS-konvencio -- pnpm/yarn/lerna workspace-ben a `packages/<nev>/` maga a
#     forras-gyoker, tehat egy `packages/my-lib/secrets.json` NEMAN atcsuszott.
#     ARA, KIMONDVA: egy regi .NET-repoban, ahol a `packages/` NuGet-cache, a `clean -fdx`
#     ezutan BLOKKOL -- ugyanaz az osztaly, mint az `.idea/`, es a BIZTONSAGOS iranyba.
# hu: `build` MARAD, tudatosan: nemely projektben build-SZKRIPTEK konyvtara, de CMake-ben
#     es a tobbsegben kimenet -- az ordog merese szerint ez a ritkabb eset.


def _is_build_artifact(path):
    """hu: A megadott repo-relativ ut valamelyik BUILD_DIRS konyvtar ALATT van-e?"""
    parts = [p for p in path.replace("\\", "/").split("/") if p and p != "."]

    # hu: a gyoker-szintu FAJL sosem build-artefaktum (`.env`, `config.local`)
    if len(parts) < 2:
        return False

    return any(p in BUILD_DIRS for p in parts[:-1])


def expand_dirs(root, paths):
    """hu: A `git clean -nd` konyvtarat is adhat -- bontsuk fajlokra."""
    expanded = set()

    for path in paths:
        full = os.path.join(root, path)

        if os.path.isdir(full):
            for dirpath, _, filenames in os.walk(full):
                for name in filenames:
                    rel = os.path.relpath(os.path.join(dirpath, name), root)
                    expanded.add(rel)
        else:
            expanded.add(path.rstrip("/"))

    return expanded


def endangered_paths(root, subcommand, args):
    """
    hu: Mit dobna el ez a parancs? Repo-relativ utak halmaza.
        Bizonytalansag eseten a TAGABB halmazt adjuk (fail-closed).
    """
    if subcommand == "reset":
        out = git(root, "diff", "--name-only", "HEAD")
        if out is None:
            return None

        return {line for line in out.splitlines() if line}

    if subcommand in ("restore", "checkout"):
        out = git(root, "diff", "--name-only", "HEAD")
        if out is None:
            return None

        modified = {line for line in out.splitlines() if line}

        if subcommand == "checkout" and "--" in args:
            explicit = args[args.index("--") + 1:]
        else:
            explicit = [a for a in args if not a.startswith("-")]

        explicit = [e for e in explicit if e not in (".", "./")]

        if not explicit:
            return modified

        selected = set()

        for path in modified:
            for entry in explicit:
                normalized = entry.rstrip("/")
                if path == normalized or path.startswith(normalized + "/"):
                    selected.add(path)

        return selected

    if subcommand == "clean":
        def clean_list(flags):
            out = git(root, "clean", flags)
            if out is None:
                return None

            raw = set()

            for line in out.splitlines():
                for prefix in ("Would remove ", "Would skip repository "):
                    if line.startswith(prefix):
                        raw.add(line[len(prefix):].strip())
                        break

            return expand_dirs(root, raw)

        wants_ignored = any(
            arg.startswith("-") and not arg.startswith("--") and "x" in arg
            for arg in args
        )

        if not wants_ignored:
            return clean_list("-nd")

        # hu: A `-x` az IGNORALT utakat is behozza. Ezek TULNYOMORESZT build-kimenet
        #     (obj/, bin/, node_modules/), amit senki nem stash-el -- ha mindet
        #     veszelyeztetettnek szamitanank, a rutin `git clean -fdx` SOHA nem oldodna
        #     fel, es a kaput megkerulnek. DE NEM MINDEN IGNORALT FAJL POTOLHATO:
        #     egy `obj/*.o` UJRAFORDITHATO, egy `.env` NEM -- es ez a kulonbseg gitben
        #     nem kifejezheto.
        #     🛑 AZ ELSo JAVITASOM ATBILLENT: egy bosszanto HAMIS POZITIVBOL (a takaritas
        #     blokkolt) NEMA, VISSZAFORDIThATATLAN VESZTES lett (egy `.env` titkos
        #     kulccsal csendben torolheto). Az ordog merte ki, a SAJAT korabbi erve
        #     ellenere, 2026-08-14.
        #     A KOMPROMISSZUM: a BUILD-KONYVTARAK alatti ignoralt utak mentesek, minden
        #     mas ignoralt tartalom VESZELYEZTETETT. Ez HEURISZTIKA, es kimondjuk, hogy
        #     az -- a hatara a lista alatt all.
        plain = clean_list("-nd")
        with_ignored = clean_list("-ndx")

        if plain is None or with_ignored is None:
            return None

        endangered = set(plain)

        for path in with_ignored - set(plain):
            if not _is_build_artifact(path):
                endangered.add(path)

        return endangered

    return set()


def stash_coverage(root):
    """
    hu: path -> {blob-hash} terkep MINDEN stash-bol (a tracked fa es az
        untracked commit, ami a stash HARMADIK szuloje). Ez adja meg, hogy
        egy KONKRET tartalom bent van-e a vedohaloban.
    """
    out = git(root, "stash", "list", "--format=%gd")
    if not out:
        return {}, []

    refs = [line.strip() for line in out.splitlines() if line.strip()][:MAX_STASHES]
    coverage = {}

    for ref in refs:
        for tree_ref in (ref, ref + "^3"):
            listing = git(root, "ls-tree", "-r", tree_ref)
            if not listing:
                continue

            for line in listing.splitlines():
                meta, _, path = line.partition("\t")
                fields = meta.split()

                if len(fields) >= 3 and path:
                    coverage.setdefault(path, set()).add(fields[2])

    return coverage, refs


SYMLINK_SENTINEL = "<symlink>"


def worktree_hash(root, path):
    """
    hu: A fajl JELENLEGI tartalmanak blob-hash-e.
        None  = nincs elveszitheto tartalom (nem letezik)
        SYMLINK_SENTINEL = symlink: a celpontja informacio, es a `git clean` TORLI --
          de a `hash-object` nem hasonlithato ossze a stash-fabeli blobbal, ezert
          FEDETLENNEK szamit (fail-closed). Az ordog merte: korabban lathatatlan volt.
    """
    full = os.path.join(root, path)

    if os.path.islink(full):
        return SYMLINK_SENTINEL

    if not os.path.isfile(full):
        return None

    out = git(root, "hash-object", path)

    if not out:
        return None

    return out.strip()


def uncovered_files(root, endangered, coverage):
    """hu: Azok a veszelyeztetett fajlok, amelyek TARTALMA nincs stash-ben."""
    uncovered = []

    for path in sorted(endangered):
        current = worktree_hash(root, path)

        # hu: nem letezo / nem-regularis fajl: nincs elveszitheto tartalom
        if current is None:
            continue

        if current not in coverage.get(path, set()):
            uncovered.append(path)

    return uncovered


def block(reason, root, command, uncovered, stash_count, ignored_hit=False):
    """hu: Blokkolo uzenet a stderr-re, majd exit 2."""
    if stash_count == 0:
        net = "ebben a repoban NINCS egyetlen git stash sem"
    else:
        net = ("van %d stash, de EGYIK SEM tartalmazza az alabbi fajlok "
               "JELENLEGI tartalmat" % stash_count)

    # hu: 🛑 A `-u` NEM MENTI AZ IGNORALT FAJLOKAT -- CSAK az `-a`. Merve (ordog,
    #     2026-08-14): `stash push -u` mellett a `.env` sem a tracked, sem az untracked
    #     (`^3`) agban nem jelent meg; `stash push -a` mellett igen. A kapu korabbi
    #     uzenete tehat HAMIS KIUTAT adott: aki koveti, azt hiszi, mentett, es a
    #     `.env` ugyanugy elveszik.
    stash_flag = "-a" if ignored_hit else "-u"
    stash_note = ""

    if ignored_hit:
        stash_note = (
            "\n   FIGYELEM: a fenti listan GITIGNORE-OLT fajl is van. A `-u` azokat NEM\n"
            "   menti (merve) -- ezert all itt `-a`. Ha csak build-kimenetet dobnal el,\n"
            "   a kapu nem allt volna utba: ami itt szerepel, az NEM ujraeloallithato.\n"
        )

    listed = uncovered[:MAX_LISTED_FILES]
    more = len(uncovered) - len(listed)
    files = "\n".join("  - " + p for p in listed)

    if more > 0:
        files += "\n  - ... es meg %d fajl" % more

    sys.stderr.write("""[hook: destructive-git-guard] BLOCK

Visszafordithatatlan parancs: %s
Repo: %s
Parancs: %s

A 'never-destructively-discard-uncommitted-changes' szabaly ezt tiltja
biztonsagi halo nelkul: %s.
Ezek a fajlok most VEGLEGESEN, VISSZAALLITHATATLANUL elvesznenek:

%s

Mielott folytatnad:
1. Nezd meg, MI valtozott: git -C "%s" status --short
2. Mentsd el ELOSZOR (nem torli, csak felreteszi):
   git -C "%s" stash push %s -m "<leiro uzenet>"
%s3. Csak EZUTAN fut le ez a parancs -- a hook a MENTETT TARTALMAT ismeri fel,
   nem azt, hogy letezik-e barmilyen stash.
4. Ha a tartalom nem a sajatod -- KERDEZD MEG a usert, mielott tovabbmesz,
   meg akkor is, ha stash-elted.
""" % (reason, root, command, net, files, root, root, stash_flag, stash_note))

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

    base_cwd = payload.get("cwd") or os.getcwd()

    try:
        invocations = parse_git_invocations(command, base_cwd)
    except Exception:
        # hu: A FELISMERES bukott. Korabban itt `exit 0` allt ("nem ad informaciot") --
        #     de az ordog joggal vetette fel: a meg nem tortent destruktiv parancs
        #     eszreveheto, a vegrehajtott NEM. Ezert FAIL-CLOSED: ha a parancs szovege
        #     barmelyik veszelyes iget tartalmazza, BLOKKOLUNK.
        if re.search(r"\b(restore|checkout|clean|reset)\b", command):
            sys.stderr.write(
                "[hook: destructive-git-guard] BLOCK\n\n"
                "A parancs ertelmezese nem sikerult, es veszelyes iget tartalmaz\n"
                "(restore / checkout / clean / reset). Fail-closed: nem engedem at.\n"
                "Parancs: %s\n\nBontsd egyszerubb alakra, vagy stash-eld elobb a tartalmat.\n"
                % command
            )
            sys.exit(2)

        sys.exit(0)

    # hu: Ha UGYANEBBEN a parancsban, a veszelyes hivas ELoTT all egy `git stash push`
    #     ugyanarra a repora, a vedohalo a parancs lefutasa kozben keszul el -- ez EPP
    #     a szabaly altal eloirt alak ("elobb stash, aztan a parancs").
    #     🛑 DE CSAK A TELJES MENTES HALO. Az ordog merte (2026-08-14):
    #        `git stash push -- tracked.txt && git clean -fd`  ->  atengedett,
    #     mert a PUSZTA JELENLET vedettnek jelolte a repot -- holott a pathspec miatt
    #     az untracked fajl NEM kerult a stash-be. Ezert: pathspec vagy `-u` hianya
    #     eseten a hivas NEM szamit halonak, es a fedettseg-meres normalisan lefut.
    stashed_targets = set()

    for subcommand, args, target in invocations:
        if subcommand == "stash":
            rest = args[1:] if (args and args[0] in ("push", "save")) else args

            # hu: a `-m <uzenet>` ERTEKE nem pathspec -- kihagyjuk, kulonben a
            #     szabalyos `stash push -u -m mentes` pathspec-esnek latszik
            positional, skip = [], False

            for a in rest:
                if skip:
                    skip = False
                    continue

                if a in ("-m", "--message", "--pathspec-from-file"):
                    skip = True
                    continue

                if not a.startswith("-"):
                    positional.append(a)

            has_pathspec = bool(positional) or "--" in rest
            includes_untracked = any(
                a in ("-u", "--include-untracked", "-a", "--all")
                or (a.startswith("-") and not a.startswith("--") and ("u" in a or "a" in a))
                for a in rest
            )

            if (not args or args[0] in ("push", "save")) and not has_pathspec and includes_untracked:
                stashed_targets.add(os.path.realpath(target))

        reason = classify(subcommand, args, target if os.path.isdir(target) else None)

        if reason is None:
            continue

        if os.path.realpath(target) in stashed_targets:
            continue

        # hu: innentol TUDJUK, hogy a parancs veszelyes -- a meres bukasa
        #     mostantol BLOKK, nem atengedes (fail-closed).
        search_dir = target if os.path.isdir(target) else base_cwd
        root = git(search_dir, "rev-parse", "--show-toplevel")

        if not root:
            # hu: nem git repo -- nincs mit merni, es a parancs sem tud
            #     git-tartalmat eldobni
            continue

        root = root.strip()

        endangered = endangered_paths(root, subcommand, args)

        if endangered is None:
            block(reason + " [a meres nem sikerult -- fail-closed]",
                  root, command, ["<a meres nem futott le>"], -1)

        if not endangered:
            continue

        coverage, refs = stash_coverage(root)
        uncovered = uncovered_files(root, endangered, coverage)

        if uncovered:
            # hu: van-e a fedetlenek kozott GITIGNORE-olt fajl? Ha igen, a blokk-uzenet
            #     `-a`-t javasol, mert a `-u` azokat merten NEM menti.
            ignored_hit = False
            chk = git(root, "check-ignore", "--", *uncovered[:MAX_LISTED_FILES])
            if chk:
                ignored_hit = bool(chk.strip())

            block(reason, root, command, uncovered, len(refs), ignored_hit)

    sys.exit(0)


if __name__ == "__main__":
    main()
