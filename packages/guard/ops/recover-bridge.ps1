# 第一次用？先看 README 的「5 分钟跑起来」，再回来读这个脚本。
# recover-bridge.ps1 - 一键恢复 11 的青鸟入站桥（重启 DSH 并自动验证）
#
# 背景：2026-10-23 我用 plugin_manager 做 disable/enable 热切换，撞上
#   "webserver: duplicate exact route /agent/inbox" ⇒ 插件"路由在、注入坏"（入站 502）。
#   本进程内无法恢复，必须重启 DSH 让它重新挂载。
#
# 这个脚本把"重启 + 验证 + 留证"打包成一步，避免重启后又不知道好没好：
#   1) 记录重启前状态（青鸟 healthz / DSH 注入 / ARMED 时间）
#   2) 结束 DeepSeek Harness（仅本用户进程，带确认提示，除非 -Yes）
#   3) 等 8 秒后重新启动 DSH（路径由 -DshExe 或 DSH_EXE 指定）
#   4) 等 90 秒（插件挂载 + 端口就绪）
#   5) 跑 qingniao-verify.ps1 -Full，把结果写到 C:\dsh-mem\logs\recover-qingniao.log
#   6) 结果同时写库（ops_findings），并把关键行打到控制台
#
# 用法：
#   powershell -File C:\dsh-mem\ops\recover-bridge.ps1 -CheckOnly     # 只检查，不重启（默认建议先跑这个）
#   powershell -File C:\dsh-mem\ops\recover-bridge.ps1 -Yes           # 直接重启并验证
param(
    # DSH 安装路径：请按自己的环境传 -DshExe，或设置环境变量 DSH_EXE
    [string]$DshExe = $(if ($env:DSH_EXE) { $env:DSH_EXE } else { '' }),
    [switch]$CheckOnly,
    [switch]$Yes,
    [int]$WaitAfterStartSeconds = 90
)
$ErrorActionPreference = 'Continue'
$log = 'C:\dsh-mem\logs\recover-qingniao.log'
$verify = 'C:\dsh-mem\ops\qingniao-verify.ps1'
if (-not (Test-Path (Split-Path $log -Parent))) { New-Item -ItemType Directory -Path (Split-Path $log -Parent) -Force | Out-Null }
function Say([string]$m) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m
    Write-Host $line
    Add-Content -Path $log -Value $line -Encoding UTF8
}

Say ('=== recover-qingniao start (CheckOnly=' + [bool]$CheckOnly + ') ===')

# ---------- 1) 重启前状态 ----------
$before = & cmd.exe /c ('powershell -NoProfile -ExecutionPolicy Bypass -File "' + $verify + '" 2>&1') | Out-String
Say '--- BEFORE ---'
foreach ($ln in ($before -split "`r?`n")) { if ($ln -match '\[PASS\]|\[FAIL\]|summary:|RESULT:') { Say ('  ' + $ln.Trim()) } }

if ($CheckOnly) {
    Say 'CheckOnly: 未重启。若上面 "DSH 插件：POST /agent/inbox 注入成功" 是 FAIL，就运行 -Yes（或关掉窗口重开一次）'
    exit 0
}

# ---------- 2) 确认要重启 ----------
if (-not $Yes) {
    $ans = Read-Host '将结束并重启 DeepSeek Harness（当前会话会中断，但历史都保存在库里）。继续？输入 yes'
    if ($ans -notmatch '^(y|yes|是)$') { Say '已取消'; exit 0 }
}

# ---------- 3) 停止 ----------
$procs = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
Say ('found ' + $procs.Count + ' DeepSeek Harness process(es): ' + (($procs | ForEach-Object { $_.Id }) -join ','))
foreach ($p in $procs) { try { $p.CloseMainWindow() | Out-Null } catch {} }
Start-Sleep -Seconds 4
$left = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
foreach ($p in $left) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {} }
Start-Sleep -Seconds 4
Say ('remaining after stop: ' + @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue).Count)

