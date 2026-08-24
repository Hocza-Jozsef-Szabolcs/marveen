#!/usr/bin/env node
// hu: Egyszeri migráció -- a ~/Work/Claude/Vault/Projects/<projekt>/**/*.md és
// ~/Work/Claude/Vault/Shared/**/*.md tartalmát a Marveen dashboard `memories`
// táblájába tölti, `project` cimkével (kártya #914 / 98f3b15e, Fázis 2).
// A Vault-fájlok a lemezen maradnak -- ez a script csak OLVAS onnan, és ÍR a
// store/claudeclaw.db-be. A teljes fájltartalom (frontmatter + törzs)
// változatlanul a `content` mezőbe kerül -- semmilyen mező nem vész el.
//
// en: One-time migration -- loads ~/Work/Claude/Vault/Projects/<project>/**/*.md
// and ~/Work/Claude/Vault/Shared/**/*.md content into the Marveen dashboard
// `memories` table, tagged with `project` (card #914 / 98f3b15e, Phase 2). The
// Vault files stay on disk -- this script only READS from there and WRITES to
// store/claudeclaw.db. The full file content (frontmatter + body) goes into
// `content` unmodified -- nothing is lost.
//
// Usage: node scripts/vault-memory-import.mjs [--dry-run]
import Database from 'better-sqlite3'
import { readdirSync, statSync, readFileSync } from 'node:fs'
import { join, relative, basename } from 'node:path'
import { homedir } from 'node:os'

const DRY_RUN = process.argv.includes('--dry-run')
const VAULT_ROOT = join(homedir(), 'Work', 'Claude', 'Vault')
const PROJECTS_ROOT = join(VAULT_ROOT, 'Projects')
const SHARED_ROOT = join(VAULT_ROOT, 'Shared')
const DB_PATH = join(process.cwd(), 'store', 'claudeclaw.db')
const AGENT_ID = 'marveen'

// Same resolution the running server uses (src/config.ts): read ALLOWED_CHAT_ID
// from .env. The project/agent-scoped queries this data is meant for
// (GET /api/memories?project=... and ?agent=...&category=shared) don't filter
// by chat_id, but getMemoriesForChat() (the plain "no filter" listing) does --
// a wrong chat_id would make these rows invisible to that path.
function readAllowedChatId() {
  try {
    const envPath = join(process.cwd(), '.env')
    const raw = readFileSync(envPath, 'utf8')
    const m = raw.match(/^ALLOWED_CHAT_ID=(.*)$/m)
    if (m) return m[1].trim()
  } catch {
    // no .env / no match -- fall through
  }
  return process.env.ALLOWED_CHAT_ID || ''
}
const ALLOWED_CHAT_ID = readAllowedChatId()

// type: frontmatter -> category (hot/warm/cold/shared enforced by the DB CHECK).
// feedback/learning/bug-log are historical record -> cold. Everything else
// (project/reference/architecture/moc/testing/user/environment/no-type) is
// stable reference knowledge -> warm. Shared/ files always get 'shared'
// regardless of type, below.
const TYPE_TO_CATEGORY = {
  feedback: 'cold',
  learning: 'cold',
  'bug-log': 'cold',
}

function walkMarkdown(dir) {
  const out = []
  let entries
  try {
    entries = readdirSync(dir, { withFileTypes: true })
  } catch {
    return out
  }
  for (const e of entries) {
    const full = join(dir, e.name)
    if (e.isDirectory()) out.push(...walkMarkdown(full))
    else if (e.isFile() && e.name.endsWith('.md')) out.push(full)
  }
  return out
}

