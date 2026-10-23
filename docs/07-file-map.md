# 文件地图（每个文件是干什么的）

> 第一次看仓库时，先看这一页，比逐个点开快。
> 标注 **示例** 的表示"照着改"，标注 **模板** 的表示"当参考，别直接跑"。

## 根目录

| 文件 | 作用 |
|---|---|
| `README.md` | 门面：解决什么问题、三中枢、5 分钟跑起来 |
| `LICENSE` | MIT |
| `CHANGELOG.md` | 版本变更 |
| `CONTRIBUTING.md` | 怎么提 issue / PR（含"提交前必须跑 secret-scan"） |
| `SECURITY.md` | 安全问题怎么私聊报，不要开公开 issue |
| `.gitignore` | 凭据、日志、备份、数据导出**一律不进仓库** |

## `docs/` —— 方法论

| 文件 | 作用 |
|---|---|
| `00-why.md` | 为什么做这个（含我们三次失败的注记） |
| `01-architecture.md` | 三中枢 = 大脑与左右手；三条职责边界 |
| `02-memory-design.md` | 注入四段、为什么必须 IDF、三层缺陷复盘 |
| `03-conventions.md` | 判据纪律 / 通道职责 / 重启身份 / 权限 / 发布前脱敏 |
| `04-postmortems.md` | 7 条真实事故与修法 |
| `05-recovery-drill.md` | RTO/RPO、恢复路径、演练判据 |
| `06-rescue.md` | DSH 改坏了怎么查、R1–R5 回滚剧本 |
| `winrm.md` | WinRM 基线（跨机管理） |
| `07-file-map.md` | 本页 |
| `08-permissions-and-antivirus.md` | 权限要求 + 安全软件拦截怎么处理 |

## `ops/` —— 安装与工具（拿起来就能用）

| 文件 | 作用 |
|---|---|
| `install.ps1` | 一键安装：目录 → 配置 → 建表 → 装插件 → 体检（缺依赖会明说并停下） |
| `doctor.ps1` | 通用体检：配置、库、副本新鲜度、插件、端口、队列（只读） |
| `secret-scan.ps1` | 发布前敏感信息扫描（BLOCK 必须为 0） |

## `examples/` —— 示例

| 文件 | 作用 |
|---|---|
| `config.example.json` | 记忆库配置（占位值；复制成 `C:\dsh-mem\dsh-mem.config.json`） |
| `peers.example.json` | 青鸟的对端令牌表（占位值） |

## `packages/memory/` —— 记忆旧时光

| 文件 | 作用 |
|---|---|
| `dsh-mem.ps1` | 引擎 CLI：`save` / `search` / `recent` / `sync` / `backup` / `replica` / `history` |
| `mem-artifact.ps1` | 把文件登记成"工件"（入库 + 校验哈希） |
| `conventions.example.md` | 关键约定的模板（复制成 `conventions.md` 再按自己情况改） |
| `sql/001..010-*.sql` | 建表脚本，按编号顺序执行 |
| `sql/job-*.sql` | SQL Agent 作业（可选：自动备份/巡检） |
| `plugin/index.mjs` | 注入插件：把"关键约定 + 自动检索 + 定义型记忆"塞进每次会话 |
| `plugin/verify.mjs` | 插件自检：副本路径、注入是否真的发生 |
| `plugin/cordis.patch.yml` | 插件在 DSH 里的配置片段（示例） |
| `plugin/package.json` | 插件包声明 |

## `packages/bridge/` —— 青鸟（通信桥）

| 文件 | 作用 |
|---|---|
| `plugin/index.mjs` | DSH 插件：入站 `/agent/inbox` 注入 + 队列轮询 + per-peer 令牌 |
| `plugin/bridge-send.mjs` | 命令行发一条消息（调试/脚本用） |
| `plugin/verify.mjs` | 桥自检：健康检查、令牌、投递 |
| `plugin/cordis.patch.yml` | 插件配置片段（**示例**：里面的 peer 名单要换成你自己的） |
| `plugin/package.json` | 插件包声明 |

## `packages/guard/` —— 时光守护

| 文件 | 作用 |
|---|---|
| `ops/guard-rules.ps1` | 规则引擎：从库里读规则、逐条判定、输出 `RESULT:` |
| `ops/heartbeat-l1.ps1` | L1 跨机互监心跳（谁多久没探通谁） |
| `ops/memory-audit.ps1` | 记忆库完整性体检（消息/会话/向量/存档） |
| `ops/check-backup-pack.ps1` | 备份包新鲜度与目录整洁度 |
| `ops/recover-bridge.ps1` | 一键恢复：停 → 起 → 验证（需要 `-DshExe` 或 `DSH_EXE`） |


### SQL 脚本逐个说明

| 文件 | 用途 |
|---|---|
| `sql/001-create-embeddings.sql` | 向量表：语义召回（可选；不装也能用关键词检索） |
| `sql/002-create-messages-history.sql` | 消息存档表：同步覆盖/回滚前先存到这里，保证"改了也能追溯" |
| `sql/003-create-machine-login.sql` | 每台机器的 SQL 登录与授权模板（执行前替换占位符） |
| `sql/004-messages-no-unarchived-delete.sql` | 保护：不允许删除"还没存档"的消息 |
| `sql/005-create-credentials.sql` | 凭据仓库表：存"引用"，不存明文口令 |
| `sql/006-create-llm-retries.sql` | 模型请求重试事件表（观测用） |
| `sql/007-create-lesson-records.sql` | 教训/经验记录表：把踩过的坑结构化留下来 |
| `sql/008-lesson-records-appendable.sql` | 把 lesson_records 改成"只追加、不可改" |
| `sql/009-agent-messages.sql` | 可靠队列：agent 间消息（含 delivered_at / last_error 三态） |
| `sql/010-create-sec-heartbeat.sql` | L1 跨机互监心跳（职能属时光守护；表名沿用历史） |
| `sql/job-estate-backup.sql` | SQL Agent 作业：定期全库备份（路径改成你自己的） |
| `sql/job-weekly-checkdb.sql` | SQL Agent 作业：每周 DBCC CHECKDB |
| `sql/job-weekly-stats.sql` | SQL Agent 作业：每周更新统计信息 |

## 看代码的建议顺序

```
1) README 的 5 分钟跑起来        —— 先让它动起来
2) docs/02-memory-design.md      —— 理解"为什么这样注入"
3) packages/memory/plugin/index.mjs —— 看注入到底做了什么
4) docs/03-conventions.md        —— 用之前先知道红线
5) docs/04-postmortems.md        —— 我们会坏在哪里
```
