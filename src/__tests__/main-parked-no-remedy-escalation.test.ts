import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  detectPaneState,
  stuckInputSignature,
  parkedInputRowCount,
  parkedChannelInput,
  parkedMachineOriginInput,
  parkedScheduledTaskInput,
  parkedMainInputHasRemedy,
  shouldClearTruncatedPreamble,
  decideStuckInputAction,
  decideStuckInputRecovery,
  type StuckInputState,
  type StuckInputThresholds,
} from '../pane-state.js'
// Namespace import on purpose: MAIN_STUCK_THRESHOLDS is asserted below and a
// named import of a not-yet-exported symbol would be a MODULE LOAD failure
// (the whole file would fail to link), which is a compile-shaped red, not a
// behavioural one. A namespace member simply reads `undefined` until wired.
import * as cm from '../web/channel-monitor.js'

const HERE = dirname(fileURLToPath(import.meta.url))

// The REAL marveen-channels capture taken 2026-09-02 18:28, AFTER the split
// teammate pane was closed (so the main pane was back to a full 80 columns and
// every text detector could read it). Six rows of prose parked at the ❯ prompt.
// Not synthetic: this is the pane the recovery stack actually looked at.
const PARKED = readFileSync(join(HERE, 'fixtures', 'main-parked-no-remedy-20260902.txt'), 'utf8')

// The production MAIN cadence, mirrored locally so the pure assertions do not
// depend on a module-level constant: channel-monitor ticks every 60 s and
// drives mainStuckInput through MAIN_STUCK_THRESHOLDS. The separate wiring
// assertion below checks that production really carries the hold window.
const TICK_MS = 60_000
const MAIN_TH: StuckInputThresholds = { confirmMs: 90_000, dedupMs: 45_000, maxAttempts: 4, holdMs: 5 * 60_000 }
const NO_STATE: StuckInputState = { parkedSig: null, firstSeenAt: null, lastRecoverAt: null, attempts: 0 }

// The guard's return type does not yet include the new action, so compare as a
// plain string -- keeps the assertion behavioural instead of type-shaped.
const guard = (...args: Parameters<typeof cm.applyStuckRestartBusyGuard>): string =>
  String(cm.applyStuckRestartBusyGuard(...args))

function mainFacts(pane: string) {
  const block = parkedChannelInput(pane)
  return {
    escalate: true,
    rowCount: parkedInputRowCount(pane),
    blockComplete: block != null && block.complete && block.block != null,
    blockTruncated: block != null && !block.complete,
    truncatedPreamble: shouldClearTruncatedPreamble(pane),
    allowPlainReinject: false, // MAIN never plain-reinjects
    hasPlainText: false,
    machineOrigin: parkedMachineOriginInput(pane),
    scheduledTaskBlock: parkedScheduledTaskInput(pane),
  }
}

