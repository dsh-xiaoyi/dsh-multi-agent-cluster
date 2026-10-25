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
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { tmpdir } from 'node:os'

const here = dirname(fileURLToPath(import.meta.url))

// 各机安装位置可能不同，逐个探测，
// 免得"配置路径不对"被误报成"插件坏了"。
const candidates = [
  process.env.DSH_MEM_REPLICA,
  // 2026-10-25 FIX: 安装目录不一定在 C:\dsh-mem；与 index.mjs 的 PATH_CANDIDATES 保持一致，
  //   否则换台机器（例如装在 G:\deepseek）时 verify 找不到副本，误报 exit=2。
  'C:\\dsh-mem\\dsh-mem-replica.json',
  'G:\\deepseek\\dsh-mem-replica.json',
  'E:\\deepseek\\dsh-mem-replica.json',
  'D:\\deepseek\\dsh-mem-replica.json',
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
let eventHandlers = []
let llmHandler = null
const fakeCtx = {
  systemPrompt: { context(c) { contextEntry = c; return () => {} } },
  on(name, handler) { if (name === 'session/event') { (eventHandlers = eventHandlers || []).push(handler) };
                      if (name === 'llm/stream') llmHandler = handler; return () => {} },
}

// ★ 关键: cliPath 指向一个不存在的路径 ⇒ 捕获流程会被触发，但【写不进数据库】
const probeLog = join(tmpdir(), 'dsh-memory-bridge-verify.log')
try { rmSync(probeLog, { force: true }) } catch (e) { }
// ★ 2026-10-25 FIX: 原来这里故意给一个"不存在的 cliPath"，指望插件不去真写库。
//   但旧版插件在"配置了但不存在"时会回退到候选里真实存在的 dsh-mem.ps1 ——
//   结果: ① 自测永远 FAIL(6)（真 CLI 写库要 1-2 秒，超过 3 秒等待窗口）；
//         ② 假数据被写进真实记忆库（实测产生 18 条 kind=llm-call 的假记录）。
//   现在改用"存在的快速 stub"，插件会立刻拿到 exit 码、且不会碰任何数据库。
const stubCli = join(tmpdir(), 'dsh-mem-verify-noop-stub.ps1')
writeFileSync(stubCli, ['$ErrorActionPreference = "SilentlyContinue"', 'exit 0'].join('\r\n'), 'utf8')
const disposer = mod.apply(fakeCtx, {
  replicaPath,
  cliPath: stubCli,
  spoolCapture: false,
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
// ---------------- T5/T4/T7: spool 配置 + 尾部字段断言（2026-10-25） ----------------
// 判据跟着被测物走：旧 verifier 只看注入内容，会把"改了配置没生效"报成绿。
// ① INJECT-TAIL 必须含 chars=<n>/<max> 与 injector=0.5.0-<sha16>（T7）
// ② spool armed 行必须含 rotateAt=<期望> 与 source=config|default（T4）
// ③ 阳性对照：VERIFY_SPOOL_MAX=33554432 时 rotateAt=33554432 ≠ 期望 ⇒ 必须红
{
  let tailLog = ''
  try { tailLog = readFileSync(probeLog, 'utf8') } catch (e) { }
  const tail = (tailLog.match(/INJECT-TAIL[^\n]*/g) || []).pop() || ''
  if (!/chars=\d+\/\d+/.test(tail)) { console.error('FAIL(11): INJECT-TAIL 缺 chars=<n>/<max>：' + tail); process.exit(11) }
  if (!/injector=0\.5\.0-[0-9A-Fa-f]{8}/.test(tail)) { console.error('FAIL(12): INJECT-TAIL 缺 injector=0.5.0-<sha16>：' + tail); process.exit(12) }
  console.log('tail assert = OK (chars + injector)')

  const expectRotate = Number(process.env.VERIFY_EXPECT_ROTATE || 1073741824)
  const spoolLog = join(tmpdir(), 'dsh-memory-bridge-verify-spool.log')
  const spoolPath = join(tmpdir(), 'dsh-memory-bridge-verify-spool.jsonl')
  try { rmSync(spoolLog, { force: true }) } catch (e) { }
  try { rmSync(spoolPath, { force: true }) } catch (e) { }
  const extra = process.env.VERIFY_SPOOL_MAX ? { spoolMaxBytes: Number(process.env.VERIFY_SPOOL_MAX) } : {}
  const d2 = mod.apply(fakeCtx, Object.assign({ replicaPath, cliPath: stubCli, spoolCapture: true, spoolPath, logPath: spoolLog, localProviders: ['ollama-local'] }, extra))
  await new Promise((r) => setTimeout(r, 120))
  try { d2() } catch (e) { }
  let armedLog = ''
  try { armedLog = readFileSync(spoolLog, 'utf8') } catch (e) { }
  const armed = (armedLog.match(/spool capture armed[^\n]*/g) || []).pop() || ''
  const m = /rotateAt=(\d+)(?:\s+source=(config|default(?:\(invalid\))?))?/.exec(armed)
  if (!m) { console.error('FAIL(10): 没有 spool capture armed 行：' + armed); process.exit(10) }
  const actual = Number(m[1])
  const source = m[2] || '?'
  console.log('armed assert= ' + armed)
  if (!m[2]) { console.error('FAIL(10): armed 行缺 source=config|default'); process.exit(10) }
  if (actual !== expectRotate) {
    console.error('FAIL(10): rotateAt=' + actual + ' 期望 ' + expectRotate + '（阳性对照：VERIFY_SPOOL_MAX=33554432 时必须红）')
    process.exit(10)
  }
  console.log('spool assert= OK rotateAt=' + actual + ' source=' + source)
}

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

// ---------------- T17-B: core 规则注入断言（规则库第一优先） ----------------
{
  function coreRules(tier) {
    const out = join(tmpdir(), 'verify-core-' + tier + '-' + process.pid + '.json')
    try { rmSync(out, { force: true }) } catch (e) { }
    const r = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
      'C:\\dsh-mem\\ops\\mem-core-rules.ps1', '-Tier', tier, '-OutFile', out], { encoding: 'utf8', timeout: 15000 })
    if (!r || r.status !== 0 || !existsSync(out)) return null
    try { return JSON.parse(readFileSync(out, 'utf8')) } catch (e) { return null }
  }
  const hdr = /rules@rev=(\d+) count=(\d+)/.exec(text)
  const mem = /memories=(\d+)/.exec(text)
  if (!hdr) { console.error('FAIL(13): 注入头缺 rules@rev=/count='); process.exit(13) }
  if (!mem) { console.error('FAIL(13): 注入头缺 memories='); process.exit(13) }
  const core = coreRules('core')
  if (!core || !core.ok) { console.error('FAIL(13): core 规则助手不可用'); process.exit(13) }
  if (Number(hdr[1]) !== Number(core.rev)) { console.error('FAIL(13): rules@rev=' + hdr[1] + ' != 库 max(version)=' + core.rev); process.exit(13) }
  if (Number(hdr[2]) !== Number(core.count)) { console.error('FAIL(13): count=' + hdr[2] + ' != core 行数=' + core.count); process.exit(13) }
  for (const r of core.rules) {
    if (text.indexOf(r.prompt) < 0) { console.error('FAIL(14): core 规则未注入: ' + r.name); process.exit(14) }
  }
  console.log('rules assert= OK rules@rev=' + core.rev + ' count=' + core.count + ' memories=' + mem[1])
  const det = coreRules('detail')
  if (det && det.ok) {
    for (const r of det.rules) {
      if (text.indexOf(r.prompt) >= 0) { console.error('FAIL(15): detail 规则泄漏进 core 注入: ' + r.name); process.exit(15) }
    }
    console.log('detail assert= OK leaked=0 (checked ' + det.count + ' detail rows)')
  }
  // CORE-EMPTY 阳性对照：coreRules=false 时必须出现 CORE-EMPTY 且不注入 core 规则
  const dEmpty = mod.apply(fakeCtx, { replicaPath, cliPath: stubCli, spoolCapture: false, logPath: probeLog,
    localProviders: ['ollama-local'], callLogFlushMs: 150, coreRules: false })
  let tEmpty = ''
  try { tEmpty = contextEntry.text() } catch (e) { }
  try { dEmpty() } catch (e) { }
  if (!/CORE-EMPTY/.test(tEmpty)) { console.error('FAIL(16): coreRules=false 时注入头未出现 CORE-EMPTY'); process.exit(16) }
  for (const r of core.rules) {
    if (tEmpty.indexOf(r.prompt) >= 0) { console.error('FAIL(16): CORE-EMPTY 场景仍注入了 core 规则'); process.exit(16) }
  }
  console.log('core-empty assert= OK (阳性对照)')

  // T18: 连续 20 轮 expect==got（expect 由 helper 直接查库，got 由注入器实读条数）
  let okRounds = 0
  for (let i = 0; i < 20; i++) {
    const dLoop = mod.apply(fakeCtx, { replicaPath, cliPath: stubCli, spoolCapture: false, logPath: probeLog,
      localProviders: ['ollama-local'], callLogFlushMs: 150, semantic: false })
    let tLoop = ''
    try { tLoop = contextEntry.text() } catch (e) { }
    try { dLoop() } catch (e) { }
    const c2 = coreRules('core')
    const h2 = /count=(\d+)/.exec(tLoop)
    if (c2 && c2.ok && h2 && Number(h2[1]) === Number(c2.expect) && Number(h2[1]) === Number(c2.got)) okRounds++
  }
  if (okRounds !== 20) { console.error('FAIL(17): 连续 20 轮 expect==got 失败: ' + okRounds + '/20'); process.exit(17) }
  console.log('rules 20-round = 20/20 expect==got (expect=' + core.expect + ')')
}
if (typeof eventHandler !== 'function') {
  console.log('eventHandler= 未挂上（v0.5.4+ 自动捕获改走 spool：C:\\dsh-mem\\spool\\hot.jsonl，这是新架构下的正常结果；要判实时性请测 hot.jsonl 是否增长）')
  console.log('RESULT: PASS (注入部分)')
  process.exit(0)
}

// 喂三条: 1 条压缩摘要(该捕获) + 1 条普通消息(不该) + 1 条重复(该去重)
const s = { id: 'session-00000000-dead-beef-0000-000000000000' }
const ckpt = 'This is an automatically generated checkpoint condensing an earlier span of the conversation. ' + 'x'.repeat(200)
for (const h of eventHandlers) h(s, { type: 'user/message', seq: 4242, time: Date.now(), data: { role: 'user', content: [{ type: 'text', text: ckpt }] } })
for (const h of eventHandlers) h(s, { type: 'user/message', seq: 4243, time: Date.now(), data: { role: 'user', content: [{ type: 'text', text: '普通用户消息，不该被当成压缩摘要捕获。' }] } })
for (const h of eventHandlers) h(s, { type: 'user/message', seq: 4242, time: Date.now(), data: { role: 'user', content: [{ type: 'text', text: ckpt }] } })

// 等子进程报错退出并写日志
await new Promise((r) => setTimeout(r, 2500))

let logText = ''
try { logText = readFileSync(probeLog, 'utf8') } catch (e) { }
const captures = (logText.match(/capture (?:checkpoint|evidence)/g) || []).length
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

  let encHandlers = []
  const encCtx = {
    systemPrompt: { context() { return () => { } } },
    on(n, h) { if (n === 'session/event') { (encHandlers = encHandlers || []).push(h) }; return () => { } },
  }
  const dispose2 = mod.apply(encCtx, {
    replicaPath,
    cliPath: stubPath,
    spoolCapture: false,
    logPath: join(tmpdir(), 'dsh-mem-verify-enc.log'),
    machine: 'NODE-A',
  })
  if (encHandlers.length > 0) {
    for (const h of encHandlers) h(s, { type: 'user/message', seq: 8888, time: Date.now(), data: { role: 'user', content: [{ type: 'text', text: ckpt }] } })
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
  try { rmSync(stubPath, { force: true }); rmSync(argsPath, { force: true }); rmSync(stubCli, { force: true }) } catch (e) { }
}

try { rmSync(probeLog, { force: true }) } catch (e) { }
if (typeof disposer === 'function') disposer()

if (captures === 1 && activityOK && accountingOK && encodingOK) { console.log('RESULT: PASS (注入 + 活动段 + 自动捕获 + 记账 + 中文编码)'); process.exit(0) }
if (captures === 1 && activityOK && accountingOK) { console.log('RESULT: 前四项通过，但中文编码异常'); process.exit(8) }
if (captures === 1 && activityOK) { console.log('RESULT: 注入/活动段/捕获通过，但记账异常'); process.exit(6) }
if (captures === 1) { console.log('RESULT: 注入与捕获通过，但活动段异常'); process.exit(5) }
console.log('RESULT: 注入通过，但自动捕获未按预期触发')
process.exit(4)
