#!/usr/bin/env python3
"""Guarantees the reply_to_message_id patch on the installed Telegram plugin.

MIERT KELL: a claude-plugins-official Telegram plugin hivatalos verzioja NEM
adja at a reply_to_message_id-t (melyik uzenetre valaszolt a kuldo) a channel
tag meta-mezoiben -- a PR (#5559), ami ezt javitotta volna, az upstream
repoban le lett zarva ("csak Anthropic-tagtol fogad el"). A javitas ezert
helyi fajl-patch, es KIZAROLAG addig el, amig valaki (vagy egy plugin-
frissites) vissza nem irja a pristine allapotot.

MIT TALALTUNK (2026-08-21): a Telegram plugin server.ts-e MINDEN egyes
Marveen-fej (marveen + 10 sub-agent) izolalt CLAUDE_CONFIG_DIR-jaban
UGYANAZ a fajl -- egyetlen inode-ra hardlinkelve. Ez azt jelenti, hogy EGY
fajl (a "cache" masolat) patch-elese MINDEN fejnel azonnal elesedik, ujabb
fejenkenti lepes nelkul. A MARKETPLACE-forras (external_plugins/telegram/
server.ts) viszont KULON inode, es SOSEM lett patch-elve -- ha valami (uj
fej onboardolasa, cache-torles, marketplace update) ujra masolna a cache-t a
forrasbol, a friss masolat patch nelkul erkezne.

EZERT MINDKET HELYET ellenorzi ez a script, es a Claude Code telepites
osszes fellelheto telegram/server.ts peldanyat -- dedupelve inode szerint,
hogy ne irjunk feleslegesen ugyanabba a fajlba tobbszor.

Idempotens: ha a jelolo string mar jelen van, nem nyul semmihez. Biztonsagos:
csak akkor irja at a fajlt, ha a HORGONY-szoveg (a patch beszurasi pontja)
SZO SZERINT megtalalhato -- ha nem (mert a plugin egy ujabb verzioja
atirta a korulotte allo kodot), FIGYELMEZTETVE kilep, nem talalgat es nem
ront el semmit.

Hasznalat:
  python3 scripts/telegram-plugin-patch-guard.py            # normal futas
  python3 scripts/telegram-plugin-patch-guard.py --dry-run  # csak jelentes, nem ir
  python3 scripts/telegram-plugin-patch-guard.py --self-test
"""
import os
import sys
import glob

MARKER_DOC = 'plus reply_to_message_id="..."'
MARKER_CODE = 'reply_to_message_id: String(replyToMessageId)'

# A HELYES tartalom -- a TENYLEGESEN elesben futo, mukodo 0.0.7 cache-bol
# szo szerint kiolvasva (nem kezzel begepelve). EZ SZAMIT, MERT AZ ELSO
# VALTOZAT EGY VALODI HIBAT TARTALMAZOTT (2026-08-21, sajat mero): a
# DOC_REPLACEMENT-ben egy escapelatlan aposztrof ("Telegram's") allt egy
# EGYES-idezojeles JS string-literal belsejeben -- ez korai string-lezarast,
# tehat SZINTAKTIKAI HIBAT okozott volna a celfajlban. A sajat self-test
# NEM fogta meg (szintaktikailag "helyesen" ellenorizte a SAJAT hibas
# stringjet onmagahoz kepest) -- csak a VALODI, mar patch-elt fajllal
# osszevetve derult ki. A JS-ben az aposztrofot ITT escapelni KELL:
# "Telegram\'s" (backslash + aposztrof), mert a korulotte allo string
# egyes idezojelekkel nyilik.
DOC_ANCHOR = 'ts="...">. If the tag has an image_path attribute'
DOC_REPLACEMENT = (
    'ts="...">, plus reply_to_message_id="..." when the sender used '
    'Telegram' + chr(92) + "'s reply-to-message feature (its value is the message_id of "
    'the message they replied to). If the tag has an image_path attribute'
)

