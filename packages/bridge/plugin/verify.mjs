// verify.mjs — exercises dsh-agent-bridge against a FAKE ctx. No DSH restart, no network,
// no database, no files written. This is the same testing shape
// dsh-memory-bridge uses (see its verify.mjs), and it exists because "installed but
// ineffective" has burned this fleet before.
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
//   H2 (2026-10-30). token HOT-RELOAD: TOKENS-RELOADED is judged on the NEW-LINE WINDOW only,
//      plus a negative control and the broken-file branches (see the H2 block at the bottom).

import { apply, VERSION, name, inject, sendToPeer } from './index.mjs'
import { readFileSync, writeFileSync, mkdtempSync, rmSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

// Per a measured note: a self-check must use its OWN temp log, so "verified here"
// can never be confused with "loaded by the host" (the real log is the host's proof).
const LOG = join(tmpdir(), 'dsh-agent-bridge-verify.log')
try { rmSync(LOG, { force: true }) } catch {}

let failures = 0
let checks = 0   // counted, so "the assertions did not shrink" is observable, not a claim
function check(label, ok, detail = '') {
  checks++
  if (ok) console.log('  PASS  ' + label + (detail ? '  ' + detail : ''))
  else { failures++; console.log('  FAIL  ' + label + '  ' + detail) }
}

const TOKEN = 'test-token-not-a-secret'
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

  // C: unknown target -> 404 AND self-describing body ([SELFDESC-20261106])
  //   阳性对照：旧 index.mjs（无 SELFDESC）在下面第二条 check 必须红——旧 404 body 没有 targets 数组。
  res = await call(msg({ to: 'me/does-not-exist' }), TOKEN)
  check('C unknown target -> 404', res.statusCode === 404, 'status=' + res.statusCode)
  let cBody = null
  try { cBody = JSON.parse(res.body) } catch {}
  check('C 404 body self-describes targets (SELFDESC-20261106)',
    cBody && cBody.code === 'unknown-target' && Array.isArray(cBody.targets) && cBody.targets.length === Object.keys({ 'me/agent-1': 1 }).length && cBody.targets.includes('me/agent-1'),
    'body=' + res.body)

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

// G0: the sender whitelist (default-deny) - the standing constraint: only the hub may inject
res = await call(msg({ from: '18' }), TOKEN)
check('G0 a sender outside allowedFrom is refused (403)', res.statusCode === 403 && /sender-not-allowed/.test(res.body), 'status=' + res.statusCode + ' body=' + res.body)
res = await call(msg({ from: '' }), TOKEN)
check('G0 an empty sender is refused (403)', res.statusCode === 403, 'status=' + res.statusCode)
res = await call(msg({ from: '11' }), TOKEN)
check('G0 the allowed sender (11) still passes the whitelist', res.statusCode === 202 || res.statusCode === 200, 'status=' + res.statusCode)

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
  check('L a self row is refused cleanly, never 500 (this config whitelists only 11/18; the accept path is proven live on 11)', r.statusCode === 403, 'status=' + r.statusCode)
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

const OLD_ASSERTION_BASELINE = 26
const OLD_CHECKS = checks
check('superset: all ' + OLD_ASSERTION_BASELINE + ' pre-H2 assertions ran (no old assertion was dropped in the merge)',
  OLD_CHECKS === OLD_ASSERTION_BASELINE, 'old-checks=' + OLD_CHECKS)

// ---------------------------------------------------------------------------
// H2 (2026-10-30) - token HOT-RELOAD. Three hard rules:
//   ① judge only the NEW-LINE WINDOW: a whole-file grep would read the TOKENS-RELOADED of an
//      earlier run and stay green forever.
//   ② a negative control: the same token, no rewrite => the window must NOT contain the marker.
//      That control only counts when the positive is observable (gated below), otherwise it is
//      a vacuous pass.
//   ③ branches that can go red: an empty own-token file and a broken peer-map JSON must show
//      their documented behaviour, must not crash, and must never become "allow everything".
// Release grep marker: [H2-TOKEN-HOTRELOAD-20261030]
// The block uses a THROWAWAY token file and log under mkdtemp: rewriting the live
// C:\dsh-mem\dsh-agent-bridge token here would rotate the production token (an outage), so the
// same code path (apply -> refreshTokens -> fileLog) is exercised on a temp file instead.
const H2 = 'H2-TOKEN-HOTRELOAD-20261030'
const h2dir = mkdtempSync(join(tmpdir(), 'bridge-h2-'))
const H2LOG = join(h2dir, 'h2.log')
const H2TOK = join(h2dir, 'token.txt')
const H2PEER = join(h2dir, 'peers.json')
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const put = (p, s) => writeFileSync(p, s)
function lineCount(p) {
  try {
    const t = readFileSync(p, 'utf8')
    if (!t) return 0
    const a = t.split('\n')
    return a[a.length - 1] === '' ? a.length - 1 : a.length
  } catch { return 0 }
}
function winSince(p, from) {
  try { return readFileSync(p, 'utf8').split('\n').slice(from).join('\n') } catch { return '' }
}
const H2A = 'h2-token-A', H2B = 'h2-token-B'
console.log('')
console.log('  -- ' + H2 + ' --')

put(H2TOK, H2A + '\n')
let r3 = null
const ctx3 = {
  logger: { info: () => {}, warn: () => {} },
  webServer: { register(r) { r3 = r; return () => { r3 = null } } },
  subagents: { async prompt() { return 'h2-msg-1' } },
}
const d3 = apply(ctx3, {
  path: '/h2/inbox', tokenFile: H2TOK, logPath: H2LOG, allowedFrom: ['01', '02', '03', '04', '05'],
  localTargets: { 'me/agent-1': { parentSessionId: PARENT, childSessionId: CHILD } },
})
// distinct senders keep their own 5/min buckets, so H2 never competes with A..K nor with itself
const h2 = async (tk, from = '01') => { const r = makeRes(); await r3.handler(makeReq(msg({ from }), tk), r); return r }

let rr = await h2(H2A)
check('H2 baseline: the token read from tokenFile is accepted (202)', rr.statusCode === 202, 'status=' + rr.statusCode)

// ② negative-control window: captured BEFORE any rewrite, judged after the positive branch
await sleep(1200)
const N0 = lineCount(H2LOG)
const negStatuses = []
for (const from of ['01', '02']) { const r = await h2(H2A, from); negStatuses.push(r.statusCode) }
const N1 = lineCount(H2LOG)
const negWin = winSince(H2LOG, N0)
const negMarker = negWin.includes('TOKENS-RELOADED')
const negOk = negStatuses.every((s) => s === 202) && N1 > N0 && !negMarker

// ① rewrite: the NEW token must be live and the rotated-out one dead, without any restart
put(H2TOK, H2B + '\n')
await sleep(1200)
const posStatuses = []
for (const from of ['01', '02']) { const r = await h2(H2B, from); posStatuses.push(r.statusCode) }
const N2 = lineCount(H2LOG)
const posWin = winSince(H2LOG, N1)
const posMarker = posWin.includes('TOKENS-RELOADED')
check('H2① rewrite -> the NEW token is live (2 requests, both 202)', posStatuses.every((s) => s === 202),
  'statuses=' + posStatuses.join(',') + ' new-lines=' + (N2 - N1))
rr = await h2(H2A, '03')
check('H2① the old token is refused (401) after the rewrite - the reload really took effect',
  rr.statusCode === 401, 'status=' + rr.statusCode)
check('H2① TOKENS-RELOADED lands in the NEW window of the rewrite', posMarker,
  'marker-in-window=' + posMarker + ' new-lines=' + (N2 - N1))
if (!posMarker) {
  console.log('  DIAG  measured: the reload happened (202/401 above) but emitted no marker. Root cause:')
  console.log('  DIAG  index.mjs:142 calls fileLog() from module-level refreshTokens(), while fileLog() is')
  console.log('  DIAG  declared inside apply() (index.mjs:184) => ReferenceError, swallowed by the :142 try/catch.')
}
check('H2② negative control: unchanged token file adds lines but NO TOKENS-RELOADED (gated on the positive)',
  negOk && posMarker,
  'statuses=' + negStatuses.join(',') + ' new-lines=' + (N1 - N0) + ' marker-in-window=' + negMarker + ' gated-on-positive=' + posMarker)

// ③a empty own-token file: the documented behaviour must be "keep the previous token", never allow-all
put(H2TOK, '')
await sleep(1200)
const rPrev = await h2(H2B, '04')
const rOld = await h2(H2A, '04')
const rNone = await h2('a-token-that-matches-nothing', '04')
const N3 = lineCount(H2LOG)
check('H2③a empty token file: the token in effect before the damage still works (202)',
  rPrev.statusCode === 202, 'status=' + rPrev.statusCode + ' new-lines=' + (N3 - N2))
check('H2③a empty token file: the rotated-out token is still refused (401)',
  rOld.statusCode === 401, 'status=' + rOld.statusCode)
check('H2③a empty token file: an unrelated token is refused (401, never allow-all)',
  rNone.statusCode === 401, 'status=' + rNone.statusCode)
put(H2TOK, H2B + '\n')
await sleep(1200)
rr = await h2(H2B, '05')
check('H2③a recovery: restoring the file revives service without a restart (202)', rr.statusCode === 202, 'status=' + rr.statusCode)
d3()

// ③b broken PEER-map JSON: the previously loaded map must stay usable and the failure must be logged
put(H2PEER, JSON.stringify({ '11': 'h2-peer-11' }))
let r4 = null
const ctx4 = {
  logger: { info: () => {}, warn: () => {} },
  webServer: { register(r) { r4 = r; return () => { r4 = null } } },
  subagents: { async prompt() { return 'h2-msg-2' } },
}
const d4 = apply(ctx4, {
  path: '/h2b/inbox', token: '', peerTokensFile: H2PEER, logPath: H2LOG, allowedFrom: ['11'],
  localTargets: { 'me/agent-1': { parentSessionId: PARENT, childSessionId: CHILD } },
})
const h2b = async (tk) => { const r = makeRes(); await r4.handler(makeReq(msg({ from: '11' }), tk), r); return r }
rr = await h2b('h2-peer-11')
check('H2③b the peer map loaded from file works before the damage (202)', rr.statusCode === 202, 'status=' + rr.statusCode)
const N4 = lineCount(H2LOG)
put(H2PEER, '{ this is not json')
await sleep(1200)
rr = await h2b('h2-peer-11')
const N5 = lineCount(H2LOG)
const brokenWin = winSince(H2LOG, N4)
check('H2③b broken peer-map JSON keeps the OLD map usable (202) and logs WARN peerTokensFile',
  rr.statusCode === 202 && /WARN[^\n]*peerTokensFile/.test(brokenWin),
  'status=' + rr.statusCode + ' new-lines=' + (N5 - N4) + ' warn=' + /WARN[^\n]*peerTokensFile/.test(brokenWin))
rr = await h2b('a-token-that-matches-nothing')
check('H2③b while the peer map is broken an unknown token is still refused (401, never allow-all)',
  rr.statusCode === 401, 'status=' + rr.statusCode)
d4()
try { rmSync(h2dir, { recursive: true, force: true }) } catch {}

console.log('')
console.log(failures === 0
  ? 'RESULT: PASS (' + VERSION + ') checks=' + checks + ' marker=' + H2
  : 'RESULT: FAIL (' + failures + ' of ' + checks + ' assertion(s)) marker=' + H2)
process.exit(failures === 0 ? 0 : 1)
