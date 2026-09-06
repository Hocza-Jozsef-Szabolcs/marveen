import { describe, it, expect, beforeAll, afterAll, beforeEach, vi } from 'vitest'
import {
  initDatabase,
  getDb,
  saveAgentMemory,
  getAgentMemories,
  updateMemory,
  clearMemoryCache,
  getMemoryCacheSize,
  backfillEmbeddings,
} from '../db.js'

// All tests use an in-memory SQLite database so they never touch the real store.
//
// generateEmbedding() (src/db.ts:2676) calls the real fetch() against
// OLLAMA_URL -- unawaited from saveAgentMemory's fire-and-forget call
// (src/db.ts:1357) and awaited from backfillEmbeddings (src/db.ts:2751-2764).
// Before this stub, both paths hit a real local Ollama: the cache tests below
// fire ~7 background embed calls, and whichever are still unresolved by the
// time the backfillEmbeddings tests run were swept up by its own
// "WHERE embedding IS NULL" query and re-embedded synchronously inside the
// test -- racing real Ollama latency (0.1s warm, up to 90s cold/CPU-bound per
// tool-timeouts.ts:10-13) against vitest's fixed 5000ms default test timeout.
// Verified: pointing OLLAMA_URL at an unresponsive listener reproduces "Test
// timed out in 5000ms" on both backfillEmbeddings tests with zero code
// change -- the same failure mode a one-off flaky run showed.
//
// The fix is not a longer timeout (the next slower machine or busier host
// brings the race back) -- it is removing the real network dependency. Only
// the row carrying BACKFILL_TARGET_CONTENT gets a successful embedding from
// the stub; every other prompt (the earlier saveAgentMemory calls) is
// rejected, the same way an unreachable Ollama would be, so both branches of
// generateEmbedding stay exercised without any timing dependency.
const FAKE_EMBEDDING = [0.1, 0.2, 0.3]
const BACKFILL_TARGET_CONTENT = 'Backfill target content'

beforeAll(() => {
  process.env.NODE_ENV = 'test'
  initDatabase(':memory:')

  vi.stubGlobal('fetch', vi.fn(async (_url: string, opts: { body: string }) => {
    const { prompt } = JSON.parse(opts.body) as { prompt: string }
    if (prompt !== BACKFILL_TARGET_CONTENT) throw new Error('stub: simulated unreachable Ollama')
    return { json: async () => ({ embedding: FAKE_EMBEDDING }) }
  }))
})

afterAll(() => {
  vi.unstubAllGlobals()
})

beforeEach(() => {
  clearMemoryCache()
})

// ---------------------------------------------------------------------------
// 1. SQLite pragmas
// ---------------------------------------------------------------------------
describe('SQLite performance pragmas', () => {
  it('cache_size is set to -65536 (64 MB)', () => {
    const row = getDb().pragma('cache_size', { simple: true })
    expect(row).toBe(-65536)
  })

  it('synchronous is NORMAL (1)', () => {
    // SQLite reports NORMAL as integer 1.
    const row = getDb().pragma('synchronous', { simple: true })
    expect(row).toBe(1)
  })

  // journal_mode and mmap_size cannot be verified on :memory: databases:
  // - WAL is silently downgraded to 'memory' journal for in-memory DBs.
  // - mmap_size is a no-op without a backing file.
  // Both are applied on the real on-disk DB; here we only test the pragmas
  // that behave identically regardless of the storage path.
})

