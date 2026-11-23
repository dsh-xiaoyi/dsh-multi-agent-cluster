# guard-mem-first-audit.ps1 -- 时光守护 · 行为级检查：历史类问题是否先查库
# [AUDIT-KIND-20261124] [OPENSOURCE-20261124] 审计条目改 kind=audit（原 ops-note 与正常笔记混在一起，污染检索）；注入器按 audit 排除
# T40 升级（2026-10-26，mem-first）；原件备份：guard-mem-first-audit.ps1.bak-before-T40-20261026134527（3845B, sha16=562B46E6B1E6A057）
#
# 判据：最近窗口（默认 24h）内，用户问"历史/约定/规则/进度"类问题后，助手本轮是否出现查库调用：
#   tool_call / tool_result 行里出现 mem-read / mem-find / mem-anchors / dsh-mem.ps1 /
#   sqlcmd / SqlConnection / DSHMemory / SELECT ... FROM dbo.*
# 或答案里带证据标记：[12345] / [src: mem=<id>] / [src: seq=<n>] / seq=N / session-xxxxxx
# ★T40 关键修正：注入的 runtime-context / time-context 行**不算**查库。
#   旧版把注入正文里的 "dsh-mem.ps1 search" 当成"查过库" ⇒ 25/26 靠这一条假绿，审计几乎永远 PASS。
#
# T40 四条必修：
#   1) 结论拆三类 queried / exempt / violations，结论行由变量插值（不再是 "all N" 字面量）
#   2) 扩面：legacy ∪ expanded 双词表（新词表是旧词表的超集），逐项打印命中数，不许静默放大
#   3) 断言：输出非空+行数合理、scanned>0、totalQ>0、queried+exempt+violations==totalQ；任一不成立 ⇒ FAIL
#   4) totalQ=0 ⇒ FAIL(unjudged)；表名非法/取不到 ⇒ FAIL（不跳过后算通过）
#
# T40b 追加（2026-10-26，用户/中枢裁决后，mem-first）：violations>0 时**主动落一条记忆**
#   （powershell -File C:\dsh-mem\dsh-mem.ps1 save，kind=ops-note），让违规出现在下一轮注入的
#   "最近结论"里自己浮上来，而不是躺在日志里没人看。约束：
#     · 幂等：违规集合（session|seq 排序）算 fp=sha16，同一个 fp 已有记忆 ⇒ 跳过，不刷屏
#     · violations=0 ⇒ 不落库（mem-save: off）
#     · 落库失败不影响判定：RESULT/exit code 照旧，只在输出留一行 `mem-save: FAIL (...)`，
#       并把 memsave 状态带进 RESULT 尾巴（守卫会把它记进 guard_rule_runs.detail = 日志面）
#
# 参数：
#   -Hours <int>           回溯小时数（默认 24）
#   -SourceTable <string>  取数表（默认 dbo.messages；阳性对照指向临时表，如 ##t40_probe）
#   -MemCli <string>       落库用的 CLI（默认 C:\dsh-mem\dsh-mem.ps1；仅在排障/对照时覆盖）
#   -NoMemSave             只做判定、不落记忆（排障开关）
# 输出：扫面行 / 特征命中数 / 三类计数 / 断言行 / 最多 10 条 VIOLATION / mem-save 行 / RESULT 行
#       exit 0=PASS 1=FAIL
param(
    [int]$Hours = 24,
    [string]$SourceTable = 'dbo.messages',
    [string]$MemCli = 'C:\dsh-mem\dsh-mem.ps1',
    [switch]$NoMemSave
)

$ErrorActionPreference = 'Continue'
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$out = New-Object System.Collections.Generic.List[string]
function Emit([string]$s) { if ($null -eq $s) { $s = '' }; $out.Add($s) }
function Finish([string]$resultLine, [int]$code) {
    Emit $resultLine
    foreach ($l in $out) { Write-Output $l }
    exit $code
}

