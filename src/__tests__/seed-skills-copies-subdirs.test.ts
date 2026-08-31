import { describe, it, expect } from 'vitest'
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'

// fleet-helper-hianyzo-scripts-mappa-20260811: a shipped seed-skill with a
// subdirectory (seed-skills/fleet-helper/scripts/) was never installed under
// ~/.claude/skills/fleet-helper/ -- the skill's SKILL.md references files that
// do not exist on disk. Root cause: the seed-skills copy loop in update.sh,
// install-macos.sh and install-linux.sh filters entries with `[ -f "$f" ]` and
// copies with plain `cp`, so a subdirectory is silently skipped. Any future
// seed-skill that ships a subdirectory hits the same loss on every install.
//
// This test runs the REAL copy block sliced out of each shipped installer, so
// a regression in the shipped file (not a reimplementation of it) fails here.

const ROOT = join(__dirname, '..', '..')

function sliceBlock(src: string, startMarker: string, endMarker: string): string {
  const start = src.indexOf(startMarker)
  if (start < 0) throw new Error(`start marker not found: ${startMarker}`)
  const end = src.indexOf(endMarker, start)
  if (end < 0) throw new Error(`end marker not found: ${endMarker}`)
  return src.slice(start, end)
}

const UPDATE_BLOCK = sliceBlock(
  readFileSync(join(ROOT, 'update.sh'), 'utf-8'),
  '# Seed skills (no template vars needed, safe without .env).',
  '# Seed scheduled tasks (requires MAIN_AGENT_ID'
)

const MACOS_BLOCK = sliceBlock(
  readFileSync(join(ROOT, 'install-macos.sh'), 'utf-8'),
  '# Seed skills: fleet-level skills from seed-skills/ into ~/.claude/skills/',
  '# Seed scheduled tasks: from seed-scheduled-tasks/'
)

const LINUX_BLOCK = sliceBlock(
  readFileSync(join(ROOT, 'install-linux.sh'), 'utf-8'),
  '# Seed skills: fleet-level skills from seed-skills/ into ~/.claude/skills/',
  'INSTALL_STEP="ollama-whisper"'
)

/** A throwaway seed source with one skill that ships a subdirectory (like fleet-helper/scripts/). */
function makeFixture() {
  const base = mkdtempSync(join(tmpdir(), 'seedsubdir-'))
  const seedSkill = join(base, 'seed-skills', 'demo-skill')
  mkdirSync(join(seedSkill, 'scripts'), { recursive: true })
  writeFileSync(join(seedSkill, 'SKILL.md'), 'top-level doc\n')
  writeFileSync(join(seedSkill, 'scripts', 'helper.py'), 'print("shipped helper")\n')
  const skillsTarget = join(base, 'home-skills')
  mkdirSync(skillsTarget, { recursive: true })
  return { base, install: join(base), skillsTarget }
}

function runBlock(block: string, install: string, skillsTarget: string, extraEnv = ''): { out: string; code: number } {
  const script = join(install, 'probe.sh')
  writeFileSync(
    script,
    [
      'set -u',
      'GREEN=""; NC=""',
      'ok() { :; }', // install-linux.sh's log helper -- not defined outside its own script
      `INSTALL_DIR="${install}"`,
      `SKILLS_DIR="${skillsTarget}"`,
      extraEnv,
      block,
    ].join('\n') + '\n'
  )
  try {
    return { out: execFileSync('bash', [script], { encoding: 'utf-8' }).trim(), code: 0 }
  } catch (e) {
    const err = e as { stdout?: string; stderr?: string; status?: number }
    return { out: `${String(err.stdout ?? '')}${String(err.stderr ?? '')}`.trim(), code: err.status ?? -1 }
  }
}

describe.each([
  ['update.sh (fresh seed)', UPDATE_BLOCK, 'RESEED_FLEET="0"'],
  ['update.sh (--reseed-fleet)', UPDATE_BLOCK, 'RESEED_FLEET="1"'],
  ['install-macos.sh', MACOS_BLOCK, ''],
  ['install-linux.sh', LINUX_BLOCK, ''],
])('%s copies a shipped subdirectory', (_label, block, extraEnv) => {
  it('installs the subdirectory and its file, not just top-level files', () => {
    const f = makeFixture()
    try {
      const target = join(f.skillsTarget, 'demo-skill')
      if (extraEnv.includes('RESEED_FLEET="1"')) {
        // reseed-fleet forces a refresh of an already-installed skill dir
        mkdirSync(target, { recursive: true })
        writeFileSync(join(target, 'SKILL.md'), 'stale top-level doc\n')
      }

      const r = runBlock(block, f.install, f.skillsTarget, extraEnv)
      expect(r.code).toBe(0)

      expect(existsSync(join(target, 'SKILL.md'))).toBe(true)
      expect(existsSync(join(target, 'scripts'))).toBe(true)
      expect(existsSync(join(target, 'scripts', 'helper.py'))).toBe(true)
      expect(readFileSync(join(target, 'scripts', 'helper.py'), 'utf-8')).toBe('print("shipped helper")\n')
    } finally {
      rmSync(f.base, { recursive: true, force: true })
    }
  })
})
