#!/usr/bin/env python3
"""A patch-oro (scripts/telegram-plugin-patch-guard.py) poller-slot patch-enek tesztje.

MIT MER: a `patch_content()` fuggveny viselkedeset egy PRISTINE fixture-on, ami
a valodi server.ts negy erintett regiojanak SZO SZERINTI masolata (55-78, 663,
1012-1013 sor). Nem a telepitett fajlt irja -- tisztan fuggveny-szintu.

A NEGY HORGONY es a MIND-VAGY-SEMMI SZABALY: a poller-patch negy kulon ponton
szur be kodot, es ezek EGYMASRA epulnek (a `CHANNEL_SESSION` konstanst a H1
vezeti be, a H2 es a H4 hasznalja). Egy FEL-alkalmazott patch tehat NEM
"reszben jo", hanem SZINTAKTIKAILAG TOROTT server.ts-t hagyna a lemezen, ami
minden Telegram-csatornat megnemitana. Ezert a patch_content()-nek eloszor
MIND A NEGY horgonyt ellenoriznie kell, es ha barmelyik hianyzik, EGYIKET SEM
szabad alkalmaznia.

Futtatas:
  python3 /Users/ceo/Marveen/scripts/__tests__/telegram-plugin-patch-guard-poller.test.py
"""
import importlib.util
import os
import sys

GUARD_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                          'telegram-plugin-patch-guard.py')

_spec = importlib.util.spec_from_file_location('tg_patch_guard', GUARD_PATH)
guard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(guard)

# ---------------------------------------------------------------------------
# A NEGY HORGONY -- a valodi server.ts-bol szo szerint kimasolva. A teszt
# SZANDEKOSAN sajat maga deklaralja oket (nem a patch-orobol importalja):
# igy a szerzodest meri, nem az implementacio onmagaval valo egyezeset.
# ---------------------------------------------------------------------------
H1 = "const PID_FILE = join(STATE_DIR, 'bot.pid')"

H2 = """mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 })
try {
  const stale = parseInt(readFileSync(PID_FILE, 'utf8'), 10)
  if (stale > 1 && stale !== process.pid) {
    process.kill(stale, 0)
    // PID files race with OS PID recycling — verify the holder is actually a
    // server.ts process before SIGTERM. Otherwise a recycled PID can point at
    // our own bun-run wrapper (kills our stdin → immediate self-shutdown) or
    // an unrelated user process.
    const cmd = execFileSync('ps', ['-p', String(stale), '-o', 'args='], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })
    if (cmd.includes('server.ts')) {
      process.stderr.write(`telegram channel: replacing stale poller pid=${stale}\\n`)
      process.kill(stale, 'SIGTERM')
    }
  }
} catch {}
writeFileSync(PID_FILE, String(process.pid))"""

H3 = "    if (parseInt(readFileSync(PID_FILE, 'utf8'), 10) === process.pid) rmSync(PID_FILE)"

H4 = "void (async () => {\n  for (let attempt = 1; ; attempt++) {"

POLLER_PRISTINE = (
    "const INBOX_DIR = join(STATE_DIR, 'inbox')\n"
    + H1 + "\n"
    "\n"
    "// Telegram allows exactly one getUpdates consumer per token. If a previous\n"
    "// session crashed (SIGKILL, terminal closed) its server.ts grandchild can\n"
    "// survive as an orphan and hold the slot forever, so every new session sees\n"
    "// 409 Conflict. Kill any stale holder before we start polling.\n"
    + H2 + "\n"
    "\n"
    "function shutdown(): void {\n"
    "  try {\n"
    + H3 + "\n"
    "  } catch {}\n"
    "}\n"
    "\n"
    + H4 + "\n"
    "    try {\n"
    "      await bot.start({})\n"
    "      return\n"
    "    } catch (err) {\n"
    "      if (shuttingDown) return\n"
    "    }\n"
    "  }\n"
    "})()\n"
)

# A meglevo reply_to patch fixture-je -- a vegyes eset (9.) hasznalja.
REPLY_TO_PRISTINE = (
    'x = [\n'
    '  \'Messages from Telegram arrive as <channel source="telegram" chat_id="..." '
    'message_id="..." user="..." ts="...">. If the tag has an image_path attribute, '
    "Read that file.',\n"
    ']\n\n'
    'const imagePath = downloadImage ? await downloadImage() : undefined\n\n'
    'meta: {\n'
    '  chat_id,\n'
    '  ...(msgId != null ? { message_id: String(msgId) } : {}),\n'
    '  user: from.username,\n'
    '},\n'
)

# A patch-tol elvart, SZERZODES-szintu reszletek.
MARKER_POLLER = 'MARVEEN-PATCH: poller-slot guard'
EXPECTED_FRAGMENTS = [
    MARKER_POLLER,
    "const OWNER_FILE = join(STATE_DIR, 'bot.owner')",
    'findChannelSessionFlag',
    'const CHANNEL_SESSION = findChannelSessionFlag()',
    'leaving it alone',
    'poller slot left untouched',
    'polling disabled',
    'rmSync(OWNER_FILE)',
]

FAILURES = []


def fail(case, msg):
    FAILURES.append(f'{case}: {msg}')
    print(f'[FAIL] {case}: {msg}')


def ok(case, msg):
    print(f'[PASS] {case}: {msg}')


def check(case, cond, msg):
    if cond:
        ok(case, msg)
    else:
        fail(case, msg)

    return cond


