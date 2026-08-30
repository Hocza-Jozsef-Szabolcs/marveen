// moveKanbanCard bug: a status-change on an archived card left archived_at
// untouched, so the card stayed invisible in every archived_at IS NULL
// listing/dispatch query even after being moved to waiting/planned/in_progress
// (proven incident: 8 done cards needed a manual /unarchive call before an
// assignment sweep could see them).
//
// moveKanbanCard now clears archived_at whenever the target status is not
// 'done' -- a status-change into an active column is itself the un-archive
// signal. Moving an already-archived card to 'done' leaves archived_at
// untouched, and a never-archived card is unaffected either way.

import { describe, it, expect, beforeEach } from 'vitest'
import { initDatabase, createKanbanCard, archiveKanbanCard, moveKanbanCard, getKanbanCard } from '../db.js'

beforeEach(() => {
  initDatabase(':memory:')
})

describe('moveKanbanCard and archived_at', () => {
  it('clears archived_at when an archived card moves to a non-done status', () => {
    createKanbanCard({ id: 'card-a', title: 'Archived, reassigned' })
    archiveKanbanCard('card-a')
    expect(getKanbanCard('card-a')!.archived_at).not.toBeNull()

    const moved = moveKanbanCard('card-a', 'waiting', 0, 'marveen')
    expect(moved).toBe(true)
    expect(getKanbanCard('card-a')!.archived_at).toBeNull()
  })

  it('leaves archived_at untouched when an archived card moves to done', () => {
    createKanbanCard({ id: 'card-b', title: 'Archived, re-closed' })
    archiveKanbanCard('card-b')
    const archivedAt = getKanbanCard('card-b')!.archived_at
    expect(archivedAt).not.toBeNull()

    const moved = moveKanbanCard('card-b', 'done', 0, 'marveen')
    expect(moved).toBe(true)
    expect(getKanbanCard('card-b')!.archived_at).toBe(archivedAt)
  })

  it('leaves archived_at null when a never-archived card moves', () => {
    createKanbanCard({ id: 'card-c', title: 'Never archived' })

    const moved = moveKanbanCard('card-c', 'in_progress', 0, 'marveen')
    expect(moved).toBe(true)
    expect(getKanbanCard('card-c')!.archived_at).toBeNull()
  })
})
