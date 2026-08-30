import { describe, it, expect } from 'vitest'
import Database from 'better-sqlite3'
import { readFileSync, mkdtempSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { HEARTBEAT_WAITING_SQL, type KanbanCard, type HeartbeatKanbanSummary } from '../db.js'
import {
  capHeartbeatWaitingList,
  buildHeartbeatSummaryResponse,
  HEARTBEAT_SUMMARY_WAITING_CAP,
} from '../web/routes/kanban.js'

// Measured 2026-08-30 on the live board (card fc704252): 80 waiting cards,
// only 48 distinct updated_at values, largest tie group 7 -- capping a list
// by updated_at picks an ARBITRARY subset within a tie. `seq` (the SQLite
// rowid, monotonic and never reused) breaks every tie the same way every
// time. See also a1408ae: updated_at is a bulk write-timestamp on this
// board, not an activity signal (128 cards once shared one value).

const ROOT = join(__dirname, '..', '..')

function waitingCard(id: string, seq: number, updated_at: number): KanbanCard & { seq: number } {
  return {
    id, seq, title: `card-${id}`, description: null, status: 'waiting', assignee: 'samu',
    priority: 'normal', project: null, parent_id: null, due_date: null, sort_order: 0,
    created_at: 1, updated_at, archived_at: null, dispatched_at: null,
  }
}

describe('capHeartbeatWaitingList: deterministic tie-break, not updated_at', () => {
  it('every card sharing the SAME updated_at still yields a stable, deterministic top-N by seq', () => {
    // 10 cards, all identical updated_at (the tie group), seq handed in shuffled order.
    const cards = [5, 1, 9, 3, 7, 2, 8, 4, 6, 10].map((seq) => waitingCard(`C${seq}`, seq, 1000))
    const expectedIds = ['C10', 'C9', 'C8', 'C7', 'C6', 'C5', 'C4', 'C3'].slice(0, HEARTBEAT_SUMMARY_WAITING_CAP)

    const first = capHeartbeatWaitingList(cards).map((c) => c.id)
    const second = capHeartbeatWaitingList([...cards].reverse()).map((c) => c.id)

    expect(first).toEqual(expectedIds)
    // Order-independent: feeding the same set in a different array order must
    // not change the result -- a naive "first N in array order" bug would fail this.
    expect(second).toEqual(expectedIds)
  })

  it('ignores updated_at entirely -- the field with the ties never decides the outcome', () => {
    // seq ascending 1..5, but updated_at DESCENDING (i.e. updated_at ranks them
    // in the opposite order from seq). If the cap were still driven by
    // updated_at, card A1 (highest updated_at) would win; by seq, A5 must win.
    const cards = [1, 2, 3, 4, 5].map((seq) => waitingCard(`A${seq}`, seq, 100 - seq))

    const result = capHeartbeatWaitingList(cards).map((c) => c.id)

    expect(result[0]).toBe('A5')
    expect(result).toEqual(['A5', 'A4', 'A3', 'A2', 'A1'])
  })

  it('caps to HEARTBEAT_SUMMARY_WAITING_CAP and passes a shorter list through untouched', () => {
    const many = Array.from({ length: HEARTBEAT_SUMMARY_WAITING_CAP + 5 }, (_, i) => waitingCard(`W${i}`, i, 1))
    expect(capHeartbeatWaitingList(many)).toHaveLength(HEARTBEAT_SUMMARY_WAITING_CAP)

    const few = [waitingCard('ONE', 1, 1), waitingCard('TWO', 2, 1)]
    expect(capHeartbeatWaitingList(few)).toHaveLength(2)
  })
})

describe('HEARTBEAT_WAITING_SQL now supplies the seq that the cap sorts on', () => {
  function fixtureDb() {
    const dir = mkdtempSync(join(tmpdir(), 'hb-waitcap-'))
    const db = new Database(join(dir, 'test.db'))
    db.exec(`CREATE TABLE kanban_cards (
      id TEXT PRIMARY KEY, title TEXT, status TEXT, priority TEXT,
      assignee TEXT, archived_at INTEGER, updated_at INTEGER, created_at INTEGER, sort_order INTEGER
    )`)
    const ins = db.prepare(
      "INSERT INTO kanban_cards (id,title,status,priority,assignee,archived_at,updated_at,created_at,sort_order) VALUES (?,?,?,?,?,?,?,?,0)",
    )
    return { dir, db, ins }
  }

  it('every returned row carries a distinct seq even when updated_at is identical for all of them', () => {
    const { dir, db, ins } = fixtureDb()
    try {
      for (let i = 0; i < 7; i++) ins.run(`T${i}`, 'tied card', 'waiting', 'normal', 'samu', null, 555, 1)

      const rows = db.prepare(HEARTBEAT_WAITING_SQL).all() as { id: string; seq: number; updated_at: number }[]

      expect(rows).toHaveLength(7)
      expect(new Set(rows.map((r) => r.updated_at)).size).toBe(1) // confirms the tie is real
      expect(new Set(rows.map((r) => r.seq)).size).toBe(7) // seq still distinguishes every row
    } finally {
      db.close()
      rmSync(dir, { recursive: true, force: true })
    }
  })
})

function summaryFixture(waitingCount: number, staleCount: number, unsentCount: number): HeartbeatKanbanSummary {
  return {
    urgent: [waitingCard('U1', 1, 1)],
    in_progress: [],
    waiting: Array.from({ length: waitingCount }, (_, i) => waitingCard(`W${i}`, i, 1)),
    staleBlockers: Array.from({ length: staleCount }, (_, i) => ({ id: `S${i}`, seq: i, title: `stale-${i}`, referencedSeq: 1 })),
    unsentQuestions: Array.from({ length: unsentCount }, (_, i) => ({ id: `Q${i}`, title: `unsent-${i}` })),
  }
}

describe('buildHeartbeatSummaryResponse: counts-first, capped waiting, uncapped stale/unsent', () => {
  it('counts is the first key (JSON.stringify preserves insertion order)', () => {
    const response = buildHeartbeatSummaryResponse(summaryFixture(3, 2, 2))
    expect(Object.keys(response)[0]).toBe('counts')
  })

  it('counts.waiting is the FULL total, the waiting list is capped', () => {
    const total = HEARTBEAT_SUMMARY_WAITING_CAP + 12
    const response = buildHeartbeatSummaryResponse(summaryFixture(total, 0, 0))
    expect(response.counts.waiting).toBe(total)
    expect(response.waiting).toHaveLength(HEARTBEAT_SUMMARY_WAITING_CAP)
  })

  it('staleBlockers and unsentQuestions appear FULL, uncapped, unchanged by the waiting cap', () => {
    const response = buildHeartbeatSummaryResponse(summaryFixture(3, 22, 22))
    expect(response.staleBlockers).toHaveLength(22)
    expect(response.unsentQuestions).toHaveLength(22)
    expect(response.counts.staleBlockers).toBe(22)
    expect(response.counts.unsentQuestions).toBe(22)
  })
})

describe('the route serves buildHeartbeatSummaryResponse over getHeartbeatKanbanSummary()', () => {
  const ROUTE_SRC = readFileSync(join(ROOT, 'src', 'web', 'routes', 'kanban.ts'), 'utf-8')

  it('still calls getHeartbeatKanbanSummary() as the one shared definition', () => {
    expect(ROUTE_SRC).toContain('getHeartbeatKanbanSummary()')
  })

  it('still reads staleBlockers/unsentQuestions off the summary, not a re-derived query', () => {
    expect(ROUTE_SRC).toContain('summary.staleBlockers')
    expect(ROUTE_SRC).toContain('summary.unsentQuestions')
  })
})
