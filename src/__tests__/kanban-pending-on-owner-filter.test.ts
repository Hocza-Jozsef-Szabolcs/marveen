// Uj "Fuggosegek" dashboard-szuro: a meglevo "Ram var" gomb (kanbanOwnerBtn,
// web/app.js) tisztan assignee==owner szures, barmely statuszra -- NINCS benne
// "utolso komment szerzoje != owner" logika, szemben a nalam-all.sh CLI-szkript
// egyenertku SQL-jevel. A dashboardon ezert az in_progress kartyakon hagyott
// mas-fej kommentek (pl. akka printer-reconnect) csak a kartyara kattintva
// latszanak.
//
// cardIsPendingOnOwner(card, ownerName) a valos szures-logika: owner==assignee,
// status in ('waiting','in_progress'), es last_comment_author letezik es != owner
// (case-insensitive, ahogy a syncOwnerFilterBtn/kanbanCardMatchesBaseFilters
// mar teszi az assignee-osszehasonlitasnal).

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const __dirname = dirname(fileURLToPath(import.meta.url))
const appJsPath = join(__dirname, '..', '..', 'web', 'app.js')
const src = readFileSync(appJsPath, 'utf8')

function extractFn(name: string): string | null {
  const re = new RegExp(`function ${name}\\s*\\([^)]*\\)\\s*\\{`)
  const m = re.exec(src)
  if (!m) return null
  let depth = 0
  for (let j = src.indexOf('{', m.index); j < src.length; j++) {
    if (src[j] === '{') depth++
    else if (src[j] === '}' && --depth === 0) return src.slice(m.index, j + 1)
  }
  return null
}

function loadFn(): (card: any, ownerName: string | null) => boolean {
  const fnSrc = extractFn('cardIsPendingOnOwner')
  if (!fnSrc) throw new Error('cardIsPendingOnOwner missing from web/app.js')
  const body = `${fnSrc}\nreturn cardIsPendingOnOwner`
  // eslint-disable-next-line @typescript-eslint/no-implied-eval
  return new Function(body)()
}

function loadOwnerAssigneeName(assignees: Array<{ name: string; type: string }>): () => string | null {
  const fnSrc = extractFn('ownerAssigneeName')
  if (!fnSrc) throw new Error('ownerAssigneeName missing from web/app.js')
  const body = `let kanbanAssignees = ${JSON.stringify(assignees)}\n${fnSrc}\nreturn ownerAssigneeName`
  // eslint-disable-next-line @typescript-eslint/no-implied-eval
  return new Function(body)()
}

describe('cardIsPendingOnOwner', () => {
  it('false when there is no owner', () => {
    const fn = loadFn()
    expect(fn({ status: 'waiting', assignee: 'marveen', last_comment_author: 'akka' }, null)).toBe(false)
  })

  it('false when the card is not assigned to the owner', () => {
    const fn = loadFn()
    expect(fn({ status: 'waiting', assignee: 'akka', last_comment_author: 'akka' }, 'marveen')).toBe(false)
  })

  it('false for planned/testing/done -- only waiting and in_progress count', () => {
    const fn = loadFn()
    for (const status of ['planned', 'testing', 'done']) {
      expect(fn({ status, assignee: 'marveen', last_comment_author: 'akka' }, 'marveen')).toBe(false)
    }
  })

  it('true for waiting, assigned to owner, last comment by someone else', () => {
    const fn = loadFn()
    expect(fn({ status: 'waiting', assignee: 'marveen', last_comment_author: 'akka' }, 'marveen')).toBe(true)
  })

  it('true for in_progress, assigned to owner, last comment by someone else', () => {
    const fn = loadFn()
    expect(fn({ status: 'in_progress', assignee: 'marveen', last_comment_author: 'akka' }, 'marveen')).toBe(true)
  })

  it('false when the owner wrote the last comment (ball is in the owner\'s court)', () => {
    const fn = loadFn()
    expect(fn({ status: 'waiting', assignee: 'marveen', last_comment_author: 'marveen' }, 'marveen')).toBe(false)
  })

  it('false when there is no comment yet (last_comment_author null)', () => {
    const fn = loadFn()
    expect(fn({ status: 'in_progress', assignee: 'marveen', last_comment_author: null }, 'marveen')).toBe(false)
  })

  it('assignee and author comparison is case-insensitive', () => {
    const fn = loadFn()
    expect(fn({ status: 'waiting', assignee: 'Marveen', last_comment_author: 'AKKA' }, 'marveen')).toBe(true)
    expect(fn({ status: 'waiting', assignee: 'marveen', last_comment_author: 'MARVEEN' }, 'marveen')).toBe(false)
  })
})

