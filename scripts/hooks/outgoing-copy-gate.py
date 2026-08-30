#!/usr/bin/env python3
"""PreToolUse gate on the MAIN agent's outbound email/Telegram copy: Hungarian
copy QA.

Ported from upstream (Szotasz/marveen) f96b763..70a2be7 -- persisted here
because the script was never committed locally (GATEPERSIST816 upstream,
tracked on card 6784a1fe). The generic checks and the send-detection logic
are kept as upstream wrote them (universal Hungarian-copy QA, not
install-specific); the only local adaptation is the recognized send-command
shape, extended for THIS install's mail sender (nas-mail-send.py, see
_SENDPY below) alongside the upstream-recognized support-mail/send.py and
graph-mail.ts.

Why this exists: outbound copy has gone out with accents stripped or an em
dash in it before -- both are standing rules in CLAUDE.md ("A KEZTETESEKET
SOHA NE HAGYD EL" / "Nincs gondolatjel (em dash). Soha.").

Note the seam this fills. `scripts/email-send-gate.mjs` already gates outbound
email, but it gates SUB-AGENTS (it is wired by writeAgentSettingsFromProfile()
guarded by `name !== MAIN_AGENT_ID`) and it is a hard deny, not a content check.
Nothing at all ran on the main agent's own sends -- and the main agent is the
one that actually writes to Józsi and to outside parties.

What it checks, all from standing owner rules in CLAUDE.md:
  1. Hungarian text that is missing its accents.
  2. Em dash (U+2014) -- forbidden in every deliverable.
  3. Double hyphen (' -- ') used as an em-dash substitute -- equally jarring.
  4. Mixed-script (homoglyph) words -- invisible when read, but silently
     breaks search/grep.
  5. Owner-specific NAME rules (misspelled surnames etc.) -- loaded from an
     untracked local rules file (GATEPERSIST816), never hardcoded here.

FAIL-CLOSED ON AN UNREADABLE BODY. If the call looks like a send but the body
cannot be recovered (e.g. `send.py ... < $SP/body.txt`, where $SP is a shell
variable this hook cannot resolve), the gate BLOCKS. A send whose content
cannot be inspected defeats the point of the gate, so "I could not read it"
must not mean "let it through". The block message says how to make it
inspectable.

Contract: PreToolUse. Reads the hook payload on stdin, exit 0 = allow,
exit 2 = block (stderr goes back to the model).
"""
import json
import os
import re
import sys

# --- what counts as an email send -------------------------------------------
# KAPUHATOKOR822: four false positives in one afternoon, on THREE operation
# types (inter-agent message, sqlite write, file READ). The old trigger
# searched the WHOLE command string for send-patterns, so the '"to":' of an
# inter-agent envelope plus 'send.py' mentioned in the CONTENT read as an
# email send -- the gate silenced the fleet on exactly the topic it most
# needs to talk about.
#
# The trigger therefore works on COMMAND POSITION, not content: heredoc
# bodies and quoted strings are cut first, then the INVOKED program of each
# pipeline segment decides. Sending is where the sender program runs:
#   - sendmail / msmtp / swaks in program position (these can only send);
#   - an ACTUAL invocation of this install's mail senders (send.py /
#     nas-mail-send.py, direct path or via python) with a --to recipient in
#     its OWN segment (so --help/reading does not trigger);
#   - graph-mail invoked with the `send` subcommand;
#   - curl/wget whose UNQUOTED URL token points at api.resend.com (a quoted
#     occurrence inside a -d payload does not count -- that is content).
# SECOND ROUND (adversarial measurement, msg 14282): the first version cut
# quoted strings BLINDLY, which opened two false negatives -- a quoted URL in
# curl's own argument position (curl's NORMAL way of being written) and a
# wrapper shell's `-c` string argument both passed through. The root cause: a
# quote is a good boundary against CONTENT, but it does not say whether the
# token stands in URL/PROGRAM position. So instead of stripping, QUOTE-AWARE
# tokenization runs (shlex): a quoted token arrives as ONE token, with its
# position intact -- curl's quoted URL argument is inspectable, while a
# domain mentioned inside a -d payload stays content (the URL pattern is
# anchored to the token's START). A wrapper shell (`sh -c "..."`) has its
# string argument analyzed recursively.
# Heredoc-stripping is ORDER-INDEPENDENT (third round): the LINE REMAINDER
# after the delimiter (e.g. a redirect: <<EOF > file) is part of the command
# and STAYS -- only the body falls out. Without this, (a) reversed order made
# the body look like a command (false positive), (b) dropping the intro line
# would have lost a heredoc-fed REAL sender (false negative).
_HEREDOC = re.compile(r"(<<-?\s*'?(\w+)'?[^\n]*)\n.*?\n\2(?=\s|$)", re.S)
_ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z_0-9]*=")
_SENDER_PROG = re.compile(r"^(sendmail|msmtp|swaks)$", re.I)
# This install's mail senders, by basename: the upstream default (send.py,
# scripts/support-mail/send.py here) plus this install's own
# scripts/nas-mail-send.py -- both take a --to recipient the same way.
_SENDPY = re.compile(r"^(send|nas-mail-send)\.py$", re.I)
_PYTHON = re.compile(r"^python3?$", re.I)
_NODEISH = re.compile(r"^(node|tsx|ts-node|deno|bun|npx)$", re.I)
_GRAPHMAIL = re.compile(r"^graph-mail(\.ts|\.js)?$", re.I)
_WRAPPER_SHELL = re.compile(r"^(sh|bash|zsh|dash)$", re.I)
_CURLISH = re.compile(r"^(curl|wget|http)$", re.I)
# Interpreter code-string argument (python -c / node -e): code handed to the
# interpreter is an OPERATION, not content -- filter for code-level send calls.
#
# STATED BOUNDARY: statically analyzing arbitrary interpreter code is
# undecidable -- this gate catches ACCIDENTAL sends, not a determined bypass.
# The heuristic below covers the NAIVE shapes (code that contains both a
# process-spawn AND a sender program name together); it claims no more.
_CODE_SEND = re.compile(
    r"\bsmtplib\b|SMTP\s*\(|\bsendMail\s*\(|\bsendEmail\b|\bmail\.send\b", re.I
)
_CODE_EXECISH = re.compile(
    r"\bsubprocess\b|os\.system|\bpopen\b|child_process|\bexec[A-Za-z]*\s*\(|\bspawn[A-Za-z]*\s*\(",
    re.I,
)
_CODE_SENDER_LIT = re.compile(r"sendmail|msmtp|swaks|send\.py", re.I)


