import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  rmSync,
  readFileSync,
  lstatSync,
  readlinkSync,
  realpathSync,
  symlinkSync,
} from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'

// hu: Ugyanaz a sandbox-alak, mint az isolated-config-mcp-reconcile.test.ts-ben:
//     a homedir() es az agentDir() egy eldobhato temp-fara mutat, tehat ez a
//     teszt a gep VALODI ~/.claude-jahoz (es a valodi eles
//     ~/.claude/channels/telegram-marveen allapot-konyvtarhoz) hozza sem er.
// en: Same sandbox shape: homedir() and agentDir() are redirected into a
//     throwaway temp tree, so the real ~/.claude is never touched.
let SANDBOX = ''
vi.mock('node:os', async (orig) => {
  const actual = await orig<typeof import('node:os')>()
  return { ...actual, homedir: () => join(SANDBOX, 'home') }
})
vi.mock('../web/agent-config.js', async (orig) => {
  const actual = await orig<typeof import('../web/agent-config.js')>()
  return { ...actual, agentDir: (name: string) => join(SANDBOX, 'agents', name) }
})

const { ensureIsolatedChannelConfigDir } = await import('../web/agent-process.js')

const AGENT = 'testagent'
const MAIN_TOKEN = 'FO-BOT-TOKEN'
const AGENT_TOKEN = 'FEJ-SAJAT-TOKEN'

function isolatedCfg(): string { return join(SANDBOX, 'agents', AGENT, '.claude-config') }
function agentOwnState(): string { return join(SANDBOX, 'agents', AGENT, '.claude', 'channels', 'telegram') }

// hu: A plugin-szerver feloldasa <PROVIDER>_STATE_DIR env NELKUL
//     (telegram/0.0.7/server.ts:27-28): CLAUDE_CONFIG_DIR/channels/<provider>.
//     A teszt EZT az utat jarja vegig -- ez az, amit egy Task-subagens
//     MCP-szervere lat.
// en: How the plugin server resolves its state dir with no *_STATE_DIR env.
function pluginStateDir(configDir: string): string {
  return join(configDir, 'channels', 'telegram')
}

function seedSandbox(): void {
  SANDBOX = mkdtempSync(join(tmpdir(), 'chanlink-'))

  // A kozos ~/.claude, benne a FO ELES csatorna-allapottal es a
  // `telegram -> telegram-marveen` symlinkkel, pontosan mint elesben.
  const claude = join(SANDBOX, 'home', '.claude')
  mkdirSync(claude, { recursive: true })
  writeFileSync(join(claude, 'settings.json'), JSON.stringify({ enabledPlugins: {} }))
  const mainState = join(claude, 'channels', 'telegram-marveen')
  mkdirSync(mainState, { recursive: true })
  writeFileSync(join(mainState, '.env'), `TELEGRAM_BOT_TOKEN=${MAIN_TOKEN}\n`)
  symlinkSync('telegram-marveen', join(claude, 'channels', 'telegram'))

  // A fej SAJAT csatorna-allapota, sajat bot-tokennel.
  mkdirSync(agentOwnState(), { recursive: true })
  writeFileSync(join(agentOwnState(), '.env'), `TELEGRAM_BOT_TOKEN=${AGENT_TOKEN}\n`)
}

beforeEach(seedSandbox)
afterEach(() => { rmSync(SANDBOX, { recursive: true, force: true }) })

describe('izolalt config dir: a nem-fo fej csatorna-allapota', () => {
  // A LENYEGI MERES: melyik botot pollozna egy env nelkul indulo plugin-szerver
  // a fej config-dirjebol. Ma a FO ELES botot -- ezert kapja meg a fo poller
  // bot.pid-jet is, es loveti ki SIGTERM-mel (server.ts:62-78, tulajdonos-
  // ellenorzes nelkul).
  it('egy env nelkuli plugin-szerver a fej SAJAT bot-tokenjet talalja, nem a fo eleset', () => {
    ensureIsolatedChannelConfigDir(AGENT, 'telegram')

    const env = readFileSync(join(pluginStateDir(isolatedCfg()), '.env'), 'utf-8')

    expect(env).toContain(AGENT_TOKEN)
    expect(env).not.toContain(MAIN_TOKEN)
  })

  it('a channels valodi konyvtar, a provider-bejegyzes a fej sajat allapotara mutat', () => {
    ensureIsolatedChannelConfigDir(AGENT, 'telegram')

    expect(lstatSync(join(isolatedCfg(), 'channels')).isSymbolicLink()).toBe(false)
    expect(realpathSync(pluginStateDir(isolatedCfg()))).toBe(realpathSync(agentOwnState()))
  })

  // MIGRACIO: a flottaban 17 fej config-dirjeben MA egy globalis `channels`
  // symlink all (merve 2026-09-02). Az ujra-provisioning cserelje le magatol,
  // kezi lepes nelkul.
  it('a mar meglevo globalis symlinket az ujra-provisioning lecsereli', () => {
    mkdirSync(isolatedCfg(), { recursive: true })
    symlinkSync(join(SANDBOX, 'home', '.claude', 'channels'), join(isolatedCfg(), 'channels'))

    ensureIsolatedChannelConfigDir(AGENT, 'telegram')

    expect(lstatSync(join(isolatedCfg(), 'channels')).isSymbolicLink()).toBe(false)
    expect(realpathSync(pluginStateDir(isolatedCfg()))).toBe(realpathSync(agentOwnState()))
  })

  // NEGATIV ESET, ami a hatokort leszogezi: csatorna nelkuli fejnel
  // (providerType === null, a flottaban a `rendezo`) minden marad a regiben.
  it('csatorna nelkuli fejnel valtozatlan a globalis symlink', () => {
    ensureIsolatedChannelConfigDir(AGENT, null)

    const link = join(isolatedCfg(), 'channels')

    expect(lstatSync(link).isSymbolicLink()).toBe(true)
    expect(readlinkSync(link)).toBe(join(SANDBOX, 'home', '.claude', 'channels'))
  })
})
