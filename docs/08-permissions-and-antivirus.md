# 权限要求与安全软件拦截说明

> 这一页解决两个最常见的"装不上/跑不起来"：
> **① 需要什么权限？② 杀毒/安全软件为什么拦我？**

---

## 一、需要哪些权限（按最小权限给）

| 操作 | 需要什么 | 为什么 | 能不能不给 |
|---|---|---|---|
| **建库建表**（`sql/*.sql`） | SQL 上 **sysadmin**（或 db_owner + CREATE TABLE） | 建表、建登录、建作业 | 不能省；但这是一次性动作，跑完就可以降权 |
| **日常读写记忆库** | 普通 SQL 登录（db_datareader/db_datawriter） | `dsh-mem.ps1 save/search`、看门狗、规则判定 | 可以，且**应该**只用这个 |
| **建插件链接**（`mklink /D`） | 当前用户的 `~/.dsh/profiles/.../node_modules` 写权限；<br>某些 Windows 版本还要**管理员**或开启"开发者模式" | 把本仓库的插件目录"链接"到 DSH 的 profile | 可以省：直接复制目录代替链接（升级时手动覆盖） |
| **注册计划任务**（备份/心跳/巡检） | 管理员（注册 SYSTEM 或指定用户任务） | 定时备份、跨机互监 | 可以省：只手动跑脚本 |
| **青鸟监听端口**（默认 19387） | 无需管理员（>1024 端口）；<br>若开了防火墙需放行该端口 | 接收其他节点的消息 | 可以省：只用数据库队列，不用实时通道 |
| **读取保管库/凭据** | 本机文件读权限（建议 DPAPI/凭据管理器保存） | 备份口令、桥令牌 | 可以省：全部改成配置里手填 |

### 三条原则

```
① 建表用高权限，运行用低权限 —— 别拿 sysadmin 当日常账号
② 不要为了"跑通"去关 UAC / 关杀软 / 给 Everyone 权限：那是在给自己的机器开洞
③ 脚本不会替你改任何安全设置（不改防火墙策略、不改杀软配置、不改 UAC）
```

---

## 二、安全软件会拦什么（以及怎么处理）

> 下面这些**不是你操作错了**，而是 PowerShell 脚本类工具的常见误报。
> 我们实测过的拦截点（360、Windows Defender 都出现过）：

| 会被拦的动作 | 表现 | 建议处理 |
|---|---|---|
| **PowerShell 启动 PowerShell**（子进程） | 子进程被静默杀掉、或弹窗"已阻止脚本" | 把**仓库目录**加入安全软件的"信任目录 / 白名单"（不是关掉它） |
| **`mklink` 创建符号链接** | 提示"需要管理员权限"或直接被拦 | 用管理员运行一次；或在"开发者模式"下运行；或改用复制目录 |
| **注册计划任务** | 任务没建上、事件日志里被拒 | 以管理员运行安装脚本；或手动在任务计划程序里建 |
| **监听端口**（青鸟） | 首次运行时弹"允许网络访问？" | 只允许**专用网络/内网**；不要放行公网 |
| **下载/解压/写入 exe** | Defender 的"受控文件夹访问"会拦 | 把安装目录加入"受控文件夹访问"的允许列表 |
| **`.ps1` 直接双击** | 提示"无法加载脚本，因为在此系统上禁止运行脚本" | 用 `powershell -ExecutionPolicy Bypass -File xxx.ps1`，或给当前用户设 `RemoteSigned`（不要设 Unrestricted） |

### 白名单怎么加（把整个目录给信任，而不是关掉防护）

```
360：设置 → 安全防护中心 → 信任区 / 开发者模式 → 添加本仓库目录
Defender：Windows 安全中心 → 病毒和威胁防护 → 管理设置 → 排除项 → 添加文件夹
```

### 我们**不**做的事（也是请不要做的）

```
× 不教你关闭杀毒软件、关闭 UAC、关闭防火墙
× 不写"杀不掉的自保护"、不装内核驱动
× 不改动系统的安全策略
```

---

## 三、最小验证顺序（出了问题先按这个缩小范围）

```powershell
# 1) 只验证 PowerShell 能被允许跑脚本
powershell -ExecutionPolicy Bypass -File .\ops\secret-scan.ps1 -Root .        # 只读，不写系统

# 2) 只验证能不能连库（不做任何写入）
powershell -ExecutionPolicy Bypass -File .\ops\doctor.ps1 -ConfigPath C:\dsh-mem\dsh-mem.config.json

# 3) 再验证建表（需要 sysadmin）
sqlcmd -E -d DSHMemory -i .\packages\memory\sql\001-create-embeddings.sql

# 4) 最后才装插件（需要写 profile 目录 + 重启 DSH）
```

每一步失败时，**先看它打印的失败原因**（本项目的脚本都会明确说出为什么失败），
再去加白名单或补权限 —— 不要一上来就把所有防护关掉。

## 四、如果组名被改过：请**用 SID 判断权限**（很重要）

有些人会把系统里的组名"对调"来做防御（例如把 `Administrators` 改名为 `Y`，把 `Guests` 改名为 `Administrators`）。
这个办法很聪明，但会让"按名字判断权限"的脚本得出**完全相反**的结论：

- 你以为把账号加进 `Administrators` 就给了管理员 → 实际加进了**来宾组**，权限一点没给
- 你以为 `BUILTIN\Administrators` 是管理员组 → 实际它是来宾组
- 你以为 `C:\Users\dsy` 属于账号 `dsy` → 实际可能属于另一个账号（目录名不随改名变化）

正确做法是**按 SID 判断**，或直接用 .NET 的 `IsInRole`（它内部就是按 SID）：

```powershell
# (1) 判断当前是否管理员：IsInRole 内部用 SID S-1-5-32-544，组名改成什么都无所谓
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# (2) 想知道"真正的管理员组"在这台机器上叫什么名字
([Security.Principal.SecurityIdentifier]'S-1-5-32-544').Translate([Security.Principal.NTAccount]).Value

# (3) 想给某账号管理员权限：先按 SID 解析组名，再加（不要硬编码 "Administrators"）
$adminsName = ([Security.Principal.SecurityIdentifier]'S-1-5-32-544').Translate([Security.Principal.NTAccount]).Value
net localgroup "$adminsName" <账号> /add
```

### 两个相关事实（省得白费功夫）

```
① 用户目录名不随账号改名而变
   目录归属按 SID 记在 HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList
   所以 C:\Users\dsy 可能属于别的账号；要确认就跑一次 ProfileList 对照 SID

② RID 改不了
   内置 Administrator 是 RID 500，后建的账号是 1001 起。**没有受支持的方法**把普通管理员"提升"成 RID 500。
   少数老软件要求 500 时，正确做法是"启用内置管理员 → 只用它跑那个软件 → 用完禁用"，
   而不是把日常账号迁移过去。另外若 `FilterAdministratorToken=1`，连 RID 500 也会被 UAC 过滤 —— 迁了也没用。
```

