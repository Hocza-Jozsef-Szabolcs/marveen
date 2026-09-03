// hu: E csomag -- a helyreallitasi ertesites HAMIS igerete + a riasztasi kuszob.
//
// TUNET (mert, 2026-08-24 .. 2026-09-02, ujramerheto:
//   grep -h 'Marveen channel plugin recovered' store/app.2026-*.log
// ): 27 helyreallitasi rekord 9 nap alatt, es a gazdanak kimeno szoveg minden
// egyes alkalommal ezt igerte: "Ha a kieses alatt irtal es nem jott valasz,
// mindjart potolom."
//
// AZ IGERET HAMIS, es nem velemeny -- meres:
//   launchctl list | grep -i coordinator        -> ures, exit 1
//   ls ~/.claude/channels/telegram-coordinator  -> No such file or directory
//   select count(*) from agent_messages
//     where from_agent like '%coordinator%'     -> 0
// A backfill-koordinator SOHA nem futott, nulla potlas tortent. Az igeret a
// legrosszabbat teszi, amit egy ertesites tehet: a gazdat NEM-cselekvesre
// birja (ulj nyugodtan, majd en potolom), holott az egyetlen dolog, ami
// visszahozhatja az uzenetet, az hogy O ujrakuldi.
//
// SZERKEZETI OK, amiert a potlas nem is lehetseges (mert, .../telegram/0.0.7/
// server.ts: `grep -n offset` -> csak entity-offset a :314-en): a plugin NEM
// perzisztal poll-offsetet, es minden koteget nyugtaz. Amit egy idegen poller
// (pl. egy Task-subagens rovid eletu szervere) felvett, nyugtazott, majd a sajat
// Claude Code-ja eldobott, azt SENKI nem tudja potolni.

import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { buildRecoveryAlert, RECOVERY_LONG_OUTAGE_SEC } from '../web/channel-monitor.js'

const __dirname = dirname(fileURLToPath(import.meta.url))
const MONITOR_PATH = join(__dirname, '..', 'web', 'channel-monitor.ts')

// A `handleMarveenUp` torzsere szukitunk, hogy a fajl BARHOL MASHOL levo szovege
// (komment, masik sendAlert) ne elegithesse ki veletlenul az allitasokat.
// A repo sajat idiomaja: channel-monitor-resume-recovery.test.ts:33-37.
function handleMarveenUpBody(): string {
  const src = readFileSync(MONITOR_PATH, 'utf-8')
  const start = src.indexOf('function handleMarveenUp')
  expect(start, 'handleMarveenUp nem talalhato').toBeGreaterThan(0)
  const end = src.indexOf('\n}\n', start)
  expect(end, 'handleMarveenUp zaro kapcsos zarojele nem talalhato').toBeGreaterThan(start)
  return src.slice(start, end)
}

// A potlas-igeret mintaja: elso szemelyu "potolom"/"potlom".
const PROMISE_RE = /p[oó]tolom|p[oó]tlom/i
// A gazdanak szolo TEENDO mintaja.
const ACTION_RE = /kuldd ujra|k[uü]ldd [uú]jra/i

// ---------------------------------------------------------------------------
// R1-R2 -- TARTALMI red: a MA futo forras viselkedese, uj szimbolum nelkul.
//
// ELTERES A TERVTOL (a meres irta felul). A terv MINDKET allitast a
// `handleMarveenUp` torzsere szukitette. R1 ott is helyes -- de R2 nem lehet
// ott, mert a terv SAJAT atalakitasa kiviszi a szoveget a `buildRecoveryAlert`
// tiszta fuggvenybe, ahol `handleMarveenUp` mar EGYETLEN szoveg-literalt sem
// tartalmaz. A terv szerinti R2 tehat az atalakitas utan is bukna, barmilyen
// helyes is a kimenet. A RED futasban (az akkori, terv szerinti alakkal) R1 es
// R2 EGYUTT bukott a valos kimeno szovegen -- az idezet a jelentesben all.
// R2 vegleges alakja ERPSEBB a tervezettnel: nem egy forras-szeleten grepel,
// hanem a TENYLEGESEN kiadott szoveget meri, MINDEN szinten.
describe('a kimeno szoveg mondjon igazat', () => {
  it('R1: a handleMarveenUp NEM tartalmazhat bedrotozott potlas-igeretet', () => {
    // Ez orzi meg azt is, hogy valaki kesobb VISSZA-inlineolja a szoveget a
    // dontesi ag melle -- pontosan ugy, ahogy az eredeti hiba keletkezett.
    expect(handleMarveenUpBody()).not.toMatch(PROMISE_RE)
  })

  it('R2: koordinator NELKUL egyetlen szinten sem igerhet potlast, es MINDEN kiadott szoveg ad teendot', () => {
    const stages = ['soft', 'save', 'resume', 'hard', 'gave_up'] as const
    // A mert savok also/felso vege + a kuszob koruli ertekek.
    const durations = [180, 240, 300, 360, 600]
    let emitted = 0

    for (const stage of stages) {
      for (const downedForSec of durations) {
        const text = buildRecoveryAlert({
          botName: 'Marveen', providerLabel: 'telegram',
          stage, downedForSec, backfillActive: false,
        })

        if (text === null) continue

        emitted += 1
        expect(text, `stage=${stage} ${downedForSec}s: potlast iger`).not.toMatch(PROMISE_RE)
        expect(text, `stage=${stage} ${downedForSec}s: nincs teendo a gazdanak`).toMatch(ACTION_RE)
      }
    }

    // Ne lehessen ugy "teljesiteni", hogy semmi nem jon ki.
    expect(emitted).toBeGreaterThan(0)
  })
})

