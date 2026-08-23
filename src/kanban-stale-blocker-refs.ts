// Pure detection logic for one specific staleness signal on the kanban board.
//
// `updated_at` cannot answer "was this card touched" -- a mass write put the
// exact same timestamp on 128 cards, and the last-comment fallback is
// useless on a card that has zero comments. This module targets a narrower,
// machine-checkable question instead: does an OPEN card's own text (title,
// description, comments) use blocking language ("blokkol...") AND cite
// another card by `#<seq>` that is by now `done` or archived? If so, the
// stated blocker no longer holds, and the card is worth a second look.
//
// Kept pure (no db import) so the decision logic is unit-tested without a
// database, mirroring kanban-dispatch.ts.

export interface StaleBlockerCardInput {
  id: string
  seq: number
  title: string
  description: string | null
}

export interface StaleBlockerRef {
  id: string
  seq: number
  title: string
  referencedSeq: number
}

const BLOCKING_LANGUAGE_RE = /blokkol|blocked by/i
const SEQ_REF_RE = /#(\d+)\b/g

// VHR8 tiltas: a VHR8 (`__VHR8__`, `VHR-8.0`) semmilyen onkezdemenyezett
// figyelmet nem kaphat, amig Jozsi nev szerint nem keri -- ez automatikus
// jelzesre is vonatkozik, tehat egy VHR8-cimu kartya sosem kerulhet ebbe a
// listaba, meg akkor sem, ha a mintaillesztes egyebkent talalna.
const VHR8_TITLE_RE = /vhr[-_]?8\b/i

export function computeStaleBlockerRefs(
  openCards: StaleBlockerCardInput[],
  closedSeqs: ReadonlySet<number>,
  commentsByCardId: ReadonlyMap<string, string[]>,
): StaleBlockerRef[] {
  const results: StaleBlockerRef[] = []

  for (const card of openCards) {
    if (VHR8_TITLE_RE.test(card.title)) continue

    const text = [card.title, card.description ?? '', ...(commentsByCardId.get(card.id) ?? [])].join('\n')
    if (!BLOCKING_LANGUAGE_RE.test(text)) continue

    const seen = new Set<number>()
    SEQ_REF_RE.lastIndex = 0
    let m: RegExpExecArray | null
    while ((m = SEQ_REF_RE.exec(text)) !== null) {
      const refSeq = Number(m[1])
      if (refSeq === card.seq || seen.has(refSeq)) continue
      seen.add(refSeq)
      if (closedSeqs.has(refSeq)) {
        results.push({ id: card.id, seq: card.seq, title: card.title, referencedSeq: refSeq })
      }
    }
  }

  return results
}
