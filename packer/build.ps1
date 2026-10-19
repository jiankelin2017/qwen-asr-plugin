# Qwen ASR installer build script (PowerShell, ASCII-only for PS5.1 compat)
# Usage: powershell -ExecutionPolicy Bypass -File build.ps1
# Chain: PyInstaller onedir (install core) -> Inno Setup compile (one-click install/uninstall pkg)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$py = "C:\HEIBA\q3\.venv\Scripts\python.exe"
if (-not (Test-Path $py)) { $py = Join-Path (Split-Path $PSScriptRoot -Parent) ".venv\Scripts\python.exe" }
$iscc = "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
if (-not (Test-Path $iscc)) { $iscc = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" }

if (-not (Test-Path $py))   { Write-Output "[ERROR] Python not found: $py"; exit 1 }
if (-not (Test-Path $iscc)) { Write-Output "[ERROR] Inno Setup compiler not found: $iscc"; exit 1 }

Remove-Item -Recurse -Force build -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force dist -ErrorAction SilentlyContinue
Remove-Item -Force *.spec -ErrorAction SilentlyContinue

Write-Output "[1/2] PyInstaller onedir (install core)..."
& $py -m PyInstaller --onedir --noconsole --clean --name "安装核心" --add-data "payload;payload" installer.py
if ($LASTEXITCODE -ne 0) { Write-Output "PYINSTALLER_FAILED"; exit 1 }
if (-not (Test-Path "dist\安装核心\安装核心.exe")) { Write-Output "[FAIL] dist\安装核心\安装核心.exe missing"; exit 1 }

Write-Output "[2/2] Inno Setup compile..."
& $iscc "Qwen ASR.iss"
if ($LASTEXITCODE -ne 0) { Write-Output "ISCC_FAILED"; exit 1 }

if (Test-Path "dist\Qwen ASR安装器.exe") {
    Write-Output "BUILD_DONE"
    Get-ChildItem dist | Select-Object Name, Length | Format-Table -AutoSize
} else {
    Write-Output "[FAIL] installer exe not produced"
    exit 1
}
