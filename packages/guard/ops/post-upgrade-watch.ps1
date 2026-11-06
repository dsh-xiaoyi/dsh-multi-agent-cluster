# post-upgrade-watch.ps1 - [POST-UPGRADE-WATCH-20261106] 升级后两天值守巡检
# 每 30 分钟跑一次；只在异常时告警（队列投给主会话 + 告警日志），正常只写一行 HEALTH
# 自过期：首次运行记 ops\post-upgrade-watch.start；超过 2 天自动禁用 DSH_PostUpgradeWatch
param(
  [string]$LogPath='C:\dsh-mem\logs\post-upgrade-watch.log',
  [string]$AlertPath='C:\dsh-mem\logs\post-upgrade-watch.ALERTS.log',
  [string]$StatePath='C:\dsh-mem\ops\post-upgrade-watch.state.json',
  [string]$StartPath='C:\dsh-mem\ops\post-upgrade-watch.start',
  [switch]$NoAlert
)
$ErrorActionPreference='Continue'
$now=Get-Date
$anom=@()
$info=@()
function Add-A([string]$code,[string]$detail){ $script:anom += ($code + ':' + $detail) }
function Add-I([string]$code,[string]$detail){ $script:info += ($code + '=' + $detail) }

# 自过期
if(-not (Test-Path $StartPath)){ [IO.File]::WriteAllText($StartPath,$now.ToString('o'),(New-Object Text.UTF8Encoding($false))) }
$start=[datetime]::Parse([IO.File]::ReadAllText($StartPath,[Text.Encoding]::UTF8).Trim(),[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
$ageHours=($now - $start.ToLocalTime()).TotalHours
if($ageHours -gt 48 -and $ageHours -lt 600){
  & schtasks /Change /TN 'DSH_PostUpgradeWatch' /DISABLE 2>/dev/null | Out-Null
  Add-Content -LiteralPath $LogPath -Value ($now.ToString('yyyy-MM-dd HH:mm:ss') + ' EXPIRED age_h=' + [int]$ageHours + ' task disabled') -Encoding UTF8
  Write-Output ('RESULT: EXPIRED age_h=' + [int]$ageHours); exit 0
}

# 1) DSH 进程/端口
$procs=@(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
$port=@(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $procs.Id -contains $_.OwningProcess } | Select-Object -ExpandProperty LocalPort -Unique) | Select-Object -First 1
if(-not $port -and (Test-Path 'C:\dsh-mem\qingniao\dsh-port.txt')){ $port=(Get-Content 'C:\dsh-mem\qingniao\dsh-port.txt' -Raw).Trim() }
if($procs.Count -eq 0 -or -not $port){
  Start-Sleep -Seconds 5   # [DEBOUNCE-20261106] 瞬时取空不报，5 秒后复测
  $procs=@(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
  $port=@(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $procs.Id -contains $_.OwningProcess } | Select-Object -ExpandProperty LocalPort -Unique) | Select-Object -First 1
  if(-not $port -and (Test-Path 'C:\dsh-mem\qingniao\dsh-port.txt')){ $port=(Get-Content 'C:\dsh-mem\qingniao\dsh-port.txt' -Raw).Trim() }
}
if($procs.Count -eq 0){ Add-A 'DSH-DOWN' 'no process (2 samples)' } elseif(-not $port){ Add-A 'DSH-NOPORT' 'no listening port (2 samples)' } else { Add-I 'port' $port }

# 2) 桥插件版本
$idx='C:\dsh-mem\dsh-agent-bridge\index.mjs'
if(Test-Path $idx){
  $h=(Get-FileHash $idx -Algorithm SHA256).Hash.Substring(0,16)
  if($h -ne '6A77263125014DFC'){ Add-A 'INDEX-SHA' $h } else { Add-I 'index' $h }
} else { Add-A 'INDEX-MISSING' $idx }

# 3) 青鸟端口文件一致
$pf='C:\dsh-mem\qingniao\dsh-port.txt'
if(Test-Path $pf){
  $stored=(Get-Content $pf -Raw).Trim()
  if($port -and $stored -ne ([string]$port)){ Add-A 'QINGNIAO-PORT' ($stored + '!=' + $port) } else { Add-I 'qport' $stored }
} else { Add-A 'QPORT-MISSING' $pf }

# 4) 青鸟 relay 近 24h 成功率
$ql='C:\dsh-mem\qingniao\qingniao.log'
if(Test-Path $ql){
  $lines=Get-Content $ql -Encoding UTF8 -ErrorAction SilentlyContinue
  $rel=@($lines | Where-Object { $_ -match 'relay ' })
  $ok=0; $bad=0
  foreach($ln in $rel){
    $m=[regex]::Match($ln,'^(\S+)Z?\s+relay .*http=(\d{3})')
    if($m.Success){
      $t=[datetime]::MinValue
      $ok2=[datetime]::TryParse(($m.Groups[1].Value -replace 'Z$',''),[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AdjustToUniversal,[ref]$t)
      if($ok2){
        if(([datetime]::UtcNow - $t).TotalHours -le 24){
          if([int]$m.Groups[2].Value -ge 200 -and [int]$m.Groups[2].Value -lt 300){ $ok++ } elseif([int]$m.Groups[2].Value -ge 500){ $bad++ }
        }
      }
    }
  }
  if($bad -gt 0 -and $ok -eq 0){ Add-A 'RELAY-ALLFAIL' ('ok=0 5xx=' + $bad) } else { Add-I 'relay' ('ok=' + $ok + ' 5xx=' + $bad) }
}

# 5) 队列
$q="SET NOCOUNT ON; SELECT CAST((SELECT COUNT(*) FROM dbo.agent_messages WHERE delivered_at IS NULL AND terminal_at IS NULL) AS varchar(5)) + '|' + CAST((SELECT COUNT(*) FROM dbo.agent_messages WHERE terminal_at IS NOT NULL) AS varchar(5)) + '|' + CAST((SELECT COUNT(*) FROM dbo.agent_messages WHERE delivered_at IS NULL AND terminal_at IS NULL AND created_at < DATEADD(MINUTE,-10,SYSUTCDATETIME())) AS varchar(5));"
$qo=''
for($try=1;$try -le 3;$try++){
  $qo=((& sqlcmd -S localhost -E -I -W -h -1 -Q $q -d DSHMemory 2>&1 | Out-String) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
  if($qo -match '^\d+\|\d+\|\d+$'){ break }
  Start-Sleep -Seconds 2   # [DEBOUNCE-20261106] SQL 瞬时失败重试
}
if($qo -match '^(\d+)\|(\d+)\|(\d+)$'){ if([int]$Matches[3] -gt 0){ Add-A 'QUEUE-STALE' ('pending>10min=' + $Matches[3]) } else { Add-I 'queue' ('pending=' + $Matches[1] + ' terminal=' + $Matches[2]) } } else { Add-A 'QUEUE-QFAIL' ([string]$qo).Substring(0,[Math]::Min(60,([string]$qo).Length)) }

# 6) 效果队列 failed
$e="SET NOCOUNT ON; SELECT CAST(COUNT(*) AS varchar(5)) FROM dbo.agent_effects WHERE status='failed' AND [key] NOT LIKE 'bf-bad-%';"
$eo=((& sqlcmd -S localhost -E -I -W -h -1 -Q $e -d DSHMemory 2>&1 | Out-String) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
if([int]$eo -gt 0){ Add-I 'effects-failed' $eo }

# 7) 三个任务状态
foreach($tn in 'DSH_QingniaoPortCheck','DSH_AgentEffectsRun','DSH_ResumeInterrupted','DSH_CoreRulesCache'){
  $t=Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
  if(-not $t){ Add-A ('TASK-MISSING') $tn; continue }
  $i=Get-ScheduledTaskInfo -TaskName $tn -ErrorAction SilentlyContinue
  if($t.State -eq 'Disabled'){ Add-A 'TASK-DISABLED' $tn }
  elseif($i.LastTaskResult -ne 0){ Add-A 'TASK-RC' ($tn + '=' + $i.LastTaskResult) }
}

# 8) 续跑闸/投递（近 24h）
$rl='C:\dsh-mem\logs\resume-interrupted.log'
if(Test-Path $rl){
  $g=@(Get-Content $rl -Encoding UTF8 -Tail 500 | Where-Object { $_ -match 'RECOVERY-GATE' }).Count
  $inj=@(Get-Content $rl -Encoding UTF8 -Tail 500 | Where-Object { $_ -match 'RECOVERY-NOTE v1' }).Count
  Add-I 'resume' ('gated=' + $g + ' notes=' + $inj)
  if($inj -gt 0){ Add-I 'resume-injected' $inj }
}

# 9) spool 热写文件大小
$sp='C:\dsh-mem\spool\hot.jsonl'
if(Test-Path $sp){
  $mb=[math]::Round((Get-Item $sp).Length/1MB,1)
  if($mb -gt 800){ Add-A 'SPOOL-BIG' ($mb.ToString() + 'MB') } else { Add-I 'spool' ($mb.ToString() + 'MB') }
}

# 9a) [RULES-CACHE-FRESH-20261106] core-rules.json 新鲜度：>15 分钟未刷新 ⇒ 注入会回落 3.8s 慢路径（11/ops 建议的失效告警）
$cf='C:\dsh-mem\spool\core-rules.json'
if(Test-Path $cf){
  $ageM=[math]::Round(((Get-Date) - (Get-Item $cf).LastWriteTime).TotalMinutes,1)
  if($ageM -gt 15){ Add-A 'RULES-CACHE-STALE' ($ageM.ToString() + 'min') } else { Add-I 'rcache' ($ageM.ToString() + 'min') }
} else { Add-A 'RULES-CACHE-MISSING' $cf }
# 9b) [COMMIT-CHECK-20261106] 提交内存占比 >90% ⇒ 异常（某节点曾 94.7% 压崩 DSH 与本机虚拟化层）
try{
  $commit=((Get-Counter '\Memory\% Committed Bytes In Use' -ErrorAction Stop).CounterSamples[0].CookedValue)
  if($commit -gt 90){ Add-A 'COMMIT-HIGH' ([math]::Round($commit,1).ToString() + '%') } else { Add-I 'commit' ([math]::Round($commit,1).ToString() + '%') }
} catch { Add-I 'commit' 'n/a' }
# 10) 桥日志近 1h 是否有 401/403/404 异常
$bl='C:\dsh-mem\dsh-agent-bridge\bridge.log'
if(Test-Path $bl){
  $cut=[datetime]::UtcNow.AddMinutes(-5)
  $recent=@(Get-Content $bl -Encoding UTF8 -Tail 400 | Where-Object { if($_ -match 'refused|unauthorized'){ $ts=[datetime]::MinValue; $mm=[regex]::Match($_,'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})'); if($mm.Success -and [datetime]::TryParseExact($mm.Groups[1].Value,'yyyy-MM-ddTHH:mm:ss',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AdjustToUniversal,[ref]$ts)){ return ($ts -gt $cut) } }; return $false })
  if($recent.Count -gt 0){ Add-A 'BRIDGE-REFUSE-5M' ('n=' + $recent.Count) } else { Add-I 'bridge-refuse-5m' 0 }
}

$anomCount=$anom.Count
$line=$now.ToString('yyyy-MM-dd HH:mm:ss') + ' RESULT: anomalies=' + $anomCount + ' checks=10 ｜ ' + ($(if($info.Count){ 'INFO ' + ($info -join ' ') } else {''})) + $(if($anomCount){ ' ｜ ALERT ' + ($anom -join ' ; ') } else {''})
Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
Write-Output ('RESULT: anomalies=' + $anomCount + ' alerts=' + ($anom -join ';'))

if($anomCount -gt 0 -and -not $NoAlert){
  $fp=(($anom | ForEach-Object { ($_ -split ':')[0] }) | Sort-Object -Unique) -join ','
  $st=@{}
  if(Test-Path $StatePath){ try { $st=(Get-Content $StatePath -Raw | ConvertFrom-Json).alerts } catch {} }
  $lastKey=$null; $lastTime=[datetime]::MinValue
  if($st -is [psobject] -and $st.PSObject.Properties.Name -contains $fp){ $lastTime=[datetime]$st.$fp }
  if(($now - $lastTime).TotalHours -ge 6){
    Add-Content -LiteralPath $AlertPath -Value ($now.ToString('yyyy-MM-dd HH:mm:ss') + ' FINGERPRINT=' + $fp + ' ｜ ' + ($anom -join ' ; ')) -Encoding UTF8
    $body='[POST-UPGRADE-WATCH] 异常 ' + $anomCount + ' 项：' + ($anom -join ' ; ') + '（' + $now.ToString('yyyy-MM-dd HH:mm') + '）'
    $esc=$body.Replace("'","''")
    $sql="SET NOCOUNT ON; INSERT INTO dshmemory.dbo.agent_messages (msg_id, from_machine, to_machine, target, delivery, body, created_at, attempt_count) VALUES (NEWID(), N'<HUB>', N'<HUB>', N'<HUB>/agent-1', N'queue', N'" + $esc + "', SYSUTCDATETIME(), 0);"
    & sqlcmd -S localhost -E -I -b -Q $sql 2>&1 | Out-Null
    $newSt=@{ alerts=@{} }
    if($st -is [psobject]){ foreach($p in $st.PSObject.Properties){ $newSt.alerts[$p.Name]=$p.Value } }
    $newSt.alerts[$fp]=$now.ToString('o')
    ($newSt | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $StatePath -Encoding UTF8
  }
}
exit 0