import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { execFileSync } from 'node:child_process'
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const CHANNELS_SH = join(REPO_ROOT, 'scripts', 'channels.sh')
const channelsSh = readFileSync(CHANNELS_SH, 'utf-8')

// The second reap pass in channels.sh kills orphan provider pollers from older
// plugin builds that carry CLAUDE_PLUGIN_ROOT but no *_STATE_DIR.
//
// SEMANTICS (changed 2026-09-02, see select_orphan_pids in channels.sh):
// the pass used to select by NEGATIVE EXCLUSION -- "anything carrying
// CLAUDE_PLUGIN_ROOT=.../<provider> that is NOT under MY $INSTALL_DIR/agents/".
// CLAUDE_PLUGIN_ROOT resolves to the SHARED user-level plugin cache, so that
// predicate also matched every poller of a NEIGHBOURING INSTALL on the same
// machine (/Users/ceo/Marveen vs /Users/ceo/jarvis share one tmux server):
// the two installs reaped each other's channel poller on every restart.
// It is now a POSITIVE OWNERSHIP TEST -- select only what provably belongs to
// THIS install (a channel-defining env var whose VALUE STARTS WITH my install
// dir), and never what belongs to my own agents/ subtree.
//
// These tests drive the REAL selector through the `--select-orphan-pids` CLI
// seam of channels.sh (which prints the PIDs and exits before any side effect:
// no .env read, no mkdir, no tmux, no kill), so a regression in the shipped
// shell function fails here. Nothing is started and no signal is ever sent.
//
// scripts/__tests__/channels-orphan-reap-scope.test.sh covers the same seam
// with a VERBATIM `ps eww` fixture from the live machine, but that shell file
// runs in no automated gate; this vitest file runs in `npm test`. The overlap
// is deliberate.

const INSTALL_DIR = '/Users/tester/Marveen'
const FOREIGN_DIR = '/Users/tester/jarvis' // launchd path is lowercase; on disk: Jarvis
const PROVIDER = 'telegram'
const STATE_VAR = 'TELEGRAM_STATE_DIR'

const SHARED_ROOT = '/Users/tester/.claude/plugins/cache/claude-plugins-official/telegram/0.0.7'
const SHARED_SLACK_ROOT = '/Users/tester/.claude/plugins/cache/claude-plugins-official/slack/0.0.7'

const HEAD = 'S+     0:00.01 bun run --shell=bun --silent start'

/**
 * One `ps eww -e` line: PID, tty, state/time/command, then the flattened env.
 */
function psLine(pid: number, env: string[]): string {
  return `${pid} s0${pid % 100} ${HEAD} HOME=/Users/tester LOGNAME=tester SHELL=/bin/zsh ${env.join(' ')} CLAUDECODE=1`
}

// --- OURS: must be reaped -----------------------------------------------------
// Old-build orphan: no *_STATE_DIR and no CLAUDE_CONFIG_DIR at all. Its ONLY
// ownership marker is CLAUDE_PROJECT_DIR, which equals the install dir EXACTLY
// (no trailing slash). This is the very target the 2nd pass exists for.
const OWN_ORPHAN_PROJECT_ONLY = psLine(1001, [
  `PWD=${SHARED_ROOT}`,
  `OLDPWD=${INSTALL_DIR}`,
  `CLAUDE_PROJECT_DIR=${INSTALL_DIR}`,
  `CLAUDE_PLUGIN_ROOT=${SHARED_ROOT}`,
])
// Main poller with an isolated channels config: owned via CLAUDE_CONFIG_DIR and
// via a CLAUDE_PLUGIN_ROOT that points INSIDE the install (not the shared cache).
const OWN_MAIN_ISOLATED_CFG = psLine(1002, [
  `PWD=${INSTALL_DIR}`,
  `CLAUDE_CONFIG_DIR=${INSTALL_DIR}/.channels-config`,
  `CLAUDE_PROJECT_DIR=${INSTALL_DIR}`,
  `CLAUDE_PLUGIN_ROOT=${INSTALL_DIR}/.channels-config/plugins/cache/claude-plugins-official/telegram/0.0.7`,
])
// Same install, spelled in the OTHER letter case (launchd starts on the
// lowercase path while the directory on disk is capitalised). MEASURED fact on
// the live box: one process carries both spellings at once.
const OWN_MAIN_LOWERCASE_SPELLING = psLine(1005, [
  `PWD=/Users/tester/marveen`,
  `CLAUDE_CONFIG_DIR=/Users/tester/marveen/.channels-config`,
  `CLAUDE_PLUGIN_ROOT=${SHARED_ROOT}`,
])

