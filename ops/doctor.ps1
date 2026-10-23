# 第一次用？先看 README 的「5 分钟跑起来」，再回来读这个脚本。
# doctor.ps1 - 体检：配置 / 库 / 副本 / 插件 / 端口 / 队列 / 规则
#
# 只读检查，不修改任何东西。任何一项失败都会打印原因并计入 FAIL。
param(
    [string]$ConfigPath = 'C:\dsh-mem\dsh-mem.config.json',
    [int]$MaxReplicaMinutes = 30
)
$ErrorActionPreference = 'Continue'
$fail = 0
function Ok($m)   { Write-Output ('[PASS] ' + $m) }
function Bad($m)  { Write-Output ('[FAIL] ' + $m); $script:fail++ }
function Info($m) { Write-Output ('[INFO] ' + $m) }
if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) { Info '没有找到 sqlcmd（可不影响本体检，但建库/恢复演练会用到）' }
if (-not (Get-Command node   -ErrorAction SilentlyContinue)) { Info '没有找到 node（青鸟与注入插件需要 Node.js）' }

# 1) 配置
if (-not (Test-Path $ConfigPath)) { Bad ('配置不存在: ' + $ConfigPath); Write-Output 'RESULT: FAIL'; exit 3 }
$cfg = (Get-Content $ConfigPath -Raw | ConvertFrom-Json)
Ok ('配置存在: ' + $ConfigPath)

# 2) 数据库
try {
    $cs = 'Server=' + $cfg.server + ';Database=' + $cfg.database + ';TrustServerCertificate=True;Connect Timeout=8'
    if ($cfg.user -and $cfg.password) { $cs += ';User Id=' + $cfg.user + ';Password=' + $cfg.password } else { $cs += ';Integrated Security=True' }
    $cn = New-Object System.Data.SqlClient.SqlConnection $cs
    $cn.Open()
    $q = $cn.CreateCommand(); $q.CommandText = 'SELECT COUNT(*) FROM dbo.memories'
    Info ('memories = ' + $q.ExecuteScalar())
    $q2 = $cn.CreateCommand(); $q2.CommandText = 'SELECT COUNT(*) FROM dbo.messages'
    Info ('messages = ' + $q2.ExecuteScalar())
    $cn.Close()
    Ok '数据库可连接'
} catch { Bad ('数据库不可用: ' + $_.Exception.Message.Split("`n")[0]) }

# 3) 离线副本新鲜度
$rp = $cfg.replicaPath
if ($rp -and (Test-Path $rp)) {
    $age = ((Get-Date) - (Get-Item $rp).LastWriteTime).TotalMinutes
    if ($age -le $MaxReplicaMinutes) { Ok ('离线副本新鲜（' + [int]$age + ' 分钟前）') }
    else { Bad ('离线副本过期（' + [int]$age + ' 分钟）') }
} else { Bad ('离线副本不存在: ' + $rp) }

# 4) 注入插件是否装了
$profileDir = Join-Path $env:USERPROFILE '.dsh\profiles\desktop'
$plugin = Join-Path $profileDir 'node_modules\dsh-memory-bridge\index.mjs'
if (Test-Path $plugin) { Ok ('注入插件存在: ' + $plugin) } else { Bad '注入插件未安装（见 ops\install.ps1 第 4 步）' }

# 5) DSH 端口（只发现）
$procs = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
if ($procs.Count -gt 0) {
    $ports = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
               Where-Object { $_.OwningProcess -in $procs.Id } | Select-Object -ExpandProperty LocalPort -Unique)
    if ($ports.Count -gt 0) { Ok ('DSH 监听端口: ' + ($ports -join ',')) } else { Bad 'DSH 在跑但没有监听端口' }
} else { Info 'DSH 未运行（若刚装完属正常）' }

# 6) 队列积压
try {
    $cs = 'Database=' + $cfg.database + ';Server=' + $cfg.server + ';Trusted_Connection=True;TrustServerCertificate=True;Connect Timeout=8'
    $cn = New-Object System.Data.SqlClient.SqlConnection $cs; $cn.Open()
    $q = $cn.CreateCommand(); $q.CommandText = 'SELECT COUNT(*) FROM dbo.agent_messages WHERE delivered_at IS NULL'
    $n = [int]$q.ExecuteScalar(); $cn.Close()
    if ($n -le 5) { Ok ('队列在途 = ' + $n) } else { Bad ('队列积压 = ' + $n) }
} catch { Info '队列表不存在（未启用青鸟时可忽略）' }

Write-Output ('RESULT: ' + $(if ($fail -eq 0) { 'PASS' } else { 'FAIL' }))
if ($fail -gt 0) { exit 3 }