# ---------- 4) 启动 ----------
if (-not (Test-Path $DshExe)) { Say ('ERROR: DSH exe 不存在: ' + $DshExe); exit 3 }
# 2026-10-23: 用"交互式任务"启动 DSH —— 否则 Start-Process 让 DSH 继承本脚本的控制台，
# 导致启动它的命令行窗口无法关闭（窗口关=DSH 死）。任务启动则 DSH 拥有独立控制台。
$launched = $false
try {
  $st = Get-ScheduledTask -TaskName 'DSH_StartInteractive' -ErrorAction SilentlyContinue
  if ($st) { Start-ScheduledTask -TaskName 'DSH_StartInteractive'; $launched = $true; Say 'started via scheduled task DSH_StartInteractive (detached console)' }
} catch { Say ('task start failed: ' + $_.Exception.Message.Split("`n")[0]) }
if (-not $launched) { Start-Process -FilePath $DshExe -WorkingDirectory (Split-Path $DshExe -Parent); Say 'started via Start-Process (fallback, console is attached)' }
Say ('started; waiting ' + $WaitAfterStartSeconds + 's for plugin mount ...')
Start-Sleep -Seconds $WaitAfterStartSeconds

# ---------- 5) 验证 ----------
$after = & cmd.exe /c ('powershell -NoProfile -ExecutionPolicy Bypass -File "' + $verify + '" -Full 2>&1') | Out-String
Say '--- AFTER ---'
foreach ($ln in ($after -split "`r?`n")) { if ($ln -match '\[PASS\]|\[FAIL\]|summary:|RESULT:') { Say ('  ' + $ln.Trim()) } }
$verdict = if ($after -match 'RESULT: PASS') { 'PASS' } else { 'FAIL' }
Say ('verdict: ' + $verdict)

# ---------- 6) 写库留证 ----------
try {
    Add-Type -AssemblyName System.Data
    $cfg = ([System.IO.File]::ReadAllText('C:\dsh-mem\dsh-mem.config.json', [System.Text.Encoding]::UTF8)) | ConvertFrom-Json
    $cs = 'Server=' + $cfg.server + ';Database=' + $cfg.database + ';TrustServerCertificate=True;Connect Timeout=20'
    if ($cfg.user -and $cfg.password) { $cs += ';User Id=' + $cfg.user + ';Password=' + $cfg.password } else { $cs += ';Integrated Security=True' }
    $cn = New-Object System.Data.SqlClient.SqlConnection $cs
    $cn.Open()
    $q = $cn.CreateCommand()
    $q.CommandText = @"
INSERT INTO dbo.ops_findings (node, kind, signature, count, severity, first_seen, last_seen)
VALUES ('NODE-A','qingniao-recover', @s, 1, @sev, SYSUTCDATETIME(), SYSUTCDATETIME())
"@
    $null = $q.Parameters.AddWithValue('@s', ('recover flow verdict=' + $verdict + ' (see ' + $log + ')'))
    $null = $q.Parameters.AddWithValue('@sev', $(if ($verdict -eq 'PASS') { 'info' } else { 'fail' }))
    $null = $q.ExecuteNonQuery()
    $cn.Close()
    Say 'recorded to dbo.ops_findings (kind=qingniao-recover)'
} catch { Say ('WARN: 写库失败: ' + $_.Exception.Message) }

if ($verdict -ne 'PASS') {
    Say 'FAIL: 仍未恢复。请把本日志的这一段发我（C:\dsh-mem\logs\recover-qingniao.log）'
    exit 3
}
# ---------- 7) HOTRELOAD-PROOF：证明"每请求重读令牌"真的生效 ----------
# 判据（能失败）：把令牌文件临时改成一个哨兵值，立即 POST /agent/inbox。
#   · 新版插件（每请求重读）⇒ 哨兵被接受 ⇒ 200/202（证明无需重启即可换令牌）
#   · 旧版插件（启动时缓存）⇒ 401/403（证明热加载没生效，仍需重启才能轮换令牌）
$tokFile = 'C:\dsh-mem\agent-bridge.token'
try {
    $orig = (Get-Content $tokFile -Raw -Encoding UTF8).Trim()
    $sentinel = 'SENTINEL-HOTRELOAD-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    [System.IO.File]::WriteAllText($tokFile, $sentinel, (New-Object System.Text.UTF8Encoding $false))
    Start-Sleep -Seconds 2
    $probeBody = '{"msgId":"' + [guid]::NewGuid().ToString() + '","from":"NODE-A","to":"11/selftest","delivery":"queue","text":"hotreload proof probe","hops":0}'
    $tmpP = Join-Path $env:TEMP ('hrp-' + [guid]::NewGuid().ToString('N') + '.json')
    [System.IO.File]::WriteAllText($tmpP, $probeBody, (New-Object System.Text.UTF8Encoding $false))
    $hdz = Invoke-RestMethod 'http://127.0.0.1:19387/healthz' -TimeoutSec 6
    $dshPort = [string]$hdz.dshPort
    $code = 0
    try {
        $resp = Invoke-WebRequest -Uri ('http://127.0.0.1:' + $dshPort + '/agent/inbox') -Method POST -Headers @{ authorization = 'Bearer ' + $sentinel } -ContentType 'application/json' -InFile $tmpP -TimeoutSec 10 -UseBasicParsing
        $code = [int]$resp.StatusCode
    } catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
    }
    Remove-Item $tmpP -Force -ErrorAction SilentlyContinue
    [System.IO.File]::WriteAllText($tokFile, $orig, (New-Object System.Text.UTF8Encoding $false))
    Start-Sleep -Seconds 2
    if ($code -ge 200 -and $code -lt 300) {
        Say ('HOTRELOAD-PROOF: PASS — 哨兵令牌被接受（HTTP ' + $code + '），说明插件每请求重读令牌，令牌轮换不再需要重启')
    } else {
        Say ('HOTRELOAD-PROOF: FAIL — 哨兵令牌被拒（HTTP ' + $code + '），说明仍是启动时缓存旧令牌；需要重启才能加载 hotreload 版')
    }
} catch {
    Say ('HOTRELOAD-PROOF: ERROR — ' + $_.Exception.Message)
    try { if ($orig) { [System.IO.File]::WriteAllText($tokFile, $orig, (New-Object System.Text.UTF8Encoding $false)) } } catch {}
}

