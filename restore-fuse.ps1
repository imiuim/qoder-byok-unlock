#Requires -Version 5.1
<#
.SYNOPSIS
  重新开启 Qoder.exe 的 Electron ASAR Integrity fuse（回滚辅助脚本）。
.DESCRIPTION
  unlock.ps1 翻转 fuse 以允许修改 app.asar；-Rollback 时除了还原文件，还应把 fuse 重新打开，
  恢复 Qoder.exe 出厂时的完整性校验行为。
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File restore-fuse.ps1 -ExePath "E:\Qoder\.qoder-versions\0.5.6\Qoder.exe"
#>
param(
  [Parameter(Mandatory=$true)]
  [string]$ExePath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not (Test-Path $ExePath)) { Write-Host "[X] 缺文件: $ExePath" -ForegroundColor Red; exit 1 }

# 复用 unlock.ps1 已装的 @electron/fuses
$nodeModules = $null
foreach ($cand in @(
  (Join-Path $env:TEMP 'qoder-unlock-fuses\node_modules\@electron\fuses'),
  (Join-Path $PSScriptRoot 'node_modules\@electron\fuses')
)) {
  if (Test-Path (Join-Path $cand 'dist\index.js')) { $nodeModules = $cand; break }
}
if (-not $nodeModules) {
  Info = $null
  Write-Host "[..] 安装 @electron/fuses（一次性）..." -ForegroundColor Cyan
  $tmp = Join-Path $env:TEMP "qoder-unlock-fuses"
  New-Item $tmp -ItemType Directory -Force | Out-Null
  Push-Location $tmp
  $ErrorActionPreference = 'Continue'
  if (-not (Test-Path 'package.json')) { cmd /c "npm init -y >nul 2>nul" | Out-Null; cmd /c "npm i @electron/fuses@1.3.0 --no-audit --no-fund --save-exact >nul 2>nul" | Out-Null }
  $ErrorActionPreference = 'Stop'
  Pop-Location
  $nodeModules = Join-Path $tmp 'node_modules\@electron\fuses'
}
$fusesJs = Join-Path $nodeModules 'dist\index.js'
if (-not (Test-Path $fusesJs)) { Write-Host "[X] @electron/fuses 不可用（需要 node/npm）" -ForegroundColor Red; exit 1 }

$restoreScript = Join-Path $env:TEMP 'qoder-restore-fuse.cjs'
@'
const f=require(process.argv[3]);
(async()=>{
  await f.flipFuses(process.argv[2],{version:f.FuseVersion.V1,[f.FuseV1Options.EnableEmbeddedAsarIntegrityValidation]:true});
  const w=await f.getCurrentFuseWire(process.argv[2]);
  console.log('fuse wire:',JSON.stringify(w));
  const on = w[f.FuseV1Options.EnableEmbeddedAsarIntegrityValidation];
  if(!on){console.error('fuse still off');process.exit(1)}
  console.log('ASAR integrity fuse ON');
})().catch(e=>{console.error('ERR',e.message);process.exit(1)});
'@ | Set-Content $restoreScript -Encoding UTF8

Write-Host "[..] 重新开启 ASAR integrity fuse..." -ForegroundColor Cyan
node $restoreScript $ExePath $fusesJs
if ($LASTEXITCODE -ne 0) { Write-Host "[X] fuse 恢复失败" -ForegroundColor Red; exit 1 }
Write-Host "[OK] ASAR integrity fuse 已恢复" -ForegroundColor Green
