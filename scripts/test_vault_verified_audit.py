"""Tests for scripts/vault-verified-audit.py.

hu: A Vault ket kulonbozo frontmatter-semat kever ugyanabban a konyvtarfaban:
    a Claude Code natjv auto-memory node-ok (`metadata.node_type: memory`, sajat
    `metadata.modified` ISO-idobelyeggel) es a kezzel irt Obsidian-natjv jegyzetek
    (`type:`, `verified:`). A ket sema kozott a `verified:` mezo NEM ertelmezheto
    azonosan -- egy auto-memory node-nal a mezo soha nincs jelen, mert a natjv
    rendszer nem irja. Ha a merő ezt nem kulonitene el, minden auto-memory node
    "hianyzo verified"-kent jelenne meg, ami ELFOJTANA a valodi (Obsidian-natjv)
    talalatokat egy zajos tomegben.
en: The Vault mixes two different frontmatter schemas in the same tree: Claude
    Code's native auto-memory nodes (`metadata.node_type: memory`, their own
    `metadata.modified` ISO timestamp) and hand-written Obsidian-native notes
    (`type:`, `verified:`). The `verified:` field is not meaningful the same
    way across both -- an auto-memory node never carries it, the native system
    doesn't write it. Without separating the two, every auto-memory node would
    show up as "missing verified", drowning the real (Obsidian-native) hits in
    noise.
"""

import importlib.util
from datetime import date
from pathlib import Path

import pytest

_spec = importlib.util.spec_from_file_location(
    "vault_verified_audit", Path(__file__).with_name("vault-verified-audit.py")
)
vva = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(vva)


def write(path: Path, frontmatter: str, body: str = "tartalom\n") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"---\n{frontmatter}\n---\n{body}", encoding="utf-8")


# ---------------------------------------------------------------------------
# parse_frontmatter -- YAML kinyerese a fajl elejerol
# ---------------------------------------------------------------------------

def test_parse_frontmatter_visszaadja_a_mezoket(tmp_path):
    p = tmp_path / "a.md"
    write(p, "type: reference\nverified: 2026-08-01")

    fm = vva.parse_frontmatter(p.read_text(encoding="utf-8"))

    assert fm == {"type": "reference", "verified": date(2026, 8, 1)}


def test_parse_frontmatter_frontmatter_nelkuli_fajlra_none(tmp_path):
    p = tmp_path / "a.md"
    p.write_text("# Cim\n\nnincs frontmatter\n", encoding="utf-8")

    assert vva.parse_frontmatter(p.read_text(encoding="utf-8")) is None


def test_parse_frontmatter_beagyazott_metadata_blokkot_is_kezel(tmp_path):
    p = tmp_path / "a.md"
    write(p, "name: x\nmetadata:\n  node_type: memory\n  modified: 2026-07-28T20:43:59.395Z")

    fm = vva.parse_frontmatter(p.read_text(encoding="utf-8"))

    assert fm["metadata"]["node_type"] == "memory"


# ---------------------------------------------------------------------------
# classify -- a harom kategoria szetvalasztasa
# ---------------------------------------------------------------------------

def test_classify_auto_memory_node():
    fm = {"name": "x", "metadata": {"node_type": "memory", "type": "feedback"}}

    assert vva.classify(fm) == "memory"


def test_classify_obsidian_native_jegyzet():
    fm = {"type": "reference", "verified": date(2026, 8, 1)}

    assert vva.classify(fm) == "native"


def test_classify_se_type_se_node_type_other():
    fm = {"kanban-plugin": "board"}

    assert vva.classify(fm) == "other"


# ---------------------------------------------------------------------------
# is_stale -- 6 honapos hatarnap, naptari honapokkal, nem 183 napos kozelitessel
# ---------------------------------------------------------------------------

def test_is_stale_pontosan_6_honapja_meg_nem_elavult():
    today = date(2026, 8, 24)
    verified = date(2026, 2, 24)  # pontosan 6 naptari honapja

    assert vva.is_stale(verified, today) is False


