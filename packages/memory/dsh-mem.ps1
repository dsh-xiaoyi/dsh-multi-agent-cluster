# 第一次用？先看 README 的「5 分钟跑起来」，再回来读这个脚本。
<#
  dsh-mem.ps1  -  DSH long-term memory CLI
  Requires PowerShell 7 or Windows PowerShell 5.1 (System.Data.SqlClient + SqlBulkCopy).

  Commands
    sync    [<session.v4.jsonl.zstd>] [-All] [-IncludeTools|-NoTools] [-Force] [-SkipArchive]
                                  upserts by (session_id, seq): ids stay stable, changed
                                  rows are updated in place, and rows the log no longer has
                                  are archived to dbo.messages_history before removal
    save    -Title .. -Body .. [-Tags a,b] [-Scope machine] [-Subject X] [-Kind fact]
            -TitleFile <f> -BodyFile <f>   safer for long text / text containing quotes
    embed   [-Limit N] [-Model m] [-Reembed] [-Chars N] [-BaseURL u]
                                  fill dbo.embeddings (F plan).  Idempotent: only rows
                                  with no vector for this model, or whose embedded text
                                  changed (MD5 of Exactly the text that is embedded).
    search  <keyword> [-Limit 20]
    recall  <query> [-Limit 8] [-Context 2]
                                  context-aware retrieval: preferred backend is
                                  semantic (F plan); otherwise an explicit DEGRADED
                                  fallback to literal LIKE + [-Context] turns
    recent  [-Limit 20]
    stats
    history [-Session <sid>] [-Seq <n>] [-Limit 20]
                                  read the append-only archive of everything sync had to
                                  destroy or overwrite (rolled-back logs, regenerated
                                  messages).  This is how another machine traces what a
                                  rollback lost: sql\002-create-messages-history.sql
    replica                       refresh the LOCAL offline copy of the memory
    backup                        full .bak on the SQL host + JSON export of memories

  recall backend (F-plan hook)
    Semantic search is used only when all three hold: dsh-mem.config.json has an
    "embed" block, dbo.embeddings holds vectors for that model, and the endpoint
    answers.  Anything else => a DEGRADED line is printed and literal search plus
    surrounding turns is used instead.  Silent degradation is forbidden on purpose
    (see shared memory [115]).
      "embed": { "baseURL": "http://192.0.2.18:11434", "model": "bge-m3", "dim": 1024 }
    Use the model host's own IP: 127.0.0.1 would only work on that host itself.

  Offline behaviour
    search / recent / stats first try the database. If it is unreachable they fall
    back to the local replica written by `replica` and say so plainly.

  Notes
    - Uses the low-privilege login from dsh-mem.config.json (DSHMemory only).
    - sync is idempotent (delete + reinsert per session) and skips session files
      whose size+mtime has not changed, so a 1-2 minute schedule is nearly free.
    - Secrets are redacted before anything reaches the database.
    - save reads -TitleFile/-BodyFile as UTF-8 and reads the row back (INSERT ... OUTPUT)
      so a silent failure or a truncation cannot pass unnoticed (memory [133]).
    - embed never fails silently: per-row failures are printed with their reason, and
      the run stops after five.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command = 'help',
  [Parameter(Position = 1)][string]$Target,
  [string]$Title,
  [string]$Body,
  [string]$TitleFile,
  [string]$BodyFile,
  [string]$Model,
  [string]$BaseURL,
  [int]$Chars = 0,
  [switch]$Reembed,
  [switch]$DryRun,
  [switch]$SelfTest,
  [string]$Tags = '',
  [string]$Scope = 'machine',
  [string]$Subject = $env:COMPUTERNAME,
  [string]$Kind = 'fact',
  [int]$Confidence = 80,
  [int]$Limit = 20,
  [int]$Context = 2,
  [int]$ReplicaMessages = 3000,
  [switch]$IncludeTools,
  [switch]$NoTools,
  [switch]$All,
  [switch]$Force,
  [switch]$SkipArchive,
  [string]$Session,
  [long]$Seq = 0
)

$ErrorActionPreference = 'Stop'
# contract: our stdout is UTF-8 so a parent process can decode it deterministically
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Read-TextFile([string]$Path) {
  # Read a text file as UTF-8, honouring a BOM if present.
  # WHY THIS EXISTS (bug found 2026-10-06, see shared memory [117]):
  #   `Get-Content -Raw` without -Encoding uses the ANSI code page for a BOM-less
  #   file.  dsh-mem-replica.json is written WITHOUT a BOM on purpose (Node's
  #   JSON.parse rejects a BOM), so PowerShell decoded it as GBK: Chinese became
  #   mojibake, and some byte pair decoded to a stray backslash inside a JSON
  #   string -> ConvertFrom-Json threw -> Get-Replica returned $null -> every
  #   offline path claimed "no local replica" exactly when the database was down.
  #   It was data-dependent, so it worked for hours and then broke on its own.
  $enc = New-Object System.Text.UTF8Encoding $false
  $sr  = New-Object System.IO.StreamReader($Path, $enc, $true)
  try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
}

$Root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$CfgPath = Join-Path $Root 'dsh-mem.config.json'
if (-not (Test-Path -LiteralPath $CfgPath)) { throw "config not found: $CfgPath" }
$cfg = Read-TextFile $CfgPath | ConvertFrom-Json

# --- explicit version, so the cluster never has to infer it from a byte count again ------------
# Lineage: 32174 (prune/handoff) -> 53025 (offline replica) -> 74605 (recall + embed half)
#          -> 77609 (path b: vectors keyed by content hash) -> 80330 (3 defects fixed)
#          -> 81395 (duplicate consolidation, cluster audit) -> 1.0.0 (UNIFIED baseline:
#             export redaction on handoff/backup/replica + this version report + check 14).
# Memory [177]/[178] is what happens without this string: two machines compared byte counts,
# both read a stale number, and the direction of the fix was reported backwards.
# Policy B (user decision 2026-10-06, memory [657]): tool calls/results are part of the record, and
# they are now the DEFAULT.  This is deliberate: the agent service has its arguments compiled into
# the exe (18 found this, memory [691]) and its .ini has no field for them, so a default here fixes
# EVERY caller at once -- scheduled task, service, shortcuts, other machines -- instead of chasing
# each entry point.  Two paths disagreeing about tools made them delete each other's rows every
# cycle (18 measured tool rows 2255 -> 1453 and 803 dropped archives in 30 minutes).
$IncludeTools = -not $NoTools
$script:CliVersion = '1.3.4'

# --- machine-specific paths are optional: auto-detect so one set of files works on any box ---
if (-not $cfg.extractor -or -not (Test-Path -LiteralPath $cfg.extractor)) {
  $cfg | Add-Member -NotePropertyName extractor -NotePropertyValue (Join-Path $Root 'dsh-zstd-extract.js') -Force
}
if (-not $cfg.sessionsRoot -or -not (Test-Path -LiteralPath $cfg.sessionsRoot)) {
  $cand = Join-Path $env:USERPROFILE '.dsh\sessions'
  if (-not (Test-Path -LiteralPath $cand)) {
    # running as SYSTEM or another account: locate the profile that actually owns DSH sessions
    $found = Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      $q = Join-Path $_.FullName '.dsh\sessions'
      if (Test-Path -LiteralPath $q) { Get-Item -LiteralPath $q }
    } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($found) { $cand = $found.FullName }
  }
  $cfg | Add-Member -NotePropertyName sessionsRoot -NotePropertyValue $cand -Force
}
if (-not $cfg.node -or -not (Test-Path -LiteralPath $cfg.node)) {
  $n = $null
  $rt = Join-Path $env:USERPROFILE '.dsh\dsh-runtimes'
  if (Test-Path -LiteralPath $rt) {
    $n = Get-ChildItem $rt -Recurse -Filter node.exe -File -ErrorAction SilentlyContinue |
         Sort-Object Length -Descending | Select-Object -First 1 -ExpandProperty FullName
  }
  if (-not $n) { $g = Get-Command node -ErrorAction SilentlyContinue; if ($g) { $n = $g.Source } }
  if ($n) { $cfg | Add-Member -NotePropertyName node -NotePropertyValue $n -Force }
}
Add-Type -AssemblyName System.Data

$script:Db          = $cfg.database
$script:CsBase      = "Server=$($cfg.server);User Id=$($cfg.user);Password=$($cfg.password);TrustServerCertificate=True;Connect Timeout=20"
$script:StatePath   = Join-Path $Root 'dsh-mem-state.json'
$script:ReplicaPath = Join-Path $Root 'dsh-mem-replica.json'
$script:ReplicaError = ''
$script:RedactList  = @()
if ($cfg.redact) { $script:RedactList = @($cfg.redact) }
$script:State       = if (Test-Path -LiteralPath $script:StatePath) {
                        try { Read-TextFile $script:StatePath | ConvertFrom-Json } catch { [pscustomobject]@{} }
                      } else { [pscustomobject]@{} }

function New-Cn([string]$db) {
  $cn = New-Object System.Data.SqlClient.SqlConnection ("Server=$($cfg.server);Database=$db;User Id=$($cfg.user);Password=$($cfg.password);TrustServerCertificate=True;Connect Timeout=20")
  $cn.Open()
  return $cn
}

function Test-DbAlive {
  try {
    $cn = New-Object System.Data.SqlClient.SqlConnection ("Server=$($cfg.server);Database=$($script:Db);User Id=$($cfg.user);Password=$($cfg.password);TrustServerCertificate=True;Connect Timeout=3")
    $cn.Open(); $cn.Close(); return $true
  } catch { return $false }
}

function Get-Replica {
  # On failure the reason is KEPT, not swallowed: the previous silent `return $null`
  # is what let the ANSI-decoding bug hide behind "no local replica" (memory [117]).
  if (-not (Test-Path -LiteralPath $script:ReplicaPath)) { $script:ReplicaError = 'replica file not found'; return $null }
  try { return (Read-TextFile $script:ReplicaPath | ConvertFrom-Json) } catch { $script:ReplicaError = $_.Exception.Message; return $null }
}

function Write-NoReplica {
  Write-Host "  database unreachable AND no local replica. Run: dsh-mem.ps1 replica"
  if ($script:ReplicaError) { Write-Host ("  replica error: " + $script:ReplicaError) }
}

function Invoke-Rows {
  param([string]$Sql, [hashtable]$Params = @{}, [string]$Db)
  if (-not $Db) { $Db = $script:Db }
  $cn = New-Cn $Db
  try {
    $cmd = $cn.CreateCommand(); $cmd.CommandText = $Sql; $cmd.CommandTimeout = 120
    foreach ($k in $Params.Keys) { [void]$cmd.Parameters.AddWithValue($k, $Params[$k]) }
    $rd = $cmd.ExecuteReader()
    $rows = New-Object System.Collections.ArrayList
    while ($rd.Read()) {
      $h = [ordered]@{}
      for ($i = 0; $i -lt $rd.FieldCount; $i++) {
        $v = $rd.GetValue($i)
        # ★ Use -is, never -eq [DBNull]::Value: for an ARRAY value (byte[] columns such as
        # dbo.embeddings.vec) PowerShell's -eq compares ELEMENT BY ELEMENT, so reading 2523
        # x 4096-byte vectors cost ~10 million comparisons and the query appeared to hang
        # (measured 2026-10-06, memory [142]).  -is is a type test and never enumerates.
        $h[$rd.GetName($i)] = $(if ($v -is [DBNull]) { $null } else { $v })
      }
      [void]$rows.Add([pscustomobject]$h)
    }
    $rd.Close()
    return ,$rows.ToArray()
  } finally { $cn.Close() }
}

function Invoke-Exec {
  param([string]$Sql, [hashtable]$Params = @{}, [string]$Db)
  if (-not $Db) { $Db = $script:Db }
  $cn = New-Cn $Db
  try {
    $cmd = $cn.CreateCommand(); $cmd.CommandText = $Sql; $cmd.CommandTimeout = 300
    foreach ($k in $Params.Keys) { [void]$cmd.Parameters.AddWithValue($k, $Params[$k]) }
    return $cmd.ExecuteNonQuery()
  } finally { $cn.Close() }
}