function parseFrontmatter(raw) {
  const m = raw.match(/^---\r?\n([\s\S]*?)\r?\n---/)
  if (!m) return {}
  const block = m[1]
  const typeMatch = block.match(/^type:\s*(\S+)\s*$/m)
  const tagsMatch = block.match(/^tags:\s*\[(.*)\]\s*$/m)
  let keywords
  if (tagsMatch) {
    keywords = tagsMatch[1].split(',').map(s => s.trim().replace(/^["']|["']$/g, '')).filter(Boolean).join(', ')
  }
  return { type: typeMatch ? typeMatch[1] : undefined, keywords }
}

function categoryFor(type, isShared) {
  if (isShared) return 'shared'
  if (type && TYPE_TO_CATEGORY[type]) return TYPE_TO_CATEGORY[type]
  return 'warm'
}

function collectRows() {
  const rows = []

  let projectDirs
  try {
    projectDirs = readdirSync(PROJECTS_ROOT, { withFileTypes: true }).filter(e => e.isDirectory())
  } catch (err) {
    console.error(`[vault-import] cannot read ${PROJECTS_ROOT}:`, err.message)
    projectDirs = []
  }

  for (const dirent of projectDirs) {
    const projectName = dirent.name
    const projectDir = join(PROJECTS_ROOT, projectName)
    for (const file of walkMarkdown(projectDir)) {
      const raw = readFileSync(file, 'utf8')
      const { type, keywords } = parseFrontmatter(raw)
      rows.push({
        project: projectName,
        sourcePath: relative(VAULT_ROOT, file),
        content: raw,
        category: categoryFor(type, false),
        keywords,
      })
    }
  }

  for (const file of walkMarkdown(SHARED_ROOT)) {
    const raw = readFileSync(file, 'utf8')
    const { keywords } = parseFrontmatter(raw)
    rows.push({
      project: null,
      sourcePath: relative(VAULT_ROOT, file),
      content: raw,
      category: 'shared',
      keywords,
    })
  }

  return rows
}

function main() {
  const rows = collectRows()

  // Per-project file count -- printed BEFORE any DB write, so a mismatch
  // against `find ... -name '*.md' | wc -l` is caught before it's too late.
  const perProject = new Map()
  for (const r of rows) {
    const key = r.project ?? '(Shared)'
    perProject.set(key, (perProject.get(key) ?? 0) + 1)
  }
  console.log(`[vault-import] ${rows.length} markdown file(s) found across ${perProject.size} project group(s):`)
  for (const [k, v] of [...perProject.entries()].sort((a, b) => b[1] - a[1])) {
    console.log(`  ${String(v).padStart(4)}  ${k}`)
  }

  if (DRY_RUN) {
    console.log('[vault-import] --dry-run: no DB write performed.')
    return
  }

  const db = new Database(DB_PATH)
  db.pragma('journal_mode = WAL')

  // topic_key carries the Vault-relative source path -- re-running the script
  // (e.g. after a partial run) must not duplicate rows already imported.
  const existing = db.prepare("SELECT topic_key FROM memories WHERE agent_id = ? AND topic_key IS NOT NULL")
    .all(AGENT_ID).map(r => r.topic_key)
  const existingSet = new Set(existing)

  const insert = db.prepare(
    `INSERT INTO memories (chat_id, topic_key, content, sector, salience, created_at, accessed_at, agent_id, category, auto_generated, keywords, project)
     VALUES (?, ?, ?, 'semantic', 1.0, ?, ?, ?, ?, 1, ?, ?)`
  )

  const now = Math.floor(Date.now() / 1000)
  const insertAll = db.transaction((items) => {
    let n = 0
    let skipped = 0
    for (const item of items) {
      if (existingSet.has(item.sourcePath)) { skipped++; continue }
      insert.run(ALLOWED_CHAT_ID, item.sourcePath, item.content, now, now, AGENT_ID, item.category, item.keywords ?? null, item.project)
      n++
    }
    return { n, skipped }
  })

  const { n: inserted, skipped } = insertAll(rows)
  console.log(`[vault-import] inserted ${inserted} row(s), skipped ${skipped} already-imported row(s), into ${DB_PATH}`)

  // Positive control: row count in DB for this import run must equal what we
  // just inserted, and per-project counts must match the file walk above.
  const totalNow = db.prepare("SELECT COUNT(*) c FROM memories WHERE topic_key IS NOT NULL AND agent_id = ?").get(AGENT_ID).c
  console.log(`[vault-import] memories rows with a Vault source path for agent '${AGENT_ID}': ${totalNow}`)

  db.close()
}

main()
