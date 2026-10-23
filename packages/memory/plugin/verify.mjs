// verify.mjs —— 假 ctx 验证 dsh-memory-bridge，不需要重启 DSH，也【不会写数据库】。
//
// 为什么必须有这个文件: 我们踩过四次坑，全都是"装了但没生效"这类静默失败 ——
//   ① "let text 重复声明" 让整个模块无法加载
//   ② UTF-8 BOM 让 JSON.parse 失败（PowerShell 5.1 写文件会带 BOM）
//   ③ 找不到离线副本时，旧版只静默注入空内容
//   ④ v0.3.0 加"各机最近活动"时，replica 里的时间是旧式 /Date(ms)/，
//      PowerShell 的 ConvertFrom-Json 会按本地时区再偏一次（实测偏 8 小时）——
//      所以这里【用原始毫秒独立算一遍期望值】，专门抓这类时区偏移。
//
// 用法: node verify.mjs        退出码 0=通过 1=没注册context 2=注入为空 3=捕获没挂上 4=捕获没触发 5=活动段异常
//
// v0.4.0 新增断言:
//   D. 必须挂上 llm/stream 记账钩子，且假流 3 个 chunk 必须【原样直通】
//   E. 喂一个 provider=ollama-local 的假调用后，日志必须出现 capture llm-call
//      ★ 记账断言必须跑在 disposer() 之前 —— 否则定时器被清掉，会误判成功能坏了
//
// v0.3.0 新增断言:
//   A. 注入内容必须含「各机最近活动」段
//   B. 活动段每行必须是  HH:MM UTC（无 NaN/Invalid）
//   C. ★ 最新一行的 HH:MM 必须等于"用 /Date(毫秒) 独立算出的 UTC 时分"
//      —— 这条能直接抓住时区偏移（正是我踩的那个坑）

