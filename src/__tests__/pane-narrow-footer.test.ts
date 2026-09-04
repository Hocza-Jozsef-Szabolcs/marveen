import { describe, it, expect } from 'vitest'
import { detectPaneState, isReadyForPrompt } from '../pane-state.js'

// RED test for kanban card `panefooterszelesseg`.
//
// Ground truth (measured, card panefooterszelesseg, comment 2026-08-06 03:30):
// a sub-agent split pane narrowed the MAIN/ACTIVE `agent-design` tmux pane
// from 80 to 23 columns. `tmux capture-pane -p` on the narrowed pane returned
// the live footer row hard-truncated at the pane's column count -- the
// trailing `on (shift+tab to cycle)` anchor IDLE_FOOTER_RX (src/pane-state.ts:78)
// requires never rendered at all -- so isSessionReadyForPrompt
// (src/web/agent-process.ts) stayed false for 14.5 hours while 12 inter-agent
// messages queued undelivered as "target session busy". A follow-up
// measurement (kanban comment 255, 2026-08-06 13:2x) confirmed it is the
// ACTIVE pane's column width that governs the footer render, not the
// narrowest pane anywhere in the tmux window.
//
// Model: `tmux capture-pane -p` returns each row hard-truncated to the pane's
// column count (Claude Code does not soft-wrap the single-line footer onto a
// second terminal row) -- this is the actually reported shape, not a
// hypothetical: at 23 columns "bypass permissions on (shift+tab to cycle)"
// rendered as just "bypass permissions". buildPane's `.slice(0, width)`
// reproduces that byte-for-byte.
//
// These tests encode the CORRECT/desired behaviour -- a pane whose only
// anomaly is a narrow column count (empty input box, no busy signal, no
// menu/error surface) IS idle and MUST be reported ready -- and are
// therefore RED against the current implementation, which loses the footer
// anchor to truncation and falls through to 'unknown'. No production code
// is touched here; this is the RED phase only.

const buildPane = (width: number, footerBody: string): string => {
  const sep = '─'.repeat(Math.max(width, 1))
  const footer = `  ⏵⏵ ${footerBody}`.slice(0, width)
  return ['', sep, '❯ ', sep, footer].join('\n')
}

describe('narrow pane truncates the footer before IDLE_FOOTER_RX\'s anchor renders', () => {
  const BYPASS_FOOTER_BODY = 'bypass permissions on (shift+tab to cycle)'

  it('matches the bypass footer at the pane\'s normal width (positive control)', () => {
    const wide = buildPane(80, BYPASS_FOOTER_BODY)
    expect(wide).toMatch(/on \(shift\+tab to cycle\)/)
    expect(detectPaneState(wide)).toBe('idle')
    expect(isReadyForPrompt(wide)).toBe(true)
  })

  it('RED: must still read idle at the real incident width (80 -> 23 columns)', () => {
    const narrow = buildPane(23, BYPASS_FOOTER_BODY)
    // What actually rendered at 23 columns: only "bypass permissions"
    // survives -- the "on (shift+tab to cycle)" anchor is gone entirely,
    // not wrapped onto a second line. Confirms the fixture reproduces the
    // real truncation shape, not a hypothetical.
    expect(narrow).not.toMatch(/on \(shift\+tab to cycle\)/)
    // DESIRED: this pane is genuinely idle (empty input box, no busy
    // signal) so it MUST classify 'idle', not fall through to 'unknown'.
    // CURRENTLY FAILS: detectPaneState has no anchor left to recognise once
    // the footer anchor is truncated away.
    expect(detectPaneState(narrow)).toBe('idle')
    // CONSEQUENCE if this stays false: the router/scheduler treat
    // 'unknown' as not-ready and defer delivery indefinitely -- the
    // measured 14.5h silent hole.
    expect(isReadyForPrompt(narrow)).toBe(true)
  })

  it.each([20, 23, 30, 40, 44, 46])(
    'RED: must read ready at %i columns (< 60), even though the footer anchor is truncated away',
    (width) => {
      const narrow = buildPane(width, BYPASS_FOOTER_BODY)
      expect(isReadyForPrompt(narrow)).toBe(true)
    },
  )

  // A second, independently real footer shape: the FleetView tail-only
  // variant (IDLE_ACCEPT_EDITS_TAIL_ONLY in pane-state.test.ts), rendered
  // when a sub-agent panel is open and no "(shift+tab to cycle)" hint is
  // shown at all -- the "← for agents" tail is the ONLY anchor this shape
  // has. Same failure class: truncation before the tail marker drops the
  // sole anchor, with no fallback to catch it.
  const FLEETVIEW_TAIL_BODY = 'accept edits on · 1 monitor · ← for agents · ↓ to manage'

  it('matches the FleetView-tail footer at normal width (positive control)', () => {
    const wide = buildPane(80, FLEETVIEW_TAIL_BODY)
    expect(wide).toMatch(/← for agents/)
    expect(isReadyForPrompt(wide)).toBe(true)
  })

  it('RED: must still read ready once < 60 columns cuts "← for agents" mid-token', () => {
    const narrow = buildPane(44, FLEETVIEW_TAIL_BODY)
    expect(narrow).not.toMatch(/← for agents/)
    // DESIRED: idle intent unaffected by width. CURRENTLY FAILS: this
    // shape has no "(shift+tab to cycle)" fallback, so once the tail
    // marker is truncated there is nothing left for IDLE_FOOTER_RX to
    // match.
    expect(isReadyForPrompt(narrow)).toBe(true)
  })
})

