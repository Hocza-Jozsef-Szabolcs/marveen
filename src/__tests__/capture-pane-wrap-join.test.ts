import { describe, it, expect, vi, beforeEach } from 'vitest'

// MEASURED (2026-08-28, card marveen-channel-gyakori-restart-20260824): all 7
// "plugin down" episodes that day escalated all the way to stage-3 (full
// session restart), and every stage-1 attempt logged "plugin submenu not
// found" with a paneTail that VISIBLY shows the target plugin's submenu
// (`Plugin:telegram:telegram MCP Server`, `Status: ✗ failed`, `Reconnect`).
// The reason the literal `plugin:telegram:telegram` pattern still failed to
// match: `tmux capture-pane -p` (no `-J`) hard-wraps long lines at the
// pane's CURRENT column width, and a narrow pane (more tiled sub-agent panes
// during a fan-out day -> narrower marveen pane) split the token itself:
//   "Plugin:telegram:te\n   legram MCP Server"
// A newline landing mid-token breaks any contiguous-substring match against
// the captured text, independent of whether the plugin was actually found.
// tmux's `-J` flag re-joins soft-wrapped lines before returning them, which
// is the root fix -- everything downstream (channel-mcp-reconnect's
// pluginPattern.test, channel-health-monitor's pane.includes) then sees the
// token intact regardless of pane width.

const h = vi.hoisted(() => ({ calls: [] as string[][] }))

vi.mock('node:child_process', async (orig) => ({
  ...(await orig() as object),
  execFileSync: vi.fn((_file: string, args?: string[]) => {
    if (Array.isArray(args)) h.calls.push(args)
    return ''
  }),
}))

import { capturePane } from '../web/agent-process.js'

beforeEach(() => {
  h.calls.length = 0
})

describe('capturePane', () => {
  it('passes -J to tmux capture-pane so soft-wrapped lines are rejoined', () => {
    capturePane('marveen-channels')

    const captureCall = h.calls.find(a => a.includes('capture-pane'))
    expect(captureCall).toBeDefined()
    expect(captureCall).toContain('-J')
  })
})
