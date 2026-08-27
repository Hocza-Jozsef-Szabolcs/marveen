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
//
// Independent review, second round (ordog, comment 3861, finding 3 / card
// #1085 point B, Marveen decision 3871 point 2): python `re` and JS RegExp
// are not the same grammar. Some constructs are only valid on ONE side (a
// crash-vs-match split, already contained by the try/catch above); others
// are valid syntax on BOTH sides but mean something DIFFERENT there -- no
// crash, no error, just a silent, opposite decision. `\Z` is the sharpest
// example: a Python-only end-of-string anchor that JS treats as a literal
// letter "Z", so the SAME pattern string matches a different set of paths
// on each side. usesOnlyCommonRegexSubset() rejects every construct known to
// diverge (named groups in EITHER dialect, lookbehind, possessive
// quantifiers, unicode property escapes, \A/\Z) BEFORE the pattern is
// compiled, on both readers of this file (this hook and the mirrored
// python check in buildszam-utkozes-kapu.sh) -- so a structurally
// questionable rule is skipped identically everywhere, never matched on one
// side and skipped on the other.
const DIVERGENT_REGEX_CONSTRUCTS = [
  /\(\?(?!:)/, // any special group other than the non-capturing (?:...) --
  // covers named groups (?P<x>/(?<x>), lookaround, atomic groups (?>...),
  // and inline flag groups (?i) in one rule instead of enumerating each.
  /[*+?}]\+/, // possessive quantifier (*+, ++, ?+, {n,m}+) -- Python 3.11+
  // only, no JS equivalent.
  /\\k</, // named backreference -- Python: (?P=name), JS: \k<name>; neither
  // side accepts the other's syntax, and a bare \k< is JS-only besides.
  /\\[AZ]/, // Python-only \A/\Z anchors -- JS silently reads them as the
  // literal letters A/Z instead of erroring, which is the dangerous case:
  // no crash on either side, just a different match.
  /\\[pP]\{/, // unicode property escape -- support/flag requirements differ
  // between the two engines.
]

// Exported for the mutation self-test and for reuse by the sibling readers
// of build-number-conventions.json that need the identical decision.
export function usesOnlyCommonRegexSubset(pattern) {
  return !DIVERGENT_REGEX_CONSTRUCTS.some((rx) => rx.test(pattern))
}

function conventionFor(repoRoot) {
  try {
    const cfg = JSON.parse(readFileSync(conventionsPath(), 'utf-8'))
    const norm = repoRoot.replace(/\\/g, '/')
    const overrides = Array.isArray(cfg.overrides) ? cfg.overrides : []

    for (const rule of overrides) {
      if (rule === null || typeof rule !== 'object') continue
      if (typeof rule.repoPathPattern !== 'string' || rule.repoPathPattern.length === 0) continue
      if (!KNOWN_CONVENTIONS.includes(rule.convention)) continue
      if (!usesOnlyCommonRegexSubset(rule.repoPathPattern)) continue

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

// Matches `git merge` the same way. Coverage measurement (buildszam-utkozes-
// kapu card #1085, backend, comment 3870): ALL 46 measured agent-attributed
// no-bump commits on JokerQ/QuantumAE main were committed on a feature
// branch (worktree) and landed on main via a merge in the main checkout --
// the commit-time check above never fires there (HEAD wasn't the release
// branch), and until now nothing re-checked the number at the moment those
// commits actually reached the release branch. Marveen (comment 3871, point
// 3): the gate must cover that landing moment too, not just direct commits.
const GIT_MERGE_RX = /\bgit\b[\s\S]*?\bmerge\b/

// Flags that consume a separate following token (its value), so that token
// must not be mistaken for the ref being merged in.
const MERGE_FLAGS_WITH_VALUE = new Set(['-m', '-F', '-s', '-X', '--file', '--strategy', '--strategy-option', '--into-name'])

// `git merge --abort|--continue|--quit` resolves an in-progress merge -- it
// takes no ref and lands nothing new, so it is not a "landing" event.
const MERGE_NO_REF_FLAGS = new Set(['--abort', '--continue', '--quit'])

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

// Value of BuildNumberV2.txt at a given ref (not the working tree) -- null if
// the ref does not exist or does not carry the file.
function buildNumberAtRef(repoRoot, ref) {
  try {
    return execFileSync('git', ['show', `${ref}:BuildNumberV2.txt`], { cwd: repoRoot, encoding: 'utf-8' }).trim()
  } catch {
    return null
  }
}

// Tokenize a shell command line, keeping quoted segments (e.g. a `-m "msg
// with spaces"` value) as one token with the surrounding quotes stripped.
// Deliberately simple -- good enough for the flag/ref shapes this gate needs
// to recognise, not a general shell parser.
function tokenize(command) {
  const tokens = command.match(/"[^"]*"|'[^']*'|\S+/g) ?? []
  return tokens.map((t) => (
    (t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'"))
      ? t.slice(1, -1)
      : t
  ))
}

// The ref a `git merge <ref>` (or `git cherry-pick`, `git rebase`, etc, if
// ever extended) would bring in -- the first token after the subcommand that
// is not a flag and not a flag's value. Returns null for --abort/--continue/
// --quit (no ref involved) or if no ref token can be found.
function mergeRefArgument(command) {
  const tokens = tokenize(command)
  const mergeIdx = tokens.indexOf('merge')
  if (mergeIdx === -1) return null
  for (let i = mergeIdx + 1; i < tokens.length; i++) {
    const t = tokens[i]
    if (MERGE_NO_REF_FLAGS.has(t)) return null
    if (t.startsWith('-')) {
      if (MERGE_FLAGS_WITH_VALUE.has(t)) i++ // skip the flag's value token too
      continue
    }
    return t
  }
  return null
}

// Shared prefix: resolve the repo/branch this command would act on, and bail
// out early with an allow for every case that isn't "a release branch that
// actually uses BuildNumberV2.txt". Returns null (meaning: caller should
// allow) once resolved-but-inapplicable, or { repoRoot, branch } otherwise.
function releaseBranchContext(command, cwdOverride) {
  const explicitRoot = extractExplicitRepoRoot(command)
  const cwd = explicitRoot ?? cwdOverride ?? process.cwd()
  const repoRoot = gitToplevel(cwd)
  if (!repoRoot) return null // not a git repo -- nothing to gate

  const buildNumberPath = `${repoRoot}/BuildNumberV2.txt`
  if (!existsSync(buildNumberPath)) return null // repo doesn't use this scheme

  const branch = currentBranch(repoRoot)
  if (!branch) return null
  const releaseBranches = releaseBranchesFor(repoRoot)
  if (!releaseBranches.includes(branch)) return null // commit.md 0.5: non-release branch, do not touch the number

  return { repoRoot, branch }
}

function commitDecision(command, cwdOverride) {
  const ctx = releaseBranchContext(command, cwdOverride)
  if (!ctx) return { deny: false }
  const { repoRoot, branch } = ctx

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

function mergeDecision(command, cwdOverride) {
  const ref = mergeRefArgument(command)
  if (!ref) return { deny: false } // --abort/--continue/--quit, or no parseable ref

  const ctx = releaseBranchContext(command, cwdOverride)
  if (!ctx) return { deny: false }
  const { repoRoot, branch } = ctx

  // Same shared convention switch as the commit path (build-number-
  // conventions.json) -- a "kiadasonkent-leptet" repo may legitimately merge
  // in commits that never touched BuildNumberV2.txt.
  if (conventionFor(repoRoot) === 'kiadasonkent-leptet') return { deny: false }

  const currentValue = buildNumberAtRef(repoRoot, 'HEAD')
  const incomingValue = buildNumberAtRef(repoRoot, ref)
  const currentNum = currentValue === null ? NaN : Number.parseInt(currentValue, 10)
  const incomingNum = incomingValue === null ? NaN : Number.parseInt(incomingValue, 10)

  // Fail-closed: an unparsable/missing value on either side must not widen
  // the gate -- it denies and lets a human/agent look at it directly, same
  // spirit as the config fail-safe above.
  if (!Number.isFinite(currentNum) || !Number.isFinite(incomingNum)) return { deny: true, repoRoot, branch }
  if (incomingNum > currentNum) return { deny: false }

  return { deny: true, repoRoot, branch }
}

// Exported for the mutation self-test: pure decision, no process I/O.
export function gateDecision(toolName, toolInput, cwdOverride) {
  if (String(toolName ?? '') !== 'Bash') return { deny: false }
  const command = String(toolInput?.command ?? '')

  // `git commit --amend` on an already-pushed release commit is a separate
  // concern (rewrites history); this gate only concerns the staged-set of a
  // NEW commit, so amend is treated the same -- BuildNumberV2.txt still has
  // to be part of what's being recorded.
  if (GIT_COMMIT_RX.test(command)) {
    const result = commitDecision(command, cwdOverride)
    if (result.deny) return result
  }

  if (GIT_MERGE_RX.test(command)) {
    const result = mergeDecision(command, cwdOverride)
    if (result.deny) return result
  }

  return { deny: false }
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