CODE_CONST_ANCHOR = 'const imagePath = downloadImage ? await downloadImage() : undefined'
CODE_CONST_INSERT = (
    CODE_CONST_ANCHOR
    + '\n  const replyToMessageId = ctx.message?.reply_to_message?.message_id'
)

CODE_META_ANCHOR = '...(msgId != null ? { message_id: String(msgId) } : {}),'
CODE_META_COMMENT = (
    "// Telegram's own reply-quote — which prior message (by message_id)\n"
    '        // this one is a reply to, if any. Without this, a reply and a plain\n'
    '        // message are indistinguishable to the model: it can see that this\n'
    "        // message exists, but not what it's a reply to.\n"
)
CODE_META_INSERT = (
    CODE_META_ANCHOR
    + '\n        ' + CODE_META_COMMENT.rstrip('\n')
    + '\n        ...(replyToMessageId != null ? { reply_to_message_id: String(replyToMessageId) } : {}),'
)

# ---------------------------------------------------------------------------
# POLLER-SLOT OR (A1 tulajdonos-kotott stale-kill + A2 poller-gate)
#
# MIERT: egy bot-tokenre a Telegram EGY getUpdates-fogyasztot enged. A
# nem-csatorna sessionok (Task-subagens, ad-hoc terminal) MCP-szervere
# TELEGRAM_STATE_DIR nelkul a ~/.claude/channels/telegram symlinken at UGYANARRA
# a FO ELES allapot-konyvtarra oldodik fel, kiolvassa a bot.pid-et, SIGTERM-mel
# elveszi a slotot -- majd a sajat Claude Code-ja eldobja a bejovo ertesitest
# ("not in --channels list"). A fo csatorna megnemul, a dashboard 60-240s
# helyreallito kaszkadot futtat.
#
# MIND-VAGY-SEMMI: a negy horgony EGYMASRA epul (a CHANNEL_SESSION konstanst a
# H1 vezeti be, a H2 es a H4 hasznalja). Egy fel-alkalmazott patch nem "reszben
# jo", hanem SZINTAKTIKAILAG TOROTT server.ts -- ezert eloszor MIND A NEGY
# horgonyt ellenorizzuk, es hianynal EGYIKET SEM alkalmazzuk.
# ---------------------------------------------------------------------------
MARKER_POLLER = 'MARVEEN-PATCH: poller-slot guard'

# H1 -- a szulo-lanc merese es a bot.owner jelolo utjanak bevezetese.
POLLER_H1_ANCHOR = "const PID_FILE = join(STATE_DIR, 'bot.pid')"
POLLER_H1_INSERT = POLLER_H1_ANCHOR + r"""
const OWNER_FILE = join(STATE_DIR, 'bot.owner')

// MARVEEN-PATCH: poller-slot guard
// Egy bot-tokenre a Telegram EGY getUpdates-fogyasztót enged. A nem-csatorna
// sessionök (Task-subagens, ad-hoc terminál) MCP-szervere ugyanezt az
// állapot-könyvtárat oldja fel, elveszi a slotot, majd a saját Claude Code-ja
// eldobja a bejövő értesítést ("not in --channels list") -- a fő csatorna
// megnémul. Ezért a szülő-láncban megkeressük az ELSŐ claude processzt, és
// csak akkor pollozunk, ha annak a parancssorában ott a '--channels'.
// Mérve ezen a gépen: a lánc bun server.ts -> 'bun run' wrapper -> claude,
// tehát a közvetlen szülő nem elég. A parancssorában 'claude'-ot tartalmazó
// bash-wrapper NEM claude, ezért az argv[0] bázisneve dönt.
// FAIL-OPEN: ha a lánc nem mérhető (ps hiba, üres sor, nincs claude a
// láncban), null-t adunk, és pollozunk -- egy téves "ne pollozz" a fő
// csatornát némítaná el, egy téves "pollozz" legrosszabb esetben 409
// Conflict, amit a lenti retry-hurok kezel.
function findChannelSessionFlag(): boolean | null {
  let pid = process.ppid
  for (let step = 0; step < 16 && pid > 1; step++) {
    let line: string
    try {
      line = execFileSync('ps', ['-o', 'ppid=,command=', '-p', String(pid)],
        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
    } catch { return null }
    const m = line.match(/^\s*(\d+)\s+([\s\S]*)$/)
    if (!m) return null
    const parent = parseInt(m[1], 10)
    const command = m[2]
    const argv0 = command.split(' ')[0]
    if (argv0 === 'claude' || argv0.endsWith('/claude')) return command.includes('--channels')
    if (!Number.isFinite(parent) || parent <= 1) break
    pid = parent
  }
  return null
}
const CHANNEL_SESSION = findChannelSessionFlag()"""

