// Contract tests (kanban-project-mezo-226-kartyan-ures-20260808, comment 410/412,
// requirement (c)): a card cannot enter 'done' without at least one comment on
// it -- a closing comment is the only point where "what's left" information
// is ever recorded. Enforced on BOTH endpoints that can set status: POST
// /api/kanban/:id/move and PUT /api/kanban/:id.
//
// These tests drive the real route handler (tryHandleKanban), the same
// production entry point the dashboard hits, on an in-memory database.

import { describe, it, expect, beforeEach } from 'vitest'
import { EventEmitter } from 'node:events'
import { initDatabase, createKanbanCard, addKanbanComment, getKanbanCard } from '../db.js'
import { tryHandleKanban } from '../web/routes/kanban.js'
import type { RouteContext } from '../web/routes/types.js'

async function call(method: string, path: string, body: unknown): Promise<{ statusCode: number; json: any }> {
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
    req, res, path, method,
    url: new URL('http://localhost' + path),
  } as RouteContext)
  expect(handled).toBe(true)
  return { statusCode: state.statusCode || 200, json: state.body ? JSON.parse(state.body) : null }
}

beforeEach(() => { initDatabase(':memory:') })

describe('POST /api/kanban/:id/move -- done requires a closing comment', () => {
  it('rejects a move to done when the card has zero comments', async () => {
    createKanbanCard({ id: 'card-a', title: 'No comment', status: 'in_progress' })

    const { statusCode, json } = await call('POST', '/api/kanban/card-a/move', { status: 'done', sort_order: 0 })
    expect(statusCode).toBe(400)
    expect(json.error).toBeTruthy()
    expect(getKanbanCard('card-a')?.status).toBe('in_progress')
  })

  it('allows a move to done when the card has at least one comment', async () => {
    createKanbanCard({ id: 'card-b', title: 'Has comment', status: 'in_progress' })
    addKanbanComment('card-b', 'backend', 'Kész, lásd a commitot.')

    const { statusCode } = await call('POST', '/api/kanban/card-b/move', { status: 'done', sort_order: 0 })
    expect(statusCode).toBe(200)
    expect(getKanbanCard('card-b')?.status).toBe('done')
  })

  it('does not gate moves to a non-done status', async () => {
    createKanbanCard({ id: 'card-c', title: 'No comment, not done', status: 'planned' })

    const { statusCode } = await call('POST', '/api/kanban/card-c/move', { status: 'in_progress', sort_order: 0 })
    expect(statusCode).toBe(200)
    expect(getKanbanCard('card-c')?.status).toBe('in_progress')
  })

  it('reports not-found (not the comment error) for a nonexistent card', async () => {
    const { statusCode, json } = await call('POST', '/api/kanban/nope/move', { status: 'done', sort_order: 0 })
    expect(statusCode).toBe(404)
    expect(json.error).toBe('Kártya nem található')
  })
})

describe('PUT /api/kanban/:id -- done requires a closing comment', () => {
  it('rejects a status update to done when the card has zero comments', async () => {
    createKanbanCard({ id: 'card-d', title: 'No comment', status: 'in_progress' })

    const { statusCode } = await call('PUT', '/api/kanban/card-d', { status: 'done' })
    expect(statusCode).toBe(400)
    expect(getKanbanCard('card-d')?.status).toBe('in_progress')
  })

  it('allows a status update to done when the card has at least one comment', async () => {
    createKanbanCard({ id: 'card-e', title: 'Has comment', status: 'in_progress' })
    addKanbanComment('card-e', 'backend', 'Kész.')

    const { statusCode } = await call('PUT', '/api/kanban/card-e', { status: 'done' })
    expect(statusCode).toBe(200)
    expect(getKanbanCard('card-e')?.status).toBe('done')
  })

  it('does not gate a PUT that leaves status untouched', async () => {
    createKanbanCard({ id: 'card-f', title: 'No comment, no status change', status: 'planned' })

    const { statusCode } = await call('PUT', '/api/kanban/card-f', { priority: 'high' })
    expect(statusCode).toBe(200)
    expect(getKanbanCard('card-f')?.priority).toBe('high')
  })
})