def test_is_stale_6_honap_es_egy_nap_mar_elavult():
    today = date(2026, 8, 24)
    verified = date(2026, 2, 23)

    assert vva.is_stale(verified, today) is True


def test_is_stale_friss_datum_nem_elavult():
    today = date(2026, 8, 24)
    verified = date(2026, 8, 20)

    assert vva.is_stale(verified, today) is False


def test_is_stale_honapvegi_hatareset_nem_dob(tmp_path):
    # 2026-08-31 mines 6 honap = 2026-02-31, ami nem letezik naptari nap ->
    # a helyes viselkedes a honap utolso napjara (2026-02-28) esik vissza,
    # nem dob kivetelt. A hatarnapon (2026-02-28) meg nem elavult...
    today = date(2026, 8, 31)

    assert vva.is_stale(date(2026, 2, 28), today) is False
    # ...egy nappal korabban mar igen.
    assert vva.is_stale(date(2026, 2, 27), today) is True


# ---------------------------------------------------------------------------
# audit -- vegponti mukodes egy szintetikus Vault-fan
# ---------------------------------------------------------------------------

def build_sample_vault(root: Path, today: date) -> None:
    # Obsidian-natjv, hianyzik a verified -> MISSING
    write(root / "Shared" / "missing.md", "type: feedback\ntags: [x]\ncreated: 2026-01-01")

    # Obsidian-natjv, elavult verified (7 honapja) -> STALE
    write(root / "Shared" / "stale.md", "type: reference\nverified: 2026-01-24")

    # Obsidian-natjv, friss verified -> sem MISSING, sem STALE
    write(root / "Shared" / "fresh.md", "type: pattern\nverified: 2026-08-20")

    # auto-memory node, regi modified -> MEMORY_STALE
    write(
        root / "Projects" / "X" / "old_memory.md",
        "name: old\nmetadata:\n  node_type: memory\n  modified: 2026-01-01T00:00:00.000Z",
    )

    # auto-memory node, friss modified -> nem stale
    write(
        root / "Projects" / "X" / "fresh_memory.md",
        "name: fresh\nmetadata:\n  node_type: memory\n  modified: 2026-08-20T00:00:00.000Z",
    )

    # se type se node_type -> OTHER, nem szamit bele egyik listaba sem
    write(root / "Untitled Kanban.md", "kanban-plugin: board")

    # frontmatter nelkuli fajl -> NO_FM
    (root / "README.md").write_text("# Sima fajl frontmatter nelkul\n", encoding="utf-8")


def test_audit_szamai_pontosan_stimmelnek(tmp_path):
    today = date(2026, 8, 24)
    build_sample_vault(tmp_path, today)

    result = vva.audit(tmp_path, today)

    assert result["native"]["total"] == 3
    assert [p.name for p in result["native"]["missing_verified"]] == ["missing.md"]
    assert [p.name for p in result["native"]["stale_verified"]] == ["stale.md"]
    assert result["memory"]["total"] == 2
    assert [p.name for p in result["memory"]["stale_modified"]] == ["old_memory.md"]
    assert result["other"]["total"] == 1
    assert result["no_frontmatter"]["total"] == 1


def test_audit_ures_vaultra_nulla_mindenhol(tmp_path):
    today = date(2026, 8, 24)

    result = vva.audit(tmp_path, today)

    assert result["native"]["total"] == 0
    assert result["native"]["missing_verified"] == []
    assert result["memory"]["total"] == 0


def test_audit_obsidian_konyvtarat_kihagyja(tmp_path):
    today = date(2026, 8, 24)
    write(tmp_path / ".obsidian" / "plugins" / "junk.md", "type: reference")

    result = vva.audit(tmp_path, today)

    assert result["native"]["total"] == 0


def test_audit_hianyzo_gyoker_hangosan_dob(tmp_path):
    missing = tmp_path / "nincs-ilyen"

    with pytest.raises(FileNotFoundError):
        vva.audit(missing, date(2026, 8, 24))
