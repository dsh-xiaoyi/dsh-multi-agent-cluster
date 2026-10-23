# 第一次用？先看 README 的「5 分钟跑起来」，再回来读这个脚本。
# memory-audit.ps1 - 11 本机"失忆"第二轮深检（比第一轮多查：配对、序号、重复、归属、向量模型、检索抽检）
# 输出 PASS/FAIL 明细 + 退出码（0 全过 / 3 有问题），便于守卫复用
param(
    [string]$ConfigPath = 'C:\dsh-mem\dsh-mem.config.json',
  # 可选：参与"文档是否登记"检查的目录；留空则跳过该项（开源环境各自不同）
  [string]$DocsRoot = '',
    [int]$SearchSamples = 5
)
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Data
$cfg = ([System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)) | ConvertFrom-Json
$cs = 'Server=' + $cfg.server + ';Database=' + $cfg.database + ';TrustServerCertificate=True;Connect Timeout=20'
if ($cfg.user -and $cfg.password) { $cs += ';User Id=' + $cfg.user + ';Password=' + $cfg.password } else { $cs += ';Integrated Security=True' }
$cn = New-Object System.Data.SqlClient.SqlConnection $cs
$cn.Open()
$results = New-Object System.Collections.Generic.List[object]
function Chk([string]$name, [bool]$ok, [string]$detail = '') {
    $results.Add([pscustomobject]@{ name = $name; ok = $ok; detail = $detail })
    Write-Output (($(if ($ok) { '[PASS] ' } else { '[FAIL] ' })) + $name + '  ' + $detail)
}
function Scalar([string]$sql) { $q = $cn.CreateCommand(); $q.CommandText = $sql; $q.CommandTimeout = 180; return $q.ExecuteScalar() }
function Rows([string]$sql) { $q = $cn.CreateCommand(); $q.CommandText = $sql; $q.CommandTimeout = 180; $d = New-Object System.Data.DataTable; $d.Load($q.ExecuteReader()); return , $d }

Write-Output '=== A) 消息规模与归属 ==='
$msgs = [int](Scalar 'SELECT COUNT(*) FROM dbo.messages')
$sess = [int](Scalar 'SELECT COUNT(DISTINCT session_id) FROM dbo.messages')
Chk 'messages/sessions 存在' (($msgs -gt 30000) -and ($sess -gt 30)) ('msgs=' + $msgs + ' sessions=' + $sess)

$orphSess = [int](Scalar "SELECT COUNT(*) FROM dbo.messages m WHERE NOT EXISTS (SELECT 1 FROM dbo.sessions s WHERE s.session_id=m.session_id)")
Chk '消息都有对应会话元数据（无孤儿消息）' ($orphSess -eq 0) ('orphans=' + $orphSess)

Write-Output '=== B) 序号连续性 / 重复 ==='
$dup = [int](Scalar "SELECT COUNT(*) FROM (SELECT session_id, seq, COUNT(*) c FROM dbo.messages GROUP BY session_id, seq HAVING COUNT(*)>1) x")
Chk '无重复 (session_id, seq)' ($dup -eq 0) ('dup_groups=' + $dup)

# seq 是会话文件里的**原始事件索引**：我们只导入 user/assistant/tool_call/tool_result，
# 其余事件（usage/status/thinking/delta 等）不落库 => seq 必然有间隔。这**不是**记忆丢失。
$gaps = 0
$g = Rows @"
;WITH s AS (
  SELECT session_id, MIN(seq) AS lo, MAX(seq) AS hi, COUNT(*) AS n
  FROM dbo.messages GROUP BY session_id
)
SELECT TOP 6 session_id, lo, hi, n, (hi - lo + 1 - n) AS missing FROM s WHERE (hi - lo + 1 - n) > 0 ORDER BY missing DESC
"@
foreach ($r in $g.Rows) { $gaps += [int]$r['missing'] }
Chk 'seq 无重复且可解释（空洞=被过滤的事件类型，说明性）' ($dup -eq 0) ('dup=0 gap_by_design=' + $gaps + ' 受影响会话=' + $g.Rows.Count)

Write-Output '=== C) 工具调用/结果配对 ==='
# 用**会话级**统计 + **顺序**判据（turn 级配对是错的：turn 按用户消息切分，一次 turn 里可能多次工具往返）
$callN = [int](Scalar "SELECT COUNT(*) FROM dbo.messages WHERE role='tool_call'")
$resultN = [int](Scalar "SELECT COUNT(*) FROM dbo.messages WHERE role='tool_result'")
$skew = if ($callN -gt 0) { [math]::Round($resultN * 1.0 / $callN, 4) } else { 0 }
Chk 'tool_result/tool_call 总量接近（0.95–1.10）' (($skew -ge 0.95) -and ($skew -le 1.10)) ('calls=' + $calls + ' results=' + $results + ' ratio=' + $skew)
$orderBad = [int](Scalar "SELECT COUNT(*) FROM dbo.messages tr WHERE tr.role='tool_result' AND NOT EXISTS (SELECT 1 FROM dbo.messages tc WHERE tc.session_id=tr.session_id AND tc.role='tool_call' AND tc.seq < tr.seq)")
Chk '无"先结果后调用"的顺序颠倒（0）' ($orderBad -eq 0) ('order_violations=' + $orderBad)

