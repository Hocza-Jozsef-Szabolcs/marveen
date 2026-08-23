// Contract tests for the PUT /api/kanban/:id status-change audit gap
// (kanban-project-mezo-226-kartyan-ures-20260808, comment 412/414):
// moveKanbanCard already writes a kanban_card_events row on every real
// status transition, but updateKanbanCard (the PUT /api/kanban/:id entry
// point) accepts `status` in its field list and never logged it -- a
// status change made through PUT left no audit trail.
//
// updateKanbanCard now records the same kind of event as moveKanbanCard
// when the fields it is given include a real status transition.

import { describe, it, expect, beforeEach } from 'vitest'
import { initDatabase, createKanbanCard, updateKanbanCard, getKanbanCardEvents, getKanbanCard } from '../db.js'

beforeEach(() => {
  initDatabase(':memory:')
})

describe('updateKanbanCard status audit trail', () => {
  it('records an event with correct from/to status and actor on a status change via PUT', () => {
    createKanbanCard({ id: 'card-a', title: 'PUT-audited card' })

    const ok = updateKanbanCard('card-a', { status: 'in_progress' }, 'marveen')
    expect(ok).toBe(true)

    const events = getKanbanCardEvents('card-a')
    expect(events).toHaveLength(1)
    expect(events[0].from_status).toBe('planned')
    expect(events[0].to_status).toBe('in_progress')
    expect(events[0].actor).toBe('marveen')
  })

  it('records no event when status is unchanged', () => {
    createKanbanCard({ id: 'card-b', title: 'Same status' })

    const ok = updateKanbanCard('card-b', { status: 'planned', priority: 'high' })
    expect(ok).toBe(true)
    expect(getKanbanCardEvents('card-b')).toHaveLength(0)
  })

  it('records no event when status is not part of the update at all', () => {
    createKanbanCard({ id: 'card-c', title: 'Non-status field only' })

    const ok = updateKanbanCard('card-c', { priority: 'urgent' })
    expect(ok).toBe(true)
    expect(getKanbanCardEvents('card-c')).toHaveLength(0)
  })

  it('leaves actor null when none is supplied', () => {
    createKanbanCard({ id: 'card-d', title: 'No actor' })

    updateKanbanCard('card-d', { status: 'waiting' })
    const events = getKanbanCardEvents('card-d')
    expect(events).toHaveLength(1)
    expect(events[0].actor).toBeNull()
  })

  it('a bare field update still merges onto the fresh row (no lost-update regression)', () => {
    createKanbanCard({ id: 'card-e', title: 'Merge check', assignee: 'akka' })
    updateKanbanCard('card-e', { priority: 'high' })

    // Sending only the changed field must not blank out assignee -- this is
    // the invariant the client-side fix (web/app.js) now relies on.
    expect(getKanbanCard('card-e')?.assignee).toBe('akka')
    expect(getKanbanCard('card-e')?.priority).toBe('high')
    expect(getKanbanCardEvents('card-e')).toHaveLength(0)
  })
})
