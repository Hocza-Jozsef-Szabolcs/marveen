// Bug (kanban card 666844f2): POST /api/kanban/:cardId/comments performs no
// existence check on cardId before inserting -- kanban_comments.card_id has
// no FOREIGN KEY, so a mistyped/nonexistent id silently accepts the comment
// (200, looks successful) and it never appears on any card. Proven incident
// (2026-08-19, delphi): a five-paragraph analysis was posted to the card's
// human-readable `#<seq>` reference instead of its real id-slug and sat
// invisible for 15+ minutes.
//
// These tests drive the real route handler (tryHandleKanban), the same
// production entry point the dashboard hits, on an in-memory database.

import { describe, it, expect, beforeEach } from 'vitest'
import { EventEmitter } from 'node:events'
import { initDatabase, createKanbanCard, getKanbanComments } from '../db.js'
import { tryHandleKanban } from '../web/routes/kanban.js'
import type { RouteContext } from '../web/routes/types.js'

async function postComment(cardId: string, body: unknown): Promise<{ statusCode: number; json: any }> {
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
    req, res, path: `/api/kanban/${cardId}/comments`, method: 'POST',
    url: new URL(`http://localhost/api/kanban/${cardId}/comments`),
  } as RouteContext)
  expect(handled).toBe(true)
  return { statusCode: state.statusCode || 200, json: state.body ? JSON.parse(state.body) : null }
}

beforeEach(() => { initDatabase(':memory:') })

describe('POST /api/kanban/:cardId/comments -- nonexistent card_id', () => {
  it('returns 404 and does NOT insert a comment for a card that does not exist', async () => {
    const { statusCode, json } = await postComment('does-not-exist', { author: 'marveen', content: 'lost comment' })
    expect(statusCode).toBe(404)
    expect(json.error).toBeTruthy()
    expect(getKanbanComments('does-not-exist')).toHaveLength(0)
  })

  it('still accepts a comment for a card that DOES exist', async () => {
    createKanbanCard({ id: 'real-card', title: 'Real card' })
    const { statusCode, json } = await postComment('real-card', { author: 'marveen', content: 'hello' })
    expect(statusCode).toBe(200)
    expect(json.card_id).toBe('real-card')
    expect(getKanbanComments('real-card')).toHaveLength(1)
  })
})
