// hu: A csatorna-kieses IDOTARTAMANAK szamitasa -- tiszta fuggvenyek, allapot
//     nelkul, hogy a channel-monitor.ts modul-szintu valtozoi (marveenSuspect-
//     FirstSeen, agentDownSince) nelkul is merhetok legyenek.
// en: Pure outage-duration arithmetic for the channel monitor, extracted so it
//     can be measured without the monitor's module-level mutable state.
//
// A repo sajat mintaja erre: agent-restart-policy.ts.

/**
 * hu: A gazdanak jelentett kieses hossza masodpercben.
 *
 * Ket kulon idopont van, amit a monitor lat:
 *   - `firstSeenMs`: az ELSO gyanus eszleles (shouldEscalateMarveenDown elso
 *     hivasa) -- innentol nem jon valasz a csatornan,
 *   - `downSinceMs`: a MEGEROSITETT stage-1, ami MARVEEN_DOWN_CONFIRM_MS
 *     (120 000 ms) mulva kovetkezik.
 * A gazda szempontjabol a kieses az ELSONEL kezdodik: a kozbeeso ket percben
 * kuldott uzenetere sem jott valasz. Ezert a ketto kozul a KORABBIT vesszuk.
 *
 * MERES (2026-09-02, ujramerheto:
 *   grep -h 'Marveen channel plugin recovered' store/app.2026-*.log
 * ): 27 helyreallitasi rekord, downedFor 60 (9x), 120 (3x), 180 (11x),
 * 240 (3x), 241 (1x) -- MIND 120 masodperccel kevesebb a valodinal. A riasztasi
 * kapu (`disruptive || downedFor >= 180`) miatt a 12 soft-szintu rekordbol
 * MIND a 12 nemaan elmaradt, pedig valojaban 180-240 s kieses volt.
 *
 * en: Outage length as reported to the owner -- measured from FIRST detection,
 * not from the confirmed stage-1 that follows MARVEEN_DOWN_CONFIRM_MS later.
 */
export function mainDownedForSeconds(a: {
  nowMs: number
  firstSeenMs: number | null
  downSinceMs: number
}): number {
  const from = a.firstSeenMs != null ? Math.min(a.firstSeenMs, a.downSinceMs) : a.downSinceMs
  return Math.round((a.nowMs - from) / 1000)
}

/**
 * hu: Egy lezarult down-spell adatai: mennyi ideig tartott, es kozben hany
 *     ujrainditas volt.
 * en: A closed down-spell: how long it lasted and how many restarts it took.
 */
export interface DownSpellClose {
  msDown: number
  restartsInSpell: number
}

/**
 * hu: Egy agens down-spelljenek lezarasa, amikor a plugin ujra el.
 *
 * Egy spellt CSAK az zar le, hogy a plugin ujra el -- az ujrainditas NEM. A
 * `downSinceMs` a jelenlegi (restart ota szamolt) kezdet, a `recovering` pedig a
 * spell EREDETI kezdete es az addigi ujrainditasok szama; ez viszi at a spellt
 * az ujrainditasokon.
 *
 * MERES (2026-09-02, ujramerheto:
 *   grep -c 'Agent channel plugin down -- auto-restarting' store/app.2026-*.log
 *   grep -c 'Agent channel plugin recovered'                store/app.2026-*.log
 * ): 85 "auto-restarting" sor / 11 "recovered" sor -- a restart-ag torolte a
 * spell kezdetet, ezert a helyreallas mar nem latott nyitott spellt.
 *
 * en: Only a live plugin closes a down-spell; a restart carries it over.
 */
export function closeDownSpell(a: {
  nowMs: number
  downSinceMs: number | null
  recovering: { spellStartedAt: number; restarts: number } | null
}): DownSpellClose | null {
  const start = a.recovering?.spellStartedAt ?? a.downSinceMs
  if (start == null) return null
  return { msDown: a.nowMs - start, restartsInSpell: a.recovering?.restarts ?? 0 }
}
