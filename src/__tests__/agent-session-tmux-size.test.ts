// Bug (kanban card 8efb4202): both `tmux new-session` launch sites omit an
// explicit -x/-y size, so the session starts at tmux's 80x24 default. A
// persistent multi-item todo-widget can fill all 24 rows, pushing the
// `Marveen · ... · Heti: X% ...` idle footer below the visible area --
// `tmux capture-pane -p` never sees it, pane-state.ts reads 'unknown'
// forever, and the message-router retries the delivery indefinitely
// ("Agent message target session busy, will retry"). Proven incident
// (2026-08-20, sejt, msg 6919/6920): stuckDurationMs 600134.
//
// Source-contract test (same style as pane-first-run-gate.test.ts): both
// `new-session` call sites must carry an explicit size that leaves room for
// the footer under a full-height todo-widget.

import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const AGENT_PROCESS = readFileSync(join(__dirname, '../web/agent-process.ts'), 'utf-8')

describe('agent tmux session launch size (card 8efb4202)', () => {
  it('the remote launch site (host-based new-session) requests an explicit -x/-y size', () => {
    const idx = AGENT_PROCESS.indexOf("runTmux(host, ['new-session', '-d', '-s', session,")
    expect(idx).toBeGreaterThan(0)
    const call = AGENT_PROCESS.slice(idx, AGENT_PROCESS.indexOf(', { timeout:', idx))
    expect(call).toMatch(/'-x',\s*'80'/)
    expect(call).toMatch(/'-y',\s*'50'/)
  })

  it('the local launch site (null-host new-session) requests an explicit -x/-y size', () => {
    const idx = AGENT_PROCESS.indexOf("runTmux(null, ['new-session', '-d', '-s', session,")
    expect(idx).toBeGreaterThan(0)
    const call = AGENT_PROCESS.slice(idx, AGENT_PROCESS.indexOf(', { timeout:', idx))
    expect(call).toMatch(/'-x',\s*'80'/)
    expect(call).toMatch(/'-y',\s*'50'/)
  })
})
