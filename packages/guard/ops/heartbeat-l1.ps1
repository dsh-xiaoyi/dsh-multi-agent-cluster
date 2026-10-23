# heartbeat-l1.ps1 - 跨机互监 L1（进程级心跳）：直连对端的青鸟 /healthz 与 DSH 端口
#
# 为什么需要 L1：现有的看门狗与规则全靠数据库汇总，DB 或中枢一挂就"全体失明"。
# L1 是点对点直连，不经中枢、不依赖 1433，所以 DB 挂了仍然能判断"对端机器/桥是否活着"。
#
# 注意（vNext 设计约束）：L1 只能证明"HTTP 端点活着"，**不能证明"智能体能用"**。
# 僵尸实例（插件活着、会话未挂载）会通过 L1。真正证明"能干活"的是 L2（nonce 挑战），另做。
#
# 输出：dbo.sec_heartbeat(machine, target, ts, l1_ok, latency_ms, detail)
param(
    [string]$ConfigPath = 'C:\dsh-mem\dsh-mem.config.json',
    [string]$Peers = 'NODE-B=192.0.2.17,NODE-C=192.0.2.18',
    [int]$TimeoutSec = 4,
    [switch]$Quiet
)
$ErrorActionPreference = 'Continue'
function Out1($m) { if (-not $Quiet) { Write-Output ([string]$m) } }

$self = $env:COMPUTERNAME
$results = @()
foreach ($pair in $Peers.Split(',')) {
    $kv = $pair.Split('=', 2)
    if ($kv.Count -ne 2) { continue }
    $name = $kv[0].Trim(); $ip = $kv[1].Trim()

    # 1) 青鸟 exe 健康端点（固定 19387）
    $l1 = $false; $lat = $null; $detail = ''
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-WebRequest -Uri ('http://' + $ip + ':19387/healthz') -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        $l1 = ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300)
        $detail = 'healthz=' + $r.StatusCode
    } catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        $detail = 'healthz=ERR(' + $code + ')'
        # 401/403 也算"端点活着"（鉴权拒绝证明服务在）
        if ($code -eq 401 -or $code -eq 403) { $l1 = $true }
    }
    $sw.Stop(); $lat = [int]$sw.ElapsedMilliseconds

    $results += [pscustomobject]@{ target = $name; ip = $ip; ok = $l1; latency = $lat; detail = $detail }
    Out1 (('{0,-10} {1,-14} l1={2,-5} {3}ms  {4}') -f $name, $ip, $l1, $lat, $detail)
}

# 落库（尽量；DB 不可用不影响 L1 判定本身）
try {
    Add-Type -AssemblyName System.Data
    $cfg = ([System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)) | ConvertFrom-Json
    $cs = 'Server=' + $cfg.server + ';Database=' + $cfg.database + ';TrustServerCertificate=True;Connect Timeout=10'
    if ($cfg.user -and $cfg.password) { $cs += ';User Id=' + $cfg.user + ';Password=' + $cfg.password } else { $cs += ';Integrated Security=True' }
    $cn = New-Object System.Data.SqlClient.SqlConnection $cs
    $cn.Open()
    $ddl = $cn.CreateCommand()
    $ddl.CommandText = @"
IF OBJECT_ID('dbo.sec_heartbeat','U') IS NULL
CREATE TABLE dbo.sec_heartbeat (
  id bigint IDENTITY PRIMARY KEY,
  machine nvarchar(64), target nvarchar(64), ip nvarchar(64),
  ts datetime2 NOT NULL DEFAULT SYSUTCDATETIME(),
  l1_ok bit, latency_ms int, detail nvarchar(200)
);
"@
    $null = $ddl.ExecuteNonQuery()
    foreach ($r in $results) {
        $q = $cn.CreateCommand()
        $q.CommandText = "INSERT INTO dbo.sec_heartbeat (machine,target,ip,l1_ok,latency_ms,detail) VALUES (@m,@t,@i,@o,@l,@d)"
        $null = $q.Parameters.AddWithValue('@m', $self)
        $null = $q.Parameters.AddWithValue('@t', $r.target)
        $null = $q.Parameters.AddWithValue('@i', $r.ip)
        $null = $q.Parameters.AddWithValue('@o', [bool]$r.ok)
        $null = $q.Parameters.AddWithValue('@l', [int]$r.latency)
        $null = $q.Parameters.AddWithValue('@d', [string]$r.detail)
        $null = $q.ExecuteNonQuery()
    }
    $cn.Close()
    Out1 'written to dbo.sec_heartbeat'
} catch {
    Out1 ('db write skipped: ' + $_.Exception.Message.Split("`n")[0])
}

$bad = @($results | Where-Object { -not $_.ok }).Count
Out1 ('peers=' + $results.Count + ' unreachable=' + $bad)
if ($bad -gt 0) { Out1 'RESULT: PARTIAL'; exit 0 }  # L1 不可达不等于失败（对端可能关机），交给规则判窗口
Out1 'RESULT: PASS'
