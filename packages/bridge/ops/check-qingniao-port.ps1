# [QINGNIAO-PORT-GUARD-20261106] 青鸟 relay 端口守卫（可自愈）：dsh-port.txt 与实际监听不一致 ⇒ FAIL；-AutoFix 则写回并记 FIXED
# [PORTPATH-DERIVE-20261106] 默认路径按本机推导：优先 C:\dsh-mem\qingniao，其次 G:\deepseek\qingniao（另一种安装布局）
param([string]$PortFile='', [string]$LogPath='C:\dsh-mem\logs\qingniao-port-guard.log', [switch]$AutoFix)
$ErrorActionPreference='Continue'
# [LOG-DEFAULT-20261106] 兜底：某些调用路径下  会为空 ⇒ 显式回落到默认，避免 Add-Content 绑空报错
if([string]::IsNullOrWhiteSpace($LogPath)){ $LogPath='C:\dsh-mem\logs\qingniao-port-guard.log' }
if([string]::IsNullOrWhiteSpace($PortFile)){
  if(Test-Path 'C:\dsh-mem\qingniao\dsh-port.txt'){ $PortFile='C:\dsh-mem\qingniao\dsh-port.txt' }
  elseif(Test-Path 'G:\deepseek\qingniao\dsh-port.txt'){ $PortFile='G:\deepseek\qingniao\dsh-port.txt' }
}
if([string]::IsNullOrWhiteSpace($PortFile) -or -not (Test-Path $PortFile)){ $line=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' FAIL reason=no-port-file'; Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8; Write-Output ('RESULT: FAIL reason=no-port-file'); exit 2 }
$stored=(Get-Content $PortFile -Raw).Trim()
$procs=@(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
$actual=@(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $procs.Id -contains $_.OwningProcess } | Select-Object -ExpandProperty LocalPort -Unique) | Select-Object -First 1
if(-not $actual){ Start-Sleep -Seconds 5; $procs=@(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue); $actual=@(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $procs.Id -contains $_.OwningProcess } | Select-Object -ExpandProperty LocalPort -Unique) | Select-Object -First 1 }   # [LISTENER-RETRY-20261106] 瞬时取空重试一次
if(-not $actual){ $line=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' FAIL reason=no-dsh-listener'; Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8; Write-Output ('RESULT: FAIL reason=no-dsh-listener'); exit 2 }
if($stored -ne ([string]$actual)){
  if($AutoFix){
    [IO.File]::WriteAllText($PortFile, ([string]$actual), (New-Object Text.UTF8Encoding($false)))
    $line=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' FIXED ' + $stored + '->' + $actual
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    Write-Output ('RESULT: FIXED stored_old=' + $stored + ' actual=' + $actual); exit 0
  } else {
    $line=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' FAIL stored=' + $stored + ' actual=' + $actual
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    Write-Output ('RESULT: FAIL stored=' + $stored + ' actual=' + $actual); exit 2
  }
}
$listening=[bool](Get-NetTCPConnection -State Listen -LocalPort ([int]$stored) -ErrorAction SilentlyContinue)
if(-not $listening){ Write-Output ('RESULT: FAIL stored=' + $stored + ' not-listening'); exit 2 }
$lastLog = if(Test-Path $LogPath){ (Get-Content $LogPath -Encoding UTF8 -Tail 1) } else { '' }
$needLog = ($lastLog -notmatch (' OK stored=' + [regex]::Escape([string]$stored) + ' actual=')) -or ((Get-Date).Hour -eq 0 -and $lastLog -notmatch ((Get-Date).ToString('yyyy-MM-dd')))
if($needLog){ Add-Content -LiteralPath $LogPath -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' OK stored=' + $stored + ' actual=' + $actual + ' listening=True') -Encoding UTF8 }   # [HEARTBEAT-20261106] 状态不变不刷屏，但状态变化必写 + 每天 0 点必写
Write-Output ('RESULT: OK stored=' + $stored + ' actual=' + $actual); exit 0