function Register-Host {
  # register this machine in dbo.machines. HOST_NAME() and SUSER_SNAME() are supplied by
  # SQL Server itself, so a machine cannot claim to be another one.
  # cli_version is what makes "unified version" checkable from the database host instead of by
  # comparing byte counts (memory [177]/[178] got that wrong twice in one hour).
  try {
    [void](Invoke-Exec -Sql @"
MERGE dbo.machines AS t
USING (SELECT SUSER_SNAME() AS login_name, HOST_NAME() AS machine, @v AS cli_version) AS s
   ON t.login_name = s.login_name
WHEN MATCHED THEN UPDATE SET machine = s.machine, cli_version = s.cli_version, last_seen = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT (login_name, machine, cli_version) VALUES (s.login_name, s.machine, s.cli_version);
"@ -Params @{ '@v' = $script:CliVersion })
  } catch {
    # older database without the cli_version column: still register, just without the version
    try {
      [void](Invoke-Exec -Sql @"
MERGE dbo.machines AS t
USING (SELECT SUSER_SNAME() AS login_name, HOST_NAME() AS machine) AS s
   ON t.login_name = s.login_name
WHEN MATCHED THEN UPDATE SET machine = s.machine, last_seen = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT (login_name, machine) VALUES (s.login_name, s.machine);
"@)
    } catch { }
  }
}

function Get-Text([object]$content) {
  if ($null -eq $content) { return '' }
  $sb = New-Object System.Text.StringBuilder
  foreach ($b in $content) {
    if ($b.type -eq 'text' -and $b.text) { [void]$sb.AppendLine([string]$b.text) }
  }
  return $sb.ToString().Trim()
}

function Protect-Text([string]$t) {
  # 2026-10-22 OWNER POLICY (memory 22589): local files and the DB are NOT redacted.
  # The old implementation rewrote stored text (sk-*, password=..., Dsh..#...) which silently
  # destroyed conversation records -- that was a direct cause of the "amnesia".
  # Kept as a function so every caller keeps working; it is now a pass-through.
  # Hard rule that still stands: secrets must never leave the LAN in clear text, and
  # shared/cold copies are sanitized at copy time (not at storage time).
  return $t
}

function Get-SecretHitCount([string]$t) {
  # 2026-10-22: storage is not redacted any more, so there is nothing to count/warn about here.
  # (External-copy sanitisation is a separate, explicit step.)
  return 0
}

function Write-ExportNote([string]$path, [string]$what, [int]$hits) {
  # Every file this tool writes contains dialogue and/or memory bodies.  Say it, every time:
  # two of these exports had to be scrubbed by hand on 2026-10-06 because nobody treated them
  # as sensitive (memory [196]).
  Write-Host ("      note: " + $what + " contains conversation/memory text - treat as sensitive, do not copy to shared folders")
  if ($hits -gt 0) {
    Write-Host ("      WARN: " + $hits + " possible secret pattern(s) still visible in " + $path)
    Write-Host  "            (redaction only removes what it knows; review before sharing)"
  }
}

# Column limits mirror dbo.memories.  They exist so a too-long value fails with a sentence that
# names the field, instead of letting SQL Server raise a truncation error that (a) reads like a
# database outage and (b) quotes the truncated value back -- a half-leak.  Reported by 18 as [262]
# after a 205-character title died on `save`.  Guard check 15 tests both boundaries.
$script:ColLimits = [ordered]@{
  scope          = 32
  subject        = 128
  kind           = 32
  title          = 200
  tags           = 200
  source_session = 64
}

function Assert-Length([string]$field, [string]$value, [int]$limit) {
  # Normalise JSON-escaped quotes/newlines and SQL placeholders: they survive redaction and
  # used to be counted as secrets (rules R31).
  $t = $t -replace '\\u0027|\\u0022|\\n|\\r|\\t', ' '
  $t = $t -replace '<PW>|<pw>|<password>|<secret>', ' '
  $n = 0
  if ($value) { $n = $value.Length }
  if ($n -gt $limit) {
    # Never echo the value: the raw SQL error quoted the truncated title, which is exactly how a
    # fragment escapes into a terminal or a log file (same pattern as rule R6).
    throw ($field + " too long: " + $n + " > " + $limit + " characters (dbo.memories." + $field + ") -- shorten it, or use -TitleFile with a shorter first line")
  }
}

function ConvertFrom-Jsonl {
  param([string]$Path)
  $raw = [System.IO.File]::ReadAllLines($Path)
  $out = New-Object System.Collections.ArrayList
  foreach ($l in $raw) {
    if ([string]::IsNullOrWhiteSpace($l)) { continue }
    try { [void]$out.Add(($l | ConvertFrom-Json)) } catch { }
  }
  return ,$out.ToArray()
}

function Save-State {
  try { [System.IO.File]::WriteAllText($script:StatePath, ($script:State | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding $false)) } catch { }
}

function Invoke-Sync {
  param([string]$SessionFile)

  if (-not (Test-Path -LiteralPath $SessionFile)) { throw "session file not found: $SessionFile" }
  if (-not (Test-Path -LiteralPath $cfg.node))      { throw "node not found: $($cfg.node)" }
  if (-not (Test-Path -LiteralPath $cfg.extractor)) { throw "extractor not found: $($cfg.extractor)" }

  # --- skip unchanged session logs: makes a 1-2 minute schedule nearly free ---
  $fi  = Get-Item -LiteralPath $SessionFile -ErrorAction SilentlyContinue
  $key = "$($fi.Length):$($fi.LastWriteTimeUtc.Ticks)"
  if (-not $Force) {
    $prev = $null
    try { $prev = $script:State.$SessionFile } catch { }
    if ($prev -eq $key) {
      Write-Host ("  skip (unchanged): " + [System.IO.Path]::GetFileName((Split-Path -Parent $SessionFile)))
      return
    }
  }

  $tmp = Join-Path $env:TEMP ("dsh_sess_" + [guid]::NewGuid().ToString('N') + ".jsonl")
  $meta = & $cfg.node $cfg.extractor $SessionFile $tmp | ConvertFrom-Json
  Write-Host ("  extract: {0} frames (ok {1} / bad {2}), {3:N1} MB text" -f $meta.frames, $meta.okFrames, $meta.badFrames, ($meta.outputBytes / 1MB))

  $events = ConvertFrom-Jsonl -Path $tmp
  $header = $events | Where-Object { $_.type -eq 'session' } | Select-Object -First 1
  $sid = if ($header) { [string]$header.id } else { [System.IO.Path]::GetFileName((Split-Path -Parent $SessionFile)) }
  $cwd = if ($header) { [string]$header.cwd } else { '' }
  $titleEvent = $events | Where-Object { $_.type -eq 'session/title' } | Select-Object -Last 1
  $sessTitle = if ($titleEvent) { [string]$titleEvent.data.title } else { '' }

  $dt = New-Object System.Data.DataTable
  [void]$dt.Columns.Add('session_id', [string])
  [void]$dt.Columns.Add('seq',        [int64])
  [void]$dt.Columns.Add('turn',       [int])
  [void]$dt.Columns.Add('role',       [string])
  [void]$dt.Columns.Add('text',       [string])
  [void]$dt.Columns.Add('created_at', [datetime])

  $nUser = 0; $nAsst = 0; $nTool = 0
  foreach ($e in $events) {
    $ts = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$e.time).UtcDateTime
    switch ($e.type) {
      'user/message' {
        $t = Get-Text $e.data.content
        if (-not $t) { $t = '[user: empty]' } $r = $dt.NewRow(); $r.session_id = $sid; $r.seq = [int64]$e.seq; $r.turn = [DBNull]::Value; $r.role = 'user'; $r.text = $t; $r.created_at = $ts; [void]$dt.Rows.Add($r); $nUser++
      }
      'assistant/message' {
        $t = Get-Text $e.data.message.content
        if (-not $t) { $t = '[assistant: tool-call only]' } $r = $dt.NewRow(); $r.session_id = $sid; $r.seq = [int64]$e.seq; $r.turn = [int]$e.data.turn; $r.role = 'assistant'; $r.text = $t; $r.created_at = $ts; [void]$dt.Rows.Add($r); $nAsst++
      }
      'tool/call' {
        if ($IncludeTools) {
          $arg = [string]$e.data.arguments
          if ($arg.Length -gt 8000) { $arg = $arg.Substring(0, 8000) + '...[truncated at 8000 chars]' }
          $t = ('[' + $e.data.name + '] ' + $arg)
          $r = $dt.NewRow(); $r.session_id = $sid; $r.seq = [int64]$e.seq; $r.turn = [int]$e.data.turn; $r.role = 'tool_call'; $r.text = $t; $r.created_at = $ts; [void]$dt.Rows.Add($r); $nTool++
        }
      }
      'tool/result' {
        if ($IncludeTools) {
          $t = Get-Text $e.data.message.content
          if ($t.Length -gt 64000) { $t = $t.Substring(0, 64000) + '...[truncated at 64000 chars]' }
          if (-not $t) { $t = '[tool_result: empty]' } $r = $dt.NewRow(); $r.session_id = $sid; $r.seq = [int64]$e.seq; $r.turn = [int]$e.data.turn; $r.role = 'tool_result'; $r.text = $t; $r.created_at = $ts; [void]$dt.Rows.Add($r); $nTool++
        }
      }
    }
  }

  # redact secrets before anything reaches the database
  foreach ($row in $dt.Rows) { $row.text = Protect-Text ([string]$row.text) }
  # FAIL CLOSED for TOOL rows only (policy B, memory [511]): tool text is raw operational text and
  # the literal redact list cannot know every shape a secret takes.  Measured 2026-10-06: Protect-Text
  # catches everything observed so far, so this net currently never fires -- it exists for the shape we
  # do NOT know yet.  Conversation rows are NOT withheld: we discuss redaction patterns in them.
  $withheld = 0
  foreach ($row in $dt.Rows) {
    if ([string]$row.role -like 'tool*' -and (Get-SecretHitCount ([string]$row.text)) -gt 0) {
      $row.text = '[withheld: the tool text still matched a secret pattern after redaction (rules R31)]'
      $withheld++
    }
  }

  # --- archive-before-delete + UPSERT: "memory with time" phases 1+2 (memory [326], [404], [421]) --
  # Phase 1 kept history.  Phase 2 also stops burning identity values: DELETE + full re-INSERT used
  # to change every row id on every sync (measured on 11: an UNCHANGED log burned 12 ids and changed
  # 12/12 seq ids; the table held ~3.5k rows while max(id) passed 600k).  Stable ids also stop the
  # vector table from constantly needing to re-point at new message ids.
  # The batch is staged ONCE in #incoming on a single connection, then, in this order:
  #   1) archive everything the batch does not reproduce (missing seq => 'dropped', changed => 'changed')
  #   2) UPDATE those rows in place  (id unchanged)
  #   3) INSERT the seqs that are new
  #   4) DELETE the seqs the log no longer has -- only AFTER their copy is in messages_history
  # Read paths are untouched: dbo.messages still mirrors the current log.
  # Verified before promotion (2026-10-06): prototype 97280 / 8400CEC192DC6073 scored 6/6 on the
  # semantics probe where 1.1.0 scored 4/6 (P2/P3 = exactly the upsert properties), burned 0 ids
  # where 1.1.0 burned 12, and still passed the 32-check regression guard.
  $archDropped = 0; $archChanged = 0; $updIns = 0; $updUpd = 0; $updRem = 0
  if ($SkipArchive) {
    Write-Host "  WARNING: -SkipArchive is set -- rows the log no longer has will be deleted WITHOUT a copy" -ForegroundColor Yellow
  }
  $cnW = New-Cn $script:Db
  try {
    $cmdW = $cnW.CreateCommand()
    $cmdW.CommandText = "CREATE TABLE #incoming (seq bigint NOT NULL, turn int NULL, role varchar(24) NOT NULL, text nvarchar(max) NULL, created_at datetime2(3) NOT NULL);"
    [void]$cmdW.ExecuteNonQuery()

    $stg = New-Object System.Data.DataTable
    [void]$stg.Columns.Add('seq',        [int64])
    [void]$stg.Columns.Add('turn',       [int])
    [void]$stg.Columns.Add('role',       [string])
    [void]$stg.Columns.Add('text',       [string])
    [void]$stg.Columns.Add('created_at', [datetime])
    foreach ($row in $dt.Rows) {
      $r2 = $stg.NewRow()
      $r2.seq = [int64]$row.seq; $r2.turn = $row.turn; $r2.role = [string]$row.role
      $r2.text = [string]$row.text; $r2.created_at = [datetime]$row.created_at
      [void]$stg.Rows.Add($r2)
    }
    $bcIn = New-Object System.Data.SqlClient.SqlBulkCopy $cnW
    $bcIn.DestinationTableName = '#incoming'
    $bcIn.BatchSize = 500
    foreach ($col in @('seq', 'turn', 'role', 'text', 'created_at')) { [void]$bcIn.ColumnMappings.Add($col, $col) }
    $bcIn.WriteToServer($stg)
    $bcIn.Close()

    $cmdW = $cnW.CreateCommand()
    $cmdW.CommandText = @"
DECLARE @dropped int, @changed int, @ins int, @upd int, @del int;
SELECT @dropped = COUNT(*) FROM dbo.messages m LEFT JOIN #incoming i ON i.seq = m.seq
  WHERE m.session_id = @sid AND i.seq IS NULL;
SELECT @changed = COUNT(*) FROM dbo.messages m JOIN #incoming i ON i.seq = m.seq
  WHERE m.session_id = @sid AND (CONVERT(varchar(32), HASHBYTES('MD5', m.text), 2) <> CONVERT(varchar(32), HASHBYTES('MD5', i.text), 2)
        OR ISNULL(m.role, '') <> ISNULL(i.role, '') OR ISNULL(m.turn, -1) <> ISNULL(i.turn, -1));
INSERT INTO dbo.messages_history (id, session_id, seq, turn, role, text, created_at, archive_reason, archived_by)
SELECT m.id, m.session_id, m.seq, m.turn, m.role, m.text, m.created_at,
       CASE WHEN i.seq IS NULL THEN 'dropped' ELSE 'changed' END, @by
FROM dbo.messages m LEFT JOIN #incoming i ON i.seq = m.seq
WHERE m.session_id = @sid
  AND (i.seq IS NULL OR CONVERT(varchar(32), HASHBYTES('MD5', m.text), 2) <> CONVERT(varchar(32), HASHBYTES('MD5', i.text), 2)
       OR ISNULL(m.role, '') <> ISNULL(i.role, '') OR ISNULL(m.turn, -1) <> ISNULL(i.turn, -1));
UPDATE m SET m.turn = i.turn, m.role = i.role, m.text = i.text, m.created_at = i.created_at
FROM dbo.messages m JOIN #incoming i ON i.seq = m.seq
WHERE m.session_id = @sid
  AND (CONVERT(varchar(32), HASHBYTES('MD5', m.text), 2) <> CONVERT(varchar(32), HASHBYTES('MD5', i.text), 2)
       OR ISNULL(m.role, '') <> ISNULL(i.role, '') OR ISNULL(m.turn, -1) <> ISNULL(i.turn, -1));
SET @upd = @@ROWCOUNT;
INSERT INTO dbo.messages (session_id, seq, turn, role, text, created_at)
SELECT @sid, i.seq, i.turn, i.role, i.text, i.created_at FROM #incoming i
WHERE NOT EXISTS (SELECT 1 FROM dbo.messages m WHERE m.session_id = @sid AND m.seq = i.seq);
SET @ins = @@ROWCOUNT;
DELETE m FROM dbo.messages m
WHERE m.session_id = @sid AND NOT EXISTS (SELECT 1 FROM #incoming i WHERE i.seq = m.seq);
SET @del = @@ROWCOUNT;
SELECT @dropped AS dropped, @changed AS changed, @ins AS inserted, @upd AS updated, @del AS removed;
"@
    [void]$cmdW.Parameters.AddWithValue('@sid', $sid)
    [void]$cmdW.Parameters.AddWithValue('@by', [string]$env:COMPUTERNAME)
    $rdW = $cmdW.ExecuteReader()
    if ($rdW.Read()) {
      $archDropped = [int]$rdW.GetValue(0); $archChanged = [int]$rdW.GetValue(1)
      $updIns = [int]$rdW.GetValue(2); $updUpd = [int]$rdW.GetValue(3); $updRem = [int]$rdW.GetValue(4)
    }
    $rdW.Close()
  } catch {
    # fail closed: no archive/write -> the session's rows are left untouched and the log stays on disk
    throw ("phase 1+2 write failed, refusing to touch this session's rows: " + $_.Exception.Message)
  } finally { $cnW.Close() }

  [void](Invoke-Exec -Sql @"
MERGE dbo.sessions AS t
USING (SELECT @sid AS session_id, @machine AS machine, @cwd AS cwd, @title AS title) AS s
   ON t.session_id = s.session_id
WHEN MATCHED THEN UPDATE SET machine=s.machine, cwd=s.cwd, title=s.title, last_seen_at=SYSUTCDATETIME(), event_count=@cnt
WHEN NOT MATCHED THEN INSERT (session_id, machine, cwd, title, event_count) VALUES (s.session_id, s.machine, s.cwd, s.title, @cnt);
"@ -Params @{ '@sid' = $sid; '@machine' = $env:COMPUTERNAME; '@cwd' = $cwd; '@title' = $sessTitle; '@cnt' = $events.Count })
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

  # remember what we imported so the next run can skip it
  $script:State | Add-Member -NotePropertyName $SessionFile -NotePropertyValue $key -Force
  Save-State

  Write-Host ("  session : $sid")
  Write-Host ("  title   : $sessTitle")
  Write-Host ("  imported: user=$nUser assistant=$nAsst tool=$nTool total=$($dt.Rows.Count)")
  Write-Host ("  upsert  : inserted=$updIns updated=$updUpd removed=$updRem")
  if ($withheld -gt 0) { Write-Host ("  withheld: " + $withheld + " tool row(s) whose text still matched a secret pattern after redaction (rules R31)") }
  if ($withheld -gt 0) { Write-Host ("  withheld: " + $withheld + " tool row(s) whose text still matched a secret pattern after redaction (rules R31)") }
  Write-Host ("  archived: dropped=$archDropped changed=$archChanged" + $(if ($archDropped -gt 0) { "   <- the log no longer has those rows; they survive in dbo.messages_history" } else { '' }))
  if ($archDropped -gt 0 -or $archChanged -gt 0) {
    Write-Host ("            trace them with: dsh-mem.ps1 history -Session " + $sid)
  }
}

# ---------------- recall (D plan) + semantic hook (F plan) ----------------

function ConvertTo-LikePattern([string]$Text) {
  # A user query is not a pattern: %, _ and [ must be bracket-escaped, otherwise the
  # search silently widens (or throws) instead of looking for what was typed.
  $t = $Text.Replace('[', '[[]')
  $t = $t.Replace('%', '[%]')
  $t = $t.Replace('_', '[_]')
  return $t
}

function Find-Memories {
  param([string]$Like, [int]$Limit)
  # NOTE: Invoke-Rows returns the row array as ONE pipeline item (it must, so a
  # single-row result is still indexable as $r[0]).  Always assign it first and
  # return the variable: `return (Invoke-Rows ...)` would emit one item that IS the
  # array, and a caller writing @(Find-Memories ...) would then get a 1-element array
  # wrapping the rows (this exact nesting bug bit recall on 2026-10-06).
  $r = Invoke-Rows -Sql "SELECT TOP (@n) id, created_at, scope, subject, kind, title, body FROM dbo.memories WHERE title LIKE @q OR body LIKE @q OR tags LIKE @q ORDER BY updated_at DESC" -Params @{ '@n' = $Limit; '@q' = $Like }
  return $r
}

function Find-Messages {
  param([string]$Like, [int]$Limit)
  $r = Invoke-Rows -Sql "SELECT TOP (@n) m.id, m.session_id, s.machine, s.title, m.seq, m.role, CONVERT(varchar(33), m.created_at, 126) + 'Z' AS created_at, LEFT(m.text, 600) AS snippet FROM dbo.messages m LEFT JOIN dbo.sessions s ON s.session_id = m.session_id WHERE m.text LIKE @q ORDER BY m.id DESC" -Params @{ '@n' = $Limit; '@q' = $Like }
  return $r
}

function Get-MessagesByHash {
  # Resolve semantic hits by CONTENT rather than by id.  sync is DELETE + re-INSERT per
  # session, so every sync of an active session gives its messages new ids; an id lookup
  # silently loses exactly the content written most recently (memory [146]).
  # Picks the newest row when the same content exists more than once.
  param([string[]]$Hashes, [int]$Chars, [int]$Limit)
  $hs = @($Hashes | Where-Object { $_ })
  if ($hs.Count -eq 0) { return @() }
  $lits = @($hs | Select-Object -First ([Math]::Max(1, $Limit)) | ForEach-Object { '0x' + $_ })
  $sql = @"
;WITH h AS (
  SELECT CONVERT(binary(16), HASHBYTES('MD5', LEFT(ISNULL(text, ''), @chars))) AS text_hash, MAX(id) AS id
  FROM dbo.messages
  WHERE CONVERT(binary(16), HASHBYTES('MD5', LEFT(ISNULL(text, ''), @chars))) IN ($($lits -join ','))
  GROUP BY CONVERT(binary(16), HASHBYTES('MD5', LEFT(ISNULL(text, ''), @chars)))
)
SELECT m.id, m.session_id, s.machine, s.title, m.seq, m.role,
       CONVERT(varchar(33), m.created_at, 126) + 'Z' AS created_at,
       h.text_hash, LEFT(m.text, 600) AS snippet
FROM h JOIN dbo.messages m ON m.id = h.id
       LEFT JOIN dbo.sessions s ON s.session_id = m.session_id
"@
  $r = Invoke-Rows -Sql $sql -Params @{ '@chars' = $Chars }
  return $r
}

function Get-MessagesById {
  param([object[]]$Ids, [int]$Limit)
  $ids = @($Ids | Select-Object -First $Limit)
  if ($ids.Count -eq 0) { return @() }
  $ph = @(); $pp = @{}; $i = 0
  foreach ($id in $ids) { $n = '@i' + $i; $ph += $n; $pp[$n] = [int64]$id; $i++ }
  $r = Invoke-Rows -Sql ("SELECT m.id, m.session_id, s.machine, s.title, m.seq, m.role, CONVERT(varchar(33), m.created_at, 126) + 'Z' AS created_at, LEFT(m.text, 600) AS snippet FROM dbo.messages m LEFT JOIN dbo.sessions s ON s.session_id = m.session_id WHERE m.id IN (" + ($ph -join ',') + ")") -Params $pp
  return $r
}

function Get-MemoriesById {
  param([object[]]$Ids)
  $ids = @($Ids)
  if ($ids.Count -eq 0) { return @() }
  $ph = @(); $pp = @{}; $i = 0
  foreach ($id in $ids) { $n = '@i' + $i; $ph += $n; $pp[$n] = [int64]$id; $i++ }
  $r = Invoke-Rows -Sql ("SELECT id, created_at, scope, subject, kind, title, body FROM dbo.memories WHERE id IN (" + ($ph -join ',') + ")") -Params $pp
  return $r
}

function Get-EmbedSettings {
  # F-plan hook.  Nothing below is active until dsh-mem.config.json gains:
  #   "embed": { "baseURL": "http://192.0.2.18:11434", "model": "bge-m3", "dim": 1024 }
  # baseURL must be the model host's IP -- 127.0.0.1 would only work on that host.
  if (-not $cfg.embed) { return $null }
  $b = [string]$cfg.embed.baseURL
  $m = [string]$cfg.embed.model
  if ([string]::IsNullOrWhiteSpace($b) -or [string]::IsNullOrWhiteSpace($m)) { return $null }
  $dim = 0
  if ($cfg.embed.dim) { $dim = [int]$cfg.embed.dim }
  $ch = 1200
  if ($cfg.embed.chars) { $ch = [int]$cfg.embed.chars }
  return [pscustomobject]@{ baseURL = $b.TrimEnd('/'); model = $m; dim = $dim; chars = $ch }
}

function Convert-BytesToFloats {
  param([byte[]]$Bytes)
  if (-not $Bytes -or $Bytes.Length -lt 4) { return ,([single[]]@()) }
  $n = [int]($Bytes.Length / 4)
  $out = New-Object single[] $n
  [System.Buffer]::BlockCopy($Bytes, 0, $out, 0, ($n * 4))
  return ,$out
}

function Convert-FloatsToBytes {
  # inverse of Convert-BytesToFloats: float32 little-endian, the layout the F proposal
  # stores in dbo.embeddings.vec
  param([single[]]$Floats)
  if (-not $Floats -or $Floats.Length -eq 0) { return ,([byte[]]@()) }
  $bytes = New-Object byte[] ($Floats.Length * 4)
  [System.Buffer]::BlockCopy($Floats, 0, $bytes, 0, $bytes.Length)
  return ,$bytes
}

function Convert-HexToFloats {
  param([string]$Hex)
  $bytes = New-Object byte[] ([int]($Hex.Length / 2))
  for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16) }
  return ,(Convert-BytesToFloats $bytes)
}

function Get-Cosine {
  param([single[]]$A, [single[]]$B)
  if (-not $A -or -not $B) { return -1.0 }
  $n = [Math]::Min($A.Length, $B.Length)
  if ($n -eq 0) { return -1.0 }
  $dot = 0.0; $na = 0.0; $nb = 0.0
  for ($i = 0; $i -lt $n; $i++) {
    $dot += [double]$A[$i] * [double]$B[$i]
    $na  += [double]$A[$i] * [double]$A[$i]
    $nb  += [double]$B[$i] * [double]$B[$i]
  }
  if ($na -le 0 -or $nb -le 0) { return -1.0 }
  return $dot / ([Math]::Sqrt($na) * [Math]::Sqrt($nb))
}

function Get-VectorScores {
  # Cosine similarity of one query vector against a PACKED buffer of float32 vectors.
  # WHY COMPILED: the pure-PowerShell loop needed more than two minutes for 2500 x 1024
  # floats (measured 2026-10-06), which makes semantic recall unusable interactively.
  # The C# kernel is compiled once per process (~1 s) and then scores the whole set in
  # milliseconds.  If Add-Type is unavailable (constrained language mode) the PowerShell
  # loop is used instead -- slower, but never a new failure mode.
  param([byte[]]$Flat, [int]$Dim, [int]$Count, [single[]]$Query)
  if ($null -eq $script:VecKernel) {
    try {
      if (-not ('DshMemVec' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
public class DshMemVec {
  public static float[] CosineAll(byte[] flat, int dim, int count, float[] q) {
    int total = dim * count;
    float[] v = new float[total];
    Buffer.BlockCopy(flat, 0, v, 0, total * 4);
    float[] s = new float[count];
    double qn = 0.0;
    for (int i = 0; i < dim; i++) { double x = q[i]; qn += x * x; }
    double qnorm = Math.Sqrt(qn);
    for (int r = 0; r < count; r++) {
      int off = r * dim;
      double dot = 0.0, vn = 0.0;
      for (int i = 0; i < dim; i++) { double x = v[off + i]; dot += (double)q[i] * x; vn += x * x; }
      s[r] = (float)(dot / (qnorm * Math.Sqrt(vn) + 1e-12));
    }
    return s;
  }
}
"@ -ErrorAction Stop
      }
      $script:VecKernel = 'csharp'
    } catch { $script:VecKernel = 'powershell' }
  }
  if ($script:VecKernel -eq 'csharp') { return ,([single[]][DshMemVec]::CosineAll($Flat, $Dim, $Count, $Query)) }
  $out = New-Object single[] $Count
  for ($r = 0; $r -lt $Count; $r++) {
    $slice = New-Object byte[] ($Dim * 4)
    [System.Buffer]::BlockCopy($Flat, ($r * $Dim * 4), $slice, 0, ($Dim * 4))
    $out[$r] = [single](Get-Cosine $Query (Convert-BytesToFloats $slice))
  }
  return ,$out
}

function New-EmbedBody {
  # ONE place that builds the request body, so a fix can never land on only one route.
  # Encoding is deliberately NOT done here: callers must send this string as UTF-8 BYTES.
  param([string]$Text, [string]$Model, [string]$KeepAlive = '', [switch]$OpenAi)
  if ($OpenAi) {
    $h = @{ model = $Model; input = $Text }
  } else {
    $h = @{ model = $Model; prompt = $Text }
    if ($KeepAlive) { $h['keep_alive'] = $KeepAlive }
  }
  return ($h | ConvertTo-Json -Compress)
}

function Get-EmbeddingVector {
  param([string]$Text, $Embed, [string]$KeepAlive = '')
  # Documented test seam: DSH_MEM_QUERY_VEC_HEX injects a query vector as hex, so the
  # cosine/ranking path can be exercised without a live model.  Normal runs never set it.
  $hex = $env:DSH_MEM_QUERY_VEC_HEX
  if ($hex) { return ,(Convert-HexToFloats $hex) }
  # Try the native Ollama route first, then the OpenAI-compatible one.  Both were measured
  # on 18 (Ollama 0.35.1) with a real embedding model; a non-embedding model answers
  # "This server does not support embeddings", which is a per-model property, not a flag.
  # KeepAlive matters for batch runs: 18 runs with OLLAMA_KEEP_ALIVE=0, so without a
  # per-request keep_alive every row would pay the model load again (seconds each).
  #
  # ★ ENCODING (measured 2026-10-06 by capturing the bytes on a local socket, memory [139]):
  #   `Invoke-RestMethod -Body <string>` in Windows PowerShell 5.1 encodes the body with the
  #   ANSI code page: a 2110-byte UTF-8 payload went out as 1237 bytes, every CJK character
  #   became '?' (0x3F) and '·' (C2 B7) collapsed to single-byte B7.  The server embedded the
  #   mojibake without complaining, so the failure is SILENT and poisons every vector --
  #   which is why the body is now always sent as explicit UTF-8 bytes with a charset.
  $errs = @()
  try {
    $uri  = $Embed.baseURL + '/api/embeddings'
    $body = New-EmbedBody -Text $Text -Model $Embed.model -KeepAlive $KeepAlive
    $r = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60
    if ($r.embedding) { return ,([single[]]$r.embedding) }
    $errs += ("no 'embedding' field from " + $uri)
  } catch { $errs += ("native /api/embeddings: " + $_.Exception.Message) }
  try {
    $uri2  = $Embed.baseURL + '/v1/embeddings'
    $body2 = New-EmbedBody -Text $Text -Model $Embed.model -OpenAi
    $r2 = Invoke-RestMethod -Uri $uri2 -Method Post -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($body2)) -TimeoutSec 60
    if ($r2.data -and $r2.data[0].embedding) { return ,([single[]]$r2.data[0].embedding) }
    $errs += ("no 'data[0].embedding' field from " + $uri2)
  } catch { $errs += ("openai /v1/embeddings: " + $_.Exception.Message) }
  throw ("embedding failed for model '" + $Embed.model + "' -- " + ($errs -join ' | '))
}

function Get-EmbeddingBatch {
  # Batch variant: POST /api/embed with an ARRAY of inputs, one HTTP round trip per chunk.
  # Measured need: the per-row route costs roughly 0.3-1 s per row, so a 2400-row corpus
  # would hold the model on the GPU host for tens of minutes.  The batch route moves the
  # same work in a few minutes.  On ANY failure the caller falls back to per-row calls, so
  # this is an optimisation, never a new failure mode.
  # Returns an array (one single[] per input) or $null when the batch route is unusable.
  param([string[]]$Texts, $Embed, [string]$KeepAlive = '')
  if (-not $Texts -or @($Texts).Count -eq 0) { return ,@() }
  $h = @{ model = $Embed.model; input = @($Texts) }
  if ($KeepAlive) { $h['keep_alive'] = $KeepAlive }
  $body = $h | ConvertTo-Json -Compress -Depth 4
  try {
    $r = Invoke-RestMethod -Uri ($Embed.baseURL + '/api/embed') -Method Post -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 300
    if (-not $r.embeddings) { return $null }
    $out = New-Object System.Collections.ArrayList
    foreach ($v in @($r.embeddings)) { [void]$out.Add([single[]]$v) }
    if ($out.Count -ne @($Texts).Count) { return $null }   # shape mismatch: fall back
    return ,@($out)
  } catch {
    return $null
  }
}

function Get-SemanticRecall {
  # Returns @{ ok = $true; model; hits = @(@{item_type;item_id;score}) }
  #     or  @{ ok = $false; reason = '...' }   -- never throws, never silent.
  param([string]$Query, [int]$Top)
  $e = Get-EmbedSettings
  if (-not $e) { return [pscustomobject]@{ ok = $false; reason = "no 'embed' block in dsh-mem.config.json (F plan not wired yet)" } }
  try {
    $has = Invoke-Rows -Sql "SELECT CASE WHEN OBJECT_ID('dbo.embeddings') IS NULL THEN 0 ELSE 1 END AS has_table"
    if ([int]$has[0].has_table -ne 1) { return [pscustomobject]@{ ok = $false; reason = 'dbo.embeddings does not exist yet (F plan not deployed)' } }
    $cnt = Invoke-Rows -Sql "SELECT COUNT(*) AS n FROM dbo.embeddings WHERE model = @m" -Params @{ '@m' = $e.model }
    if ([int]$cnt[0].n -eq 0) { return [pscustomobject]@{ ok = $false; reason = ("no vectors for model '" + $e.model + "'") } }
    $qv = Get-EmbeddingVector -Text $Query -Embed $e
    # text_hash travels with each vector so hits can be resolved by CONTENT later: sync
    # re-inserts messages with new ids, so an id-keyed lookup loses exactly the newest
    # content (memory [146]).
    $rowsRaw = Invoke-Rows -Sql "SELECT item_type, item_id, vec, text_hash FROM dbo.embeddings WHERE model = @m" -Params @{ '@m' = $e.model }
    $rows = @($rowsRaw)
    # Pack all vectors into one buffer, then score them in one compiled call (see
    # Get-VectorScores for why the PowerShell loop is not good enough here).
    $dim = 0
    $packed = New-Object System.Collections.ArrayList
    $chunks = New-Object System.Collections.ArrayList
    foreach ($r in $rows) {
      $b = [byte[]]$r.vec
      if (-not $b -or $b.Length -lt 4) { continue }
      if ($dim -eq 0) { $dim = [int]($b.Length / 4) }
      if ($b.Length -ne ($dim * 4)) { continue }
      [void]$chunks.Add($b); [void]$packed.Add($r)
    }
    if ($packed.Count -eq 0) { return [pscustomobject]@{ ok = $false; reason = 'no usable stored vector for this model' } }
    if ($qv.Length -ne $dim) { return [pscustomobject]@{ ok = $false; reason = ('query dimension ' + $qv.Length + ' != stored dimension ' + $dim + ' (wrong model/dim in the embed block?)') } }
    $flat = New-Object byte[] ($dim * 4 * $packed.Count)
    for ($k = 0; $k -lt $packed.Count; $k++) { $bb = $chunks[$k]; [System.Buffer]::BlockCopy($bb, 0, $flat, ($k * $dim * 4), $bb.Length) }
    $scores = Get-VectorScores -Flat $flat -Dim $dim -Count $packed.Count -Query $qv
    $scored = New-Object System.Collections.ArrayList
    for ($k = 0; $k -lt $packed.Count; $k++) {
      $hb = [byte[]]$packed[$k].text_hash
      $hx = ''
      if ($hb -and $hb.Length -gt 0) { $hx = ([System.BitConverter]::ToString($hb)) -replace '-', '' }
      [void]$scored.Add([pscustomobject]@{ item_type = [string]$packed[$k].item_type; item_id = [int64]$packed[$k].item_id; score = [double]$scores[$k]; hash = $hx })
    }
    # NOTE: do NOT name this $top -- PowerShell variable names are case-insensitive,
    # so $top IS the [int]$Top parameter, and assigning an array to a type-constrained
    # variable throws "Cannot convert System.Object[] to System.Int32" (memory [118]).
    $ranked = @($scored | Sort-Object -Property score -Descending | Select-Object -First $Top)
    return [pscustomobject]@{ ok = $true; model = $e.model; hits = $ranked; scored = $packed.Count }
  } catch {
    # Covers both backend failures and bugs on this path, so the wording stays neutral
    # and the line number is included: a mislabelled "backend error" hides code faults.
    return [pscustomobject]@{ ok = $false; reason = ('semantic path error: ' + $_.Exception.Message + ' (dsh-mem.ps1 line ' + $_.InvocationInfo.ScriptLineNumber + ')') }
  }
}

function Get-RecallContext {
  # For every session that has hits: the hit turns plus [-Context] turns before/after.
  # Overlapping windows are merged, so a cluster of hits stays one continuous block.
  param([object[]]$Hits, [int]$Context)
  $out = New-Object System.Collections.ArrayList
  $bySess = @{}
  foreach ($h in @($Hits)) {
    $sid = [string]$h.session_id
    if (-not $bySess.ContainsKey($sid)) { $bySess[$sid] = New-Object System.Collections.ArrayList }
    [void]$bySess[$sid].Add($h)
  }
  foreach ($sid in @($bySess.Keys)) {
    $hs = @($bySess[$sid])
    $ph = @(); $pp = @{ '@sid' = $sid }; $i = 0
    foreach ($h in $hs) { $n = '@h' + $i; $ph += $n; $pp[$n] = [int64]$h.id; $i++ }
    $rnRaw = Invoke-Rows -Sql (";WITH o AS (SELECT id, ROW_NUMBER() OVER (ORDER BY seq) AS rn FROM dbo.messages WHERE session_id = @sid) SELECT id, rn FROM o WHERE id IN (" + ($ph -join ',') + ")") -Params $pp
    $rn = @($rnRaw)
    if ($rn.Count -eq 0) { continue }    $ranges = New-Object System.Collections.ArrayList
    foreach ($r in $rn) {
      $a = [Math]::Max(1, ([int]$r.rn - $Context))
      $b = [int]$r.rn + $Context
      [void]$ranges.Add(@($a, $b))
    }
    $sorted = @($ranges | Sort-Object -Property { $_[0] })
    $merged = New-Object System.Collections.ArrayList
    foreach ($rg in $sorted) {
      if ($merged.Count -eq 0) { [void]$merged.Add(@([int]$rg[0], [int]$rg[1])); continue }
      $last = $merged[$merged.Count - 1]
      if ([int]$rg[0] -le ([int]$last[1] + 1)) {
        if ([int]$rg[1] -gt [int]$last[1]) { $merged[$merged.Count - 1] = @([int]$last[0], [int]$rg[1]) }
      } else {
        [void]$merged.Add(@([int]$rg[0], [int]$rg[1]))
      }
    }
    $preds = @($merged | ForEach-Object { "(rn BETWEEN " + $_[0] + " AND " + $_[1] + ")" })
    $sql = ";WITH o AS (SELECT id, seq, role, CONVERT(varchar(33), created_at, 126) + 'Z' AS created_at, ROW_NUMBER() OVER (ORDER BY seq) AS rn, LEFT(text, 600) AS text FROM dbo.messages WHERE session_id = @sid) SELECT id, seq, role, created_at, rn, text FROM o WHERE " + ($preds -join ' OR ') + " ORDER BY rn"
    $rowsRaw = Invoke-Rows -Sql $sql -Params @{ '@sid' = $sid }
    $rows = @($rowsRaw)
    [void]$out.Add([pscustomobject]@{
      session_id = $sid
      machine    = [string]$hs[0].machine
      title      = [string]$hs[0].title
      hit_ids    = @($hs | ForEach-Object { [int64]$_.id })
      rows       = $rows
    })
  }
  return @($out | Sort-Object -Property @{ Expression = { if (@($_.rows).Count -gt 0) { [datetime]$_.rows[-1].created_at } else { [datetime]'2000-01-01' } } } -Descending)
}

function Get-RecallContextOffline {
  # Same idea as Get-RecallContext, but over the local replica (needs no database).
  param([object[]]$Messages, [int64[]]$HitIds, [int]$Context)
  $out = New-Object System.Collections.ArrayList
  $bySess = @{}
  foreach ($m in @($Messages)) {
    $sid = [string]$m.session_id
    if (-not $bySess.ContainsKey($sid)) { $bySess[$sid] = New-Object System.Collections.ArrayList }
    [void]$bySess[$sid].Add($m)
  }
  $hitSet = @{}
  foreach ($h in @($HitIds)) { $hitSet[[int64]$h] = $true }
  foreach ($sid in @($bySess.Keys)) {
    $all = @($bySess[$sid] | Sort-Object -Property { [int64]$_.id })
    $idx = @()
    for ($i = 0; $i -lt $all.Count; $i++) { if ($hitSet.ContainsKey([int64]$all[$i].id)) { $idx += $i } }
    if ($idx.Count -eq 0) { continue }
    $keep = @{}
    foreach ($i in $idx) {
      $a = [Math]::Max(0, $i - $Context)
      $b = [Math]::Min($all.Count - 1, $i + $Context)
      for ($j = $a; $j -le $b; $j++) { $keep[$j] = $true }
    }
    $rows = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $all.Count; $i++) { if ($keep.ContainsKey($i)) { [void]$rows.Add($all[$i]) } }
    [void]$out.Add([pscustomobject]@{
      session_id = $sid
      machine    = [string]$all[0].machine
      title      = '(replica)'
      hit_ids    = @($all | Where-Object { $hitSet.ContainsKey([int64]$_.id) } | ForEach-Object { [int64]$_.id })
      rows       = @($rows)
    })
  }
  return @($out | Sort-Object -Property @{ Expression = { if (@($_.rows).Count -gt 0) { [datetime]$_.rows[-1].created_at } else { [datetime]'2000-01-01' } } } -Descending)
}