def poller_warnings(warnings):
    """A POLLER_PRISTINE fixture szandekosan CSAK a poller-regiokat tartalmazza,
    ezert a mar meglevo reply_to-horgonyok hianya varhato figyelmeztetes -- a
    teljes fajlra vonatkozo szigoru "nulla figyelmeztetes" allitas a 9. (vegyes)
    esetben all."""
    return [w for w in warnings if 'poller' in w]


def test_pristine_patchable():
    case = '5-pristine'
    patched, changed, warnings = guard.patch_content(POLLER_PRISTINE)
    check(case, changed, 'a pristine tartalomnak valtoznia kell')
    check(case, not poller_warnings(warnings),
          f'nem lehet poller-figyelmeztetes (kapott: {poller_warnings(warnings)})')

    for frag in EXPECTED_FRAGMENTS:
        check(case, frag in patched, f'a patch-elt tartalomban ott kell legyen: {frag!r}')

    return patched


def test_idempotent(patched):
    case = '6-idempotencia'
    patched2, changed2, warnings2 = guard.patch_content(patched)
    check(case, not changed2, 'mar patch-elt tartalmat nem szabad ujra modositani')
    check(case, patched2 == patched, 'a masodik futas bajtazonos kell legyen')


def test_atomicity():
    """MIND-VAGY-SEMMI: barmelyik horgony hianyaban SEMMI nem valtozhat."""
    mutations = [
        ('H1', H1, 'const PID_FILE = join(STATE_DIR, "bot.pid")'),
        ('H2', 'mode: 0o700 })\ntry {', 'mode: 0o750 })\ntry {'),
        ('H3', "10) === process.pid) rmSync(PID_FILE)", "10) == process.pid) rmSync(PID_FILE)"),
        ('H4', 'void (async () => {', 'void (async function () {'),
    ]

    for name, old, new in mutations:
        case = f'7-atomossag-{name}'

        if old not in POLLER_PRISTINE:
            fail(case, f'a mutacio alapja nincs meg a fixture-ben: {old!r}')
            continue

        broken = POLLER_PRISTINE.replace(old, new, 1)
        patched, changed, warnings = guard.patch_content(broken)
        check(case, not changed, f'{name} horgony nelkul semmit nem szabad valtoztatni')
        check(case, patched == broken, f'{name} horgony nelkul bajtazonos kell maradjon')
        check(case, bool(poller_warnings(warnings)),
              f'{name} horgony hianyaban poller-figyelmeztetes kell (kapott: {warnings})')

        # A legfontosabb: egyik BESZURT reszlet sem szivaroghat at.
        leaked = [f for f in EXPECTED_FRAGMENTS if f in patched]
        check(case, not leaked, f'{name} horgony nelkul nem szivaroghat be reszlet (kapott: {leaked})')

        # FUGGETLENSEG: a torott poller-horgony a MASIK (reply_to) patch-et NEM
        # akadalyozhatja -- kulonben egy plugin-frissites az egyik javitas
        # elvesztesevel a masikat is magaval rantana.
        mixed_broken = REPLY_TO_PRISTINE + '\n' + broken
        mixed_patched, mixed_changed, _ = guard.patch_content(mixed_broken)
        check(case, mixed_changed, f'{name} torotten is alkalmazodnia kell a reply_to patch-nek')
        check(case, guard.MARKER_CODE in mixed_patched,
              f'{name} torotten is jelen kell legyen a reply_to kod-marker')
        mixed_leaked = [f for f in EXPECTED_FRAGMENTS if f in mixed_patched]
        check(case, not mixed_leaked,
              f'{name} torotten nem szivaroghat be poller-reszlet (kapott: {mixed_leaked})')


def test_brace_balance(patched):
    case = '8-zarojel-merleg'
    added_open = patched.count('{') - POLLER_PRISTINE.count('{')
    added_close = patched.count('}') - POLLER_PRISTINE.count('}')
    check(case, added_open == added_close,
          f'a beszurt blokkok kapcsos zarojelei kiegyenlitettek ({added_open} nyito, {added_close} zaro)')

    added_paren_open = patched.count('(') - POLLER_PRISTINE.count('(')
    added_paren_close = patched.count(')') - POLLER_PRISTINE.count(')')
    check(case, added_paren_open == added_paren_close,
          f'a beszurt blokkok kerek zarojelei kiegyenlitettek '
          f'({added_paren_open} nyito, {added_paren_close} zaro)')


def test_mixed():
    """A poller-patch es a meglevo reply_to patch EGYUTT is alkalmazhato."""
    case = '9-vegyes'
    combined = REPLY_TO_PRISTINE + '\n' + POLLER_PRISTINE
    patched, changed, warnings = guard.patch_content(combined)
    check(case, changed, 'a vegyes tartalomnak valtoznia kell')
    check(case, not warnings, f'nem lehet figyelmeztetes (kapott: {warnings})')
    check(case, guard.MARKER_DOC in patched, 'a reply_to doc-marker jelen kell legyen')
    check(case, guard.MARKER_CODE in patched, 'a reply_to kod-marker jelen kell legyen')
    check(case, MARKER_POLLER in patched, 'a poller-marker jelen kell legyen')

    patched2, changed2, _ = guard.patch_content(patched)
    check(case, not changed2, 'vegyes tartalom: a masodik futas nem valtoztathat')
    check(case, patched2 == patched, 'vegyes tartalom: a masodik futas bajtazonos')


def main():
    patched = test_pristine_patchable()
    test_idempotent(patched)
    test_atomicity()
    test_brace_balance(patched)
    test_mixed()

    print()

    if FAILURES:
        print(f'BUKAS: {len(FAILURES)} allitas nem teljesult')
        for f_ in FAILURES:
            print(f'  - {f_}')
        return 1

    print('All telegram-plugin-patch-guard poller tests passed.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