def _code_string_sends(code: str) -> bool:
    if _CODE_SEND.search(code):
        return True
    return bool(_CODE_EXECISH.search(code) and _CODE_SENDER_LIT.search(code))


# Token-START anchored target pattern: a URL argument or a bare domain/path
# matches; a JSON payload ('{...api.resend.com...}') does not.
_RESEND_TARGET = re.compile(r"^(https?://)?([^/@\s]*\.)?api\.resend\.com(/|$|\s|$)", re.I)

# RESENDGATE826: a resend-target curl/wget is only a SEND if the METHOD is.
# The earlier pattern was method-blind, so a read-only GET /domains (no body,
# no recipient) got the same fail-closed rejection -- exactly when a
# domain-verification MEASUREMENT needed it. The narrowing is strict: the
# method must be RECOGNIZED (explicit -X/--request/--method, or implicit POST
# from body flags); if it cannot be determined (variable, config file,
# truncated flag), it stays fail-closed. There is NO "no recognizable body ->
# pass" branch -- that would gut the gate.
_CURL_BODY_OPTS = {
    "-d", "--data", "--data-raw", "--data-binary", "--data-urlencode",
    "--data-ascii", "-F", "--form", "--form-string", "--json",
    "-T", "--upload-file",
    "--post-data", "--post-file", "--body-data", "--body-file",
}
_SAFE_METHODS = {"GET", "HEAD"}


def _curl_resend_verdict(rest):
    """'read' | 'send' | 'unknown' -- unknown is fail-closed at the caller."""
    method = None
    has_body = False
    get_forced = False
    i, n = 0, len(rest)
    while i < n:
        t = rest[i]
        if t in ("-X", "--request", "--method"):
            if i + 1 >= n or not rest[i + 1].isalpha():
                return "unknown"  # truncated or a variable ($METHOD) -- undecidable
            method = rest[i + 1].upper()
            i += 2
            continue
        if t.startswith("--request=") or t.startswith("--method="):
            m = t.split("=", 1)[1]
            if not m.isalpha():
                return "unknown"
            method = m.upper()
            i += 1
            continue
        if t in ("-G", "--get"):
            get_forced = True
            i += 1
            continue
        if t in ("-K", "--config"):
            return "unknown"  # a config file may carry a hidden method/body
        if t in _CURL_BODY_OPTS or any(
            t.startswith(o + "=") for o in _CURL_BODY_OPTS if o.startswith("--")
        ):
            has_body = True
            i += 1
            continue
        if t.startswith("-") and not t.startswith("--") and len(t) > 1:
            # a single-hyphen cluster (-sS, -sX POST, -sd '{}'): letters bundled
            letters = t[1:]
            if "X" in letters:
                after = letters.split("X", 1)[1]
                if after:
                    if not after.isalpha():
                        return "unknown"
                    method = after.upper()
                else:
                    if i + 1 >= n or not rest[i + 1].isalpha():
                        return "unknown"
                    method = rest[i + 1].upper()
                    i += 1
            elif "d" in letters or "F" in letters or "T" in letters:
                has_body = True
            elif "G" in letters:
                get_forced = True
            elif "K" in letters:
                return "unknown"
            i += 1
            continue
        i += 1
    if method is not None and method not in _SAFE_METHODS:
        return "send"
    if has_body and not get_forced:
        # implicit POST (curl -d/-F/--json/-T default), or a suspicious
        # "GET with a body" shape -- both treated as a send
        return "send"
    return "read"


# Additional send-shaped literals used ONLY as the conservative fallback when
# parsing fails -- see is_send_invocation at the end.
_FALLBACK_LITERALS = re.compile(
    r"send\.py|api\.resend\.com|\bsendmail\b|\bmsmtp\b|\bswaks\b"
    r"|\bsmtplib\b|\bsendMail\s*\(", re.I
)


