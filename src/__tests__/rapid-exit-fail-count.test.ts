import { describe, it, expect } from 'vitest'
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'

// channels-failures.log is not a rapid-exit-only log: main-agent config mode,
// the post-init /mcp unlock probes and their outcomes all append their own
// diagnostic lines to the SAME file (scripts/channels.sh, several `>>` sites
// besides the rapid-exit one). FAIL_COUNT must count only the rapid-exit
// lines that actually measure back-to-back crash-looping -- counting every
// line in the file conflates unrelated diagnostics with the crash signal and
// can trigger a 300s backoff (or skip a warranted one) that the real
// rapid-exit rate never asked for.

const ROOT = join(__dirname, '..', '..')
const CHANNELS = readFileSync(join(ROOT, 'scripts', 'channels.sh'), 'utf-8')

function sliceBetween(src: string, startMarker: string, endMarker: string): string {
  const start = src.indexOf(startMarker)
  if (start < 0) throw new Error(`start marker not found: ${startMarker}`)
  const end = src.indexOf(endMarker, start + startMarker.length)
  if (end < 0) throw new Error(`end marker not found after start: ${endMarker}`)
  return src.slice(start, end + endMarker.length)
}

/** The whole rapid-exit branch: ELAPSED check, the log append, the FAIL_COUNT
 *  count and its two thresholds, down to its own `exit 1`. Sliced verbatim --
 *  the harness only supplies the environment (elapsed time, a pre-seeded log). */
function rapidExitBranch(): string {
  return sliceBetween(CHANNELS, 'ELAPSED=$(( $(date +%s) - START_TS ))', 'exit 1\nfi')
}

function runBranch(dir: string, ageSeconds: number): { out: string; code: number } {
  const body = [
    'set -u',
    'exec 2>&1', // the shipped WARN/ERROR lines go to stderr; merge so assertions see them
    `INSTALL_DIR="${dir}"`,
    'mkdir -p "$INSTALL_DIR/store"',
    `START_TS=$(( $(date +%s) - ${ageSeconds} ))`,
    // Override sleep so a triggered backoff does not actually stall the test;
    // the branch logic under test is which threshold fires, not the duration.
    'sleep() { echo "SLEPT $1"; }',
    rapidExitBranch(),
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

function seedLog(dir: string, lines: string[]): void {
  mkdirSync(join(dir, 'store'), { recursive: true })
  writeFileSync(join(dir, 'store', 'channels-failures.log'), lines.map((l) => l + '\n').join(''))
}

describe('rapid-exit FAIL_COUNT counts only rapid-exit lines', () => {
  it('a log with mixed diagnostic content: 4 real rapid-exits must not read as 9', () => {
    const dir = mkdtempSync(join(tmpdir(), 'rapidexit-'))
    try {
      // 5 unrelated diagnostic lines the same file also collects, plus 4
      // genuine rapid-exit lines -- 9 lines total, 4 of them the real signal.
      seedLog(dir, [
        '2026-09-02 10:00:00 channels.sh: main-agent shared CLAUDE_CONFIG_DIR=/Users/ceo/.claude',
        '2026-09-02 10:00:01 channels.sh post-init: unlock probe SKIPPED -- input line not confirmed empty (state: busy)',
        '2026-09-02 10:00:02 channels.sh post-init: telegram plugin row failed, firing /mcp Up+Enter+Enter unlock -- row: 3',
        '2026-09-02 10:00:03 channels.sh post-init: unlock round finished, input line verified empty',
        '2026-09-02 10:00:04 channels.sh post-init: unlock effect: plugin bun poller RUNNING (pid 4242)',
        '2026-09-02 10:00:05 rapid-exit after 4s',
        '2026-09-02 10:00:09 rapid-exit after 3s',
        '2026-09-02 10:00:12 rapid-exit after 5s',
        '2026-09-02 10:00:17 rapid-exit after 4s',
      ])
      // this invocation appends its OWN rapid-exit line before counting, so the
      // real rapid-exit count the branch must see is 4 (seeded) + 1 (this run) = 5
      const r = runBranch(dir, 5)
      expect(r.code).toBe(1)
      expect(r.out).not.toMatch(/^ERROR: 9 rapid failures/m)
      expect(r.out).not.toMatch(/^ERROR: 10 rapid failures/m)
      expect(r.out).toMatch(/^ERROR: 5 rapid failures detected\. Waiting 300s/m)
      expect(r.out).toContain('SLEPT 300')
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('unrelated diagnostics alone must not fake a rapid-failure streak', () => {
    const dir = mkdtempSync(join(tmpdir(), 'rapidexit-'))
    try {
      // 6 non-rapid-exit lines, 0 real rapid-exits before this run -- the file
      // is bulky, but the crash signal itself has not repeated.
      seedLog(dir, [
        '2026-09-02 10:00:00 channels.sh: main-agent shared CLAUDE_CONFIG_DIR=/Users/ceo/.claude',
        '2026-09-02 10:00:01 channels.sh post-init: unlock probe SKIPPED -- input line not confirmed empty (state: busy)',
        '2026-09-02 10:00:02 channels.sh post-init: telegram plugin row failed, firing /mcp Up+Enter+Enter unlock -- row: 3',
        '2026-09-02 10:00:03 channels.sh post-init: unlock round finished, input line verified empty',
        '2026-09-02 10:00:04 channels.sh post-init: unlock effect: plugin bun poller RUNNING (pid 4242)',
        '2026-09-02 10:00:05 channels.sh: WARN main-agent starting on SHARED ~/.claude although a fleet setup-token exists',
      ])
      // this run's own append makes it 1 real rapid-exit -- below both thresholds
      const r = runBranch(dir, 5)
      expect(r.code).toBe(1)
      expect(r.out).not.toContain('SLEPT')
      expect(r.out).not.toMatch(/rapid failures/)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})
