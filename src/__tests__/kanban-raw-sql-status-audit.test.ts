// Contract tests for the kanban status-change audit trail's third write path
// (kanban-statusz-valtas-nyomtalanul-megkerulheto-20260814, comment 1339/2556):
// moveKanbanCard and updateKanbanCard both record a kanban_card_events row on
// a real status transition, but a raw SQL UPDATE against kanban_cards --
// bypassing both entry points entirely -- left no trace at all. This is the
// write path that actually fired twice on the day the card was opened (a
// direct SQL revert, and a design agent's nine direct status writes).
//
// The fix is a DB-level trigger (AFTER UPDATE OF status ON kanban_cards),
// so the audit trail cannot be bypassed by *any* write path, including ones
// the application code doesn't know about yet. moveKanbanCard and
// updateKanbanCard no longer INSERT the event row themselves -- they hand
// the actor to the trigger via a one-row context table, cleared right after
// the UPDATE runs, so the trigger fires exactly once per real transition
// regardless of which path performed it.

import { describe, it, expect, beforeEach } from 'vitest'
import { initDatabase, createKanbanCard, moveKanbanCard, updateKanbanCard, getKanbanCardEvents, getDb } from '../db.js'

beforeEach(() => {
  initDatabase(':memory:')
})

describe('kanban status audit trail -- raw SQL write path', () => {
  it('records an event when kanban_cards.status is changed by raw SQL, bypassing moveKanbanCard/updateKanbanCard', () => {
    createKanbanCard({ id: 'card-a', title: 'Bypassed card' })

    getDb().prepare('UPDATE kanban_cards SET status = ? WHERE id = ?').run('waiting', 'card-a')

    const events = getKanbanCardEvents('card-a')
    expect(events).toHaveLength(1)
    expect(events[0].from_status).toBe('planned')
    expect(events[0].to_status).toBe('waiting')
    expect(events[0].actor).toBeNull()
  })

  it('records no event when raw SQL changes a non-status column', () => {
    createKanbanCard({ id: 'card-b', title: 'Reordered by raw SQL' })

    getDb().prepare('UPDATE kanban_cards SET sort_order = ? WHERE id = ?').run(9, 'card-b')

    expect(getKanbanCardEvents('card-b')).toHaveLength(0)
  })

  it('records no event when raw SQL sets status to the same value it already had', () => {
    createKanbanCard({ id: 'card-c', title: 'No-op raw SQL' })

    getDb().prepare('UPDATE kanban_cards SET status = ? WHERE id = ?').run('planned', 'card-c')

    expect(getKanbanCardEvents('card-c')).toHaveLength(0)
  })

  it('does not leak an actor from a prior moveKanbanCard call into a later raw SQL write', () => {
    createKanbanCard({ id: 'card-d', title: 'Actor leak check' })

    moveKanbanCard('card-d', 'in_progress', 0, 'marveen')
    getDb().prepare('UPDATE kanban_cards SET status = ? WHERE id = ?').run('waiting', 'card-d')

    const events = getKanbanCardEvents('card-d')
    expect(events).toHaveLength(2)
    expect(events[0].actor).toBe('marveen')
    expect(events[1].actor).toBeNull()
  })

  it('does not double-write when moveKanbanCard performs the status change (single source of truth)', () => {
    createKanbanCard({ id: 'card-e', title: 'Single event via move' })

    moveKanbanCard('card-e', 'in_progress', 0, 'marveen')

    expect(getKanbanCardEvents('card-e')).toHaveLength(1)
  })

  it('does not double-write when updateKanbanCard performs the status change (single source of truth)', () => {
    createKanbanCard({ id: 'card-f', title: 'Single event via PUT' })

    updateKanbanCard('card-f', { status: 'in_progress' }, 'marveen')

    const events = getKanbanCardEvents('card-f')
    expect(events).toHaveLength(1)
    expect(events[0].actor).toBe('marveen')
  })
})