def _basename(tok: str) -> str:
    return tok.rsplit("/", 1)[-1]


def _mask_subshell_markers(cmd: str) -> str:
    """Newline/`$(`/backtick OUTSIDE quotes -> a `;` separator, so shlex sees
    a segment boundary; text INSIDE quotes is untouched (content)."""
    out = []
    q = None  # None | "'" | '"'
    i, n = 0, len(cmd)
    while i < n:
        ch = cmd[i]
        if q:
            if ch == "\\" and q == '"' and i + 1 < n:
                out.append(cmd[i:i + 2]); i += 2; continue
            if ch == q:
                q = None
            out.append(ch); i += 1; continue
        if ch in "'\"":
            q = ch; out.append(ch); i += 1; continue
        if ch == "\\" and i + 1 < n:
            out.append(cmd[i:i + 2]); i += 2; continue
        if ch == "\n" or ch == "`":
            out.append(";"); i += 1; continue
        if ch == "$" and i + 1 < n and cmd[i + 1] == "(":
            out.append(";"); i += 2; continue
        out.append(ch); i += 1
    return "".join(out)


def _segments_tokens(cmd: str):
    """[[token, ...], ...] per segment -- quote-aware, position preserved."""
    import shlex
    lex = shlex.shlex(_mask_subshell_markers(_HEREDOC.sub(r"\1", cmd)),
                      posix=True, punctuation_chars="();|&")
    lex.whitespace_split = True
    segments, cur = [], []
    for tok in lex:
        if tok in ("|", "||", "&", "&&", ";", "(", ")", ";;", "|&"):
            if cur:
                segments.append(cur)
            cur = []
        else:
            cur.append(tok)
    if cur:
        segments.append(cur)
    return segments


def _segment_is_send(toks, depth: int) -> bool:
    while toks and _ENV_ASSIGN.match(toks[0]):
        toks = toks[1:]
    if not toks:
        return False
    prog = _basename(toks[0])
    rest = toks[1:]
    if _SENDER_PROG.match(prog):
        return True
    # wrapper shell: the -c string argument is itself a command -- recurse
    if _WRAPPER_SHELL.match(prog) and depth < 3:
        for i, t in enumerate(rest):
            if t == "-c" and i + 1 < len(rest):
                if is_send_invocation(rest[i + 1], _depth=depth + 1):
                    return True
    # interpreter code-string: python -c / node -e / --eval calling a sender
    if _PYTHON.match(prog) or _NODEISH.match(prog):
        for i, t in enumerate(rest):
            if t in ("-c", "-e", "--eval") and i + 1 < len(rest) and _code_string_sends(rest[i + 1]):
                return True
    # send.py / nas-mail-send.py invoked (directly, or via python/a runner)
    # with a --to recipient
    candidates = [prog] + (
        [_basename(rest[0])] if rest and (_PYTHON.match(prog) or _NODEISH.match(prog)) else []
    )
    if any(_SENDPY.match(c) for c in candidates) and any(
        t == "--to" or t.startswith("--to=") for t in rest
    ):
        return True
    # graph-mail with the outbound subcommand (also via a tsx/node runner)
    if any(_GRAPHMAIL.match(_basename(t)) for t in toks) and "send" in rest:
        return True
    # curl/wget: the target token is an operation even when it sat in quotes --
    # the anchored pattern separates it from a mention inside the payload.
    # RESENDGATE826: only an ACTUAL send (POST/PUT/... or a body) fires; a
    # read-only GET/HEAD query passes; an undecidable method stays fail-closed.
    if _CURLISH.match(prog) and any(_RESEND_TARGET.match(t) for t in rest):
        return _curl_resend_verdict(rest) != "read"
    return False


def is_send_invocation(cmd: str, _depth: int = 0) -> bool:
    try:
        segments = _segments_tokens(cmd)
    except ValueError:
        # Parse error (e.g. an unbalanced quote): no position can be trusted.
        # Conservative fallback: audit only if a strong send literal sits in
        # the text -- an odd but real send does not slip through silently,
        # while typical internal commands do not get a false positive.
        return bool(_FALLBACK_LITERALS.search(cmd))
    return any(_segment_is_send(toks, _depth) for toks in segments)

# --- Hungarian detection (accent-insensitive markers) -----------------------
# These fire on both the correct and the stripped spelling, so a transliterated
# mail is still recognised as Hungarian -- that is the whole point.
HU_MARKERS = [
    "hogy", "nem", "vagy", "amit", "ami", "mert", "ezt", "ez a", "van", "lesz",
    "kell", "tehat", "tehát", "koszonom", "köszönöm", "szia", "sziasztok",
    "kerlek", "kérlek", "csatolva", "udvozlettel", "üdvözlettel", "levelet",
    "level", "kuldom", "küldöm", "jelezz", "irj", "írj", "mar", "már", "csak",
]

