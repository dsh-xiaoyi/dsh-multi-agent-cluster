// dsh-agent-bridge — host half (prototype v0.1.0)
//
// PLAN B (B1): cross-machine agent messaging for the DSH cluster. Only the relay host
// (the hub node) opens a LAN port; the other machines may still receive because they run this same
// plugin and each injects LOCALLY.
//
// WHY LOCAL INJECTION (this is the key design point, verified against the runtime contract):
//   ctx.subagents.sendMessage(sender, targetId, ...) only accepts the sender's *direct parent
//   or direct continuable child* — an arbitrary session id is rejected (adjacency).
//   The deliverable primitive with queue/steer semantics is:
//       ctx.subagents.prompt({ requestId, parentSessionId, childSessionId,
//                              mode: 'continuable', delivery: 'queue' | 'steer', content })
//   So an inbound request carries a LOGICAL target ("me/agent-1"); the receiving machine maps
//   it to its own (parentSessionId, childSessionId) pair and injects locally. No remote
//   session ids cross the wire, and each machine authorizes its own targets.
//
// INBOUND   POST <path>   Authorization: Bearer <token>
//           { "msgId": "...", "from": "11", "to": "18/agent-1", "delivery": "queue|steer",
//             "text": "...", "hops": 0 }
// OUTBOUND  import { sendToPeer } and call it (see bridge-send.mjs for a CLI wrapper).
//
// SAFETY (every guard is here because it was a named risk in the design record [12030])
//   * token per peer, compared without leaking length/timing (constant-time-ish)
//   * msgId de-duplication inside a 60 s window (replay)
//   * hops >= MAX_HOPS is refused (loops)
//   * target must exist in localTargets (mis-injection)
//   * per-sender token bucket (flooding)
//   * body size and text length caps
//   * NEVER logs the message text (records only ids/sizes) — the text belongs to the trajectory
//
// ROLLBACK: this plugin adds one route. Removing the bundle entry + restart, or
//   plugin_manager disable, returns the machine to a zero-plugin state. Nothing is written
//   outside the DSH session logs.

import { randomUUID, timingSafeEqual } from 'node:crypto'
import { readFileSync, appendFileSync, statSync, renameSync } from 'node:fs'

export const name = 'dsh-agent-bridge'
export const VERSION = '0.1.1-hotreload'
// Hard dependencies: without the HTTP carrier there is no inbound path, and without the
// subagent service there is nothing to inject into.
export const inject = ['webServer', 'subagents']

const MAX_HOPS = 2
const DEDUPE_MS = 60_000
const MAX_BODY = 64 * 1024
const MAX_TEXT = 8 * 1024
const RATE_PER_MIN = 5
const ALLOWED_DELIVERY = new Set(['queue', 'steer'])

function normConfig(config = {}) {
  return {
    path: typeof config.path === 'string' && config.path.startsWith('/') ? config.path : '/agent/inbox',
    token: typeof config.token === 'string' ? config.token : '',
    // Preferred over `token`: the secret lives in an admin-only file (produced from the vault),
    // so it never sits in a world-readable profile config (R46).
    tokenFile: typeof config.tokenFile === 'string' ? config.tokenFile : '',
    // OWN ON-DISK LOG, and why it is not optional:
    // this cluster already lost time to "installed but ineffective" — a plugin that never
    // loaded reports nothing and simply does nothing. Per the owner's measured note
    // (dsh-memory-bridge/README-插件热重载行为.md) a plugin must leave a file marker, so
    // "armed" here is the only trustworthy proof that apply() actually ran in the host.
    logPath: typeof config.logPath === 'string' ? config.logPath : '',
    localTargets: config.localTargets && typeof config.localTargets === 'object' ? config.localTargets : {},
    // SENDER whitelist (default-deny). The cluster is MUTUAL (owner, 2026-10-12): 11, 17 and 18 may
    // each inject into the others. An empty/absent list means "refuse everything", never "allow all".
    // R49(1) support, staged: a per-peer token map. When configured, the SENDER IS DERIVED FROM
    // THE TOKEN (never from the request body), which is what the rule actually requires. Left
    // empty until the cluster lays out per-peer tokens, so nothing changes today.
    peerTokens: config.peerTokens && typeof config.peerTokens === 'object' ? config.peerTokens : {},
    // Same principle as tokenFile (R46): the per-peer tokens live in an ACL-tight FILE produced from
    // the vault, never in this config. Format: {"<peer>":"<token>", ...}
    peerTokensFile: typeof config.peerTokensFile === 'string' ? config.peerTokensFile : '',
    allowedFrom: Array.isArray(config.allowedFrom)
      ? config.allowedFrom.map((s) => String(s).trim()).filter(Boolean)
      : [],
    peers: config.peers && typeof config.peers === 'object' ? config.peers : {},
  }
}