# ---------------- 0) 自证前提（目标取不到 ⇒ FAIL，不许跳过后算通过） ----------------
if ($SourceTable -notmatch '^(##)?[A-Za-z0-9_]{1,60}(\.[A-Za-z0-9_]{1,60})?$') {
    Emit ('source_table=' + $SourceTable)
    Finish ('RESULT: FAIL (precondition: illegal -SourceTable "' + $SourceTable + '"; unreachable target is never a pass)') 1
}
if ($Hours -lt 1 -or $Hours -gt 168) {
    Emit ('hours=' + $Hours)
    Finish ('RESULT: FAIL (precondition: -Hours ' + $Hours + ' out of allowed range 1..168)') 1
}
$cfgPath = 'C:\dsh-mem\dsh-mem.config.json'
if (-not (Test-Path $cfgPath)) {
    Emit ('config_missing=' + $cfgPath)
    Finish ('RESULT: FAIL (precondition: db config not found: ' + $cfgPath + ')') 1
}
try {
    $cfg = ([System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8)) | ConvertFrom-Json
} catch {
    Emit ('config_parse_error=' + $_.Exception.Message.Split("`n")[0])
    Finish ('RESULT: FAIL (precondition: db config unparsable: ' + $cfgPath + ')') 1
}
$cs = 'Server=' + $cfg.server + ';Database=' + $cfg.database + ';User Id=' + $cfg.user + ';Password=' + $cfg.password + ';TrustServerCertificate=True;Connect Timeout=15'
$conn = New-Object System.Data.SqlClient.SqlConnection $cs
try { $conn.Open() } catch {
    Emit ('db=' + $cfg.server + ' db_unreachable=' + $_.Exception.Message.Split("`n")[0])
    Finish ('RESULT: FAIL (precondition: db unreachable: ' + $cfg.server + ')') 1
}

$q = $conn.CreateCommand(); $q.CommandTimeout = 60
$q.CommandText = 'SELECT session_id, seq, role, source, text FROM ' + $SourceTable + ' WHERE created_at > DATEADD(hour, -@h, SYSUTCDATETIME()) AND text IS NOT NULL ORDER BY session_id, seq'
$null = $q.Parameters.AddWithValue('@h', $Hours)
try {
    $dt = New-Object System.Data.DataTable
    $dt.Load($q.ExecuteReader())
} catch {
    Emit ('source_table=' + $SourceTable + ' read_error=' + $_.Exception.Message.Split("`n")[0])
    $conn.Close()
    Finish ('RESULT: FAIL (precondition: cannot read ' + $SourceTable + '; refusing to pass on an unreadable target)') 1
}
$q2 = $conn.CreateCommand()
$q2.CommandText = 'SELECT CONVERT(varchar(33), DATEADD(hour, -@h, SYSUTCDATETIME()), 127) + ''|'' + CONVERT(varchar(33), SYSUTCDATETIME(), 127)'
$null = $q2.Parameters.AddWithValue('@h', $Hours)
$window = [string]$q2.ExecuteScalar()
$conn.Close()

$rows = $dt.Rows
$scanned = $rows.Count

# ---------------- 1) 词表（legacy = 旧口径；expanded = 扩面；union 是旧口径的超集） ----------------
$histLegacy   = '(以前|上次|之前|当时|那天|约定|规则|决定|定过|进度|谁负责|还记得|记不记得|怎么定|谁定的|什么时候定)'
$askLegacy    = '(\?|？|吗|呢|怎么|如何|是否|谁|哪|多少|几个|记不记得|还记得|定过|约定|规则|进度|什么时候)'
$skipLegacy   = '(现在|今天|刚才|下一步|继续|马上|立刻|^\[bridge |^\[Agent |^Agent session-|^Background subagent|sent a message|from=|to=)'
$histExpanded = '(以前|上次|之前|当时|那天|历史|约定|规则|决定|定过|改过|进度|做到哪|谁负责|谁定的|怎么定|什么时候定|哪个任务|哪个窗口|哪个文件|哪台机器|第几次|记不记得|还记得|早前|原先|老规矩|已经做完)'
$askExpanded  = '(\?|？|吗|呢|怎么|如何|是否|谁|哪|多少|几个|什么时候|有没有|是不是|能不能|要不要|可不可以|记不记得|还记得|说说|讲讲|列一下|列出来|查一下|告诉我|给我|复述|回顾|整理|找一下|搜一下|看看|发我|发一下)'
$nonUserPat  = '^(\[bridge |\[Agent |\[Assistant |Agent (session-)?[0-9a-f\-]{8,} sent a message|sent a message|Background subagent|Current runtime context|Time sampled while preparing turn|你是「|<goal_(blocked|active)|## |【系统)'
$querySig     = '(mem-read|mem-find|mem-anchors|dsh-mem\.ps1|sqlcmd|SqlConnection|SqlClient|DSHMemory|FROM\s+dbo\.|dbo\.messages|dbo\.memories|dbo\.guard_rules)'
$evidencePat  = '(\[\d{4,6}\]|\[src:\s*(mem|seq)=\d+\]|session-[0-9a-f]{6,}|seq=\d+)'
$userSources  = @('user', 'spool')   # [MEM-FIRST-SOURCE-20261030] spool-import 把用户轮写成 source='spool'（旧口径只认 source='user' ⇒ totalQ=0 假红）
$ctxSources   = @('runtime-context', 'time-context', 'system-reminder', 'compact-checkpoint')