# Accentless spellings of frequent Hungarian words -> the correct form. Every
# entry is a word that CANNOT be spelled without its accent, so a hit inside
# Hungarian text is an error, not a style choice.
ACCENTLESS = {
    "es": "és", "tehat": "tehát", "koszonom": "köszönöm", "koszi": "köszi",
    "koszonjuk": "köszönjük", "kerlek": "kérlek", "kerem": "kérem",
    "kerjuk": "kérjük", "kerdes": "kérdés", "kerdesem": "kérdésem",
    "valasz": "válasz", "valaszt": "választ", "valaszol": "válaszol",
    # "levelet" is deliberately NOT here: the dictionary invariant is that
    # every entry is a word that CANNOT be spelled without its accent. "level"
    # accepting the -et suffix stays a correct accentless-looking form
    # ("levelet") that used to self-block every correct Hungarian letter. Its
    # possessive counterpart ("levelét") collides accentless -- the gate
    # cannot and must not try to resolve that ambiguity.
    "level": "levél", "levelre": "levélre",
    "elore": "előre", "elott": "előtt", "utan": "után", "kozott": "között",
    "kesz": "kész", "keszult": "készült", "keszen": "készen",
    "ervenyes": "érvényes", "ervenytelen": "érvénytelen",
    "telepito": "telepítő", "telepites": "telepítés", "telepiteni": "telepíteni",
    "ujra": "újra", "uj": "új", "ujat": "újat", "igy": "így", "ugy": "úgy",
    "tobb": "több", "tobbi": "többi", "kulon": "külön", "kuldom": "küldöm",
    "kuldtem": "küldtem", "kuldes": "küldés", "kuldunk": "küldünk",
    "fajl": "fájl", "fajlt": "fájlt", "fajlok": "fájlok",
    "hatarido": "határidő", "hataridot": "határidőt",
    "lehetoseg": "lehetőség", "lehetoseget": "lehetőséget",
    "szukseges": "szükséges", "szuksege": "szüksége",
    "mukodik": "működik", "mukodes": "működés", "muszaki": "műszaki",
    "beallitas": "beállítás", "beallitani": "beállítani",
    "elofizetes": "előfizetés", "elofizetest": "előfizetést",
    "szamla": "számla", "szamlat": "számlát", "szamlazas": "számlázás",
    "arajanlat": "árajánlat", "ar": "ár", "arak": "árak",
    "ora": "óra", "orakor": "órakor", "ev": "év", "evi": "évi",
    "honap": "hónap", "het": "hét", "hetfo": "hétfő", "csutortok": "csütörtök",
    "pentek": "péntek", "januar": "január", "februar": "február",
    "marcius": "március", "aprilis": "április", "majus": "május",
    "junius": "június", "julius": "július", "oktober": "október",
    "ket": "két", "harom": "három", "negy": "négy", "ot": "öt",
    "szivesen": "szívesen", "erteket": "értéket", "ertem": "értem",
    "jol": "jól", "rovid": "rövid", "hosszu": "hosszú", "biztonsagos": "biztonságos",
    "eleresi": "elérési", "elerheto": "elérhető",
    "sajat": "saját", "tovabbi": "további", "tovabb": "tovább",
    "figyelmeztetes": "figyelmeztetés", "ellenorizd": "ellenőrizd",
    "ellenorzes": "ellenőrzés", "reszletek": "részletek", "resz": "rész",
    "vegen": "végén", "vegre": "végre", "elinditja": "elindítja",
    "inditas": "indítás", "masold": "másold", "masolat": "másolat",
    "gepre": "gépre", "gep": "gép", "gepen": "gépen",
    "ervenyesites": "érvényesítés", "aktivalas": "aktiválás",
    "hozzajarulas": "hozzájárulás", "elofordul": "előfordul",
    "elso": "első", "ezert": "ezért", "valodi": "valódi",
    "nelkul": "nélkül", "miert": "miért", "utana": "utána",
    "kovetkezo": "következő", "szekcio": "szekció", "tenyleg": "tényleg",
    "videot": "videót", "video": "videó", "azert": "azért",
    "hivas": "hívás", "szam": "szám", "szoveg": "szöveg",
    "mas": "más", "kulso": "külső", "dontes": "döntés",
    "letezik": "létezik", "kozvetlenul": "közvetlenül", "felhasznalo": "felhasználó",
    "nema": "néma", "verzio": "verzió", "erdemes": "érdemes",
    "irja": "írja", "mostantol": "mostantól", "latszik": "látszik",
    "szoval": "szóval", "kozos": "közös", "netto": "nettó",
    "cim": "cím", "futo": "futó", "javitas": "javítás",
    "kockazat": "kockázat", "ebbol": "ebből", "mindket": "mindkét",
    "eleg": "elég", "regi": "régi", "kulonbozo": "különböző",
    "kezzel": "kézzel", "peldaul": "például", "izolalt": "izolált",
    "kozben": "közben", "udvozlettel": "üdvözlettel", "oket": "őket",
    "afa": "áfa", "allapot": "állapot", "all": "áll",
}

# GATEHOMOGLIF816: mixed-script (homoglyph) words are invisible when read but
# silently break search/grep. The rule targets a MIXED word (Latin AND
# non-Latin letters inside ONE word), not the mere presence of a non-Latin
# script -- a deliberately foreign-language quote's PURE non-Latin words pass.
UWORD = re.compile(r"[^\W\d_]+", re.UNICODE)


