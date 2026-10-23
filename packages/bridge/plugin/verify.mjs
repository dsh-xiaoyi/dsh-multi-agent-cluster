// verify.mjs — exercises dsh-agent-bridge against a FAKE ctx. No DSH restart, no network,
// no database, no files written. This is the same testing shape the owner's
// dsh-memory-bridge uses (see its verify.mjs), and it exists because "installed but
// ineffective" has burned this cluster before.
//
//   node verify.mjs        exit 0 = all pass, 1 = an assertion failed
//
// What it proves (the guards named in the design record [12030]):
//   A. a valid request reaches ctx.subagents.prompt with the LOCAL (parent,child) pair,
//      mode=continuable and the requested delivery (queue vs steer)
//   B. a wrong token is refused with 401 and never reaches the injection call
//   C. an unknown logical target is refused with 404
//   D. hops >= 2 is refused with 409 (loop guard)
//   E. a repeated msgId inside the window is answered 200 deduplicated and injected once
//   F. oversized text is refused with 400
//   G. the route path is exactly what the config asked for, and the disposer removes it

import { apply, VERSION, name, inject, sendToPeer } from './index.mjs'
import { readFileSync, rmSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

// Per the owner's measured note: a self-check must use its OWN temp log, so "verified here"
// can never be confused with "loaded by the host" (the real log is the host's proof).
const LOG = join(tmpdir(), 'dsh-agent-bridge-verify.log')
try { rmSync(LOG, { force: true }) } catch {}

let failures = 0
function check(label, ok, detail = '') {
  if (ok) console.log('  PASS  ' + label + (detail ? '  ' + detail : ''))
  else { failures++; console.log('  FAIL  ' + label + '  ' + detail) }
}

const TOKEN = "TEST-TOKEN-NOT-A-SECRET"
const PARENT = 'session-parent-aaaa'
const CHILD = 'child-bbbb'

let route = null
const injected = []
const fakeCtx = {
  logger: { info: () => {}, warn: () => {} },
  webServer: { register(r) { route = r; return () => { route = null } } },
  subagents: { async prompt(req) { injected.push(req); return 'inbox-msg-1' } },
}

const dispose = apply(fakeCtx, {
  path: '/agent/inbox',
  token: TOKEN,
  logPath: LOG,
  allowedFrom: ['11'],
  localTargets: { 'me/agent-1': { parentSessionId: PARENT, childSessionId: CHILD } },
  peers: { '18': { url: 'http://192.0.2.18:19387', token: 'peer-token' } },
})

check('plugin identity', name === 'dsh-agent-bridge' && inject.includes('webServer') && inject.includes('subagents'), 'VERSION=' + VERSION)
check('route registered at the configured path', route !== null && route.path === '/agent/inbox' && route.kind === 'exact')

// --- fake req/res -----------------------------------------------------------
function makeRes() {
  const r = { statusCode: null, headers: null, body: '', }
  r.writeHead = (c, h) => { r.statusCode = c; r.headers = h }
  r.setHeader = () => {}
  r.end = (b) => { r.body = b ?? '' }
  return r
}
function makeReq(body, token, method = 'POST') {
  const listeners = {}
  const req = {
    method,
    headers: { authorization: token === null ? '' : 'Bearer ' + token, 'content-type': 'application/json' },
    socket: { remoteAddress: '127.0.0.1' },
    on(ev, fn) { (listeners[ev] ||= []).push(fn); return req },
    destroy() {},
  }
  // emit asynchronously like a real socket
  setImmediate(() => {
    if (body !== undefined) for (const fn of (listeners.data || [])) fn(Buffer.from(body))
    for (const fn of (listeners.end || [])) fn()
  })
  return req
}
const msg = (o = {}) => JSON.stringify({ msgId: 'm-' + Math.random().toString(16).slice(2), from: '11', to: 'me/agent-1', delivery: 'queue', text: 'ping', hops: 0, ...o })

async function call(body, token, method = 'POST') {
  const res = makeRes()
  await route.handler(makeReq(body, token, method), res)
  return res
}

// A: happy path, steer delivery must reach the LOCAL pair
let res = await call(msg({ delivery: 'steer' }), TOKEN)
check('A valid steer request is accepted (202)', res.statusCode === 202, 'status=' + res.statusCode + ' body=' + res.body)
check('A injection used the LOCAL (parent,child) pair, mode=continuable, delivery=steer',
  injected.length === 1 && injected[0].parentSessionId === PARENT && injected[0].childSessionId === CHILD &&
  injected[0].mode === 'continuable' && injected[0].delivery === 'steer' && String(injected[0].content?.[0]?.text ?? '').endsWith('ping'),
  'got=' + JSON.stringify(injected[0] ?? null))
check('A requestId is a uuid', typeof injected[0]?.requestId === 'string' && injected[0].requestId.length >= 32)

// B: wrong token
res = await call(msg(), 'wrong-token')
check('B wrong token -> 401 and no injection', res.statusCode === 401 && injected.length === 1, 'status=' + res.statusCode)

// C: unknown target
res = await call(msg({ to: 'me/does-not-exist' }), TOKEN)
check('C unknown target -> 404', res.statusCode === 404, 'status=' + res.statusCode)

// D: hop limit
res = await call(msg({ hops: 2 }), TOKEN)
check('D hops>=2 -> 409', res.statusCode === 409, 'status=' + res.statusCode)

// E: duplicate msgId
const dup = msg()
res = await call(dup, TOKEN)
const firstStatus = res.statusCode
res = await call(dup, TOKEN)
check('E duplicate msgId -> 200 deduplicated and injected once', firstStatus === 202 && res.statusCode === 200 && /deduplicated/.test(res.body) && injected.length === 2,
  'first=' + firstStatus + ' second=' + res.statusCode + ' injections=' + injected.length)

// F: oversize text (rate limit is 5/min, so this must not be the limiting factor first)
res = await call(msg({ text: 'x'.repeat(9000) }), TOKEN)
check('F oversize text -> 400', res.statusCode === 400, 'status=' + res.statusCode)

// G0: the sender whitelist (default-deny) - the owner's standing constraint: only 11 may inject
res = await call(msg({ from: '18' }), TOKEN)
check('G0 a sender outside allowedFrom is refused (403)', res.statusCode === 403 && /sender-not-allowed/.test(res.body), 'status=' + res.statusCode + ' body=' + res.body)
res = await call(msg({ from: '' }), TOKEN)
check('G0 an empty sender is refused (403)', res.statusCode === 403, 'status=' + res.statusCode)
res = await call(msg({ from: '11' }), TOKEN)
check('G0 the allowed sender (hub) still passes the whitelist', res.statusCode === 202 || res.statusCode === 200, 'status=' + res.statusCode)

// G: method + disposer
res = await call(msg(), TOKEN, 'GET')
check('G non-POST -> 405', res.statusCode === 405, 'status=' + res.statusCode)
dispose()
check('G disposer removes the route', route === null)

// H: outbound helper shape (no network: a stub fetch)
let seen = null
const stubFetch = async (url, init) => { seen = { url, init }; return { status: 202, ok: true, text: async () => '{"ok":true}' } }
const out = await sendToPeer({ url: 'http://192.0.2.18:19387/', path: '/agent/inbox', token: 'peer-token' }, { msgId: 'm1', from: '11', to: '18/agent-1', delivery: 'queue', text: 'hi', hops: 0 }, stubFetch)
check('H outbound posts to the peer with a bearer token and bumps hops',
  seen?.url === 'http://192.0.2.18:19387/agent/inbox' && /Bearer peer-token/.test(seen?.init?.headers?.authorization ?? '') &&
  JSON.parse(seen.init.body).hops === 1 && out.status === 202,
  'url=' + seen?.url)

// J: R50 - the injected content must carry the VERIFIED origin as a structured header, because
// subagents.prompt transports text only (otherwise a target can never know whose instruction it is)
check('J content carries the bridge header with the verified sender',
  /^\[bridge msg=\S+ from=11 to=me\/agent-1 delivery=steer ts=\S+\]\n/.test(String(injected[0]?.content?.[0]?.text ?? '')),
  'head=' + JSON.stringify(String(injected[0]?.content?.[0]?.text ?? '').slice(0, 60)))

// K: R49(1) staged per-peer tokens - the token decides the sender, the body must agree
{
  let route2 = null; const inj2 = []
  const ctx2 = {
    logger: { info: () => {}, warn: () => {} },
    webServer: { register(r) { route2 = r; return () => {} } },
    subagents: { async prompt(q) { inj2.push(q); return 'x' } },
  }
  const d2 = apply(ctx2, { path: '/agent/inbox', token: '', logPath: LOG, allowedFrom: ['11', '18'],
    peerTokens: { '11': 'tok-11', '18': 'tok-18' },
    localTargets: { 'me/agent-1': { parentSessionId: PARENT, childSessionId: CHILD } } })
  const res2 = (b, tk) => { const r = makeRes(); return route2.handler(makeReq(b, tk), r).then(() => r) }
  let r = await res2(msg({ from: '11' }), 'tok-11')
  check('K a matching per-peer token is accepted (202)', r.statusCode === 202, 'status=' + r.statusCode)
  r = await res2(msg({ from: '18' }), 'tok-11')
  check('K a token/from mismatch is refused (403 impersonation)', r.statusCode === 403 && /sender-mismatch/.test(r.body), 'status=' + r.statusCode + ' body=' + r.body)
  r = await res2(msg({ from: '11' }), 'tok-nope')
  check('K a token matching no peer is refused (401)', r.statusCode === 401, 'status=' + r.statusCode)
  d2()
}

// L: the SELF path - the machine's own token may only speak for the machine itself
{
  let route3 = null
  const ctx3 = {
    logger: { info: () => {}, warn: () => {} },
    webServer: { register(r) { route3 = r; return () => {} } },
    subagents: { async prompt() { return 'x' } },
  }
  const d3 = apply(ctx3, { path: '/agent/inbox', token: 'self-tok', logPath: LOG, allowedFrom: ['11', '18'],
    peerTokens: { '18': 'tok-18' },
    localTargets: { 'me/agent-1': { parentSessionId: PARENT, childSessionId: CHILD } } })
  const res3 = (b, tk) => { const r = makeRes(); return route3.handler(makeReq(b, tk), r).then(() => r) }
  const selfName = (typeof process !== 'undefined' && process.env && process.env.COMPUTERNAME) ? process.env.COMPUTERNAME : ''
  let r = await res3(msg({ from: selfName }), 'self-tok')
  check('L a self row is refused cleanly, never 500 (this config whitelists only one node1/18; the accept path is proven live on 11)', r.statusCode === 403, 'status=' + r.statusCode)
  r = await res3(msg({ from: '18' }), 'self-tok')
  check('L the local token is refused when it claims another machine (403)', r.statusCode === 403 && /sender-mismatch/.test(r.body), 'status=' + r.statusCode + ' body=' + r.body)
  d3()
}

console.log('')
// I: the on-disk log — the ONLY trustworthy proof that apply() ran, and proof that the
// message text never reaches the log.
const logText = existsSync(LOG) ? readFileSync(LOG, 'utf8') : ''
check('I log carries the ARMED marker', /ARMED v/.test(logText), 'lines=' + logText.split('\n').filter(Boolean).length)
check('I log records the refusal (401) without the message text', /WARN/.test(logText) && /refused/.test(logText) && !logText.includes('ping'),
  'contains-text=' + logText.includes('ping'))
check('I log records delivery as ids/sizes only', /delivered .* bytes=\d+ messageId=/.test(logText))

console.log('')
console.log(failures === 0 ? 'RESULT: PASS (' + VERSION + ')' : 'RESULT: FAIL (' + failures + ' assertion(s))')
process.exit(failures === 0 ? 0 : 1)
