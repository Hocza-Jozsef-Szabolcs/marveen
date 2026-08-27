#!/usr/bin/env node
// PreToolUse hard-gate: blocks a `git commit` on a release branch if
// BuildNumberV2.txt is not staged alongside it.
//
// Governance control (Józsi, 2026-08-15, VHR5 7.4.1.61: four developer commits
// since 2026-08-13 -- dbdcaaba, 9df96a30, 4fa6d2bd, 35e00473 -- followed every
// formal convention in commit.md section 0.5 (card line, hu/en body) but
// skipped the build-number step. The rule existed in prose only; nothing
// enforced it, so a compliant-looking commit silently skipped it four times
// in a row). Józsi, same day: "miert letezik olyan ut, amelyen meg lehet
// kerulni az ellenorzest, alapveto tervezesi hiba" -- this closes that gap.
//
// Scope: commit.md 0.5 names which branches are RELEASE branches per repo --
// most repos: `main`; VHR5: BOTH `7.4.1.61` and `7.4.1.60` (each an
// independent release branch with its own number sequence). That mapping is
// NOT derivable from the repo alone (build-szam-utkozes-meres skill: "a
// hatokor nem illett a repora, es ez nemán tortent" -- a scope claim is a
// claim like a number, and must be measured per repo, not assumed). Hence
// RELEASE_BRANCH_RULES below, keyed by repo path pattern.
//
// Why a hook and not only the VHR5 git pre-commit hook: that hook is
// per-machine (`.git/hooks` is not versioned, per its own header) and is
// bypassable with `git commit --no-verify`. This hook fires at the Claude
// Code tool-call layer, before the Bash command ever reaches the shell, so
// --no-verify does not apply to it -- it never gets that far.

