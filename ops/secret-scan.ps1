# secret-scan.ps1 - 开源前的敏感信息扫描（本地只读，不上传任何东西）
#
# 用途：在把代码放进公开仓库之前，扫出不该出门的东西。
# 判据：BLOCK 级 = 绝对不能出现（口令/令牌/真实私网 IP/邮箱/QQ/私钥）；
#       INFO 级 = 需要人工确认（个人路径、机器名、用户名）。
#
# 用法：
#   powershell -File ops\secret-scan.ps1 -Paths C:\dsh-mem\dsh-memory-bridge,C:\dsh-mem\sql
#   powershell -File ops\secret-scan.ps1 -Root C:\path\to\your\repo
# 退出码：0 = 无 BLOCK；3 = 有 BLOCK（不允许发布）
param(
  [string[]]$Paths,
  [string]$Root,
  [string]$OutFile,
  [switch]$Quiet
)
$ErrorActionPreference = 'Continue'

# Normalize: -File 传参不会按逗号拆分数组，这里统一支持 "a,b,c" 与 "a;b;c"
if ($Paths) { $Paths = @($Paths | ForEach-Object { $_ -split '[,;]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

# ---------------- 规则 ----------------
$rules = @(
  @{ name = 'SQL/应用口令赋值';  level = 'BLOCK'; re = '(?i)(password|pwd|passwd)\s*[=:]\s*["''](?![$<;])(?=[^"'']*["''])[A-Za-z0-9][^"''=+]{3,}["'']' },
  @{ name = '令牌赋值';          level = 'BLOCK'; re = '(?i)(token|secret|apikey|api_key)\s*[=:]\s*["''][A-Za-z0-9_\-\.]{16,}' },
  @{ name = 'Bearer 头';         level = 'BLOCK'; re = 'Bearer\s+[A-Za-z0-9_\-\.]{20,}' },
  @{ name = '私钥块';            level = 'BLOCK'; re = 'BEGIN [A-Z ]*PRIVATE KEY' },
  @{ name = '真实私网 IP';       level = 'BLOCK'; re = '\b10\.0\.0\.\d{1,3}\b' },
  @{ name = '邮箱地址';          level = 'BLOCK'; re = '\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b' },
  @{ name = 'QQ 号(仅上下文)'; level = 'INFO';  re = '(?i)(qq|扣扣)[^0-9]{0,6}[1-9][0-9]{4,10}' },
  @{ name = 'UNC 共享路径';      level = 'BLOCK'; re = '\\\\10\.\d+\.\d+\.\d+\\' },
  @{ name = '个人绝对路径';      level = 'INFO';  re = '(?i)(E:\\deepseek|C:\\dsh-mem|D:\\10\.0\.0|G:\\deepseek)' },
  @{ name = '本机用户名';        level = 'INFO';  re = '(?i)\b(dshuser|dshuser|dshuser)\b' }
)

$exts = @('.ps1', '.cmd', '.mjs', '.js', '.sql', '.json', '.yml', '.yaml', '.md', '.txt', '.psm1')
$skip = @('logs', 'outbox', '_tmp', '_share', '.git', 'node_modules', '.bak')

function Get-Targets {
  param([string[]]$P, [string]$R)
  $out = @()
  if ($P) {
    foreach ($x in $P) {
      if (Test-Path $x) {
        if ((Get-Item $x).PSIsContainer) { $out += @(Get-ChildItem $x -Recurse -File -ErrorAction SilentlyContinue) }
        else { $out += Get-Item $x }
      }
    }
  }
  if ($R) {
    if (Test-Path $R) { $out += @(Get-ChildItem $R -Recurse -File -ErrorAction SilentlyContinue) }
    else { Write-Output ('[FAIL] root not found: ' + $R) }
  }
  $out | Where-Object { $exts -contains $_.Extension.ToLower() } |
         Where-Object { $full = $_.FullName.ToLower(); -not ($skip | Where-Object { $full -like ('*\' + $_ + '\*') -or $full -like ('*\' + $_ + '.bak') }) } |
         Sort-Object FullName -Unique
}

$targets = @(Get-Targets -P $Paths -R $Root)
if (-not $Quiet) { Write-Output ('scanned files: ' + $targets.Count) }

# 允许清单：看起来像、其实不是凭据的常见写法
$allowLine = @(
  '\+\s*\$',                            # "..." + $var 拼接
  ';\s*(User Id|Password|Database|Server)=', # 连接串拼接
  'EXAMPLE_', '<PAIR-TOKEN', 'TEST-TOKEN',   # 示例/占位
  '00000000-0000-0000-0000-000000000000',    # 测试夹具 GUID
  'dead-beef'                                # 测试夹具
)
$selfPath = [System.IO.Path]::GetFullPath($PSCommandPath)

$blockHits = 0
$infoHits  = 0
$lines = @()

foreach ($f in $targets) {
  # skip self
  if ([System.IO.Path]::GetFullPath($f.FullName) -eq $selfPath) { continue }
  $n = 0
  # 2026-10-24: 必须按 **UTF-8** 读，不能依赖 BOM。
  # 之前用 Get-Content 读无 BOM 的 UTF-8 文件时会被当成 ANSI/GBK，
  # 中文与相邻 ASCII 被错配 ⇒ 明明有问题的文件被判 CLEAN（实测踩到：CI 报 BLOCK，本地却 CLEAN）。
  try { $content = (([System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)) -split "`r?`n") } catch { continue }
  foreach ($line in $content) {
    $n++
    foreach ($r in $rules) {
      if ($line -match $r.re) {
        # 允许：示例占位（EXAMPLE_ / <...> / 10.0.0.x / your- / 192.0.2.x）
        $isPlaceholder = ($line -match 'EXAMPLE_|<\s*[A-Za-z_ ]+\s*>|10\.0\.0\.x|your[-_ ]')
        # allow hit：命中允许清单则视为误报
        if (-not $isPlaceholder) { $isPlaceholder = [bool]($allowLine | Where-Object { $line -match $_ }) }
        if ($isPlaceholder -and $r.level -eq 'BLOCK') { continue }
        $tag = $r.level
        if ($tag -eq 'BLOCK') { $blockHits++ } else { $infoHits++ }
        $snippet = $line.Trim()
        if ($snippet.Length -gt 120) { $snippet = $snippet.Substring(0, 120) + '…' }
        $lines += ('[' + $tag + '] ' + $r.name + ' :: ' + $f.FullName + ':' + $n + ' :: ' + $snippet)
        break   # 每行只报一次，避免刷屏
      }
    }
  }
}

foreach ($l in $lines) { Write-Output $l }
if ($OutFile) { [System.IO.File]::WriteAllLines($OutFile, $lines, (New-Object System.Text.UTF8Encoding $false)) }

Write-Output ('SUMMARY: files=' + $targets.Count + ' block=' + $blockHits + ' info=' + $infoHits)
if ($blockHits -gt 0) { Write-Output 'RESULT: BLOCKED (must sanitize before publishing)'; exit 3 }
Write-Output 'RESULT: CLEAN'