function Write-RecallContextBlock {
  # Prints one block per session and returns how many hit lines were printed, so the
  # caller can assert that every hit really came through the window (anti-vacuous check,
  # see shared memory [109]).
  param($Blocks)
  $printed = 0
  foreach ($b in @($Blocks)) {
    $last = '-'
    if (@($b.rows).Count -gt 0) { $last = ([datetime]$b.rows[-1].created_at).ToLocalTime().ToString('MM-dd HH:mm') }
    Write-Host ""
    Write-Host ("  ### " + $b.session_id + "  [" + $b.machine + "]  " + $b.title + "   last " + $last)
    foreach ($r in @($b.rows)) {
      $isHit = (@($b.hit_ids) -contains [int64]$r.id)
      $mark = '  '; $lim = 200
      if ($isHit) { $mark = '>>'; $lim = 400; $printed++ }
      $txt = ([string]$r.text) -replace '\s+', ' '
      if ($txt.Length -gt $lim) { $txt = $txt.Substring(0, $lim) + ' ...' }
      Write-Host ("    " + $mark + " " + ([datetime]$r.created_at).ToLocalTime().ToString('HH:mm') + "  " + ([string]$r.role).PadRight(9) + " " + $txt)
    }
  }
  return $printed
}

# ---------------- dispatch ----------------

