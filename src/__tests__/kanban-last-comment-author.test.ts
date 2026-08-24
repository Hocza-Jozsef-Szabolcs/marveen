// GET /api/kanban jelenleg NEM adja vissza kártyánként az utolsó komment
// szerzőjét -- csak a labels-t joinolja be (src/web/routes/kanban.ts:109-116).
// Ezért a dashboard "Rám vár" gombja (web/app.js kanbanOwnerBtn) tisztán
// assignee==owner szűrés, nincs benne "utolsó szerző != owner" logika,
// szemben a nalam-all.sh CLI-szkript egyenértékű SQL-jével.
//
// getLastCommentAuthorsForAllCards() a getLabelsForAllCards() mintáját követi:
// egy JOIN/lekérdezés az összes kártyára (N+1 nélkül), Map<card_id, author>
// eredménnyel -- csak azokra a kártyákra van bejegyzés, amiknek van legalább
// egy kommentje, és a legutóbbi (legnagyobb id) komment szerzőjét adja.

import { describe, it, expect, beforeEach } from 'vitest'
import { EventEmitter } from 'node:events'
import { initDatabase, createKanbanCard, addKanbanComment, getLastCommentAuthorsForAllCards } from '../db.js'
import { tryHandleKanban } from '../web/routes/kanban.js'
import type { RouteContext } from '../web/routes/types.js'

beforeEach(() => { initDatabase(':memory:') })

describe('getLastCommentAuthorsForAllCards', () => {
  it('returns nothing for a card with no comments', () => {
    createKanbanCard({ id: 'card-a', title: 'A' })
    expect(getLastCommentAuthorsForAllCards().has('card-a')).toBe(false)
  })

  it('returns the sole author for a card with one comment', () => {
    createKanbanCard({ id: 'card-a', title: 'A' })
    addKanbanComment('card-a', 'akka', 'started')
    expect(getLastCommentAuthorsForAllCards().get('card-a')).toBe('akka')
  })

  it('returns the MOST RECENT author, not the first, when several comments exist', () => {
    createKanbanCard({ id: 'card-a', title: 'A' })
    addKanbanComment('card-a', 'akka', 'started')
    addKanbanComment('card-a', 'marveen', 'question')
    addKanbanComment('card-a', 'akka', 'answered')
    expect(getLastCommentAuthorsForAllCards().get('card-a')).toBe('akka')
  })

  it('keeps cards independent -- one bulk query, correct per-card result', () => {
    createKanbanCard({ id: 'card-a', title: 'A' })
    createKanbanCard({ id: 'card-b', title: 'B' })
    addKanbanComment('card-a', 'akka', 'x')
    addKanbanComment('card-b', 'marveen', 'y')
    const map = getLastCommentAuthorsForAllCards()
    expect(map.get('card-a')).toBe('akka')
    expect(map.get('card-b')).toBe('marveen')
  })
})

async function getKanbanList(): Promise<{ statusCode: number; json: any[] }> {
  const req = new EventEmitter() as unknown as RouteContext['req']
  ;(req as any).headers = {}
  const state = { statusCode: 0, body: '' }
  const res = {
    writeHead(code: number) { state.statusCode = code; return res },
    end(data?: unknown) { state.body = String(data ?? '') },
    setHeader() {},
  } as unknown as RouteContext['res']
  const handled = await tryHandleKanban({
    req, res, path: '/api/kanban', method: 'GET',
    url: new URL('http://localhost/api/kanban'),
  } as RouteContext)
  expect(handled).toBe(true)
  return { statusCode: state.statusCode || 200, json: JSON.parse(state.body) }
}

describe('GET /api/kanban -- last_comment_author', () => {
  it('is null for a card with no comments', async () => {
    createKanbanCard({ id: 'card-a', title: 'A' })
    const { json } = await getKanbanList()
    expect(json.find((c) => c.id === 'card-a').last_comment_author).toBeNull()
  })

  it('is the most recent comment author for a card that has comments', async () => {
    createKanbanCard({ id: 'card-a', title: 'A' })
    addKanbanComment('card-a', 'akka', 'started')
    addKanbanComment('card-a', 'marveen', 'question')
    const { json } = await getKanbanList()
    expect(json.find((c) => c.id === 'card-a').last_comment_author).toBe('marveen')
  })
})
