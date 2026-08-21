import { describe, it, expect } from 'vitest'
import { parseCredentials } from '../graph-mail.js'

// parseCredentials is the pure, filesystem-free core of the credentials
// loader. The network paths (token mint, Graph calls) are exercised out of
// band against the live tenant; here we pin the parsing + validation contract.
describe('parseCredentials', () => {
  const full = [
    'TENANT_ID=00000000-0000-4000-8000-000000000001',
    'CLIENT_ID=00000000-0000-4000-8000-000000000002',
    'CLIENT_SECRET=xy~8Q~secretvalue',
    'MAILBOX=marveen@example.invalid',
  ].join('\n')

  it('parses a well-formed credentials file', () => {
    const c = parseCredentials(full)
    expect(c.tenantId).toBe('00000000-0000-4000-8000-000000000001')
    expect(c.clientId).toBe('00000000-0000-4000-8000-000000000002')
    expect(c.clientSecret).toBe('xy~8Q~secretvalue')
    expect(c.mailbox).toBe('marveen@example.invalid')
  })

  it('ignores comments and blank lines', () => {
    const c = parseCredentials(`# header comment\n\n${full}\n# trailing`)
    expect(c.mailbox).toBe('marveen@example.invalid')
  })

  it('strips surrounding quotes from values', () => {
    const c = parseCredentials(full.replace('CLIENT_SECRET=xy~8Q~secretvalue', 'CLIENT_SECRET="xy~8Q~secretvalue"'))
    expect(c.clientSecret).toBe('xy~8Q~secretvalue')
  })

  it('keeps = characters inside a value', () => {
    const c = parseCredentials(full.replace('CLIENT_SECRET=xy~8Q~secretvalue', 'CLIENT_SECRET=ab=cd=ef'))
    expect(c.clientSecret).toBe('ab=cd=ef')
  })

  it('throws listing every missing key', () => {
    expect(() => parseCredentials('MAILBOX=marveen@example.invalid')).toThrowError(/TENANT_ID.*CLIENT_ID.*CLIENT_SECRET/)
  })

  it('treats an empty value as missing', () => {
    expect(() => parseCredentials(full.replace('CLIENT_SECRET=xy~8Q~secretvalue', 'CLIENT_SECRET='))).toThrowError(
      /CLIENT_SECRET/,
    )
  })
})
