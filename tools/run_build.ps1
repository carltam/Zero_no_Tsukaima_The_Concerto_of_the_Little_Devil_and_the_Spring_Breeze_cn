# run_build.ps1 — 一键打包运行器（由「一键打包.bat」调用，也可单独运行）。
# 职责：调用 build_all.ps1 完整构建，全程输出到屏幕并写入 output\build.log，
#       构建失败时以退出码 1 结束（批处理据此判断成败）。
param(
    [string]$Root = (Split-Path $PSScriptRoot -Parent)
)
$ErrorActionPreference = "Stop"
$log = Join-Path $Root "output\build.log"
$outDir = Join-Path $Root "output\build"
$transDir = Join-Path $Root "text"
if (-not (Test-Path (Split-Path $log -Parent))) { New-Item -ItemType Directory -Path (Split-Path $log -Parent) -Force | Out-Null }

try {
    & (Join-Path $PSScriptRoot "build_all.ps1") -OutDir $outDir -TransDir $transDir 2>&1 |
        Tee-Object -FilePath $log
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n[错误] 构建步骤返回非零退出码 ($LASTEXITCODE)，详见 $log" -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host "`n[错误] 构建失败：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "详见 $log" -ForegroundColor Red
    exit 1
}
Write-Host "`n构建完成，日志: $log" -ForegroundColor Green
exit 0