def _char_script(ch: str) -> str:
    import unicodedata
    try:
        return unicodedata.name(ch).split(" ")[0]
    except ValueError:
        return "UNKNOWN"


def mixed_script_words(text: str):
    """Return [(word, bad_char, bad_char_name), ...] for words mixing LATIN
    with any other script. Pure non-Latin words (foreign quotes) pass."""
    import unicodedata
    out = []
    for word in UWORD.findall(text):
        scripts = {_char_script(ch) for ch in word}
        if "LATIN" in scripts and len(scripts) > 1:
            bad = next(ch for ch in word if _char_script(ch) != "LATIN")
            try:
                bad_name = unicodedata.name(bad)
            except ValueError:
                bad_name = "UNKNOWN"
            out.append((word, bad, f"{bad_name} (U+{ord(bad):04X})"))
    return out


EM_DASH = "—"

# GATEPERSIST816: owner-specific NAME rules load from an UNTRACKED local file,
# not from this (repo-tracked) script. The generic checks (accents, em dash,
# double hyphen, mixed-script) are universal Hungarian-copy QA and ship in the
# repo; a personal-name rule names a private third party, and that must not be
# published as a side effect of persisting the gate. A missing rules file is
# NOT silent: every run appends a loud line to the gate log, because a
# protection whose absence is invisible only protects until someone touches
# the tree. File shape: {"bad_name_patterns": ["<python-regex>", ...]}
_LOCAL_RULES = os.environ.get(
    "OUTGOING_COPY_GATE_RULES",
    os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                 "store", "outgoing-copy-gate-rules.json"),
)


def load_bad_name():
    try:
        with open(_LOCAL_RULES, encoding="utf-8") as fh:
            pats = json.load(fh).get("bad_name_patterns") or []
        if pats:
            return re.compile("|".join(pats))
    except OSError:
        pass
    except Exception:
        pass
    try:
        log_path = os.path.join(os.path.dirname(_LOCAL_RULES), "outgoing-copy-gate.log")
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write(f"outgoing-copy-gate: NEV-SZABALY FAJL HIANYZIK/URES ({_LOCAL_RULES}) -- "
                     "a nev-ellenorzes NEM fut; potold a store/outgoing-copy-gate-rules.json-t.\n")
    except OSError:
        pass
    return None


def _name_correction() -> str:
    try:
        with open(_LOCAL_RULES, encoding="utf-8") as fh:
            corr = json.load(fh).get("correction") or ""
        return (" " + corr) if corr else ""
    except Exception:
        return ""


BAD_NAME = load_bad_name()
ACCENTED = set("áéíóöőúüűÁÉÍÓÖŐÚÜŰ")
TAG = re.compile(r"<[^>]+>")

# GATEKOTOJEL817 + GATEHYPH816: two false positives in five minutes, in a live
# owner conversation, both the same class -- the gate could not tell PROSE
# from IDENTIFIER. (1) `Drive-ot` -- a Hungarian suffix attaches to a foreign
# proper noun WITH a hyphen (that is the correct spelling), but the
# letters-only tokenizer cut at the hyphen and read the `ot` remainder as a
# standalone Hungarian word (ot -> öt). (2) `Video atalakitas` -- a Drive
# folder NAME quoted in prose: a mid-sentence capitalized word is an
# identifier, not prose. The fix is TOKENIZATION, not the dictionary (a word
# exception list would also pass real errors):
#   - a hyphenated form is checked as the WHOLE token (`drive-ot` as one is
#     not in the dictionary -> passes; the standalone `ot` in prose still
#     fails);
#   - a MID-SENTENCE capitalized word is an identifier/proper noun -> skipped;
#     at the START of a sentence (after . ! ? : a newline or a list marker)
#     a capital is normal prose and stays checked.
HYPHEN_WORD = re.compile(r"[a-záéíóöőúüűA-ZÁÉÍÓÖŐÚÜŰ]+(?:-[a-záéíóöőúüűA-ZÁÉÍÓÖŐÚÜŰ]+)*")


def _at_sentence_start(text: str, idx: int) -> bool:
    i = idx - 1
    while i >= 0 and text[i] in " \t\"'([{":
        i -= 1
    if i < 0:
        return True
    ch = text[i]
    if ch in ".!?:\n":
        return True
    if ch in "-*•":
        j = i - 1
        while j >= 0 and text[j] in " \t":
            j -= 1
        return j < 0 or text[j] == "\n"
    return False


def accent_check_tokens(prose: str):
    """(lowercase form, start position) pairs for the accent check."""
    out = []
    for m in HYPHEN_WORD.finditer(prose):
        tok = m.group(0)
        # DIGIT-HYPHEN SUFFIX (429-es, 403-as, 2026-os, 3420-as). HYPHEN_WORD
        # only admits LETTERS around the hyphen, so a Hungarian suffix
        # attached to a NUMBER is seen as a standalone word -- and "es" then
        # reads as the accent-stripped "és". These are not prose words; they
        # carry no accent. GATESZAMKOTOJEL821 covered this; GATEKOTOJEL817
        # only covered letter-hyphen-letter forms.
        if m.start() >= 2 and prose[m.start() - 1] == "-" and prose[m.start() - 2].isdigit():
            continue
        if "-" not in tok and tok[0].isupper() and not _at_sentence_start(prose, m.start()):
            continue
        out.append((tok.lower(), m.start()))
    return out


