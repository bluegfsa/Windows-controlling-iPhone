# PhoneKit — one-time setup on a Windows PC
#
#   powershell -ExecutionPolicy Bypass -File install.ps1
#
# What it does: python venv, one dependency, wintun.dll (needed by the iOS 17+
# tunnel), then a full health check. Safe to re-run.

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here
Write-Host "== PhoneKit setup in $here ==" -ForegroundColor Cyan

# --- 1. python -------------------------------------------------------------
$py = $null
foreach ($cand in @("$here\.venv\Scripts\python.exe", "python", "py")) {
    try {
        $v = & $cand -c "import sys;print(sys.version_info>=(3,10))" 2>$null
        if ("$v".Trim() -eq "True") { $py = $cand; break }
    } catch { }
}
if (-not $py) { throw "Python 3.10+ not found. Install it from python.org (tick 'Add to PATH')." }
Write-Host "python: $py"

# --- 2. venv + deps --------------------------------------------------------
if (-not (Test-Path "$here\.venv\Scripts\python.exe")) {
    Write-Host "creating .venv ..."
    & $py -m venv "$here\.venv"
}
& "$here\.venv\Scripts\python.exe" -m pip install --quiet --upgrade pip
& "$here\.venv\Scripts\python.exe" -m pip install --quiet -r "$here\requirements.txt"
Write-Host "deps installed (requests)"

# --- 3. wintun.dll ---------------------------------------------------------
# go-ios' userspace tunnel loads wintun.dll from System32. Without it the
# tunnel dies with "Error loading wintun.dll" and NOTHING on iOS 17+ works.
$sys = "$env:WINDIR\System32\wintun.dll"
if (Test-Path $sys) {
    Write-Host "wintun.dll already present in System32"
} else {
    Write-Host "wintun.dll missing — copying (needs admin) ..." -ForegroundColor Yellow
    try {
        Copy-Item "$here\bin\wintun.dll" $sys -Force
        Write-Host "wintun.dll copied"
    } catch {
        Write-Host "Could not copy (not admin). Run this once in an ADMIN PowerShell:" -ForegroundColor Red
        Write-Host "  Copy-Item `"$here\bin\wintun.dll`" `"$sys`""
    }
}

# --- 4. health check -------------------------------------------------------
Write-Host "`n== health check ==" -ForegroundColor Cyan
& "$here\.venv\Scripts\python.exe" "$here\phone.py" doctor

Write-Host @"

Next steps:
  1. Plug the iPhone in over USB, unlock it, tap "Trust".
  2. Double-click up.cmd and LEAVE THE WINDOW OPEN (minimize it).
  3. phone.cmd status      -> should show  "wda": true
  4. phone.cmd shot --path hello.png

If doctor says the WebDriverAgent app is missing, follow docs/02-从零部署.md
section 4 (Sideloadly signing). Everything else is already installed.
"@ -ForegroundColor Green
