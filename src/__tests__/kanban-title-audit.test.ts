// Contract tests for the kanban card TITLE-change audit trail.
//
// updateKanbanCard records a kanban_card_events row (event_type='title')
// whenever the title actually changes value -- who overwrote it, when, old/new
// title. An update that omits title, or sets it to the same value, records
// nothing. Status-change events (event_type='status', written by
// moveKanbanCard) stay untouched by this path -- see kanban-move-audit.test.ts.
//
// These tests call the real production entry points (updateKanbanCard,
// moveKanbanCard, getKanbanCardEvents) on an in-memory database seeded with
// the production schema, the same way the other kanban db tests do.

import { describe, it, expect, beforeEach } from 'vitest'
import { initDatabase, createKanbanCard, updateKanbanCard, moveKanbanCard, getKanbanCardEvents } from '../db.js'

beforeEach(() => {
  // Re-init with an in-memory database for isolation.
  initDatabase(':memory:')
})

describe('kanban title-change audit trail', () => {
  it('records exactly one title event with old/new title and actor on a real title change', () => {
    createKanbanCard({ id: 'card-t1', title: 'Eredeti cím' })

    const updated = updateKanbanCard('card-t1', { title: 'Új cím' }, 'marveen')
    expect(updated).toBe(true)

    const events = getKanbanCardEvents('card-t1')
    expect(events).toHaveLength(1)
    expect(events[0].event_type).toBe('title')
    expect(events[0].old_title).toBe('Eredeti cím')
    expect(events[0].new_title).toBe('Új cím')
    expect(events[0].actor).toBe('marveen')
    expect(events[0].from_status).toBeNull()
    expect(events[0].to_status).toBeNull()
  })

  it('records no event when the title is unchanged', () => {
    createKanbanCard({ id: 'card-t2', title: 'Változatlan' })

    updateKanbanCard('card-t2', { title: 'Változatlan', priority: 'high' }, 'marveen')
    expect(getKanbanCardEvents('card-t2')).toHaveLength(0)
  })

  it('records no event when the update does not touch the title', () => {
    createKanbanCard({ id: 'card-t3', title: 'Marad' })

    updateKanbanCard('card-t3', { priority: 'urgent' }, 'marveen')
    expect(getKanbanCardEvents('card-t3')).toHaveLength(0)
  })

  it('leaves actor null when none is supplied (backward-compatible callers)', () => {
    createKanbanCard({ id: 'card-t4', title: 'Régi' })

    const updated = updateKanbanCard('card-t4', { title: 'Friss' })
    expect(updated).toBe(true)

    const events = getKanbanCardEvents('card-t4')
    expect(events).toHaveLength(1)
    expect(events[0].actor).toBeNull()
  })

  it('records no event when no card matches', () => {
    const updated = updateKanbanCard('nonexistent-card', { title: 'X' }, 'marveen')
    expect(updated).toBe(false)
    expect(getKanbanCardEvents('nonexistent-card')).toHaveLength(0)
  })

  it('keeps status events (event_type=status) and title events (event_type=title) distinguishable in one timeline', () => {
    createKanbanCard({ id: 'card-t5', title: 'Vegyes' })

    moveKanbanCard('card-t5', 'in_progress', 0, 'marveen')
    updateKanbanCard('card-t5', { title: 'Vegyes 2' }, 'marveen')

    const events = getKanbanCardEvents('card-t5')
    expect(events).toHaveLength(2)
    expect(events[0].event_type).toBe('status')
    expect(events[0].to_status).toBe('in_progress')
    expect(events[0].old_title).toBeNull()
    expect(events[0].new_title).toBeNull()
    expect(events[1].event_type).toBe('title')
    expect(events[1].old_title).toBe('Vegyes')
    expect(events[1].new_title).toBe('Vegyes 2')
    expect(events[1].from_status).toBeNull()
    expect(events[1].to_status).toBeNull()
  })
})