// ---------------------------------------------------------------------------
// R3-R6 -- VISELKEDESI red az uj, tiszta fuggvenyre. Ketoldalu: R3 null-t var,
// R4 nem-null-t; R5 ket aga KULONBOZO szoveget. Konstans-visszaado ("megengedo")
// stub egyik parost sem eli tul.
//
// A KUSZOB MERT ALAPJA -- ES ITT ELTEREK A TERVTOL.
// A terv 180 s-ot javasolt, azzal az indokkal, hogy "a soft-ag mert maximuma
// 120 s". Ez a szam a D csomag ELOTTI naplobol szarmazik. A D csomag (mar bent
// a munkafaban: src/web/channel-down-spell.ts + channel-monitor.ts:1467-1471)
// atallitotta a `downedFor`-t az ELSO eszlelesre, ami MARVEEN_DOWN_CONFIRM_MS
// = 120 000 ms-mal korabbi -- vagyis MINDEN mert ertek +120 s-ra tolodik:
//
//   mert (n=27)         D elott          D utan (a mostani forras)
//   stage=soft            60 x9            180 x9
//   stage=soft           120 x3            240 x3
//   stage=resume         180 x11           300 x11
//   stage=resume         240 x3            360 x3
//   stage=resume         241 x1            361 x1
//
// A 180 s-os kuszob a D csomag utan MIND a 12 soft rekordra tuzelne
// (27/27 ertesites 15/27 helyett) -- pontosan az ellenkezoje annak, amit a
// gazda ker. A soft-ag mert maximuma D utan 240 s, ezert a kuszob 60 s
// tartalekkal 300 s. Ellenorzo futas (a predikatumot a mert eloszlason):
//   kuszob 180s -> 27/27 (ebbol CSAK az idokuszob miatt: 12)
//   kuszob 300s -> 15/27 (ebbol CSAK az idokuszob miatt:  0)
describe('buildRecoveryAlert: a magatol gyogyulo blipp nema, a valos veszteseg szol', () => {
  const base = { botName: 'Marveen', providerLabel: 'telegram' as const }

  it('R3: a magatol gyogyulo soft-blipp (mert maximum: 240s) NEMA marad', () => {
    expect(buildRecoveryAlert({
      ...base, stage: 'soft', downedForSec: 240, backfillActive: false,
    })).toBeNull()
  })

  it('R4: a szokatlanul hosszu, nem-diszruptiv kieses MEGIS szol', () => {
    expect(buildRecoveryAlert({
      ...base, stage: 'soft', downedForSec: 600, backfillActive: false,
    })).not.toBeNull()
  })

  it('R5a: koordinator NELKUL -- nincs potlas-igeret, van gazda-teendo', () => {
    // A mert modalis eset: stage=resume, 300 s (x11 a 27-bol).
    const text = buildRecoveryAlert({
      ...base, stage: 'resume', downedForSec: 300, backfillActive: false,
    })
    expect(text).not.toBeNull()
    expect(text!).toContain('300s')
    expect(text!).not.toMatch(PROMISE_RE)
    expect(text!).toMatch(ACTION_RE)
  })

  it('R5b: futo koordinatorral VISZONT igerhet potlast (a szoveg a MERT valosagot koveti)', () => {
    const withBackfill = buildRecoveryAlert({
      ...base, stage: 'resume', downedForSec: 300, backfillActive: true,
    })
    const without = buildRecoveryAlert({
      ...base, stage: 'resume', downedForSec: 300, backfillActive: false,
    })
    expect(withBackfill).not.toBeNull()
    expect(withBackfill!).toMatch(PROMISE_RE)
    // A ket ag NEM adhatja ugyanazt: a szoveg a mert allapotbol kovetkezik,
    // nincs bedrotozva.
    expect(withBackfill).not.toBe(without)
  })

  it('R6: a kuszob a mert soft-sav (max 240s) FOLOTT ul', () => {
    // Ne lehessen egy kesobbi szerkesztessel visszavinni a magatol gyogyulo
    // savba -- az a zaj, amit a gazda kifogasol.
    expect(RECOVERY_LONG_OUTAGE_SEC).toBeGreaterThan(240)
  })
})
