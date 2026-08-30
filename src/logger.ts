import pino from 'pino'
import path from 'node:path'

const level = process.env.LOG_LEVEL ?? 'info'
const isProd = process.env.NODE_ENV === 'production'

/**
 * hu: A fájl-cél könyvtára MARVEEN_LOG_DIR-vel felülírható (teszteknek);
 * alapból a `store/` alá ír, ahol a többi állapot-napló (dashboard.log,
 * channels.log) is él.
 * <br />
 * en: The file target's directory is overridable via MARVEEN_LOG_DIR (for
 * tests); defaults to `store/`, where the other state logs (dashboard.log,
 * channels.log) already live.
 */
const logDir = process.env.MARVEEN_LOG_DIR ?? path.join(process.cwd(), 'store')

/**
 * hu: Minden naplósor a stdouton KÍVÜL egy rotált fájlba is megy -- korábban
 * csak a stdout kapott sort, ami a folyamat indítási módjától (tmux pane,
 * launchd stdout-redirect, vagy semmi) függően némán elveszhetett. A rotáció
 * (napi + 10 MB méretkorlát, 5 régi fájl megtartva) döntés, nem mérés: a cél,
 * hogy a napló ne nőjön a lemezen korlátlanul.
 * <br />
 * en: Every log line now also goes to a rolled file, not just stdout --
 * previously only stdout received it, which could silently vanish depending
 * on how the process was launched (tmux pane, launchd stdout-redirect, or
 * neither). The rotation (daily + 10 MB size cap, 5 old files kept) is a
 * design choice, not a measurement: the goal is bounding disk growth.
 */
const fileTarget: pino.TransportTargetOptions = {
  target: 'pino-roll',
  level,
  options: {
    file: path.join(logDir, 'app.log'),
    frequency: 'daily',
    dateFormat: 'yyyy-MM-dd',
    mkdir: true,
    size: '10m',
    limit: { count: 5 },
  },
}

const stdoutTarget: pino.TransportTargetOptions = isProd
  ? { target: 'pino/file', level, options: { destination: 1 } }
  : { target: 'pino-pretty', level, options: { colorize: true } }

export const logger = pino({
  level,
  transport: { targets: [fileTarget, stdoutTarget] },
})
