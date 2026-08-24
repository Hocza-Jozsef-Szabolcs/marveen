import { describe, it, expect } from 'vitest'
import Database from 'better-sqlite3'
import { readFileSync, mkdtempSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { computeUnsentWaitingQuestions, type UnsentQuestionCardInput } from '../kanban-unsent-question.js'
import { UNSENT_QUESTION_WAITING_CARDS_SQL } from '../db.js'

const ROOT = join(__dirname, '..', '..')

function card(over: Partial<UnsentQuestionCardInput> & { id: string }): UnsentQuestionCardInput {
  return { title: '', ...over }
}

describe('computeUnsentWaitingQuestions', () => {
  // Bukas-eloallitas (kartya kikuldetlen-kerdes-vakfolt-20260806, 3. pont):
  // egy waiting+marveen kartya kikuldott kerdes NELKUL -- ennek PIROSAT kell
  // adnia, kulonben az ellenorzo ugyanolyan vak, mint a mai allapot.
  it('flags a waiting+marveen card with NO kikuldve-marker comment (the reproduced bug)', () => {
    const cards = [card({ id: 'arfolyamnullajelzes', title: 'arfolyam nulla jelzes' })]
    const refs = computeUnsentWaitingQuestions(cards, new Map())
    expect(refs).toEqual([{ id: 'arfolyamnullajelzes', title: 'arfolyam nulla jelzes' }])
  })

  it('does NOT flag when a comment records the send with a {X} sequence number', () => {
    const cards = [card({ id: 'A', title: 'X' })]
    const comments = new Map([['A', ['KIKULDVE: {602}']]])
    const refs = computeUnsentWaitingQuestions(cards, comments)
    expect(refs).toEqual([])
  })

  it('does NOT flag a bare "kikuldve" with no {X} reference (unverifiable claim)', () => {
    const cards = [card({ id: 'A', title: 'X' })]
    const comments = new Map([['A', ['kikuldve, mar elment']]])
    const refs = computeUnsentWaitingQuestions(cards, comments)
    expect(refs).toEqual([{ id: 'A', title: 'X' }])
  })

  it('accepts "elkuldve" as an equivalent marker verb', () => {
    const cards = [card({ id: 'A', title: 'X' })]
    const comments = new Map([['A', ['elkuldve a {604}-es listaban']]])
    const refs = computeUnsentWaitingQuestions(cards, comments)
    expect(refs).toEqual([])
  })

  it('reads the marker out of any comment, not just the last one', () => {
    const cards = [card({ id: 'A', title: 'X' })]
    const comments = new Map([['A', ['meg nem ment ki', 'KIKULDVE: {600}', 'utana meg valasz varva']]])
    const refs = computeUnsentWaitingQuestions(cards, comments)
    expect(refs).toEqual([])
  })

  it('excludes a VHR8-titled card even with no marker (VHR8 tiltas)', () => {
    const cards = [card({ id: 'A', title: 'VHR8: regi hiba' })]
    const refs = computeUnsentWaitingQuestions(cards, new Map())
    expect(refs).toEqual([])
  })

  it('an empty board yields an empty list', () => {
    expect(computeUnsentWaitingQuestions([], new Map())).toEqual([])
  })
})

// The SHIPPED SQL feeding computeUnsentWaitingQuestions, run against a fixture
// DB with real kanban_cards/kanban_comments tables.
describe('the shipped SQL feeds computeUnsentWaitingQuestions correctly', () => {
  function fixtureDb() {
    const dir = mkdtempSync(join(tmpdir(), 'hb-unsent-question-'))
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
      "INSERT INTO kanban_cards (id,title,description,status,priority,assignee,archived_at,updated_at,created_at,sort_order) VALUES (?,?,?,?,'normal',?,?,1,1,0)",
    )
    return { dir, db, ins }
  }

  it('flags a waiting+marveen card with no marker and skips a marked one end-to-end', () => {
    const { dir, db, ins } = fixtureDb()
    try {
      ins.run('UNSENT', 'nincs kikuldve', null, 'waiting', 'marveen', null)
      ins.run('SENT', 'ki lett kuldve', null, 'waiting', 'marveen', null)
      db.prepare("INSERT INTO kanban_comments (card_id, author, content, created_at) VALUES ('SENT','marveen','KIKULDVE: {600}',1)").run()

      const cards = db.prepare(UNSENT_QUESTION_WAITING_CARDS_SQL).all() as UnsentQuestionCardInput[]
      const commentRows = db.prepare('SELECT card_id, content FROM kanban_comments').all() as { card_id: string; content: string }[]
      const commentsByCardId = new Map<string, string[]>()
      for (const row of commentRows) {
        const arr = commentsByCardId.get(row.card_id) ?? []
        arr.push(row.content)
        commentsByCardId.set(row.card_id, arr)
      }

      const refs = computeUnsentWaitingQuestions(cards, commentsByCardId)
      expect(refs).toEqual([{ id: 'UNSENT', title: 'nincs kikuldve' }])
    } finally {
      db.close()
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('excludes a waiting card NOT assigned to marveen (another fej own escalation)', () => {
    const { dir, db, ins } = fixtureDb()
    try {
      ins.run('OTHER', 'mas fejre var', null, 'waiting', 'delphi', null)

      const cards = db.prepare(UNSENT_QUESTION_WAITING_CARDS_SQL).all() as UnsentQuestionCardInput[]
      expect(cards).toEqual([])
    } finally {
      db.close()
      rmSync(dir, { recursive: true, force: true })
    }
  })

  // Meresi lelet (2026-08-24): az elo tablan 'marveen' ES 'Marveen' is elofordul
  // waiting kartyan, es 'jozsi' assignee is -- mindharom a "Jozsi dontesere var"
  // esetet jeloli, egy csak kisbetus/csak 'marveen' szuro csendben kihagyna oket.
  it('includes a capitalized "Marveen" assignee and a direct "jozsi" assignee (case + owner variants)', () => {
    const { dir, db, ins } = fixtureDb()
    try {
      ins.run('CAP', 'Marveen nagybetuvel', null, 'waiting', 'Marveen', null)
      ins.run('JOZSI', 'kozvetlenul jozsira bizva', null, 'waiting', 'jozsi', null)

      const cards = db.prepare(UNSENT_QUESTION_WAITING_CARDS_SQL).all() as UnsentQuestionCardInput[]
      expect(cards.map((c) => c.id).sort()).toEqual(['CAP', 'JOZSI'])
    } finally {
      db.close()
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('excludes an archived or non-waiting marveen card', () => {
    const { dir, db, ins } = fixtureDb()
    try {
      ins.run('ARCHIVED', 'archivalt', null, 'waiting', 'marveen', 999)
      ins.run('DONE', 'kesz', null, 'done', 'marveen', null)

      const cards = db.prepare(UNSENT_QUESTION_WAITING_CARDS_SQL).all() as UnsentQuestionCardInput[]
      expect(cards).toEqual([])
    } finally {
      db.close()
      rmSync(dir, { recursive: true, force: true })
    }
  })
})

describe('the unsent-question signal is reused, not re-derived, by its consumers', () => {
  const HEARTBEAT_SRC = readFileSync(join(ROOT, 'src', 'heartbeat.ts'), 'utf-8')
  const ROUTE_SRC = readFileSync(join(ROOT, 'src', 'web', 'routes', 'kanban.ts'), 'utf-8')
  const SCAFFOLD_SRC = readFileSync(join(ROOT, 'src', 'web', 'heartbeat-agent-scaffold.ts'), 'utf-8')

  it('the built-in heartbeat reads it off getHeartbeatKanbanSummary, not its own query', () => {
    expect(HEARTBEAT_SRC).toContain('summary.unsentQuestions')
  })

  it('the heartbeat-summary API endpoint serves unsentQuestions too', () => {
    expect(ROUTE_SRC).toContain('summary.unsentQuestions')
  })

  it('the heartbeat agent scaffold documents the field', () => {
    expect(SCAFFOLD_SRC).toContain('unsentQuestions')
  })
})
