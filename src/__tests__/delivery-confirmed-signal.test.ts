import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

// Contract tests for the honest "delivered" mark (card 84ad4f6e).
//
// Root cause: sendPromptToSession's post-send retry loop already DETECTS a
// prompt that never submits (it parks in the input box), but on give-up it
// `break`s and falls through to `return 'sent'` -- so the message-router marks
// the message 'delivered' (and the card `dispatched_at` stays set) even though
// the agent never received a submittable prompt. The loss is silent.
//
// Fix: a parked prompt is a DISTINCT result ('parked'), the router only marks
// 'delivered' when the send result is 'sent' AND the target session is still
// alive, and a non-confirmed send routes through the existing inject-fail
// path (retry, then markMessageFailed + notifyOrchestratorOfFailedHandoff).

import { isConfirmedDelivery } from '../web/message-router.js'

const AGENT_PROCESS = readFileSync(join(__dirname, '../web/agent-process.ts'), 'utf-8')
const MESSAGE_ROUTER = readFileSync(join(__dirname, '../web/message-router.ts'), 'utf-8')

describe('isConfirmedDelivery: only a confirmed send marks a message delivered', () => {
  it('accepts a sent prompt into a still-alive session', () => {
    expect(isConfirmedDelivery('sent', true)).toBe(true)
  })

  it('rejects a sent prompt when the session died mid-send', () => {
    // The session was alive when the pre-pass checked it, but died during the
    // chunk stream. The prompt is gone; this must NOT mark delivered.
    expect(isConfirmedDelivery('sent', false)).toBe(false)
  })

  it('rejects a parked prompt (give-up) even when the session is alive', () => {
    // The prompt was typed but never submitted -- the agent never acts on it.
    // This was the silent-loss case: 'sent' was returned on give-up.
    expect(isConfirmedDelivery('parked', true)).toBe(false)
  })

  it('rejects aborted-busy and skipped-locked results', () => {
    expect(isConfirmedDelivery('aborted-busy', true)).toBe(false)
    expect(isConfirmedDelivery('skipped-locked', true)).toBe(false)
  })
})

describe('sendPromptToSession give-up returns a distinct parked result', () => {
  it('declares a SendPromptResult type that includes parked', () => {
    const typeIdx = AGENT_PROCESS.indexOf('export type SendPromptResult = ')
    expect(typeIdx).toBeGreaterThan(0)
    const typeLine = AGENT_PROCESS.slice(typeIdx, typeIdx + 120)
    expect(typeLine).toContain("'parked'")
  })

  it('the function returns Promise<SendPromptResult>', () => {
    const sigIdx = AGENT_PROCESS.indexOf('export async function sendPromptToSession(')
    expect(sigIdx).toBeGreaterThan(0)
    const sig = AGENT_PROCESS.slice(sigIdx, sigIdx + 400)
    expect(sig).toMatch(/Promise<SendPromptResult>/)
  })

  it('the give-up branch returns parked, not sent', () => {
    const giveUpIdx = AGENT_PROCESS.indexOf("if (action === 'give-up') {")
    expect(giveUpIdx).toBeGreaterThan(0)
    // Narrow slice: cover the give-up block only (a `break` lives farther down
    // in the clear-and-resend recovery, which is unrelated to the give-up path).
    const branch = AGENT_PROCESS.slice(giveUpIdx, giveUpIdx + 200)
    expect(branch).toContain("return 'parked'")
    expect(branch).not.toContain('break')
  })
})

describe('message-router only marks delivered on a confirmed send', () => {
  it('guards markMessageDelivered behind isConfirmedDelivery', () => {
    // The delivery branch must capture the send result and refuse to mark
    // delivered when the send was not confirmed (parked / died mid-send).
    const deliverIdx = MESSAGE_ROUTER.indexOf('const sendResult = await sendPromptToSession(session, prefix + wrapped, host)')
    expect(deliverIdx).toBeGreaterThan(0)
    const branch = MESSAGE_ROUTER.slice(deliverIdx, deliverIdx + 700)
    expect(branch).toMatch(/const sendResult = await sendPromptToSession/)
    expect(branch).toMatch(/isConfirmedDelivery\(sendResult, sessionAliveAfterSend\)/)
    expect(branch).toMatch(/throw new Error/)
  })
})