// ownerAssigneeName() feeds every "Rám vár"/"Függőségek" check (owner_btn,
// pending_btn, syncOwnerFilterBtn, syncPendingFilterBtn, kanbanCardMatchesPendingFilter).
// Correkt (2026-09-01, Józsi mérése): a fleet-konvenció szerint egy kártya SOHA
// nem kerül az 'owner'-tipusú assignee-re (a kanban.ts:76-77 kommentje szerint
// ezt kifejezetten tiltja az escalation-út -- a döntésre váró kártya a 'bot'
// (marveen) nevén marad, ő triázsol). Emiatt az 'owner'-típusra szűrő régi
// alak strukturálisan mindig üres eredményt adott -- a gomb nem hibás volt,
// csak olyasmit mért, ami a konvenció szerint sosem történik meg.
describe('ownerAssigneeName prefers the bot-type assignee over the owner-type one', () => {
  it('returns the bot name when both a bot and an owner assignee exist', () => {
    const fn = loadOwnerAssigneeName([
      { name: 'Józsi', type: 'owner' },
      { name: 'Marveen', type: 'bot' },
      { name: 'akka', type: 'agent' },
    ])
    expect(fn()).toBe('Marveen')
  })

  it('falls back to the owner name when no bot-type assignee exists', () => {
    const fn = loadOwnerAssigneeName([
      { name: 'Józsi', type: 'owner' },
      { name: 'akka', type: 'agent' },
    ])
    expect(fn()).toBe('Józsi')
  })

  it('returns null when neither a bot nor an owner assignee exists', () => {
    const fn = loadOwnerAssigneeName([{ name: 'akka', type: 'agent' }])
    expect(fn()).toBe(null)
  })
})

// The pure function alone proves the logic; these guard that it is actually
// WIRED into the board -- a toggle button that toggles nothing, or a filter
// function nobody calls, would pass every test above while doing nothing in
// the running UI.
describe('Fuggosegek filter is wired into the toolbar and render path', () => {
  it('a toolbar button exists and toggles a dedicated filter state', () => {
    expect(src).toMatch(/kanbanPendingBtn/)
    expect(src).toMatch(/kanbanPendingFilterActive/)
  })

  it('renderKanban is wired through a pending-filter dimension that calls cardIsPendingOnOwner (not just defines it)', () => {
    const renderSrc = extractFn('renderKanban')
    expect(renderSrc, 'renderKanban not found').toBeTruthy()
    expect(renderSrc).toMatch(/kanbanCardMatchesPendingFilter/)

    const filterFnSrc = extractFn('kanbanCardMatchesPendingFilter')
    expect(filterFnSrc, 'kanbanCardMatchesPendingFilter not found').toBeTruthy()
    expect(filterFnSrc).toMatch(/cardIsPendingOnOwner/)
  })

  it('does not change the existing owner ("Rám vár") button behaviour', () => {
    // ownerAssigneeName / syncOwnerFilterBtn stay assignee-only -- the new
    // filter is additive, not a rewrite of the existing quick-toggle.
    const ownerFn = extractFn('syncOwnerFilterBtn')
    expect(ownerFn).not.toMatch(/last_comment_author/)
  })

  it('both languages define the pending-filter button label', () => {
    const huPath = join(__dirname, '..', '..', 'web', 'lang', 'hu.js')
    const enPath = join(__dirname, '..', '..', 'web', 'lang', 'en.js')
    const hu = readFileSync(huPath, 'utf8')
    const en = readFileSync(enPath, 'utf8')
    expect(hu).toMatch(/kanban\.filter\.pending_btn/)
    expect(en).toMatch(/kanban\.filter\.pending_btn/)
  })
})
