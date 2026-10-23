param(
  [string]$Import,
  [string]$Subject = 'ImportedFile',
  [string]$Note = '',
  [int]$Extract = 0,
  [string]$Out,
  [string]$List,
  [string]$Root = 'C:\dsh-mem'
)
# mem-artifact.ps1 - store a file inside the memory database BYTE-EXACTLY, and get it back later.
#
# Why base64: the database's only clear-text channel is kind='secret' (rule R39), and any text path can be
# altered by redaction or by an encoding guess.  Base64 of the raw bytes sidesteps both, so the round trip
# is provable: store -> read back -> decode -> SHA256 must equal the source hash BEFORE anyone deletes the
# original.  That gate is the whole point of this tool.
#
# Usage
#   store    : mem-artifact.ps1 -Import <path> [-Subject <group>] [-Note <text>]
#   extract  : mem-artifact.ps1 -Extract <id> -Out <path>
#   list     : mem-artifact.ps1 -List <subject-or-keyword>
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
function Read-Cfg([string]$p) { return ([System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)) | ConvertFrom-Json }
$cfgPath = Join-Path $Root 'dsh-mem.config.json'
$cfg = Read-Cfg $cfgPath
Add-Type -AssemblyName System.Data
function New-Conn {
  $cs = "Server=" + $cfg.server + ";Database=" + $cfg.database + ";User Id=" + $cfg.user + ";Password=" + $cfg.password + ";TrustServerCertificate=True;Connect Timeout=30"
  $c = New-Object System.Data.SqlClient.SqlConnection $cs; $c.Open(); return $c
}
function Get-Body([int]$id) {
  $cn = New-Conn
  try { $c = $cn.CreateCommand(); $c.CommandText = "SELECT body FROM dbo.memories WHERE id = @i"; $null = $c.Parameters.AddWithValue('@i', $id); return [string]$c.ExecuteScalar() }
  finally { $cn.Close() }
}
function Parse-B64([string]$body) {
  $i = $body.IndexOf('base64:')
  if ($i -lt 0) { throw 'this memory is not an artifact (no base64: marker)' }
  $b64 = $body.Substring($i + 7)
  $b64 = ($b64 -replace '\s', '')
  return [Convert]::FromBase64String($b64)
}
function Get-Meta([string]$body, [string]$key) {
  $m = [regex]::Match($body, '(?m)^' + [regex]::Escape($key) + ':\s*(.*)$')
  if ($m.Success) { return $m.Groups[1].Value.Trim() }
  return ''
}

