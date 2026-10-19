@echo off
chcp 65001 >nul
cd /d "%~dp0"

rem 打包用 Python：优先用引擎目录下自带的 .venv（q3\.venv）。
rem ★ 以前这里指向 DaVinci-ASR 插件的 venv —— 那插件已删，
rem   打包环境必须完全自持，否则 build.bat 直接失效。
set PY=%~dp0..\.venv\Scripts\python.exe
if not exist "%PY%" set PY=C:\HEIBA\q3\.venv\Scripts\python.exe
set ISCC=%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe
if not exist "%ISCC%" set "ISCC=C:\Program Files (x86)\Inno Setup 6\ISCC.exe"

echo ============================================
echo  Qwen ASR · 安装器 打包
echo  PyInstaller onedir + Inno Setup
echo ============================================
echo.

if not exist "%PY%" (
  echo [错误] 找不到 Python: %PY%
  pause & exit /b 1
)
if not exist "%ISCC%" (
  echo [错误] 找不到 Inno Setup 编译器: %ISCC%
  echo        先装 Inno Setup 6: https://jrsoftware.org/isdl.php
  pause & exit /b 1
)

if exist build rmdir /s /q build
if exist dist  rmdir /s /q dist
if exist *.spec del /q *.spec

echo [1/2] PyInstaller 打包安装核心（onedir）...
"%PY%" -m PyInstaller ^
  --onedir ^
  --noconsole ^
  --clean ^
  --name "安装核心" ^
  --add-data "payload;payload" ^
  installer.py
if errorlevel 1 (
  echo [失败] PyInstaller 出错，请看上面的日志
  pause & exit /b 1
)
if not exist "dist\安装核心\安装核心.exe" (
  echo [失败] 没有生成 安装核心.exe
  pause & exit /b 1
)

echo [2/2] Inno Setup 编译安装包...
"%ISCC%" "Qwen ASR.iss"
if errorlevel 1 (
  echo [失败] Inno 编译出错，请看上面的日志
  pause & exit /b 1
)

echo.
if exist "dist\Qwen ASR安装器.exe" (
  echo [完成] dist\Qwen ASR安装器.exe
  for %%F in ("dist\Qwen ASR安装器.exe") do echo        大小: %%~zF 字节
  echo        双击运行 → 选位置 → 装完自动弹出下载向导
) else (
  echo [失败] 没有生成安装包
)
echo.
pause
