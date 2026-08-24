/**
 * Regression coverage for the `project` tag on memories.
 *
 * Vault content (VrMobile, JokerQ, QuantumAE, VHR5, ...) is being migrated
 * into the dashboard `memories` table. Unlike `agent_id` (which fej owns the
 * row) and `category` (hot/warm/cold/shared tier), there was no column for
 * "which product line does this fact belong to" -- `project` fills that gap.
 */
import { describe, it, expect, beforeAll, afterAll, vi } from 'vitest'
import { initDatabase, saveAgentMemory, getDb } from '../db.js'
import { tryHandleMemories } from '../web/routes/memories.js'
import type { RouteContext } from '../web/routes/types.js'

vi.mock('../config.js', async () => {
  const actual = await vi.importActual<typeof import('../config.js')>('../config.js')
  return {
    ...actual,
    MAIN_AGENT_ID: 'marveen',
    ALLOWED_CHAT_ID: 'test-chat',
    OLLAMA_URL: '',
  }
})

vi.mock('../logger.js', () => ({
  logger: { info: vi.fn(), warn: vi.fn(), debug: vi.fn(), error: vi.fn() },
}))

function makeGetCtx(searchParams: Record<string, string>): { ctx: RouteContext; getBody: () => any } {
  const url = new URL('http://localhost:3420/api/memories')
  for (const [k, v] of Object.entries(searchParams)) url.searchParams.set(k, v)
  let responseBody = ''
  const res = { writeHead: vi.fn(), end: (body?: string) => { responseBody = body || '' } }
  const req = { headers: {} } as any
  return {
    ctx: { req, res: res as any, path: '/api/memories', method: 'GET', url },
    getBody: () => (responseBody ? JSON.parse(responseBody) : null),
  }
}

beforeAll(() => {
  initDatabase(':memory:')
})

afterAll(() => {
  vi.restoreAllMocks()
})

describe('memories.project column', () => {
  it('saveAgentMemory persists an optional project tag', () => {
    const { id } = saveAgentMemory('marveen', 'VrMobile Vault note', 'warm', undefined, false, 'VrMobile')
    const row = getDb().prepare('SELECT project FROM memories WHERE id = ?').get(id) as { project: string | null }
    expect(row.project).toBe('VrMobile')
  })

  it('project defaults to NULL when not passed (no regression for existing callers)', () => {
    const { id } = saveAgentMemory('marveen', 'plain memory, no project', 'warm')
    const row = getDb().prepare('SELECT project FROM memories WHERE id = ?').get(id) as { project: string | null }
    expect(row.project).toBeNull()
  })

  it('GET /api/memories?project=X returns only that project\'s rows', async () => {
    saveAgentMemory('marveen', 'JokerQ note one', 'warm', undefined, false, 'JokerQ')
    saveAgentMemory('marveen', 'JokerQ note two', 'warm', undefined, false, 'JokerQ')
    saveAgentMemory('marveen', 'VHR5 note', 'warm', undefined, false, 'VHR5')

    const { ctx, getBody } = makeGetCtx({ project: 'JokerQ' })
    await tryHandleMemories(ctx)
    const results = getBody() as any[]

    expect(results.length).toBe(2)
    for (const m of results) expect(m.project).toBe('JokerQ')
  })

  it('GET /api/memories without project still returns rows regardless of their project tag', async () => {
    const { ctx, getBody } = makeGetCtx({ agent: 'marveen', limit: '200' })
    await tryHandleMemories(ctx)
    const results = getBody() as any[]
    const projects = new Set(results.map((m: any) => m.project))
    expect(projects.has('VrMobile')).toBe(true)
    expect(projects.has('JokerQ')).toBe(true)
  })
})
