import { describe, it, expect, vi, beforeEach } from 'vitest'

// A `-J` flag INERT ezen a pane-tipuson -- ez a teszt csak az argv-t rogziti.
//
// MERES (2026-09-02, elo agent-akka es agent-rendezo pane, 80x50, csak
// olvasas): `tmux capture-pane -t <s> -p` es `tmux capture-pane -t <s> -p -J`
// kimenete jobbra trimmelve BAJTAZONOS -- 50/50 sor, 0 eltero sor. A pane-en
// atnyulo, szo kozepen tordelt tokenek EGYIK alakban SINCSENEK osszefuzve.
//
// Ok: a tmux `-J` csak azokat a sorokat fuzi ossze, amelyeket a terminal
// AUTOMATIKUS tordelese jelolt meg wrap-flaggel. A Claude Code teljes kepernyos
// rajzolo: minden sort explicit kurzor-pozicionalassal ir ki, tehat egyetlen
// sora sem kap wrap-jelolest. A `-J` egyetlen merheto hatasa, hogy megorzi a
// zaro feherkozt (a 0 hosszu sorbol a pane szelessegenyi szokoz lesz).
//
// A TUI-tordelt azonositok tenyleges javitasa ezert a FEHERKOZ-MENTES
// illesztes (pane-state.ts `paneContainsIgnoringWrap`), nem ez a flag.
// A `-J` a `capturePane`-ben maradhat -- artalmatlan, es hiven adja vissza a
// zaro feherkozt --, de ez a teszt CSAK azt allitja, hogy a flag ott van az
// argv-ben; a VISELKEDESROL semmit nem mond. A tordeles-turo illesztest a
// channel-mcp-reconnect / channel-health-monitor / channel-plugin-unlock sajat
// tesztjei merik.

const h = vi.hoisted(() => ({ calls: [] as string[][] }))

vi.mock('node:child_process', async (orig) => ({
  ...(await orig() as object),
  execFileSync: vi.fn((_file: string, args?: string[]) => {
    if (Array.isArray(args)) h.calls.push(args)
    return ''
  }),
}))

import { capturePane } from '../web/agent-process.js'

beforeEach(() => {
  h.calls.length = 0
})

describe('capturePane', () => {
  it('atadja a -J flaget a tmux capture-pane-nek (argv-rogzites, nem viselkedes-meres)', () => {
    capturePane('marveen-channels')

    const captureCall = h.calls.find(a => a.includes('capture-pane'))
    expect(captureCall).toBeDefined()
    expect(captureCall).toContain('-J')
  })
})
