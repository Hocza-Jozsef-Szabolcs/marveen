// Contract test (kanban-project-mezo-226-kartyan-ures-20260808, comment 414):
// the dashboard's assignee- and parent-editors PUT `{ ...card, <field>: newVal }`
// to /api/kanban/:id. updateKanbanCard's merge is "the sent field wins, the
// rest reload fresh from the row" -- so a caller sending the FULL card object
// back overwrites every other column with whatever the browser's (possibly
// stale) in-memory copy holds. If another agent moved/edited the card in the
// minutes between page-load and this PUT, that change is silently reverted,
// with no error and no audit trail (a plain UPDATE, not a status transition).
//
// Fix: send only the field that actually changed.

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const __dirname = dirname(fileURLToPath(import.meta.url))
const appJsPath = join(__dirname, '..', '..', 'web', 'app.js')
const src = readFileSync(appJsPath, 'utf8')

describe('kanban inline editors must not PUT the full (possibly stale) card object', () => {
  it('the assignee editor sends only the changed field', () => {
    expect(src).not.toMatch(/body:\s*JSON\.stringify\(\{\s*\.\.\.card,\s*assignee:/)
  })

  it('the parent_id editor sends only the changed field', () => {
    expect(src).not.toMatch(/body:\s*JSON\.stringify\(\{\s*\.\.\.card,\s*parent_id:/)
  })

  it('no JSON.stringify body anywhere in the file spreads the in-memory card object', () => {
    // Broad guard: any future inline editor written the same way would
    // reproduce this bug -- not just the two measured call sites above.
    expect(src).not.toMatch(/JSON\.stringify\(\{\s*\.\.\.card,/)
  })
})