// RED test for the follow-up gap measured 2026-09-04 03:0x on the MAIN
// `marveen-channels` pane (%1365), narrowed to 23 columns by the
// `@dontes-audit` teammate's split pane -- the same narrowing class as
// `panefooterszelesseg` above, but the narrow-pane fallback introduced for
// that card does NOT catch it.
//
// Why the fallback misses: idleFooterLineIndex (src/pane-state.ts) only
// inspects the pane's LAST line. Claude Code renders the running
// background-task list BELOW the footer -- a `⏺ main` row plus one
// `◯ <task> <elapsed>` row per live task -- so on a pane with background
// work the footer is no longer the last line and the ⏵⏵ glyph anchor is
// never reached.
//
// Measured consequence: four scheduled tasks starved while the `❯` input
// box was EMPTY on both panes (i.e. not parked input, so no C-u recovery
// applies): fej-kapacitas-figyelo 339 attempts, kvota-deepseek-valto 279,
// dream-engine 251, munka-motor 199 -- all with last_reason='busy' in
// pending_task_retries. Widening the tmux window to 200 columns released
// all four within 2.5 minutes, which confirms column width was the sole
// cause.
const MARVEEN_NARROW_WITH_TASK_LIST = [
  '⏺ Nincs várakozó',
  '  üzenet.',
  '',
  '─'.repeat(23),
  '❯ ',
  '─'.repeat(23),
  '  Marveen · Sonnet 5…',
  '  ⏵⏵ bypass       · …',
  '',
  '  ⏺ main',
  '  ◯ dontes-audit 1h 34m',
].join('\n')

describe('narrow pane whose footer is not the last line (background-task list below)', () => {
  it('reproduces the measured shape: narrow, no wide anchor, footer above the task list', () => {
    // The pane is genuinely narrow (23 columns, read off the box separator).
    expect(MARVEEN_NARROW_WITH_TASK_LIST).not.toMatch(/on \(shift\+tab to cycle\)/)
    expect(MARVEEN_NARROW_WITH_TASK_LIST).not.toMatch(/← for agents/)
    // The ⏵⏵ footer glyph IS present -- just not on the last line.
    expect(MARVEEN_NARROW_WITH_TASK_LIST).toMatch(/^ {2}⏵⏵ /m)
    const lines = MARVEEN_NARROW_WITH_TASK_LIST.split('\n')
    expect(lines[lines.length - 1]).not.toMatch(/⏵/)
  })

  it('RED: must read idle -- an empty input box is idle regardless of what renders below the footer', () => {
    expect(detectPaneState(MARVEEN_NARROW_WITH_TASK_LIST)).toBe('idle')
    expect(isReadyForPrompt(MARVEEN_NARROW_WITH_TASK_LIST)).toBe(true)
  })

  it.each([1, 2, 5])(
    'RED: stays ready with %i background task rows rendered below the footer',
    (taskCount) => {
      const tasks = Array.from(
        { length: taskCount },
        (_, i) => `  ◯ task-${i} ${i + 1}h 0${i}m`,
      )
      const pane = [
        '─'.repeat(23),
        '❯ ',
        '─'.repeat(23),
        '  Marveen · Sonnet 5…',
        '  ⏵⏵ bypass       · …',
        '',
        '  ⏺ main',
        ...tasks,
      ].join('\n')
      expect(isReadyForPrompt(pane)).toBe(true)
    },
  )
})
