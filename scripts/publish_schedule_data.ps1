# 一键：根据 data/schedule 下 xlsx 重新生成 SQL/CSV 并提交推送到 GitHub
# 用法（在仓库根目录）:  .\scripts\publish_schedule_data.ps1
# 仅生成不推送:        .\scripts\publish_schedule_data.ps1 -NoPush
# 自定义提交说明:      .\scripts\publish_schedule_data.ps1 -Message "更新春季课表"

param(
    [switch]$NoPush,
    [string]$Message = ""
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $RepoRoot

Write-Host "==> 生成 schedule SQL/CSV (Python)..." -ForegroundColor Cyan
python (Join-Path $RepoRoot "scripts\build_schedule_import.py")
if ($LASTEXITCODE -ne 0) {
    Write-Host "生成失败，已中止。" -ForegroundColor Red
    exit $LASTEXITCODE
}

$toAdd = @(
    "data/schedule/timetable.xlsx",
    "data/schedule/teachers.xlsx",
    "data/schedule/README.md",
    "scripts/schedule_generated.csv",
    "scripts/schedule_replace_generated.sql",
    "scripts/schedule_missing_teachers.txt",
    "scripts/build_schedule_import.py",
    "scripts/publish_schedule_data.ps1",
    "db_checklist_supabase.sql"
)

Write-Host "==> git add ..." -ForegroundColor Cyan
foreach ($p in $toAdd) {
    $full = Join-Path $RepoRoot $p.Replace("/", "\"))
    if (Test-Path -LiteralPath $full) {
        git add -- $p
    }
}

$status = git status --short
if (-not $status) {
    Write-Host "无变更可提交。" -ForegroundColor Yellow
    exit 0
}

if (-not $Message) {
    $Message = "更新课表数据与导入 SQL $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
}

Write-Host "==> git commit" -ForegroundColor Cyan
git commit -m $Message

if ($NoPush) {
    Write-Host "已跳过推送（-NoPush）。本地提交已完成。" -ForegroundColor Yellow
    exit 0
}

Write-Host "==> git push" -ForegroundColor Cyan
git push

Write-Host "完成。请在 Supabase 执行 scripts/schedule_replace_generated.sql 以更新数据库。" -ForegroundColor Green
