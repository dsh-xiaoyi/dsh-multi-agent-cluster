# check-backup-pack.ps1 - 周包新鲜度 + 目录整洁度
#
# 修正记录（2026-10-23 20:42）：
#   旧版要求"暂存目录里有 ≤2 天的 .bak" —— 但使用方明确
#   "明文暂存确认同步后即删，暂存目录只留两份说明文件"，
#   所以旧判据永远 FAIL（自相矛盾的灯，比红灯更糟）。
#   新版判据：
#     ① 投放目录下最新 .7z 年龄 ≤ MaxPackDays（周备份是否在跑）
#     ② 投放目录里不要出现裸 .bak/.zip（该目录只放 .7z 与说明）
#     ③ 暂存目录只允许两件说明文件（不得有暂存残留）
param(
  [string]$PackDir  = $(if ($env:DSH_PACK_DIR) { $env:DSH_PACK_DIR } else { 'C:\dsh-mem\.backup' }),
  [string]$StageDir = $(if ($env:DSH_STAGE_DIR) { $env:DSH_STAGE_DIR } else { 'C:\dsh-mem\.dshbackup' }),
  [int]$MaxPackDays = 8
)
$ErrorActionPreference = 'Continue'
$bad = 0

# ① 周包新鲜度
if (Test-Path $PackDir) {
  $p = Get-ChildItem $PackDir -File -Filter '*.7z' -ErrorAction SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($p) {
    $age = [math]::Round(((Get-Date) - $p.LastWriteTime).TotalDays, 1)
    Write-Output ('[INFO] newest pack: ' + $p.Name + '  ' + [math]::Round($p.Length / 1MB, 1) + 'MB  age=' + $age + 'd')
    if ($age -gt $MaxPackDays) { Write-Output ('[FAIL] weekly pack older than ' + $MaxPackDays + ' days'); $bad++ }
  } else { Write-Output '[FAIL] no .7z in pack dir'; $bad++ }

  # ② 投放目录不得有裸备份
  $raw = @(Get-ChildItem $PackDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.bak', '.zip' })
  if ($raw.Count -gt 0) {
    Write-Output ('[FAIL] raw backup files in pack dir: ' + (($raw | ForEach-Object { $_.Name }) -join ', '))
    $bad++
  } else { Write-Output '[INFO] pack dir clean (no raw .bak/.zip)' }
} else { Write-Output ('[FAIL] pack dir missing: ' + $PackDir); $bad++ }

# ③ 暂存目录只留说明文件
$allowed = @('备份记录.txt', '【说明】关于17的唤醒.txt')
if (Test-Path $StageDir) {
  $extra = @(Get-ChildItem $StageDir -Force -ErrorAction SilentlyContinue |
             Where-Object { $allowed -notcontains $_.Name })
  if ($extra.Count -gt 0) {
    Write-Output ('[FAIL] staging dir has non-note items (delete after sync): ' + (($extra | ForEach-Object { $_.Name }) -join ', '))
    $bad++
  } else { Write-Output '[INFO] staging dir holds only the two notes' }
} else { Write-Output ('[WARN] staging dir missing: ' + $StageDir) }

if ($bad -gt 0) { Write-Output 'RESULT: FAIL'; exit 3 }
Write-Output 'RESULT: PASS'
