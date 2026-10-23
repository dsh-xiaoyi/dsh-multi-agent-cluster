# 时光守护 · 规则执行器 (guard-rules.ps1)
#
# Owner 2026-10-22: the guard program should read its RULES from the database and execute them,
# so policy changes are a data change (auditable, versioned) instead of a script edit. When there is
# no database it must fall back to the central commander (中枢) for centrally issued rules.
#
# Rule sources, in order:
#   1) DB          dbo.guard_rules (enabled=1)         -- normal fleet operation
#   2) local file  <root>\ops\guard-rules.json         -- no DB, rules shipped with the installer
#   3) commander   http://<中枢>:19387/rules           -- no DB and no local rules: ask 青鸟
#
# Supported rule_type (deliberately a small, auditable set -- no free-form code execution):
#   sql_zero            definition=SQL, expect scalar == 0
#   sql_max             definition=SQL, expect scalar <= param
#   file_exists         definition=path; param='acl-restricted' also requires no Everyone/Users read
#   regex_absent_in_files  definition=dir, param=regex, optional -Mask (default *.json)
#   endpoint_ok         definition=URL, expect JSON ok=true; if param looks like a CIDR, additionally
#                       require a firewall rule for the listen port scoped to that CIDR
param(
    [string]$ConfigPath = 'C:\dsh-mem\dsh-mem.config.json',
    [string]$RulesFile = '',
    [string]$CommanderUrl = '',
    [string]$Mask = '*.json',
    [switch]$NoRecord,
    [switch]$Quiet
)
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Data

$root = Split-Path (Split-Path $ConfigPath -Parent) -Parent
if (-not $root) { $root = 'C:\dsh-mem' }
$opsDir = Join-Path (Split-Path $ConfigPath -Parent) 'ops'
if (-not $RulesFile) { $RulesFile = Join-Path $opsDir 'guard-rules.json' }

$results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$name, [string]$category, [string]$severity, [bool]$ok, [string]$detail) {
    $results.Add([pscustomobject]@{ name = $name; category = $category; severity = $severity; ok = $ok; detail = $detail })
}

# ---------------- rule sources ----------------
$rules = @()
$srcName = ''
$rulesVer = ''
$cn = $null
try {
    if (Test-Path $ConfigPath) {
        $cfg = ([System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)) | ConvertFrom-Json
        $cs = 'Server=' + $cfg.server + ';Database=' + $cfg.database + ';User Id=' + $cfg.user + ';Password=' + $cfg.password + ';TrustServerCertificate=True;Connect Timeout=8'
        $cn = New-Object System.Data.SqlClient.SqlConnection $cs
        $cn.Open()
        $q = $cn.CreateCommand()
        $q.CommandText = "SELECT name, category, severity, rule_type, definition, param, version FROM dbo.guard_rules WHERE enabled = 1 ORDER BY rule_id"
        $dt = New-Object System.Data.DataTable; $dt.Load($q.ExecuteReader())
        foreach ($r in $dt.Rows) {
            $rules += [pscustomobject]@{
                name = [string]$r['name']; category = [string]$r['category']; severity = [string]$r['severity']
                rule_type = [string]$r['rule_type']; definition = [string]$r['definition']; param = [string]$r['param']
            }
            $rulesVer += ([string]$r['version'])
        }
        $srcName = 'db'
        $rulesVer = (([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes(($rules | ConvertTo-Json -Compress))))).Replace('-', '').Substring(0, 16))
    }
} catch { if (-not $Quiet) { Write-Output ('  (db unavailable, falling back: ' + $_.Exception.Message.Split("`n")[0] + ')') } }

if ($rules.Count -eq 0 -and (Test-Path $RulesFile)) {
    try {
        $rules = @(([System.IO.File]::ReadAllText($RulesFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json))
        $srcName = 'file:' + (Split-Path $RulesFile -Leaf)
        $rulesVer = (([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes(($rules | ConvertTo-Json -Compress))))).Replace('-', '').Substring(0, 16))
    } catch { }
}

if ($rules.Count -eq 0 -and $CommanderUrl) {
    try {
        $resp = Invoke-RestMethod -Uri ($CommanderUrl.TrimEnd('/') + '/rules') -TimeoutSec 8
        if ($resp -and $resp.rules) {
            $rules = @($resp.rules)
            $srcName = 'commander:' + $CommanderUrl
            $rulesVer = [string]$resp.version
        }
    } catch { if (-not $Quiet) { Write-Output ('  (commander rules unavailable: ' + $_.Exception.Message.Split("`n")[0] + ')') } }
}

if ($rules.Count -eq 0) {
    Write-Output 'guard-rules: NO RULES AVAILABLE (db, local file and commander all failed) -- this itself is reported'
    Add-Result 'rule source available' 'hygiene' 'fail' $false 'no rules from db/file/commander'
} else {
    if (-not $Quiet) { Write-Output ('guard-rules: ' + $rules.Count + ' rule(s) from ' + $srcName + ' ver=' + $rulesVer) }
}

