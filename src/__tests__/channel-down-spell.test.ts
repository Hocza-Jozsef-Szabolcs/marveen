import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { mainDownedForSeconds, closeDownSpell } from '../web/channel-down-spell.js'

const T0 = 1_756_000_000_000

// ---------------------------------------------------------------------------
// D2 -- a gazdanak jelentett kieses-hossz.
//
// MERES (2026-09-02, ujramerheto:
//   grep -h 'Marveen channel plugin recovered' store/app.2026-*.log
// ): 27 helyreallitasi rekord, a `downedFor` ertekek 60 (9x), 120 (3x),
// 180 (11x), 240 (3x), 241 (1x). MIND a megerositett stage-1-tol szamol, ami
// MARVEEN_DOWN_CONFIRM_MS = 120 000 ms-mal az ELSO eszleles utan van -- vagyis
// mindegyik pontosan 120 masodperccel kevesebb a valodinal.
//
// A kovetkezmeny nem csak kozmetikai: a riasztasi kapu
// (channel-monitor.ts: `disruptive || downedFor >= 180`) a soft/save szinten a
// SZAMOT nezi, ezert a 12 soft-szintu rekordbol (downedFor 60 es 120) MIND a
// 12 nemaan elmaradt -- pedig valojaban 180-240 masodperces kieses volt.
describe('mainDownedForSeconds', () => {
  it('az ELSO eszlelestol szamol, nem a megerositett stage-1-tol', () => {
    // A tipikus alak: T0-kor lat gyanut, T0+120s-kor erositi meg (stage-1),
    // T0+180s-kor jon vissza a plugin.
    expect(mainDownedForSeconds({
      nowMs: T0 + 180_000,
      firstSeenMs: T0,
      downSinceMs: T0 + 120_000,
    })).toBe(180)
  })

  it('a naploban mert legrosszabb alak: a jelentett 240s valojaban 360s', () => {
    expect(mainDownedForSeconds({
      nowMs: T0 + 360_000,
      firstSeenMs: T0,
      downSinceMs: T0 + 120_000,
    })).toBe(360)
  })

  it('firstSeen nelkul (mar torolve) a megerositett kezdet marad a tampont', () => {
    expect(mainDownedForSeconds({
      nowMs: T0 + 180_000,
      firstSeenMs: null,
      downSinceMs: T0 + 120_000,
    })).toBe(60)
  })

  it('a korabbi ket idopont kozul mindig a korabbit veszi (nem hosszabbit soha rovidebbre)', () => {
    // Vedelmi eset: ha egy escalation-ag ujra beallitana a firstSeen-t a
    // megerositett kezdet UTAN, a kieses nem rovidulhet meg tole.
    expect(mainDownedForSeconds({
      nowMs: T0 + 180_000,
      firstSeenMs: T0 + 150_000,
      downSinceMs: T0 + 120_000,
    })).toBe(60)
  })
})

// ---------------------------------------------------------------------------
// D4 -- a down-spell atvitele az ujrainditason.
//
// MERES (2026-09-02, ujramerheto:
//   grep -c 'Agent channel plugin down -- auto-restarting' store/app.2026-*.log
//   grep -c 'Agent channel plugin recovered'                store/app.2026-*.log
// ): 85 "auto-restarting" sor / 11 "recovered" sor. A restart-ag torli az
// `agentDownSince` bejegyzest, ezert a kesobbi helyreallas mar nem lat nyitott
// spellt -- a spell hossza es a kozben elhasznalt ujrainditasok szama SEHOL nem
// jelenik meg a naploban.
describe('closeDownSpell', () => {
  it('az ujrainditason ATVITT spellt zarja le, nem a restart ota eltelt idot', () => {
    // T0: a plugin halott. T0+300s: watchdog-restart (agentDownSince torlodik,
    // a spell kezdete atkerul a recovering-terkepbe). T0+420s: a plugin el.
    expect(closeDownSpell({
      nowMs: T0 + 420_000,
      downSinceMs: null,
      recovering: { spellStartedAt: T0, restarts: 1 },
    })).toEqual({ msDown: 420_000, restartsInSpell: 1 })
  })

  it('tobb ujrainditas utan is az EREDETI kezdettol szamol', () => {
    expect(closeDownSpell({
      nowMs: T0 + 900_000,
      downSinceMs: T0 + 800_000,
      recovering: { spellStartedAt: T0, restarts: 3 },
    })).toEqual({ msDown: 900_000, restartsInSpell: 3 })
  })

  it('ujrainditas nelkuli spell: az agentDownSince-bol szamol, 0 restarttal', () => {
    expect(closeDownSpell({
      nowMs: T0 + 200_000,
      downSinceMs: T0,
      recovering: null,
    })).toEqual({ msDown: 200_000, restartsInSpell: 0 })
  })

  it('nincs nyitott spell -> nincs mit lezarni', () => {
    expect(closeDownSpell({ nowMs: T0, downSinceMs: null, recovering: null })).toBeNull()
  })
})

// ---------------------------------------------------------------------------
// INVARIANS (regresszios kapu, nem uj viselkedes).
//
// A spell-kezdet nyilvantartasa KIZAROLAG naplozasra valo. A restart-dontest
// vezerlo `msDown` -- amit a decideDownAgentAction kap az AGENT_DOWN_CONFIRM_MS
// (150 000 ms) es a busy-defer cap melle -- TOVABBRA IS csak az agentDownSince
// bejegyzesbol szarmazhat, ami minden ujrainditasnal nullarol indul ujra. Ha a
// spell-kezdet szivarogna ide, egy frissen ujrainditott agens azonnal atlepne
// mindket kaput, es a muszer-javitasbol restart-hurok lenne.
describe('channel-monitor msDown invarians', () => {
  const monitor = readFileSync(join(__dirname, '../web/channel-monitor.ts'), 'utf-8')

  it('a decideDownAgentAction msDown-ja csak az agentDownSince-bol jon', () => {
    const m = monitor.match(/const\s+msDown\s*=\s*[^\n]*/)
    expect(m, 'msDown hozzarendeles nem talalhato').not.toBeNull()
    expect(m![0]).toContain('agentDownSince.get(')
    expect(m![0]).not.toContain('agentRecoveringSince')
    expect(m![0]).not.toContain('spellStartedAt')
  })
})