# ---------------- 2) 主循环 ----------------
$legacyHistHits = 0; $legacyAskHits = 0; $legacyBoth = 0
$expHistHits = 0; $expAskHits = 0; $expBoth = 0
$expandedOnlyHits = 0
$totalQ = 0
$queriedTool = 0; $queriedEvidence = 0
$exemptShort = 0; $exemptNoAnswer = 0; $exemptNonUser = 0
$userQ = 0; $nonUserQ = 0; $nonUserWouldViolate = 0
$viol = 0
$details = New-Object System.Collections.Generic.List[string]
$violKeys = New-Object System.Collections.Generic.List[string]      # T40b：全部违规的 session|seq（算幂等指纹）
$violSample = New-Object System.Collections.Generic.List[object]    # T40b：前 3 条明细（落记忆正文用）

$i = 0
while ($i -lt $rows.Count) {
    $role = [string]$rows[$i].Item('role')
    $source = [string]$rows[$i].Item('source')
    if ($role -ne 'user' -or ($userSources -notcontains $source) -or ($ctxSources -contains $source)) { $i++; continue }
    $utext = [string]$rows[$i].Item('text')
    if ($utext.Length -lt 6) { $i++; continue }

    $hLeg = [bool]($utext -match $histLegacy); $aLeg = [bool]($utext -match $askLegacy)
    $hExp = [bool]($utext -match $histExpanded); $aExp = [bool]($utext -match $askExpanded)
    if ($hLeg) { $legacyHistHits++ }
    if ($aLeg) { $legacyAskHits++ }
    if ($hExp) { $expHistHits++ }
    if ($aExp) { $expAskHits++ }
    $isLegacy = $hLeg -and $aLeg -and ($utext -notmatch $skipLegacy)
    $isExpanded = $hExp -and $aExp
    if ($isLegacy) { $legacyBoth++ }
    if ($isExpanded) { $expBoth++ }
    if (-not ($isLegacy -or $isExpanded)) { $i++; continue }

    $totalQ++
    $isNonUser = [bool]($utext -match $nonUserPat)
    if ($isNonUser) { $nonUserQ++ } else { $userQ++ }
    if ($isExpanded -and -not $isLegacy) { $expandedOnlyHits++ }

    $sid = [string]$rows[$i].Item('session_id')
    $seq = [int64]$rows[$i].Item('seq')
    $j = $i + 1
    $sawQuery = $false
    $answer = ''
    while ($j -lt $rows.Count) {
        $sid2 = [string]$rows[$j].Item('session_id')
        if ($sid2 -ne $sid) { break }
        $r2 = [string]$rows[$j].Item('role')
        $s2 = [string]$rows[$j].Item('source')
        $t2 = [string]$rows[$j].Item('text')
        if ($r2 -eq 'user' -and $s2 -eq 'user') { break }
        if (($r2 -eq 'tool_call' -or $r2 -eq 'tool_result') -and ($ctxSources -notcontains $s2) -and ($t2 -match $querySig)) { $sawQuery = $true }
        if ($r2 -eq 'assistant' -and ($ctxSources -notcontains $s2) -and $t2.Length -gt 20) { $answer = $t2 }
        $j++
    }
    $hasEvidence = ($answer.Length -gt 0) -and ($answer -match $evidencePat)

    if ($sawQuery) {
        $queriedTool++
    } elseif ($hasEvidence) {
        $queriedEvidence++
    } elseif ($isNonUser) {
        $exemptNonUser++
        if ($answer.Length -gt 80) { $nonUserWouldViolate++ }
    } elseif ($answer.Length -eq 0) {
        $exemptNoAnswer++
    } elseif ($answer.Length -le 80) {
        $exemptShort++
    } else {
        $viol++
        $violKeys.Add($sid + '|' + $seq)
        $snippet = ($utext -replace '\s+', ' ')
        if ($snippet.Length -gt 60) { $snippet = $snippet.Substring(0, 60) + '…' }
        if ($violSample.Count -lt 3) {
            $violSample.Add([pscustomobject]@{ sid = $sid; seq = $seq; answer_len = $answer.Length; snippet = $snippet })
        }
        if ($details.Count -lt 10) {
            $details.Add('  VIOLATION ' + $sid.Substring(0, [Math]::Min(20, $sid.Length)) + ' seq=' + $seq + ' answer_len=' + $answer.Length + ' no_db_query no_evidence | ' + $snippet)
        }
    }
    $i++
}