# H2 -- a TELJES stale-kill blokk. SZANDEKOSAN nagy, szo szerinti horgony: ez a
# KILOVO ut, es ha egy plugin-frissites barmit modosit rajta, a patch-oro alljon
# meg es kerjen emberi felulvizsgalatot, ne probaljon reszlegesen illeszteni.
# (A `mkdirSync(STATE_DIR, ...)` sor egyebkent ketszer szerepel a fajlban, tehat
# kis horgonykent nem is lenne egyedi.)
POLLER_H2_ANCHOR = r"""mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 })
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
      process.stderr.write(`telegram channel: replacing stale poller pid=${stale}\n`)
      process.kill(stale, 'SIGTERM')
    }
  }
} catch {}
writeFileSync(PID_FILE, String(process.pid))"""

POLLER_H2_INSERT = r"""mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 })
let stateDirId: string
try { stateDirId = realpathSync(STATE_DIR) } catch { stateDirId = STATE_DIR }
if (CHANNEL_SESSION === false) {
  // Nem-csatorna session: a bot.pid-hez hozzá sem nyúlunk -- se olvasás-kilövés,
  // se írás. Így a bot.pid a VALÓDI poller azonosítója marad, és nem egy siket,
  // mégis élő PID mutat "egészséges" csatornát a watchdognak.
  process.stderr.write(
    'telegram channel: not a --channels session — poller slot left untouched (bot.pid not read, not written)\n',
  )
} else {
  try {
    const stale = parseInt(readFileSync(PID_FILE, 'utf8'), 10)
    if (stale > 1 && stale !== process.pid) {
      process.kill(stale, 0)
      // PID files race with OS PID recycling — verify the holder is actually a
      // server.ts process before SIGTERM. Otherwise a recycled PID can point at
      // our own bun-run wrapper (kills our stdin → immediate self-shutdown) or
      // an unrelated user process.
      const cmd = execFileSync('ps', ['-p', String(stale), '-o', 'args='], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })
      // TULAJDONOS-KÖTÖTT KILÖVÉS (fail-closed): a bot.owner a FELOLDOTT
      // állapot-könyvtár útja. Hiányzó jelölő = a patch előtti poller -- azt
      // visszafelé kompatibilisen a miénknek vesszük, különben a bevezetés
      // pillanatában árva pollert hagynánk a fő csatornán.
      let staleOwner: string | null = null
      try { staleOwner = readFileSync(OWNER_FILE, 'utf8').trim() || null } catch {}
      if (staleOwner !== null && staleOwner !== stateDirId) {
        process.stderr.write(
          `telegram channel: stale poller pid=${stale} is owned by ${staleOwner}, not ${stateDirId} — leaving it alone\n`,
        )
      } else if (cmd.includes('server.ts')) {
        process.stderr.write(`telegram channel: replacing stale poller pid=${stale}\n`)
        process.kill(stale, 'SIGTERM')
      }
    }
  } catch {}
  writeFileSync(PID_FILE, String(process.pid))
  writeFileSync(OWNER_FILE, stateDirId)
}"""