import { readFileSync, existsSync, realpathSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { execFileSync } from 'node:child_process'

// repoPathPattern matches the git toplevel path (forward-slash normalised).
// First match wins; keep VHR5 before the catch-all.
const RELEASE_BRANCH_RULES = [
  // VHR5: two independent release branches, each with its own build-number
  // sequence (commit.md 0.5. pont, Józsi 2026-08-12).
  { repoPathPattern: /VHR ?5\/Delphi\/Projects\/VHR5$/, branches: ['7.4.1.61', '7.4.1.60'] },
  // Default for every other repo.
  { repoPathPattern: /.*/, branches: ['main'] },
]

function releaseBranchesFor(repoRoot) {
  const norm = repoRoot.replace(/\\/g, '/')
  for (const rule of RELEASE_BRANCH_RULES) {
    if (rule.repoPathPattern.test(norm)) return rule.branches
  }
  return ['main']
}

// A repo's build-number CONVENTION (bumps every commit vs. bumps only per
// release) is not derivable from the repo alone -- measured for JokerQ-SDK,
// whose last eight commits all carry the same value (buildszam-utkozes-kapu
// card, avalonia's measurement + marveen's requirement, 2026-08-14/comment
// 1928). This file is the SINGLE source for the convention switch: the
// history gate (buildszam-utkozes-kapu.sh) reads the same JSON, so the two
// gates cannot disagree about which repos are exempt from per-commit bumps.
function conventionsPath() {
  return process.env.BUILD_NUMBER_CONVENTIONS_PATH
    ?? join(dirname(fileURLToPath(import.meta.url)), 'build-number-conventions.json')
}

const KNOWN_CONVENTIONS = ['minden-commit-leptet', 'kiadasonkent-leptet']

// Independent review (ordog, buildszam-utkozes-kapu card, comment 3861) found
// three fail-open shapes in an earlier version of this function:
//   1. `new RegExp(undefined)` is /(?:)/ in JS, which matches EVERY string --
//      a rule with a missing/mistyped repoPathPattern silently exempted
//      every repo, not the one it was meant for.
//   2. `new RegExp(rule.repoPathPattern)` sat outside the try/catch -- an
//      invalid regex threw, crashing the hook process. A crashed PreToolUse
//      hook does not block, so this was a fail-OPEN, not a fail-safe.
//   3. The .sh side (Python `re`) and this side (JS RegExp) diverged on a
//      malformed rule instead of agreeing to skip it.
// The fix: validate EVERY field of EVERY rule before using it, skip (not
// match-all) anything invalid, and wrap the whole thing so nothing can
// throw past this function.
function conventionFor(repoRoot) {
  try {
    const cfg = JSON.parse(readFileSync(conventionsPath(), 'utf-8'))
    const norm = repoRoot.replace(/\\/g, '/')
    const overrides = Array.isArray(cfg.overrides) ? cfg.overrides : []

    for (const rule of overrides) {
      if (rule === null || typeof rule !== 'object') continue
      if (typeof rule.repoPathPattern !== 'string' || rule.repoPathPattern.length === 0) continue
      if (!KNOWN_CONVENTIONS.includes(rule.convention)) continue

      let matches
      try {
        matches = new RegExp(rule.repoPathPattern).test(norm)
      } catch {
        continue // invalid regex in this one rule -- skip it, keep checking the rest
      }
      if (matches) return rule.convention
    }

    return KNOWN_CONVENTIONS.includes(cfg.defaultConvention) ? cfg.defaultConvention : 'minden-commit-leptet'
  } catch {
    // Fail-safe: an unreadable/malformed config must NOT widen the gate's
    // enforcement -- it falls back to today's already-enforced behaviour.
    return 'minden-commit-leptet'
  }
}

// Matches `git commit` as an actual subcommand invocation (not a substring
// inside an unrelated word), optionally preceded by `-C <path>` / `--git-dir=`
// flags or a `cd X &&` prefix, which the extraction below also honours.
const GIT_COMMIT_RX = /\bgit\b[\s\S]*?\bcommit\b/

function extractExplicitRepoRoot(command) {
  // `git -C <path> commit ...` -- the path git will actually act on,
  // independent of the hook's own cwd.
  const m = command.match(/\bgit\s+-C\s+(?:"([^"]+)"|'([^']+)'|(\S+))/)
  if (!m) return null
  return m[1] ?? m[2] ?? m[3] ?? null
}

function gitToplevel(cwd) {
  try {
    return execFileSync('git', ['rev-parse', '--show-toplevel'], { cwd, encoding: 'utf-8' }).trim()
  } catch {
    return null
  }
}

function currentBranch(repoRoot) {
  try {
    return execFileSync('git', ['rev-parse', '--abbrev-ref', 'HEAD'], { cwd: repoRoot, encoding: 'utf-8' }).trim()
  } catch {
    return null
  }
}

function stagedFiles(repoRoot) {
  try {
    return execFileSync('git', ['diff', '--cached', '--name-only'], { cwd: repoRoot, encoding: 'utf-8' })
      .split('\n')
      .filter(Boolean)
  } catch {
    return []
  }
}

// Exported for the mutation self-test: pure decision, no process I/O.
export function gateDecision(toolName, toolInput, cwdOverride) {
  if (String(toolName ?? '') !== 'Bash') return { deny: false }
  const command = String(toolInput?.command ?? '')
  if (!GIT_COMMIT_RX.test(command)) return { deny: false }
  // `git commit --amend` on an already-pushed release commit is a separate
  // concern (rewrites history); this gate only concerns the staged-set of a
  // NEW commit, so amend is treated the same -- BuildNumberV2.txt still has
  // to be part of what's being recorded.

  const explicitRoot = extractExplicitRepoRoot(command)
  const cwd = explicitRoot ?? cwdOverride ?? process.cwd()
  const repoRoot = gitToplevel(cwd)
  if (!repoRoot) return { deny: false } // not a git repo -- nothing to gate

  const buildNumberPath = `${repoRoot}/BuildNumberV2.txt`
  if (!existsSync(buildNumberPath)) return { deny: false } // repo doesn't use this scheme

  const branch = currentBranch(repoRoot)
  if (!branch) return { deny: false }
  const releaseBranches = releaseBranchesFor(repoRoot)
  if (!releaseBranches.includes(branch)) return { deny: false } // commit.md 0.5: non-release branch, do not touch the number

  const staged = stagedFiles(repoRoot)
  if (staged.length === 0) return { deny: false } // nothing staged -- git itself will reject this commit

  // A "kiadasonkent-leptet" repo legitimately carries the same build number
  // across many consecutive commits -- forcing it into every staged set here
  // would fight the actual, measured convention instead of enforcing it.
  if (conventionFor(repoRoot) === 'kiadasonkent-leptet') return { deny: false }

  const buildNumberStaged = staged.some((f) => f === 'BuildNumberV2.txt')
  if (buildNumberStaged) return { deny: false }

  return { deny: true, repoRoot, branch }
}

function allow() { process.exit(0) }

function deny(reason) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason,
    },
  }))
  process.exit(0)
}

function isInvokedDirectly() {
  try {
    const self = realpathSync(fileURLToPath(import.meta.url))
    const entry = process.argv[1] ? realpathSync(process.argv[1]) : ''
    return self === entry
  } catch {
    return false
  }
}

if (isInvokedDirectly()) {
  let payload
  try {
    payload = JSON.parse(readFileSync(0, 'utf-8'))
  } catch {
    allow() // malformed/empty input must never break the agent's tool calls
  }
  const cwdOverride = payload?.cwd ?? undefined
  const result = gateDecision(payload?.tool_name, payload?.tool_input, cwdOverride)
  if (result.deny) {
    deny(
      `Build-szam kapu (governance hard-gate): a(z) "${result.branch}" kiadasi agon a BuildNumberV2.txt ` +
      `NINCS a staged fajlok kozott (${result.repoRoot}). commit.md 0.5. pont: minden commit a kiadasi ` +
      `agon lepteti a szamot. Elobb: olvasd be, novelt ertekkel Edit, "git add BuildNumberV2.txt", ` +
      `utana a commit.`
    )
  }
  allow()
}