if ($Import) {
  if (-not (Test-Path -LiteralPath $Import)) { throw ('file not found: ' + $Import) }
  $fi = Get-Item -LiteralPath $Import
  $sha = (Get-FileHash -LiteralPath $Import -Algorithm SHA256).Hash
  $bytes = [System.IO.File]::ReadAllBytes($Import)
  $b64 = [Convert]::ToBase64String($bytes)
  $wrapped = ($b64 -split '(.{120})' | Where-Object { $_ -ne '' }) -join "`r`n"
  $body = 'artifact: file stored byte-exactly (base64 of the raw bytes)' + "`r`n" +
          'name: ' + $fi.Name + "`r`n" +
          'source: ' + $fi.FullName + "`r`n" +
          'bytes: ' + $bytes.Length + "`r`n" +
          'sha256: ' + $sha + "`r`n" +
          'mtime: ' + $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + "`r`n" +
          'note: ' + $Note + "`r`n" +
          'base64:' + "`r`n" + $wrapped
  $tmpBody = Join-Path $env:TEMP ('artb-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.txt')
  $tmpTitle = Join-Path $env:TEMP ('artt-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.txt')
  [System.IO.File]::WriteAllText($tmpBody, $body, (New-Object System.Text.UTF8Encoding $false))
  $title = 'ARTIFACT ' + $fi.Name + ' (' + $bytes.Length + ' B, sha ' + $sha.Substring(0,12) + ')'
  [System.IO.File]::WriteAllText($tmpTitle, $title, (New-Object System.Text.UTF8Encoding $false))
  $cli = Join-Path $Root 'dsh-mem.ps1'
  $out = @(& powershell -ExecutionPolicy Bypass -File $cli save -TitleFile $tmpTitle -BodyFile $tmpBody -Kind secret -Subject $Subject -Scope global -Tags ('artifact,' + $Subject) 2>&1)
  Remove-Item -LiteralPath $tmpBody -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tmpTitle -Force -ErrorAction SilentlyContinue
  $idm = [regex]::Match(($out -join ' '), 'saved memory id=(\d+)')
  if (-not $idm.Success) { throw ('save failed: ' + (($out | Select-Object -Last 3) -join ' | ')) }
  $id = [int]$idm.Groups[1].Value
  # VERIFY: read the row back, decode, and compare the hash with the source file
  $back = Get-Body $id
  $bytesBack = Parse-B64 $back
  $shaBack = (Get-FileHash -InputStream (New-Object System.IO.MemoryStream(, $bytesBack)) -Algorithm SHA256).Hash
  $ok = ($shaBack -eq $sha) -and ($bytesBack.Length -eq $bytes.Length)
  $verified = Get-Meta $back 'verified'
  if ($ok -and -not $verified) {
    $cn = New-Conn
    try {
      $c = $cn.CreateCommand()
      $c.CommandText = "UPDATE dbo.memories SET body = REPLACE(body, 'note: ', 'verified: ' + CONVERT(varchar(20), SYSUTCDATETIME(), 120) + ' (round-trip sha256 match) by 11' + CHAR(13) + CHAR(10) + 'note: ') WHERE id = @i"
      $null = $c.Parameters.AddWithValue('@i', $id); $null = $c.ExecuteNonQuery()
    } finally { $cn.Close() }
  }
  Write-Host ('  stored id=' + $id + '  ' + $fi.Name + '  bytes=' + $bytes.Length + '  sha=' + $sha.Substring(0,16))
  Write-Host ('  round-trip verify: ' + $(if ($ok) { 'MATCH (safe to destroy the source)' } else { 'MISMATCH -- DO NOT DESTROY THE SOURCE' }))
  if (-not $ok) { exit 2 }
  exit 0
}

if ($Extract -gt 0) {
  if (-not $Out) { throw '-Out is required with -Extract' }
  $body = Get-Body $Extract
  if (-not $body) { throw ('no memory with id ' + $Extract) }
  $bytes = Parse-B64 $body
  [System.IO.File]::WriteAllBytes($Out, $bytes)
  $sha = (Get-FileHash -InputStream (New-Object System.IO.MemoryStream(, $bytes)) -Algorithm SHA256).Hash
  $want = Get-Meta $body 'sha256'
  Write-Host ('  extracted id=' + $Extract + ' -> ' + $Out)
  Write-Host ('  name=' + (Get-Meta $body 'name') + '  bytes=' + $bytes.Length + '  source=' + (Get-Meta $body 'source'))
  Write-Host ('  sha256 now = ' + $sha.Substring(0,16) + '   recorded = ' + $want.Substring(0, [Math]::Min(16, $want.Length)) + '   match=' + ($sha -eq $want))
  exit 0
}

if ($List) {
  $cn = New-Conn
  try {
    $c = $cn.CreateCommand()
    $c.CommandText = "SELECT id, subject, title, CAST(DATALENGTH(body)/1024.0 AS DECIMAL(10,1)) AS kb FROM dbo.memories WHERE kind='secret' AND (subject LIKE '%' + @k + '%' OR title LIKE '%' + @k + '%' OR body LIKE '%' + @k + '%') ORDER BY id"
    $null = $c.Parameters.AddWithValue('@k', $List)
    $rd = $c.ExecuteReader()
    $n = 0
    while ($rd.Read()) { $n++; Write-Host ('  [' + $rd.GetValue(0) + '] ' + ([string]$rd.GetValue(1)).PadRight(14) + $rd.GetValue(3).ToString().PadLeft(8) + ' KB  ' + [string]$rd.GetValue(2)) }
    $rd.Close()
    Write-Host ('  ' + $n + ' entry(ies)')
  } finally { $cn.Close() }
  exit 0
}

Write-Host 'usage: -Import <path> [-Subject X] [-Note Y] | -Extract <id> -Out <path> | -List <keyword>'
