import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

// Kártya 6784a1fe: nincs tartalmi kapu a fő agens kimenő szövegén. A
// scripts/hooks/outgoing-copy-gate.py hiányzott a repóból -- csak a
// scripts/email-send-gate.mjs hard-deny létezett, ami sub-agenseket tilt
// email-küldéstől, de a FŐ agens saját küldéseit tartalmilag nem vizsgálta
// semmi. Ez a fájl a kártya elfogadási feltételét méri: a kapu elutasítja
// az ékezet-hiányos és az em dash-t tartalmazó szöveget, mindkét
// csatornán (email-Bash, Telegram), ÉS felismeri ennek az installnak a
// saját email-küldő szkriptjét (scripts/nas-mail-send.py).
const ROOT = join(__dirname, '..', '..')
const GATE = join(ROOT, 'scripts', 'hooks', 'outgoing-copy-gate.py')

// The email/Bash leg is deliberately fail-closed when the owner-specific
// name-rules file is missing (GATEPERSIST816(2)) -- correct in production,
// but it would make every end-to-end test below block regardless of the
// audited text. A throwaway rules file (one harmless, never-matching
// pattern) isolates these tests from that fail-closed branch without
// touching the real, gitignored store/outgoing-copy-gate-rules.json.
let rulesDir: string
let rulesPath: string

beforeAll(() => {
  rulesDir = mkdtempSync(join(tmpdir(), 'outgoing-copy-gate-test-'))
  rulesPath = join(rulesDir, 'rules.json')
  writeFileSync(rulesPath, JSON.stringify({ bad_name_patterns: ['ZZZ_SOSEM_MATCHEL_ZZZ'], correction: 'teszt' }))
})

afterAll(() => {
  rmSync(rulesDir, { recursive: true, force: true })
})

function runGate(payload: unknown): { code: number; stderr: string; stdout: string } {
  try {
    const stdout = execFileSync('python3', [GATE], {
      input: JSON.stringify(payload),
      encoding: 'utf-8',
      env: { ...process.env, OUTGOING_COPY_GATE_RULES: rulesPath },
    })
    return { code: 0, stderr: '', stdout }
  } catch (err: any) {
    return { code: err.status ?? 1, stderr: String(err.stderr ?? ''), stdout: String(err.stdout ?? '') }
  }
}

function audit(text: string): string[] {
  const out = execFileSync('python3', ['-c', `
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("gate", ${JSON.stringify(GATE)})
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
print(json.dumps(g.audit(sys.argv[1])))
`, text], { encoding: 'utf-8' })
  return JSON.parse(out.trim())
}

function isSend(cmd: string): boolean {
  const out = execFileSync('python3', ['-c', `
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("gate", ${JSON.stringify(GATE)})
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
print(json.dumps(g.is_send_invocation(sys.argv[1])))
`, cmd], { encoding: 'utf-8' })
  return JSON.parse(out.trim())
}

describe('outgoing-copy gate: audit() catches the two standing CLAUDE.md rules (kártya 6784a1fe elfogadási feltétel)', () => {
  it('accent-less Hungarian text is rejected', () => {
    const probs = audit('Szia Balint, itt van a Marveen licenckulcsod es a telepito.')
    expect(probs.some((p) => p.includes('HIANYZO EKEZETEK'))).toBe(true)
  })

  it('an em dash is rejected', () => {
    const probs = audit('A kártya kész — nincs több teendő.')
    expect(probs.some((p) => p.includes('GONDOLATJEL'))).toBe(true)
  })

  it('correctly accented, em-dash-free Hungarian prose passes', () => {
    expect(audit('Szia Bálint, itt van a Marveen licenckulcsod és a telepítő.')).toEqual([])
  })
})

describe('outgoing-copy gate: this install\'s mail sender is recognized (nas-mail-send.py)', () => {
  it('a nas-mail-send.py invocation with a recipient fires, direct path and via python3', () => {
    expect(isSend('python3 scripts/nas-mail-send.py --to a@b.hu --subject "X" --body "Y"')).toBe(true)
    expect(isSend('./scripts/nas-mail-send.py --to=a@b.hu < /tmp/body.txt')).toBe(true)
  })

  it('a nas-mail-send.py invocation WITHOUT a recipient does not fire (--help is not a send)', () => {
    expect(isSend('python3 scripts/nas-mail-send.py --help')).toBe(false)
  })

  it('the upstream-default support-mail/send.py still fires unchanged (this install also has it)', () => {
    expect(isSend('python3 scripts/support-mail/send.py --to a@b.hu --subject X --body Y')).toBe(true)
  })
})

