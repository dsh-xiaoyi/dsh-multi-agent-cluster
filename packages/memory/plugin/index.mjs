
// 出错不要静默：写到 <memHome>\logs\memory-bridge-errors.log（最多保留最近 200 行）
function noteErr(where, e) {
  try {
    const home = process.env.DSH_MEM_HOME || 'C:\\dsh-mem'
    const dir = home + '\\logs'
    try { mkdirSync(dir, { recursive: true }) } catch (_) { }
    const file = dir + '\\memory-bridge-errors.log'
    const line = new Date().toISOString() + ' [' + where + '] ' + (e && e.message ? e.message : String(e)) + '\n'
    appendFileSync(file, line, 'utf8')
    try {
      const st = statSync(file)
      if (st.size > 64 * 1024) {
        const all = readFileSync(file, 'utf8').split('\n')
        writeFileSync(file, all.slice(-200).join('\n'), 'utf8')
      }
    } catch (_) { }
  } catch (_) { }
}

// dsh-memory-bridge — host half.  v0.3.0
//
// TWO JOBS
//   1) INJECT  — put a compact digest of the shared long-term memory into every
//      session's system prompt, so a brand-new conversation is never a blank slate.
//   2) CAPTURE — when DSH compacts a session it writes a checkpoint summary into the
//      session log as a user message. That text is ALREADY a distillation, so we
//      persist it as a shared memory instead of paying for another model call.
//
// v0.4.0 = MERGED: 11 activity section (baseline) + 18 llm accounting (see [81] collision note)
// v0.3.0 ADDED (by 11): an ACTIVITY section — "what the other two machines are doing right now".
//   The replica already carries one row per session (machine / title / event_count /
//   last_seen_at), so no schema or CLI change is needed: we group by machine, keep the
//   freshest row each, and render a few lines. This is the cheapest possible answer to
//   "另一个我在忙什么" — a few hundred characters instead of pulling a whole session.
//
// WHY IT READS A FILE INSTEAD OF THE DATABASE
//   PromptContext.text must be SYNCHRONOUS (see the systemPrompt contract), so it
//   cannot await a query. The DshMemoryAgent service refreshes a local replica
//   (dsh-mem-replica.json) every 60 seconds: the hook is a cheap in-memory return,
//   needs no database driver, and keeps working while the DB host is unreachable.
//
// TIMESTAMP GOTCHA (cost us two wrong guesses)
//   PowerShell 5.1's ConvertTo-Json writes DateTime columns in the legacy
//   "/Date(1791190176972)/" form: Unix milliseconds, UTC. Node's JSON.parse leaves that
//   as a plain STRING (good — nothing is silently shifted), but PowerShell's own
//   ConvertFrom-Json DOES reinterpret it and shifts it by the local timezone, which made
//   a correct value look 8 hours wrong. So we parse the milliseconds ourselves here.
//
// WHY IT SHELLS OUT TO THE CLI
//   Writing memory correctly needs the SQL connection, the redaction rules and the
//   idempotent upserts dsh-mem.ps1 already implements. Instead of duplicating (or
//   weakening) that in JavaScript, the plugin invokes the CLI — but it passes the
//   title/body through UTF-8 FILES and a generated wrapper, never through
//   command-line quoting (command-line Chinese broke in an earlier attempt).
//
// SAFETY
//   * every entry point is wrapped: this plugin must never break prompt assembly,
//     the session log, or the agent loop
//   * capture is switchable (autoCapture:false) and de-duplicated per event
//   * the CLI applies the same secret redaction as manual saves

