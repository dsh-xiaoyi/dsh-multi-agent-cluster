# 变更记录

## [0.5.1] — 2026-10-25（memory 插件升级）
### 修复（发布前自测拦下的两个真问题）

- `packages/memory/plugin` 同步了 0.5.1 的两处修复：
  **显式 `cliPath` 缺失不再静默回退**（记 `CLI-MISSING`、拒绝执行）+
  **`verify.mjs` 改用临时 no-op stub CLI**（自测稳定 PASS，且不再写任何数据库）。
- 补齐了 `package.json` 里 `files` 清单缺失的 4 个文件（否则 `npm pack` 出来的包不完整）。


- `packages/memory/plugin` 升级到 **dsh-memory-bridge 0.5.1**：新增
  **state card**（跨会话工作状态）与 **anchor 指针**（可回读的 session+seq）两段注入，
  `SEC_BUDGET`/`BUDGET_FLOOR` 随之再平衡（state 2400 / anchor 900，各段设下限）。
- 对外示例已脱敏：默认 `ollamaUrl` 改为 `127.0.0.1`，文案不再含具体主机名/GPU 型号；
  文档中的示例路径统一为 `C:\Users\<用户名>`；`packages/bridge/plugin/cordis.patch.yml`
  的白名单示例主机名改为 `<agent-host>`。
## v0.1.0 (2026-10-23) — 首发（experimental）

### 新增
- **记忆旧时光**：引擎（save/search/recent/sync/backup/replica/history）、12 个 SQL 结构脚本、注入插件（v3/IDF）
- **青鸟**：DSH 插件（入站注入 + 队列轮询 + peer 令牌）、发送脚本、验证脚本
- **时光守护**：表驱动规则引擎、30 项体检、L1 跨机互监心跳、一键恢复脚本、周包检查
- **文档**：00-why（为什么做）、01-architecture（三中枢架构）、02-memory-design（记忆设计，含三层缺陷复盘）、
  03-conventions（运维纪律）、04-postmortems（复盘集）、05-recovery-drill（恢复演练）、06-rescue（故障自诊与回滚）、winrm（WinRM 基线）、07-file-map（文件地图）、08-permissions-and-antivirus（权限与安全软件拦截）
- **工具**：`ops\secret-scan.ps1`（发布前必跑）、`ops\install.ps1`、`ops\doctor.ps1`

### 明确不含
- 任何真实环境数据（记忆库内容、对话、主机信息）

### 已知限制
- 检索是关键词 + IDF，不是语义向量
- 注入长度受上限约束，超长会截断
- 缓存/队列在生产环境请先压测
