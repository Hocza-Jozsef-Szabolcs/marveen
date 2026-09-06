import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'

// The schedule-runner logs dropped ticks through the shared logger
// (`logger.info(..., 'Schedule busy, skipIfBusy=true: dropping tick silently')`).
// Without a file target, that line only ever reaches process.stdout -- whether
// it survives depends entirely on how the process happens to be launched. This
// pins that a line written through the shared logger lands in a file on disk,
// regardless of the launch mechanism.
//
// hu: MERT TENY (kartya 1c9cb950): pino fajl-celja (pino-roll) egy thread-stream
//     worker szalban fut. A worker a fogadott sort a cel Writable.write()-jenek
//     adja at, es a READ_INDEX-et (a fo szal ezt latja) MAR AKKOR elore lepteti,
//     amikor a write() true-t ad vissza -- azaz amikor a Node Writable elfogadta
//     a sort a SAJAT belso pufferebe, NEM amikor a fajlrendszerre tenylegesen
//     kiirta (node_modules/thread-stream/lib/worker.js:130-135). A `logger.flush()`
//     (node_modules/thread-stream/index.js:298) a READ_INDEX-re var, tehat CSAK
//     azt igazolja, hogy a worker AT VETTE a sort, nem hogy LEMEZEN van -- ez
//     MERVE megbukott: az elso teljes (nem izolalt) vitest-futasban a
//     flush()-ra epulo valtozat is ures tartalmat olvasott. A korabbi
//     `pollUntil(() => existsSync(dir) && readdirSync(dir).length > 0)` ugyanezen
//     okbol volt vak: a fajlt pino-roll a `mkdir: true` miatt hamarabb hozza
//     letre, mint hogy a tartalom rakerulne, es a poll csak a LETEZEST nezte.
//     A helyes megoldas egyik korabbi valtozat szinkronizacios pontjara sem
//     tamaszkodik: a poll predikatuma maga a VART VEGALLAPOT (a fajl TARTALMAZZA
//     a markert), nem egy kozvetett jel a worker allapotarol.
// en: MEASURED FACT (card 1c9cb950): pino's file target (pino-roll) runs in a
//     thread-stream worker. The worker hands the line to the destination
//     Writable's write() and advances READ_INDEX (visible to the main thread)
//     as soon as write() returns true -- i.e. once Node's Writable accepted the
//     line into ITS OWN internal buffer, not once it was actually flushed to the
//     filesystem (node_modules/thread-stream/lib/worker.js:130-135).
//     `logger.flush()` (node_modules/thread-stream/index.js:298) waits on
//     READ_INDEX, so it only proves the worker RECEIVED the line, not that it
//     landed on disk -- MEASURED to fail: the flush()-based version also read
//     empty content on the first full (non-isolated) vitest run. The earlier
//     `pollUntil(() => existsSync(dir) && readdirSync(dir).length > 0)` was
//     blind for the same reason: pino-roll creates the file (via `mkdir: true`)
//     before its content lands, and the poll only checked existence. The fix
//     below relies on neither prior synchronization point: the poll predicate
//     IS the awaited end state (the file contains the marker), not an indirect
//     signal about worker state.
async function pollUntilContains(dir: string, marker: string, timeoutMs = 3000, intervalMs = 25): Promise<string> {
  const deadline = Date.now() + timeoutMs

  while (Date.now() < deadline) {
    const files = readdirSync(dir)
    const content = files.map((f) => readFileSync(path.join(dir, f), 'utf8')).join('\n')

    if (content.includes(marker)) return content
    await new Promise((resolve) => setTimeout(resolve, intervalMs))
  }

  throw new Error(`pollUntilContains: marker "${marker}" not found within ${timeoutMs}ms`)
}

describe('logger file target', () => {
  let dir: string
  const originalLogDir = process.env.MARVEEN_LOG_DIR

  beforeEach(() => {
    dir = mkdtempSync(path.join(tmpdir(), 'marveen-logger-test-'))
    process.env.MARVEEN_LOG_DIR = dir
    vi.resetModules()
  })

  afterEach(() => {
    if (originalLogDir === undefined) delete process.env.MARVEEN_LOG_DIR
    else process.env.MARVEEN_LOG_DIR = originalLogDir
    rmSync(dir, { recursive: true, force: true })
  })

  it('writes a warn line to a file under MARVEEN_LOG_DIR', async () => {
    const { logger } = await import('../logger.js')

    logger.warn({ marker: 'LOGGER-FILE-TARGET-TEST' }, 'schedule busy test line')

    const content = await pollUntilContains(dir, 'LOGGER-FILE-TARGET-TEST')

    expect(content).toContain('LOGGER-FILE-TARGET-TEST')
    expect(content).toContain('schedule busy test line')
  })
})