describe('MAIN parked input with no soft remedy (2026-09-02, 5h38m schedule outage)', () => {
  // ---------------------------------------------------------------------
  // Positive controls. GREEN today AND after the fix -- they prove the
  // fixture really is the deadlock cell, so the reds below are about the
  // DECISION and not about a mis-built fixture.
  // ---------------------------------------------------------------------
  describe('the fixture is the measured deadlock cell', () => {
    it('reads as a parked ("typing") pane with multi-row text', () => {
      expect(detectPaneState(PARKED)).toBe('typing')
      expect(stuckInputSignature(PARKED)).not.toBeNull()
      expect(parkedInputRowCount(PARKED)).toBe(6)
    })

    it('has NO identifiable machine origin and NO soft remedy', () => {
      // Prose, no delivery wrapper: it may be the owner's own hand-typed
      // draft, so nothing may clear or submit it.
      expect(parkedMachineOriginInput(PARKED)).toBe(false)
      expect(parkedScheduledTaskInput(PARKED)).toBe(false)
      expect(parkedMainInputHasRemedy(PARKED)).toBe(false)
    })
  })

  // ---------------------------------------------------------------------
  // DRAFT SAFETY. Green today and it MUST stay green: the fix may not add a
  // destructive move for text whose origin is uncertain. The rule is the
  // session-parkolt-input-recovery skill step 3: "Emberi draftot HAGYD BEKEN."
  // ---------------------------------------------------------------------
  it('never chooses a clearing or submitting move for uncertain-origin text', () => {
    const action = decideStuckInputAction(mainFacts(PARKED))
    expect(action).toBe('hold')
    expect(['clear-scheduled', 'clear-preamble', 'reinject-plain', 'enter']).not.toContain(action)
  })

  // ---------------------------------------------------------------------
  // RED 1 -- spell memory. The sibling state machine in the same file
  // (decidePaneErrorAlert / PaneErrorAlertThresholds.clearMs) already owns
  // this guarantee and its comment calls it load-bearing: "A single non-error
  // tick (null capture, a mid-flight busy spinner) must NOT reset the spell,
  // otherwise a genuinely wedged but flapping session never reaches the
  // confirm window and never alerts." The stuck-input machine lacks it.
  // ---------------------------------------------------------------------
  it('does not wipe an active parked spell on a single unreadable tick', () => {
    const sig = stuckInputSignature(PARKED)!
    const t0 = 1_000_000
    const opened = decideStuckInputRecovery(sig, NO_STATE, t0, MAIN_TH).next
    expect(opened.firstSeenAt).toBe(t0) // control: the spell opened

    // One tick where the pane does NOT read 'typing' (busy turn, narrow pane,
    // failed capture) -- the text is still parked, we just could not see it.
    const held = decideStuckInputRecovery(null, opened, t0 + TICK_MS, MAIN_TH).next
    expect(held.firstSeenAt).toBe(t0)
    expect(held.parkedSig).toBe(sig)
  })

  // ---------------------------------------------------------------------
  // RED 2 -- the escalation budget must be REACHABLE. Measured in production:
  // across 9 days of app logs, all 166 'Stuck-input restart deferred' lines
  // for marveen-channels carry attempts=0. The counter has never once reached
  // 1, so decideStuckInputRestart can only ever return 'skip' on MAIN and the
  // entire restart/alert escalation above it is dead code.
  // ---------------------------------------------------------------------
  it('accumulates its confirm window on a pane that flaps in and out of view', () => {
    const sig = stuckInputSignature(PARKED)!
    let state = NO_STATE
    let now = 0
    let maxAttempts = 0
    for (let i = 0; i < 30; i++) {
      now += TICK_MS
      const observed = i % 2 === 0 ? sig : null // seen on half the ticks
      state = decideStuckInputRecovery(observed, state, now, MAIN_TH).next
      maxAttempts = Math.max(maxAttempts, state.attempts)
    }
    expect(maxAttempts).toBe(MAIN_TH.maxAttempts)
  })

  it('still drops the spell when the box genuinely empties for good', () => {
    // Control for RED 2: the hold widens MEMORY, it must not create a zombie
    // spell that outlives a park which really did submit.
    const sig = stuckInputSignature(PARKED)!
    let state = decideStuckInputRecovery(sig, NO_STATE, 0, MAIN_TH).next
    for (let i = 1; i <= 30; i++) {
      state = decideStuckInputRecovery(null, state, i * TICK_MS, MAIN_TH).next
    }
    expect(state.parkedSig).toBeNull()
    expect(state.firstSeenAt).toBeNull()
  })

  it('wires the hold window into the MAIN production thresholds', () => {
    // Fixing the pure function without wiring it to MAIN would change nothing
    // in production -- MAIN_STUCK_THRESHOLDS is what mainStuckInput runs on.
    expect(cm.MAIN_STUCK_THRESHOLDS?.holdMs).toBeGreaterThan(0)
  })

  // ---------------------------------------------------------------------
  // RED 3 -- the block must be NAMED. On 2026-09-02 18:27:57 the stack saw
  // this exact cell (paneState 'typing', machineOrigin false, softRemedy
  // false) and returned 'skip'; the same cell appears 166 times over 9 days.
  // 'skip' here is unbounded silence: nothing clears it, nothing restarts it,
  // nothing reports it.
  // ---------------------------------------------------------------------
  describe('the no-remedy / uncertain-origin cell', () => {
    it('escalates to a named alert instead of skipping forever', () => {
      expect(guard('typing', 'restart', { machineOrigin: false, softRemedy: false })).toBe('alert-parked')
      expect(guard('typing', 'alert', { machineOrigin: false, softRemedy: false })).toBe('alert-parked')
    })

    it('never turns into a restart -- the text may be a human draft', () => {
      // The alert path must stay non-destructive: no respawn, no clear.
      expect(guard('typing', 'restart', { machineOrigin: false, softRemedy: false })).not.toBe('restart')
    })

    it('stays silent while the soft recovery has not been exhausted yet', () => {
      // decision 'skip' = the retry budget is not spent (or the rate limit is
      // holding). A transient park -- the normal case -- must not alert.
      expect(guard('typing', 'skip', { machineOrigin: false, softRemedy: false })).toBe('skip')
    })

    // Sibling guarantees that must survive the change.
    it('keeps the 2026-07-25 machine-origin carve-out', () => {
      expect(guard('typing', 'restart', { machineOrigin: true, softRemedy: false })).toBe('restart')
      expect(guard('typing', 'alert', { machineOrigin: true, softRemedy: false })).toBe('alert')
    })

    it('keeps deferring while soft recovery still has a move', () => {
      expect(guard('typing', 'restart', { machineOrigin: false, softRemedy: true })).toBe('skip')
      expect(guard('typing', 'restart', { machineOrigin: true, softRemedy: true })).toBe('skip')
    })

    it('keeps deferring on a busy pane and without carve-out facts', () => {
      expect(guard('busy', 'restart', { machineOrigin: false, softRemedy: false })).toBe('skip')
      expect(guard('typing', 'restart')).toBe('skip')
    })
  })
})
