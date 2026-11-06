# [RESOURCE-GATE-20261106] 注册"吃资源"的计划任务前必须先跑一次；任一超阈 => DENY 并退出 3
# 背景：2026-11-06 18:33 某节点在提交内存 94.7% 时注册全表查询任务 => Commit 打满 => DSH+VMware 崩溃
# 闸门：百分比 + 余量（余量取"绝对值下限"与"Commit Limit 比例"的较大者，防止大机器被百分比放宽）
#   小机器 Commit Limit 只有 ~49GB、大机器 ~157GB => 单用固定 20GB 余量会把小机器永久判红，故用 max()
param(
  [double]$CommitPctMax = 90,
  [double]$AvailMinGB = 8,
  [double]$AvailPctOfLimitMin = 15,
  [double]$FreePhysMinGB = 2,
  [double]$DiskFreeMinGB = 5,
  [string]$Disk = 'C'
)
$ErrorActionPreference='Continue'
$reasons=@()
$pct=$null; $usedGB=$null; $limitGB=$null; $availGB=$null
try {
  $pct=((Get-Counter '\Memory\% Committed Bytes In Use' -ErrorAction Stop).CounterSamples[0].CookedValue)
  $cb=((Get-Counter '\Memory\Committed Bytes' -ErrorAction Stop).CounterSamples[0].CookedValue)
  $cl=((Get-Counter '\Memory\Commit Limit' -ErrorAction Stop).CounterSamples[0].CookedValue)
  if($cb){ $usedGB=[math]::Round($cb/1GB,1) }
  if($cl){ $limitGB=[math]::Round($cl/1GB,1) }
  if($cl -and $cb){ $availGB=[math]::Round(($cl-$cb)/1GB,1) }
} catch { }
$availFloor = $AvailMinGB
if($limitGB){ $availFloor = [math]::Round([math]::Max($AvailMinGB, $limitGB*$AvailPctOfLimitMin/100),1) }
if($null -eq $pct){ $reasons += 'commit-unreadable' }
else {
  if($pct -gt $CommitPctMax){ $reasons += ('pct=' + [math]::Round($pct,1) + '% > ' + $CommitPctMax + '%') }
  if($null -ne $availGB -and $availGB -lt $availFloor){ $reasons += ('avail=' + $availGB + 'GB < ' + $availFloor + 'GB') }
}
$os=Get-CimInstance Win32_OperatingSystem
$freeMB=[double]$os.FreePhysicalMemory/1024
if($freeMB -lt ($FreePhysMinGB*1024)){ $reasons += ('freephys=' + [math]::Round($freeMB/1024,1) + 'GB < ' + $FreePhysMinGB + 'GB') }
$ld=Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + $Disk + ":'") -ErrorAction SilentlyContinue
$diskFreeGB = if($ld){ [math]::Round(($ld.FreeSpace/1GB),1) } else { 'n/a' }
if($ld -and ([double]$ld.FreeSpace/1GB) -lt $DiskFreeMinGB){ $reasons += ('disk' + $Disk + '=' + $diskFreeGB + 'GB < ' + $DiskFreeMinGB + 'GB') }

$verdict = if($reasons.Count -eq 0){ 'ALLOW' } else { 'DENY' }
$line=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' RESULT: ' + $verdict +
  ' pct=' + $(if($null -ne $pct){[math]::Round($pct,1)}else{'n/a'}) + '%' +
  ' used=' + $(if($null -ne $usedGB){$usedGB}else{'n/a'}) + 'GB' +
  ' limit=' + $(if($null -ne $limitGB){$limitGB}else{'n/a'}) + 'GB' +
  ' avail=' + $(if($null -ne $availGB){$availGB}else{'n/a'}) + 'GB' +
  ' avail_floor=' + $availFloor + 'GB' +
  ' freephys=' + [math]::Round($freeMB/1024,1) + 'GB disk' + $Disk + '=' + $diskFreeGB + 'GB' +
  ' ｜ ' + ($reasons -join ' ; ')
New-Item -ItemType Directory -Path 'C:\dsh-mem\logs' -Force | Out-Null
Add-Content -LiteralPath 'C:\dsh-mem\logs\resource-gate.log' -Value $line -Encoding UTF8
Write-Output $line
if($verdict -eq 'ALLOW'){ exit 0 } else { exit 3 }