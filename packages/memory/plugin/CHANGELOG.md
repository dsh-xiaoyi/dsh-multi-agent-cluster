# CHANGELOG — dsh-memory-bridge

> 状态：**已开源**（0.5.0 起内部验收通过；0.5.1 对外发布）
> 命名：v0.5.0 对应"记忆插件 v2"改造（A/B/C 三阶段）

## [0.5.1] — 2026-10-25（开源发布）

### 新增：让记忆**可追溯**，而不只是可注入

- **状态卡（state card）**：从 `stateDir`（默认 `C:\dsh-mem\sessions`）读取最近更新的会话状态文件，
  取最新 `stateCards`（默认 3）张、每张上限 `stateMaxChars`（默认 2400 字符），注入 `state` 段。
  用于跨会话接手时先看到"上次做到哪、下一步是什么"。
- **锚点指针（anchor pointers）**：从 `anchorPath`（默认 `C:\dsh-mem\anchors\LATEST.md`）取最新锚点
  （`session` + `seq` 指针），上限 `anchorMaxChars`（默认 900 字符），注入 `anchor` 段。
  给出可回读的原文指针，避免模型复述失真；配合 `mem-read` 类工具即可按指针回读原文。

### 预算再平衡（新增两段后）

```
SEC_BUDGET  conv 8000 ｜ shards 2600 ｜ state 2400 ｜ anchor 900 ｜ recall 1600
            ｜ pinned 1200 ｜ recent 2000 ｜ activity 700 ｜ hints 400
BUDGET_FLOOR shards 700 ｜ state 1200 ｜ anchor 350 ｜ recall 500 ｜ pinned 350
            ｜ recent 450 ｜ activity 250 ｜ hints 300
```

超限时的丢弃顺序仍为 `recent → activity → pinned → shards → recall`，**不先砍 hints**。

### 安全与脱敏

- 对外发布前已移除示例中的本地地址与主机标识：`ollamaUrl` 默认值改为 `127.0.0.1`，
  示例文案不再包含具体主机名/GPU 型号；真实地址一律由配置提供。
- `docs/08-permissions-and-antivirus.md` 中的示例路径改为 `C:\Users\<用户名>` 形式。

---
## [0.5.0] — 2026-10-24（内部，未发布）

### 注入契约（A + B1/B2）

- **分段预算**：`SECTIONS` + `SEC_BUDGET`
  `conv 8000` ｜ `shards 2600` ｜ `recall 1600` ｜ `pinned 1200` ｜ `recent 2000` ｜ `activity 700` ｜ `hints 400`
  超预算不再静默 `slice`，改为追加「…（本段超出预算，省略 N 条；用 search/recent 取更多）」。
- **总量可见**：超过 `maxChars`（16000）时写 `INJECT-TOTAL-TRUNC` 并在尾部标注。
- **全局去重**：同一 `id` 只出现一次（recall > conv > shards > pinned > recent > activity > hints），
  计数写进 `INJECT-BUDGET` 的 `dup`。
- **上限来源对齐**：生效值来自 bundle patch（`cordis.patch.yml`），自检脚本读生效配置而非代码默认。
- **配置默认值**：`maxChars 16000`、`conventionsMax 8000`。

### 分片约定（B5）

- `conventions.d/*.md`：首行写 `[关键词 …]`；按命中关键词数量排序，**最多注入 3 片**（`config.shardCap`）。
- 未命中或超出上限的分片合并成一行清单（相当于目录），不占预算。

### 话题源（B3）

- 只取最近 3 条「真实用户发言」：长度 <10 忽略、纯寒暄（好的/收到/继续/ok…）忽略。

### 混合检索（C4）

- 新增可选语义检索：本地 `bge-m3`（1024 维）向量 + 现有 IDF 关键词。
- 向量缓存：`C:\dsh-mem\mem-vectors.bin`（二进制：magic/`DSHVEC01`、dim、count、时间戳、`id + float32[]`），
  由 `ops\build-vectors.ps1` 通过 18 上的 Ollama（`/api/embed`）批量生成。
- 打分：`final = 0.55 * min(1, lex/3) + 0.45 * cosine`；语义可单独入选（`semMinFinal 0.32`）。
- 降级：向量文件缺失 / Ollama 不可达 / 维度不符 → 自动退回纯 IDF，并在 `INJECT-BUDGET.semantic` 标注原因。
- 注入行：保留 `‹命中: …›`，语义命中另标 `‹语义 0.72›`。

### 数据模型（C1/C2，SQL Server）

