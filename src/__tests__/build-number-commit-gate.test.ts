import { describe, it, expect } from 'vitest'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
// @ts-expect-error -- plain .mjs hook script, no types
import { gateDecision } from '../../scripts/build-number-commit-gate.mjs'
import { injectBuildNumberGate } from '../web/agent-scaffold.js'

// Governance control (Józsi, 2026-08-15, VHR5 7.4.1.61): four developer commits
// (dbdcaaba, 9df96a30, 4fa6d2bd, 35e00473) followed commit.md's formal shape
// (card line, hu/en body) but skipped the build-number step -- nothing enforced
// it, so a compliant-looking commit silently skipped it four times in a row.
// "miert letezik olyan ut, amelyen meg lehet kerulni az ellenorzest, alapveto
// tervezesi hiba" -- this gate closes that gap at the tool-call layer, where
// `git commit --no-verify` (which bypasses the repo's OWN pre-commit hook)
// cannot reach it.

function makeRepo(): string {
  const dir = mkdtempSync(join(tmpdir(), 'buildnum-gate-'))
  execFileSync('git', ['init', '-q'], { cwd: dir })
  execFileSync('git', ['config', 'user.email', 'a@a.hu'], { cwd: dir })
  execFileSync('git', ['config', 'user.name', 'a'], { cwd: dir })
  writeFileSync(join(dir, 'BuildNumberV2.txt'), '1\n')
  writeFileSync(join(dir, 'Foo.cs'), 'class Foo {}\n')
  execFileSync('git', ['add', '-A'], { cwd: dir })
  execFileSync('git', ['commit', '-q', '-m', 'init'], { cwd: dir })
  execFileSync('git', ['branch', '-M', 'main'], { cwd: dir })
  return dir
}

