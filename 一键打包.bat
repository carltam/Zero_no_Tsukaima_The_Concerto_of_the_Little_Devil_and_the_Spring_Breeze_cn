@echo off
chcp 936 >nul
setlocal

rem ============================================================
rem  零之使魔 小恶魔与春风的协奏曲 - 中文 ROM 一键打包
rem  用法：双击本文件。产物：output\01_patched.iso
rem ============================================================

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

echo ============================================================
echo   零之使魔 小恶魔与春风的协奏曲 - 中文 ROM 一键打包
echo   项目目录: %ROOT%
echo ============================================================
echo.

rem ---------- 前置检查 ----------
if not exist "%ROOT%\rom\01.iso" (
    echo [错误] 找不到原版 ISO: %ROOT%\rom\01.iso
    echo        请将原版日文 ISO 复制到 rom\ 目录并命名为 01.iso
    goto :fail
)

where python >nul 2>nul
if errorlevel 1 (
    echo [错误] 未找到 Python。请先安装 Python 3.x 并确保加入 PATH。
    goto :fail
)

python -c "import PIL" >nul 2>nul
if errorlevel 1 (
    echo [错误] 缺少 Pillow 库。请先执行: python -m pip install Pillow
    goto :fail
)

if not exist "C:\Windows\Fonts\msyh.ttc" (
    echo [错误] 未找到渲染字体 C:\Windows\Fonts\msyh.ttc
    echo        可修改 tools\build_all.ps1 的 -FontPath 参数指定其他字体。
    goto :fail
)

where powershell >nul 2>nul
if errorlevel 1 (
    echo [错误] 未找到 PowerShell。
    goto :fail
)

echo [1/1] 开始构建（完整流程约 20-30 分钟，期间请勿关闭窗口）...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\tools\run_build.ps1"
if errorlevel 1 goto :fail

if exist "%ROOT%\output\build\01_patched.iso" (
    move /y "%ROOT%\output\build\01_patched.iso" "%ROOT%\output\01_patched.iso" >nul
)

echo.
echo ============================================================
echo   构建成功！
echo   汉化 ROM   : %ROOT%\output\01_patched.iso
echo   构建日志   : %ROOT%\output\build.log
echo   自校验报告 : %ROOT%\output\build\verify.log
echo ============================================================
echo.
pause
exit /b 0

:fail
echo.
echo [失败] 构建未完成。请根据上方提示修正后重试；
echo        如仍失败，请把 output\build.log 发给汉化组定位问题。
pause
exit /b 1
