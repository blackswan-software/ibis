# install.ps1 — put the ibis CLI on your PATH (Windows).
# ibis is a bash program, so it needs Git for Windows (Git Bash) or WSL. This
# writes a tiny .cmd shim that hands off to bash. Per-repo scheduling is set up
# later by `ibis init` (Task Scheduler + a PowerShell FileSystemWatcher).
$ErrorActionPreference = "Stop"
$src  = Split-Path -Parent $MyInvocation.MyCommand.Path
$dest = Join-Path $env:USERPROFILE ".local\bin"
New-Item -ItemType Directory -Force -Path $dest | Out-Null

$bin  = ($src -replace '\\','/') + "/bin/ibis"
$shim = Join-Path $dest "ibis.cmd"
"@echo off`r`nbash `"$bin`" %*" | Set-Content -Encoding ASCII $shim
Write-Host "linked $shim -> bash $bin"

if (-not (Get-Command bash -ErrorAction SilentlyContinue)) {
  Write-Warning "bash not found. Install 'Git for Windows' (Git Bash) or enable WSL, then re-run."
}
if (-not (Get-Command python3 -ErrorAction SilentlyContinue) -and -not (Get-Command python -ErrorAction SilentlyContinue)) {
  Write-Warning "python not found. Install Python 3 and ensure it's on PATH."
}

# Ensure ~/.local/bin is on the user PATH
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$dest*") {
  [Environment]::SetEnvironmentVariable("Path", "$userPath;$dest", "User")
  Write-Host "added $dest to your user PATH (restart the terminal)"
}

Write-Host ""
Write-Host "Next (in Git Bash):  cd your-repo && ibis init --adopt"