Write-Output '=== D) 空内容 / 截断 / 脱敏 ==='
$emptyMark = [int](Scalar "SELECT COUNT(*) FROM dbo.messages WHERE CHARINDEX('[assistant: tool-call only]', text)>0 OR CHARINDEX('[tool_result: empty]', text)>0")
Chk '空内容保真标记存在（>1000）' ($emptyMark -gt 1000) ('markers=' + $emptyMark)
$truncTail = [int](Scalar "SELECT COUNT(*) FROM dbo.messages WHERE text LIKE '%...[truncated]'")
Chk '真截断标记（≤5）' ($truncTail -le 5) ('tail_truncated=' + $truncTail)
$capHit = [int](Scalar "SELECT COUNT(*) FROM dbo.messages WHERE text LIKE '%truncated at 64000 chars%' OR text LIKE '%truncated at 8000 chars%'")
Chk '命中长度上限的行（说明性，≤200）' ($capHit -le 200) ('cap_hits=' + $capHit)

Write-Output '=== E) 向量：覆盖 / 模型一致 / 孤儿 ==='
# 注意：「未向量化」≠「丢失」。占位行（[assistant: tool-call only] / [tool_result: empty]）与
# 极短文本（<3 字符）按设计不嵌入 —— 它们没有语义可嵌入。真正该看的是"普通行的缺口"。
# 实时尾巴：比"已向量化最新消息时间"更新的消息必然还没嵌入（嵌入任务按批跑）
$maxEmb = Scalar "SELECT MAX(m.created_at) FROM dbo.embeddings e JOIN dbo.messages m ON m.id=e.item_id WHERE e.item_type='message' AND e.model='bge-m3'"
$tail = 0
if ($maxEmb) {
    $qTail = $cn.CreateCommand()
    $qTail.CommandText = "SELECT COUNT(*) FROM dbo.messages WHERE created_at > @t"
    $null = $qTail.Parameters.AddWithValue('@t', [datetime]$maxEmb)
    $tail = [int]$qTail.ExecuteScalar()
}
$gapAll = [int](Scalar "SELECT COUNT(*) FROM dbo.messages m WHERE NOT EXISTS (SELECT 1 FROM dbo.embeddings e WHERE e.item_type='message' AND e.item_id=m.id AND e.model='bge-m3')")
$gapPlaceholder = [int](Scalar "SELECT COUNT(*) FROM dbo.messages m WHERE NOT EXISTS (SELECT 1 FROM dbo.embeddings e WHERE e.item_type='message' AND e.item_id=m.id AND e.model='bge-m3') AND (text LIKE '%[assistant: tool-call only]%' OR text LIKE '%[tool_result: empty]%' OR LEN(ISNULL(text,''))<3)")
$gapReal = $gapAll - $gapPlaceholder
Chk '普通行向量覆盖缺口（排除占位行与实时尾巴；≤50）' (($gapReal - $tail) -le 50) ('gap_real=' + $gapReal + ' placeholder_by_design=' + $gapPlaceholder + ' total=' + $gapAll)
$orph = [int](Scalar "SELECT COUNT(*) FROM dbo.embeddings e WHERE (e.item_type='message' AND NOT EXISTS (SELECT 1 FROM dbo.messages m WHERE m.id=e.item_id)) OR (e.item_type='memory' AND NOT EXISTS (SELECT 1 FROM dbo.memories k WHERE k.id=e.item_id))")
Chk '孤儿向量（0）' ($orph -eq 0) ('orphans=' + $orph)
$models = Rows "SELECT model, dim, COUNT(*) n FROM dbo.embeddings GROUP BY model, dim ORDER BY n DESC"
$modelDesc = (($models.Rows | ForEach-Object { [string]$_['model'] + '/' + [string]$_['dim'] + ':' + [string]$_['n'] }) -join ' ')
$multiModel = $models.Rows.Count -gt 1
Chk '向量模型/维度一致（单一 model+dim）' (-not $multiModel) ($modelDesc)