# ---------------- execute ----------------
function Q-Scalar([string]$sql) {
    if (-not $cn) { throw 'no db connection' }
    $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql
    return $cmd.ExecuteScalar()
}

function Test-AclRestricted([string]$path) {
    $out = & cmd.exe /c ('icacls "' + $path + '" 2>&1') | Out-String
    # Everyone / Users / Authenticated Users with read (or more) => too open
    foreach ($bad in @('Everyone:(R', 'Everyone:(F', 'Everyone:(M', 'BUILTIN\Users:(R', 'BUILTIN\Users:(F', 'Authenticated Users:(R')) {
        if ($out -like ('*' + $bad + '*')) { return $false }
    }
    return $true
}

foreach ($r in $rules) {
    $name = [string]$r.name; $cat = [string]$r.category; $sev = [string]$r.severity
    if (-not $sev) { $sev = 'fail' }
    try {
        switch ([string]$r.rule_type) {
            'sql_zero' {
                $v = Q-Scalar ([string]$r.definition)
                $val = if ($null -eq $v -or $v -is [System.DBNull]) { 0 } else { [int]$v }
                Add-Result $name $cat $sev ($val -eq 0) ('value=' + $val + ' expected=0')
            }
            'sql_max' {
                $v = Q-Scalar ([string]$r.definition)
                $val = if ($null -eq $v -or $v -is [System.DBNull]) { 0 } else { [double]$v }
                $max = [double]$r.param
                Add-Result $name $cat $sev ($val -le $max) ('value=' + $val + ' max=' + $max)
            }
            'file_exists' {
                $p = [string]$r.definition
                $exists = Test-Path $p
                $detail = 'exists=' + $exists
                $ok = $exists
                if ($exists -and [string]$r.param -eq 'acl-restricted') {
                    $aclOk = Test-AclRestricted $p
                    $ok = $ok -and $aclOk
                    $detail += ' acl_restricted=' + $aclOk
                }
                Add-Result $name $cat $sev $ok $detail
            }
            'script_exit0' {
                # definition = 脚本绝对路径；param = 超时秒数（默认 120）
                # 用 exit code 判定：0 = PASS。脚本必须自己打印 RESULT: PASS/FAIL（便于日志追溯）。
                $sp = [string]$r.definition
                $to = if ([string]$r.param) { [int]$r.param } else { 120 }
                if (-not (Test-Path $sp)) { Add-Result $name $cat $sev $false ('script missing: ' + $sp); break }
                $out = ''
                $code = -1
                try {
                    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $sp 2>&1 | Out-String
                    $code = $LASTEXITCODE
                } catch { $code = -2; $out = [string]$_.Exception.Message }
                $tail = (@(($out -split "`r?`n") | Where-Object { $_ -match 'RESULT:' }) | Select-Object -Last 1)
                Add-Result $name $cat $sev ($code -eq 0) ('exit=' + $code + ' ' + ($tail -replace '[^\x20-\x7E]','.') + ' timeout=' + $to + 's')
            }            'log_max_age' {
                # definition = 日志路径；param = "正则|最大静默分钟"
                # 判据：日志里最近一条匹配行距今超过阈值 ⇒ FAIL（= 该通道已经很久没有成功过一次）
                $lp = [string]$r.definition
                $parts = ([string]$r.param) -split '\|'
                $pat = if ($parts.Count -ge 1) { $parts[0] } else { '' }
                $maxAge = if ($parts.Count -ge 2) { [int]$parts[1] } else { 25 }
                if (-not (Test-Path $lp)) { Add-Result $name $cat $sev $false ('log missing: ' + $lp); break }
                $newest = $null
                foreach ($ln in (Get-Content $lp -Tail 3000 -Encoding UTF8)) {
                    if ($ln -notmatch '^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})') { continue }
                    # ★ 先把时间戳取出来：第二次 -match 会覆盖 $Matches（2026-10-23 实际踩到 ParseExact 报错）
                    $tsText = $Matches[1]
                    if ($ln -notmatch $pat) { continue }
                    $ts = [datetime]::ParseExact($tsText, 'yyyy-MM-ddTHH:mm:ss', $null)
                    if (-not $newest -or $ts -gt $newest) { $newest = $ts }
                }
                if (-not $newest) { Add-Result $name $cat $sev $false ('no match ever for /' + $pat + '/ in ' + (Split-Path $lp -Leaf)); break }
                $ageMin = [math]::Round(((Get-Date).ToUniversalTime() - $newest).TotalMinutes, 1)
                Add-Result $name $cat $sev ($ageMin -le $maxAge) ('last=' + $newest.ToString('MM-dd HH:mm:ss') + 'Z age=' + $ageMin + 'min max=' + $maxAge + 'min')
            }            'log_count_max' {
                # definition = 日志文件路径；param = "正则|窗口分钟|上限"
                $lp = [string]$r.definition
                $parts = ([string]$r.param) -split '\|'
                $pat = if ($parts.Count -ge 1) { $parts[0] } else { '' }
                $win = if ($parts.Count -ge 2) { [int]$parts[1] } else { 15 }
                $max = if ($parts.Count -ge 3) { [int]$parts[2] } else { 0 }
                if (-not (Test-Path $lp)) { Add-Result $name $cat $sev $true ('log missing (nothing to count): ' + $lp); break }
                $lines = @(Get-Content $lp -Tail 2000 -Encoding UTF8)
                $cut = (Get-Date).ToUniversalTime().AddMinutes(-$win)
                $n = 0
                foreach ($ln in $lines) {
                    if ($ln -notmatch '^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})') { continue }
                    $ts = [datetime]::ParseExact($Matches[1], 'yyyy-MM-ddTHH:mm:ss', $null)
                    if ($ts -lt $cut) { continue }
                    if ($ln -match $pat) { $n++ }
                }
                Add-Result $name $cat $sev ($n -le $max) ('matches=' + $n + ' in last ' + $win + 'min, max=' + $max)
            }            'file_min_bytes' {
                $p = [string]$r.definition
                $min = [int64]$r.param
                if (-not (Test-Path $p)) { Add-Result $name $cat $sev $false ('missing file: ' + $p); break }
                $len = (Get-Item $p).Length
                Add-Result $name $cat $sev ($len -ge $min) ('size=' + [math]::Round($len/1KB,1) + 'KB min=' + [math]::Round($min/1KB,1) + 'KB')
            }            'regex_absent_in_files' {
                $dir = [string]$r.definition
                $pat = [string]$r.param
                if (-not (Test-Path $dir)) { Add-Result $name $cat $sev $true ('dir missing (nothing to leak): ' + $dir); break }
                $hits = @()
                foreach ($f in (Get-ChildItem $dir -File -Filter $Mask -ErrorAction SilentlyContinue)) {
                    $txt = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
                    if ($txt -match $pat) { $hits += $f.Name }
                }
                Add-Result $name $cat $sev ($hits.Count -eq 0) ('files=' + $Mask + ' matches=' + ($hits.Count) + $(if ($hits.Count) { ' -> ' + (($hits | Select-Object -First 3) -join ',') } else { '' }))
            }
            'endpoint_ok' {
                $url = [string]$r.definition
                $ok = $false; $detail = ''
                try {
                    $h = Invoke-RestMethod -Uri $url -TimeoutSec 6
                    $ok = [bool]$h.ok
                    $detail = 'healthz ok=' + $ok
                } catch { $detail = 'unreachable: ' + $_.Exception.Message.Split("`n")[0] }
                if ([string]$r.param -match '^\d+\.\d+\.\d+\.\d+/\d+$') {
                    $fw = & cmd.exe /c 'netsh advfirewall firewall show rule name="DSH-Bridge-19387" 2>&1' | Out-String
                    $scoped = ($fw -match [regex]::Escape([string]$r.param))
                    $ok = $ok -and $scoped
                    $detail += ' firewall_scoped_to=' + $scoped
                }
                Add-Result $name $cat $sev $ok $detail
            }
            default { Add-Result $name $cat $sev $false ('unsupported rule_type: ' + [string]$r.rule_type) }
        }
    } catch {
        Add-Result $name $cat $sev $false ('error: ' + $_.Exception.Message.Split("`n")[0])
    }
}