# ---------------- 3) 计数与断言 ----------------
$queried = $queriedTool + $queriedEvidence
$exempt = $exemptShort + $exemptNoAnswer + $exemptNonUser
$sum3 = $queried + $exempt + $viol
$invariantOk = ($sum3 -eq $totalQ)
$scannedOk = ($scanned -gt 0)
$denominatorOk = ($totalQ -gt 0)

Emit ('guard-mem-first-audit T40 | source_table=' + $SourceTable + ' hours=' + $Hours + ' scanned=' + $scanned)
Emit ('window_utc: from=' + $window.Split('|')[0] + ' to=' + $window.Split('|')[1])
Emit ('features_legacy: hist_hits=' + $legacyHistHits + ' ask_hits=' + $legacyAskHits + ' both_hits=' + $legacyBoth + '  (旧版口径复现)')
Emit ('features_expanded: hist_hits=' + $expHistHits + ' ask_hits=' + $expAskHits + ' both_hits=' + $expBoth)
Emit ('coverage: legacy_candidates=' + $legacyBoth + ' expanded_only=' + $expandedOnlyHits + ' union_candidates=' + $totalQ + '  (旧版=26 → 新版=' + $totalQ + '，扩面来源=新词表+新问句特征)')
Emit ('scope: user_questions=' + $userQ + ' nonuser_envelope=' + $nonUserQ + ' (非用户提问只记 exempt，不判违规)')
Emit ('totalQ=' + $totalQ + ' queried=' + $queried + ' (tool=' + $queriedTool + ' evidence=' + $queriedEvidence + ') exempt=' + $exempt + ' (short=' + $exemptShort + ' no_answer=' + $exemptNoAnswer + ' nonuser=' + $exemptNonUser + ') violations=' + $viol)
Emit ('invariant: queried+exempt+violations = ' + $queried + '+' + $exempt + '+' + $viol + ' = ' + $sum3 + ' == totalQ=' + $totalQ + ' : ' + $(if ($invariantOk) { 'OK' } else { 'MISMATCH' }))
if ($viol -gt 0) { foreach ($d in $details) { Emit $d } } else { Emit 'violations: none' }
Emit ('note: nonuser envelopes are recorded as exempt; if they were judged they would add nonuser_violations=' + $nonUserWouldViolate)

