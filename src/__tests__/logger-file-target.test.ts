import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'

// The schedule-runner logs dropped ticks through the shared logger
// (`logger.info(..., 'Schedule busy, skipIfBusy=true: dropping tick silently')`).
// Without a file target, that line only ever reaches process.stdout -- whether
// it survives depends entirely on how the process happens to be launched. This
// pins that a line written through the shared logger lands in a file on disk,
// regardless of the launch mechanism.
//
// pino's file transport runs in a worker thread, so a written line is not
// necessarily on disk the instant `.info()`/`.warn()` returns -- pollUntil
// gives it a bounded window instead of asserting on a fixed sleep.
async function pollUntil(predicate: () => boolean, timeoutMs = 3000, intervalMs = 25): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return
    await new Promise((resolve) => setTimeout(resolve, intervalMs))
  }
  if (!predicate()) throw new Error(`pollUntil: condition not met within ${timeoutMs}ms`)
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

    await pollUntil(() => existsSync(dir) && readdirSync(dir).length > 0)

    const files = readdirSync(dir)
    const content = files.map((f) => readFileSync(path.join(dir, f), 'utf8')).join('\n')

    expect(content).toContain('LOGGER-FILE-TARGET-TEST')
    expect(content).toContain('schedule busy test line')
  })
})