function resolveToken(cfg, warn) {
  if (cfg.token) return cfg.token
  if (!cfg.tokenFile) return ''
  try {
    const t = readFileSync(cfg.tokenFile, 'utf8').trim()
    if (!t) { warn('[agent-bridge] tokenFile is empty: ' + cfg.tokenFile); return '' }
    return t
  } catch (e) {
    warn('[agent-bridge] cannot read tokenFile ' + cfg.tokenFile + ': ' + (e?.message ?? e))
    return ''
  }
}

// 2026-10-23: tokens are HOT-RELOADED. The DB is the source of truth (dbo.bridge_tokens) and each
// machine refreshes its token files every 5 minutes; a plugin that caches them at boot turns every
// rotation into an outage ("token matches no configured peer") until DSH restarts. So re-read the
// files per request, with an mtime cache so the common path costs one stat().
// WARN-FOLD (2026-10-23): the bridge log had 2,077 refusals vs 54 deliveries over 11 days --
// 38:1 noise means a real incident would be invisible. Fold identical warnings to one per 60s.
const __warnSeen = new Map()
function warnFold(fn, key, msg) {
  const now = Date.now()
  const prev = __warnSeen.get(key) ?? 0
  if (now - prev < 60000) return
  __warnSeen.set(key, now)
  try { fn(msg) } catch {}
}const __tokenState = { token: '', peerRaw: '', tokenMtime: 0, peerMtime: 0, at: 0 }
function refreshTokens(cfg, warn) {
  const now = Date.now()
  if (now - __tokenState.at < 1000) return
  __tokenState.at = now
  let changed = false
  // own token
  if (cfg.tokenFile) {
    try {
      const st = statSync(cfg.tokenFile)
      if (st.mtimeMs !== __tokenState.tokenMtime) {
        const t = readFileSync(cfg.tokenFile, 'utf8').trim()
        __tokenState.tokenMtime = st.mtimeMs
        if (t !== __tokenState.token) { __tokenState.token = t; changed = true }
      }
    } catch (e) { warn('[agent-bridge] refresh: cannot read tokenFile ' + cfg.tokenFile + ': ' + (e?.message ?? e)) }
  } else if (cfg.token) {
    __tokenState.token = cfg.token
  }
  // peer token map
  if (cfg.peerTokensFile) {
    try {
      const st = statSync(cfg.peerTokensFile)
      if (st.mtimeMs !== __tokenState.peerMtime) {
        const raw = readFileSync(cfg.peerTokensFile, 'utf8')
        __tokenState.peerMtime = st.mtimeMs
        if (raw !== __tokenState.peerRaw) {
          __tokenState.peerRaw = raw
          const parsed = JSON.parse(raw)
          if (parsed && typeof parsed === 'object') { cfg.peerTokens = parsed; changed = true }
        }
      }
    } catch (e) { warn('[agent-bridge] refresh: cannot read peerTokensFile ' + cfg.peerTokensFile + ': ' + (e?.message ?? e)) }
  }
  if (changed) {
    try { fileLog('TOKENS-RELOADED v' + VERSION + ' peers=' + Object.keys(cfg.peerTokens || {}).length + ' self=' + (__tokenState.token ? 'set' : 'MISSING')) } catch {}
  }
}