import { statSync, appendFileSync, mkdirSync, readFileSync, existsSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import { spawn } from 'node:child_process'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

export const VERSION = '0.4.2'
export const name = 'dsh-memory-bridge'
export const inject = ['systemPrompt']

// DSH writes this sentence at the head of a compaction summary. Match either language.
const CHECKPOINT_MARK = /automatically generated checkpoint|自动生成[^\n]{0,12}checkpoint|condensing an earlier span/i

function firstText(data) {
  try {
    const parts = Array.isArray(data && data.content) ? data.content : []
    const out = []
    for (const p of parts) {
      if (p && p.type === 'text' && typeof p.text === 'string') out.push(p.text)
    }
    return out.join('\n').trim()
  } catch (e) {
    return ''
  }
}

// Accept the legacy "/Date(ms)/" form as well as ISO-8601 / epoch numbers.
//
// ★ The legacy form carries a REAL BUG we measured (not a guess):
//   the SQL column holds UTC, .NET hands it back with Kind=Unspecified, and
//   PowerShell's ConvertTo-Json assumes Unspecified means LOCAL — so the epoch it
//   writes is shifted by this machine's UTC offset (measured: 8 hours on UTC+8).
//   Arithmetic proof: 1791190366180 mod 86400000 = 31866180 ms = 08:52:46 while the
//   DB value for the same row was 16:52:46 UTC.
//   ISO-8601 (what the CLI emits once fixed) is NOT shifted, so we only compensate
//   on the legacy form — that keeps this forward-compatible with a CLI-side fix.
function parseStamp(v) {
  try {
    if (v === null || v === undefined) return null
    if (typeof v === 'number') return new Date(v)
    if (v instanceof Date) return v
    const s = String(v)
    const m = /\/Date\((-?\d+)([+-]\d+)?\)\//.exec(s)
    if (m) {
      const raw = Number(m[1])
      const off = new Date(raw).getTimezoneOffset()   // minutes; UTC+8 -> -480
      return new Date(raw - off * 60000)              // undo the local-offset shift
    }
    const d = new Date(s)
    return isNaN(d.getTime()) ? null : d
  } catch (e) {
    return null
  }
}

function hhmmUTC(d) {
  try {
    const p = function (n) { return (n < 10 ? '0' : '') + n }
    return p(d.getUTCHours()) + ':' + p(d.getUTCMinutes()) + ' UTC'
  } catch (e) { return '?' }
}

function agoText(d, now) {
  try {
    const min = Math.max(0, Math.round((now.getTime() - d.getTime()) / 60000))
    if (min < 1) return '刚刚'
    if (min < 60) return min + ' 分钟前'
    const h = Math.floor(min / 60)
    if (h < 24) return h + ' 小时前'
    return Math.floor(h / 24) + ' 天前'
  } catch (e) { return '' }
}

export function apply(ctx, config) {
  config = config || {}
  // 记忆目录：优先 config，其次环境变量 DSH_MEM_HOME，最后默认 C:\dsh-mem（安装文档里的默认位置）
  const memHome     = process.env.DSH_MEM_HOME || 'C:\\dsh-mem'
  const replicaPath = config.replicaPath || (memHome + '\\dsh-mem-replica.json')
  const cliPath     = config.cliPath     || (memHome + '\\dsh-mem.ps1')
  const powershell  = config.powershell  || 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe'
  const limit       = Number(config.limit    || 8)
  // 2026-10-23: 关键约定文件（每次会话完整注入）+ 定义型记忆（不看新旧，只看是否定义行为）
  const conventionsPath = config.conventionsPath || 'C:\\dsh-mem\\conventions.md'
  const pinnedKinds = Array.isArray(config.pinnedKinds) ? config.pinnedKinds : ['decision','fact','rule','correction']
  const pinnedLimit = Number(config.pinnedLimit || 6)
  // AUTO-RECALL 2026-10-23: 从副本里读"最近真正说过的话"，去记忆库做关键词检索，注入相关旧约定
  const autoRecall   = config.autoRecall === false ? false : true
  const recallTop    = Number(config.recallTop || 4)
  const maxChars    = Number(config.maxChars || 2400)
  const refreshMs   = Number(config.refreshMs || 60000)
  const heading     = config.heading || '共享长期记忆（三台机器共用）'
  const activity    = config.activity !== false
  const activityMax = Number(config.activityMax || 6)

  const autoCapture = config.autoCapture !== false
  const captureMin  = Number(config.captureMinChars || 120)
  const captureMax  = Number(config.captureMaxChars || 6000)
  const captureTag  = config.captureTag || 'auto-capture'
  const logPath     = config.logPath || join(dirname(fileURLToPath(import.meta.url)), 'bridge.log')
  const localProviders = new Set(config.localProviders || ['ollama-local'])   // accounting: only these providers
  const callLogFlushMs = Number(config.callLogFlushMs || 60000)               // accounting: merge window

  const captured = new Set()

  function log(msg) {
    if (!logPath) return
    try { writeFileSync(logPath, new Date().toISOString() + '  ' + msg + '\n', { flag: 'a' }) } catch (e) { }
  }

  // ---------------- 1) inject ----------------

  let digest = ''

  function refresh() {
    try {
      if (!existsSync(replicaPath)) {
        // fail LOUDLY inside the prompt: a silent empty digest is the hardest kind of
        // "installed but not working" to notice (we hit exactly that).
        digest = '## ' + heading + '\n\n警告: 找不到本机离线副本 ' + replicaPath + '\n请检查插件配置 replicaPath，以及 DshMemoryAgent 服务是否在运行。'
        return
      }
      let rawText = readFileSync(replicaPath, 'utf8')
      if (rawText.charCodeAt(0) === 0xFEFF) rawText = rawText.slice(1)
      const raw = JSON.parse(rawText)

      const mems = Array.isArray(raw.memories) ? raw.memories.slice() : []
      mems.sort(function (a, b) { return (Number(b.id) || 0) - (Number(a.id) || 0) })

      const now = parseStamp(raw.generatedAt) || new Date()

      // ★ 顺序刻意如此: 头部 → 活动段 → 取细节提示 → 最近结论。
      //   最后一段（记忆列表）最占地方，超过 maxChars 时被截断的是它 —— 也就是
      //   最旧的那几条结论，而不是"活动段"或"怎么取细节"的提示。
      const lines = []
      lines.push('## ' + heading)
      lines.push('')
      lines.push('')
      lines.push('> **强制指令（每次会话第一眼看这条）**：回答任何"以前怎么定的 / 约定 / 规则"类问题之前，必须先查记忆库，不许凭印象。')
      lines.push('>   powershell -ExecutionPolicy Bypass -File "' + cliPath + '" search <关键词>')
      lines.push('> 并读 C:\\dsh-mem\\conventions.md（长期硬约定，全部有效）。查不到就问用户，不要猜。')
      lines.push('来源: 本机离线副本，刷新于 ' + (raw.generatedAt || '?') + '；库主机 ' + (raw.server || '?') + '；共 ' + mems.length + ' 条记忆')

      // ---- AUTO-RECALL v3 (IDF): 与当前话题相关的旧记忆 ----
      // v2 失败教训（2026-10-23）：阈值+长度归一 把"上周末 360 演练报告"挡掉了，因为
      // 提问里的词（防护/能力）都很常见，而'360'这种稀有词没有额外权重。
      // v3 用 IDF 给稀有词加权，并做少量同义词扩展；门槛改成"分数≥1.2 且 (中文命中≥2 或 含数字标识)"。
      if (autoRecall) {
        try {
          const NOISE = ['Current runtime context', '[bridge msg', 'Agent ', 'Background subagent', 'This is an automatically generated', '[SCHEDULE', '<goal_', 'Time sampled while preparing']
          const CJK_STOP = new Set(['这个','那个','我们','你们','他们','什么','怎么','可以','已经','还是','因为','所以','就是','不是','没有','现在','今天','明天','一个','这样','那样','需要','应该','如果','然后','但是','而且','或者','时候','一次','一样','多少','哪里','请问','谢谢','好的','收到','明白','继续','算是','属于','问题','会话','记得','小易','那么','你对'])
          const EN_STOP = new Set(['the','and','for','this','that','with','from','while','time','dsh','turn','step','sampled','preparing','browser','zone','asia','shanghai','request','context','current','runtime','http','https','true','false','null'])
          const SYN = { '防护': ['防御','拦截','查杀','隔离'], '能力': ['效果','评估','演练'], '测试': ['演练','渗透','评估'], '演练': ['渗透','评估'], '病毒': ['木马','EICAR','查杀'], '备份': ['冷备','网盘','云端'], '记忆': ['记忆库','注入','失忆','检索'] }
          const kws = new Set()
          const addKws = function (text) {
            const t = String(text || '')
            for (const m of t.matchAll(/[\u4e00-\u9fa5]{2,4}/g)) {
              let w = m[0].replace(/^[的了是我你他她它就也都还很再又和与及或者吧呢啊呀]/, '').replace(/[的了是]$/, '')
              if (w.length >= 2 && !CJK_STOP.has(w)) kws.add(w)
            }
            for (const m of t.matchAll(/[A-Za-z][A-Za-z0-9_\-\.]{3,}/g)) { const w = m[0].toLowerCase(); if (!EN_STOP.has(w)) kws.add(w) }
            for (const m of t.matchAll(/\b\d{2,4}\b/g)) kws.add(m[0])
            for (const w of Array.from(kws)) { const ex = SYN[w]; if (ex) ex.forEach(function (e) { kws.add(e) }) }
          }
          const rawUsers = (Array.isArray(raw.messages) ? raw.messages : [])
            .filter(function (m) { return String(m.role || '') === 'user' })
            .filter(function (m) { const t = String(m.text || ''); return t.trim() && !NOISE.some(function (p) { return t.startsWith(p) }) })
            .sort(function (a, b) { return (Number(b.id) || 0) - (Number(a.id) || 0) })
            .slice(0, 2)
          rawUsers.forEach(function (m) { addKws(m.text) })
          const kwList = Array.from(kws)
          if (kwList.length) {
            const pool = mems.filter(function (m) {
              if (String(m.kind || '') === 'checkpoint') return false
              if (String(m.body || '').length > 6000) return false
              return true
            })
            const hays = []
            for (const m of pool) hays.push((String(m.title || '') + ' ' + String(m.body || '') + ' ' + String(m.tags || '')).toLowerCase())
            const N = Math.max(1, pool.length)
            const df = new Map()
            for (const k of kwList) {
              const kl = k.toLowerCase()
              let n = 0
              for (const h of hays) if (h.indexOf(kl) >= 0) n++
              df.set(k, n)
            }
            const idf = function (k) { return Math.log(1 + N / (1 + (df.get(k) || 0))) }
            const CJK = /[\u4e00-\u9fa5]/
            const scored = []
            for (let i2 = 0; i2 < pool.length; i2++) {
              const m = pool[i2], hay = hays[i2], len = Math.max(200, hay.length)
              const hitSet = new Set()
              let w = 0
              for (const k of kwList) {
                const kl = k.toLowerCase()
                if (hay.indexOf(kl) < 0) continue
                hitSet.add(k)
                w += idf(k) * (CJK.test(k) ? 1.0 : 0.8)
              }
              if (!hitSet.size) continue
              const cjkHits = Array.from(hitSet).filter(function (k) { return CJK.test(k) }).length
              const hasNum = Array.from(hitSet).some(function (h) { return /^\d{2,4}$/.test(h) })
              const score = w / Math.sqrt(len / 500)
              if (score < 1.2) continue
              if (cjkHits < 2 && !hasNum) continue
              scored.push({ id: m.id, kind: String(m.kind || ''), title: m.title, score: score, hits: Array.from(hitSet).slice(0, 8) })
            }
            scored.sort(function (a, b) { return b.score - a.score })
            const top = scored.slice(0, recallTop)
            if (top.length) {
              lines.push('')
              lines.push('### 与当前话题相关的记忆（自动检索 v3/IDF，可能不全；要全量请用 search）')
              for (const t of top) {
                lines.push('- [' + t.id + '] (' + t.kind + ') ' + String(t.title || '').replace(/\s+/g, ' ').trim() + '  ‹命中: ' + t.hits.join('/') + '›')
              }
            }
          }
        } catch (e) { }
      }

      // ---- 关键约定：每次完整注入（不看新旧）----
      try {
        if (conventionsPath && existsSync(conventionsPath)) {
          let conv = readFileSync(conventionsPath, 'utf8')
          if (conv.charCodeAt(0) === 0xFEFF) conv = conv.slice(1)
          conv = conv.trim()
          if (conv) {
            lines.push('')
            lines.push('### 关键约定（完整，勿违背）')
            lines.push(conv)
          }
        }
      } catch (e) { }

      // ---- ACTIVITY: newest session per machine (v0.3.0) ----
      if (activity && Array.isArray(raw.sessions) && raw.sessions.length) {
        const best = new Map()
        for (const s of raw.sessions) {
          try {
            const t = parseStamp(s && s.last_seen_at)
            if (!t) continue
            const key = String((s && s.machine) || '?')
            const cur = best.get(key)
            if (!cur || t.getTime() > cur.t.getTime()) best.set(key, { t: t, s: s })
          } catch (e) { }
        }
        const rows = Array.from(best.values()).sort(function (a, b) { return b.t.getTime() - a.t.getTime() })
        if (rows.length) {
          lines.push('')
          lines.push('### 各机最近活动（同一份离线副本，时间 UTC）')
          for (const r of rows.slice(0, activityMax)) {
            const title = String((r.s && r.s.title) || '').trim() || '(未命名会话)'
            const ev = Number((r.s && r.s.event_count) || 0)
            lines.push('- ' + (r.s.machine || '?') + ' · 「' + title + '」 · ' + hhmmUTC(r.t) + '（' + agoText(r.t, now) + '，' + ev + ' 事件）')
          }
        }
      }

      lines.push('')
      lines.push('取细节（本机命令，勿凭印象回答历史问题）:')
      lines.push('  powershell -ExecutionPolicy Bypass -File "' + cliPath + '" search <关键词>')
      lines.push('  powershell -ExecutionPolicy Bypass -File "' + cliPath + '" recent -Limit 20')
      lines.push('  powershell -ExecutionPolicy Bypass -File "' + cliPath + '" handoff    # 接力另一台机器的会话')

      lines.push('')
      lines.push('### 定义型记忆（决策/事实/规则/更正，不按新旧筛）')
      try {
        const pinned = mems.filter(function (m) { return pinnedKinds.indexOf(String(m.kind || '')) >= 0 }).slice(0, pinnedLimit)
        for (const m of pinned) {
          let body = String(m.body || '').replace(/\s+/g, ' ').trim()
          if (body.length > 160) body = body.slice(0, 160) + ' …'
          lines.push('- [' + m.id + '] (' + (m.kind || '?') + ') ' + (m.title || '') + (body ? ' — ' + body : ''))
        }
      } catch (e) { }

      lines.push('')
      lines.push('### 最近结论（新 → 旧）')
      for (const m of mems.slice(0, limit)) {
        let body = String(m.body || '').replace(/\s+/g, ' ').trim()
        if (body.length > 200) body = body.slice(0, 200) + ' …'
        lines.push('- [' + m.id + '] (' + (m.kind || '?') + ') ' + (m.title || '') + (body ? ' — ' + body : ''))
      }

      let text = lines.join('\n')
      if (text.length > maxChars) text = text.slice(0, maxChars) + '\n…（已截断）'
      digest = text
    } catch (e) {
      digest = ''
    }
  }

  refresh()
  const timer = setInterval(refresh, refreshMs)
  if (typeof timer.unref === 'function') timer.unref()

  ctx.systemPrompt.context({ name: 'shared-memory', order: 900, text: function () { return digest } })

  // ---------------- 2) capture ----------------

  function saveMemory(kind, title, body, session) {
    try {
      const dir = mkdtempSync(join(tmpdir(), 'dshmem-'))
      const tPath = join(dir, 'title.txt')
      const bPath = join(dir, 'body.txt')
      const sPath = join(dir, 'subject.txt')
      const wPath = join(dir, 'run.ps1')
      writeFileSync(tPath, title, 'utf8')
      writeFileSync(bPath, body, 'utf8')

      const machine = config.machine || process.env.COMPUTERNAME || 'unknown'
      const src = session && session.id ? String(session.id) : ''
      const q = function (s) { return String(s).replace(/'/g, "''") }
      // ★ 机器名可能是中文（本机 COMPUTERNAME 就是"NODE-A"）。
      //   v0.4.1 把 -Subject '<机器名>' 内联进这个 wrapper，而 wrapper 是【无 BOM 的
      //   UTF-8 .ps1】—— PowerShell 5.1 会按 ANSI 读它，于是中文被写成乱码
      //   （实测: 库里 subject 存成 "鏈ㄦ槗"，E9 8F 88 …）。
      //   现在 subject 也走 UTF-8 文件（和 title/body 一样），wrapper 里不再出现中文。
      //   另外仍然给 wrapper 加 BOM —— 双保险，将来若有人再往里面塞中文也不会坏。
      writeFileSync(sPath, machine, 'utf8')
      const ps = [
        "$ErrorActionPreference = 'Stop'",
        "$t = Get-Content -LiteralPath '" + q(tPath) + "' -Raw -Encoding UTF8",
        "$b = Get-Content -LiteralPath '" + q(bPath) + "' -Raw -Encoding UTF8",
        "$s = Get-Content -LiteralPath '" + q(sPath) + "' -Raw -Encoding UTF8",
        "& '" + q(cliPath) + "' save -Title $t -Body $b -Tags '" + captureTag + "' -Scope machine -Subject $s -Kind " + kind + " -Confidence 90 -Target '" + q(src) + "'",
      ].join('\r\n')
      writeFileSync(wPath, '\uFEFF' + ps, 'utf8')

      const child = spawn(powershell, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', wPath], { stdio: 'ignore', windowsHide: true })
      child.on('exit', function (code) {
        log('capture ' + kind + ' exit=' + code + ' len=' + body.length)
        try { rmSync(dir, { recursive: true, force: true }) } catch (e) { }
      })
      child.on('error', function (err) {
        log('capture spawn error: ' + (err && err.message))
        try { rmSync(dir, { recursive: true, force: true }) } catch (e) { }
      })
    } catch (err) {
      log('capture setup failed: ' + (err && err.message))
    }
  }

  if (autoCapture) {
    try {
      ctx.on('session/event', function (session, event) {
        try {
          if (!event || event.type !== 'user/message') return
          const text = firstText(event.data)
          if (!text || text.length < captureMin) return
          if (!CHECKPOINT_MARK.test(text)) return
          const key = String(session && session.id ? session.id : '?') + '#' + String(event.seq)
          if (captured.has(key)) return
          captured.add(key)
          if (captured.size > 200) captured.clear()
          const clipped = text.length > captureMax ? text.slice(0, captureMax) + '\n…[截断]' : text
          const title = '会话压缩摘要（自动捕获）' + (session && session.id ? ' · ' + String(session.id).slice(8, 16) : '')
          saveMemory('checkpoint', title, clipped, session)
        } catch (err) {
          log('session/event handler failed: ' + (err && err.message))
        }
      })
      log('auto-capture armed')
    } catch (err) {
      log('failed to arm auto-capture: ' + (err && err.message))
    }
  }

  // ---------------- 3) account for LOCAL model calls ----------------
  // 用户要求: 本地模型的调用要记进共享记忆，让三台都能看到。
  // llm/stream 是所有模型调用的唯一必经点（waterfall），可读到
  // options.provider / model / sessionId / purpose，并可包装流以捕获 usage。
  // ★ 只记【本地提供方】的调用 —— 否则每个 agent step 写一行会把记忆库淹掉。
  const pendingCalls = new Map()

  function noteCall(options, usage, ms) {
    try {
      const sid = String(options.sessionId || '(no-session)')
      let q = pendingCalls.get(sid)
      if (!q) { q = { count: 0, inTok: 0, outTok: 0, ms: 0, purposes: new Set(), model: options.model, at: Date.now() }; pendingCalls.set(sid, q) }
      q.count++
      q.ms += ms
      if (usage) { q.inTok += Number(usage.inputTokens || 0); q.outTok += Number(usage.outputTokens || 0) }
      if (options.purpose) q.purposes.add(String(options.purpose))
      q.model = options.model
      q.at = Date.now()
    } catch (e) { log('noteCall failed: ' + (e && e.message)) }
  }

  function flushCalls() {
    try {
      const now = Date.now()
      for (const entry of Array.from(pendingCalls.entries())) {
        const sid = entry[0], q = entry[1]
        if (now - q.at < callLogFlushMs) continue
        pendingCalls.delete(sid)
        log('flushCalls -> save llm-call sid=' + sid.slice(0,20) + ' count=' + q.count)
        const body = [
          '本地模型调用记录（dsh-memory-bridge 自动记账）',
          '',
          '模型     : ' + q.model + '  @ 192.0.2.18（RTX 3060, Ollama）',
          '会话     : ' + sid,
          '调用次数 : ' + q.count,
          '耗时合计 : ' + (q.ms / 1000).toFixed(1) + ' 秒',
          'tokens   : 输入 ' + q.inTok + ' / 输出 ' + q.outTok,
          '用途     : ' + (q.purposes.size ? Array.from(q.purposes).join(', ') : '(普通对话)'),
          '',
          '说明: 本地模型跑在 192.0.2.18 的 GPU 上，不消耗云端额度；',
          '      空闲时不占显存（keep_alive=0），不影响该机打游戏。'
        ].join('\n')
        const title = '本地模型调用 · ' + q.model + ' × ' + q.count + ' · ' + sid.slice(8, 16)
        saveMemory('llm-call', title, body, { id: sid })
      }
    } catch (e) { log('flushCalls failed: ' + (e && e.message)) }
  }

  const callTimer = setInterval(flushCalls, callLogFlushMs)
  if (typeof callTimer.unref === 'function') callTimer.unref()

  try {
    // ★★ CONTRACT (read from the host's own Inspect provider, 2026-10-06):
    //   'llm/stream'(this: LlmRuntime, options: GenerateOptions, next: () => AsyncIterable<StreamChunk>): AsyncIterable<StreamChunk>
    //   mode: waterfall.  `this` is the LlmRuntime — it is NOT a parameter.
    //
    // v0.4.0 declared `(runtime, options, next)` here. That extra leading parameter
    // shifted everything by one: `options` actually received `next`, and the real `next`
    // parameter was undefined — so `next()` threw
    //   "next(...) is not a function or its return value is not async iterable"
    // on EVERY model call, which took down every session on that machine.
    // Do not add a leading parameter back. verify.mjs now calls this handler with the
    // real arity and a fake `next`, so a regression fails the self-test instead of DSH.
    ctx.on('llm/stream', async function* (options, next) {
      const t0 = Date.now()
      let usage = null
      try {
        for await (const chunk of next()) {
          if (chunk && chunk.type === 'usage') usage = chunk.usage
          yield chunk
        }
      } finally {
        try { if (options && localProviders.has(options.provider)) noteCall(options, usage, Date.now() - t0) } catch (e) { }
      }
    })
    log('llm accounting armed for providers: ' + Array.from(localProviders).join(','))
  } catch (e) { log('failed to arm llm accounting: ' + (e && e.message)) }

  return function () { try { clearInterval(timer) } catch (e) { } try { clearInterval(callTimer) } catch (e) { } }
}
