import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { activityLabel } from '../pane-state.js'

// Regression for the "Csapat/Aktivitas" dashboard widget: a parked GHOST
// suggestion (Claude Code's dim placeholder in an EMPTY input box) must read
// as 'idle', not 'working'. /api/agents/activity fed detectPaneState's raw
// 'typing' straight into 'working' with no ghost-strip pass, so a genuinely
// idle agent showed as busy on every poll.

const SEP = '─'.repeat(80)

// Plain (`capture-pane -p`) view: colour is gone, so the dim ghost hint reads
// as literal parked text -> detectPaneState classifies this 'typing'.
const PLAIN_WITH_GHOST = [
  '',
  SEP,
  '❯ Try refactor src/utils.ts to use the new API',
  SEP,
  '  ⏵⏵ bypass permissions on (shift+tab to cycle)',
].join('\n')

// Same pane through captureParkedInputView (-e capture, dim spans stripped):
// the placeholder was SGR-2 faint, so the box reads empty.
const DIM_STRIPPED_EMPTY = [
  '',
  SEP,
  '❯ ',
  SEP,
  '  ⏵⏵ bypass permissions on (shift+tab to cycle)',
].join('\n')

// REAL typed input: normal intensity, survives the dim strip too.
const DIM_STRIPPED_REAL_TEXT = [
  '',
  SEP,
  '❯ deploy the thing please',
  SEP,
  '  ⏵⏵ bypass permissions on (shift+tab to cycle)',
].join('\n')

const BUSY = [
  '✻ Baking… (12s · 1.2k tokens · esc to interrupt)',
  SEP,
  '❯ ',
  SEP,
  '  ⏵⏵ bypass permissions on (shift+tab to cycle)',
].join('\n')

const IDLE = [
  '',
  SEP,
  '❯ ',
  SEP,
  '  ⏵⏵ bypass permissions on (shift+tab to cycle)',
].join('\n')

describe('activityLabel (dashboard /api/agents/activity)', () => {
  it('a parked ghost-suggestion box labels idle once the dim-stripped view is empty', () => {
    expect(activityLabel(true, PLAIN_WITH_GHOST, DIM_STRIPPED_EMPTY)).toBe('idle')
  })

  it('a REAL parked message still labels working (no over-tolerance)', () => {
    expect(activityLabel(true, PLAIN_WITH_GHOST, DIM_STRIPPED_REAL_TEXT)).toBe('working')
  })

  it('fails safe to working when the dim-stripped capture is unavailable', () => {
    expect(activityLabel(true, PLAIN_WITH_GHOST, null)).toBe('working')
  })

  it('a busy pane labels working without consulting the dim view', () => {
    expect(activityLabel(true, BUSY, null)).toBe('working')
  })

  it('a plainly idle pane labels idle', () => {
    expect(activityLabel(true, IDLE, null)).toBe('idle')
  })

  it('a stopped agent labels stopped regardless of pane content', () => {
    expect(activityLabel(false, PLAIN_WITH_GHOST, null)).toBe('stopped')
  })

  it('a running agent with no capture labels unknown', () => {
    expect(activityLabel(true, null, null)).toBe('unknown')
  })
})

// Wiring guard: /api/agents/activity must resolve 'typing' through
// activityLabel (which consults captureParkedInputView) instead of mapping
// detectPaneState's raw 'typing' straight to 'working'.
describe('/api/agents/activity wiring (ghost-tolerant label)', () => {
  it('the route labels through activityLabel + captureParkedInputView, not raw typing->working', () => {
    const src = readFileSync(
      join(dirname(fileURLToPath(import.meta.url)), '../web/routes/agents.ts'),
      'utf-8',
    )
    const start = src.indexOf(`path === '/api/agents/activity'`)
    expect(start).toBeGreaterThan(-1)
    const block = src.slice(start, start + 2000)
    expect(block).toContain('activityLabel(')
    expect(block).toContain('captureParkedInputView(')
    expect(block).not.toMatch(/'busy'\s*\|\|\s*s\s*===\s*'typing'/)
  })
})
