import { describe, it, expect } from 'vitest'
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync, chmodSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'

// channels.sh and the dashboard start IN PARALLEL in start.sh (no readiness
// wait between them) -- a cold-boot guard notification (channels_guard_notify)
// could hit the dashboard before it is listening. This slices the function
// out of scripts/channels.sh, unmodified, and drives it against a FAKE curl
// (a stub script placed first on PATH) that fails a controlled number of
// times before succeeding, proving the retry actually gets the message
// through instead of giving up on the first miss.

const ROOT = join(__dirname, '..', '..')
const CHANNELS = readFileSync(join(ROOT, 'scripts', 'channels.sh'), 'utf-8')

function sliceShellFn(src: string, name: string): string {
  const start = src.indexOf(`${name}() {`)
  if (start < 0) throw new Error(`function ${name}() not found`)
  const end = src.indexOf('\n  }', start)
  if (end < 0) throw new Error(`unterminated ${name}()`)
  return src.slice(start, end + 4)
}

/** A fake `curl` on PATH: fails (empty body) for the first `failCount` calls
 *  (tracked via a counter file), then succeeds with a message-shaped JSON body
 *  carrying an "id". Records every invocation to `logFile` for assertions. */
function makeFakeCurl(dir: string, failCount: number): void {
  const counter = join(dir, 'attempts')
  writeFileSync(counter, '0')
  const bin = join(dir, 'bin')
  mkdirSync(bin, { recursive: true })
  const script = `#!/bin/bash
n=$(cat "${counter}")
n=$((n + 1))
echo "$n" > "${counter}"
echo "$n" >> "${dir}/log"
if [ "$n" -le ${failCount} ]; then
  exit 0
fi
echo '{"id":42,"from_agent":"channels-sh-guard"}'
`
  writeFileSync(join(bin, 'curl'), script)
  chmodSync(join(bin, 'curl'), 0o755)
}

function runNotify(dir: string, message: string): { out: string; code: number } {
  const body = [
    'set -u',
    // sleep is stubbed so a multi-attempt retry does not actually stall the
    // test -- the thing under test is WHETHER it retries, not how long.
    'sleep() { :; }',
    `INSTALL_DIR="${dir}"`,
    'mkdir -p "$INSTALL_DIR/store"',
    'MAIN_AGENT_ID="marveen"',
    `PATH="${join(dir, 'bin')}:$PATH"`,
    sliceShellFn(CHANNELS, 'channels_guard_notify'),
    `channels_guard_notify "${message}"`,
    'echo "RC=$?"',
  ].join('\n')
  const p = join(dir, 'probe.sh')
  writeFileSync(p, body + '\n')
  try {
    return { out: execFileSync('bash', [p], { encoding: 'utf-8' }).trim(), code: 0 }
  } catch (e) {
    const err = e as { stdout?: string; stderr?: string; status?: number }
    return { out: `${String(err.stdout ?? '')}${String(err.stderr ?? '')}`.trim(), code: err.status ?? -1 }
  }
}

describe('channels_guard_notify retries until the dashboard is up', () => {
  it('without a dashboard token, it is a no-op success (nothing to authenticate with)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'guardnotify-'))
    try {
      makeFakeCurl(dir, 0)
      const r = runNotify(dir, 'hello')
      expect(r.out).toContain('RC=0')
      expect(() => readFileSync(join(dir, 'log'), 'utf-8')).toThrow() // curl never called
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('succeeds immediately when the dashboard answers on the first try', () => {
    const dir = mkdtempSync(join(tmpdir(), 'guardnotify-'))
    try {
      mkdirSync(join(dir, 'store'), { recursive: true })
      writeFileSync(join(dir, 'store', '.dashboard-token'), 'tok')
      makeFakeCurl(dir, 0)
      const r = runNotify(dir, 'hello')
      expect(r.out).toContain('RC=0')
      expect(readFileSync(join(dir, 'log'), 'utf-8').trim().split('\n').length).toBe(1)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('retries past early failures and still delivers the message', () => {
    const dir = mkdtempSync(join(tmpdir(), 'guardnotify-'))
    try {
      mkdirSync(join(dir, 'store'), { recursive: true })
      writeFileSync(join(dir, 'store', '.dashboard-token'), 'tok')
      makeFakeCurl(dir, 3) // fails 3 times (dashboard still booting), then answers
      const r = runNotify(dir, 'hello')
      expect(r.out).toContain('RC=0')
      expect(readFileSync(join(dir, 'log'), 'utf-8').trim().split('\n').length).toBe(4)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('gives up (RC=1) if the dashboard never comes up, after exhausting the retry budget', () => {
    const dir = mkdtempSync(join(tmpdir(), 'guardnotify-'))
    try {
      mkdirSync(join(dir, 'store'), { recursive: true })
      writeFileSync(join(dir, 'store', '.dashboard-token'), 'tok')
      makeFakeCurl(dir, 999) // never succeeds
      const r = runNotify(dir, 'hello')
      expect(r.out).toContain('RC=1')
      // exactly the retry budget, not fewer (would silently give up early) and
      // not unbounded (would hang a genuinely offline dashboard forever)
      expect(readFileSync(join(dir, 'log'), 'utf-8').trim().split('\n').length).toBe(6)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})