def _hit_context(prose: str, pos: int, length: int) -> str:
    """3 words of context each side plus the character position (GATEHYPH816
    (B): so a false positive costs one glance, not a grep of your own text
    mid-conversation)."""
    before = prose[:pos].split()[-3:]
    token = prose[pos:pos + length]
    after = prose[pos + length:].split()[:3]
    frag = " ".join(before + [token] + after)
    return f'"...{frag}..." @{pos}'


# Technical tokens are masked BEFORE the accent check runs. Measured on the
# +48 accent-list expansion's negative control: a correctly-accented live
# letter got stuck on the "video" inside a `video_view` event name. The
# tokenizer treats the underscore as a boundary, so every snake_case
# identifier, filename, URL slug and domain contributes a "Hungarian word"
# that is correctly accent-free there. The fix does not remove dictionary
# entries (that would also let real mistakes through) -- it cuts the
# technical regions out of the text under review. The em-dash and name
# checks do NOT run on this.
TECHNICAL = re.compile(
    r"""https?://\S+                # URL
      | [\w.+-]+@[\w-]+\.[\w.]+     # email
      | `[^`]*`                     # code span
      | \b\w+(?:_\w+)+\b            # snake_case identifier
      | \b\w+\.[A-Za-z]{2,10}\b     # filename / domain (video.mp4, marveen.io)
      | \b[\w-]*/[\w/-]+            # path / slug
    """,
    re.X,
)


def strip_technical(text: str) -> str:
    return TECHNICAL.sub(" ", text)


def is_hungarian(text: str) -> bool:
    low = text.lower()
    return sum(1 for m in HU_MARKERS if m in low) >= 3


# GATETG816: is_hungarian() filters on function words, so a TERSE,
# fact-stating, list-style Hungarian message (exactly the main agent's
# Telegram style) may not reach 3 markers, and the accent check never starts.
# The language detector is therefore not the SOLE gate any more: a single
# dictionary hit that CANNOT exist unaccented in Hungarian AND cannot be read
# as an English/technical word is reason enough on its own to run the audit.
# The exclusion below applies ONLY to the trigger: if the text is proven
# Hungarian some other way, these hits are still reported -- alone, they just
# cannot pull an English sentence into the audit ("the all-new level editor").
AMBIGUOUS_TRIGGER = {
    "es", "ar", "arak", "ev", "evi", "ot", "uj", "ujat", "het", "ora", "mas",
    "all", "level", "video", "netto",
}


def accentless_evidence(words):
    return {w for w in words if w in ACCENTLESS and w not in AMBIGUOUS_TRIGGER}


def collect_bash_body(cmd: str):
    """Return (text, unreadable_reason). text is '' when nothing was recovered."""
    parts = []
    for m in re.finditer(r"--(?:body|subject)[= ]+(\"([^\"]*)\"|'([^']*)'|(\S+))", cmd):
        val = m.group(2) or m.group(3) or m.group(4) or ""
        # A shell-expanded --body ($(cat f), `cat f`, $VAR) reaches this hook
        # UNEXPANDED: what we would audit is the literal command text, not the
        # letter. That is worse than useless -- it fires on words that happen
        # to sit in the PATH while the real copy goes uninspected. Same
        # fail-closed rule as the `<` branch below.
        if re.search(r"\$\(|`|\$\{?\w", val):
            return ("\n".join(parts),
                    "a --body shell-behelyettesitest tartalmaz, amit a hook nem old fel "
                    f"({val[:60]}...) -- igy a parancs szoveget vizsgalnam, nem a levelet")
        parts.append(val)
    # heredoc payloads sit inline in the command string
    for m in re.finditer(r"<<-?\s*'?(\w+)'?\n(.*?)\n\1", cmd, re.S):
        parts.append(m.group(2))
    # A single `<` only. Without the lookarounds a heredoc (`<<'EOF'`) matches
    # here and the quoted delimiter is taken for a filename.
    redirect = re.search(r"(?<!<)<(?!<)\s*([^\s|;&<>]+)", cmd)
    if redirect:
        raw = redirect.group(1)
        path = os.path.expandvars(os.path.expanduser(raw))
        if "$" in path:
            return ("\n".join(parts), f"a torzs egy fel nem oldhato utvonalrol jon ({raw})")
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                parts.append(fh.read())
        except OSError as exc:
            return ("\n".join(parts), f"a torzs-fajl nem olvashato ({path}: {exc})")
    if not parts and re.search(r"\|\s*(python3?|node|tsx)?[^|]*send", cmd):
        return ("", "a torzs egy pipe-bol jon, a hook nem latja")
    return ("\n".join(parts), None)


def collect_mcp_body(tool_input: dict):
    fields = ("body", "text", "html", "htmlBody", "message", "subject", "content")
    got = [str(tool_input[f]) for f in fields if tool_input.get(f)]
    return "\n".join(got)


