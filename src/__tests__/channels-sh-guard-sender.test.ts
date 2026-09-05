import { describe, it, expect, beforeAll } from 'vitest'
import { Readable } from 'node:stream'
import { existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { initDatabase, listAgentMessages } from '../db.js'
import { tryHandleMessages } from '../web/routes/messages.js'

const here = dirname(fileURLToPath(import.meta.url))

// Card main-agent-kozos-claude-boot-20260904: the silent-401 boot failure has
// a working DETECTOR (scripts/channels.sh's two WARN triggers), but the
// ALERT was never actually reaching anyone -- MEASURED: the agent_messages
// table has never once recorded a sender named "channels-sh-guard", despite
// the install restarting channels.sh many times a day.
//
// ROOT CAUSE, measured live against the running dashboard (not assumed):
//   curl -X POST /api/messages -d '{"from":"channels-sh-guard", ...}'
//   -> 403 {"error":"unknown agent 'channels-sh-guard' -- from must be a
//           registered fleet agent id"}
// isKnownAgent() only accepts MAIN_AGENT_ID, the OWNER, or a real
// `agents/<name>/` directory. channels.sh's cold-boot guard uses a synthetic
// sender that is none of those -- so every guard notification this install
// has ever attempted was rejected before creation, silently (channels.sh
// discards curl's result with `|| true`).
//
// The fix is a narrow, named exemption for this ONE script-originated sender
// -- NOT an `agents/channels-sh-guard/` directory, which would pull it into
// listAllAgentNames()'s lifecycle sweep (context-guard, heartbeat) as if it
// were a real, sessionless agent to keep alive.

beforeAll(() => { initDatabase(':memory:') })

async function postFrom(from: string): Promise<{ status: number; body: any }> {
  const payload = JSON.stringify({ from, to: 'marveen', content: '[GUARD] test message' })
  const req = Readable.from([Buffer.from(payload)]) as any
  let status = 0
  let body = ''
  const res = {
    writeHead(s: number) { status = s },
    end(b?: string) { body = b ?? '' },
  } as any
  const handled = await tryHandleMessages({
    req, res, path: '/api/messages', method: 'POST', url: new URL('http://x/api/messages'),
  } as any)
  expect(handled).toBe(true)
  return { status, body: body ? JSON.parse(body) : null }
}

describe('channels.sh cold-boot guard sender is a real, accepted identity', () => {
  it('is accepted (not 403) so the guard message actually reaches the DB', async () => {
    const { status, body } = await postFrom('channels-sh-guard')
    expect(status, `body: ${JSON.stringify(body)}`).not.toBe(403)
    expect(body.id).toBeGreaterThan(0)
    expect(body.from_agent).toBe('channels-sh-guard')
  })

  it('the accepted message is actually retrievable -- not just a 200 with nothing stored', async () => {
    await postFrom('channels-sh-guard')
    const all = listAgentMessages().filter((m) => m.from_agent === 'channels-sh-guard')
    expect(all.length).toBeGreaterThan(0)
  })

  it('bypass variants that sanitize to the same sender are ALSO accepted (symmetry with the coordinator-forgery guard)', async () => {
    const { status } = await postFrom('channels-sh-guard.')
    expect(status).not.toBe(403)
  })

  it('an UNRELATED made-up sender is still rejected -- the exemption is narrow, not a general bypass', async () => {
    const { status, body } = await postFrom('totally-made-up-agent-xyz')
    expect(status).toBe(403)
    expect(body.error).toMatch(/unknown agent/)
  })

  it('does NOT create a real agents/channels-sh-guard/ directory as the fix (lifecycle-sweep safety)', () => {
    // Measured guard against the wrong fix: creating a directory would pull
    // this into listAllAgentNames() (context-guard / heartbeat lifecycle
    // sweep), which expects every entry to be a real, sessionless-or-not
    // dispatchable agent.
    const dir = join(here, '..', '..', 'agents', 'channels-sh-guard')
    expect(existsSync(dir)).toBe(false)
  })
})