# every writing command refreshes this machine's roster row
if ($Command -match '^(sync|replica|save|backup)$') { Register-Host }

switch ($Command.ToLower()) {

  'sync' {
    if ($All) {
      $files = Get-ChildItem $cfg.sessionsRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -like '*.jsonl.zstd' }
      Write-Host ("syncing $($files.Count) session file(s)...")
      foreach ($f in $files) {
        Write-Host ("--- " + $f.FullName)
        try { Invoke-Sync -SessionFile $f.FullName } catch { Write-Host ("  FAILED: " + $_.Exception.Message) }
      }
    } else {
      if (-not $Target) {
        $Target = Get-ChildItem $cfg.sessionsRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like '*.jsonl.zstd' } |
                  Sort-Object Length -Descending | Select-Object -First 1 -ExpandProperty FullName
        Write-Host ("no path given, using largest: $Target")
      }
      Invoke-Sync -SessionFile $Target
    }
  }

  'save' {
    # -TitleFile / -BodyFile exist because passing long text through the OS command line
    # is unsafe: with `powershell -File`, a body containing an ODD number of double quotes
    # makes the child fail argument binding and exit 2 with NO output at all -- the memory
    # is simply never written, and nothing says so (reported by 17 as [133]).
    # Reading from a file removes shell quoting from the path entirely.
    if ($TitleFile) {
      if (-not (Test-Path -LiteralPath $TitleFile)) { throw "TitleFile not found: $TitleFile" }
      $Title = (Read-TextFile $TitleFile).Trim()
      Write-Host ("  title from file : " + $TitleFile)
    }
    if ($BodyFile) {
      if (-not (Test-Path -LiteralPath $BodyFile)) { throw "BodyFile not found: $BodyFile" }
      $Body = (Read-TextFile $BodyFile).Trim()
      Write-Host ("  body from file  : " + $BodyFile + "  (" + $Body.Length + " chars)")
    }
    if (-not $Title) { throw "save requires -Title or -TitleFile" }

    $inTitleLen = $Title.Length
    $inBodyLen  = ([string]$Body).Length
# OWNER-AUTHORISED CREDENTIAL STORE (rules R39, user decision 2026-10-07).  kind='secret' is the one
# deliberate exception to "never store a secret in this database": the owner asked for their own
# passwords to live here so they are not forgotten.  Every other kind is still redacted on write.
if ([string]$Kind -eq 'secret') {
  Write-Host "  * SECRET MODE: stored in CLEAR TEXT on purpose (owner authorisation, rules R39)"
  Write-Host "    readable by every machine/login that shares this database; never copy it to a shared folder"
  Write-Host "    read it back with:  dsh-mem.ps1 secrets [<keyword>]"
} else {
  $Title = Protect-Text $Title
  $Body  = Protect-Text $Body
}
    # Pre-check every length-limited column BEFORE touching the database (defect [262]): the raw
    # SQL truncation error named the table/column and quoted the value, which is both confusing
    # and a fragment leak.  Validate what will actually be written (post-redaction lengths).
    Assert-Length 'title'   $Title               $script:ColLimits.title
    Assert-Length 'subject' ([string]$Subject)   $script:ColLimits.subject
    Assert-Length 'kind'    ([string]$Kind)      $script:ColLimits.kind
    Assert-Length 'tags'    ([string]$Tags)      $script:ColLimits.tags
    Assert-Length 'scope'   ([string]$Scope)     $script:ColLimits.scope
    Assert-Length 'source_session' ([string]$Target) $script:ColLimits.source_session
    # Read back what actually landed: INSERT ... OUTPUT gives the row id and the stored
    # length in the same round trip, so a silent failure or a truncation cannot hide.
    $res = Invoke-Rows -Sql @"
INSERT INTO dbo.memories (scope, subject, kind, title, body, tags, source_session, confidence)
OUTPUT INSERTED.id AS id, LEN(INSERTED.title) AS tlen, LEN(INSERTED.body) AS blen
VALUES (@scope, @subject, @kind, @title, @body, @tags, @src, @conf)
"@ -Params @{ '@scope' = $Scope; '@subject' = $Subject; '@kind' = $Kind; '@title' = $Title; '@body' = $Body; '@tags' = $Tags; '@src' = $Target; '@conf' = $Confidence }
    if (@($res).Count -ne 1) { throw "save wrote no row (INSERT returned nothing)" }
    $newId = [int64]$res[0].id
    $gotB  = [int]$res[0].blen
    $gotT  = [int]$res[0].tlen
    Write-Host ("  saved memory id=" + $newId + "  [" + $Kind + "] " + $Title)
    Write-Host ("  readback : title " + $gotT + "/" + $inTitleLen + " chars, body " + $gotB + "/" + $inBodyLen + " chars")
    if ($gotB -ne $inBodyLen -or $gotT -ne $inTitleLen) {
      Write-Host ("  WARN stored length differs from input (redaction or truncation?) -- verify with: dsh-mem.ps1 recent")
    }
  }

  'search' {
    if (-not $Target) { throw "search requires a keyword" }
    $q = '%' + $Target + '%'
    if (Test-DbAlive) {
      Write-Host ("== memories matching '$Target' ==")
      $m = Invoke-Rows -Sql "SELECT TOP (@n) id, created_at, scope, subject, kind, title, tags, body FROM dbo.memories WHERE title LIKE @q OR body LIKE @q OR tags LIKE @q ORDER BY updated_at DESC" -Params @{ '@n' = $Limit; '@q' = $q }
      if (@($m).Count -eq 0) { Write-Host "  (none)" }
      foreach ($r in @($m)) {
        Write-Host ("  [{0}] {1} {2}/{3} {4}  {5}" -f $r.id, $r.created_at.ToLocalTime().ToString('MM-dd HH:mm'), $r.scope, $r.subject, $r.kind, $r.title)
        # 2026-10-22: print the matched fragment. Searching titles only is how a fact that IS
        # in the database still gets "forgotten"; the body must be visible at search time.
        $body = [string]$r.body
        if ($body) {
          $flat = $body -replace '\s+', ' '
          $pos = $flat.IndexOf($Target, [StringComparison]::OrdinalIgnoreCase)
          if ($pos -lt 0) { $pos = 0 }
          $start = [Math]::Max(0, $pos - 70)
          $len = [Math]::Min(260, $flat.Length - $start)
          if ($len -gt 0) {
            $frag = $flat.Substring($start, $len)
            Write-Host ("      ... " + $frag + " ...")
          }
        }
      }
      Write-Host ""
      Write-Host ("== messages matching '$Target' ==")
      $g = Invoke-Rows -Sql "SELECT TOP (@n) session_id, seq, role, created_at, LEFT(text, 200) AS snippet FROM dbo.messages WHERE text LIKE @q ORDER BY created_at DESC" -Params @{ '@n' = $Limit; '@q' = $q }
      if (@($g).Count -eq 0) { Write-Host "  (none)" }
      foreach ($r in @($g)) { Write-Host ("  {0} #{1} {2}: {3}" -f $r.created_at.ToLocalTime().ToString('MM-dd HH:mm'), $r.seq, $r.role, ($r.snippet -replace '\s+', ' ')) }
    } else {
      $rep = Get-Replica
      if (-not $rep) { Write-NoReplica; return }
      Write-Host ("  OFFLINE - local replica, last synced " + $rep.generatedAt)
      $k = $Target.ToLower()
      Write-Host ("== memories matching '$Target' ==")
      $mm = @($rep.memories) | Where-Object { (([string]$_.title) + ' ' + ([string]$_.body) + ' ' + ([string]$_.tags)).ToLower().Contains($k) } | Select-Object -First $Limit
      if (@($mm).Count -eq 0) { Write-Host "  (none)" }
      foreach ($r in @($mm)) {
        Write-Host ("  [{0}] {1} {2}/{3}  {4}" -f $r.id, ([datetime]$r.updated_at).ToLocalTime().ToString('MM-dd HH:mm'), $r.scope, $r.subject, $r.title)
        $body = [string]$r.body
        if ($body) {
          $flat = $body -replace '\s+', ' '
          $pos = $flat.ToLower().IndexOf($k)
          if ($pos -lt 0) { $pos = 0 }
          $start = [Math]::Max(0, $pos - 70)
          $len = [Math]::Min(260, $flat.Length - $start)
          if ($len -gt 0) { Write-Host ("      ... " + $flat.Substring($start, $len) + " ...") }
        }
      }
      Write-Host ""
      Write-Host ("== messages matching '$Target' ==")
      $gg = @($rep.messages) | Where-Object { ([string]$_.text).ToLower().Contains($k) } | Select-Object -First $Limit
      if (@($gg).Count -eq 0) { Write-Host "  (none)" }
      foreach ($r in @($gg)) { Write-Host ("  {0} [{1}] {2}: {3}" -f ([datetime]$r.created_at).ToLocalTime().ToString('MM-dd HH:mm'), $r.machine, $r.role, ((([string]$r.text) -replace '\s+', ' ').Substring(0, [Math]::Min(160, (([string]$r.text) -replace '\s+', ' ').Length)))) }
    }
  }

  'recall' {
    # ---- D plan: context-aware recall --------------------------------------------
    # Preferred backend is semantic search (F plan).  It is used only when the embed
    # config, the vector table and the endpoint all work; otherwise this DEGRADES to
    # literal LIKE plus surrounding turns and prints a DEGRADED line.  Silent
    # degradation is forbidden on purpose: an unavailable backend must be visible.
    if (-not $Target) { throw "recall requires a query (keyword or natural-language question)" }
    if ($Context -lt 0) { $Context = 0 }
    $q       = '%' + (ConvertTo-LikePattern $Target) + '%'
    $semOk   = $false
    $semNote = ''
    $backend = ''
    $srcNote = ''
    $memNote = 'literal match'
    $hitMsg  = @()
    $memRows = @()
    $blocks  = @()

    if (Test-DbAlive) {
      $backend = 'database ' + $cfg.server + ' / ' + $script:Db
      $sem = Get-SemanticRecall -Query $Target -Top ([Math]::Max($Limit * 2, 20))
      if ($sem.ok) {
        $semOk   = $true
        $scoredN = @($sem.hits).Count
        if ($sem.PSObject.Properties['scored']) { $scoredN = [int]$sem.scored }
        $semNote = "OK - model '" + $sem.model + "', " + $scoredN + " vectors scored, top " + @($sem.hits).Count
        $msgHashes = New-Object System.Collections.ArrayList
        $embedChars = 1200
        $es = Get-EmbedSettings
        if ($es -and $es.chars) { $embedChars = [int]$es.chars }
        $msgIds    = New-Object System.Collections.ArrayList
        $memIds    = New-Object System.Collections.ArrayList
        $hashScore = @{}
        $score     = @{}
        foreach ($h in @($sem.hits)) {
          $key = [int64]$h.item_id
          if ($h.item_type -eq 'message') {
            if (-not $msgIds.Contains($key)) { [void]$msgIds.Add($key) }
            $score[$key] = [double]$h.score
            $hx = [string]$h.hash
            if ($hx) {
              $hk = 'm' + $hx
              if (-not $hashScore.ContainsKey($hk)) { $hashScore[$hk] = [double]$h.score; [void]$msgHashes.Add($hx) }
            }
          } elseif ($h.item_type -eq 'memory') {
            if (-not $memIds.Contains($key)) { [void]$memIds.Add($key) }
          }
        }
        # Resolve message hits by CONTENT first (survives the id churn that sync causes).
        if ($msgHashes.Count -gt 0) {
          $rows   = @(Get-MessagesByHash -Hashes @($msgHashes) -Chars $embedChars -Limit $Limit)
          $hitMsg = @($rows | Sort-Object -Property @{ Expression = { $hx = ([System.BitConverter]::ToString([byte[]]$_.text_hash)) -replace '-', ''; $hashScore['m' + $hx] } } -Descending)
        }
        # Fallback: plain id lookup.  Used when the stored hash no longer matches the current
        # text prefix (the embed -Chars setting changed) so the hash join finds nothing.
        if (@($hitMsg).Count -eq 0 -and $msgIds.Count -gt 0) {
          $rows   = @(Get-MessagesById -Ids @($msgIds) -Limit $Limit)
          $hitMsg = @($rows | Sort-Object -Property @{ Expression = { $score[[int64]$_.id] } } -Descending)
        }
        if ($memIds.Count -gt 0) {
          $memRows = @(Get-MemoriesById -Ids @($memIds))
          $memNote = 'semantic hit'
        } else {
          $memRows = @(Find-Memories -Like $q -Limit $Limit)
          $memNote = 'literal (no vectors for memories yet)'
        }
      } else {
        $semNote = 'UNAVAILABLE - ' + $sem.reason
        $hitMsg  = @(Find-Messages -Like $q -Limit $Limit)
        $memRows = @(Find-Memories -Like $q -Limit $Limit)
      }
      if (@($hitMsg).Count -gt 0) { $blocks = @(Get-RecallContext -Hits $hitMsg -Context $Context) }
    } else {
      $rep = Get-Replica
      if (-not $rep) { Write-NoReplica; return }
      $backend = 'OFFLINE replica - last synced ' + $rep.generatedAt
      $srcNote = '   (replica keeps the newest messages, text cut at 800 chars)'
      $semNote = 'UNAVAILABLE - offline replica carries no vectors'
      $k = $Target.ToLower()
      $memRows = @(@($rep.memories) | Where-Object { ((([string]$_.title) + ' ' + ([string]$_.body) + ' ' + ([string]$_.tags)).ToLower().Contains($k)) } | Select-Object -First $Limit)
      $msgs   = @($rep.messages)
      $hitIds = @($msgs | Where-Object { ([string]$_.text).ToLower().Contains($k) } | Sort-Object -Property { [int64]$_.id } -Descending | Select-Object -First $Limit | ForEach-Object { [int64]$_.id })
      $hitMsg = @($hitIds)
      if (@($hitIds).Count -gt 0) { $blocks = @(Get-RecallContextOffline -Messages $msgs -HitIds $hitIds -Context $Context) }
    }

    Write-Host ("== recall '" + $Target + "' ==")
    Write-Host ("  backend  : " + $backend + $srcNote)
    Write-Host ("  semantic : " + $semNote)
    if (-not $semOk) { Write-Host "  [DEGRADED] semantic search unavailable; fell back to literal search + context" }
    Write-Host ("  hits     : memories " + @($memRows).Count + " (" + $memNote + ") / messages " + @($hitMsg).Count + "   limit " + $Limit + ", context +/-" + $Context)

    if ($semOk) {
      # The context blocks below are CHRONOLOGICAL (that is what makes them readable),
      # so without this list the ranking -- the whole point of the semantic backend --
      # would be invisible and unverifiable from the output.
      # ★ Keyed by CONTENT HASH, never by the vector's item_id: that id may already be stale
      #   (sync re-inserts rows with new ids) while the resolver fetched the CURRENT row.
      #   Joining the two by id printed stale ids plus "(not fetched)" for perfectly good
      #   hits -- exactly the defect 17 and 18 measured ([153] / [155]).
      $msgSnipByHash  = @{}
      $msgCurIdByHash = @{}
      foreach ($m in @($hitMsg)) {
        $hx = ''
        if ($m.text_hash) { $hx = ([System.BitConverter]::ToString([byte[]]$m.text_hash)) -replace '-', '' }
        if (-not $hx) { continue }
        $msgSnipByHash['m' + $hx]  = (([string]$m.snippet) -replace '\s+', ' ')
        $msgCurIdByHash['m' + $hx] = [int64]$m.id
      }
      $memTitle = @{}
      foreach ($m in @($memRows)) { $memTitle[[int64]$m.id] = [string]$m.title }
      Write-Host ""
      Write-Host "  -- semantic ranking (cosine, model " -NoNewline
      Write-Host ($sem.model + ") --")
      $rank = 0
      $shownHashes = @{}
      foreach ($h in @($sem.hits)) {
        if ($rank -ge $Limit) { break }
        $vecId  = [int64]$h.item_id
        $showId = $vecId
        $note   = ''
        $txt    = ''
        if ($h.item_type -eq 'message') {
          $hk = 'm' + [string]$h.hash
          # Legacy data can hold several vectors for the same content (that is why the
          # housekeeping now consolidates by hash); never list the same content twice.
          if ($hk -and $shownHashes.ContainsKey($hk)) { continue }
          if ($h.hash -and $msgSnipByHash.ContainsKey($hk)) {
            $shownHashes[$hk] = $true
            $txt    = $msgSnipByHash[$hk]
            $showId = $msgCurIdByHash[$hk]
            if ($showId -ne $vecId) { $note = ' (was #' + $vecId + ')' }
          } else {
            $txt = '(content not found - the message row is gone)'
          }
        } elseif ($h.item_type -eq 'memory') {
          if ($memTitle.ContainsKey($vecId)) { $txt = $memTitle[$vecId] }
          else { $txt = '(content not found - the memory row is gone)' }
        } else {
          $txt = '(unknown item type)'
        }
        if ($txt.Length -gt 90) { $txt = $txt.Substring(0, 90) + ' ...' }
        $rank++
        Write-Host ("    " + $rank + ". " + ('{0:N3}' -f [double]$h.score) + "  " + [string]$h.item_type + " #" + $showId + $note + "  " + $txt)
      }
    }

    if (@($memRows).Count -gt 0) {
      Write-Host ""
      Write-Host ("  -- memories (" + @($memRows).Count + ") --")
      foreach ($r in @($memRows)) {
        $ts = '-'
        if ($r.created_at) { $ts = ([datetime]$r.created_at).ToLocalTime().ToString('MM-dd HH:mm') }
        $lbl = [string]$r.kind
        if ($r.subject) { $lbl = $lbl + '/' + [string]$r.subject }
        Write-Host ("    [" + $r.id + "] " + $ts + "  " + $lbl + "  " + $r.title)
        $b = ([string]$r.body) -replace '\s+', ' '
        if ($b.Length -gt 240) { $b = $b.Substring(0, 240) + ' ...' }
        if ($b) { Write-Host ("         " + $b) }
      }
    }

    if (@($blocks).Count -gt 0) {
      Write-Host ""
      Write-Host ("  -- dialogue context (" + @($blocks).Count + " session(s)) --")
      $printed = Write-RecallContextBlock -Blocks $blocks
      if ($printed -ne @($hitMsg).Count) {
        Write-Host ("  WARN context window printed " + $printed + " hit line(s), expected " + @($hitMsg).Count)
      }
    } elseif (@($memRows).Count -eq 0) {
      Write-Host ""
      Write-Host "  (no matches)"
    }
  }

  'embed' {
    # ---- F plan (semantic search): fill dbo.embeddings so `recall` can use vectors ----
    # Idempotent by design: a row is a candidate only when it has no vector for this model
    # OR the embedded text changed (MD5 of exactly the text that gets embedded).
    $e = Get-EmbedSettings
    $base = ''
    if ($BaseURL) { $base = $BaseURL } elseif ($e) { $base = $e.baseURL }
    $mdl = ''
    if ($Model) { $mdl = $Model } elseif ($e) { $mdl = $e.model }
    if (-not $base -or -not $mdl) {
      throw "embed needs a baseURL and a model. Add to dsh-mem.config.json: `"embed`": { `"baseURL`": `"http://192.0.2.18:11434`", `"model`": `"bge-m3`", `"dim`": 1024 }  (or pass -BaseURL / -Model)"
    }
    $nChars = $Chars
    if ($nChars -le 0 -and $cfg.embed -and $cfg.embed.chars) { $nChars = [int]$cfg.embed.chars }
    if ($nChars -le 0) { $nChars = 1200 }
    $emb = [pscustomobject]@{ baseURL = $base.TrimEnd('/'); model = $mdl; dim = 0 }
    # keep_alive per request: the model host (18) runs OLLAMA_KEEP_ALIVE=0 by policy, so a
    # batch without this would reload the model for every single row.
    $keepAlive = '5m'
    if ($cfg.embed -and $cfg.embed.keepAlive) { $keepAlive = [string]$cfg.embed.keepAlive }
    $nBatch = 16
    if ($cfg.embed -and $cfg.embed.batch) { $nBatch = [int]$cfg.embed.batch }
    if ($nBatch -lt 1) { $nBatch = 1 }
    if ($nBatch -gt 64) { $nBatch = 64 }

    if ($SelfTest) {
      # Regression guard for the ANSI-body bug (memory [139]).  The old code sent the body as
      # a .NET string and PS 5.1 encoded it with the ANSI code page, turning every CJK
      # character into '?' -- the model still answered, so nothing looked wrong.
      # Offline half: the body must still contain the probe.  Online half: the vector of the
      # real probe must differ from the vector of a same-length string of '?' (if the text
      # were mangled, those two would be identical, cosine ~= 1.0).
      $probe = ([string][char]0x7F16 + [char]0x7801 + [char]0x81EA + [char]0x68C0) + ' CJK probe - 2026-10-06'
      $body  = New-EmbedBody -Text $probe -Model $mdl -KeepAlive $keepAlive
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
      $qCount = ([regex]::Matches($body, '\?')).Count
      $kept = $body.Contains(([string][char]0x7F16 + [char]0x7801))
      Write-Host ("  model      : " + $mdl + "   endpoint: " + $emb.baseURL)
      Write-Host ("  probe      : " + $probe + "   (" + $probe.Length + " chars, " + [System.Text.Encoding]::UTF8.GetByteCount($probe) + " UTF-8 bytes)")
      Write-Host ("  body       : " + $bytes.Length + " bytes, '?' substituted: " + $qCount + ", CJK kept: " + $kept)
      $offlineOk = ($kept -and $qCount -eq 0)
      $onlineOk = $true
      if ($offlineOk) {
        try {
          $v1 = Get-EmbeddingVector -Text $probe -Embed $emb -KeepAlive $keepAlive
          $masked = ('?' * $probe.Length) -join ''
          $v2 = Get-EmbeddingVector -Text $masked -Embed $emb -KeepAlive $keepAlive
          $cos = Get-Cosine $v1 $v2
          $onlineOk = ([double]$cos -lt 0.99)
          Write-Host ("  live probe : dim=" + $v1.Length + "   cosine(real, '?'*n) = " + [math]::Round([double]$cos, 4) + "   (must be well below 1.0)")
        } catch {
          Write-Host ("  live probe : endpoint did not answer - " + $_.Exception.Message)
          $onlineOk = $true   # offline half already proved the encoding; do not fail on a down endpoint
        }
      }
      if ($offlineOk -and $onlineOk) { Write-Host "  RESULT: PASS (request body carries real UTF-8 text)"; } else { Write-Host "  RESULT: FAIL" }
      return
    }

    $hasTable = [int](Invoke-Rows -Sql "SELECT CASE WHEN OBJECT_ID('dbo.embeddings') IS NULL THEN 0 ELSE 1 END AS n")[0].n
    if ($hasTable -ne 1) { throw "dbo.embeddings does not exist -- run sql\001-create-embeddings.sql against this database first" }

    $reFlag = 0
    if ($Reembed) { $reFlag = 1 }
    $candSql = @"
;WITH src AS (
  SELECT 'message' AS item_type, id AS item_id, LEFT(ISNULL(text, ''), @chars) AS t FROM dbo.messages
  UNION ALL
  SELECT 'memory', id, LEFT(ISNULL(title, '') + CHAR(13) + CHAR(10) + ISNULL(body, ''), @chars) FROM dbo.memories
), w AS (
  SELECT src.item_type, src.item_id, src.t, CONVERT(binary(16), HASHBYTES('MD5', src.t)) AS h FROM src
)
SELECT w.item_type, w.item_id, w.t, w.h
FROM w
-- Candidate test is by CONTENT, not by id: after a sync the same text comes back with a new
-- id, and testing "does this item_id have a vector" would re-embed it every ten minutes
-- (memory [146]).
WHERE (@reembed = 1)
   OR NOT EXISTS (SELECT 1 FROM dbo.embeddings e WHERE e.model = @model AND e.item_type = w.item_type AND e.text_hash = w.h)
ORDER BY CASE WHEN w.item_type = 'memory' THEN 0 ELSE 1 END, w.item_id DESC
"@
    # NOTE: Invoke-Rows returns the row array as ONE pipeline item (so a single-row result
    # stays indexable as $r[0]).  Wrapping the CALL in @() therefore produces a 1-element
    # array whose element is the whole row set -- this exact nesting bug reported "1 pending"
    # for ~2350 rows and joined every text into one giant prompt (2026-10-06, second time).
    # Always assign first, then wrap.
    $todoRaw = Invoke-Rows -Sql $candSql -Params @{ '@chars' = $nChars; '@model' = $mdl; '@reembed' = $reFlag }
    $todo    = @($todoRaw)

    if ($DryRun) {
      $nMsg = 0; $nMem = 0
      foreach ($row in $todo) { if ([string]$row.item_type -eq 'memory') { $nMem++ } else { $nMsg++ } }
      Write-Host ("  model    : " + $mdl + "  (dry run: nothing embedded, nothing written)")
      Write-Host ("  pending  : memories " + $nMem + " / messages " + $nMsg + "  total " + $todo.Count)
      if ($todo.Count -gt 0) {
        $first = $todo[0]
        Write-Host ("  first    : " + $first.item_type + " #" + $first.item_id + "  text " + ([string]$first.t).Length + " chars")
      }
      $have = [int](Invoke-Rows -Sql "SELECT COUNT(*) AS n FROM dbo.embeddings WHERE model = @m" -Params @{ '@m' = $mdl })[0].n
      Write-Host ("  in table : " + $have + " row(s) for model '" + $mdl + "'")
      Write-Host "  note     : -DryRun is read-only; housekeeping (re-point/dedupe/cleanup) runs only on a real embed"
      return
    }

    # ---- housekeeping (writes; therefore only on a real run) ----------------------------
    # sync does DELETE + re-INSERT per session, so every sync of an active session gives its
    # messages NEW ids and strands the old vectors.  Before paying the model again: move ONE
    # orphan per text_hash onto the current row, then drop the rest.
    # ★ ONE orphan per hash is the fix for the PK collision reported by 17 ([153]) and 18
    #   ([155]): when several orphans shared a hash they all targeted the same new id and the
    #   second one violated PK_embeddings -- and because a single try/catch wrapped everything,
    #   the orphan cleanup was skipped too.  Each step now has its own catch as well.
    $moved = 0; $deduped = 0; $cleaned = 0
    try {
      $moved = Invoke-Exec -Sql @"
;WITH cur AS (
  SELECT id, CONVERT(binary(16), HASHBYTES('MD5', LEFT(ISNULL(text, ''), @chars))) AS h FROM dbo.messages
), orph AS (
  SELECT e.item_id, e.text_hash,
         ROW_NUMBER() OVER (PARTITION BY e.text_hash ORDER BY e.item_id DESC) AS rn
  FROM dbo.embeddings e
  WHERE e.model = @model AND e.item_type = 'message'
    AND NOT EXISTS (SELECT 1 FROM dbo.messages m WHERE m.id = e.item_id)
), keepOne AS (
  SELECT item_id, text_hash FROM orph WHERE rn = 1
)
UPDATE e SET e.item_id = cur.id
FROM dbo.embeddings e
JOIN keepOne k ON k.item_id = e.item_id AND k.text_hash = e.text_hash
JOIN cur ON cur.h = e.text_hash
WHERE e.model = @model AND e.item_type = 'message'
  AND NOT EXISTS (SELECT 1 FROM dbo.embeddings x WHERE x.model = e.model AND x.item_type = 'message' AND x.item_id = cur.id)
"@ -Params @{ '@chars' = $nChars; '@model' = $mdl }
    } catch { Write-Host ("  re-point skipped (will be retried next run): " + $_.Exception.Message) }
    try {
      # Consolidate to ONE vector per (model, item_type, text_hash): prefer a row whose target
      # is live, else the newest.  The earlier version dropped only ORPHAN duplicates, so
      # 17 groups of legacy "live row + live row, same content" survived -- found by the
      # cluster audit 2026-10-06 (44 vectors / 27 redundant), which also produced duplicate
      # ranking lines.  Content is what `recall` resolves on, so one vector per hash is enough.
      $deduped = Invoke-Exec -Sql @"
;WITH r AS (
  SELECT e.item_type, e.item_id, e.text_hash,
         ROW_NUMBER() OVER (PARTITION BY e.model, e.item_type, e.text_hash
                            ORDER BY CASE WHEN m.id IS NOT NULL OR k.id IS NOT NULL THEN 0 ELSE 1 END,
                                     e.created_at DESC, e.item_id DESC) AS rn
  FROM dbo.embeddings e
  LEFT JOIN dbo.messages m ON e.item_type = 'message' AND m.id = e.item_id
  LEFT JOIN dbo.memories k ON e.item_type = 'memory'  AND k.id = e.item_id
  WHERE e.model = @model
)
DELETE e
FROM dbo.embeddings e
JOIN r ON r.item_type = e.item_type AND r.item_id = e.item_id AND r.text_hash = e.text_hash
WHERE e.model = @model AND r.rn > 1
    -- 2026-10-23: 每个 item 保留自己的向量；只收敛"孤儿"重复。
    -- 原逻辑按 (model,item_type,text_hash) 只留一条，导致同文本的活消息没有自己的行，
    -- 而 recall 是按 item_id 回表的 ⇒ 这些消息语义检索永远查不到（"无向量消息"降不到 0）。
    AND NOT EXISTS (SELECT 1 FROM dbo.messages mm WHERE e.item_type = 'message' AND mm.id = e.item_id)
    AND NOT EXISTS (SELECT 1 FROM dbo.memories kk WHERE e.item_type = 'memory'  AND kk.id = e.item_id)
"@ -Params @{ '@model' = $mdl }
    } catch { Write-Host ("  duplicate consolidation skipped: " + $_.Exception.Message) }
    try {
      $cleaned = Invoke-Exec -Sql "DELETE FROM dbo.embeddings WHERE model = @m AND item_type = 'message' AND NOT EXISTS (SELECT 1 FROM dbo.messages m WHERE m.id = dbo.embeddings.item_id)" -Params @{ '@m' = $mdl }
      $null = Invoke-Exec -Sql "DELETE FROM dbo.embeddings WHERE model = @m AND item_type = 'memory' AND NOT EXISTS (SELECT 1 FROM dbo.memories k WHERE k.id = dbo.embeddings.item_id)" -Params @{ '@m' = $mdl }
    } catch { Write-Host ("  orphan cleanup skipped: " + $_.Exception.Message) }
    if ($moved -gt 0 -or $deduped -gt 0 -or $cleaned -gt 0) {
      Write-Host ("  housekeeping: re-pointed " + $moved + ", deduped " + $deduped + ", cleaned " + $cleaned)
    }

    $batch = 0                      # 0 = everything pending
    if ($PSBoundParameters.ContainsKey('Limit')) { $batch = $Limit }
    $plan = $todo.Count
    if ($batch -gt 0 -and $batch -lt $plan) { $plan = $batch }

    Write-Host ("  model    : " + $mdl)
    Write-Host ("  endpoint : " + $emb.baseURL)
    Write-Host ("  chars    : " + $nChars + "   (this prefix is both embedded and hashed)")
    Write-Host ("  keepalive: " + $keepAlive + "   (avoids reloading the model for every row)")
    Write-Host ("  batch    : " + $nBatch + " input(s) per request (route /api/embed; per-row fallback)")
    if ($Reembed) { Write-Host "  reembed  : ON (-Reembed ignores text_hash)" }
    Write-Host ("  to embed : " + $todo.Count + " pending row(s); processing " + $plan)
    if ($todo.Count -gt 0) {
      $ok = 0; $fail = 0; $dim = 0; $n = 0; $batched = 0; $single = 0
      $work = @($todo | Select-Object -First $plan)
      for ($i = 0; $i -lt $work.Count; $i += $nBatch) {
        $end = [Math]::Min($i + $nBatch - 1, $work.Count - 1)
        $chunk = @($work[$i..$end])
        $texts = @($chunk | ForEach-Object { [string]$_.t })
        $vecs = $null
        if ($chunk.Count -gt 1) { $vecs = Get-EmbeddingBatch -Texts $texts -Embed $emb -KeepAlive $keepAlive }
        if ($vecs) { $batched += $chunk.Count } else { $single += $chunk.Count }
        for ($j = 0; $j -lt $chunk.Count; $j++) {
          $row = $chunk[$j]
          try {
            if ($vecs) { $vec = $vecs[$j] } else { $vec = Get-EmbeddingVector -Text ([string]$row.t) -Embed $emb -KeepAlive $keepAlive }
            if (-not $vec -or $vec.Length -eq 0) { throw 'empty vector' }
            if ($dim -eq 0) { $dim = $vec.Length }
            if ($vec.Length -ne $dim) { throw ("dimension changed mid-run: " + $vec.Length + " vs " + $dim) }
            $bytes = Convert-FloatsToBytes $vec
            $null = Invoke-Exec -Sql "DELETE FROM dbo.embeddings WHERE item_type=@t AND item_id=@i AND model=@m; INSERT INTO dbo.embeddings (item_type,item_id,model,dim,vec,text_hash) VALUES (@t,@i,@m,@d,@v,@h)" -Params @{ '@t' = [string]$row.item_type; '@i' = [int64]$row.item_id; '@m' = $mdl; '@d' = [int16]$vec.Length; '@v' = $bytes; '@h' = [byte[]]$row.h }
            $ok++
            $n++
          } catch {
            $fail++
            Write-Host ("    FAILED " + $row.item_type + " #" + $row.item_id + ": " + $_.Exception.Message)
            if ($fail -ge 5) { Write-Host "    (stopping: 5 failures -- fix the endpoint/model first)"; break }
          }
        }
        if ($fail -ge 5) { break }
        if (($n % 100) -lt $nBatch) { Write-Host ("    ... " + $n + " processed (ok=" + $ok + " failed=" + $fail + ", batched=" + $batched + " per-row=" + $single + ")") }
      }
      $cnt = [int](Invoke-Rows -Sql "SELECT COUNT(*) AS n FROM dbo.embeddings WHERE model = @m" -Params @{ '@m' = $mdl })[0].n
      Write-Host ("  embedded : " + $ok + "   failed: " + $fail + "   dim: " + $dim + "   (batched " + $batched + " / per-row " + $single + ")")
      Write-Host ("  in table : " + $cnt + " row(s) for model '" + $mdl + "'")
      if ($fail -gt 0) { Write-Host "  NOTE: failures are printed above, never swallowed" }
      if ($ok -gt 0 -and $cnt -gt 0) { Write-Host "  next     : dsh-mem.ps1 recall <question>   (semantic when the config embed block matches this model)" }
    } else {
      Write-Host "  nothing to do: every candidate already has a vector with the same text_hash"
    }
  }

  'recent' {
    if (Test-DbAlive) {
      $m = Invoke-Rows -Sql "SELECT TOP (@n) id, created_at, scope, subject, kind, title FROM dbo.memories ORDER BY id DESC" -Params @{ '@n' = $Limit }
      foreach ($r in @($m)) { Write-Host ("  [{0}] {1} {2}/{3} {4}  {5}" -f $r.id, $r.created_at.ToLocalTime().ToString('MM-dd HH:mm'), $r.scope, $r.subject, $r.kind, $r.title) }
    } else {
      $rep = Get-Replica
      if (-not $rep) { Write-NoReplica; return }
      Write-Host ("  OFFLINE - local replica, last synced " + $rep.generatedAt)
      $m = @($rep.memories) | Sort-Object { [int]$_.id } -Descending | Select-Object -First $Limit
      foreach ($r in @($m)) { Write-Host ("  [{0}] {1} {2}/{3} {4}  {5}" -f $r.id, ([datetime]$r.created_at).ToLocalTime().ToString('MM-dd HH:mm'), $r.scope, $r.subject, $r.kind, $r.title) }
    }
  }

  'history' {
    # The append-only archive that sync writes before it deletes (phase 1 of "memory with time",
    # memory [326]).  This is the command another machine's DSH runs to trace what a rollback,
    # crash or truncation destroyed -- the whole point of keeping history.
    if (-not (Test-DbAlive)) { $repH = Get-Replica; if (-not $repH) { Write-NoReplica; return }; Write-Host "  OFFLINE - the archive lives in the database only; replica carries no history" ; return }
    if ($Session -and $Seq -gt 0) {
      $hOne = Invoke-Rows -Sql "SELECT TOP (1) id, session_id, seq, turn, role, text, created_at, archived_at, archive_reason, archived_by FROM dbo.messages_history WHERE session_id=@sid AND seq=@seq ORDER BY archived_at DESC" -Params @{ '@sid' = $Session; '@seq' = $Seq }
      if (@($hOne).Count -eq 0) { Write-Host ("  no archived row for session=" + $Session + " seq=" + $Seq); return }
      $h = $hOne[0]
      Write-Host ("  archived seq=" + $h.seq + "  reason=" + $h.archive_reason + "  by=" + $h.archived_by + "  at=" + $h.archived_at)
      Write-Host ("  original id=" + $h.id + "  role=" + $h.role + "  turn=" + $h.turn + "  created_at=" + $h.created_at)
      Write-Host "  --- text (full) ---"
      Write-Host ([string]$h.text)
      return
    }
    if ($Session) {
      $hList = Invoke-Rows -Sql "SELECT TOP (@n) seq, archive_reason, archived_at, archived_by, role, LEFT(text,70) AS preview FROM dbo.messages_history WHERE session_id=@sid ORDER BY seq, archived_at" -Params @{ '@n' = $Limit; '@sid' = $Session }
    } else {
      $hList = Invoke-Rows -Sql "SELECT TOP (@n) session_id, seq, archive_reason, archived_at, archived_by, role, LEFT(text,60) AS preview FROM dbo.messages_history ORDER BY archived_at DESC" -Params @{ '@n' = $Limit }
    }
    if (@($hList).Count -eq 0) { Write-Host "  (nothing archived yet - that means no sync has ever had to destroy history)"; return }
    Write-Host ("== archived rows (" + @($hList).Count + " shown, newest query = " + $(if ($Session) { 'session ' + $Session } else { 'all sessions' }) + ") ==")
    foreach ($h in @($hList)) {
      if ($Session) {
        Write-Host ("  seq={0,-6} {1,-8} {2}  {3}  {4}" -f $h.seq, $h.archive_reason, $h.archived_at.ToLocalTime().ToString('MM-dd HH:mm'), $h.archived_by, $h.preview)
      } else {
        Write-Host ("  {0}  seq={1,-6} {2,-8} {3}  {4}" -f $h.session_id, $h.seq, $h.archive_reason, $h.archived_at.ToLocalTime().ToString('MM-dd HH:mm'), $h.preview)
      }
    }
    Write-Host ""
    Write-Host "  full text of one row : dsh-mem.ps1 history -Session <sid> -Seq <n>"
  }

  'secrets' {
    # Owner-authorised clear-text credential list (rules R39).  Deliberately does NOT run Protect-Text:
    # the whole point is to read the stored value back.  Local-only; the banner says what not to do.
    $pat = [string]$Target
    if ($pat) { $rows = Invoke-Rows -Sql "SELECT TOP 300 id, subject, title, body, tags, CONVERT(varchar(19), created_at, 120) AS at FROM dbo.memories WHERE kind='secret' AND (subject LIKE '%'+@p+'%' OR title LIKE '%'+@p+'%' OR body LIKE '%'+@p+'%' OR tags LIKE '%'+@p+'%') ORDER BY id DESC" -Params @{ '@p' = $pat } }
    else      { $rows = Invoke-Rows -Sql "SELECT TOP 300 id, subject, title, body, tags, CONVERT(varchar(19), created_at, 120) AS at FROM dbo.memories WHERE kind='secret' ORDER BY id DESC" -Params @{} }
    Write-Host ""
    Write-Host "  == stored credentials (kind=secret, CLEAR TEXT on purpose) =="
    Write-Host "     local-only: do NOT copy this output to a shared folder or into a chat log"
    if (@($rows).Count -eq 0) {
      Write-Host "     (none yet -- add one with:  save -Kind secret -Subject <name> -Title <what> -Body <the secret>)"
    } else {
      foreach ($r in @($rows)) {
        Write-Host ("     [" + $r.id + "] " + $r.at + "  subject=" + $r.subject + "  title=" + $r.title)
        foreach ($ln in ([string]$r.body -split "`r?`n")) { Write-Host ("         " + $ln) }
      }
      Write-Host ("     total: " + @($rows).Count + " entry(ies)")
    }
    Write-Host ""
  }
  'stats' {
    if (Test-DbAlive) {
      $s = Invoke-Rows -Sql @"
SELECT (SELECT COUNT(*) FROM dbo.sessions) AS sessions,
       (SELECT COUNT(*) FROM dbo.messages) AS messages,
       (SELECT COUNT(*) FROM dbo.memories) AS memories,
       (SELECT CAST(SUM(size)*8.0/1024 AS DECIMAL(10,1)) FROM sys.database_files) AS size_mb
"@
      Write-Host ("  sessions : " + $s[0].sessions)
      Write-Host ("  messages : " + $s[0].messages)
      Write-Host ("  memories : " + $s[0].memories)
      Write-Host ("  db size  : " + $s[0].size_mb + " MB")
      Write-Host ""
      $sessList = Invoke-Rows -Sql "SELECT TOP 10 session_id, machine, title, event_count, last_seen_at FROM dbo.sessions ORDER BY last_seen_at DESC"
      if (@($sessList).Count -eq 0) { Write-Host "  (no sessions imported yet)" }
      foreach ($r in @($sessList)) {
        $ls = if ($r -and $r.last_seen_at) { $r.last_seen_at.ToLocalTime().ToString('MM-dd HH:mm') } else { '-' }
        Write-Host ("  {0}  {1}  ev={2}  {3}  {4}" -f $r.session_id, $r.machine, $r.event_count, $ls, $r.title)
      }
    } else {
      $rep = Get-Replica
      if (-not $rep) { Write-NoReplica; return }
      Write-Host ("  OFFLINE - local replica, last synced " + $rep.generatedAt)
      Write-Host ("  sessions : " + @($rep.sessions).Count + "  (replica)")
      Write-Host ("  messages : " + @($rep.messages).Count + "  (replica, capped)")
      Write-Host ("  memories : " + @($rep.memories).Count + "  (replica)")
      Write-Host ""
      foreach ($r in @($rep.sessions)) { Write-Host ("  {0}  {1}  ev={2}  {3}" -f $r.session_id, $r.machine, $r.event_count, $r.title) }
    }
  }

  'roster' {
    # cli_version turns this from a presence list into a cluster VERSION check: three machines
    # reporting the same string is the thing [177]/[178] tried to establish from byte counts.
    $m = Invoke-Rows -Sql "SELECT login_name, machine, purpose, first_seen, last_seen, cli_version FROM dbo.machines ORDER BY login_name"
    Write-Host ("== 记忆库成员 " + @($m).Count + " 个 ==")
    $seen = @()
    foreach ($r in @($m)) {
      $fs = if ($r.first_seen) { ([datetime]$r.first_seen).ToLocalTime().ToString('MM-dd HH:mm') } else { '-' }
      $ls = if ($r.last_seen)  { ([datetime]$r.last_seen).ToLocalTime().ToString('MM-dd HH:mm') } else { '-' }
      $cv = if ($r.cli_version) { [string]$r.cli_version } else { '(none)' }
      if ($cv -ne '(none)') { $seen += $cv }
      Write-Host ("  {0,-18} 主机 {1,-20} CLI {2,-8} 首次 {3}  最近 {4}  {5}" -f $r.login_name, $r.machine, $cv, $fs, $ls, $r.purpose)
    }
    # all machines that report a version must agree, otherwise say so loudly
    $uniq = @($seen | Select-Object -Unique)
    if ($uniq.Count -gt 1) {
      Write-Host ("  WARN: cluster versions differ -> " + ($uniq -join ', ') + "   (this machine: " + $script:CliVersion + ")")
    } elseif ($uniq.Count -eq 1) {
      Write-Host ("  cluster cli version: " + $uniq[0] + $(if ($uniq[0] -eq $script:CliVersion) { "  (this machine agrees)" } else { "  WARN: this machine is " + $script:CliVersion }))
    }
  }

  'version' {
    # One string that identifies the whole script, so the cluster stops guessing from byte counts.
    # It is also reported into dbo.machines on every run that touches the DB (Register-Host),
    # which is what makes 'roster' a cluster-wide version check (memory [177]/[178] is why).
    $vFile = $PSCommandPath
    if (-not $vFile) { $vFile = Join-Path $Root 'dsh-mem.ps1' }
    $vLen = (Get-Item -LiteralPath $vFile).Length
    $vSha = (Get-FileHash -LiteralPath $vFile -Algorithm SHA256).Hash.Substring(0,16)
    Write-Host ("  cli     : dsh-mem.ps1 " + $script:CliVersion)
    Write-Host ("  file    : " + $vFile)
    Write-Host ("  size    : " + $vLen + " bytes   sha256[0..15] " + $vSha)
    Write-Host ("  limits  : " + (($script:ColLimits.Keys | ForEach-Object { $_ + " " + $script:ColLimits[$_] }) -join ' / ') + "  (mirror dbo.memories; guard check 15 enforces the boundary)")
    Write-Host ("  server  : " + $cfg.server + " / " + $script:Db)
    Write-Host  "  cluster   : run 'roster' to see the version each machine reports in dbo.machines"
  }

  'handoff' {
    # Session handoff: pull a session that happened on ANOTHER machine and write a brief
    # that a fresh local session can start from.  This is the closest thing to "roaming":
    # the durable memory already roams; this brings back the recent dialogue too.
    #
    #   dsh-mem.ps1 handoff                     # most recent session from another machine
    #   dsh-mem.ps1 handoff <session-id-prefix> # a specific one
    #   dsh-mem.ps1 handoff -Limit 40           # how many recent turns to include
    $me = $env:COMPUTERNAME
    $sid = $null; $machine = ''; $title = ''; $last = $null
    if ($Target) {
      $row = Invoke-Rows -Sql "SELECT TOP 1 s.session_id, s.machine, s.title, MAX(m.created_at) AS last FROM dbo.sessions s LEFT JOIN dbo.messages m ON m.session_id=s.session_id WHERE s.session_id LIKE @p GROUP BY s.session_id, s.machine, s.title ORDER BY MAX(m.created_at) DESC" -Params @{ '@p' = ($Target + '%') }
      if (@($row).Count -gt 0) { $sid = [string]$row[0].session_id; $machine = [string]$row[0].machine; $title = [string]$row[0].title; $last = $row[0].last }
    } else {
      $row = Invoke-Rows -Sql "SELECT TOP 1 s.session_id, s.machine, s.title, MAX(m.created_at) AS last FROM dbo.sessions s JOIN dbo.messages m ON m.session_id=s.session_id WHERE s.machine <> @me GROUP BY s.session_id, s.machine, s.title ORDER BY MAX(m.created_at) DESC" -Params @{ '@me' = $me }
      if (@($row).Count -gt 0) { $sid = [string]$row[0].session_id; $machine = [string]$row[0].machine; $title = [string]$row[0].title; $last = $row[0].last }
    }
    if (-not $sid) { Write-Host "  no session from another machine found"; return }

    $msgs = Invoke-Rows -Sql "SELECT TOP (@n) role, created_at, text FROM dbo.messages WHERE session_id = @sid AND role IN ('user','assistant') ORDER BY created_at DESC" -Params @{ '@n' = $Limit; '@sid' = $sid }
    $mems = Invoke-Rows -Sql "SELECT TOP 12 id, kind, title, body, updated_at FROM dbo.memories ORDER BY updated_at DESC"

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# 接力简报 · 来自 " + $machine + " 的会话")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("本文件由 dsh-mem.ps1 handoff 生成，用于在**另一台机器**上接续此前的对话。")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("- 源机器: " + $machine)
    [void]$sb.AppendLine("- 会话  : " + $sid)
    [void]$sb.AppendLine("- 标题  : " + $title)
    [void]$sb.AppendLine("- 最后活动: " + $(if ($last) { ([datetime]$last).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { '-' }))
    [void]$sb.AppendLine("- 生成于: " + (Get-Date -Format 'yyyy-MM-dd HH:mm') + "  (" + $me + ")")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("> 说明: 记忆库里只保存 user/assistant 正文（不含工具调用细节），所以这是【对话层】的接力，")
    [void]$sb.AppendLine("> 不是进程级的无缝迁移。工具体验需要在新机器上重新走一遍。")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## 一、该会话最近 " + @($msgs).Count + " 轮（新的在后）")
    [void]$sb.AppendLine("")
    $arr = @($msgs); [array]::Reverse($arr)
    foreach ($m in $arr) {
      # REDACT FIRST, THEN TRUNCATE.  The other order lets a secret that straddles the cut
      # survive as an unmatched fragment -- exactly the half-redaction failure of rule R6.
      $txt = Protect-Text ([string]$m.text)
      $txt = $txt -replace '\s+', ' '
      if ($txt.Length -gt 900) { $txt = $txt.Substring(0, 900) + ' …[截断]' }
      [void]$sb.AppendLine("**" + ([datetime]$m.created_at).ToLocalTime().ToString('HH:mm') + " " + $m.role + "**: " + $txt)
      [void]$sb.AppendLine("")
    }
    [void]$sb.AppendLine("## 二、共享记忆里最新的结论（三台一致）")
    [void]$sb.AppendLine("")
    foreach ($k in @($mems)) {
# OWNER CREDENTIALS (rule R39): this brief is written to be carried to ANOTHER machine, so a
# kind='secret' memory shows only a placeholder here.
      if ([string]$k.kind -eq 'secret') {
        $b = '[secret: value not exported -- read it with: dsh-mem.ps1 secrets]'
      } else {
        $b = Protect-Text ([string]$k.body)
      }
      $b = $b -replace '\s+', ' '
      if ($b.Length -gt 300) { $b = $b.Substring(0, 300) + ' …' }
      [void]$sb.AppendLine("### [" + $k.id + "] " + (Protect-Text ([string]$k.title)))
      [void]$sb.AppendLine($b)
      [void]$sb.AppendLine("")
    }
    # session ids are usually 36-char GUIDs, but guard probes and short ids exist -- Substring
    # without a clamp crashed handoff for anything shorter than 18 chars (found by guard check 14)
    $sidTail = $sid.Substring(5, [Math]::Min(8, [Math]::Max(0, $sid.Length - 5)))
    $out = Join-Path $Root ("handoff-" + $sidTail + ".md")
    # belt and braces: redact the assembled document too, then report what still looks secret
    $content = Protect-Text $sb.ToString()
    $hits = Get-SecretHitCount $content
    [System.IO.File]::WriteAllText($out, $content, (New-Object System.Text.UTF8Encoding $true))
    $kb = [math]::Round((Get-Item -LiteralPath $out).Length / 1KB, 1)
    Write-Host ("  OK  handoff brief -> " + $out + "  (" + $kb + " KB)")
    Write-ExportNote $out 'handoff brief' $hits
    Write-Host ("      来源: " + $machine + " / " + $sid.Substring(0, [Math]::Min(18, $sid.Length)) + "...  " + $title)
    Write-Host ("      含 " + @($msgs).Count + " 轮对话 + " + @($mems).Count + " 条记忆")
    Write-Host ""
    Write-Host "  在新会话里说这一句即可接上："
    Write-Host ("    读 " + $out + "，然后接着那边的事情继续。")
  }

  'prune' {
    # Ageing policy.  IMPORTANT MODEL: this database is a DERIVED store --
    #   messages/sessions are rebuilt from each machine's local session logs,
    #   so pruning them is always safe (they come back if a session resumes).
    # The ONLY non-rebuildable data is dbo.memories (hand-written distilled memory),
    # and that is what the daily DSH_MemoryBackup protects.  prune NEVER touches it.
    #
    #   dry run : dsh-mem.ps1 prune             (default -- just reports)
    #   execute : dsh-mem.ps1 prune -Force
    $days = if ($Target) { [int]$Target } else { 90 }
    $cut  = (Get-Date).ToUniversalTime().AddDays(-$days)
    $old = Invoke-Rows -Sql "SELECT COUNT(*) AS n FROM dbo.messages WHERE created_at < @cut" -Params @{ '@cut' = $cut }
    $orph = Invoke-Rows -Sql "SELECT COUNT(*) AS n FROM dbo.sessions s WHERE NOT EXISTS (SELECT 1 FROM dbo.messages m WHERE m.session_id = s.session_id)"
    $mems = Invoke-Rows -Sql "SELECT COUNT(*) AS n FROM dbo.memories"
    Write-Host ("  policy   : keep messages newer than " + $days + " days; memories are never pruned")
    Write-Host ("  would delete : messages " + $old[0].n + " 条 / 空会话 " + $orph[0].n + " 个")
    Write-Host ("  protected    : memories " + $mems[0].n + " 条（唯一不可重建的数据，由每日备份保护）")
    if (-not $Force) {
      Write-Host "  DRY RUN - 加 -Force 才真正执行"
    } else {
      [void](Invoke-Exec -Sql "DELETE FROM dbo.messages WHERE created_at < @cut" -Params @{ '@cut' = $cut })
      [void](Invoke-Exec -Sql "DELETE FROM dbo.sessions WHERE NOT EXISTS (SELECT 1 FROM dbo.messages m WHERE m.session_id = dbo.sessions.session_id)")
      $s2 = Invoke-Rows -Sql "SELECT (SELECT COUNT(*) FROM dbo.messages) AS m,(SELECT COUNT(*) FROM dbo.sessions) AS s,(SELECT COUNT(*) FROM dbo.memories) AS k"
      Write-Host ("  DONE - 现在: 消息 " + $s2[0].m + " / 会话 " + $s2[0].s + " / 记忆 " + $s2[0].k)
      Write-Host ("  提示: 数据库文件不会自动缩小，如需回收空间可在主机上执行 DBCC SHRINKFILE（非必需）")
    }
  }

  'replica' {
    if (-not (Test-DbAlive)) { Write-Host "  database unreachable - replica NOT refreshed (existing copy left untouched)"; return }
    $mem  = Invoke-Rows -Sql "SELECT id, scope, subject, kind, title, body, tags, confidence, CONVERT(varchar(33), created_at, 126) + 'Z' AS created_at, CONVERT(varchar(33), updated_at, 126) + 'Z' AS updated_at FROM dbo.memories ORDER BY id"
    $msg  = Invoke-Rows -Sql "SELECT TOP (@n) m.id, m.session_id, s.machine, m.seq, m.role, CONVERT(varchar(33), m.created_at, 126) + 'Z' AS created_at, LEFT(m.text, 800) AS text FROM dbo.messages m LEFT JOIN dbo.sessions s ON s.session_id = m.session_id ORDER BY m.id DESC" -Params @{ '@n' = $ReplicaMessages }
    $sess = Invoke-Rows -Sql "SELECT session_id, machine, title, event_count, CONVERT(varchar(33), last_seen_at, 126) + 'Z' AS last_seen_at FROM dbo.sessions ORDER BY last_seen_at DESC"
    $rep = [pscustomobject]@{
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      server      = $cfg.server
      database    = $script:Db
      memories    = @($mem)
      messages    = @($msg)
      sessions    = @($sess)
    }
    # Redact every content-bearing field BEFORE serialising.  Doing it on the JSON string would
    # miss values that JSON escapes, and this file is read by other tools/machines.
foreach ($r in @($mem)) {
  # OWNER CREDENTIALS (rule R39): this file is copied around far more easily than the database, so a
  # kind='secret' row is exported as a PLACEHOLDER -- the entry's existence stays visible, its value does not.
  if ([string]$r.kind -eq 'secret') {
    $r.title = '[secret: value not exported]'
    $r.body  = '[secret: kept in the database only -- read it with: dsh-mem.ps1 secrets]'
  } else {
    $r.title = Protect-Text ([string]$r.title); $r.body = Protect-Text ([string]$r.body)
  }
}
    foreach ($r in @($msg)) { $r.text  = Protect-Text ([string]$r.text) }
    $repJson = $rep | ConvertTo-Json -Depth 6 -Compress
    $repHits = Get-SecretHitCount $repJson
    # write WITHOUT a BOM: PowerShell 5.1's -Encoding UTF8 adds one, and Node's JSON.parse rejects it
    [System.IO.File]::WriteAllText($script:ReplicaPath, $repJson, (New-Object System.Text.UTF8Encoding $false))
    $kb = [math]::Round((Get-Item -LiteralPath $script:ReplicaPath).Length / 1KB, 1)
    Write-Host ("  OK  replica -> " + $script:ReplicaPath)
    Write-Host ("      memories=" + @($mem).Count + "  messages=" + @($msg).Count + "  sessions=" + @($sess).Count + "  size=" + $kb + " KB")
    Write-ExportNote $script:ReplicaPath 'the replica' $repHits
  }

  'backup' {
    $stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
    # 备份目录：优先环境变量 DSH_BACKUP_DIR，其次 <配置目录>\backup（不再写死某台机器的盘符）
    $bakDir = if ($env:DSH_BACKUP_DIR) { $env:DSH_BACKUP_DIR } else { Join-Path (Split-Path $ConfigPath -Parent) 'backup' }
    $bak    = Join-Path $bakDir ("DSHMemory_" + $stamp + ".bak")
    try {
      [void](Invoke-Exec -Sql "BACKUP DATABASE [$script:Db] TO DISK = N'$bak' WITH INIT, COMPRESSION, CHECKSUM, STATS = 25" -Db 'master')
      Write-Host ("  OK  full backup -> " + $bak + "  (size on " + $cfg.server + ", see msdb history)")
      # retention: keep 30 days of .bak on the SQL host
      try {
        # .bak retention runs as a SQL Agent job on the host (the low-priv login has no sysadmin)
        Write-Host "  note: .bak retention -> run prune-backups.ps1 on the SQL host (file-level, no SQL permission needed)"
      } catch { Write-Host ("  WARN retention skipped: " + $_.Exception.Message) }
    } catch {
      Write-Host ("  WARN full backup skipped: " + $_.Exception.Message)
    }
    $rows = Invoke-Rows -Sql "SELECT id, scope, subject, kind, title, body, tags, source_session, confidence, created_at, updated_at FROM dbo.memories ORDER BY id"
    # redact per field, then check the serialised result before it reaches the disk
foreach ($r in @($rows)) {
  # same reason as the replica: the JSON export is a plain file (see the .bak for the complete copy)
  if ([string]$r.kind -eq 'secret') {
    $r.title = '[secret: value not exported]'
    $r.body  = '[secret: kept in the database only -- read it with: dsh-mem.ps1 secrets]'
  } else {
    $r.title = Protect-Text ([string]$r.title); $r.body = Protect-Text ([string]$r.body)
  }
}
    $out  = Join-Path $Root ("memories-backup-" + $stamp + ".json")
    $json = $rows | ConvertTo-Json -Depth 5
    $hits = Get-SecretHitCount $json
    Set-Content -LiteralPath $out -Value $json -Encoding UTF8
    Write-Host ("  OK  memories export (" + @($rows).Count + " rows) -> " + $out)
    Write-ExportNote $out 'the memories export' $hits
    # keep the 30 newest JSON exports
    Get-ChildItem -LiteralPath $Root -Filter 'memories-backup-*.json' -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -Skip 30 |
      ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
  }

  default {
    Write-Host "dsh-mem.ps1 - DSH long-term memory CLI"
    Write-Host ""
    Write-Host "  sync    [<session.v4.jsonl.zstd>] [-All] [-NoTools] [-Force]   import session log (tool events INCLUDED by default since 1.3.1; -NoTools opts out)(s)"
    Write-Host "  save    -Title '...' -Body '...' [-Tags a,b] [-Scope machine] [-Subject X] [-Kind fact|secret]"
Write-Host "          -Kind secret is the OWNER's clear-text credential store (rules R39) -- read it with: secrets"
    Write-Host "          -TitleFile <f> -BodyFile <f>  <- use these for long text or text with quotes"
    Write-Host "                                          (a body with an odd number of `" makes"
    Write-Host "                                           powershell -File fail silently, exit 2)"
    Write-Host "  embed   [-Limit N] [-Model m] [-Reembed] [-Chars N] [-BaseURL u]"
    Write-Host "                                       fill dbo.embeddings (F plan); idempotent via"
    Write-Host "                                       text_hash, so re-running only embeds what is"
    Write-Host "                                       new or changed. Needs an 'embed' config block."
    Write-Host "  search  <keyword> [-Limit 20]        (falls back to the local replica when offline)"
    Write-Host "  recall  <query> [-Limit 8] [-Context 2]"
    Write-Host "                                       hits + N turns around them; semantic when the"
    Write-Host "                                       F-plan embedding backend is live, otherwise a"
    Write-Host "                                       clearly marked DEGRADED literal search"
    Write-Host "  recent  [-Limit 20]                  (same)"
Write-Host "  secrets [<keyword>]                  list stored credentials (kind=secret, CLEAR TEXT, local-only)"
    Write-Host "  stats                                (same)"
    Write-Host "  replica                              refresh the local offline copy"
    Write-Host "  backup                               full .bak on the SQL host + JSON export"
    Write-Host "  roster                               list the machines registered in the shared memory"
    Write-Host "  prune    [<days>] [-Force]           ageing policy; dry run unless -Force (memories are never pruned)"
    Write-Host "  handoff  [<session-id>] [-Limit N]   pull another machine's session -> handoff brief"
    Write-Host ""
    Write-Host ("  state   : " + $script:StatePath)
    Write-Host ("  replica : " + $script:ReplicaPath + $(if (Test-Path -LiteralPath $script:ReplicaPath) { "  (exists)" } else { "  (not created yet)" }))
    Write-Host ("  server  : " + $cfg.server + " / " + $script:Db)
    Write-Host ("  sessions: " + $cfg.sessionsRoot)
    Write-Host ("  node    : " + $cfg.node)
  }
}