// --- OURS, but must be SPARED -------------------------------------------------
const OWN_SUB_DEV2_STATEDIR = psLine(1003, [
  `PWD=${INSTALL_DIR}/agents/dev2`,
  `${STATE_VAR}=${INSTALL_DIR}/agents/dev2/.claude/channels/telegram`,
  `CLAUDE_PROJECT_DIR=${INSTALL_DIR}/agents/dev2`,
  `CLAUDE_PLUGIN_ROOT=${SHARED_ROOT}`,
])
const OWN_SUB_DEV3_CONFIGDIR = psLine(1004, [
  `PWD=${INSTALL_DIR}/agents/dev3`,
  `CLAUDE_CONFIG_DIR=${INSTALL_DIR}/agents/dev3/.claude-config`,
  `CLAUDE_PROJECT_DIR=${INSTALL_DIR}/agents/dev3`,
  `CLAUDE_PLUGIN_ROOT=${SHARED_ROOT}`,
])
// Our own agent poller whose state dir is spelled in the lowercase install
// path. Without case folding the agents/ guard would miss it and we would kill
// our OWN sub-agent's poller.
const OWN_SUB_LOWERCASE_SPELLING = psLine(1006, [
  `${STATE_VAR}=/Users/tester/marveen/agents/dev4/.claude/channels/telegram`,
  `CLAUDE_PLUGIN_ROOT=${SHARED_ROOT}`,
])

// --- FOREIGN INSTALL: must never be touched ----------------------------------
const FOREIGN_MAIN = psLine(2001, [
  `PWD=${FOREIGN_DIR}`,
  `CLAUDE_CONFIG_DIR=${FOREIGN_DIR}/.channels-config`,
  `CLAUDE_PROJECT_DIR=/Users/tester/Jarvis`,
  `CLAUDE_PLUGIN_ROOT=${SHARED_ROOT}`,
])
const FOREIGN_SUB = psLine(2002, [
  `${STATE_VAR}=${FOREIGN_DIR}/agents/felderito/.claude/channels/telegram`,
  `CLAUDE_PROJECT_DIR=/Users/tester/Jarvis/agents/felderito`,
  `CLAUDE_PLUGIN_ROOT=${SHARED_ROOT}`,
])
// Foreign poller that merely MENTIONS our install dir in a non-channel variable
// (OLDPWD / PATH). Ownership is read from channel-defining keys only.
const FOREIGN_MENTIONS_US = psLine(5001, [
  `PWD=${FOREIGN_DIR}`,
  `OLDPWD=${INSTALL_DIR}`,
  `PATH=${INSTALL_DIR}/scripts/bin:/usr/bin:/bin`,
  `CLAUDE_CONFIG_DIR=${FOREIGN_DIR}/.channels-config`,
  `CLAUDE_PROJECT_DIR=/Users/tester/Jarvis`,
  `CLAUDE_PLUGIN_ROOT=${SHARED_ROOT}`,
])
// Sibling install whose path merely has ours as a STRING prefix.
const SIBLING_PREFIX_INSTALL = psLine(6001, [
  `PWD=${INSTALL_DIR}-old`,
  `CLAUDE_CONFIG_DIR=${INSTALL_DIR}-old/.channels-config`,
  `CLAUDE_PROJECT_DIR=${INSTALL_DIR}-old`,
  `CLAUDE_PLUGIN_ROOT=${SHARED_ROOT}`,
])
// Our path appears INSIDE a channel var's value but not at its start (restored
// backup copy). Ownership is anchored to the START of the value.
const OUR_PATH_MID_VALUE = psLine(7001, [
  `CLAUDE_PROJECT_DIR=/Users/tester/backup${INSTALL_DIR}`,
  `CLAUDE_PLUGIN_ROOT=${SHARED_ROOT}`,
])