# H3 -- a leallaskori takaritas: a jelolo a PID-del EGYUTT el.
POLLER_H3_ANCHOR = (
    "    if (parseInt(readFileSync(PID_FILE, 'utf8'), 10) === process.pid) rmSync(PID_FILE)"
)
POLLER_H3_INSERT = r"""    if (parseInt(readFileSync(PID_FILE, 'utf8'), 10) === process.pid) {
      // A jelölő a PID-del EGYÜTT él. ELŐSZÖR a jelölő: ha az egyik törlés
      // elbukik, a maradék állapot a mai (jelölő nélküli) viselkedés felé
      // essen, ne egy idegen jelölő felé, ami tartósan blokkolná a slotot.
      try { rmSync(OWNER_FILE) } catch {}
      rmSync(PID_FILE)
    }"""

# H4 -- a polling-kapu. A kimeno toolok es az mcp.connect VALTOZATLANOK: a
# valasz-kuldes HTTP-n megy, nem a polling-slotbol.
POLLER_H4_ANCHOR = 'void (async () => {\n  for (let attempt = 1; ; attempt++) {'
POLLER_H4_INSERT = r"""if (CHANNEL_SESSION === false) {
  // Ez a sor mondja meg, miért néma ez a szerver. A kimenő toolok és az
  // mcp.connect VÁLTOZATLANUL működnek -- a válasz-küldés HTTP-n megy, nem a
  // polling-slotból.
  process.stderr.write(
    'telegram channel: no --channels claude in the parent process chain — polling disabled (outbound tools still work)\n',
  )
} else void (async () => {
  for (let attempt = 1; ; attempt++) {"""

POLLER_PATCHES = (
    ('H1', POLLER_H1_ANCHOR, POLLER_H1_INSERT),
    ('H2', POLLER_H2_ANCHOR, POLLER_H2_INSERT),
    ('H3', POLLER_H3_ANCHOR, POLLER_H3_INSERT),
    ('H4', POLLER_H4_ANCHOR, POLLER_H4_INSERT),
)


def candidate_paths():
    home = os.path.expanduser('~')
    patterns = [
        os.path.join(home, '.claude', 'plugins', 'marketplaces', 'claude-plugins-official',
                     'external_plugins', 'telegram', 'server.ts'),
        os.path.join(home, '.claude', 'plugins', 'cache', 'claude-plugins-official',
                     'telegram', '*', 'server.ts'),
    ]
    paths = []
    for pat in patterns:
        if '*' in pat:
            paths.extend(sorted(glob.glob(pat)))
        elif os.path.exists(pat):
            paths.append(pat)
    return paths


def dedupe_by_inode(paths):
    """Egy peldany minden egyedi inode-hoz -- a hardlinkelt masolatok
    ujra-irasa felesleges IO, es ha egyet patch-elunk, a tobbi (ugyanaz a
    fajl) magatol kesz."""
    seen = {}
    result = []
    for p in paths:
        try:
            ino = os.stat(p).st_ino
        except OSError:
            continue
        if ino in seen:
            continue
        seen[ino] = p
        result.append(p)
    return result


def patch_content(content):
    """Visszaadja: (uj_tartalom, valtozott_e, figyelmeztetesek)."""
    warnings = []
    changed = False

    if MARKER_DOC not in content:
        if DOC_ANCHOR in content:
            content = content.replace(DOC_ANCHOR, DOC_REPLACEMENT, 1)
            changed = True
        else:
            warnings.append('doc-anchor nem talalhato -- a leiro szoveg patch-e kimaradt')

    if MARKER_CODE not in content:
        if CODE_CONST_ANCHOR not in content:
            warnings.append('code-const-anchor nem talalhato -- a kod-patch kimaradt')
        elif CODE_META_ANCHOR not in content:
            warnings.append('code-meta-anchor nem talalhato -- a kod-patch kimaradt')
        else:
            content = content.replace(CODE_CONST_ANCHOR, CODE_CONST_INSERT, 1)
            content = content.replace(CODE_META_ANCHOR, CODE_META_INSERT, 1)
            changed = True

    # POLLER-SLOT OR -- MIND-VAGY-SEMMI. A negy beszuras egymasra epul, ezert
    # eloszor MINDET ellenorizzuk, es csak hianytalan horgony-keszlet eseten
    # irunk. Fel-alkalmazva szintaktikailag torott server.ts maradna a lemezen.
    if MARKER_POLLER not in content:
        missing = [name for name, anchor, _ in POLLER_PATCHES if anchor not in content]

        if missing:
            warnings.append(
                'poller-horgony nem talalhato (' + ', '.join(missing) + ') -- a '
                'poller-slot patch MIND-VAGY-SEMMI szabaly szerint TELJESEN kimaradt'
            )
        else:
            for _, anchor, insert in POLLER_PATCHES:
                content = content.replace(anchor, insert, 1)

            changed = True

    return content, changed, warnings