# --- Telegram reply (GATETG816) ---------------------------------------------
# The reply tool sends MarkdownV2, where every special char arrives escaped
# (\. \( \) \-). Those backslashes sit inside the prose the audit reads, and
# they can split technical tokens or glue fragments in ways the email path
# never sees. Un-escape (backslash before a non-word char) BEFORE auditing --
# this is analysis-only, the outgoing payload is untouched.
MDV2_ESCAPE = re.compile(r"\\([^\w\s])")


def collect_telegram_body(tool_input: dict) -> str:
    fields = ("text", "caption", "message")
    got = [str(tool_input[f]) for f in fields if tool_input.get(f)]
    return MDV2_ESCAPE.sub(r"\1", "\n".join(got))


def telegram_gate(tool_input: dict) -> None:
    """Audit a Telegram reply. FAIL-OPEN on any internal error (exit 0 + loud
    log): email is deferrable, but Telegram is the owner's ONLY supervision
    channel -- a gate crash that silences it costs more than a slipped accent.
    A FOUND problem still blocks (exit 2): that is the gate's whole point."""
    try:
        text = collect_telegram_body(tool_input)
        if not text.strip():
            sys.exit(0)  # files-only reply or empty text: nothing to audit
        problems = audit(text)
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 -- deliberate blanket: fail-open path
        warn = f"outgoing-copy-gate: TELEGRAM-ag belso hiba, FAIL-OPEN atengedes: {exc!r}\n"
        sys.stderr.write(warn)
        try:
            log_path = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
                os.path.abspath(__file__)))), "store", "outgoing-copy-gate.log")
            with open(log_path, "a", encoding="utf-8") as fh:
                fh.write(warn)
        except OSError:
            pass
        sys.exit(0)
    if problems:
        sys.stderr.write(
            "KIMENO-SZOVEG KAPU (Telegram): TILTVA, az uzenet nem mehet ki igy.\n\n"
            + "\n".join(f"  - {p}" for p in problems)
            + "\n\nJavitsd a szoveget es kuldd ujra (a MarkdownV2 escape-eket a kapu "
              "az ellenorzes elott feloldja, azok nem szamitanak hibanak).\n"
        )
        sys.exit(2)
    # GATEPERSIST816(2): the missing name-rule stays fail-open on the telegram
    # leg, but the warning goes WHERE the session actually sees it -- the
    # hook's stdout systemMessage field shows up in the running session, not
    # a log file nobody reads.
    if BAD_NAME is None:
        print(json.dumps({"systemMessage":
            "outgoing-copy-gate: a NEV-SZABALY fajl hianyzik/ures "
            f"({_LOCAL_RULES}) -- a nev-ellenorzes NEM fut a kimeno uzeneteken. "
            "Potold a store/outgoing-copy-gate-rules.json-t."}))
    sys.exit(0)