// --- Not a target of THIS pass ------------------------------------------------
// Ours, but a different provider: only the provider filter may reject it.
const OWN_OTHER_PROVIDER = psLine(3001, [
  `PWD=${INSTALL_DIR}`,
  `CLAUDE_CONFIG_DIR=${INSTALL_DIR}/.channels-config`,
  `CLAUDE_PROJECT_DIR=${INSTALL_DIR}`,
  `CLAUDE_PLUGIN_ROOT=${SHARED_SLACK_ROOT}`,
])
// Ours and telegram-flavoured, but carries NO CLAUDE_PLUGIN_ROOT -- not a
// plugin poller at all (the 2nd pass is defined over plugin-root carriers).
const OWN_NON_POLLER = psLine(4001, [
  `PWD=${INSTALL_DIR}`,
  `CLAUDE_PROJECT_DIR=${INSTALL_DIR}`,
  `${STATE_VAR}=${INSTALL_DIR}/.claude/channels/telegram`,
])
const UNRELATED = '4002 s042  S+     0:00.01 node some-other-process --flag'
// Plugin poller with NO ownership marker whatsoever. Under the OLD negative
// exclusion this was reaped; under positive ownership it is not -- it cannot be
// proven ours, and unprovable was exactly the cross-install kill.
const UNATTRIBUTABLE = psLine(8001, [`PWD=/tmp`, `CLAUDE_PLUGIN_ROOT=${SHARED_ROOT}`])

const ALL_LINES = [
  OWN_ORPHAN_PROJECT_ONLY,
  OWN_MAIN_ISOLATED_CFG,
  OWN_MAIN_LOWERCASE_SPELLING,
  OWN_SUB_DEV2_STATEDIR,
  OWN_SUB_DEV3_CONFIGDIR,
  OWN_SUB_LOWERCASE_SPELLING,
  FOREIGN_MAIN,
  FOREIGN_SUB,
  FOREIGN_MENTIONS_US,
  SIBLING_PREFIX_INSTALL,
  OUR_PATH_MID_VALUE,
  OWN_OTHER_PROVIDER,
  OWN_NON_POLLER,
  UNRELATED,
  UNATTRIBUTABLE,
]

let tmp: string

beforeAll(() => {
  tmp = mkdtempSync(join(tmpdir(), 'reap-scope-'))
})
afterAll(() => {
  rmSync(tmp, { recursive: true, force: true })
})

/** Runs the SHIPPED selector via channels.sh --select-orphan-pids. */
function selectOrphans(psLines: string[], installDir = INSTALL_DIR): string[] {
  const snap = join(tmp, `ps-${Math.random().toString(36).slice(2)}.txt`)
  writeFileSync(snap, psLines.join('\n') + '\n', 'utf-8')
  const out = execFileSync(
    'bash',
    [CHANNELS_SH, '--select-orphan-pids', PROVIDER, installDir, STATE_VAR, snap],
    { encoding: 'utf-8' },
  )
  rmSync(snap, { force: true })
  return out.split('\n').map((s) => s.trim()).filter(Boolean)
}