Write-Output '=== F) 记忆质量 ==='
$memEmpty = [int](Scalar "SELECT COUNT(*) FROM dbo.memories WHERE LEN(ISNULL(title,''))=0 OR LEN(ISNULL(body,''))=0")
Chk '记忆标题/正文非空（≤5 例外）' ($memEmpty -le 5) ('empty=' + $memEmpty)
# 同一会话会被多次压缩 => 同标题不同正文是正常；只有"同标题+同正文"才是真重复
$dupChk = [int](Scalar "SELECT COUNT(*) FROM (SELECT title, CONVERT(varchar(32),HASHBYTES('MD5',body),2) AS h, COUNT(*) n FROM dbo.memories WHERE kind='checkpoint' GROUP BY title, CONVERT(varchar(32),HASHBYTES('MD5',body),2) HAVING COUNT(*)>1) x")
Chk '真重复 checkpoint 组（同标题+同正文，0 容忍）' ($dupChk -eq 0) ('dup_groups=' + $dupChk)
$kinds = Rows "SELECT kind, COUNT(*) n FROM dbo.memories GROUP BY kind ORDER BY n DESC"
Chk '记忆有分类（kind 种类 >3）' ($kinds.Rows.Count -gt 3) ((($kinds.Rows | ForEach-Object { [string]$_['kind'] + ':' + [string]$_['n'] }) -join ' '))

Write-Output '=== G) 产物台账覆盖 ==='
$arts = [int](Scalar 'SELECT COUNT(*) FROM dbo.artifacts')
$artsNewestH = Scalar 'SELECT DATEDIFF(hour, MAX(last_seen), SYSUTCDATETIME()) FROM dbo.artifacts'
Chk 'artifacts 非空且最新登记 <24h' (($arts -gt 700) -and ([int]$artsNewestH -lt 24)) ('arts=' + $arts + ' newest_age_h=' + $artsNewestH)
$mdFiles = @(if ($DocsRoot -and (Test-Path $DocsRoot)) { Get-ChildItem $DocsRoot -File -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 2KB } } else { @() })
$reg = Rows 'SELECT path FROM dbo.artifacts'
$regSet = @{}; foreach ($r in $reg.Rows) { $regSet[[string]$r['path']] = $true }
$unreg = @($mdFiles | Where-Object { -not $regSet.ContainsKey($_.FullName) })
Chk ('文档目录下的 md 均已登记 artifacts（目录: ' + $DocsRoot + '）') ($unreg.Count -eq 0) ('md=' + $mdFiles.Count + ' unregistered=' + $unreg.Count)

Write-Output '=== H) 检索抽检（随机记忆能否被搜索命中）==='
$sample = Rows ("SELECT TOP " + $SearchSamples + " id, title FROM dbo.memories WHERE LEN(ISNULL(body,''))>50 ORDER BY NEWID()")
$hitOk = 0; $hitTotal = 0
foreach ($r in $sample.Rows) {
    $hitTotal++
    $id = [string]$r['id']
    # 2026-10-23 修：旧写法把片段里的换行删掉再去原文里搜 -> 必然搜不到（偶发红的真因）
    # 现在取窗口里的「最长无空白片段」作为检索词，原文不做任何处理
    $win = [string](Scalar ("SELECT SUBSTRING(body, 25, 60) FROM dbo.memories WHERE id=" + $id))
    $parts = @(($win -split '\s+') | Where-Object { $_.Length -ge 6 })
    if ($parts.Count -eq 0) { continue }
    $frag = ($parts | Sort-Object Length -Descending | Select-Object -First 1)
    $found = Scalar ("SELECT COUNT(*) FROM dbo.memories WHERE CHARINDEX(N'" + ($frag -replace "'", "''") + "', body) > 0")
    if ([int]$found -gt 0) { $hitOk++ }
}
if ($hitTotal -gt 0) { Chk '随机记忆片段可被检索到（SQL 层）' ($hitOk -eq $hitTotal) ('hit ' + $hitOk + '/' + $hitTotal) }

Write-Output '=== I) 表体积与备份 ==='
$sz = Rows @"
SELECT ROUND(SUM(used_page_count)*8.0/1024,1) AS mb, OBJECT_NAME(object_id) AS t
FROM sys.dm_db_partition_stats WHERE index_id IN (0,1)
GROUP BY object_id HAVING SUM(used_page_count)*8.0/1024 > 5 ORDER BY mb DESC
"@
Chk '主要表体积正常（<1GB）' ($true) ((($sz.Rows | ForEach-Object { [string]$_['t'] + ':' + [string]$_['mb'] + 'MB' }) -join ' '))
$bakDir = if ($env:DSH_BACKUP_DIR) { $env:DSH_BACKUP_DIR } else { 'C:\dsh-mem\backup' }
$bak = if (Test-Path $bakDir) { Get-ChildItem $bakDir -File -Filter '*.bak' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 } else { $null }
if ($bak) {
    $ageH = [math]::Round(((Get-Date) - $bak.LastWriteTime).TotalHours, 1)
    Chk '最近备份 <36h' ($ageH -le 36) ($bak.Name + ' age=' + $ageH + 'h')
} else { Chk '最近备份存在' $false 'no bak' }

$cn.Close()
$bad = @($results | Where-Object { -not $_.ok })
Write-Output ''
Write-Output ('summary: total=' + $results.Count + ' pass=' + ($results.Count - $bad.Count) + ' fail=' + $bad.Count)
if ($bad.Count -gt 0) { Write-Output 'RESULT: FAIL'; exit 3 }
Write-Output 'RESULT: PASS'
