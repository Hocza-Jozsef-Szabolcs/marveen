// Kártya-létrehozási kapu (Józsi, 2026-08-04, 2026-08-20, 2026-08-24 -- HARMADSZOR
// megismételve, szó szerint: "A VHR8-at FELEJTSÜK EL, amíg nem szól"): a VHR8-nak
// SEMMILYEN önkezdeményezett figyelem nem járhat. Bizonyított eset, 2026-08-24: egy
// flotta-szintű audit-kártya (94a28308) a repó-listájában "VHR8"-at is felsorolt,
// annak ellenére, hogy a tiltás szó szerint ott állt ugyanabban a CLAUDE.md-ben, amit
// a kártyát létrehozó saját maga olvasott. Írott szabály önmagában nem elég -- ez a
// harmadik előfordulás ugyanabból a hibaosztályból. POST /api/kanban mostantól
// elutasítja (400) az új kártyát, ha a cím vagy a leírás "VHR8"/"VHR-8" (kis-nagybetű
// független) szöveget tartalmaz, hacsak a kérés explicit `override: true`-t nem küld
// -- ez utóbbi arra az esetre marad, amikor Józsi maga kéri a VHR8-at érintő munkát.

import { describe, it, expect, beforeEach } from 'vitest'
import { EventEmitter } from 'node:events'
import { initDatabase, getKanbanCard } from '../db.js'
import { tryHandleKanban } from '../web/routes/kanban.js'
import type { RouteContext } from '../web/routes/types.js'

async function postCard(body: unknown): Promise<{ statusCode: number; json: any }> {
  const req = new EventEmitter() as unknown as RouteContext['req']
  const state = { statusCode: 0, body: '' }
  const res = {
    writeHead(code: number) { state.statusCode = code; return res },
    end(data?: unknown) { state.body = String(data ?? '') },
    setHeader() {},
  } as unknown as RouteContext['res']
  process.nextTick(() => {
    ;(req as unknown as EventEmitter).emit('data', Buffer.from(JSON.stringify(body)))
    ;(req as unknown as EventEmitter).emit('end')
  })
  const handled = await tryHandleKanban({
    req, res, path: '/api/kanban', method: 'POST',
    url: new URL('http://localhost/api/kanban'),
  } as RouteContext)
  expect(handled).toBe(true)
  return { statusCode: state.statusCode || 200, json: state.body ? JSON.parse(state.body) : null }
}

beforeEach(() => { initDatabase(':memory:') })

describe('POST /api/kanban -- VHR8 önkezdeményezett kártya tiltva', () => {
  it('rejects a card whose title mentions VHR8', async () => {
    const { statusCode, json } = await postCard({ title: 'VHR8: valami', project: 'VHR' })
    expect(statusCode).toBe(400)
    expect(json.error).toBeTruthy()
    expect(getKanbanCard(json.id)).toBeFalsy()
  })

  it('rejects a card whose description mentions VHR-8 (hyphenated, mixed case)', async () => {
    const { statusCode } = await postCard({
      title: 'Repó-lista', project: 'Marveen',
      description: 'Érintett repók: QuantumAE, JokerQ, Vhr-8.0',
    })
    expect(statusCode).toBe(400)
  })

  it('creates the card when override:true is explicitly set', async () => {
    const { statusCode, json } = await postCard({
      title: 'VHR8: Józsi kérésére', project: 'VHR', override: true,
    })
    expect(statusCode).toBe(200)
    expect(getKanbanCard(json.id)).toBeTruthy()
  })

  it('creates a normal card with no VHR8 mention', async () => {
    const { statusCode, json } = await postCard({ title: 'QuantumAE: valami', project: 'QCassa' })
    expect(statusCode).toBe(200)
    expect(getKanbanCard(json.id)).toBeTruthy()
  })
})