// ---------------------------------------------------------------------------
// 2. In-process TTL cache
// ---------------------------------------------------------------------------
describe('getAgentMemories in-process cache', () => {
  const AGENT = 'cache-test-agent'

  it('cold miss: returns data from DB, cache is populated', () => {
    saveAgentMemory(AGENT, 'First memory', 'warm', 'keyword1')
    const before = getMemoryCacheSize()
    getAgentMemories(AGENT, 5)
    expect(getMemoryCacheSize()).toBe(before + 1)
  })

  it('warm hit: second call returns same object from cache (no DB round-trip)', () => {
    saveAgentMemory(AGENT, 'Cache hit check', 'warm', 'keyword2')
    const first = getAgentMemories(AGENT, 5)
    const second = getAgentMemories(AGENT, 5)
    // Same array reference means the cache was hit.
    expect(second).toBe(first)
  })

  it('cache key is per agentId+limit: different limit = separate entry', () => {
    getAgentMemories(AGENT, 5)
    getAgentMemories(AGENT, 10)
    // Both limit variants should be cached as separate entries.
    expect(getMemoryCacheSize()).toBeGreaterThanOrEqual(2)
  })

  it('saveAgentMemory invalidates the cache for that agent', () => {
    const before = getAgentMemories(AGENT, 5)
    saveAgentMemory(AGENT, 'Invalidation trigger', 'hot', 'new')
    // After write the cache for this agent should be gone.
    expect(getMemoryCacheSize()).toBe(0)
    const after = getAgentMemories(AGENT, 5)
    // Different reference: fresh DB read.
    expect(after).not.toBe(before)
    // New memory must appear.
    expect(after.some(m => m.content === 'Invalidation trigger')).toBe(true)
  })

  it('updateMemory with agentId invalidates the cache', () => {
    const { id } = saveAgentMemory(AGENT, 'Update me', 'warm', 'upd')
    getAgentMemories(AGENT, 5) // warm the cache
    const sizeBefore = getMemoryCacheSize()
    updateMemory(id, 'Updated content', 'warm', AGENT, 'upd')
    expect(getMemoryCacheSize()).toBeLessThan(sizeBefore)
  })

  it('cache is isolated between agents', () => {
    const OTHER = 'other-agent'
    saveAgentMemory(AGENT, 'Agent A memory', 'cold', 'a')
    saveAgentMemory(OTHER, 'Agent B memory', 'cold', 'b')
    getAgentMemories(AGENT, 5)
    getAgentMemories(OTHER, 5)
    const sizeBefore = getMemoryCacheSize()
    // Write to AGENT should not evict OTHER's cache entry.
    saveAgentMemory(AGENT, 'New for agent A', 'hot')
    const sizeAfter = getMemoryCacheSize()
    // At least one entry (OTHER's) should survive.
    expect(sizeAfter).toBeGreaterThan(0)
    expect(sizeAfter).toBeLessThan(sizeBefore)
  })

  it('clearMemoryCache wipes all entries', () => {
    getAgentMemories(AGENT, 5)
    expect(getMemoryCacheSize()).toBeGreaterThan(0)
    clearMemoryCache()
    expect(getMemoryCacheSize()).toBe(0)
  })
})

// ---------------------------------------------------------------------------
// 3. Embedding backfill
// ---------------------------------------------------------------------------
describe('backfillEmbeddings', () => {
  it('returns 0 when all memories already have embeddings or Ollama is unreachable', async () => {
    // Every pending row at this point comes from the cache tests above, none
    // of which carry BACKFILL_TARGET_CONTENT, so the stub (see beforeAll)
    // rejects each one -- deterministically reproducing the "Ollama
    // unreachable" branch instead of depending on whether a real Ollama
    // happens to be reachable on the machine running the suite.
    const count = await backfillEmbeddings()
    expect(count).toBe(0)
  })

  it('processes rows without embeddings and updates them when Ollama responds', async () => {
    const BACKFILL_AGENT = 'backfill-test-agent'

    // Insert a memory bypassing saveAgentMemory so embedding stays NULL.
    const db = getDb()
    const now = Math.floor(Date.now() / 1000)
    const result = db.prepare(
      `INSERT INTO memories (chat_id, topic_key, content, sector, salience,
       created_at, accessed_at, agent_id, category, auto_generated, keywords)
       VALUES (?, NULL, ?, 'semantic', 1.0, ?, ?, ?, 'cold', 0, NULL)`
    ).run('test-chat', BACKFILL_TARGET_CONTENT, now, now, BACKFILL_AGENT)
    const id = Number(result.lastInsertRowid)

    const rowBefore = db.prepare('SELECT embedding FROM memories WHERE id = ?').get(id) as { embedding: string | null }
    expect(rowBefore.embedding).toBeNull()

    // Only this row's content matches the stub's success case (see
    // beforeAll); every other pending row is rejected again, so the count is
    // exactly 1 regardless of how many other NULL rows exist at this point.
    const count = await backfillEmbeddings()
    expect(count).toBe(1)

    const rowAfter = db.prepare('SELECT embedding FROM memories WHERE id = ?').get(id) as { embedding: string | null }
    expect(rowAfter.embedding).not.toBeNull()
    expect(JSON.parse(rowAfter.embedding!)).toEqual(FAKE_EMBEDDING)
  })
})