# ---------------- 3b) T40b: violations>0 主动落记忆（幂等；失败不影响判定） ----------------
$memSaveState = 'off'
$memSaveDetail = ''
if ($viol -gt 0 -and -not $NoMemSave) {
    $fp16 = ''
    try {
        # 幂等键：全部违规 (session|seq) 排序 + 条数 ⇒ sha16。同一批违规重复跑 = 同一个 fp ⇒ 跳过。
        $fpRaw = (($violKeys | Sort-Object) -join ';') + '|v=' + $viol
        $fp16 = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($fpRaw)))).Replace('-', '').Substring(0, 16)
        $memTitle = 'MEM-FIRST-VIOLATION v=' + $viol + ' totalQ=' + $totalQ + ' user=' + $userQ + ' fp=' + $fp16 + ' · 历史类提问未查库（T40 自动落库）'
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('【T40 行为审计 · 历史类提问未查库】')
        [void]$sb.AppendLine('table=' + $SourceTable + ' hours=' + $Hours + ' scanned=' + $scanned + ' window_from=' + $window.Split('|')[0] + ' window_to=' + $window.Split('|')[1])
        [void]$sb.AppendLine('counts: totalQ=' + $totalQ + ' user=' + $userQ + ' nonuser_envelope=' + $nonUserQ + ' queried=' + $queried + ' (tool=' + $queriedTool + ' evidence=' + $queriedEvidence + ') exempt=' + $exempt + ' violations=' + $viol)
        [void]$sb.AppendLine('idempotency: fp=' + $fp16 + '（同一批违规重复跑不重复落库；violations 变化才会落新的一条）')
        [void]$sb.AppendLine('前 3 条违规明细:')
        $k = 0
        foreach ($s in $violSample) {
            $k++
            [void]$sb.AppendLine(' ' + $k + ') session=' + $s.sid + ' seq=' + $s.seq + ' answer_len=' + $s.answer_len + ' no_db_query no_evidence | ' + $s.snippet)
        }
        [void]$sb.AppendLine('规则: RULE-MEM-EVIDENCE（历史类提问必须当轮查库 search/mem-read，并在答案末尾标 [src: mem=<id>] 或 [src: seq=<n>]）')
        [void]$sb.AppendLine('来源: guard-mem-first-audit.ps1 T40b 自动落库；复核: powershell -File C:\dsh-mem\dsh-mem.ps1 search MEM-FIRST-VIOLATION')
        $memBody = $sb.ToString().TrimEnd()

        # 幂等检查：同一个 fp 已有记忆 ⇒ 跳过（不刷屏）——先查库，不靠印象
        $cn = New-Object System.Data.SqlClient.SqlConnection $cs
        $cn.Open()
        $qc = $cn.CreateCommand()
        $qc.CommandText = 'SELECT TOP 1 id FROM dbo.memories WHERE title LIKE @p ORDER BY id DESC'
        $null = $qc.Parameters.AddWithValue('@p', '%MEM-FIRST-VIOLATION%fp=' + $fp16 + '%')
        $dupId = $qc.ExecuteScalar()
        if ($null -ne $dupId -and -not ($dupId -is [System.DBNull])) {
            $memSaveState = 'skipped'
            $memSaveDetail = 'already-saved id=' + [int64]$dupId + ' fp=' + $fp16
            Emit ('mem-save: skipped (same violation set already saved; id=' + [int64]$dupId + ' fp=' + $fp16 + ')')
        } else {
            $titleFile = Join-Path $env:TEMP ('t40-mem-title-' + $fp16 + '.txt')
            $bodyFile = Join-Path $env:TEMP ('t40-mem-body-' + $fp16 + '.txt')
            [System.IO.File]::WriteAllText($titleFile, $memTitle, (New-Object System.Text.UTF8Encoding($false)))
            [System.IO.File]::WriteAllText($bodyFile, $memBody, (New-Object System.Text.UTF8Encoding($false)))
            $saveOut = ''
            $saveCode = -1
            try {
                # 用 -TitleFile/-BodyFile：长正文走命令行在带奇数引号时会静默失败（dsh-mem.ps1 注释 [133]）
                $saveOut = (& powershell -NoProfile -ExecutionPolicy Bypass -File $MemCli save -TitleFile $titleFile -BodyFile $bodyFile -Kind audit -Scope global -Subject 'ORCHESTRATOR' -Tags 'MEM-FIRST-VIOLATION,ops-note' -Confidence 90 2>&1 | Out-String)
                $saveCode = $LASTEXITCODE
            } catch { $saveCode = -2; $saveOut = [string]$_.Exception.Message }
            if (Test-Path $titleFile) { Remove-Item -LiteralPath $titleFile -Force -ErrorAction SilentlyContinue }
            if (Test-Path $bodyFile) { Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue }

            $newId = $null
            if ($saveOut -match 'saved memory id=(\d+)') { $newId = [int64]$Matches[1] }
            # 断言：输出非空 + 落库可回读（退出码不算证据）
            $qc2 = $cn.CreateCommand()
            $qc2.CommandText = 'SELECT COUNT(*) FROM dbo.memories WHERE title LIKE @p'
            $null = $qc2.Parameters.AddWithValue('@p', '%MEM-FIRST-VIOLATION%fp=' + $fp16 + '%')
            $after = [int]$qc2.ExecuteScalar()
            if ($saveCode -eq 0 -and $saveOut.Trim().Length -gt 0 -and $after -ge 1) {
                $memSaveState = 'ok'
                $memSaveDetail = 'id=' + $(if ($null -ne $newId) { $newId } else { '?' }) + ' fp=' + $fp16 + ' rows=' + $after
                Emit ('mem-save: ok id=' + $(if ($null -ne $newId) { $newId } else { '?' }) + ' fp=' + $fp16 + ' verify_rows=' + $after + ' title_len=' + $memTitle.Length + ' body_len=' + $memBody.Length)
            } else {
                $memSaveState = 'failed'
                $last = ''
                if ($saveOut) {
                    # 取"真正的错误句"：先滤掉 PowerShell 欢迎横幅与错误记录的装饰行（+ / CategoryInfo / FullyQualifiedErrorId）
                    $lns = @($saveOut -split "`r?`n" | Where-Object {
                        $_.Trim() -and
                        $_ -notmatch 'Install the latest PowerShell|Try the new cross-platform' -and
                        $_ -notmatch '^\s*\+' -and
                        $_ -notmatch '^\s*(所在位置|CategoryInfo|FullyQualifiedErrorId|At line)'
                    })
                    $errLine = @($lns | Where-Object { $_ -match '(?i)does not exist|not found|cannot find|无法|不存在|is not recognized|拒绝|失败|permission' }) | Select-Object -First 1
                    if ($errLine) { $last = $errLine } elseif ($lns.Count -gt 0) { $last = $lns[$lns.Count - 1] }
                }
                if (-not $last) { $last = '(no output)' }
                if ($last.Length -gt 120) { $last = $last.Substring(0, 120) + '…' }
                $memSaveDetail = 'exit=' + $saveCode + ' rows=' + $after + ' err=' + $last
                Emit ('mem-save: FAIL (exit=' + $saveCode + ' verify_rows=' + $after + ' err=' + $last + ')')
            }
        }
        $cn.Close()
    } catch {
        $memSaveState = 'failed'
        $memSaveDetail = [string]$_.Exception.Message.Split("`n")[0]
        Emit ('mem-save: FAIL (exception: ' + $memSaveDetail + ')')
        $fp16 = ''
    }
} else {
    $memSaveState = 'off'
    Emit ('mem-save: off (violations=' + $viol + '; nothing to save)')
}