import { existsSync, readFileSync, writeFileSync, rmSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { tmpdir } from 'node:os'

const here = dirname(fileURLToPath(import.meta.url))

// 各机安装位置可能不同，逐个探测，
// 免得"配置路径不对"被误报成"插件坏了"。
const candidates = [
  process.env.DSH_MEM_REPLICA,
  'C:\\dsh-mem\\dsh-mem-replica.json',
  process.env.DSH_MEM_HOME ? join(process.env.DSH_MEM_HOME, 'dsh-mem-replica.json') : null,
  join(here, 'dsh-mem-replica.json'),
].filter(Boolean)
const replicaPath = candidates.find((p) => { try { return existsSync(p) } catch (e) { return false } })

console.log('候选副本路径:')
for (const c of candidates) console.log('  ' + (existsSync(c) ? '[有] ' : '[无] ') + c)
if (!replicaPath) {
  console.error('FAIL: 找不到 dsh-mem-replica.json —— 先确认 DshMemoryAgent 服务在跑、config 路径正确')
  process.exit(2)
}
console.log('使用: ' + replicaPath)

const mod = await import(new URL('./index.mjs', import.meta.url).href)
console.log('VERSION     = ' + (mod.VERSION || '(未标注)'))

let contextEntry = null
let eventHandler = null
let llmHandler = null
const fakeCtx = {
  systemPrompt: { context(c) { contextEntry = c; return () => {} } },
  on(name, handler) { if (name === 'session/event') eventHandler = handler;
                      if (name === 'llm/stream') llmHandler = handler; return () => {} },
}

// ★ 关键: cliPath 指向一个不存在的路径 ⇒ 捕获流程会被触发，但【写不进数据库】
const probeLog = join(tmpdir(), 'dsh-memory-bridge-verify.log')
try { rmSync(probeLog, { force: true }) } catch (e) { }
const disposer = mod.apply(fakeCtx, {
  replicaPath,
  cliPath: 'C:\\__verify_no_such_dir__\\dsh-mem.ps1',
  logPath: probeLog,
  localProviders: ['ollama-local'],
  callLogFlushMs: 150,
})

console.log('name        = ' + mod.name)
console.log('inject      = ' + JSON.stringify(mod.inject))
if (!contextEntry) { console.error('FAIL: 没有注册 prompt context'); process.exit(1) }

const text = contextEntry.text()
console.log('context     = name=' + contextEntry.name + ' order=' + contextEntry.order)
console.log('digest      = ' + text.length + ' chars, 同步且稳定=' + (text === contextEntry.text()))
console.log('--- 注入内容前 6 行 ---')
for (const l of text.split('\n').slice(0, 6)) console.log('  ' + l)
if (text.length === 0) { console.error('FAIL: 注入内容为空'); process.exit(2) }

// ---------------- v0.3.0: 活动段断言 ----------------
let activityOK = false
const lines = text.split('\n')
const actIdx = lines.findIndex((l) => l.indexOf('各机最近活动') >= 0)
if (actIdx < 0) {
  console.error('FAIL(5): 注入内容里没有「各机最近活动」段 —— v0.3.0 应当包含')
  process.exit(5)
}
{
  // 只取"各机最近活动"到下一个 ### 标题之间的行 —— 记忆列表也用 "- " 开头，
  // 不设边界会把记忆行误判成畸形活动行（我们刚踩过）。
  const rows = []
  for (let i = actIdx + 1; i < lines.length; i++) {
    const l = lines[i]
    if (/^###/.test(l) || l.indexOf('取细节') === 0) break
    if (l.trim().startsWith('- ')) rows.push(l)
  }
  console.log('activity    = 活动段存在，机器行数 = ' + rows.length)
  for (const r of rows) console.log('  > ' + r)

  const bad = rows.filter((r) => !/\d{2}:\d{2} UTC/.test(r) || /NaN|Invalid|undefined|null/.test(r))
  if (rows.length === 0) { console.error('FAIL(5): 活动段没有任何机器行'); process.exit(5) }
  if (bad.length > 0) {
    console.error('FAIL(5): 活动段有畸形行（时间没解析出来？检查 /Date(ms)/ 的处理）')
    for (const b of bad) console.error('   ' + b)
    process.exit(5)
  }

  // ★ C. 时区断言。replica 的旧式 /Date(ms)/ 本身带一个"本地时区偏移"（见 index.mjs
  //      里的算术说明），所以这里算出【未补偿】和【补偿后】两个候选，然后断言活动段
  //      用的是"补偿后"的那个。若两个候选相同（UTC 机器）则本断言自动退化为格式检查。
  let raw = readFileSync(replicaPath, 'utf8')
  if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1)
  const parsed = JSON.parse(raw)
  const stamps = []
  for (const s of (Array.isArray(parsed.sessions) ? parsed.sessions : [])) {
    const v = s && s.last_seen_at
    const m = typeof v === 'string' ? /\/Date\((-?\d+)/.exec(v) : null
    const ms = m ? Number(m[1]) : (typeof v === 'number' ? v : Date.parse(String(v)))
    if (!isNaN(ms)) stamps.push({ machine: String(s.machine || '?'), ms: ms, legacy: !!m })
  }
  stamps.sort((a, b) => b.ms - a.ms)
  if (stamps.length) {
    const pad = (n) => (n < 10 ? '0' : '') + n
    const hhmm = (d) => pad(d.getUTCHours()) + ':' + pad(d.getUTCMinutes()) + ' UTC'
    // ★ 补偿【只对旧式 /Date(ms)/ 形式】。CLI 修好之后 replica 输出的是 ISO-8601，
    //   那种形式本来就不偏，再补偿一次反而会错 8 小时 —— 这里必须跟着数据格式走。
    const legacy = stamps[0].legacy
    const dRaw = new Date(stamps[0].ms)
    const dFix = legacy ? new Date(stamps[0].ms - dRaw.getTimezoneOffset() * 60000) : dRaw
    const wrong = legacy ? hhmm(dRaw) : null
    const expect = hhmm(dFix)
    console.log('stampForm   = ' + (legacy ? '旧式 /Date(ms)/ ⇒ 需要时区补偿' : 'ISO-8601 ⇒ 不需要补偿（CLI 已修）'))
    console.log('expectUTC   = 应出现 ' + expect + '   (' + stamps[0].machine + ')' + (wrong ? '   错的候选 ' + wrong : ''))
    if (text.indexOf(expect) < 0) {
      console.error('FAIL(5): 活动段里没有出现应有的时间 ' + expect)
      process.exit(5)
    }
    if (wrong && wrong !== expect && text.indexOf(wrong) >= 0) {
      console.error('FAIL(5): 活动段里出现了不该有的时间 ' + wrong + ' —— 补偿被多应用了一次')
      process.exit(5)
    }
    // 语义边界: 最新会话的补偿后时间应与 generatedAt 同量级（24 小时内）
    const g = Date.parse(String(parsed.generatedAt || ''))
    if (!isNaN(g)) {
      const gapH = Math.abs(g - dFix.getTime()) / 3600000
      console.log('gapVsGen    = ' + gapH.toFixed(2) + ' 小时  (应远小于 24)')
      if (gapH > 24) { console.error('FAIL(5): 活动段最新时间与 generatedAt 差 ' + gapH.toFixed(1) + ' 小时，太大'); process.exit(5) }
    }
    console.log('             ✅ 时区补偿正确')
  }
  activityOK = true
}

if (typeof eventHandler !== 'function') {
  console.log('eventHandler= 未挂上（旧版插件没有自动捕获；若你的版本应含此功能请检查）')
  console.log('RESULT: PASS (注入部分)')
  process.exit(0)
}

// 喂三条: 1 条压缩摘要(该捕获) + 1 条普通消息(不该) + 1 条重复(该去重)
const s = { id: 'session-00000000-dead-beef-0000-000000000000' }
const ckpt = 'This is an automatically generated checkpoint condensing an earlier span of the conversation. ' + 'x'.repeat(200)
eventHandler(s, { type: 'user/message', seq: 4242, time: Date.now(), data: { role: 'user', content: [{ type: 'text', text: ckpt }] } })
eventHandler(s, { type: 'user/message', seq: 4243, time: Date.now(), data: { role: 'user', content: [{ type: 'text', text: '普通用户消息，不该被当成压缩摘要捕获。' }] } })
eventHandler(s, { type: 'user/message', seq: 4242, time: Date.now(), data: { role: 'user', content: [{ type: 'text', text: ckpt }] } })

// 等子进程报错退出并写日志
await new Promise((r) => setTimeout(r, 2500))

let logText = ''
try { logText = readFileSync(probeLog, 'utf8') } catch (e) { }
const captures = (logText.match(/capture checkpoint/g) || []).length
console.log('capture 日志行数 = ' + captures + '（应为 1: 摘要被捕获、普通消息不算、重复被去重）')
for (const l of logText.split('\n').filter(Boolean)) console.log('  | ' + l)

// ---------------- v0.4.1: 记账断言（★ 按【宿主真实契约】调用）----------------
// ★ 必须放在下面的 rmSync/disposer 之前 —— disposer() 会清掉记账的合并定时器，
//   那样看起来就像"记账坏了"（我们真的因此误判过一次）。
//
// ★★ 为什么这一版重写了调用方式（v0.4.0 的 verify 漏掉了真 bug）:
//    宿主的契约是 'llm/stream'(this: LlmRuntime, options, next)  —— 【两个参数】:
//      this    = LlmRuntime（不是参数！）
//      options = GenerateOptions
//      next    = () => AsyncIterable<StreamChunk>
//    v0.4.0 的插件多写了一个前置参数 (runtime, options, next)，参数整体错位，
//    真正的 next 变成 undefined ⇒ 每次模型调用抛
//      "next(...) is not a function or its return value is not async iterable"
//    ⇒ 【那台机器所有会话都跑不起来】。
//    而 v0.4.0 的 verify 是这样调的:  llmHandler({}, options, fakeStream)
//      —— 三个参数，恰好复述了插件自己的错误假设 ⇒ 测试与 bug 自洽 ⇒ 永远 PASS。
//    ★ 教训: 测试必须按【宿主契约】调用被测代码，不能沿用实现里的假设；
//      契约要用宿主自带的 Inspect（provider=Event, method=listEvents）读，别猜。
//    所以这里: ① 断言 handler.length === 2 ② 用 (options, next) 真调一次。
let accountingOK = false
if (typeof llmHandler !== 'function') {
  console.log('llmHandler  = 未挂上 —— 本版应当挂 llm/stream 记账钩子')
} else if (llmHandler.length !== 2) {
  console.error('FAIL(7): llm/stream 钩子的参数个数是 ' + llmHandler.length + '，契约要求 2 个 —— ' +
    '本事件是 waterfall，签名 (this: LlmRuntime, options, next)，没有 runtime 形参')
  console.error('         （v0.4.0 就是因为多了一个前置形参，让 next 变成 undefined，导致所有会话失败）')
  process.exit(7)
} else {
  async function* fakeStream() {
    yield { type: 'text-delta', index: 0, text: 'hi' }
    yield { type: 'usage', usage: { inputTokens: 11, outputTokens: 22 } }
    yield { type: 'finish', reason: { kind: 'stop' } }
  }
  try { rmSync(probeLog, { force: true }) } catch (e) { }   // 只看记账产生的日志
  // ★ 两个参数，与宿主一致
  const it = llmHandler({ provider: 'ollama-local', model: 'deepseek-r1:7b',
    sessionId: 'session-00000000-dead-beef-000000000000', messages: [] }, fakeStream)
  let drained = 0
  for await (const _c of it) drained++
  console.log('llmStream   = 按契约 (options, next) 调用，直通排空 ' + drained + ' 个 chunk（应为 3）')
  await new Promise((r) => setTimeout(r, 3000))
  let t2 = ''
  try { t2 = readFileSync(probeLog, 'utf8') } catch (e) { }
  for (const l of t2.split('\n').filter(Boolean)) console.log('  | ' + l)
  accountingOK = /capture llm-call/.test(t2)
  console.log('accounting  = ' + (accountingOK ? '✅ 触发了记账（capture llm-call）' : '❌ 没有触发记账'))
  if (drained !== 3) { console.error('FAIL(6): llm/stream 钩子没有直通（' + drained + ' != 3）'); process.exit(6) }
  if (!accountingOK) { console.error('FAIL(6): 记账未触发'); process.exit(6) }
}

// ---------------- v0.4.2: 捕获时中文机器名不得被写坏 ----------------
// ★ 真 bug 回归守卫。v0.4.1 把 -Subject '<机器名>' 内联进 wrapper，而 wrapper 是
//   【无 BOM 的 UTF-8 .ps1】—— PowerShell 5.1 按 ANSI 读它 ⇒ 中文写坏。
//   实测后果: 库里 subject 存成 "鏈ㄦ槗"（E9 8F 88 E3 84 A6 E6 A7 97），本机 COMPUTERNAME
//   正是中文的"NODE-A"，所以每条自动捕获都会带上这个乱码。
//   修法: subject 也走 UTF-8 文件 + wrapper 加 BOM。
//   这里用一个 stub 冒充 CLI，把收到的参数落到文件，再断言 subject 原样是中文。
let encodingOK = false
{
  const stubPath = join(tmpdir(), 'dsh-mem-verify-stub.ps1')
  const argsPath = join(tmpdir(), 'dsh-mem-verify-args.txt')
  try { rmSync(argsPath, { force: true }) } catch (e) { }
  writeFileSync(stubPath, [
    "$ErrorActionPreference = 'Stop'",
    "$sep = [char]31",
    "$line = ($args | ForEach-Object { [string]$_ }) -join $sep",
    "[System.IO.File]::WriteAllText('" + argsPath.replace(/'/g, "''") + "', $line, (New-Object System.Text.UTF8Encoding $false))",
  ].join('\r\n'), 'utf8')

  let encHandler = null
  const encCtx = {
    systemPrompt: { context() { return () => { } } },
    on(n, h) { if (n === 'session/event') encHandler = h; return () => { } },
  }
  const dispose2 = mod.apply(encCtx, {
    replicaPath,
    cliPath: stubPath,
    logPath: join(tmpdir(), 'dsh-mem-verify-enc.log'),
    machine: 'NODE-A',
  })
  if (typeof encHandler === 'function') {
    encHandler(s, { type: 'user/message', seq: 8888, time: Date.now(), data: { role: 'user', content: [{ type: 'text', text: ckpt }] } })
    await new Promise((r) => setTimeout(r, 4000))
    let got = ''
    try { got = readFileSync(argsPath, 'utf8') } catch (e) { }
    const toks = got.split('\u001f')
    const idx = toks.indexOf('-Subject')
    const subject = idx >= 0 ? String(toks[idx + 1]) : '(stub 未收到 -Subject)'
    console.log('captureArgs = stub 收到的 subject = [' + subject + ']（应为 NODE-A）')
    encodingOK = (subject === 'NODE-A')
    if (!encodingOK) {
      console.error('FAIL(8): 中文机器名在传给 CLI 时被写坏了（收到 ' + subject + '）—— ' +
        '检查是否把中文内联进了无 BOM 的 .ps1，或 subject 没走 UTF-8 文件')
    }
  } else {
    console.log('captureArgs = （本版没有 session/event 钩子，跳过）')
    encodingOK = true
  }
  if (typeof dispose2 === 'function') dispose2()
  try { rmSync(stubPath, { force: true }); rmSync(argsPath, { force: true }) } catch (e) { }
}

try { rmSync(probeLog, { force: true }) } catch (e) { }
if (typeof disposer === 'function') disposer()

if (captures === 1 && activityOK && accountingOK && encodingOK) { console.log('RESULT: PASS (注入 + 活动段 + 自动捕获 + 记账 + 中文编码)'); process.exit(0) }
if (captures === 1 && activityOK && accountingOK) { console.log('RESULT: 前四项通过，但中文编码异常'); process.exit(8) }
if (captures === 1 && activityOK) { console.log('RESULT: 注入/活动段/捕获通过，但记账异常'); process.exit(6) }
if (captures === 1) { console.log('RESULT: 注入与捕获通过，但活动段异常'); process.exit(5) }
console.log('RESULT: 注入通过，但自动捕获未按预期触发')
process.exit(4)
