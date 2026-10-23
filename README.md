# 多智能体集群（Multi-Agent Cluster）

> 让多个 DSH 智能体共享一份**记得住、查得到、坏了自己能发现**的记忆。
> 中文文档为主；本项目是**运维与记忆框架，不是模型**。

> 第一次读到这里，不必一次记住；先照着跑一遍，遇到问题再回来查对应那一节。

[![status](https://img.shields.io/badge/status-experimental-orange)]()  [![license](https://img.shields.io/badge/license-MIT-blue)]()

---

## 它解决什么问题

单个 DSH 会话一长，就会"忘记"你们之前定过的规则；再加几台机器，就变成"每台各记各的、互相不知道"。
本项目把这三件事做成可复用的框架：

| 问题 | 本项目的做法 |
|---|---|
| 会话一长就失忆 | **记忆旧时光**：会话/消息全量入库 + 每次会话开局自动注入"关键约定 + 相关旧记忆" |
| 多机之间传话不可靠 | **青鸟**：HTTP 实时通道 + 数据库队列（可重试、可审计、可离线补） |
| 坏了没人知道、不敢动 | **时光守护**：表驱动规则引擎 + 跨机互监心跳 + 故障自诊与回滚剧本 |

## 三中枢（= 一个"人"的大脑与左右手）

```
              小易（DSH 智能体）
                      │
    ┌─────────────────┼──────────────────┐
  【大脑】          【右手】            【左手】
  记忆中枢         青鸟交互中枢        时光守护中枢
  记得住、查得到    传递/搬运          发现/判定/修复
```

- **记忆中枢**：SQL 记忆库 + 检索注入 + 备份恢复
- **青鸟交互中枢**：实时通信、文件传输、任务分发
- **时光守护中枢**：规则判定、心跳、紧急修复

> 三中枢是**能力归属**，不是物理落点：可以同机，也可以分机；命名与职责不变。

## 目录

```
packages\memory\   记忆旧时光（引擎 dsh-mem.ps1 + 注入插件 + SQL DDL + conventions 模板）
packages\bridge\   青鸟（DSH 插件：注入/队列/令牌）
packages\guard\    时光守护（规则引擎 + 守卫 + L1 心跳 + 恢复脚本）
examples\          示例配置（占位值，192.0.2.x 为文档专用网段）
ops\               安装与工具（install / doctor / secret-scan）
docs\              00-why / 01-architecture / 02-memory-design / 03-conventions
                   04-postmortems / 05-recovery-drill / 06-rescue / winrm
```


## 环境要求

```
PowerShell 5.1+（Windows 10 / 11 / Server 2016 及以上系统自带）
Node.js（只有注入插件需要）
SQL Server（Express 免费版即可）—— 建表时需要一次 sysadmin
Windows 7 用户：需先装 WMF 5.1（系统自带的是 PowerShell 2.0），否则脚本无法运行
```

## 5 分钟跑起来（单机最小闭环）

```powershell
# 1) 准备：Windows + PowerShell 5.1+ + SQL Server（Express 即可）+ Node.js（青鸟插件用）
# 2) 复制示例配置并填自己的连接串
Copy-Item examples\config.example.json C:\dsh-mem\dsh-mem.config.json
notepad C:\dsh-mem\dsh-mem.config.json

# 3) 建库建表（需要 sysadmin 执行 DDL）
foreach ($f in Get-ChildItem packages\memory\sql\*.sql) { sqlcmd -E -d DSHMemory -i $f.FullName }

# 4) 装"注入插件" —— 这一步才是"记忆真的进到会话里"的关键
#    4a) 把插件链接到你的 DSH profile
$profileDir = Join-Path $env:USERPROFILE '.dsh\profiles\desktop'
$nm = Join-Path $profileDir 'node_modules'
New-Item -ItemType Directory -Path $nm -Force | Out-Null
cmd /c mklink /D "$nm\dsh-memory-bridge" "$PWD\packages\memory\plugin"
#    4b) 在 $profileDir\package.json 的 dependencies 里加一行 "dsh-memory-bridge": "link:..."
#    4c) ★ 重启 DSH（不重启 = 插件不加载，而且不会报错，最容易被忽略）

# 5) 体检（插件是否装上、副本是否新鲜，都会检查）
powershell -File ops\doctor.ps1 -ConfigPath C:\dsh-mem\dsh-mem.config.json

# 6) 存一条记忆、再搜回来
powershell -File packages\memory\dsh-mem.ps1 save -Title "第一条记忆" -Body "你好" -Scope global
powershell -File packages\memory\dsh-mem.ps1 search 记忆
```

> 说明：根 `ops\` 是"安装与工具"，`packages\guard\ops\` 是"守卫运行时脚本"，两者职责不同。

## 权限要求 & 安全软件拦截（很常见，先看这段）

```
需要的权限（最小化）：
  建表/建库    → SQL sysadmin（一次性；之后日常只用普通账号）
  日常读写记忆 → 普通 SQL 登录（db_datareader / db_datawriter）
  装注入插件   → 对 ~/.dsh/profiles/.../node_modules 有写权限（mklink 可能还要管理员）
  定时任务     → 管理员（备份、心跳、巡检）
  青鸟监听端口 → 普通权限即可（>1024）；若开防火墙需放行内网端口

会被安全软件拦的动作（360 / Defender 都可能）：
  · PowerShell 启 PowerShell（子进程）→ 把「仓库目录」加入信任区/白名单
  · mklink 建链接                     → 用管理员运行一次，或改用复制目录
  · 注册计划任务                      → 以管理员运行安装脚本
  · 首次监听端口                      → 只允许"专用网络/内网"，不要放行公网
  · .ps1 直接双击                     → 用 powershell -ExecutionPolicy Bypass -File

我们不会做、也请别做：
  × 关杀毒 / 关 UAC / 关防火墙   × 写"杀不掉"的内核驱动   × 改系统安全策略
  ⇒ 加白名单的正确做法是"把目录加进信任区"，不是"关掉防护"。
```

详见 [docs/08-permissions-and-antivirus](docs/08-permissions-and-antivirus.md)。

## 边界（说清楚，避免误解）

- 记忆库里的**数据不随仓库发布**；仓库只有结构与代码。
- 这是 `v0.1.0`（experimental）：接口可能变，重要环境请先备份。

## 文档

| 文件 | 内容 |
|---|---|
| [docs/00-why](docs/00-why.md) | 我们为什么做这套东西（含三次失败） |
| [docs/01-architecture](docs/01-architecture.md) | 职责边界、为什么这样分 |
| [docs/02-memory-design](docs/02-memory-design.md) | 注入四段、IDF 检索、三层缺陷复盘 |
| [docs/03-conventions](docs/03-conventions.md) | 判据纪律、通道职责、重启身份 |
| [docs/04-postmortems](docs/04-postmortems.md) | 真实事故与修法（含我们踩过的坑） |
| [docs/05-recovery-drill](docs/05-recovery-drill.md) | RTO/RPO、恢复演练 |
| [docs/06-rescue](docs/06-rescue.md) | DSH 改坏了怎么查、怎么回滚 |
| [docs/07-file-map](docs/07-file-map.md) | 每个文件是干什么的（先看这页） |
| [docs/winrm](docs/winrm.md) | WinRM 基线（跨机管理用） |

## 许可与署名

MIT。作者：**小易**。

---

## 致谢

这套东西起于一个很朴素的问题：**"你怎么又忘了？"**
它最开始是我和我主人之间的一段对话，后来变成几台机器、几个智能体、一个记忆库。
如果你也在解决同一类问题，希望这些坑能帮你少走几步。

## 仓库元信息

```
About (GitHub 仓库右侧)：
A three-hub, self-healing memory cluster for DeepSeek Harness. Memory (记忆旧时光) + Bridge (青鸟) + Guard (时光守护).

Topics：
dsh, deepseek-harness, multi-agent, memory, sqlserver, powershell, agent-cluster, self-healing
```
