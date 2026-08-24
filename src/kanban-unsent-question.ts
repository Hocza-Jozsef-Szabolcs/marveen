// Pure detection logic for one specific blind spot on the kanban board: a
// `waiting` card assigned to `marveen` or `jozsi` (blocked on the owner's
// decision) whose blocking question was never actually sent to the owner.
//
// The board only records that a card is WAITING, not WHETHER SOMETHING WAS
// SENT. A card assigned to `marveen` in `waiting` means "blocked on the
// owner's decision" -- but the decision request itself goes out as a
// Telegram message (a napzaro dontesi lista, or a direct reply), which is
// text sent through a channel plugin, not a database write joined to the
// card. Nothing links the two, so a card can sit blocked on a question that
// was drafted and never sent, and look identical on the board to one that is
// correctly waiting on a real, delivered question.
//
// The fix is the same shape as kanban-stale-blocker-refs.ts: a self-declared,
// mechanically-checkable marker. Every outbound Telegram message already
// carries a mandatory leading sequence number (`{X}`, see tg-seq.sh) -- so
// the marker convention is a kanban comment recording that number:
//   "KIKULDVE: {123}"
// A `waiting`+`marveen` card with no such comment has an unsent question.
//
// Kept pure (no db import) so the decision logic is unit-tested without a
// database, mirroring kanban-stale-blocker-refs.ts.

export interface UnsentQuestionCardInput {
  id: string
  title: string
}

export interface UnsentQuestionRef {
  id: string
  title: string
}

// "kikuldve" / "kikülve" / "elkuldve" + a {szam} hivatkozas ugyanabban a
// kommentben. A puszta "kikuldve" szo hivatkozas nelkul nem szamit --
// azonositatlan allitas, ugyanolyan ellenorizhetetlen mint a jelenlegi hiany.
const SENT_MARKER_RE = /(kik[üu]ldve|elk[üu]ldve).*\{\d+\}/is

// VHR8 tiltas: lasd kanban-stale-blocker-refs.ts -- ugyanaz az onkezdemenyezett
// figyelem-tilalom vonatkozik minden automatikus kartya-vizsgalatra.
const VHR8_TITLE_RE = /vhr[-_]?8\b/i

export function computeUnsentWaitingQuestions(
  waitingMarveenCards: UnsentQuestionCardInput[],
  commentsByCardId: ReadonlyMap<string, string[]>,
): UnsentQuestionRef[] {
  const results: UnsentQuestionRef[] = []

  for (const card of waitingMarveenCards) {
    if (VHR8_TITLE_RE.test(card.title)) continue

    const comments = commentsByCardId.get(card.id) ?? []
    const hasSentMarker = comments.some((c) => SENT_MARKER_RE.test(c))
    if (!hasSentMarker) {
      results.push({ id: card.id, title: card.title })
    }
  }

  return results
}
