// Contract tests (kanban-project-mezo-226-kartyan-ures-20260808, 410-es komment
// 4. pontja): a `project` mezo hianya uj kartyanal a lelet FORRASA -- 226 kartyan
// ures maradt, mert semmi nem kenyszeritette ki letrehozaskor. POST /api/kanban
// mostantol elutasitja (400) az ures/hianyzo project-et.
//
// Ket ismert flotta-hivo hianyzott a project mezobol -- mindketto javitva ugyanebben
// a valtozasban: a dashboard "Create cards" tomeges gomb (web/app.js) es az
// idea-to-kanban-triage skill sablonja.

import { describe, it, expect, beforeEach } from 'vitest'
import { EventEmitter } from 'node:events'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { initDatabase, getKanbanCard } from '../db.js'
import { tryHandleKanban } from '../web/routes/kanban.js'
import type { RouteContext } from '../web/routes/types.js'

const __dirname = dirname(fileURLToPath(import.meta.url))

async function postCard(body: unknown): Promise<{ statusCode: number; json: any }> {
  const req = new EventEmitter() as unknown as RouteContext['req']
  const state = { statusCode: 0, body: '' }
  const res = {
    writeHead(code: number) { state.statusCode = code; return res },
    end(data?: unknown) { state.body = String(data ?? '') },
    setHeader() {},
  } as unknown as RouteContext['res']
  process.nextTick(() => {
    ;(req as unknown as EventEmitter).emit('data', Buffer.from(JSON.stringify(body)))
    ;(req as unknown as EventEmitter).emit('end')
  })
  const handled = await tryHandleKanban({
    req, res, path: '/api/kanban', method: 'POST',
    url: new URL('http://localhost/api/kanban'),
  } as RouteContext)
  expect(handled).toBe(true)
  return { statusCode: state.statusCode || 200, json: state.body ? JSON.parse(state.body) : null }
}

beforeEach(() => { initDatabase(':memory:') })

describe('POST /api/kanban -- project is required', () => {
  it('rejects a card with no project field', async () => {
    const { statusCode, json } = await postCard({ title: 'No project' })
    expect(statusCode).toBe(400)
    expect(json.error).toBeTruthy()
    expect(getKanbanCard(json.id)).toBeFalsy()
  })

  it('rejects a card with an empty-string project', async () => {
    const { statusCode } = await postCard({ title: 'Empty project', project: '  ' })
    expect(statusCode).toBe(400)
  })

  it('creates the card when project is a non-empty string', async () => {
    const { statusCode, json } = await postCard({ title: 'Has project', project: 'VHR5' })
    expect(statusCode).toBe(200)
    expect(getKanbanCard(json.id)?.project).toBe('VHR5')
  })
})

describe('a dashboard "Create cards" tömeges gomb project mezővel bővítve', () => {
  it('sends project="Marveen" (a modell-váltási kártya a saját flotta-eszközünkről szól)', () => {
    const src = readFileSync(join(__dirname, '..', '..', 'web', 'app.js'), 'utf8')
    const idx = src.indexOf("createModelChangeCardsBtn")
    const handlerRegionStart = src.indexOf("fetch('/api/kanban'", idx)
    const handlerRegion = src.slice(handlerRegionStart, handlerRegionStart + 550)
    expect(handlerRegion).toMatch(/project:\s*'Marveen'/)
  })
})