describe('channels.sh second-pass orphan reap: positive ownership scope', () => {
  it('reaps our own old-build orphan whose only owner marker is CLAUDE_PROJECT_DIR', () => {
    // The 2nd pass would be pointless without this: an orphan with no
    // *_STATE_DIR is invisible to the 1st pass, so if it were unreapable too it
    // would 409-Conflict against every future poller forever.
    expect(selectOrphans([OWN_ORPHAN_PROJECT_ONLY])).toEqual(['1001'])
  })

  it('reaps our own main poller (isolated config dir, install-local plugin root)', () => {
    expect(selectOrphans([OWN_MAIN_ISOLATED_CFG])).toEqual(['1002'])
  })

  it('reaps our own poller when the install path is spelled in the other letter case', () => {
    expect(selectOrphans([OWN_MAIN_LOWERCASE_SPELLING])).toEqual(['1005'])
  })

  it('never reaps a live sub-agent poller of ours (state dir or config dir under agents/)', () => {
    expect(selectOrphans([OWN_SUB_DEV2_STATEDIR, OWN_SUB_DEV3_CONFIGDIR])).toEqual([])
  })

  it('never reaps our sub-agent poller whose agents/ path is spelled in the other letter case', () => {
    expect(selectOrphans([OWN_SUB_LOWERCASE_SPELLING])).toEqual([])
  })

  it('never reaps a NEIGHBOURING INSTALL poller, main or sub-agent', () => {
    expect(selectOrphans([FOREIGN_MAIN, FOREIGN_SUB])).toEqual([])
  })

  it('does not claim a foreign poller that only mentions our install dir in OLDPWD/PATH', () => {
    expect(selectOrphans([FOREIGN_MENTIONS_US])).toEqual([])
  })

  it('does not claim a sibling install whose path merely has ours as a string prefix', () => {
    expect(selectOrphans([SIBLING_PREFIX_INSTALL])).toEqual([])
  })

  it('anchors ownership to the START of the value, not anywhere inside it', () => {
    expect(selectOrphans([OUR_PATH_MID_VALUE])).toEqual([])
  })

  it('ignores our own poller of a DIFFERENT provider', () => {
    // Owned on every axis; only the provider filter may reject it.
    expect(selectOrphans([OWN_OTHER_PROVIDER])).toEqual([])
  })

  it('ignores an owned, telegram-flavoured process that carries no CLAUDE_PLUGIN_ROOT', () => {
    expect(selectOrphans([OWN_NON_POLLER, UNRELATED])).toEqual([])
  })

  it('does NOT reap a plugin poller with no ownership marker at all', () => {
    // Semantic inversion vs. the old negative exclusion, and the point of the
    // fix: unprovable ownership is exactly what killed the neighbour install.
    expect(selectOrphans([UNATTRIBUTABLE])).toEqual([])
  })

  it('selects only our own non-agent pollers out of a mixed fleet snapshot', () => {
    expect(selectOrphans(ALL_LINES).sort()).toEqual(['1001', '1002', '1005'])
  })

  it('is symmetric: the neighbouring install selects its own main pollers and none of ours', () => {
    // Run the SAME selector as the other install. If it ever reaps one of our
    // PIDs (1xxx) the cross-install kill is back, from the other direction.
    // 2001 and 5001 are both jarvis MAIN pollers; 2002 is its own sub-agent.
    const foreign = selectOrphans(ALL_LINES, FOREIGN_DIR)
    expect(foreign.sort()).toEqual(['2001', '5001'])
  })

  it('the selector is side-effect free: the seam exits before .env, mkdir, ps and tmux', () => {
    // Everything above the seam is function DEFINITIONS only; every executed
    // side effect lives below it. Without this the tests here would be running
    // .env reads, a full `ps eww -e` and tmux calls on the developer's machine.
    const seamIdx = channelsSh.indexOf('--select-orphan-pids')
    expect(seamIdx).toBeGreaterThan(-1)
    const after = channelsSh.slice(seamIdx)
    for (const sideEffect of ['mkdir -p', 'new-session', "$INSTALL_DIR/.env", '/bin/ps eww -e']) {
      expect(after).toContain(sideEffect)
    }
    const before = channelsSh.slice(0, seamIdx)
    for (const sideEffect of ['mkdir -p', 'new-session', "$INSTALL_DIR/.env", '/bin/ps eww -e']) {
      expect(before).not.toContain(sideEffect)
    }
  })

  it('production and this test drive ONE implementation (no dead-code testing)', () => {
    // Anti-drift anchor replacing the old source-scrape: the CLI seam and the
    // 2nd reap pass must both call select_orphan_pids, otherwise everything
    // above would be exercising a shell function nothing ships.
    expect(channelsSh).toMatch(/^select_orphan_pids\(\)\s*\{/m)
    expect(channelsSh).toMatch(/^\s*select_orphan_pids "\$2" "\$3" "\$4" "\$5"/m)
    expect(channelsSh).toMatch(/ORPHAN_PIDS2="\$\(select_orphan_pids /)
    // The reverted, unscoped form must not come back.
    expect(channelsSh).not.toContain('index($0, subdir) == 0')
  })
})
