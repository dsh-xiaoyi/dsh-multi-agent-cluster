# 第一次用？先看 README 的「5 分钟跑起来」，再回来读这个脚本。
# install.ps1 - 多智能体集群 · 一键安装（单机最小闭环）
#
# 只做"能把记忆跑起来"的最小动作，不修改系统安全设置、不安装第三方杀软、不联网下载。
# 需要：Windows + PowerShell 5.1+、SQL Server（Express 可用）、Node.js（青鸟插件需要）
param(
    [string]$ConfigPath = 'C:\dsh-mem\dsh-mem.config.json',
    [string]$SqlServer  = '127.0.0.1,1433',
    [string]$Database   = 'DSHMemory',
    [switch]$SkipDdl
)
$ErrorActionPreference = 'Stop'
function Say($m) { Write-Host ('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $m) }

function Test-Prerequisites {
    # 缺依赖要"吵"，不要默默跑一半
    $missing = @()
    if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) { $missing += 'sqlcmd（SQL Server 命令行工具，装 SQL Server 或 ODBC Driver 时自带）' }
    if (-not (Get-Command node   -ErrorAction SilentlyContinue)) { $missing += 'node（Node.js，青鸟/记忆注入插件需要）' }
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($missing.Count -gt 0) {
        Write-Host ''
        Write-Host '还差这些前置条件（装好后再跑一次）：' -ForegroundColor Yellow
        foreach ($m in $missing) { Write-Host ('  · ' + $m) -ForegroundColor Yellow }
        Write-Host '  说明：本脚本不改系统安全设置、不联网下载任何东西。' -ForegroundColor DarkGray
        throw '前置条件不足'
    }
    if (-not $isAdmin) {
        Write-Host '提示：当前不是管理员。建表/建库那一步需要 sysadmin 连接；如果只是验证流程可以先跳过 DDL。' -ForegroundColor Yellow
    }
}


Test-Prerequisites

Say '1/5 准备目录 C:\dsh-mem'
New-Item -ItemType Directory -Path 'C:\dsh-mem' -Force | Out-Null

Say '2/5 生成配置（若已存在则跳过）'
if (-not (Test-Path $ConfigPath)) {
    $example = Join-Path $PSScriptRoot '..\examples\config.example.json'
    if (Test-Path $example) {
        $t = Get-Content $example -Raw
        $t = $t -replace '192\.0\.2\.11,1433', $SqlServer -replace 'DSHMemory', $Database
        [System.IO.File]::WriteAllText($ConfigPath, $t, (New-Object System.Text.UTF8Encoding $false))
        Say ('   已生成 ' + $ConfigPath + '（请按需修改 user/password）')
    } else { throw '找不到 examples\config.example.json' }
} else { Say '   已存在，跳过' }

if (-not $SkipDdl) {
    Say '3/5 建库建表（需要 sysadmin；失败会停下并提示）'
    $sqlDir = Join-Path $PSScriptRoot '..\packages\memory\sql'
    $files = @(Get-ChildItem $sqlDir -Filter '*.sql' | Sort-Object Name)
    if ($files.Count -eq 0) { throw ('没有找到 SQL 脚本: ' + $sqlDir) }
    foreach ($f in $files) {
        Say ('   - ' + $f.Name)
        & cmd.exe /c ('sqlcmd -E -S ' + $SqlServer + ' -d ' + $Database + ' -b -i "' + $f.FullName + '"')
        if ($LASTEXITCODE -ne 0) { throw ('SQL 执行失败: ' + $f.Name + '（exit=' + $LASTEXITCODE + '）') }
    }
} else { Say '3/5 跳过 DDL' }

Say '4/5 安装记忆注入插件（link 到本仓库）'
$pluginSrc = Resolve-Path (Join-Path $PSScriptRoot '..\packages\memory\plugin')
$profileDir = Join-Path $env:USERPROFILE '.dsh\profiles\desktop'
$nm = Join-Path $profileDir 'node_modules'
New-Item -ItemType Directory -Path $nm -Force | Out-Null
$target = Join-Path $nm 'dsh-memory-bridge'
if (Test-Path $target) { Say '   已存在，跳过（要更新请手动替换）' }
else {
    cmd /c mklink /D "$target" "$pluginSrc" | Out-Null
    Say ('   已链接: ' + $target + ' → ' + $pluginSrc)
    Say '   ★ 还需要在 package.json 里声明依赖，然后**重启 DSH**，否则插件不会加载'
}

Say '5/5 体检'
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'doctor.ps1') -ConfigPath $ConfigPath