describe('outgoing-copy gate: end-to-end PreToolUse contract, Bash/email leg (fail-closed)', () => {
  it('blocks a nas-mail-send.py call whose --body is missing accents', () => {
    const res = runGate({
      tool_name: 'Bash',
      tool_input: {
        command: 'python3 scripts/nas-mail-send.py --to ugyfel@ceg.hu --subject "Info" --body "Szia, itt van a fajl es a jelszo."',
      },
    })
    expect(res.code).toBe(2)
    expect(res.stderr).toContain('HIANYZO EKEZETEK')
  })

  it('blocks a nas-mail-send.py call whose --body contains an em dash', () => {
    const res = runGate({
      tool_name: 'Bash',
      tool_input: {
        command: 'python3 scripts/nas-mail-send.py --to ugyfel@ceg.hu --subject "Info" --body "Kész — köszönöm."',
      },
    })
    expect(res.code).toBe(2)
    expect(res.stderr).toContain('GONDOLATJEL')
  })

  it('allows a nas-mail-send.py call whose --body is correct Hungarian, no em dash', () => {
    const res = runGate({
      tool_name: 'Bash',
      tool_input: {
        command: 'python3 scripts/nas-mail-send.py --to ugyfel@ceg.hu --subject "Info" --body "Szia, itt van a fájl és a jelszó."',
      },
    })
    expect(res.code).toBe(0)
  })

  it('a non-send Bash command passes untouched', () => {
    const res = runGate({ tool_name: 'Bash', tool_input: { command: 'git status --short' } })
    expect(res.code).toBe(0)
  })
})

describe('outgoing-copy gate: end-to-end PreToolUse contract, Telegram leg (fail-open on internal error, blocks on a found problem)', () => {
  it('blocks a Telegram reply missing accents', () => {
    const res = runGate({
      tool_name: 'mcp__plugin_telegram_telegram__reply',
      tool_input: { chat_id: 0, text: 'Szia, keszen van a jelentes, koszonom.' },
    })
    expect(res.code).toBe(2)
    expect(res.stderr).toContain('HIANYZO EKEZETEK')
  })

  it('blocks a Telegram reply containing an em dash', () => {
    const res = runGate({
      tool_name: 'mcp__plugin_telegram_telegram__reply',
      tool_input: { chat_id: 0, text: 'Kész — köszönöm szépen.' },
    })
    expect(res.code).toBe(2)
    expect(res.stderr).toContain('GONDOLATJEL')
  })

  it('allows a correct Telegram reply', () => {
    const res = runGate({
      tool_name: 'mcp__plugin_telegram_telegram__reply',
      tool_input: { chat_id: 0, text: 'Kész, köszönöm szépen.' },
    })
    expect(res.code).toBe(0)
  })

  it('an empty (files-only) Telegram reply passes: nothing to audit', () => {
    const res = runGate({
      tool_name: 'mcp__plugin_telegram_telegram__reply',
      tool_input: { chat_id: 0, files: ['/tmp/x.png'] },
    })
    expect(res.code).toBe(0)
  })
})

describe('GATEPERSIST816(2): missing name-rules file -- email fail-closed, telegram fail-open+loud', () => {
  // Independent of the beforeAll fixture: points OUTGOING_COPY_GATE_RULES at
  // a path that does not exist, reproducing a fresh install with no rules
  // file yet.
  function runWithoutRules(payload: unknown): { code: number; stderr: string; stdout: string } {
    try {
      const stdout = execFileSync('python3', [GATE], {
        input: JSON.stringify(payload),
        encoding: 'utf-8',
        env: { ...process.env, OUTGOING_COPY_GATE_RULES: join(rulesDir, 'nincs-ilyen.json') },
      })
      return { code: 0, stderr: '', stdout }
    } catch (err: any) {
      return { code: err.status ?? 1, stderr: String(err.stderr ?? ''), stdout: String(err.stdout ?? '') }
    }
  }

  it('blocks an otherwise-correct email send when the rules file is missing', () => {
    const res = runWithoutRules({
      tool_name: 'Bash',
      tool_input: { command: 'python3 scripts/nas-mail-send.py --to ugyfel@ceg.hu --subject "Info" --body "Szia, itt van a fájl és a jelszó."' },
    })
    expect(res.code).toBe(2)
    expect(res.stderr).toContain('NEV-SZABALY')
  })

  it('an otherwise-correct Telegram reply still goes out (fail-open), but with a loud systemMessage', () => {
    const res = runWithoutRules({
      tool_name: 'mcp__plugin_telegram_telegram__reply',
      tool_input: { chat_id: 0, text: 'Kész, köszönöm szépen.' },
    })
    expect(res.code).toBe(0)
    expect(res.stdout).toContain('NEV-SZABALY')
  })
})
