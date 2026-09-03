#!/usr/bin/env python3
"""VISELKEDESI teszt a telepitett Telegram-plugin server.ts poller-slot orere.

MIT MER: a TELEPITETT (patch-elt) server.ts-t TENYLEGESEN elinditja `bun`-nal,
ideiglenes allapot-konyvtarral es sajat, artalmatlan alany-processzel, majd a
szerver INDULASKORI viselkedeset (stderr-sorok, SIGTERM, bot.pid) allitja.
Nem forras-szoveget grep-el: egy szintaktikailag torott patch itt azonnal
pirosat ad.

MIERT: egy bot-tokenre a Telegram EGY getUpdates-fogyasztot enged. A
nem-csatorna sessionok (Task-subagens, ad-hoc terminal) MCP-szervere UGYANAZT
az allapot-konyvtarat oldja fel (TELEGRAM_STATE_DIR nelkul a ~/.claude/channels/
telegram symlinken at), elveszi a slotot a bot.pid-bol kiolvasott poller
SIGTERM-elesevel, majd a sajat Claude Code-ja eldobja a bejovo ertesitest
("not in --channels list") -- a fo csatorna megnemul.

BIZTONSAG (nem opcionalis):
  * a teszt SOHA nem hasznalja az eles allapot-konyvtarat -- ha a feloldott
    ideiglenes ut a ~/.claude/channels ala esne, azonnal leall;
  * a gyermek kornyezetebol torli a TELEGRAM_BOT_TOKEN-t (a tmp .env-ben
    hamis token all), tehat az eles bot tokenjet sosem latja;
  * futas elott es utan visszaolvassa az eles bot.pid-et, es allitja, hogy
    valtozatlan (csak olvasas).

Futtatas:
  python3 /Users/ceo/Marveen/scripts/__tests__/telegram-poller-slot-guard.test.py
"""
import glob
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HOME = os.path.expanduser('~')
BUN = os.path.join(HOME, '.bun', 'bin', 'bun')
LIVE_CHANNELS_DIR = os.path.join(HOME, '.claude', 'channels')
LIVE_PID_FILE = os.path.join(LIVE_CHANNELS_DIR, 'telegram', 'bot.pid')

# Hamis token: formailag helyes alaku, de nem letezo bot -- a Telegram 401-gyel
# valaszol, a teszt allitasai viszont INDULASKORI sorokra vonatkoznak, ezert
# halozat nelkul is helyesen dontenek.
FAKE_TOKEN = '123456789:FAKE-TOKEN-FOR-LOCAL-TEST-DO-NOT-USE'

# Az indulas "tulhaladt a poller-donteseken" jelei. Barmelyik megjelenese utan
# a szerver mar tulment a stale-kill blokkon ES a polling-inditasi ponton is.
DONE_MARKERS = (
    'polling error',
    'polling disabled',
    'polling as @',
    '409 Conflict',
)

STARTUP_TIMEOUT_S = 20.0
GRACE_S = 0.6

FAILURES = []
# A letrehozott ideiglenes allapot-konyvtarak -- zold futasnal takaritjuk.
STATE_DIRS = []


def fail(case, msg):
    FAILURES.append(f'{case}: {msg}')
    print(f'[FAIL] {case}: {msg}')


def ok(case, msg):
    print(f'[PASS] {case}: {msg}')


def plugin_dir():
    """A telepitett plugin-peldany konyvtara (a legfrissebb verzio)."""
    hits = sorted(glob.glob(os.path.join(
        HOME, '.claude', 'plugins', 'cache', 'claude-plugins-official',
        'telegram', '*', 'server.ts')))

    if not hits:
        print('telegram-poller-slot-guard: nincs telepitett telegram-plugin server.ts',
              file=sys.stderr)
        sys.exit(2)

    return os.path.dirname(hits[-1])


def read_live_pid():
    try:
        with open(LIVE_PID_FILE, 'r', encoding='utf-8') as f:
            return f.read()
    except OSError:
        return None


