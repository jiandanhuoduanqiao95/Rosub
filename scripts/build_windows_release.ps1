# Rosub Windows 发行包一键构建
# 用法（在 Windows 仓库根的 scripts 目录下，PowerShell 执行）:
#   .\build_windows_release.ps1 -ServerHost <服务器公网IP> [-Version 1.0.0]
# 前提: 已安装 Flutter SDK（与开发机同版本），flutter doctor 无红色阻断项
param(
  [Parameter(Mandatory = $true)][string]$ServerHost,
  [string]$Version = "1.0.0"
)
$ErrorActionPreference = "Stop"

# 切到 Flutter 工程目录（脚本位于 <仓库根>\scripts\）
Set-Location (Join-Path $PSScriptRoot "..\chatroom_flutter")

flutter build windows --release --dart-define=CHATROOM_SERVER_HOST=$ServerHost
if ($LASTEXITCODE -ne 0) { throw "flutter build 失败" }

$dist = Join-Path (Get-Location) "..\dist"
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$out = Join-Path $dist "rosub-windows-x64-v$Version.zip"
if (Test-Path $out) { Remove-Item $out }
Compress-Archive -Path "build\windows\x64\runner\Release\*" -DestinationPath $out

Write-Host ""
Write-Host "完成: $out"
Write-Host "内置服务器地址: $ServerHost （朋友解压即用，无需配置）"
