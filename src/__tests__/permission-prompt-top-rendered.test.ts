import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { detectsPermissionPrompt, detectsBlockingMenu, detectPaneState } from '../pane-state.js'

const CHANNEL_MONITOR = readFileSync(join(__dirname, '../web/channel-monitor.ts'), 'utf-8')

// Both fixtures are REAL panes, captured 2026-09-03 from a throwaway Claude
// Code v2.1.259 session (120x40) driven into a genuine permission prompt; only
// the paths are anonymised. They were produced INDEPENDENTLY of the detector --
// the point of a failure-first measurement is that the sample must not come
// from the same hand that wrote the pattern.
const readFixture = (name: string) =>
  readFileSync(join(__dirname, 'fixtures/pane', name), 'utf8')

// A FRESH session whose FIRST tool call needs consent: the TUI renders the
// prompt card right under the banner and leaves the rest of the pane blank.
// This is the shape a newly spawned agent shows -- and every card handover
// spawns a fresh window, so it is the common case, not a corner one.
const TOP_RENDERED = readFixture('permission-prompt-bash-top-rendered.txt')

// The Write-tool variant: the question reads "Do you want to create <file>?",
// not "proceed". Live evidence that the question matcher must stay verb-plural.
const WRITE_CREATE = readFixture('permission-prompt-write-create.txt')

describe('permission prompt rendered above a blank pane tail', () => {
  // Self-check FIRST: the whole point of this fixture is its blank tail. If a
  // whitespace-trimming hook ever strips it, these tests would silently pass
  // for the wrong reason -- so pin the property the fixture exists to carry.
  it('the fixture really has a blank tail longer than the footer window', () => {
    const lines = TOP_RENDERED.split('\n')
    let blank = 0
    for (let i = lines.length - 1; i >= 0 && lines[i].trim() === ''; i--) blank++
    expect(blank).toBeGreaterThan(12)
    expect(TOP_RENDERED).toContain('Do you want to proceed?')
  })

  it('is recognised as a permission prompt, not a silent unknown pane', () => {
    expect(detectsPermissionPrompt(TOP_RENDERED)).toBe(true)
  })

  // Why it matters, measured: on this shape the pane state is 'unknown' (the
  // router will not deliver) AND the menu detector is false (no menu alert),
  // so without its own detection the session waits with nothing said about it.
  it('documents the gap it closes: unknown state, and no menu alert to fall back on', () => {
    expect(detectPaneState(TOP_RENDERED)).toBe('unknown')
    expect(detectsBlockingMenu(TOP_RENDERED)).toBe(false)
  })

  it('recognises the Write-tool "create" wording as well', () => {
    expect(detectsPermissionPrompt(WRITE_CREATE)).toBe(true)
    expect(WRITE_CREATE).toContain('Do you want to create')
  })

  // Regression anchor for the recovery that must NOT change: a genuine stuck
  // menu is still a menu (Escape recovers it), and must never be mistaken for
  // a permission prompt -- including when it, too, sits above a blank tail.
  it('leaves genuine stuck menus alone, blank tail or not', () => {
    const mcpMenu = [
      '   Manage MCP servers',
      '   5 servers',
      '',
      '     claude.ai',
      '   ❯ claude.ai Canva · ✔ connected · 39 tools',
      '',
      '   ↑/↓ to navigate · Enter to confirm · Esc to cancel',
    ].join('\n')
    expect(detectsBlockingMenu(mcpMenu)).toBe(true)
    expect(detectsPermissionPrompt(mcpMenu)).toBe(false)
    const withBlankTail = mcpMenu + '\n'.repeat(18)
    expect(detectsPermissionPrompt(withBlankTail)).toBe(false)
  })

  // The blank-tail allowance must not become "search the whole pane": a reply
  // that quotes a prompt far above the live surface is not a live prompt.
  it('does not reach past the footer window into scrollback', () => {
    const quotedFarAbove = [
      ' Do you want to proceed?',
      ' ❯ 1. Yes',
      '   2. No',
      ...Array(20).fill('  ...later output...'),
      '',
      '',
    ].join('\n')
    expect(detectsPermissionPrompt(quotedFarAbove)).toBe(false)
  })
})

// --- source contract (same style as pane-first-run-gate.test.ts) ---
//
// The detector only helps if the recovery branch actually consults it BEFORE
// the blind Escape. Without this contract the ordering can be lost in a later
// edit and every test above stays green -- the pane would be recognised and
// then cancelled anyway.
describe('blocking-menu recovery wiring: a permission prompt gets no keystroke', () => {
  it('probes the permission prompt before the blind Escape', () => {
    const permIdx = CHANNEL_MONITOR.indexOf('detectsPermissionPrompt(paneNow)')
    const escIdx = CHANNEL_MONITOR.indexOf("'Session parked in a blocking interactive menu -- sending Escape to recover'")
    expect(permIdx).toBeGreaterThan(0)
    expect(escIdx).toBeGreaterThan(permIdx)
  })

  it('the permission branch sends no keys at all -- it alerts and stops', () => {
    const permIdx = CHANNEL_MONITOR.indexOf('if (paneNow != null && detectsPermissionPrompt(paneNow)) {')
    expect(permIdx).toBeGreaterThan(0)
    const branch = CHANNEL_MONITOR.slice(permIdx, CHANNEL_MONITOR.indexOf('} else if', permIdx))
    expect(branch).not.toContain('send-keys')
    expect(branch).not.toContain("'Escape'")
    expect(branch).toMatch(/sendAlert\(/)
  })

  // The other half of the contract: fixing the permission case must not cost
  // the recovery it was built for. A genuine stuck menu still gets its Escape.
  it('a genuine stuck menu still gets the recovery Escape', () => {
    expect(CHANNEL_MONITOR).toMatch(/sending Escape to recover'\)[\s\S]{0,300}?send-keys'[\s\S]{0,80}?'Escape'/)
  })
})
