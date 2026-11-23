# [REFLECT-20261119] LLM 自动反思（记忆系统"使用层"）
# 读最近记忆 → 调 LLM（主 deepseek 官方，失败自动切火山 v2）→ 生成情绪价+处境的反思 → 写回 kind='reflection'
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File dsh-reflect.ps1 [-Limit 15]
param([int]$Limit = 15)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# ---- 读配置 + 主备密钥（deepseek 官方主 / 火山 v2 备）----
$cfg = Get-Content 'C:\dsh-mem\dsh-mem.config.json' -Raw | ConvertFrom-Json
$cs = "Server=$($cfg.server);Database=$($cfg.database);User Id=$($cfg.user);Password=$($cfg.password);Encrypt=False;TrustServerCertificate=True;Connect Timeout=20"
$cn = New-Object System.Data.SqlClient.SqlConnection $cs
$cn.Open()
$cmd = $cn.CreateCommand()
$cmd.CommandText = "SELECT name, secret FROM dbo.credentials WHERE is_active=1 AND name IN ('deepseek-api-key-2026-10','volc-ark-doubao-v2');"
$rd = $cmd.ExecuteReader()
$keyDs = ''; $keyVolc = ''
while ($rd.Read()) {
  if ($rd['name'] -eq 'deepseek-api-key-2026-10') { $keyDs = [string]$rd['secret'] }
  elseif ($rd['name'] -eq 'volc-ark-doubao-v2') { $keyVolc = [string]$rd['secret'] }
}
$rd.Close()
if (-not $keyDs -and -not $keyVolc) { $cn.Close(); Write-Host "  FAIL: 主备密钥都读不到"; exit 1 }

# ---- 读最近记忆（排除 reflection/compaction-summary，避免自我引用）----
$cmd.CommandText = "SELECT TOP (@n) id, kind, title FROM dbo.memories WHERE kind NOT IN ('reflection','compaction-summary') ORDER BY id DESC"
[void]$cmd.Parameters.AddWithValue('@n', $Limit)
$rd = $cmd.ExecuteReader()
$mems = @()
while ($rd.Read()) { $mems += ("- [" + $rd['id'] + "] " + $rd['kind'] + ": " + $rd['title']) }
$rd.Close()
# [MOOD-ENABLE-20261124] [OPENSOURCE-20261124] 漂移必须在 LLM 调用【之前】：原来这段在 L83（LLM 之后），
#   LLM 一失败 exit 1 就永远走不到 ⇒ agent_state 实测冻结 23 小时。
$moodDriftSql = "UPDATE dbo.agent_state SET value = CASE state_name " +
  "WHEN 'boredom' THEN CASE WHEN value + 0.0002 * DATEDIFF(MINUTE, updated_at, SYSUTCDATETIME()) > 1.0 THEN 1.0 ELSE value + 0.0002 * DATEDIFF(MINUTE, updated_at, SYSUTCDATETIME()) END " +
  "WHEN 'energy' THEN CASE WHEN value - 0.0001 * DATEDIFF(MINUTE, updated_at, SYSUTCDATETIME()) < 0.1 THEN 0.1 ELSE value - 0.0001 * DATEDIFF(MINUTE, updated_at, SYSUTCDATETIME()) END " +
  "ELSE value END, updated_at = SYSUTCDATETIME()"
try {
  $cmd. Parameters.Clear()
  $cmd.CommandText = $moodDriftSql
  $null = $cmd.ExecuteNonQuery()
} catch { Write-Host ("  NOTE 漂移失败（不阻断反思）: " + $_.Exception.Message.Split("`n")[0]) }

$cn.Close()
if (@($mems).Count -eq 0) { Write-Host "  没有可反思的记忆"; exit 1 }

# ---- 拼 prompt（让 LLM 严格只输出一行 JSON）----
$prompt = @"
你是记忆系统的反思引擎。下面是最近的记忆条目。请用中文写一段反思，严格只输出一行 JSON（不要任何多余文字、不要 markdown 代码块）：
{"valence":0到10的整数,"context":"一句处境或感受","reflection":"2到3句反思，说明这阶段在做什么、卡在哪、意义是什么"}