- `dbo.memories` 新增列：`valid_from`、`valid_to`、`status`（默认 `current`）、`revision`、
  `replaced_by`、`importance`（默认 50）、`access_count`、`last_injected_at` + 索引 `IX_memories_status`。
- 新表 `dbo.memory_events`（append-only 审计：`add/merge/supersede/retire/reject/inject`，含 before/after hash）。
- 新表 `dbo.memory_links`（`supersedes/duplicates/refines/derived_from/evidence_of`）。
- 引擎 `save` 成功后自动写一条 `action='add'`（body 的 SHA256）。
- **"删除"= `status='retired'`**，行永不物理删除。

### 捕获语义（C3）

- 会话压缩摘要改为 `kind='evidence'`（不再叫 `checkpoint`），**不参与注入**。
- 注入端排除：`kind ∈ {checkpoint, evidence, llm-call}`、`status ∈ {retired, archived}`。
- 非 `current` 状态在行尾标注：`‹状态: superseded，已被 [id] 取代›`。

### 检索修复（B4，引擎侧）

- `LIKE` 通配符转义（`[[]` `[%]` `[_]`）；多词按 **AND** 拆开。
- 排序：`checkpoint` 垫底 → 标题命中优先 → `updated_at DESC`。
- 反例前后：`备份_` 440→2 ｜ `"共享盘 SMB"` 0→6 ｜ `备份` 前 6 条 checkpoint 8→0。

### 可观测性（A4）

- `C:\dsh-mem\logs\inject.log`：每轮 `INJECT-BUDGET`、`INJECT-SHARDS`、`INJECT-TRUNC`、
  `INJECT-TOTAL-TRUNC`、`INJECT-FAIL`、`SEMANTIC-OK`。
- `ops\check-conventions.ps1` + 每日任务 `DSH_ConventionsCheck`（06:50）：超限当场报警。

### 故障可见（A2）

- 副本原子写（`.tmp` + `Move-Item -Force`）。
- 插件读取/解析失败不再清空 digest，改为在系统提示里写**汉字告警**（原因 + 副本路径 + 处理建议）。

### 维护脚本安全（A3）

- `mem-maintenance.ps1` 新增 `-AllowDelete`；没有它时 `-Apply` 自动降级为 DRY-RUN（只报告，不删）。

## [0.5.3] — 2026-10-25（实时同步）

### 新增：spool 实时捕获（每轮即时入库）
- 插件在 `session/event` 里把**每一条**消息事件追加到 `C:\dsh-mem\spool\hot.jsonl`
  （只写文件：不 spawn 子进程、不直连数据库 —— DB 抖动不会阻塞任何一轮对话）
- 轮转：超过 `spoolMaxBytes`（默认 32MB）改名为 `hot.jsonl.1`；单条文本上限 `spoolTextMax`（默认 100000 字符）
- 关闭开关：`spoolCapture: false`
- 为何不给 `dsh-mem.ps1 sync` 提频：实测单次 sync 约 30 秒且成本随会话体积增长，
  1 分钟间隔会重叠、延迟反而从 2 分钟涨到 4 分钟（已回滚到 3 分钟）

### 新增：增量导入器（配套脚本）
- `ops/spool-import.ps1`：按偏移量只读新增行，`(session_id, seq)` 去重，单实例锁，失败写日志
- `ops/spool-import-loop.ps1`：常驻循环每 8 秒导入一次；实测 spool 行 → 入库 = 9.3 秒

### 修复：自测更严格
- `verify.mjs` 的 mock ctx 由"只记一个 handler"改为"收集全部 handler 并逐个派发"
  （新增第二个 `session/event` 处理者后，旧 mock 会吞掉捕获处理器，造成 FAIL(8) 假红）
## [0.5.4] — 2026-10-25（补全 spool 捕获）

### 修复：spool 只捕获到 user/message
- 第一版用单一提取器（只认 `data.content[].text`），实测 assistant / tool 事件取不到文本 ⇒ 被当空事件丢弃。
- 现在多形状提取：`data.content[]` / `data.message.content[]` / `data.parts[]` 的 `text`，工具调用取
  `name + arguments`，最后还有"序列化兜底"（保证事件不静默消失）。
- 单元测试：6 个事件覆盖 user / assistant（含嵌套）/ tool/call / tool/result（块 + 字符串）→ 6/6 全部落盘。
- `verify.mjs` 的两处 apply 显式 `spoolCapture: false`，自测不再往真实 spool 写（此前会留 `session-00000000-*` 噪音行）。