import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'

// Kulon fajl, nem a channel-health-monitor.test.ts bovitese: a monitor
// `reconnectState` terkepe MODUL-SZINTU es tulel egy `vi.clearAllMocks()`-ot,
// tehat egy korabbi teszt backoff-bejegyzese (nextRetryAt) elnyelne a
// spawn-hivast, es a teszt a ROSSZ okbol lenne piros/zold. Sajat fajl =
// sajat modul-peldany = tiszta allapot.

const { mockSpawn } = vi.hoisted(() => ({ mockSpawn: vi.fn() }))
vi.mock('node:child_process', () => ({
  execFileSync: vi.fn(),
  execSync: vi.fn(),
  spawn: mockSpawn,
}))

vi.mock('../platform.js', () => ({
  resolveFromPath: (name: string) => `/usr/local/bin/${name}`,
}))

vi.mock('../logger.js', () => ({
  logger: { info: vi.fn(), warn: vi.fn(), debug: vi.fn(), error: vi.fn() },
}))

vi.mock('../config.js', () => ({
  MAIN_AGENT_ID: 'marveen',
  CHANNEL_PROVIDER: 'telegram',
  PROJECT_ROOT: '/tmp/test-claudeclaw',
}))

// Nincs sub-agens: igy csak a fo session-t vizsgalja a sweep, es a spawn-hivas
// egyertelmuen a vizsgalt pane-hez tartozik.
vi.mock('../web/agent-config.js', () => ({
  listAgentNames: () => [],
  readAgentChannelProvider: () => 'telegram',
  AGENTS_BASE_DIR: '/tmp/test-claudeclaw/agents',
}))

const mockCapturePane = vi.fn<(session: string) => string | null>()
vi.mock('../web/agent-process.js', () => ({
  isAgentRunning: () => false,
  capturePane: (session: string) => mockCapturePane(session),
  agentSessionName: (name: string) => `agent-${name}`,
}))

vi.mock('../web/main-agent.js', () => ({
  MAIN_CHANNELS_SESSION: 'marveen-channels',
}))

vi.mock('../web/channel-mcp-reconnect.js', async (orig) => ({
  ...(await orig() as object),
  attemptChannelMcpReconnect: vi.fn(),
  resolveAgentSession: (name: string) => name === 'marveen' ? 'marveen-channels' : `agent-${name}`,
  resolveAgentProviderType: () => 'telegram' as const,
}))

vi.mock('../channel-provider.js', () => ({
  getProvider: () => ({
    pluginId: 'telegram@claude-plugins-official',
    pluginPaneId: 'plugin:telegram:telegram',
  }),
}))

import { startChannelHealthMonitor } from '../web/channel-health-monitor.js'

// MERES (2026-09-02, elo agent-akka es agent-rendezo pane, 80x50, csak
// olvasas): a `tmux capture-pane -p` es a `-p -J` kimenete jobbra trimmelve
// BAJTAZONOS (50/50 sor, 0 eltero sor) -- a `-J` tehat a Claude Code TUI altal
// rajzolt sorokat NEM fuzi ossze (csak a terminal automatikus tordelese altal
// wrap-flaggel jelolt sorokat fuzne). A 24 karakteres `plugin:telegram:telegram`
// azonosito keskeny pane-en ketteszakad, es a `pane.includes(pluginPaneId)`
// nem talal ra -- a halott plugin ESZREVETLEN marad, a helyreallitas el sem
// indul.
describe('channel-health-monitor: tordelt plugin-azonosito', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.useFakeTimers()
    mockSpawn.mockReturnValue({ once: vi.fn(), unref: vi.fn() })
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('hamis-pozitiv ellenproba: idegen plugin bukasa NEM indit helyreallitast', () => {
    const timer = startChannelHealthMonitor()
    mockCapturePane.mockReturnValue(
      'plugin:slack-channel:marveen-mar\nketplace  ✘ failed',
    )

    vi.advanceTimersByTime(46_000)

    expect(mockSpawn).not.toHaveBeenCalled()
    clearInterval(timer)
  })

  it('a szo kozepen tordelt sajat plugin-azonositot felismeri', () => {
    const timer = startChannelHealthMonitor()
    mockCapturePane.mockReturnValue(
      'plugin:telegram:te\nlegram  ✘ failed\nsome other output',
    )

    vi.advanceTimersByTime(46_000)

    expect(mockSpawn).toHaveBeenCalled()
    clearInterval(timer)
  })
})
