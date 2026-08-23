import { describe, it, expect } from 'vitest'
import Database from 'better-sqlite3'
import { readFileSync, mkdtempSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { computeStaleBlockerRefs, type StaleBlockerCardInput } from '../kanban-stale-blocker-refs.js'
import { STALE_BLOCKER_OPEN_CARDS_SQL, STALE_BLOCKER_CLOSED_SEQS_SQL } from '../db.js'

const ROOT = join(__dirname, '..', '..')

// The `updated_at` column is unreliable as an "was this touched" signal (128
// cards share one mass-write timestamp; most affected cards have zero
// comments). This is a DETERMINISTIC, machine-checkable substitute for one
// specific case: an open card whose own text uses blocking language ("blokkol")
// AND references another card by `#<seq>`, where that referenced card is by
// now closed (`done` or archived). Such a card is very likely stale -- its
// stated blocker no longer applies, but nobody moved it.

function card(over: Partial<StaleBlockerCardInput> & { id: string; seq: number }): StaleBlockerCardInput {
  return { title: '', description: null, ...over }
}

describe('computeStaleBlockerRefs', () => {
  it('flags an open card that cites blocking language AND references a now-closed card', () => {
    const openCards = [card({ id: 'A', seq: 10, title: 'feature X', description: 'blokkolva #5-tol' })]
    const closedSeqs = new Set([5])
    const refs = computeStaleBlockerRefs(openCards, closedSeqs, new Map())
    expect(refs).toEqual([{ id: 'A', seq: 10, title: 'feature X', referencedSeq: 5 }])
  })

  it('does NOT flag when the referenced card is still open', () => {
    const openCards = [card({ id: 'A', seq: 10, title: 'feature X', description: 'blokkolva #5-tol' })]
    const closedSeqs = new Set<number>() // #5 not in the closed set
    const refs = computeStaleBlockerRefs(openCards, closedSeqs, new Map())
    expect(refs).toEqual([])
  })

  it('does NOT flag a plain cross-reference without blocking language (avoids false positives)', () => {
    const openCards = [card({ id: 'A', seq: 10, title: 'feature X', description: 'lasd meg #5-öt a részletekért' })]
    const closedSeqs = new Set([5])
    const refs = computeStaleBlockerRefs(openCards, closedSeqs, new Map())
    expect(refs).toEqual([])
  })

  it('does NOT flag blocking language with no card reference at all', () => {
    const openCards = [card({ id: 'A', seq: 10, title: 'feature X', description: 'ez blokkolva van, de nincs megnevezve mi altal' })]
    const closedSeqs = new Set([5])
    const refs = computeStaleBlockerRefs(openCards, closedSeqs, new Map())
    expect(refs).toEqual([])
  })

  it('reads the reference out of a COMMENT, not just title/description', () => {
    const openCards = [card({ id: 'A', seq: 10, title: 'feature X', description: null })]
    const closedSeqs = new Set([5])
    const comments = new Map([['A', ['ez blokkolva volt #5 miatt, de az mar lezart']]])
    const refs = computeStaleBlockerRefs(openCards, closedSeqs, comments)
    expect(refs).toEqual([{ id: 'A', seq: 10, title: 'feature X', referencedSeq: 5 }])
  })

  it('excludes a VHR8-titled card even when the pattern otherwise matches (VHR8 tiltas)', () => {
    const openCards = [card({ id: 'A', seq: 10, title: 'VHR/VHR8: regi hiba', description: 'blokkolva #5-tol' })]
    const closedSeqs = new Set([5])
    const refs = computeStaleBlockerRefs(openCards, closedSeqs, new Map())
    expect(refs).toEqual([])
  })

  it('does not report the same referenced card twice when cited more than once', () => {
    const openCards = [card({ id: 'A', seq: 10, title: 'feature X', description: 'blokkolva #5-tol. Meg mindig #5 a blokkolo.' })]
    const closedSeqs = new Set([5])
    const refs = computeStaleBlockerRefs(openCards, closedSeqs, new Map())
    expect(refs.length).toBe(1)
  })

  it('reports each distinct closed reference once when a card cites more than one', () => {
    const openCards = [card({ id: 'A', seq: 10, title: 'feature X', description: 'blokkolva #5-tol es #6-tol is' })]
    const closedSeqs = new Set([5, 6])
    const refs = computeStaleBlockerRefs(openCards, closedSeqs, new Map())
    expect(refs.map((r) => r.referencedSeq).sort()).toEqual([5, 6])
  })

  it('ignores a self-reference even if it coincides with a closed seq', () => {
    const openCards = [card({ id: 'A', seq: 5, title: 'feature X', description: 'blokkolva #5-tol' })]
    const closedSeqs = new Set([5])
    const refs = computeStaleBlockerRefs(openCards, closedSeqs, new Map())
    expect(refs).toEqual([])
  })

  it('an empty board yields an empty list', () => {
    expect(computeStaleBlockerRefs([], new Set(), new Map())).toEqual([])
  })
})

// The SHIPPED SQL feeding computeStaleBlockerRefs, run against a fixture DB
// with real kanban_cards/kanban_comments tables -- proves the rowid-derived
// `seq`, the open/closed split and the comment join actually work together,
// not just the pure function in isolation.
describe('the shipped SQL feeds computeStaleBlockerRefs correctly', () => {
  function fixtureDb() {
    const dir = mkdtempSync(join(tmpdir(), 'hb-stale-blocker-'))
    const db = new Database(join(dir, 'test.db'))
    db.exec(`CREATE TABLE kanban_cards (
      id TEXT PRIMARY KEY, title TEXT, description TEXT, status TEXT,
      priority TEXT, assignee TEXT, archived_at INTEGER, updated_at INTEGER,
      created_at INTEGER, sort_order INTEGER
    )`)
    db.exec(`CREATE TABLE kanban_comments (
      id INTEGER PRIMARY KEY AUTOINCREMENT, card_id TEXT NOT NULL,
      author TEXT NOT NULL, content TEXT NOT NULL, created_at INTEGER NOT NULL
    )`)
    const ins = db.prepare(
      "INSERT INTO kanban_cards (id,title,description,status,priority,assignee,archived_at,updated_at,created_at,sort_order) VALUES (?,?,?,?,'normal','samu',?,1,1,0)",
    )
    return { dir, db, ins }
  }

  it('flags a stale reference end-to-end and skips a still-open one', () => {
    const { dir, db, ins } = fixtureDb()
    try {
      ins.run('BLOCKER_DONE', 'the old blocker', null, 'done', null) // seq 1
      ins.run('BLOCKER_OPEN', 'still open blocker', null, 'planned', null) // seq 2
      ins.run('CITER1', 'nyitott kartya', 'blokkolva #1-tol', 'planned', null) // seq 3 -> stale
      ins.run('CITER2', 'masik nyitott kartya', 'blokkolva #2-tol', 'planned', null) // seq 4 -> still valid

      const openCards = db.prepare(STALE_BLOCKER_OPEN_CARDS_SQL).all() as StaleBlockerCardInput[]
      const closedSeqs = new Set(
        (db.prepare(STALE_BLOCKER_CLOSED_SEQS_SQL).all() as { seq: number }[]).map((r) => r.seq),
      )
      const refs = computeStaleBlockerRefs(openCards, closedSeqs, new Map())

      expect(refs).toEqual([{ id: 'CITER1', seq: 3, title: 'nyitott kartya', referencedSeq: 1 }])
    } finally {
      db.close()
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('archived (not just done) counts as closed', () => {
    const { dir, db, ins } = fixtureDb()
    try {
      ins.run('ARCHIVED_BLOCKER', 'archived old blocker', null, 'waiting', 999) // seq 1, archived
      ins.run('CITER', 'nyitott kartya', 'blokkolva #1-tol', 'planned', null) // seq 2

      const openCards = db.prepare(STALE_BLOCKER_OPEN_CARDS_SQL).all() as StaleBlockerCardInput[]
      const closedSeqs = new Set(
        (db.prepare(STALE_BLOCKER_CLOSED_SEQS_SQL).all() as { seq: number }[]).map((r) => r.seq),
      )
      const refs = computeStaleBlockerRefs(openCards, closedSeqs, new Map())

      expect(refs).toEqual([{ id: 'CITER', seq: 2, title: 'nyitott kartya', referencedSeq: 1 }])
    } finally {
      db.close()
      rmSync(dir, { recursive: true, force: true })
    }
  })
})

describe('the stale-blocker signal is reused, not re-derived, by its consumers', () => {
  const HEARTBEAT_SRC = readFileSync(join(ROOT, 'src', 'heartbeat.ts'), 'utf-8')
  const ROUTE_SRC = readFileSync(join(ROOT, 'src', 'web', 'routes', 'kanban.ts'), 'utf-8')
  const SCAFFOLD_SRC = readFileSync(join(ROOT, 'src', 'web', 'heartbeat-agent-scaffold.ts'), 'utf-8')

  it('the built-in heartbeat reads it off getHeartbeatKanbanSummary, not its own query', () => {
    expect(HEARTBEAT_SRC).toContain('summary.staleBlockers')
    expect(HEARTBEAT_SRC).not.toMatch(/FROM kanban_cards/i)
  })

  it('the heartbeat-summary API endpoint serves staleBlockers too', () => {
    expect(ROUTE_SRC).toContain('summary.staleBlockers')
  })

  it('the heartbeat agent scaffold documents the field', () => {
    expect(SCAFFOLD_SRC).toContain('staleBlockers')
  })
})
