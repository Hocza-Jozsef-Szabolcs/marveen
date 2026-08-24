// The main agent's PROJECT-level .claude/settings.json (repo root, git-tracked)
// is NOT covered by ensureAgentHooks' automatic legacy-upgrade pass: that
// function only maintains agentSettingsPath(MAIN_AGENT_ID), which resolves to
// the USER-level ~/.claude/settings.json, a different file. A bare
// `python3 "$CLAUDE_PROJECT_DIR/scripts/hooks/X.py"` command in the
// project-level file silently exits non-zero when the variable is empty in
// the running channels session -- python3 can't open '/scripts/hooks/X.py' --
// which blocks every UserPromptSubmit/PostToolUse/SessionStart hook.
import { describe, it, expect } from 'vitest'
import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { PROJECT_ROOT } from '../config.js'

describe('main agent project-level settings.json hook commands', () => {
  const settingsPath = join(PROJECT_ROOT, '.claude', 'settings.json')
  const settings = JSON.parse(readFileSync(settingsPath, 'utf-8'))

  type HookEntry = { hooks?: Array<{ command?: string }> }
  const allCommands: string[] = []
  for (const entries of Object.values(settings.hooks ?? {})) {
    for (const entry of entries as HookEntry[]) {
      for (const h of entry.hooks ?? []) {
        if (h.command) allCommands.push(h.command)
      }
    }
  }

  it('has hook commands to check (sanity)', () => {
    expect(allCommands.length).toBeGreaterThan(0)
  })

  it('never runs a scripts/hooks/*.py command through a bare, unguarded $CLAUDE_PROJECT_DIR expansion', () => {
    const unsafe = allCommands.filter(
      (c) => c.includes('scripts/hooks/') && c.includes('$CLAUDE_PROJECT_DIR') && !c.startsWith("bash -c"),
    )
    expect(unsafe).toEqual([])
  })

  it('every scripts/hooks/*.py command resolves to a script that exists on disk right now', () => {
    for (const c of allCommands) {
      const m = c.match(/\/[^\s"']+\/scripts\/hooks\/[^\s"']+\.py/)
      if (!m) continue
      const resolved = m[0].replace('$CLAUDE_PROJECT_DIR', PROJECT_ROOT)
      expect({ command: c, path: resolved, exists: existsSync(resolved) })
        .toEqual({ command: c, path: resolved, exists: true })
    }
  })
})