$($mems -join "`n")
"@

# ---- LLM 调用（body 必须 UTF8 bytes，避免 PS5.1 ANSI 把中文变问号）----
function Invoke-Chat([string]$url, [string]$key, [string]$model, [string]$content) {
  $bodyObj = @{ model = $model; messages = @(@{ role = 'user'; content = $content }); temperature = 0.6 } | ConvertTo-Json -Depth 6
  $bytes = [Text.Encoding]::UTF8.GetBytes($bodyObj)
  $resp = Invoke-WebRequest -Uri $url -Method Post -ContentType 'application/json; charset=utf-8' -Headers @{ Authorization = "Bearer $key" } -Body $bytes -TimeoutSec 120 -UseBasicParsing
  $json = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
  $obj = $json | ConvertFrom-Json
  return [string]$obj.choices[0].message.content
}

$reply = $null; $used = ''
try {
  $reply = Invoke-Chat 'https://api.deepseek.com/chat/completions' $keyDs 'deepseek-chat' $prompt
  $used = 'deepseek'
} catch {
  Write-Host ("  deepseek 失败: " + $_.Exception.Message + " → 切火山")
  try {
    $reply = Invoke-Chat 'https://ark.cn-beijing.volces.com/api/v3/chat/completions' $keyVolc 'deepseek-v4-1-flash' $prompt
    $used = 'volc-v2'
  } catch {
    Write-Host ("  FAIL: 主备都失败: " + $_.Exception.Message)
    exit 1
  }
}

# ---- 解析 JSON（去掉可能的 ```json 包裹）----
$reply = ([string]$reply).Trim()
$reply = $reply -replace '^```(json)?\s*', '' -replace '```\s*$', ''
$j = $reply | ConvertFrom-Json
$valence = [int]$j.valence
if ($valence -lt 0) { $valence = 0 }; if ($valence -gt 10) { $valence = 10 }
Write-Host ("  引擎: " + $used + "  情绪价: " + $valence)
Write-Host ("  处境: " + $j.context)
Write-Host ("  反思: " + $j.reflection)

# ---- 附加当前心境（mood 行为挂钩：情绪状态进入记忆流，agent 可感知）----
$cn3 = New-Object System.Data.SqlClient.SqlConnection $cs
$cn3.Open()
$c3 = $cn3.CreateCommand()
# [MOOD-DRIFT-20261121] 读 mood 前先按静默时间漂移（否则 mood 冻结在最后一次手动 mood 命令，反思读到旧值）
$c3.CommandText = "UPDATE dbo.agent_state SET value = CASE state_name WHEN 'boredom' THEN CASE WHEN value + 0.0002 * DATEDIFF(MINUTE, updated_at, SYSUTCDATETIME()) > 1.0 THEN 1.0 ELSE value + 0.0002 * DATEDIFF(MINUTE, updated_at, SYSUTCDATETIME()) END WHEN 'energy' THEN CASE WHEN value - 0.0001 * DATEDIFF(MINUTE, updated_at, SYSUTCDATETIME()) < 0.1 THEN 0.1 ELSE value - 0.0001 * DATEDIFF(MINUTE, updated_at, SYSUTCDATETIME()) END ELSE value END, updated_at = SYSUTCDATETIME()"
$null = $c3.ExecuteNonQuery()
$c3.CommandText = "SELECT state_name, value FROM dbo.agent_state ORDER BY state_name"
$r3 = $c3.ExecuteReader()
$moodParts = @()
while ($r3.Read()) { $moodParts += ($r3['state_name'] + "=" + [Math]::Round([double]$r3['value'], 2)) }
$r3.Close()
$cn3.Close()
$j.context = ([string]$j.context) + "；心境 " + ($moodParts -join '/')

# ---- 写回（复用 dsh-mem.ps1 save 的 valence/context 支持）----
$title = "反思 " + (Get-Date).ToString('MM-dd HH:mm') + " (" + $used + ")"
& 'C:\dsh-mem\dsh-mem.ps1' save -Title $title -Kind reflection -Valence $valence -Situation ([string]$j.context) -Body ([string]$j.reflection)
