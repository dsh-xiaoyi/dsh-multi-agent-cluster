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

import { readFileSync, existsSync, readdirSync, writeFileSync, mkdtempSync, rmSync, statSync, appendFileSync, renameSync, mkdirSync } from 'node:fs'
import { spawn, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import os, { tmpdir } from 'node:os'   // 2026-10-25 修：之前只取了 tmpdir，os 未定义 ⇒ SELF_ID 抛错被 catch 吞
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

export const VERSION = '0.5.3'
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
  // 2026-10-24 采纳 17/18 复核建议：路径不再靠"每机一套变体 + 人传用哪个"，
  //   改为运行时解析：配置给的路径存在就用它；否则按候选列表探测（C:\dsh-mem / G:\deepseek / E:\deepseek）。
  const pathTrace = []
  function pickExisting (configured, candidates, label) {
    const list = []
    if (configured) list.push(configured)
    for (const c of (candidates || [])) list.push(c)
    const skipped = []
    let chosen = ''
    for (const c of list) {
      try {
        if (c && existsSync(c)) { chosen = c; break }
        skipped.push(c + ' (missing)')
      } catch (e) { skipped.push(c + ' (err)') }
    }
    if (!chosen) chosen = configured || (candidates && candidates[0]) || ''
    pathTrace.push({ what: label, chosen: chosen, skipped: skipped })
    return chosen
  }
  const require_stat = function (f) { return statSync(f) }
  function describeFile (f) {
    try {
      if (!f || !existsSync(f)) return 'missing'
      const st = require_stat(f)
      return (st.isDirectory() ? 'dir' : (st.size + 'B'))
    } catch (e) { return 'err' }
  }
  const PATH_CANDIDATES = [
    'C:\\dsh-mem',
    'G:\\deepseek',
    'E:\\deepseek',
    'D:\\deepseek'
  ]
  const replicaPath = pickExisting(config.replicaPath || 'C:\\dsh-mem\\dsh-mem-replica.json',
    PATH_CANDIDATES.map(function (d) { return d + '\\dsh-mem-replica.json' }), 'replica')
  const cliPath = pickExisting(config.cliPath || 'C:\\dsh-mem\\dsh-mem.ps1',
    PATH_CANDIDATES.map(function (d) { return d + '\\dsh-mem.ps1' }), 'cli')
  const powershell  = config.powershell  || 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe'
  const limit       = Number(config.limit    || 8)
  // 2026-10-23: 关键约定文件（每次会话完整注入）+ 定义型记忆（不看新旧，只看是否定义行为）
  const conventionsPath = pickExisting(config.conventionsPath || 'C:\\dsh-mem\\conventions.md',
    PATH_CANDIDATES.map(function (d) { return d + '\\conventions.md' }), 'conventions')
  const pinnedKinds = Array.isArray(config.pinnedKinds) ? config.pinnedKinds : ['decision','fact','rule','correction']
  const pinnedLimit = Number(config.pinnedLimit || 6)
  // AUTO-RECALL 2026-10-23: 从副本里读"最近真正说过的话"，去记忆库做关键词检索，注入相关旧约定
  const autoRecall   = config.autoRecall === false ? false : true
  const recallTop    = Number(config.recallTop || 4)
  const maxChars = Number(config.maxChars || 16000) // 2026-10-24 r5: 默认=推荐值 16000（默认 12000 < 必需 13550 ⇒ 空配置即拒启）
  const conventionsMax = Number(config.conventionsMax || 8000) // 2026-10-24: 3000 太小会静默截断 §8+；提到 8000
  // 2026-10-25 state card: inject the most recently updated session state files
  const stateDir = String(config.stateDir || 'C:\\dsh-mem\\sessions')
  const stateMaxChars = Number(config.stateMaxChars || 2400)
  const stateCards = Number(config.stateCards || 3)
  // 2026-10-25 anchor pointers: inject the freshest exact anchors (session + seq) for lossless readback
  const anchorPath = String(config.anchorPath || 'C:\\dsh-mem\\anchors\\LATEST.md')
  const anchorMaxChars = Number(config.anchorMaxChars || 900)
  const conventionsDir = pickExisting(config.conventionsDir || 'C:\\dsh-mem\\conventions.d',
    PATH_CANDIDATES.map(function (d) { return d + '\\conventions.d' }), 'conventions.d') // 可选分片：按关键词命中才注入
  const injectLogPath = config.injectLogPath || 'C:\\dsh-mem\\logs\\inject.log'
  // 2026-10-24 C4：混合检索（本地嵌入 bge-m3 via 18 的 Ollama；失败自动退化为纯 IDF）
  const semanticOn    = config.semantic === false ? false : true
  const vectorPath    = config.vectorPath || 'C:\\dsh-mem\\mem-vectors.bin'
  const ollamaUrl     = config.ollamaUrl || 'http://127.0.0.1:11434'
  const embedModel    = config.embedModel || 'bge-m3'
  // 2026-10-25 r8（18 指出）：`injector=0.5.0` 从 r1 到 r7 一直没变 ⇒ **不携带"哪个 build"的信息**。
  //   改为 injector=0.5.0-<本文件 sha16 前 8 位>，自证 build；任何探针必须能区分相邻版本。
  const SELF_BUILD = (function () {
    try {
      const b = readFileSync(new URL(import.meta.url))
      return createHash('sha256').update(b).digest('hex').slice(0, 8).toUpperCase()
    } catch (e) { return 'UNKNOWN' }
  })()

  // 2026-10-25 r11：SELF_ID 必须是**模块级**绑定 —— r10 里它定义在 refresh() 内，
  //   导致另一处的诊断日志取不到（INJECT-SELFID-FAIL SELF_ID is not defined），而渲染却能取到。
  //   两条路径共用一个绑定，才不会"一处好一处坏"。
  const SELF_ID = (function () {
    try {
      let adminGroupOk = null
      try {
        const r2 = spawnSync('whoami', ['/groups', '/fo', 'csv', '/nh'], { encoding: 'utf8', timeout: 4000 })
        if (r2 && r2.stdout) adminGroupOk = /S-1-5-32-544/.test(r2.stdout)
      } catch (e) { }
      return {
        host: os.hostname(),
        os: os.type() + ' ' + os.release(),
        user: (function () { try { return os.userInfo().username } catch (e) { return '?' } })(),
        admin: adminGroupOk
      }
    } catch (e) { return null }
  })()
  const semLexWeight  = Number(config.semLexWeight || 0.55)
  const semVecWeight  = Number(config.semVecWeight || 0.45)
  const semMinFinal   = Number(config.semMinFinal || 0.32)
  const semBackoffMs  = Number(config.semanticBackoffMs || 600000) // 仅测试可用配置缩短（默认 10 分钟）

  // 2026-10-24 采纳 17/18 意见：maxChars 不能只 WARN —— 低于"保证下限"就拒启并把算式写进注入，
  //   因为 WARN 会被忽略，而截断是静默的（hints 就是这样丢的）。
  const FLOOR_SUM = 700 + 500 + 350 + 450 + 250 + 300 // shards/recall/pinned/recent/activity/hints 的下限之和
  const REQUIRED_MIN = Number(conventionsMax) + 3000 + FLOOR_SUM
  const CONFIG_PROBLEMS = []
  if (Number(maxChars) < REQUIRED_MIN) {
    CONFIG_PROBLEMS.push('maxChars=' + maxChars + ' < 保证下限 ' + REQUIRED_MIN +
      '（算式：conventionsMax ' + conventionsMax + ' + 3000 头部与余量 + 各段下限之和 ' + FLOOR_SUM + '）')
  }
  if (CONFIG_PROBLEMS.length) log('INJECT-CONFIG-FAIL ' + CONFIG_PROBLEMS.join(' ; '))
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
    const line = new Date().toISOString() + '  ' + msg + '\n'
    try { if (logPath) writeFileSync(logPath, line, { flag: 'a' }) } catch (e) { }
    // INJECT-* 另外写一份到 inject.log，便于审计注入了什么、是否被截断（2026-10-24）
    try { if ((msg.indexOf('INJECT-') === 0 || msg.indexOf('SEMANTIC-') === 0 || msg.indexOf('PATH-') === 0 || msg.indexOf('CONVENTIONS-') === 0) && injectLogPath) writeFileSync(injectLogPath, line, { flag: 'a' }) } catch (e) { }
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

      // 分片话题来源：最近对话（不是已注入内容，避免自己命中自己）2026-10-24
      const recentTopic = (Array.isArray(raw.messages) ? raw.messages : []).slice(0, 30)
        .map(function (m) { return String(m.text || '') }).join(' ').toLowerCase()
      if (CONFIG_PROBLEMS.length) {
        // 2026-10-24 r7（17 指出）：**拒启 = 会话里静默失忆**，比降级更危险。
        //   改成"降级注入 + 明文标注"：照最小可行预算注入约定与取法提示，并在注入内容里写明为什么降级。
        const warnLine = '**⚠ INJECT-CONFIG-FAIL（降级注入）**：' + CONFIG_PROBLEMS.join(' ; ') +
          ' ｜ 修复：cordis.patch.yml 里 maxChars 调到 ≥ ' + REQUIRED_MIN
        let degConv = ''
        try {
          if (conventionsPath && existsSync(conventionsPath)) {
            const b = readFileSync(conventionsPath)
            const sha16 = createHash('sha256').update(b).digest('hex').slice(0, 16).toUpperCase()
            degConv = b.toString('utf8').trim()
            const cap = Math.max(600, Math.floor(Number(maxChars) * 0.8))
            if (degConv.length > cap) degConv = degConv.slice(0, cap) + '\n…（降级注入：按 maxChars×0.8 截断）'
            degConv += '\n<!-- conventions@' + sha16 + ' size=' + b.length + 'B injector=0.5.0-' + SELF_BUILD + '-degraded -->'
            log('INJECT-TAIL-DEGRADED conventions@' + sha16 + ' size=' + b.length + 'B')
          }
        } catch (e) { }
        digest = '## ' + heading + '\n\n' + warnLine + '\n\n' +
          (degConv ? ('### 关键约定（降级注入，可能被截断）\n' + degConv + '\n\n') : '') +
          '取细节（本机命令）:\n' +
          '  powershell -ExecutionPolicy Bypass -File "' + cliPath + '" search <关键词>\n' +
          '  powershell -ExecutionPolicy Bypass -File "' + cliPath + '" recent -Limit 20\n'
        log('INJECT-DEGRADED maxChars=' + maxChars + ' required=' + REQUIRED_MIN)
        return
      }
      const mems = Array.isArray(raw.memories) ? raw.memories.slice() : []

      // ---- C4 混合检索：加载向量缓存 + 给当前话题算一个向量（同步 curl，失败即退化）----
      let vecMap = null
      const vecState = { ok: false, why: '', count: 0, dim: 0 }
      function loadVectors () {
        if (!semanticOn) { vecState.why = 'configured-off'; return null }
        try {
          if (!existsSync(vectorPath)) { vecState.why = 'no-vector-file'; return null }
          const buf = readFileSync(vectorPath)
          if (buf.length < 24 || buf.toString('ascii', 0, 8) !== 'DSHVEC01') { vecState.why = 'bad-magic'; return null }
          const dim = buf.readUInt32LE(8)
          const cnt = buf.readUInt32LE(12)
          const m = new Map()
          let off = 24
          for (let i = 0; i < cnt; i++) {
            const id = Number(buf.readBigInt64LE(off)); off += 8
            const f = new Float32Array(buf.buffer, buf.byteOffset + off, dim)
            off += dim * 4
            let n2 = 0
            for (let k = 0; k < dim; k++) n2 += f[k] * f[k]
            m.set(id, { v: f, n: Math.sqrt(n2) || 1 })
          }
          vecState.ok = true; vecState.count = cnt; vecState.dim = dim
          return m
        } catch (e) { vecState.why = 'load-fail:' + String(e && e.message || e); return null }
      }
      let semanticSkipUntil = 0
      function embedTopic (text) {
        if (!vecState.ok || !text) return null
        if (Date.now() < semanticSkipUntil) { vecState.why = 'backoff'; return null }
        try {
          const body = JSON.stringify({ model: embedModel, input: String(text).slice(0, 2000) })
          const t0 = Date.now()
          const res = spawnSync('curl.exe', ['-s', '--max-time', '12', '-X', 'POST', ollamaUrl + '/api/embed',
            '-H', 'Content-Type: application/json', '--data-binary', body], { encoding: 'utf8', timeout: 15000 })
          if (!res || res.status !== 0 || !res.stdout) {
            vecState.why = 'curl-fail'
            semanticSkipUntil = Date.now() + semBackoffMs
            log('SEMANTIC-BACKOFF ' + Math.round(semBackoffMs / 1000) + 's after curl-fail')
            return null
          }
          const j = JSON.parse(res.stdout)
          const arr = (j.embeddings && j.embeddings[0]) || null
          if (!arr || arr.length !== vecState.dim) {
            vecState.why = 'dim-mismatch'
            semanticSkipUntil = Date.now() + semBackoffMs
            log('SEMANTIC-BACKOFF ' + Math.round(semBackoffMs / 1000) + 's after dim-mismatch')
            return null
          }
          const f = new Float32Array(arr)
          let n2 = 0
          for (let k = 0; k < f.length; k++) n2 += f[k] * f[k]
          log('SEMANTIC-OK dim=' + vecState.dim + ' ms=' + (Date.now() - t0))
          return { v: f, n: Math.sqrt(n2) || 1 }
        } catch (e) { vecState.why = 'embed-fail:' + String(e && e.message || e); return null }
      }
      function cosine (a, b) {
        if (!a || !b || a.v.length !== b.v.length) return 0
        let dot = 0
        for (let k = 0; k < a.v.length; k++) dot += a.v[k] * b.v[k]
        return dot / (a.n * b.n)
      }
      vecMap = loadVectors()
      const topicVec = vecMap ? embedTopic(recentTopic) : null
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
      lines.push('> 并读 C:\\dsh-mem\\conventions.md（长期硬约定，全部有效）。查不到就问主人，不要猜。')
      lines.push('来源: 本机离线副本，刷新于 ' + (raw.generatedAt || '?') + '；库主机 ' + (raw.server || '?') + '；共 ' + mems.length + ' 条记忆')
      if (SELF_ID) {
        lines.push('本机身份（注入器实测，非记载值）: ' + SELF_ID.host + ' ｜ ' + SELF_ID.os + ' ｜ 登录用户 ' + SELF_ID.user +
          ' ｜ 管理员组(SID 544) ' + (SELF_ID.admin === null ? '未知' : (SELF_ID.admin ? '是' : '否')))
      }
      // 2026-10-24 B1/B2：分区渲染（每段独立预算 + 全局去重 + 显式省略清单）
      const SECTIONS = { recall: [], conv: [], shards: [], state: [], anchor: [], activity: [], hints: [], pinned: [], recent: [] }
      const SEC_BUDGET = { conv: 8000, shards: 2600, state: 2400, anchor: 900, recall: 1600, pinned: 1200, recent: 2000, activity: 700, hints: 400 }
      // 2026-10-24 修（17/18 复核 R3-⑤ 证实）：各段预算之和 16500 > maxChars 16000，
      //   尾部（hints=怎么查记忆）被全局截断吃掉，日志却还写着 hints=281（"有数字没送达"的假绿）。
      //   做法：conv 之外各段按 maxChars*0.95 - conventionsMax 等比缩放，并给每段设下限。
      const BUDGET_FLOOR = { shards: 700, state: 1200, anchor: 350, recall: 500, pinned: 350, recent: 450, activity: 250, hints: 300 }
      const scaledSections = ['shards', 'state', 'anchor', 'recall', 'pinned', 'recent', 'activity', 'hints']
      const otherSum = scaledSections.reduce(function (a, k) { return a + SEC_BUDGET[k] }, 0)
      const targetOther = Math.max(3000, Math.round(maxChars * 0.95) - conventionsMax)
      const budgetScale = Math.min(1, targetOther / otherSum)
      const EFF_BUDGET = { conv: conventionsMax }
      for (const k of scaledSections) {
        EFF_BUDGET[k] = Math.max(BUDGET_FLOOR[k], Math.round(SEC_BUDGET[k] * budgetScale))
      }

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
            // 2026-10-24 B3：滤掉寒暄/系统回执类短句，避免"我回来拉""好的"当话题源
            .filter(function (m) {
              const t = String(m.text || '').trim()
              if (t.length < 10) return false
              if (/^(好的|好|嗯|收到|知道了|谢谢|继续|可以|行|ok|OK)[，,。.!！\s]*$/.test(t)) return false
              return true
            })
            .sort(function (a, b) { return (Number(b.id) || 0) - (Number(a.id) || 0) })
            .slice(0, 3)
          rawUsers.forEach(function (m) { addKws(m.text) })
          const kwList = Array.from(kws)
          if (kwList.length) {
            const pool = mems.filter(function (m) {
              if (String(m.kind || '') === 'checkpoint' || String(m.kind || '') === 'evidence' || String(m.kind || '') === 'llm-call') return false
              if (String(m.status || 'current') === 'retired' || String(m.status || 'current') === 'archived') return false
              if (String(m.body || '').length > 200000) return false // 2026-10-24: 原来 >6000 直接跳过=静默丢失；只挡 20 万字符以上的极端情况
              return true
            })
            const hays = []
            for (const m of pool) hays.push((String(m.title || '') + ' ' + String(m.body || '').slice(0, 8000) + ' ' + String(m.tags || '')).toLowerCase())
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
              const lexScore = w / Math.sqrt(len / 500)
              const lexPass = lexScore >= 1.2 && (cjkHits >= 2 || hasNum)
              // 2026-10-24 C4：有向量时用"关键词 + 语义"混合分；纯语义命中（无词命中）也允许入选
              let vecCos = 0
              let finalScore = lexScore
              if (topicVec && vecMap && vecMap.get(m.id)) {
                vecCos = cosine(topicVec, vecMap.get(m.id))
                const lexNorm = Math.min(1, lexScore / 3.0)
                finalScore = (semLexWeight * lexNorm) + (semVecWeight * Math.max(0, vecCos))
              }
              const pass = topicVec ? (lexPass || finalScore >= semMinFinal) : lexPass
              if (!pass) continue
              if (!topicVec) { if (cjkHits < 2 && !hasNum) continue }
              scored.push({
                id: m.id, kind: String(m.kind || ''), title: m.title,
                score: topicVec ? finalScore : lexScore,
                lex: lexScore, cos: vecCos,
                hits: Array.from(hitSet).slice(0, 8),
                long: String(m.body || '').length > 6000
              })
            }
            scored.sort(function (a, b) { return b.score - a.score })
            const top = scored.slice(0, recallTop)
            if (top.length) {
              SECTIONS.recall.push('')
              SECTIONS.recall.push('### 与当前话题相关的记忆（自动检索 v3/IDF，可能不全；要全量请用 search）')
              for (const t of top) {
                const vecNote = (t.cos && t.cos > 0) ? ('  ‹语义 ' + t.cos.toFixed(2) + '›') : ''
                const why = t.hits.length ? ('命中: ' + t.hits.join('/')) : '语义'
                SECTIONS.recall.push('- [' + t.id + '] (' + t.kind + ') ' + String(t.title || '').replace(/\s+/g, ' ').trim() + '  ‹' + why + '›' + vecNote + (t.long ? '  ‹长文·需 search 看全文›' : ''))
              }
            }
          }
        } catch (e) { }
      }

      // ---- 关键约定：每次完整注入（不看新旧）----
      try {
        if (conventionsPath && existsSync(conventionsPath)) {
          // 2026-10-24 r5：采纳 18 的运行时版本尾巴——从注入内容本身就能报出跑的是哪一版
        const convBuf = readFileSync(conventionsPath)
        const convSha16 = createHash('sha256').update(convBuf).digest('hex').slice(0, 16).toUpperCase()
        const convSize = convBuf.length
        let conv = convBuf.toString('utf8')
      if (conv.length > conventionsMax) {
        const head = conv.slice(0, conventionsMax)
        const rest = conv.slice(conventionsMax)
        const dropped = (rest.match(/^##\s.+$/gm) || []).map(function (s) { return s.trim() })
        conv = head + '\n\n…（关键约定超出上限 ' + conventionsMax + ' 字符，已截断）\n' +
          (dropped.length ? '**未注入的章节**（完整内容见 ' + conventionsPath + '）：\n' + dropped.map(function (h) { return '- ' + h }).join('\n') : '（被截断部分无二级标题）')
        log('INJECT-TRUNC kept=' + (head.match(/^##\s.+$/gm) || []).length + ' dropped=' + dropped.length + ' max=' + conventionsMax)
      }
          if (conv.charCodeAt(0) === 0xFEFF) conv = conv.slice(1)
          conv = conv.trim()
          // 2026-10-24 采纳 18 的复核意见：指针必须自证——别让注入指向不存在的文件
          //   （"文档说有、机器上没有" = 清单有说的第四种形态）
          try {
            const detailRel = 'docs\\约定详情-完整版.md'
            const detailAbs = join(dirname(conventionsPath), detailRel)
            if (conv.indexOf(detailRel) >= 0 && !existsSync(detailAbs)) {
              conv = conv.split(detailRel).join('（详情文件未部署，本机仅有精简版）')
              log('CONVENTIONS-POINTER-MISSING ' + detailAbs)
            }
          } catch (e) { }
          // 2026-10-25 r7：共享文档里若仍残留"本机 = <固定机器名>"这类写死身份，告警（防以后又被写死一次）
          try {
            // 只认"以 本机 = 开头的声明行"；出现在括号里的历史反例（如"实际发生过"）不算
            const declLines = conv.split(/\r?\n/).filter(function (ln) { return /^\s*本机\s*=\s*\S/.test(ln) })
            // 2026-10-25 r9：排除规则必须**结构性**（用词排除可被词绕过）
            //   历史引用形如 "  （2026-10-24 实际发生过：…）"：首个非空白字符是 （ 或 > 或 #
            const realDecls = declLines.filter(function (ln) {
              const t2 = ln.replace(/^\s+/, '')
              return !/^[（(>#]/.test(t2)
            })
            if (realDecls.length) log('CONVENTIONS-IDENTITY-CONFLICT 共享文档仍含写死身份声明 ' + realDecls.length + ' 行（应由注入器实测替代）')
          } catch (e) { }
          if (conv) {
            SECTIONS.conv.push('')
            SECTIONS.conv.push('### 关键约定（完整，勿违背）')
            SECTIONS.conv.push(conv)
            // 版本尾巴：不回写文件，只在注入末尾追加一行；机器可 grep：conventions@
            // 2026-10-24 r6（18 指出）：注入内容必须幂等 —— 尾巴不带时间戳，时间只进 inject.log
            SECTIONS.conv.push('<!-- conventions@' + convSha16 + ' size=' + convSize + 'B injector=0.5.0-' + SELF_BUILD + ' -->')
            log('INJECT-TAIL conventions@' + convSha16 + ' size=' + convSize + 'B at=' + new Date().toISOString())
          }
          // ---- 关键约定分片：只注入命中当前话题关键词的分片，其余仅列名字（2026-10-24）----
          try {
            if (conventionsDir && existsSync(conventionsDir)) {
              const shardNames = readdirSync(conventionsDir).filter(function (n) { return /\.md$/i.test(n) })
              if (shardNames.length) {
                const topic = recentTopic
                const injected = []
                const skipped = []
                // 2026-10-24 B5：按命中关键词数量排序，最多注入 3 片（避免"全都沾边就全塞进来"）
                const SHARD_CAP = Number(config.shardCap || 3)
                const scoredShards = []
                for (const nm of shardNames) {
                  let body = ""
                  try { body = readFileSync(join(conventionsDir, nm), "utf8") } catch (e) { continue }
                  if (body.charCodeAt(0) === 0xFEFF) body = body.slice(1)
                  const keys = (body.split(/\r?\n/)[0].match(/\[[^\]]+\]/g) || []).map(function (s) { return s.replace(/[\[\]]/g, "") }).join(",").split(/[,，\s]+/).map(function (s) { return s.trim().toLowerCase() }).filter(function (s) { return s.length >= 2 })
                  const hits = keys.filter(function (k) { return topic.indexOf(k) >= 0 })
                  if (hits.length) scoredShards.push({ name: nm, body: body.trim(), hits: hits.length, keys: hits })
                }
                scoredShards.sort(function (a, b) { return b.hits - a.hits })
                const chosen = scoredShards.slice(0, SHARD_CAP)
                const notChosen = scoredShards.slice(SHARD_CAP).map(function (x) { return x.name })
                for (const sd of chosen) injected.push({ name: sd.name, body: sd.body, hits: sd.keys })
                const injectedNames = chosen.map(function (x) { return x.name })
                for (const nm of shardNames) { if (injectedNames.indexOf(nm) < 0 && notChosen.indexOf(nm) < 0) skipped.push(nm) }
                if (injected.length) {
                  SECTIONS.shards.push("")
                  SECTIONS.shards.push("### 关键约定·分片（按话题命中注入，最多 " + SHARD_CAP + " 片）")
                  for (const sd of injected) { SECTIONS.shards.push(""); SECTIONS.shards.push(sd.body) }
                }
                const rest = skipped.concat(notChosen)
                if (rest.length) { SECTIONS.shards.push(""); SECTIONS.shards.push("可用约定分片（未命中或超出上限，未注入；需要时读 " + conventionsDir + "）：" + rest.join("、")) }
                log("INJECT-SHARDS injected=" + injected.length + " skipped=" + skipped.length)
              }
            }
          } catch (e) { log("INJECT-SHARDS-FAIL " + String(e && e.message || e)) }
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
          SECTIONS.activity.push('')
          SECTIONS.activity.push('### 各机最近活动（同一份离线副本，时间 UTC）')
          for (const r of rows.slice(0, activityMax)) {
            const title = String((r.s && r.s.title) || '').trim() || '(未命名会话)'
            const ev = Number((r.s && r.s.event_count) || 0)
            SECTIONS.activity.push('- ' + (r.s.machine || '?') + ' · 「' + title + '」 · ' + hhmmUTC(r.t) + '（' + agoText(r.t, now) + '，' + ev + ' 事件）')
          }
        }
      }

      SECTIONS.hints.push('')
      SECTIONS.hints.push('取细节（本机命令，勿凭印象回答历史问题）:')
      SECTIONS.hints.push('  powershell -ExecutionPolicy Bypass -File "' + cliPath + '" search <关键词>')
      SECTIONS.hints.push('  powershell -ExecutionPolicy Bypass -File "' + cliPath + '" recent -Limit 20')
      SECTIONS.hints.push('  powershell -ExecutionPolicy Bypass -File "' + cliPath + '" handoff    # 接力另一台机器的会话')

      // ---- STATE CARD (2026-10-25): recent per-session working state ----
      try {
        if (stateDir && existsSync(stateDir)) {
          const cards = []
          for (const d of readdirSync(stateDir)) {
            try {
              const p = join(stateDir, d, 'state.md')
              if (existsSync(p)) { const st = statSync(p); cards.push({ d, p, m: st.mtimeMs }) }
            } catch (e) { }
          }
          cards.sort(function (a, b) { return b.m - a.m })
          const pick = cards.slice(0, Math.max(1, stateCards))
          if (pick.length) {
            SECTIONS.state.push('')
            SECTIONS.state.push('### 会话状态卡（每轮注入；按标题认领你自己的那张）')
            for (const c of pick) {
              try {
                let body = readFileSync(c.p, 'utf8')
                if (body.charCodeAt(0) === 0xFEFF) body = body.slice(1)
                body = body.replace(/\r?\n/g, ' ').replace(/\s+/g, ' ').trim()
                if (body.length > 800) body = body.slice(0, 800) + '…'
                const tm = body.match(/- title: ([^\-]*?)(?: -|$)/)
                const title = tm && tm[1] ? tm[1].trim() : c.d.slice(0, 40)
                const upd = new Date(c.m).toISOString().slice(0, 19) + 'Z'
                SECTIONS.state.push('- 【' + title + '】 ' + c.d + ' · updated ' + upd)
                SECTIONS.state.push('  ' + body)
              } catch (e) { }
            }
          }
        }
      } catch (e) { }
      // ---- ANCHOR POINTERS (2026-10-25): exact anchors with session + seq, for mem-read readback ----
      try {
        if (anchorPath && existsSync(anchorPath)) {
          let at = readFileSync(anchorPath, 'utf8')
          if (at.charCodeAt(0) === 0xFEFF) at = at.slice(1)
          at = at.trim()
          if (at.length > anchorMaxChars) at = at.slice(0, anchorMaxChars) + '…'
          const alines = at.split(/\r?\n/).filter(function (ln) { return ln.indexOf('- ') === 0 })
          if (alines.length) {
            SECTIONS.anchor.push('')
            SECTIONS.anchor.push('### 最近锚点（原文指针 session·seq；用 mem-read 回读原文）')
            for (const ln of alines) SECTIONS.anchor.push(ln)
          }
        }
      } catch (e) { }
      SECTIONS.pinned.push('')
      SECTIONS.pinned.push('### 定义型记忆（决策/事实/规则/更正，不按新旧筛）')
      try {
        const injectable = function (m) {
          const k = String(m.kind || '')
          const st = String(m.status || 'current')
          if (k === 'checkpoint' || k === 'evidence' || k === 'llm-call') return false
          if (st === 'retired' || st === 'archived') return false
          return true
        }
        const pinned = mems.filter(function (m) { return pinnedKinds.indexOf(String(m.kind || '')) >= 0 && injectable(m) }).slice(0, pinnedLimit)
        for (const m of pinned) {
          let body = String(m.body || '').replace(/\s+/g, ' ').trim()
          if (body.length > 160) body = body.slice(0, 160) + ' …'
          SECTIONS.pinned.push('- [' + m.id + '] (' + (m.kind || '?') + ') ' + (m.title || '') + (body ? ' — ' + body : ''))
        }
      } catch (e) { }

      SECTIONS.recent.push('')
      SECTIONS.recent.push('### 最近结论（新 → 旧）')
      // 2026-10-24 C3：最近结论同样跳过 evidence/checkpoint；status 非 current 的加标注，便于"别引用旧结论"
      const recentList = mems.filter(function (m) {
        const k = String(m.kind || '')
        const st = String(m.status || 'current')
        if (k === 'checkpoint' || k === 'evidence' || k === 'llm-call') return false
        if (st === 'retired' || st === 'archived') return false
        return true
      }).slice(0, limit)
      for (const m of recentList) {
        let body = String(m.body || '').replace(/\s+/g, ' ').trim()
        if (body.length > 200) body = body.slice(0, 200) + ' …'
        const st = String(m.status || 'current')
        const mark = st !== 'current' ? ('  ‹状态: ' + st + (m.replaced_by ? '，已被 [' + m.replaced_by + '] 取代' : '') + '›') : ''
        SECTIONS.recent.push('- [' + m.id + '] (' + (m.kind || '?') + ') ' + (m.title || '') + (body ? ' — ' + body : '') + mark)
      }

      // ---- B1/B2：按预算装配 + 全局去重（同一 id 只出现一次）+ 显式省略清单 ----
      const seenIds = new Set()
      const dupIds = []
      const budgetLog = {}
      const assemble = function (name, arr, mandatory) {
        if (!arr.length) return []
        const budget = EFF_BUDGET[name] || SEC_BUDGET[name] || 2000
        const out = []
        let used = 0
        let omitted = 0
        for (const ln of arr) {
          const mm = /^- \[(\d+)\]/.exec(ln)
          if (mm) {
            const id = mm[1]
            if (seenIds.has(id)) { dupIds.push(id); continue }
            seenIds.add(id)
          }
          if (!mandatory && used + ln.length + 1 > budget) { omitted++; continue }
          out.push(ln); used += ln.length + 1
        }
        if (omitted > 0) {
          out.push('…（本段超出预算，省略 ' + omitted + ' 条；用 dsh-mem.ps1 search / recent 取更多）')
        }
        budgetLog[name] = used
        if (omitted) budgetLog[name + '_dropped'] = omitted
        return out
      }
      const tail = []
      for (const name of ['recall', 'conv', 'shards', 'state', 'anchor', 'pinned', 'recent', 'activity', 'hints']) {
        const arr = assemble(name, SECTIONS[name], name === 'conv')
        if (arr.length) { tail.push(''); tail.push.apply(tail, arr) }
      }
      const head = lines.join('\n')
      let text = head + (tail.length ? '\n' + tail.join('\n') : '')
      // 总上限：按"先砍最不重要的段"的顺序减，**绝不先砍 hints（怎么查记忆）**
      if (text.length > maxChars) {
        const before = text.length
        let dropped = 0
        for (const secName of ['recent', 'activity', 'pinned', 'shards', 'state', 'anchor', 'recall']) {
          while (text.length > maxChars && SECTIONS[secName] && SECTIONS[secName].length > 2) {
            SECTIONS[secName].pop(); dropped++
            const rebuild = []
            for (const nm of ['recall', 'conv', 'shards', 'state', 'anchor', 'pinned', 'recent', 'activity', 'hints']) {
              const arr = assemble(nm, SECTIONS[nm], nm === 'conv')
              if (arr.length) { rebuild.push(''); rebuild.push.apply(rebuild, arr) }
            }
            text = head + (rebuild.length ? '\n' + rebuild.join('\n') : '')
          }
          if (text.length <= maxChars) break
        }
        if (text.length > maxChars) {
          text = text.slice(0, maxChars) + '\n…（仍超出 ' + maxChars + ' 字符，尾部截断；用 search/recent 取全量）'
        }
        log('INJECT-TOTAL-TRIM from=' + before + ' to=' + text.length + ' lines_dropped=' + dropped + ' max=' + maxChars)
      }
      if (dupIds.length) budgetLog.dup = dupIds.length
      // 2026-10-25 r7（17/18 论证后定稿）：尾巴能不能活下来是"涌现属性"（位置+数字），不建在位置学上；
      //   装配完成后做一次正向断言，把"尾巴被弄丢"变成可见事件 INJECT-TAIL-LOST。
      if (text.indexOf('<!-- conventions@') < 0) {
        log('INJECT-TAIL-LOST maxChars=' + maxChars + ' convLen=' + (SECTIONS.conv.join('\n').length) + ' total=' + text.length)
      }
      budgetLog.semantic = vecState.ok ? ('on/' + vecState.count + 'x' + vecState.dim) : ('off:' + (vecState.why || 'unknown'))
      budgetLog.budgetScale = Number(budgetScale.toFixed(3))
      budgetLog.eff = (EFF_BUDGET.hints || 0) + '/' + (EFF_BUDGET.recent || 0) + '/' + (EFF_BUDGET.activity || 0)
      log('INJECT-BUDGET ' + JSON.stringify(budgetLog))
      digest = text
    } catch (e) {
      // 2026-10-24: 解析/读取失败必须“可见”，不能把整段记忆静默清空
      const msg = String((e && e.message) || e)
      log('INJECT-FAIL ' + msg)
      digest = '## ' + heading + '\n\n**警告：共享记忆注入失败**\n\n' +
        '- 原因：`' + msg + '`\n' +
        '- 副本：`' + replicaPath + '`\n' +
        '- 处理：检查 DshMemoryAgent 服务与副本文件；本次会话**没有**共享长期记忆可用。'
    }
  }

  refresh()
  const timer = setInterval(refresh, refreshMs)
  if (typeof timer.unref === 'function') timer.unref()

  // 2026-10-24 采纳 18 的建议：记录"选中哪个 + 跳过了哪些 + 内容校验"，而不只是"存在"
  try {
    const detailCheck = (function () {
      try {
        const d = join(dirname(conventionsPath), 'docs\\约定详情-完整版.md')
        return existsSync(d) ? describeFile(d) : 'missing'
      } catch (e) { return 'err' }
    })()
    // 2026-10-25 r7（18 指出）：**哪个配置生效只能用运行时自报证明**，不能用文件内容推断
  // 2026-10-25 r9：两条诊断日志各自独立 try —— 之前共用一个 try，一条抛错另一条也静默消失（无法定位）
  try {
    log('INJECT-SELFID ' + (SELF_ID ? (String(SELF_ID.host) + ' | ' + String(SELF_ID.os) + ' | ' + String(SELF_ID.user) + ' | admin=' + String(SELF_ID.admin)) : 'NULL') + ' build=' + String(SELF_BUILD))
  } catch (e) { log('INJECT-SELFID-FAIL ' + String((e && e.message) || e)) }
  try {
    log('INJECT-EFFCONFIG ' + JSON.stringify({ maxChars: Number(maxChars), conventionsMax: Number(conventionsMax), requiredMin: REQUIRED_MIN, shardCap: Number(config.shardCap || 3), semantic: (config.semantic === false ? false : true), maxCharsSource: (config.maxChars ? 'config' : 'code-default') }))
  } catch (e) { log('INJECT-EFFCONFIG-FAIL ' + String((e && e.message) || e)) }
  log('PATH-RESOLVED ' + JSON.stringify({
      replica: { chosen: replicaPath, size: describeFile(replicaPath) },
      cli: { chosen: cliPath, size: describeFile(cliPath) },
      conventions: { chosen: conventionsPath, size: describeFile(conventionsPath) },
      conventionsDir: { chosen: conventionsDir, size: describeFile(conventionsDir) },
      detailDoc: detailCheck,
      trace: pathTrace
    }))
  } catch (e) { log('PATH-RESOLVED-FAIL ' + String(e && e.message || e)) }
  ctx.systemPrompt.context({ name: 'shared-memory', order: 900, text: function () { return digest } })

  // ---------------- 2) capture ----------------

  function saveMemory(kind, title, body, session) {
    try {
      // 2026-10-25 FIX: 显式配置的 cliPath 若不存在，禁止回退到别的安装路径。
      //   旧行为: pickExisting() 在"配置了但不存在"时会回退到候选里真实存在的 dsh-mem.ps1，
      //   结果 verify.mjs 用假路径跑自测时，数据被写进了真实记忆库（已产生 18 条假 llm-call）。
      if (config.cliPath && !existsSync(String(config.cliPath))) {
        log('CLI-MISSING ' + String(config.cliPath) + ' — 显式配置的 CLI 不存在，拒绝回退/执行')
        return
      }
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
      // ★ 机器名可能是中文（例如以中文命名的 Windows 主机）。
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
          // 2026-10-24 C3：压缩摘要只作为"证据"落库，不参与注入；由后续 curator 决定是否蒸馏成记忆
        saveMemory((config.captureKind || 'evidence'), title, clipped, session)
        } catch (err) {
          log('session/event handler failed: ' + (err && err.message))
        }
      })
      log('auto-capture armed')
    } catch (err) {
      log('failed to arm auto-capture: ' + (err && err.message))
    }
  }

  // ---------------- 2b) REAL-TIME SPOOL (2026-10-25, plan B) ----------------
  // WHY: the file-based `dsh-mem.ps1 sync` costs ~30 s per run no matter how few turns are new
  // (it decompresses the whole session file), so it cannot deliver "each turn lands within seconds".
  // Here the plugin writes every message event to a local JSONL spool with ZERO child processes
  // (appendFileSync only). `ops\spool-import.ps1` then imports only the new lines every ~8 s.
  // Rules honoured: no DB write from the plugin (a hanging DB must never block a turn), the spool
  // is the only side effect, and every 200th line is logged so "armed but silent" is detectable.
  if (config.spoolCapture !== false) {
    try {
      const spoolPath = String(config.spoolPath || 'C:\\dsh-mem\\spool\\hot.jsonl')
      const spoolMaxBytes = Number(config.spoolMaxBytes || 33554432)
      const spoolTextMax = Number(config.spoolTextMax || 100000)
      try { mkdirSync(dirname(spoolPath), { recursive: true }) } catch (e) { /* already exists */ }
      let spoolCount = 0
      ctx.on('session/event', function (session, event) {
        try {
          if (!event || typeof event.type !== 'string') return
          const sid = String((session && session.id) || '?')
          const seq = Number(event.seq || 0)
          const text = firstText(event.data)
          if (!text) return
          const clipped = text.length > spoolTextMax ? text.slice(0, spoolTextMax) + '\n…[spool-trunc]' : text
          const rec = { ts: new Date().toISOString(), session: sid, seq: seq, type: event.type, text: clipped }
          let st = null
          try { st = statSync(spoolPath) } catch (e) { st = null }
          if (st && st.size > spoolMaxBytes) {
            try { renameSync(spoolPath, spoolPath + '.1') } catch (e) { /* next append recreates */ }
          }
          appendFileSync(spoolPath, JSON.stringify(rec) + '\n', 'utf8')
          spoolCount++
          if (spoolCount === 1 || spoolCount % 200 === 0) {
            log('SPOOL n=' + spoolCount + ' last=' + event.type + ' seq=' + seq + ' bytes=' + Buffer.byteLength(rec.text))
          }
        } catch (err) {
          log('spool handler failed: ' + (err && err.message))
        }
      })
      log('spool capture armed path=' + spoolPath + ' textMax=' + spoolTextMax + ' rotateAt=' + spoolMaxBytes)
    } catch (err) {
      log('failed to arm spool capture: ' + (err && err.message))
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
          '模型     : ' + q.model + '  @ <ollama-host>（GPU, Ollama）',
          '会话     : ' + sid,
          '调用次数 : ' + q.count,
          '耗时合计 : ' + (q.ms / 1000).toFixed(1) + ' 秒',
          'tokens   : 输入 ' + q.inTok + ' / 输出 ' + q.outTok,
          '用途     : ' + (q.purposes.size ? Array.from(q.purposes).join(', ') : '(普通对话)'),
          '',
          '说明: 本地模型跑在局域网 GPU 上，不消耗云端额度；',
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
