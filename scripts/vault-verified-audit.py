#!/usr/bin/env python3
"""Vault-jegyzetek `verified:` mezejenek merese -- hianyzo vagy 6 honapnal
regebbi ellenorzes szama nem emlekezeten mulik, hanem gepi merestol.

A Vault ket frontmatter-semat kever ugyanabban a konyvtarfaban:

  native  Obsidian-natjv jegyzet (`type:`, `tags:`, `created:`, `verified:`)
          -- erre vonatkozik a globalis CLAUDE.md "Frontmatter (KOTELEZO
          minden uj jegyzeten)" szabalya, benne a `verified:` mezovel.
  memory  Claude Code natjv auto-memory node (`metadata.node_type: memory`,
          sajat `metadata.modified` ISO-idobelyeggel). Ezt a natjv rendszer
          irja, `verified:` mezot soha nem kap -- a `metadata.modified` az
          egyetlen datum-jel, ami ra ertelmezheto.
  other   se `type:`, se `metadata.node_type` -- eszkoz-fajl (pl. Obsidian
          Kanban board), nem tudas-jegyzet, kimarad a szamlalasbol.

A ket kategoriat osszemosni HAMIS riasztast adna: minden auto-memory node
"hianyzo verified"-kent jelenne meg, elfojtva a valodi (native) talalatokat.

Hasznalat: python3 scripts/vault-verified-audit.py [vault_gyoker]

A kimenet jelentes, nem kapu -- a kilepesi kod mindig 0. Egy hianyzo vagy
olvashatatlan gyoker viszont HANGOSAN dob: egy nema ures jelentes "minden
rendben"-kent olvasna, ez az egyetlen hiba, amit ez az eszkoz nem engedhet meg.
"""
import calendar
import os
import sys
from datetime import date, datetime
from pathlib import Path

import yaml

STALE_MONTHS = 6


def parse_frontmatter(content):
    """A fajl elejen allo `---\\n...\\n---` YAML-blokk kinyerese dict-kent.

    None, ha nincs frontmatter. A `verified:` erteket YAML mar `date`
    objektumma parse-olja (YYYY-MM-DD alak), tovabbi konverzio nem kell.
    """
    if not content.startswith("---\n"):
        return None

    end = content.find("\n---\n", 4)
    if end == -1:
        return None

    raw = content[4:end]
    try:
        data = yaml.safe_load(raw)
    except yaml.YAMLError:
        return None

    return data if isinstance(data, dict) else None


def classify(frontmatter):
    """'memory' | 'native' | 'other' -- lasd a modul-docstringet."""
    metadata = frontmatter.get("metadata")
    if isinstance(metadata, dict) and metadata.get("node_type") == "memory":
        return "memory"
    if frontmatter.get("type"):
        return "native"
    return "other"


def _months_before(d, months):
    """`d`-nel `months` naptari honappal korabbi datum.

    Honapvegi hataresetben (pl. augusztus 31 mines 6 honap = februar 31,
    ami nem letezik) a cel honap UTOLSO napjara esik vissza, nem dob.
    """
    total_month = d.year * 12 + (d.month - 1) - months
    year, month = divmod(total_month, 12)
    month += 1
    day = min(d.day, calendar.monthrange(year, month)[1])
    return date(year, month, day)


def is_stale(when, today, months=STALE_MONTHS):
    """True, ha `when` (date) tobb mint `months` naptari honapja van `today`-hoz kepest."""
    cutoff = _months_before(today, months)
    return when < cutoff


def _as_date(value):
    """YAML `date` objektum vagy ISO idobelyeg-string -> `date`. Ervenytelenre None."""
    if isinstance(value, date) and not isinstance(value, datetime):
        return value
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, str):
        text = value.strip().rstrip("Z")
        for candidate in (text, text[:10]):
            try:
                return date.fromisoformat(candidate)
            except ValueError:
                continue
    return None


def _iter_markdown_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != ".obsidian"]
        for fname in sorted(filenames):
            if fname.endswith(".md"):
                yield Path(dirpath) / fname


def audit(root, today):
    """A Vault bejarasa, kategorizalt szamlalas es talalati listak.

    `root` hianya/olvashatatlansaga hangosan dob (FileNotFoundError /
    NotADirectoryError) -- lasd a modul-docstring indoklasat.
    """
    root = Path(root)
    if not root.is_dir():
        raise FileNotFoundError(f"Vault gyoker nem talalhato: {root}")

    result = {
        "native": {"total": 0, "missing_verified": [], "stale_verified": []},
        "memory": {"total": 0, "stale_modified": []},
        "other": {"total": 0},
        "no_frontmatter": {"total": 0},
    }

    for path in _iter_markdown_files(root):
        content = path.read_text(encoding="utf-8", errors="replace")
        frontmatter = parse_frontmatter(content)

        if frontmatter is None:
            result["no_frontmatter"]["total"] += 1
            continue

        kind = classify(frontmatter)

        if kind == "other":
            result["other"]["total"] += 1
            continue

        if kind == "native":
            result["native"]["total"] += 1
            verified = _as_date(frontmatter.get("verified"))
            if verified is None:
                result["native"]["missing_verified"].append(path)
            elif is_stale(verified, today):
                result["native"]["stale_verified"].append(path)
            continue

        # kind == "memory"
        result["memory"]["total"] += 1
        modified = _as_date(frontmatter.get("metadata", {}).get("modified"))
        if modified is not None and is_stale(modified, today):
            result["memory"]["stale_modified"].append(path)

    return result


def format_report(result, root, today):
    lines = []
    n = result["native"]
    lines.append(f"Obsidian-natjv jegyzetek (type: mezovel): {n['total']}")
    lines.append(f"  verified: HIANYZIK: {len(n['missing_verified'])}")
    for p in n["missing_verified"]:
        lines.append(f"    {p.relative_to(root)}")
    lines.append(f"  verified: {STALE_MONTHS} honapnal REGEBBI: {len(n['stale_verified'])}")
    for p in n["stale_verified"]:
        lines.append(f"    {p.relative_to(root)}")

    m = result["memory"]
    lines.append(f"\nAuto-memory node-ok (metadata.node_type: memory): {m['total']}")
    lines.append(f"  metadata.modified {STALE_MONTHS} honapnal REGEBBI: {len(m['stale_modified'])}")
    for p in m["stale_modified"]:
        lines.append(f"    {p.relative_to(root)}")

    lines.append(f"\nEgyeb (se type, se node_type -- eszkoz-fajl): {result['other']['total']}")
    lines.append(f"Frontmatter nelkuli fajl: {result['no_frontmatter']['total']}")

    return "\n".join(lines)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Work/Claude/Vault")
    today = date.today()
    result = audit(root, today)
    print(format_report(result, Path(root), today))


if __name__ == "__main__":
    main()