describe('build-number-commit-gate gateDecision', () => {
  it('denies a git commit on a release branch with source staged but BuildNumberV2.txt NOT staged', () => {
    const dir = makeRepo()
    try {
      writeFileSync(join(dir, 'Foo.cs'), 'class Foo { void Bar() {} }\n')
      execFileSync('git', ['add', 'Foo.cs'], { cwd: dir })
      const result = gateDecision('Bash', { command: 'git commit -m "feat: x"' }, dir)
      expect(result.deny).toBe(true)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('allows the commit when BuildNumberV2.txt is staged too', () => {
    const dir = makeRepo()
    try {
      writeFileSync(join(dir, 'Foo.cs'), 'class Foo { void Bar() {} }\n')
      writeFileSync(join(dir, 'BuildNumberV2.txt'), '2\n')
      execFileSync('git', ['add', 'Foo.cs', 'BuildNumberV2.txt'], { cwd: dir })
      const result = gateDecision('Bash', { command: 'git commit -m "feat: x"' }, dir)
      expect(result.deny).toBe(false)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('allows a commit on a NON-release branch even without the build number staged', () => {
    const dir = makeRepo()
    try {
      execFileSync('git', ['checkout', '-q', '-b', 'feature/x'], { cwd: dir })
      writeFileSync(join(dir, 'Foo.cs'), 'class Foo { void Baz() {} }\n')
      execFileSync('git', ['add', 'Foo.cs'], { cwd: dir })
      const result = gateDecision('Bash', { command: 'git commit -m "feat: x"' }, dir)
      expect(result.deny).toBe(false)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('allows a commit in a repo that does not use BuildNumberV2.txt at all', () => {
    const dir = mkdtempSync(join(tmpdir(), 'buildnum-gate-nosch-'))
    try {
      execFileSync('git', ['init', '-q'], { cwd: dir })
      execFileSync('git', ['config', 'user.email', 'a@a.hu'], { cwd: dir })
      execFileSync('git', ['config', 'user.name', 'a'], { cwd: dir })
      writeFileSync(join(dir, 'f.txt'), 'x\n')
      execFileSync('git', ['add', '-A'], { cwd: dir })
      const result = gateDecision('Bash', { command: 'git commit -m "init"' }, dir)
      expect(result.deny).toBe(false)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('is inert on non-commit Bash commands and non-Bash tools', () => {
    expect(gateDecision('Bash', { command: 'git status' }).deny).toBe(false)
    expect(gateDecision('Bash', { command: 'echo "git commit is not a real one"' }).deny).toBe(false)
    expect(gateDecision('Write', { file_path: 'x' }).deny).toBe(false)
  })

  // buildszam-utkozes-kapu card (marveen, comment 1928): a repo's build-number
  // CONVENTION (bumps every commit vs. bumps only per release) is not
  // derivable from the repo alone -- measured for JokerQ-SDK, whose last
  // eight commits all carry 53. This hook enforces "minden-commit-leptet"
  // unconditionally; for a "kiadasonkent-leptet" repo that would force staging
  // BuildNumberV2.txt on commits where it legitimately isn't touched. The
  // switch must be a SHARED config, because the history gate
  // (buildszam-utkozes-kapu.sh) reads the same file.
  describe('build-number convention switch', () => {
    const envKey = 'BUILD_NUMBER_CONVENTIONS_PATH'

    function withConventionsPath(path: string | undefined, fn: () => void) {
      const original = process.env[envKey]
      if (path === undefined) delete process.env[envKey]
      else process.env[envKey] = path
      try {
        fn()
      } finally {
        if (original === undefined) delete process.env[envKey]
        else process.env[envKey] = original
      }
    }

    it('does NOT require BuildNumberV2.txt staged in a repo declared kiadasonkent-leptet', () => {
      const dir = makeRepo()
      try {
        const cfgPath = join(dir, 'conventions.json')
        writeFileSync(cfgPath, JSON.stringify({
          defaultConvention: 'minden-commit-leptet',
          overrides: [{ repoPathPattern: dir.replace(/\\/g, '/'), convention: 'kiadasonkent-leptet' }],
        }))
        writeFileSync(join(dir, 'Foo.cs'), 'class Foo { void Bar() {} }\n')
        execFileSync('git', ['add', 'Foo.cs'], { cwd: dir })
        withConventionsPath(cfgPath, () => {
          const result = gateDecision('Bash', { command: 'git commit -m "feat: x"' }, dir)
          expect(result.deny).toBe(false)
        })
      } finally {
        rmSync(dir, { recursive: true, force: true })
      }
    })

    // Independent review (ordog, kanban comment 3861, finding 1): `new
    // RegExp(undefined)` becomes /(?:)/ in JS, which matches EVERY string --
    // a rule with a missing/mistyped repoPathPattern silently exempts every
    // repo, not the one it was meant for.
    it('an override with a MISSING repoPathPattern does not silently match every repo', () => {
      const dir = makeRepo()
      try {
        const cfgPath = join(dir, 'conventions.json')
        writeFileSync(cfgPath, JSON.stringify({
          defaultConvention: 'minden-commit-leptet',
          // No repoPathPattern -- a typo'd config, not this repo's own dir.
          overrides: [{ convention: 'kiadasonkent-leptet' }],
        }))
        writeFileSync(join(dir, 'Foo.cs'), 'class Foo { void Bar() {} }\n')
        execFileSync('git', ['add', 'Foo.cs'], { cwd: dir })
        withConventionsPath(cfgPath, () => {
          const result = gateDecision('Bash', { command: 'git commit -m "feat: x"' }, dir)
          // Must still enforce -- a broken rule must not become a blanket exemption.
          expect(result.deny).toBe(true)
        })
      } finally {
        rmSync(dir, { recursive: true, force: true })
      }
    })

    // Independent review (ordog, finding 2): `new RegExp(rule.repoPathPattern)`
    // sat OUTSIDE the try/catch -- an invalid regex pattern threw an uncaught
    // exception, crashing the hook process instead of denying. A crashed
    // PreToolUse hook does not block -- this is a fail-OPEN, not a fail-safe.
    it('an override with an INVALID regex does not crash the gate (still enforces)', () => {
      const dir = makeRepo()
      try {
        const cfgPath = join(dir, 'conventions.json')
        writeFileSync(cfgPath, JSON.stringify({
          defaultConvention: 'minden-commit-leptet',
          overrides: [{ repoPathPattern: '[', convention: 'kiadasonkent-leptet' }],
        }))
        writeFileSync(join(dir, 'Foo.cs'), 'class Foo { void Bar() {} }\n')
        execFileSync('git', ['add', 'Foo.cs'], { cwd: dir })
        withConventionsPath(cfgPath, () => {
          expect(() => {
            const result = gateDecision('Bash', { command: 'git commit -m "feat: x"' }, dir)
            expect(result.deny).toBe(true)
          }).not.toThrow()
        })
      } finally {
        rmSync(dir, { recursive: true, force: true })
      }
    })

    // Independent review (ordog, finding 2, second shape): `overrides` itself
    // can be present but not an array (e.g. a hand-edited config mistake).
    it('a non-array "overrides" field does not crash the gate (still enforces)', () => {
      const dir = makeRepo()
      try {
        const cfgPath = join(dir, 'conventions.json')
        writeFileSync(cfgPath, JSON.stringify({
          defaultConvention: 'minden-commit-leptet',
          overrides: 'not-an-array',
        }))
        writeFileSync(join(dir, 'Foo.cs'), 'class Foo { void Bar() {} }\n')
        execFileSync('git', ['add', 'Foo.cs'], { cwd: dir })
        withConventionsPath(cfgPath, () => {
          expect(() => {
            const result = gateDecision('Bash', { command: 'git commit -m "feat: x"' }, dir)
            expect(result.deny).toBe(true)
          }).not.toThrow()
        })
      } finally {
        rmSync(dir, { recursive: true, force: true })
      }
    })

    // A broken rule followed by a VALID, matching rule must still apply the
    // valid one -- this is the shape that actually distinguishes "skip just
    // the bad rule and keep checking" from "crash and fall through to the
    // top-level default", which happen to produce the SAME outcome (deny:true)
    // for a lone bad rule and would otherwise mask a lost-safety-net mutation.
    // 🛑 The broken rule's OWN convention is deliberately set to the SAME
    //    value as defaultConvention, and the later valid rule to the OTHER
    //    value. This is what makes the test discriminate "properly skip the
    //    bad rule and keep checking" from EITHER known bug shape: a rule that
    //    wrongly matches everything (returns the bad rule's own convention,
    //    which here equals the default -- indistinguishable if we'd used the
    //    same convention for both rules) or a crash that falls through to the
    //    top-level default (same failure mode). Only the correct behaviour
    //    reaches the second rule and returns ITS convention.
    it('a broken rule does not stop a LATER valid, matching rule from applying', () => {
      const dir = makeRepo()
      try {
        const cfgPath = join(dir, 'conventions.json')
        writeFileSync(cfgPath, JSON.stringify({
          defaultConvention: 'minden-commit-leptet',
          overrides: [
            { convention: 'minden-commit-leptet' }, // broken: no repoPathPattern
            { repoPathPattern: dir.replace(/\\/g, '/'), convention: 'kiadasonkent-leptet' },
          ],
        }))
        writeFileSync(join(dir, 'Foo.cs'), 'class Foo { void Bar() {} }\n')
        execFileSync('git', ['add', 'Foo.cs'], { cwd: dir })
        withConventionsPath(cfgPath, () => {
          const result = gateDecision('Bash', { command: 'git commit -m "feat: x"' }, dir)
          expect(result.deny).toBe(false)
        })
      } finally {
        rmSync(dir, { recursive: true, force: true })
      }
    })

    it('a rule with an invalid regex does not stop a LATER valid, matching rule from applying', () => {
      const dir = makeRepo()
      try {
        const cfgPath = join(dir, 'conventions.json')
        writeFileSync(cfgPath, JSON.stringify({
          defaultConvention: 'minden-commit-leptet',
          overrides: [
            { repoPathPattern: '[', convention: 'minden-commit-leptet' }, // broken regex
            { repoPathPattern: dir.replace(/\\/g, '/'), convention: 'kiadasonkent-leptet' },
          ],
        }))
        writeFileSync(join(dir, 'Foo.cs'), 'class Foo { void Bar() {} }\n')
        execFileSync('git', ['add', 'Foo.cs'], { cwd: dir })
        withConventionsPath(cfgPath, () => {
          const result = gateDecision('Bash', { command: 'git commit -m "feat: x"' }, dir)
          expect(result.deny).toBe(false)
        })
      } finally {
        rmSync(dir, { recursive: true, force: true })
      }
    })

    // Independent review (ordog, finding 1, second shape): an override whose
    // "convention" value is not one of the two known values must not be
    // treated as a match either.
    it('an override with an UNKNOWN convention value is skipped, not applied', () => {
      const dir = makeRepo()
      try {
        const cfgPath = join(dir, 'conventions.json')
        writeFileSync(cfgPath, JSON.stringify({
          defaultConvention: 'minden-commit-leptet',
          overrides: [{ repoPathPattern: dir.replace(/\\/g, '/'), convention: 'kiadasonkent-lep' }],
        }))
        writeFileSync(join(dir, 'Foo.cs'), 'class Foo { void Bar() {} }\n')
        execFileSync('git', ['add', 'Foo.cs'], { cwd: dir })
        withConventionsPath(cfgPath, () => {
          const result = gateDecision('Bash', { command: 'git commit -m "feat: x"' }, dir)
          expect(result.deny).toBe(true)
        })
      } finally {
        rmSync(dir, { recursive: true, force: true })
      }
    })

    it('falls back to minden-commit-leptet (todays enforced behaviour) when the config is unreadable', () => {
      const dir = makeRepo()
      try {
        writeFileSync(join(dir, 'Foo.cs'), 'class Foo { void Bar() {} }\n')
        execFileSync('git', ['add', 'Foo.cs'], { cwd: dir })
        withConventionsPath(join(dir, 'does-not-exist.json'), () => {
          const result = gateDecision('Bash', { command: 'git commit -m "feat: x"' }, dir)
          expect(result.deny).toBe(true)
        })
      } finally {
        rmSync(dir, { recursive: true, force: true })
      }
    })

    // Exercises the SHIPPED scripts/build-number-conventions.json (no env
    // override) against the real, measured JokerQ-SDK case -- the path
    // suffix is what the shipped override matches on.
    it('applies the shipped kiadasonkent-leptet override for JokerQ-SDK (real measured case)', () => {
      const base = mkdtempSync(join(tmpdir(), 'buildnum-gate-sdk-'))
      const dir = join(base, 'QCassa.com', 'JokerQ-SDK')
      try {
        execFileSync('mkdir', ['-p', dir])
        execFileSync('git', ['init', '-q'], { cwd: dir })
        execFileSync('git', ['config', 'user.email', 'a@a.hu'], { cwd: dir })
        execFileSync('git', ['config', 'user.name', 'a'], { cwd: dir })
        writeFileSync(join(dir, 'BuildNumberV2.txt'), '53\n')
        writeFileSync(join(dir, 'Foo.cs'), 'class Foo {}\n')
        execFileSync('git', ['add', '-A'], { cwd: dir })
        execFileSync('git', ['commit', '-q', '-m', 'init'], { cwd: dir })
        execFileSync('git', ['branch', '-M', 'main'], { cwd: dir })
        writeFileSync(join(dir, 'Foo.cs'), 'class Foo { void Bar() {} }\n')
        execFileSync('git', ['add', 'Foo.cs'], { cwd: dir })
        withConventionsPath(undefined, () => {
          const result = gateDecision('Bash', { command: 'git commit -m "fix: x"' }, dir)
          expect(result.deny).toBe(false)
        })
      } finally {
        rmSync(base, { recursive: true, force: true })
      }
    })
  })

  // VHR5 names TWO independent release branches, each with its own build-number
  // sequence (commit.md 0.5. pont, Józsi 2026-08-12) -- neither is "main".
  it('recognises BOTH VHR5 release branches (7.4.1.61 and 7.4.1.60), not just main', () => {
    const base = mkdtempSync(join(tmpdir(), 'buildnum-gate-vhr5-'))
    const dir = join(base, 'VHR 5', 'Delphi', 'Projects', 'VHR5')
    try {
      execFileSync('mkdir', ['-p', dir])
      execFileSync('git', ['init', '-q'], { cwd: dir })
      execFileSync('git', ['config', 'user.email', 'a@a.hu'], { cwd: dir })
      execFileSync('git', ['config', 'user.name', 'a'], { cwd: dir })
      writeFileSync(join(dir, 'BuildNumberV2.txt'), '1\n')
      writeFileSync(join(dir, 'Foo.pas'), 'unit Foo;\n')
      execFileSync('git', ['add', '-A'], { cwd: dir })
      execFileSync('git', ['commit', '-q', '-m', 'init'], { cwd: dir })
      for (const branch of ['7.4.1.61', '7.4.1.60']) {
        execFileSync('git', ['checkout', '-q', '-B', branch], { cwd: dir })
        writeFileSync(join(dir, 'Foo.pas'), `unit Foo; // ${branch}\n`)
        execFileSync('git', ['add', 'Foo.pas'], { cwd: dir })
        const result = gateDecision('Bash', { command: 'git commit -m "fix: x"' }, dir)
        expect(result.deny).toBe(true)
      }
    } finally {
      rmSync(base, { recursive: true, force: true })
    }
  })
})

describe('build-number gate scaffold wiring', () => {
  it('injectBuildNumberGate is idempotent (no duplicate on respawn)', () => {
    const s: Record<string, unknown> = {}
    injectBuildNumberGate(s)
    injectBuildNumberGate(s)
    const pre = ((s.hooks as Record<string, unknown>).PreToolUse as unknown[])
    expect(pre.filter((e) => JSON.stringify(e).includes('build-number-commit-gate.mjs')).length).toBe(1)
  })
  it('the hook matcher fires on Bash', () => {
    const s: Record<string, unknown> = {}
    injectBuildNumberGate(s)
    const pre = ((s.hooks as Record<string, unknown>).PreToolUse as Array<{ matcher: string }>)
    const entry = pre.find((e) => JSON.stringify(e).includes('build-number-commit-gate.mjs'))
    const re = new RegExp(`^(?:${entry!.matcher})$`)
    expect(re.test('Bash')).toBe(true)
  })
})