# ---------- 8) POST-RESTART-E2E：重启后证明"跨机聊天真的通了" ----------
$e2eKey = 'POSTRESTART-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
try {
    $cfg2 = ([System.IO.File]::ReadAllText('C:\dsh-mem\dsh-mem.config.json', [System.Text.Encoding]::UTF8)) | ConvertFrom-Json
    $cs2 = 'Server=' + $cfg2.server + ';Database=' + $cfg2.database + ';TrustServerCertificate=True;Connect Timeout=20'
    if ($cfg2.user -and $cfg2.password) { $cs2 += ';User Id=' + $cfg2.user + ';Password=' + $cfg2.password } else { $cs2 += ';Integrated Security=True' }
    $cn2 = New-Object System.Data.SqlClient.SqlConnection $cs2
    $cn2.Open()
    $ins2 = $cn2.CreateCommand()
    $ins2.CommandText = "INSERT INTO dbo.agent_messages (msg_id, from_machine, to_machine, target, delivery, body, created_at, attempt_count) VALUES (NEWID(), 'NODE-A', 'NODE-B', 'NODE-B/agent-1', 'queue', @b, SYSUTCDATETIME(), 0)"
    $null = $ins2.Parameters.AddWithValue('@b', ('[' + $e2eKey + '] 重启后自动验收：11→17 聊天链路测试（收到请回 ACK）'))
    $null = $ins2.ExecuteNonQuery()
    $ok2 = $false
    for ($i = 0; $i -lt 24; $i++) {
        Start-Sleep -Seconds 5
        $chk2 = $cn2.CreateCommand()
        $chk2.CommandText = "SELECT delivered_at FROM dbo.agent_messages WHERE body LIKE @k"
        $null = $chk2.Parameters.AddWithValue('@k', ('%' + $e2eKey + '%'))
        $v2 = $chk2.ExecuteScalar()
        if ($v2 -and $v2 -isnot [System.DBNull]) { $ok2 = $true; break }
    }
    $cn2.Close()
    Say ('POST-RESTART-E2E: ' + $(if ($ok2) { 'PASS — 11→17 消息已投递（聊天链路通）' } else { 'FAIL — 2 分钟内未投递（聊天链路仍不通）' }))
} catch { Say ('POST-RESTART-E2E: ERROR — ' + $_.Exception.Message) }

# ---------- 9) 重启后规则复核（两条日志灯应转绿） ----------
try {
    $g = & powershell -NoProfile -ExecutionPolicy Bypass -File 'C:\dsh-mem\ops\guard-rules.ps1' 2>&1 | Out-String
    $fails = @(($g -split "`r?`n") | Where-Object { $_ -match '^\s*\[FAIL' })
    Say ('RULES: fails=' + $fails.Count)
    foreach ($f in $fails) { Say ('  ' + $f.Trim()) }
} catch { Say ('RULES: ERROR — ' + $_.Exception.Message) }

Say 'DONE: 入站桥已恢复。'
exit 0
