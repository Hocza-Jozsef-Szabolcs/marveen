// Bug (kanban card kanbanpostidhazug): POST /api/kanban generates a random id,
// then merges it with `{ id, ...data }` -- if the caller's body also carries
// an `id` field (the normal way slug-style card ids like "delphi-fix-20260811"
// get created), the spread silently overwrites the generated id in the stored
// record, but the JSON response still echoes the discarded, never-stored
// generated id. A caller who trusts the response `id` (PUT/comment/move on the
// next call) silently targets a card that doesn't exist.
//
// Proven twice independently (2026-08-20): a caller-supplied id
// ("test-echo-delete-me") was stored correctly, but the response reported a
// different, random id that matches no row.
//
// These tests drive the real route handler (tryHandleKanban), the same
// production entry point the dashboard hits, on an in-memory database.

import { describe, it, expect, beforeEach } from 'vitest'
import { EventEmitter } from 'node:events'
import { initDatabase, getKanbanCard } from '../db.js'
import { tryHandleKanban } from '../web/routes/kanban.js'
import type { RouteContext } from '../web/routes/types.js'

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

describe('POST /api/kanban -- response id must match the stored id', () => {
  it('echoes the caller-supplied id when the body carries one', async () => {
    const { json } = await postCard({ id: 'test-echo-delete-me', title: 'Echo test' })
    expect(json.id).toBe('test-echo-delete-me')
    expect(getKanbanCard('test-echo-delete-me')).toBeTruthy()
    expect(getKanbanCard(json.id)).toBeTruthy()
  })

  it('generates and echoes a random id when the body carries none', async () => {
    const { json } = await postCard({ title: 'No id supplied' })
    expect(json.id).toBeTruthy()
    expect(getKanbanCard(json.id)).toBeTruthy()
    expect(getKanbanCard(json.id)!.title).toBe('No id supplied')
  })
})
