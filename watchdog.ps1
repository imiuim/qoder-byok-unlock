#Requires -Version 5.1
<#
.SYNOPSIS
  Qoder BYOK 看门狗 - 检测自定义模型补丁失效并自动修复
.DESCRIPTION
  监控当前实际运行的 Qoder 版本（从启动器 state.ini 读取），校验该版本的
  BYOK 补丁（app.asar P1-P4 + worker P5-P6）是否在位：
    - 在位        -> 静默/记日志
    - 失效/被更新 -> AutoRepair 模式下自动重跑 unlock.ps1（会结束 Qoder 进程）
                    并重启 Qoder；否则只记日志提醒
  注意：只能修复客户端补丁丢失（版本更新/切换导致）。智能体团队的服务端
  模型目录限制、BYOK 服务未就绪的瞬时抖动不属于可修复范围。
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File watchdog.ps1 -CheckOnce          # 只检查一次
  powershell -ExecutionPolicy Bypass -File watchdog.ps1 -AutoRepair         # 常驻，5 分钟一查，失效自动修复
  powershell -ExecutionPolicy Bypass -File watchdog.ps1 -IntervalSec 600 -AutoRepair
#>
param(
  [switch]$CheckOnce,
  [switch]$AutoRepair,
  [int]$IntervalSec = 300
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$LogFile = Join-Path $PSScriptRoot 'watchdog.log'
$StateFile = Join-Path $PSScriptRoot 'watchdog.state.json'

function Log($m){
  $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  Write-Host $line
  Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Read-StateIni {
  # 从启动器 state.ini 拿实际运行中的版本目录
  $ini = "$env:LOCALAPPDATA\Qoder\Qoder Launcher\state.ini"
  if (-not (Test-Path $ini)) { return $null }
  $txt = [IO.File]::ReadAllText($ini)
  if ($txt -match "\x00") { $txt = [IO.File]::ReadAllText($ini, [Text.Encoding]::Unicode) }
  $installDir = $null; $appExe = $null
  foreach ($line in ($txt -split "\r?\n")) {
    if ($line -match '^\s*installDir\s*=\s*(.+?)\s*$') { $installDir = $Matches[1].Trim() }
    if ($line -match '^\s*appExecutable\s*=\s*(.+?)\s*$') { $appExe = $Matches[1].Trim() }
  }
  if (-not $installDir -or -not $appExe) { return $null }
  # appExecutable 两种形态：.qoder-versions\0.5.6\Qoder.exe 或裸 Qoder.exe
  # 裸形态时取 .qoder-versions 下语义化版本最新的目录
  $exePath = Join-Path $installDir $appExe
  if (-not (Test-Path $exePath)) { return $null }
  $versionDir = $null
  if ($appExe -match '\.qoder-versions[\\/](\d+\.\d+\.\d+)') {
    $versionDir = Join-Path $installDir ('.qoder-versions\' + $Matches[1])
  } else {
    $vroot = Join-Path $installDir '.qoder-versions'
    if (Test-Path $vroot) {
      $best = Get-ChildItem $vroot -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
      if ($best) { $versionDir = $best.FullName }
    }
  }
  if (-not $versionDir -or -not (Test-Path (Join-Path $versionDir 'Qoder.exe'))) { return $null }
  return @{
    InstallDir = $installDir
    ExePath    = $exePath
    VersionDir = $versionDir
  }
}

# 生成/复用 node 校验脚本（只读文件，不改任何东西）
$checkScript = Join-Path $env:TEMP 'qoder-watchdog-check.cjs'
@'
const fs = require('fs');
const [asarPath, workerPath] = process.argv.slice(2);
const out = { asarOk: false, workerP5Ok: false, workerP6Ok: false, error: null };
try {
  const asar = fs.readFileSync(asarPath);
  out.asarOk = asar.includes(Buffer.from('models:z.filter(M=>M!==null)/*', 'utf8'));
  const wk = fs.readFileSync(workerPath, 'utf8');
  out.workerP5Ok = wk.includes('featureSwitches?.allow_byok??0)>=1');
  out.workerP6Ok = wk.includes('replaceCustomProviderSettings?.(d.providers)');
} catch (e) { out.error = e.message; }
console.log(JSON.stringify(out));
'@ | Set-Content $checkScript -Encoding UTF8

function Test-PatchState($ver) {
  $asarPath   = Join-Path $ver.VersionDir 'resources\app.asar'
  $workerPath = Join-Path $ver.VersionDir 'resources\app.asar.unpacked\node_modules\@qoder-ai\qoder-agent-sdk\dist\_worker\qoder-worker-runtime.obf.mjs'
  if (-not (Test-Path $asarPath))   { return @{ ok=$false; reason="缺 $asarPath" } }
  if (-not (Test-Path $workerPath)) { return @{ ok=$false; reason="缺 $workerPath" } }
  $raw = node $checkScript $asarPath $workerPath 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $raw) { return @{ ok=$false; reason='node 校验脚本执行失败' } }
  $s = $raw | ConvertFrom-Json
  if ($s.error) { return @{ ok=$false; reason=$s.error } }
  $missing = @()
  if (-not $s.asarOk)     { $missing += 'asar补丁(P1-P4)' }
  if (-not $s.workerP5Ok) { $missing += 'worker补丁(P5)' }
  if (-not $s.workerP6Ok) { $missing += 'worker补丁(P6)' }
  if ($missing.Count -gt 0) { return @{ ok=$false; reason=($missing -join '、') } }
  return @{ ok=$true; reason='' }
}

function Get-LastState {
  if (Test-Path $StateFile) { try { return (Get-Content $StateFile -Raw | ConvertFrom-Json) } catch {} }
  return $null
}
function Set-LastState($status, $detail){
  @{ status=$status; detail=$detail; at=(Get-Date -Format 'o') } |
    ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
}

function Invoke-Check {
  $ver = Read-StateIni
  if (-not $ver) {
    Log '[!] 未读到启动器 state.ini 的运行版本（Qoder 未安装或未运行过），跳过'
    Set-LastState 'unknown' 'no state.ini'
    return
  }
  $verName = Split-Path $ver.VersionDir -Leaf
  $st = Test-PatchState $ver

  if ($st.ok) {
    $last = Get-LastState
    if (-not $last -or $last.status -ne 'ok') {
      Log "[OK] 版本 $verName 补丁在位"
    }
    Set-LastState 'ok' $verName
    return
  }

  Log "[X] 版本 $verName 补丁失效: $($st.reason)"
  Set-LastState 'broken' $st.reason

  if ($AutoRepair) {
    Log '[..] 自动修复: 重跑 unlock.ps1（会结束 Qoder 进程）...'
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'unlock.ps1') 2>&1
    $code = $LASTEXITCODE
    $out | ForEach-Object { Log "    $_" }
    if ($code -eq 0) {
      Log '[OK] 补丁已重新应用'
      # 重启 Qoder（从启动器 installDir 启动）
      if (Test-Path (Join-Path $ver.InstallDir 'Qoder.exe')) {
        Start-Process (Join-Path $ver.InstallDir 'Qoder.exe')
        Log '[OK] Qoder 已重启'
      } else {
        Log '[!] 未找到启动器入口，请手动启动 Qoder'
      }
    } else {
      Log "[X] unlock.ps1 退出码 $code（可能版本锚点漂移，需人工适配），未重启 Qoder"
    }
  } else {
    Log '[!] 未启用 -AutoRepair，请手动执行: powershell -ExecutionPolicy Bypass -File unlock.ps1'
  }
}

# ---------- 入口 ----------
if ($CheckOnce) {
  Invoke-Check
  exit 0
}
Log "看门狗启动 (interval=${IntervalSec}s, autoRepair=$AutoRepair)"
while ($true) {
  try { Invoke-Check } catch { Log "[X] 检查异常: $($_.Exception.Message)" }
  Start-Sleep $IntervalSec
}