def run(dry_run=False):
    paths = dedupe_by_inode(candidate_paths())
    if not paths:
        print('telegram-plugin-patch-guard: nincs telepitett telegram-plugin server.ts -- nincs teendo.')
        return 0

    total_patched = 0
    total_warned = 0
    for path in paths:
        with open(path, 'r', encoding='utf-8') as f:
            original = f.read()
        new_content, changed, warnings = patch_content(original)
        for w in warnings:
            print(f'telegram-plugin-patch-guard: FIGYELMEZTETES {path}: {w}', file=sys.stderr)
            total_warned += 1
        if changed:
            if dry_run:
                print(f'telegram-plugin-patch-guard: [dry-run] patch-elne: {path}')
            else:
                tmp = path + '.patchguard-tmp'
                with open(tmp, 'w', encoding='utf-8') as f:
                    f.write(new_content)
                os.replace(tmp, path)
                print(f'telegram-plugin-patch-guard: patch-elve: {path}')
            total_patched += 1

    if total_patched == 0 and total_warned == 0:
        print(f'telegram-plugin-patch-guard: {len(paths)} peldany, mind patch-elt -- nincs teendo.')
    return 1 if total_warned > 0 else 0


def self_test():
    # 1. Pristine tartalom -> patch-elheto, MINDKET marker megjelenik utana.
    pristine = (
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
    patched, changed, warnings = patch_content(pristine)
    assert changed, 'pristine tartalomnak valtoznia kellett volna'
    # Ez a fixture SZANDEKOSAN csak a reply_to-regiokat tartalmazza, ezert a
    # poller-horgonyok hianya VART figyelmeztetes -- a ket patch fuggetlen.
    reply_warnings = [w for w in warnings if 'poller' not in w]
    assert not reply_warnings, f'varatlan figyelmeztetes: {reply_warnings}'
    assert MARKER_DOC in patched, 'a leiro-marker hianyzik patch utan'
    assert MARKER_CODE in patched, 'a kod-marker hianyzik patch utan'
    print('[PASS] pristine -> patched, mindket marker jelen')

    # 1/b. REGRESSZIO-VEDELEM (a sajat elso valtozat hibaja, 2026-08-21):
    # a DOC_REPLACEMENT-be escapelatlan aposztrof kerult egy egyes-idezojeles
    # JS string-literal belsejebe -- szintaktikailag torott celfajlt eredmenyezett
    # volna. A self-test EREDETILEG nem fogta meg, mert onmagahoz kepest
    # ellenorzott. Ez a check kifejezetten a "\\'" alakot koveteli.
    escaped = 'Telegram' + chr(92) + "'s reply-to-message"
    unescaped_bare = 'Telegram' + "'s reply-to-message"
    assert escaped in patched, 'a Telegram utani aposztrofnak escapelve kell lennie (\\\')'
    assert unescaped_bare not in patched, (
        'escapelatlan aposztrof a JS string-literalban -- szintaktikai hiba'
    )
    print('[PASS] aposztrof-escapeles helyes (regresszio-vedelem)')

    # 2. Mar patch-elt tartalom -> IDEMPOTENS, nem valtozik ujra.
    patched2, changed2, warnings2 = patch_content(patched)
    assert not changed2, 'mar patch-elt tartalmat nem szabad ujra modositani'
    assert patched2 == patched, 'idempotens futasnak byte-azonosnak kell maradnia'
    print('[PASS] patched -> idempotens, nincs valtozas')

    # 3. Idegen (horgony nelkuli) tartalom -> NEM nyul hozza, csak figyelmeztet.
    foreign = 'valami egeszen mas kod, nincs benne egyik horgony sem\n'
    patched3, changed3, warnings3 = patch_content(foreign)
    assert not changed3, 'horgony nelkuli tartalmat nem szabad modositani'
    assert patched3 == foreign, 'horgony nelkuli tartalom byte-azonos kell maradjon'
    assert warnings3, 'horgony hianyaban figyelmeztetes kell'
    print('[PASS] idegen tartalom: erintetlen + figyelmeztetes')

    # 4. POLLER-SLOT OR -- fust-teszt. A TELJES matrix (idempotencia, negy
    # kulon horgony-hiany, zarojel-merleg, vegyes eset) a dedikalt tesztben all:
    # scripts/__tests__/telegram-plugin-patch-guard-poller.test.py, es a
    # VISELKEDEST (a patch-elt fajl tenyleges inditasat) a
    # scripts/__tests__/telegram-poller-slot-guard.test.py meri.
    poller_pristine = (
        POLLER_H1_ANCHOR + '\n\n'
        + POLLER_H2_ANCHOR + '\n\n'
        + POLLER_H3_ANCHOR + '\n\n'
        + POLLER_H4_ANCHOR + '\n'
    )
    p4, changed4, warn4 = patch_content(poller_pristine)
    poller_warn4 = [w for w in warn4 if 'poller' in w]
    assert changed4, 'a poller-fixture-nek valtoznia kellett volna'
    assert not poller_warn4, f'varatlan poller-figyelmeztetes: {poller_warn4}'
    assert MARKER_POLLER in p4, 'a poller-marker hianyzik patch utan'

    for frag in ("const OWNER_FILE = join(STATE_DIR, 'bot.owner')",
                 'const CHANNEL_SESSION = findChannelSessionFlag()',
                 'leaving it alone', 'poller slot left untouched',
                 'polling disabled', 'rmSync(OWNER_FILE)'):
        assert frag in p4, f'hianyzo beszurt reszlet: {frag!r}'

    print('[PASS] poller-fixture -> patched, mind a negy beszuras jelen')

    p5, changed5, _ = patch_content(p4)
    assert not changed5, 'a poller-patch nem idempotens'
    assert p5 == p4, 'a poller-patch masodik futasa nem bajtazonos'
    print('[PASS] poller-patch -> idempotens')

    # MIND-VAGY-SEMMI: egyetlen hianyzo horgony az EGESZ poller-patch-et
    # visszatartja -- fel-alkalmazva torott TypeScript maradna a lemezen.
    broken = poller_pristine.replace('void (async () => {', 'void (async function () {', 1)
    p6, changed6, warn6 = patch_content(broken)
    assert not changed6, 'hianyzo H4 horgony mellett SEMMIT nem szabad irni'
    assert p6 == broken, 'hianyzo horgony eseten a tartalom bajtazonos kell maradjon'
    assert [w for w in warn6 if 'poller' in w], 'hianyzo poller-horgonynal figyelmeztetes kell'
    assert MARKER_POLLER not in p6, 'hianyzo horgony mellett a marker sem szivaroghat be'
    print('[PASS] poller-patch: mind-vagy-semmi (hianyzo horgony -> nincs iras)')

    print('\nAll telegram-plugin-patch-guard self-tests passed.')
    return 0


if __name__ == '__main__':
    if '--self-test' in sys.argv:
        sys.exit(self_test())
    sys.exit(run(dry_run='--dry-run' in sys.argv))