def make_state_dir():
    d = tempfile.mkdtemp(prefix='telegram-poller-slot-guard-')
    STATE_DIRS.append(d)
    real = os.path.realpath(d)
    live_real = os.path.realpath(LIVE_CHANNELS_DIR)

    # Fail-closed: az eles allapot-konyvtar kozeleben SEMMIT nem inditunk.
    if real == live_real or real.startswith(live_real + os.sep):
        print(f'telegram-poller-slot-guard: BIZTONSAGI LEALLAS -- a tmp allapot-konyvtar '
              f'({real}) az eles csatorna-fa ({live_real}) alatt van', file=sys.stderr)
        sys.exit(2)

    env_file = os.path.join(d, '.env')

    with open(env_file, 'w', encoding='utf-8') as f:
        f.write(f'TELEGRAM_BOT_TOKEN={FAKE_TOKEN}\n')

    os.chmod(env_file, 0o600)

    fakebin = os.path.join(d, 'fakebin')
    os.makedirs(fakebin)
    # A szulo-lanc felismerese az argv[0] bazisnevere epul -- ezert symlink,
    # nem shebanges szkript (az utobbinal az argv[0] az ertelmezo lenne).
    os.symlink('/bin/sh', os.path.join(fakebin, 'claude'))
    return d


def start_subject(state_dir):
    """Artalmatlan alany-processz, aminek a PARANCSSORABAN ott a 'server.ts'
    szo -- ezert a mai `cmd.includes('server.ts')` ellenorzes atengedi. A
    SIGTERM-et fajl-jelolovel nyugtazza, majd kilep."""
    marker = os.path.join(state_dir, 'SIGTERM-ERKEZETT')
    script = (f'trap "touch {marker}; exit 0" TERM; while :; do sleep 0.2; done')
    proc = subprocess.Popen(
        ['/bin/bash', '-c', script, 'fake-server.ts-subject'],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    return proc, marker


def child_env(state_dir):
    env = dict(os.environ)
    # Az eles token SOSEM kerulhet a gyermekbe.
    env.pop('TELEGRAM_BOT_TOKEN', None)
    env.pop('CLAUDE_CONFIG_DIR', None)
    env['TELEGRAM_STATE_DIR'] = state_dir
    return env


def start_server(state_dir, parent_mode, err_path):
    """Elinditja a valodi server.ts-t a kert szulo-lanccal.

    parent_mode:
      'channels'    -- kozvetlen szulo a hamis claude, '--channels' flaggel
      'no-channels' -- kozvetlen szulo a hamis claude, flag NELKUL
      'detached'    -- dupla-fork, ppid=1 (a lancban NINCS claude)
    """
    fake_claude = os.path.join(state_dir, 'fakebin', 'claude')
    errf = open(err_path, 'w+', encoding='utf-8')
    env = child_env(state_dir)
    pid_path = os.path.join(state_dir, 'server-under-test.pid')

    if parent_mode == 'detached':
        # A hattersitett lista stdin-je alapbol /dev/null lenne (POSIX), ezert
        # fd3-on atmentjuk a pipe-ot, es a gyermekben visszaallitjuk -- kulonben
        # a szerver azonnal 'shutting down'-ol a stdin EOF-jatol.
        script = (
            'exec 3<&0\n'
            f'{{ exec 0<&3; exec {BUN} server.ts ; }} &\n'
            f'echo $! > "{pid_path}"\n'
            'exit 0\n'
        )
        proc = subprocess.Popen(
            ['/bin/bash', '-c', script], cwd=plugin_dir(), env=env,
            stdin=subprocess.PIPE, stdout=errf, stderr=errf, start_new_session=True,
        )
        return proc, errf, pid_path

    argv = [fake_claude, '-c', f'{BUN} server.ts; :', 'claude-fake']

    if parent_mode == 'channels':
        argv += ['--channels', 'plugin:telegram@claude-plugins-official']

    proc = subprocess.Popen(
        argv, cwd=plugin_dir(), env=env,
        stdin=subprocess.PIPE, stdout=errf, stderr=errf, start_new_session=True,
    )
    return proc, errf, None


def wait_for_startup(err_path):
    deadline = time.time() + STARTUP_TIMEOUT_S

    while time.time() < deadline:
        try:
            with open(err_path, 'r', encoding='utf-8', errors='replace') as f:
                text = f.read()
        except OSError:
            text = ''

        if any(m in text for m in DONE_MARKERS):
            return True

        time.sleep(0.2)

    return False


def kill_tree(proc, pid_path):
    """Csak a SAJAT, uj sessionbe inditott csoportot bantjuk."""
    try:
        proc.stdin.close()
    except Exception:
        pass

    if pid_path and os.path.exists(pid_path):
        try:
            with open(pid_path, 'r', encoding='utf-8') as f:
                pid = int(f.read().strip())

            if pid > 1:
                os.kill(pid, signal.SIGKILL)
        except Exception:
            pass

    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except Exception:
        pass

    try:
        proc.wait(timeout=5)
    except Exception:
        pass


def scenario(name, owner, parent_mode):
    """Lefuttat egy esetet, es visszaadja a mert tenyeket."""
    state_dir = make_state_dir()
    subject, marker = start_subject(state_dir)
    pid_file = os.path.join(state_dir, 'bot.pid')

    with open(pid_file, 'w', encoding='utf-8') as f:
        f.write(str(subject.pid))

    if owner is not None:
        resolved_owner = os.path.realpath(state_dir) if owner == '@self' else owner

        with open(os.path.join(state_dir, 'bot.owner'), 'w', encoding='utf-8') as f:
            f.write(resolved_owner)

    err_path = os.path.join(state_dir, 'server.err')
    proc, errf, pid_path = start_server(state_dir, parent_mode, err_path)
    reached = wait_for_startup(err_path)
    time.sleep(GRACE_S)

    with open(err_path, 'r', encoding='utf-8', errors='replace') as f:
        stderr_text = f.read()

    sigterm = os.path.exists(marker)
    subject_alive = subject.poll() is None

    try:
        with open(pid_file, 'r', encoding='utf-8') as f:
            pid_file_text = f.read()
    except OSError:
        pid_file_text = None

    kill_tree(proc, pid_path)

    try:
        errf.close()
    except Exception:
        pass

    try:
        os.killpg(os.getpgid(subject.pid), signal.SIGKILL)
    except Exception:
        pass

    try:
        subject.wait(timeout=5)
    except Exception:
        pass

    return {
        'name': name,
        'state_dir': state_dir,
        'subject_pid': subject.pid,
        'stderr': stderr_text,
        'sigterm': sigterm,
        'subject_alive': subject_alive,
        'pid_file_text': pid_file_text,
        'reached_startup': reached,
    }


def check_reached(r):
    if not r['reached_startup']:
        fail(r['name'], 'a szerver nem jutott el az indulasi dontesekig '
                        f'({STARTUP_TIMEOUT_S:.0f}s alatt) -- stderr:\n{r["stderr"]}')
        return False

    return True


def main():
    live_before = read_live_pid()

    print('=== 1) A1: tulajdonos-eltero stale poller (bot.owner idegen, szulo --channels) ===')
    r = scenario('A1-tulajdonos-eltero', '/egy/egeszen/mas/allapot-konyvtar', 'channels')
    print(r['stderr'].rstrip() or '(ures stderr)')

    if check_reached(r):
        if r['sigterm']:
            fail(r['name'], 'idegen tulajdonosu poller SIGTERM-et kapott (nem lett volna szabad)')
        else:
            ok(r['name'], 'nincs SIGTERM')

        if not r['subject_alive']:
            fail(r['name'], 'az alany-processz meghalt (kilottek)')
        else:
            ok(r['name'], 'az alany el')

        if 'leaving it alone' not in r['stderr']:
            fail(r['name'], "hianyzik a 'leaving it alone' indoklas a stderr-bol")
        else:
            ok(r['name'], "stderr indokol ('leaving it alone')")

    print()
    print('=== 2) A2: nem-csatorna session (nincs bot.owner, szulo --channels NELKUL) ===')
    r = scenario('A2-nem-csatorna', None, 'no-channels')
    print(r['stderr'].rstrip() or '(ures stderr)')

    if check_reached(r):
        if r['sigterm']:
            fail(r['name'], 'nem-csatorna session SIGTERM-et kuldott a pollernek')
        else:
            ok(r['name'], 'nincs SIGTERM')

        if not r['subject_alive']:
            fail(r['name'], 'az alany-processz meghalt (kilottek)')
        else:
            ok(r['name'], 'az alany el')

        if r['pid_file_text'] != str(r['subject_pid']):
            fail(r['name'], f'a bot.pid felul lett irva: {r["pid_file_text"]!r} '
                            f'!= {str(r["subject_pid"])!r}')
        else:
            ok(r['name'], 'a bot.pid bajtazonos maradt')

        if 'poller slot left untouched' not in r['stderr']:
            fail(r['name'], "hianyzik a 'poller slot left untouched' indoklas")
        else:
            ok(r['name'], "stderr indokol ('poller slot left untouched')")

        if 'polling disabled' not in r['stderr']:
            fail(r['name'], "hianyzik a 'polling disabled' indoklas")
        else:
            ok(r['name'], "stderr indokol ('polling disabled')")

    print()
    print('=== 3) POZITIV KONTROLL: sajat tulajdonu stale poller (bot.owner = a tmp STATE_DIR) ===')
    r = scenario('pozitiv-kontroll', '@self', 'channels')
    print(r['stderr'].rstrip() or '(ures stderr)')

    if check_reached(r):
        if not r['sigterm']:
            fail(r['name'], 'a sajat tulajdonu stale pollert KI KELLETT VOLNA lonie')
        else:
            ok(r['name'], 'SIGTERM megerkezett (a kilovo gepezet mukodik)')

        if 'replacing stale poller pid=' not in r['stderr']:
            fail(r['name'], "hianyzik a 'replacing stale poller pid=' sor")
        else:
            ok(r['name'], "stderr indokol ('replacing stale poller')")

    print()
    print('=== 4) VISSZAFELE KOMPAT: jelolo nelkuli poller, szulo --channels ===')
    r = scenario('visszafele-kompat', None, 'channels')
    print(r['stderr'].rstrip() or '(ures stderr)')

    if check_reached(r):
        if not r['sigterm']:
            fail(r['name'], 'a jelolo nelkuli (patch elotti) pollert ki kellett volna lonie')
        else:
            ok(r['name'], 'SIGTERM megerkezett')

        if 'replacing stale poller pid=' not in r['stderr']:
            fail(r['name'], "hianyzik a 'replacing stale poller pid=' sor")
        else:
            ok(r['name'], "stderr indokol ('replacing stale poller')")

    print()
    print('=== 5) FAIL-OPEN: nem merheto szulo-lanc (ppid=1, nincs claude) ===')
    r = scenario('fail-open', None, 'detached')
    print(r['stderr'].rstrip() or '(ures stderr)')

    if check_reached(r):
        if not r['sigterm']:
            fail(r['name'], 'nem merheto lancnal a mai (pollozo) viselkedesnek kell maradnia')
        else:
            ok(r['name'], 'SIGTERM megerkezett (fail-open: pollozik)')

        if 'replacing stale poller pid=' not in r['stderr']:
            fail(r['name'], "hianyzik a 'replacing stale poller pid=' sor")
        else:
            ok(r['name'], "stderr indokol ('replacing stale poller')")

    print()
    live_after = read_live_pid()

    if live_before != live_after:
        fail('biztonsag', f'az ELES bot.pid megvaltozott a teszt alatt: '
                          f'{live_before!r} -> {live_after!r}')
    else:
        ok('biztonsag', f'az eles bot.pid erintetlen ({live_before!r})')

    print()

    if FAILURES:
        # Bukasnal a tmp allapot-konyvtarak MARADNAK -- bennuk a szerver teljes
        # stderr-je (server.err) es a bot.pid/bot.owner vegallapota.
        print(f'BUKAS: {len(FAILURES)} allitas nem teljesult')
        for f_ in FAILURES:
            print(f'  - {f_}')
        print('A vizsgalhato tmp allapot-konyvtarak:')
        for d in STATE_DIRS:
            print(f'  - {d}')
        return 1

    for d in STATE_DIRS:
        shutil.rmtree(d, ignore_errors=True)

    print('All telegram-poller-slot-guard behaviour tests passed.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