# ---------------- report ----------------
$failCount = @($results | Where-Object { -not $_.ok -and $_.severity -eq 'fail' }).Count
$warnCount = @($results | Where-Object { -not $_.ok -and $_.severity -eq 'warn' }).Count
if (-not $Quiet) {
    foreach ($x in $results) {
        Write-Output (($(if ($x.ok) { '[PASS]' } elseif ($x.severity -eq 'warn') { '[WARN]' } else { '[FAIL]' })) + ' ' + $x.name + '  ' + $x.detail)
    }
    Write-Output ('rules: total=' + $results.Count + ' failed=' + $failCount + ' warn=' + $warnCount + ' source=' + $srcName + ' ver=' + $rulesVer)
}

# ---------------- record ----------------
if (-not $NoRecord -and $cn) {
    try {
        $ins = $cn.CreateCommand()
        $ins.CommandText = "INSERT INTO dbo.guard_rule_runs (rules_ver, total, passed, failed, detail, machine) VALUES (@v,@t,@p,@f,@d,@m)"
        $null = $ins.Parameters.AddWithValue('@v', $rulesVer)
        $null = $ins.Parameters.AddWithValue('@t', $results.Count)
        $null = $ins.Parameters.AddWithValue('@p', (@($results | Where-Object { $_.ok }).Count))
        $null = $ins.Parameters.AddWithValue('@f', $failCount)
        $null = $ins.Parameters.AddWithValue('@d', (($results | ForEach-Object { ($(if ($_.ok) { 'ok' } else { 'FAIL' })) + ':' + $_.name + ' | ' + $_.detail }) -join ' ;; '))
        $null = $ins.Parameters.AddWithValue('@m', $env:COMPUTERNAME)
        $null = $ins.ExecuteNonQuery()
    } catch { }
}
if ($cn) { $cn.Close() }
if ($failCount -gt 0) { exit 3 }
exit 0
