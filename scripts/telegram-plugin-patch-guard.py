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
    assert not warnings, f'varatlan figyelmeztetes: {warnings}'
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

    print('\nAll telegram-plugin-patch-guard self-tests passed.')
    return 0


if __name__ == '__main__':
    if '--self-test' in sys.argv:
        sys.exit(self_test())
    sys.exit(run(dry_run='--dry-run' in sys.argv))
