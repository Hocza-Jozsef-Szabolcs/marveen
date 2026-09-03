import { describe, expect, it, vi } from 'vitest'

vi.mock('../platform.js', () => ({
  resolveFromPath: (name: string) => `/usr/local/bin/${name}`,
}))
vi.mock('../logger.js', () => ({
  logger: { info: vi.fn(), warn: vi.fn(), debug: vi.fn(), error: vi.fn() },
}))
import { paneShowsIdleFooter, paneListsProvider } from '../web/channel-plugin-unlock.js'

// Ugyanaz a hibaosztaly, mint a channel-mcp-reconnect / channel-health-monitor
// illesztesein: a Claude Code TUI keskeny pane-en szo kozepen tori a sort, es a
// tmux `-J` ezt NEM javitja (merve 2026-09-02, elo pane, 80x50: a `-p` es a
// `-p -J` kimenete jobbra trimmelve bajtazonos).
//
// Itt ket kovetkezmenye van, es MINDKETTO a rossz iranyba tev:
//   - a tordelt tetlen-lablec miatt a session sosem szamit "keszen allonak",
//     tehat a feloldas el sem indul egy tenylegesen halott pluginnal;
//   - a tordelt szolgaltato-azonosito miatt a probe "absent"-nek konyveli el a
//     plugint, ami a down-kaszkad restart-budzsejet EGY probalkozasra vagja.
describe('paneShowsIdleFooter', () => {
  it('felismeri a lablecet a szokasos, egy soros alakban', () => {
    expect(paneShowsIdleFooter('  ? for shortcuts       bypass permissions on')).toBe(true)
  })

  it('felismeri a lablecet akkor is, ha a TUI ket sorra tordelte', () => {
    expect(paneShowsIdleFooter('  ? for shortcuts       bypass permis\nsions on')).toBe(true)
  })

  it('nem talal lablecet, ahol nincs', () => {
    expect(paneShowsIdleFooter('Resume from summary\n  1. Continue')).toBe(false)
  })
})

describe('paneListsProvider', () => {
  it('megtalalja a szolgaltatot a tordeletlen /mcp listaban', () => {
    expect(paneListsProvider('  1. plugin:telegram:telegram', 'telegram')).toBe(true)
  })

  it('megtalalja a szolgaltatot akkor is, ha a sor szo kozepen tort el', () => {
    expect(paneListsProvider('  1. plugin:tele\ngram:telegram', 'telegram')).toBe(true)
  })

  it('hamis-pozitiv ellenproba: idegen lista nem szamit talalatnak', () => {
    expect(paneListsProvider('  1. google-workspace\n  2. spotify', 'telegram')).toBe(false)
  })
})