$summaryPresent = @($out | Where-Object { $_ -match '^totalQ=' }).Count -ge 1
$structOk = ($out.Count -ge 10) -and $summaryPresent
Emit ('assert: scanned_positive=' + $scannedOk + ' denominator_positive=' + $denominatorOk + ' counter_sum=' + $invariantOk + ' output_lines=' + $out.Count + ' structural=' + $structOk)

$failReasons = New-Object System.Collections.Generic.List[string]
if (-not $structOk) { $failReasons.Add('output-structure') }
if (-not $scannedOk) { $failReasons.Add('scanned=0(no-data)') }
if (-not $denominatorOk) { $failReasons.Add('unjudged(totalQ=0)') }
if (-not $invariantOk) { $failReasons.Add('counter-sum-mismatch(' + $sum3 + '!=' + $totalQ + ')') }
if ($viol -gt 0) { $failReasons.Add('violations=' + $viol) }

$verdict = if ($failReasons.Count -eq 0) { 'PASS' } else { 'FAIL' }
$summary = 'scanned=' + $scanned + ' totalQ=' + $totalQ + ' user=' + $userQ + ' queried=' + $queried + ' exempt=' + $exempt + ' violations=' + $viol + '; memsave=' + $memSaveState + $(if ($memSaveDetail) { ' (' + $memSaveDetail + ')' } else { '' })
if ($verdict -eq 'PASS') {
    Finish ('RESULT: PASS (' + $summary + '; queried+exempt+violations=' + $sum3 + '=totalQ)') 0
} else {
    Finish ('RESULT: FAIL (' + $summary + '; reasons=' + ($failReasons -join ',') + ')') 1
}
