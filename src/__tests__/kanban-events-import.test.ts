// Contract tests for importKanbanCardEvent -- the fleet-backup restore path for
// kanban_card_events. A backup contains BOTH status-change and title-change
// events (see kanban-move-audit.test.ts / kanban-title-audit.test.ts for how
// they get written in the first place); restore must not silently drop either
// kind, and must stay idempotent across repeated imports of the same backup.

import { describe, it, expect, beforeEach } from 'vitest'
import { initDatabase, createKanbanCard, importKanbanCardEvent, getKanbanCardEvents } from '../db.js'

beforeEach(() => {
  initDatabase(':memory:')
})

describe('importKanbanCardEvent', () => {
  it('imports a status event (event_type omitted defaults to status, like pre-#? exports)', () => {
    createKanbanCard({ id: 'card-i1', title: 'Card' })

    importKanbanCardEvent({ card_id: 'card-i1', from_status: 'planned', to_status: 'in_progress', actor: 'marveen', created_at: 1000 })

    const events = getKanbanCardEvents('card-i1')
    expect(events).toHaveLength(1)
    expect(events[0].event_type).toBe('status')
    expect(events[0].from_status).toBe('planned')
    expect(events[0].to_status).toBe('in_progress')
  })

  it('imports a title event', () => {
    createKanbanCard({ id: 'card-i2', title: 'Card' })

    importKanbanCardEvent({ card_id: 'card-i2', event_type: 'title', old_title: 'Régi', new_title: 'Új', actor: 'marveen', created_at: 1000 })

    const events = getKanbanCardEvents('card-i2')
    expect(events).toHaveLength(1)
    expect(events[0].event_type).toBe('title')
    expect(events[0].old_title).toBe('Régi')
    expect(events[0].new_title).toBe('Új')
  })

  it('skips an event with no card_id', () => {
    importKanbanCardEvent({ card_id: '', to_status: 'done', created_at: 1000 } as any)
    expect(getKanbanCardEvents('')).toHaveLength(0)
  })

  it('skips a status-type event with no to_status', () => {
    createKanbanCard({ id: 'card-i3', title: 'Card' })
    importKanbanCardEvent({ card_id: 'card-i3', created_at: 1000 })
    expect(getKanbanCardEvents('card-i3')).toHaveLength(0)
  })

  it('skips a title-type event with no new_title', () => {
    createKanbanCard({ id: 'card-i4', title: 'Card' })
    importKanbanCardEvent({ card_id: 'card-i4', event_type: 'title', created_at: 1000 })
    expect(getKanbanCardEvents('card-i4')).toHaveLength(0)
  })

  it('is idempotent: importing the same event twice records it once', () => {
    createKanbanCard({ id: 'card-i5', title: 'Card' })
    const ev = { card_id: 'card-i5', from_status: 'planned', to_status: 'waiting', actor: 'marveen', created_at: 2000 }

    importKanbanCardEvent(ev)
    importKanbanCardEvent(ev)

    expect(getKanbanCardEvents('card-i5')).toHaveLength(1)
  })

  it('does not conflate a status event and a title event that share card_id and created_at', () => {
    createKanbanCard({ id: 'card-i6', title: 'Card' })
    const ts = 3000

    importKanbanCardEvent({ card_id: 'card-i6', from_status: 'planned', to_status: 'in_progress', created_at: ts })
    importKanbanCardEvent({ card_id: 'card-i6', event_type: 'title', old_title: 'A', new_title: 'B', created_at: ts })

    expect(getKanbanCardEvents('card-i6')).toHaveLength(2)
  })
})
