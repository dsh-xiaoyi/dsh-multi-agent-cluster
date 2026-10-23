# 变更记录

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