def audit(text: str):
    """Return a list of human-readable problems."""
    plain = TAG.sub(" ", text)
    problems = []
    if EM_DASH in plain:
        problems.append(
            f"GONDOLATJEL (em dash, U+2014) {plain.count(EM_DASH)} helyen -- allo szabaly, soha nem mehet ki."
        )
    bad = BAD_NAME.search(plain) if BAD_NAME else None
    if bad:
        problems.append(
            f"HELYTELEN NEV: {bad.group(0)!r} -- a lokal nev-szabaly (store/outgoing-copy-gate-rules.json) szerint helytelen alak; a helyes irast a szabaly-fajl correction mezoje adja." + _name_correction()
        )
    prose = strip_technical(plain)
    # DOUBLE HYPHEN as an em-dash substitute: ' -- ' is just as jarring in
    # prose as the forbidden em dash. Measured on the PROSE (after
    # strip_technical), so code/command --flag forms are unaffected -- those
    # are not ' -- ' shaped anyway (no space after the hyphens), but cutting
    # the technical regions is the safe boundary regardless.
    dh = prose.count(" -- ")
    if dh:
        problems.append(
            f"DUPLA KOTOJEL gondolatjel-potlokent {dh} helyen (' -- ') -- "
            "ugyanugy zavaro, mint az em dash. Ird at kotojel nelkul: kettospont, zarojel, vagy uj mondat."
        )
    # GATEHOMOGLIF816: mixed-script word. Deliberately NOT Hungarian-gated:
    # the FP protection is the MIXED-word rule itself -- a legitimate foreign
    # quote's words are PURE non-Latin, never mixed. Gating this on Hungarian
    # would protect nothing here, but would open a hole: a homoglyph inside a
    # correctly-accented, 2-marker Hungarian text would slip through (the
    # marker pair alone is too thin for the language detector). Name the
    # concrete word AND character, because the defect is invisible to the eye.
    mixed = mixed_script_words(prose)
    if mixed:
        shown = "; ".join(f"{w!r} -- benne {name}" for w, _c, name in mixed[:5])
        more = f" (+{len(mixed) - 5} tovabbi)" if len(mixed) > 5 else ""
        problems.append(
            f"VEGYES IRASRENDSZERU SZO (homoglifa), {len(mixed)} db: {shown}{more}. "
            "Latin szoba keveredett nem-latin betu: olvasva lathatatlan, de a keresest/grepet neman eltori."
        )
    tok_pos = accent_check_tokens(prose)
    words = [w for w, _ in tok_pos]
    if is_hungarian(plain) or accentless_evidence(words):
        hits = sorted({w for w in words if w in ACCENTLESS})
        # The ratio is also measured on the prose: technical tokens carry no
        # accents, so a code-rich but otherwise correct letter would drag the
        # ratio down.
        letters = sum(1 for ch in prose if ch.isalpha())
        acc = sum(1 for ch in prose if ch in ACCENTED)
        ratio = (acc / letters) if letters else 0.0
        if hits:
            first_pos = {}
            for w, p in tok_pos:
                if w in ACCENTLESS and w not in first_pos:
                    first_pos[w] = p
            shown = ", ".join(
                f"{h} -> {ACCENTLESS[h]} ({_hit_context(prose, first_pos[h], len(h))})"
                for h in hits[:12]
            )
            more = f" (+{len(hits) - 12} tovabbi)" if len(hits) > 12 else ""
            problems.append(f"HIANYZO EKEZETEK, {len(hits)} szo: {shown}{more}")
        elif letters > 200 and ratio < 0.01:
            problems.append(
                f"MAGYAR SZOVEG GYAKORLATILAG EKEZET NELKUL (ekezet-arany {ratio:.3%}, {letters} betun). "
                "A szolistam nem talalt konkret talalatot, de az arany onmagaban gepi atirasra utal -- olvasd vissza."
            )
    return problems


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)  # unparseable payload must not wedge the session

    tool = str(payload.get("tool_name") or "")
    tool_input = payload.get("tool_input") or {}

    if re.search(r"telegram.*__reply$", tool, re.I):
        telegram_gate(tool_input)  # exits; never falls through
    if re.search(r"send_email", tool, re.I):
        text, unreadable = collect_mcp_body(tool_input), None
    elif tool == "Bash":
        cmd = str(tool_input.get("command") or "")
        if not is_send_invocation(cmd):
            sys.exit(0)
        text, unreadable = collect_bash_body(cmd)
    else:
        sys.exit(0)

    if unreadable or not text.strip():
        reason = unreadable or "a hook nem talalt vizsgalhato szoveget a hivasban"
        sys.stderr.write(
            "KIMENO-SZOVEG KAPU: TILTVA, mert a levelet nem tudtam megvizsgalni.\n"
            f"Ok: {reason}.\n\n"
            "Ez szandekosan fail-closed: egy vizsgalhatatlan kuldes pont a kaput utne ki.\n"
            "Tedd vizsgalhatova, aztan kuldd ujra -- ABSZOLUT utvonalu stdin-atiranyitas "
            "(< /teljes/ut/body.txt, shell-valtozo NELKUL), vagy --body-ban atadott szoveg.\n"
        )
        sys.exit(2)

    # GATEPERSIST816(2): the EMAIL leg is fail-closed on the missing
    # name-rule. Mail is deferrable, and it is the recipient's side where a
    # wrong name costs the most -- sending with a silently disabled
    # name-check is worse than waiting for the rules file to be filled in.
    # (The telegram leg stays fail-open with a systemMessage warning: that is
    # the supervision channel, and going silent there is the more expensive
    # failure.)
    if BAD_NAME is None:
        sys.stderr.write(
            "KIMENO-SZOVEG KAPU: TILTVA -- a NEV-SZABALY fajl hianyzik/ures "
            f"({_LOCAL_RULES}), igy a nev-ellenorzes nem tud lefutni.\n"
            "Email fail-closed: potold a store/outgoing-copy-gate-rules.json-t "
            "(bad_name_patterns + correction), aztan kuldd ujra.\n"
        )
        sys.exit(2)

    problems = audit(text)
    if problems:
        sys.stderr.write(
            "KIMENO-SZOVEG KAPU: TILTVA, a levél nem mehet ki így.\n\n"
            + "\n".join(f"  - {p}" for p in problems)
            + "\n\nJavitsd a szoveget es kuldd ujra. Ekezetes magyar szoveg a vevo fele "
              "nem stiluskerdes.\n"
        )
        sys.exit(2)

    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 -- deliberate blanket: fail-closed net
        # An unhandled crash exits 1, and PreToolUse treats 1 as NON-blocking,
        # so the send would run UNCHECKED -- the exact opposite of the email
        # path's fail-closed contract (e.g. a non-dict tool_input used to
        # AttributeError inside collect_mcp_body). The telegram path never
        # reaches here: telegram_gate() catches its own errors and exits 0
        # (fail-open by design), so this net only ever catches the email/Bash
        # send paths, where blocking is the safe failure mode.
        sys.stderr.write(
            "KIMENO-SZOVEG KAPU: TILTVA, belso hiba a vizsgalat kozben "
            f"({exc!r}).\n"
            "Fail-closed: egy vizsgalhatatlan kuldes pont a kaput utne ki. "
            "Tedd vizsgalhatova a hivast, aztan kuldd ujra.\n"
        )
        sys.exit(2)