function safeEqual(a, b) {
  const ba = Buffer.from(String(a ?? ''), 'utf8')
  const bb = Buffer.from(String(b ?? ''), 'utf8')
  if (ba.length !== bb.length) return false
  try { return timingSafeEqual(ba, bb) } catch { return false }
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0
    const chunks = []
    req.on('data', (c) => {
      size += c.length
      if (size > MAX_BODY) { reject(Object.assign(new Error('body too large'), { code: 413 })); try { req.destroy() } catch {} ; return }
      chunks.push(c)
    })
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    req.on('error', (e) => reject(Object.assign(e, { code: 400 })))
  })
}

export function apply(ctx, config) {
  const cfg = normConfig(config)
  const warnForToken = (m) => { try { ctx.logger?.warn?.(m) ?? ctx.logger?.info?.(m) } catch {} }
  let token = resolveToken(cfg, warnForToken)
  // Peer tokens: inline map wins, otherwise the file; empty either way keeps today's behaviour.
  if (cfg.peerTokensFile && Object.keys(cfg.peerTokens).length === 0) {
    try {
      const raw = JSON.parse(readFileSync(cfg.peerTokensFile, 'utf8'))
      if (raw && typeof raw === 'object') { cfg.peerTokens = raw }
    } catch (e) { warnForToken('[agent-bridge] cannot read peerTokensFile ' + cfg.peerTokensFile + ': ' + (e?.message ?? e)) }
  }
  const seen = new Map()      // msgId -> timestamp
  const buckets = new Map()   // from -> { tokens, at }
  const log = (m) => { try { ctx.logger?.info?.(m) } catch {} ; fileLog(m) }
  const warn = (m) => { try { ctx.logger?.warn?.(m) || ctx.logger?.info?.(m) } catch {} ; fileLog('WARN ' + m) }

  // Rotate at 512 KB so a chatty bridge cannot fill the disk; never writes message text.
  function fileLog(line) {
    if (!cfg.logPath) return
    try {
      if (statSync(cfg.logPath, { throwIfNoEntry: false })?.size > 512 * 1024) {
        renameSync(cfg.logPath, cfg.logPath + '.1')
      }
    } catch {}
    try { appendFileSync(cfg.logPath, new Date().toISOString() + '  ' + line + '\n') } catch {}
  }

  // ★ The armed marker: "installed" is not "loaded". This line is the proof.
  fileLog('BUILD 0.1.1-hotreload (tokens re-read per request)')
fileLog('ARMED v' + VERSION + ' path=' + cfg.path + ' targets=' + Object.keys(cfg.localTargets).length +
    ' token=' + (token ? (cfg.tokenFile ? 'from-file' : 'inline') : 'MISSING'))

  __tokenState.token = token

  try { if (cfg.tokenFile) __tokenState.tokenMtime = statSync(cfg.tokenFile).mtimeMs } catch {}

  try { if (cfg.peerTokensFile) __tokenState.peerMtime = statSync(cfg.peerTokensFile).mtimeMs } catch {}

  __tokenState.at = 0


  if (!token) warn('[agent-bridge] no token available (config or tokenFile) -> every inbound request will be refused')

  function allow(from) {
    const now = Date.now()
    const b = buckets.get(from) ?? { tokens: RATE_PER_MIN, at: now }
    const refill = ((now - b.at) / 60_000) * RATE_PER_MIN
    b.tokens = Math.min(RATE_PER_MIN, b.tokens + refill)
    b.at = now
    if (b.tokens < 1) { buckets.set(from, b); return false }
    b.tokens -= 1
    buckets.set(from, b)
    return true
  }

  function respond(res, code, payload) {
    const body = JSON.stringify(payload)
    try {
      res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(body) })
    } catch { try { res.statusCode = code; res.setHeader?.('content-type', 'application/json; charset=utf-8') } catch {} }
    try { res.end(body) } catch {}
  }

  const handler = async (req, res) => {
    try {
      if ((req.method || '').toUpperCase() !== 'POST') return respond(res, 405, { ok: false, code: 'method-not-allowed' })
      const auth = String(req.headers?.authorization ?? '')
      const supplied = auth.toLowerCase().startsWith('bearer ') ? auth.slice(7).trim() : ''
      // hot-reload tokens before any auth decision (see refreshTokens)
      refreshTokens(cfg, warn)
      token = __tokenState.token || token

      // R49(1): when a per-peer token map is configured it REPLACES the single-token check, so the
      // token identifies the peer before anything else runs.
      const peerEntries = Object.entries(cfg.peerTokens)
      let verifiedPeer = null
      let selfTokenOk = false
      const localName = (typeof process !== 'undefined' && process.env && process.env.COMPUTERNAME) ? process.env.COMPUTERNAME : ''
      if (peerEntries.length > 0) {
        const hit = peerEntries.find(([, tk]) => safeEqual(supplied, tk))
        if (!hit) {
          // SELF fallback: the machine's own single token (tokenFile) is what the LOCAL poller uses for
          // rows it addresses to itself (from == this machine). Without this, flipping to per-peer
          // tokens would break self-delivery.
          if (token && safeEqual(supplied, token)) {
            selfTokenOk = true
          } else {
            warnFold(warn, 'no-peer', '[agent-bridge] refused: token matches no configured peer'); return respond(res, 401, { ok: false, code: 'unauthorized' })
          }
        } else {
        verifiedPeer = hit[0]
        }
      } else if (!token || !safeEqual(supplied, token)) {
        warn('[agent-bridge] refused: bad token from ' + (req.socket?.remoteAddress ?? '?'))
        return respond(res, 401, { ok: false, code: 'unauthorized' })
      }

      let raw
      try { raw = await readBody(req) } catch (e) { return respond(res, e.code === 413 ? 413 : 400, { ok: false, code: 'bad-body' }) }
      let m
      try { m = JSON.parse(raw) } catch { return respond(res, 400, { ok: false, code: 'bad-json' }) }

      // Sender whitelist, before anything else touches state. Checked on the declared origin; the
      // DB path additionally stamps the origin from the sender's own COMPUTERNAME (see bridge-poll).
      let declaredFrom = typeof m.from === 'string' ? m.from.trim() : ''
      // Per-peer tokens (staged): if a map is configured, the token identifies the peer and the
      // body's `from` must agree with it; a mismatch is an impersonation attempt, not a typo.
      if (verifiedPeer !== null) {
        if (declaredFrom && declaredFrom !== verifiedPeer) {
          warn('[agent-bridge] refused: body from=' + declaredFrom + ' but token belongs to ' + verifiedPeer + ' (impersonation)')
          return respond(res, 403, { ok: false, code: 'sender-mismatch' })
        }
        declaredFrom = verifiedPeer
      } else if (selfTokenOk) {
        // the machine's own token may only speak for the machine itself
        if (declaredFrom && declaredFrom !== localName) {
          warn('[agent-bridge] refused: body from=' + declaredFrom + ' but the local token belongs to ' + localName)
          return respond(res, 403, { ok: false, code: 'sender-mismatch' })
        }
        declaredFrom = declaredFrom || localName
      }
      if (cfg.allowedFrom.length === 0 || !cfg.allowedFrom.includes(declaredFrom)) {
        warn('[agent-bridge] refused: sender not allowed (' + (declaredFrom || '(empty)') + ')')
        return respond(res, 403, { ok: false, code: 'sender-not-allowed' })
      }

      const msgId = typeof m.msgId === 'string' ? m.msgId.trim() : ''
      const from = typeof m.from === 'string' ? m.from.trim() : ''
      const to = typeof m.to === 'string' ? m.to.trim() : ''
      const delivery = typeof m.delivery === 'string' ? m.delivery : 'queue'
      const text = typeof m.text === 'string' ? m.text : ''
      const hops = Number.isInteger(m.hops) ? m.hops : 0
      if (!msgId || !from || !to) return respond(res, 400, { ok: false, code: 'missing-field' })
      if (!ALLOWED_DELIVERY.has(delivery)) return respond(res, 400, { ok: false, code: 'bad-delivery' })
      if (text.length === 0 || text.length > MAX_TEXT) return respond(res, 400, { ok: false, code: 'bad-text-length' })
      if (hops >= MAX_HOPS) return respond(res, 409, { ok: false, code: 'hop-limit' })

      const now = Date.now()
      for (const [k, t] of seen) if (now - t > DEDUPE_MS) seen.delete(k)
      if (seen.has(msgId)) return respond(res, 200, { ok: true, deduplicated: true })
      if (!allow(from)) return respond(res, 429, { ok: false, code: 'rate-limited' })

      const target = cfg.localTargets[to]
      if (!target || !target.parentSessionId || !target.childSessionId) {
        return respond(res, 404, { ok: false, code: 'unknown-target' })
      }

      const requestId = randomUUID()
      let messageId
      let returnValue
      try {
        returnValue = await ctx.subagents.prompt({
          requestId,
          parentSessionId: target.parentSessionId,
          childSessionId: target.childSessionId,
          mode: 'continuable',
          delivery,
          // R50: subagents.prompt carries text only, so the VERIFIED origin must travel with the
          // text - otherwise no target can ever tell whose instruction it is.
          content: [{ type: 'text', text: '[bridge msg=' + msgId + ' from=' + declaredFrom + ' to=' + to + ' delivery=' + delivery + ' ts=' + new Date().toISOString() + ']\n' + text }],
        }, new AbortController().signal)
        // The runtime does not return a bare string here: unwrap whatever id it carries, so the
        // log and the response never degrade to "[object Object]" (observed in the first live run).
        messageId = (typeof returnValue === 'string')
          ? returnValue
          : (returnValue?.id ?? returnValue?.messageId ?? returnValue?.inboxId ?? returnValue?.message?.id ?? requestId)
      } catch (e) {
        warn('[agent-bridge] inject failed for ' + to + ': ' + (e?.message ?? e))
        return respond(res, 502, { ok: false, code: 'delivery-failed', detail: String(e?.code ?? e?.message ?? 'error') })
      }

      seen.set(msgId, now)
      // Deliberately NO message text in the log: ids and sizes only.
      log('[agent-bridge] delivered ' + to + ' delivery=' + delivery + ' bytes=' + text.length + ' messageId=' + messageId)
      return respond(res, 202, { ok: true, messageId: String(messageId ?? ''), to })
    } catch (e) {
      warn('[agent-bridge] handler error: ' + (e?.message ?? e))
      return respond(res, 500, { ok: false, code: 'internal' })
    }
  }

  const dispose = ctx.webServer.register({ kind: 'exact', path: cfg.path, handler })
  log('[agent-bridge] ' + VERSION + ' listening on ' + cfg.path + ' with ' + Object.keys(cfg.localTargets).length + ' local target(s)')
  return () => { try { dispose?.() } catch {} ; seen.clear(); buckets.clear() }
}

// Outbound helper (used by bridge-send.mjs and, later, by a tool plugin).
export async function sendToPeer(peer, msg, fetchImpl = globalThis.fetch) {
  if (!peer || typeof peer.url !== 'string') throw new Error('peer.url is required')
  const url = peer.url.replace(/\/+$/, '') + (peer.path || '/agent/inbox')
  const res = await fetchImpl(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: 'Bearer ' + String(peer.token ?? '') },
    body: JSON.stringify({ ...msg, hops: (Number.isInteger(msg?.hops) ? msg.hops : 0) + 1 }),
  })
  let body = ''
  try { body = await res.text() } catch {}
  let parsed = null
  try { parsed = JSON.parse(body) } catch {}
  return { status: res.status, ok: res.ok, body: parsed ?? body }
}
// hmr-touch 2026-10-23 01:40:50
