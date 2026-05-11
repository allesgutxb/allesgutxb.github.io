# Regenerate schedule SQL/CSV from data/schedule xlsx, then git commit/push.
# Run from repo root:  .\scripts\publish_schedule_data.ps1
# No push:              .\scripts\publish_schedule_data.ps1 -NoPush
# Custom message:       .\scripts\publish_schedule_data.ps1 -Message "update schedule"

param(
    [switch]$NoPush,
    [string]$Message = ""
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $RepoRoot

Write-Host "==> build_schedule_import.py" -ForegroundColor Cyan
$py = Join-Path $RepoRoot "scripts\build_schedule_import.py"
python $py
if ($LASTEXITCODE -ne 0) {
    Write-Host "Python failed." -ForegroundColor Red
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

Write-Host "==> git add" -ForegroundColor Cyan
foreach ($p in $toAdd) {
    # Use single-quoted '\' — double-quoted "\" breaks PS 5.1 parsing and causes bogus "missing }" errors later.
    $rel = $p.Replace('/', '\')
    $full = Join-Path $RepoRoot $rel
    if (Test-Path -LiteralPath $full) {
        git add -- $p
    }
}

$status = git status --short
if (-not $status) {
    Write-Host "Nothing to commit." -ForegroundColor Yellow
    exit 0
}

if (-not $Message) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $Message = "update schedule data $ts"
}

Write-Host "==> git commit" -ForegroundColor Cyan
git commit -m $Message

if ($NoPush) {
    Write-Host "Skipped push (-NoPush)." -ForegroundColor Yellow
    exit 0
}

Write-Host "==> git push" -ForegroundColor Cyan
git push

Write-Host "Done. Run scripts/schedule_replace_generated.sql in Supabase." -ForegroundColor Green
