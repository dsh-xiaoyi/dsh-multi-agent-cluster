// bridge-send.mjs — outbound CLI for dsh-agent-bridge (prototype).
//
// Sends one message to a peer's /agent/inbox. Used by the live 11 -> 18 test, and later by
// a tool plugin so an agent can call it directly.
//
// R46: the message TEXT is passed through a FILE, never through the command line; the peer
// TOKEN is read from a config file, never from the command line.
//
//   node bridge-send.mjs --peer 18 --to "18/agent-1" --text-file C:\temp\msg.txt --delivery steer
//   node bridge-send.mjs --config C:\dsh-mem\dsh-agent-bridge\peers.json ... (same flags)
//
// The peers file shape (keep it admin-readable only; the token may also come from the vault):
//   { "18": { "url": "http://192.0.2.18:19387", "path": "/agent/inbox", "token": "..." } }
//
// Exit codes: 0 sent, 2 usage/config problem, 3 peer refused/network failure.

import { readFileSync, existsSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
import { sendToPeer } from './index.mjs'

function arg(name, fallback = undefined) {
  const i = process.argv.indexOf('--' + name)
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : fallback
}

const peerName = arg('peer')
const to = arg('to')
const textFile = arg('text-file')
const delivery = arg('delivery', 'queue')
const configPath = arg('config', 'C:\\dsh-mem\\dsh-agent-bridge\\peers.json')
const from = arg('from', process.env.COMPUTERNAME || 'unknown')

if (!peerName || !to || !textFile) {
  console.error('usage: node bridge-send.mjs --peer <name> --to <logical-target> --text-file <path> [--delivery queue|steer] [--config <peers.json>]')
  process.exit(2)
}
if (!['queue', 'steer'].includes(delivery)) { console.error('bad --delivery: ' + delivery); process.exit(2) }
if (!existsSync(configPath)) { console.error('peers config not found: ' + configPath); process.exit(2) }
if (!existsSync(textFile)) { console.error('text file not found: ' + textFile); process.exit(2) }

let peers
try { peers = JSON.parse(readFileSync(configPath, 'utf8')) } catch (e) { console.error('cannot parse ' + configPath + ': ' + e.message); process.exit(2) }
const peer = peers[peerName]
if (!peer) { console.error('peer not configured: ' + peerName + '  (known: ' + Object.keys(peers).join(', ') + ')'); process.exit(2) }
if (!peer.token) { console.error('peer ' + peerName + ' has no token configured'); process.exit(2) }

const text = readFileSync(textFile, 'utf8')
const msgId = randomUUID()
let out
try {
  out = await sendToPeer(peer, { msgId, from, to, delivery, text, hops: 0 })
} catch (e) {
  console.error('send failed: ' + (e?.message ?? e))
  process.exit(3)
}
console.log('peer=' + peerName + ' to=' + to + ' delivery=' + delivery + ' msgId=' + msgId + ' bytes=' + text.length)
console.log('response: HTTP ' + out.status + '  ' + (typeof out.body === 'string' ? out.body : JSON.stringify(out.body)))
process.exit(out.status >= 200 && out.status < 300 ? 0 : 3)
