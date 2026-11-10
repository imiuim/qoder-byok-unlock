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
  另外检测 BYOK 模型目录瞬时掉线（byokModelCount:0 / ByokModelError，
  对应弹窗「这个个人模型已被删除或不再属于当前账号」），无 BOM 重写
  settings.json 的 providers 触发目录重载，不重启 Qoder。
  注意：服务端团队限制、BYOK 上游服务本身不可用不属于可修复范围。
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
  $exePath = Join-Path $installDir $appExe
  if (-not (Test-Path $exePath)) { return $null }
  # 0.5.7+ 新布局优先：app.asar 直接在 <root>\resources\
  if (Test-Path (Join-Path $installDir 'resources\app.asar')) {
    return @{
      InstallDir = $installDir
      ExePath    = $exePath
      VersionDir = $installDir
      Layout     = 'root'
    }
  }
  # 0.5.6 旧布局：.qoder-versions\<ver>
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
    Layout     = 'versions'
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
  // P6 两种形态：v1 全量替换(SE) / v2 最小注入(DE)，任一命中即可
  out.workerP6Ok = wk.includes('replaceCustomProviderSettings?.(d.providers)') ||
                   wk.includes('e.startsWith("qoder-custom-")');
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

function Invoke-ProviderConfigCheck {
  # BYOK provider 配置自愈：settings.json 的 providers 丢失是"重启后模型消失"的主因
  $settings = Join-Path $env:USERPROFILE '.qoder\settings.json'
  $snapshot = Join-Path $env:USERPROFILE '.qoder\providers.snapshot.json'
  if (-not (Test-Path $settings)) { Log '[!] settings.json 不存在，跳过配置检查'; return }
  $providers = $null
  try { $providers = (Get-Content $settings -Raw | ConvertFrom-Json).providers } catch { Log '[!] settings.json 解析失败'; return }
  $count = if ($providers) { @($providers.PSObject.Properties.Name).Count } else { 0 }

  if ($count -gt 0) {
    # 配置健在：更新快照（含首次建立）
    # 注意：PS5.1 的 -Encoding UTF8 会写 BOM，Qoder 解析 settings.json 会因 BOM 报
    # "Unexpected token '\uFEFF'" 而丢失默认模型，必须用无 BOM 的 UTF8。
    try {
      [IO.File]::WriteAllText($snapshot, ($providers | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
    } catch {}
    return
  }

  Log "[X] settings.json 的 BYOK providers 为空（模型会消失）"
  if (-not (Test-Path $snapshot)) { Log '[!] 无 providers.snapshot.json 快照，无法自动恢复'; return }
  if (-not $AutoRepair) { Log '[!] 未启用 -AutoRepair，可用该参数自动从快照恢复'; return }
  try {
    $snap = Get-Content $snapshot -Raw | ConvertFrom-Json
    $n = if ($snap) { @($snap.PSObject.Properties.Name).Count } else { 0 }
    if ($n -eq 0) { Log '[!] 快照为空，跳过恢复'; return }
    $d = Get-Content $settings -Raw | ConvertFrom-Json
    $d | Add-Member -NotePropertyName providers -NotePropertyValue $snap -Force
    [IO.File]::WriteAllText($settings, ($d | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
    Log "[OK] 已从快照恢复 $n 个 provider（无 BOM 写入，重启 Qoder 后生效）"
  } catch { Log "[X] 快照恢复失败: $($_.Exception.Message)" }
}

function Invoke-ByokModelDropCheck {
  # 模型策略同步抖动: 一次慢刷新会把 byokModelCount 短暂清零，此时发消息报
  # "这个个人模型已被删除或不再属于当前账号"（main.log: ByokModelError）。
  # 自愈方式：无 BOM 重写 settings.json 的 providers，触发目录重载；不重启 Qoder。
  $logRoot = Join-Path $env:APPDATA 'com.qoder.app.stable\logs'
  if (-not (Test-Path $logRoot)) { return }
  $cut = (Get-Date).ToUniversalTime().AddMinutes(-15)
  $hit = $null
  foreach ($d in (Get-ChildItem $logRoot -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 2)) {
    $f = Join-Path $d.FullName 'main.log'
    if (-not (Test-Path $f)) { continue }
    try {
      foreach ($line in (Get-Content $f -Tail 1500)) {
        if ($line -notmatch 'byokModelCount":0|ByokModelError') { continue }
        if ($line -match '^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})') {
          $ts = [datetime]::ParseExact($Matches[1], 'yyyy-MM-ddTHH:mm:ss', $null)
          if ($ts -lt $cut) { continue }
        }
        $hit = $line
        break
      }
    } catch {}
    if ($hit) { break }
  }
  if (-not $hit) { $script:lastByokHit = $null; return }
  if ($script:lastByokHit -eq $hit) { return }   # 同一次掉线只自愈一次
  $script:lastByokHit = $hit
  Log '[X] 检测到 BYOK 模型目录掉线（byokModelCount:0 / ByokModelError）'
  $settings = Join-Path $env:USERPROFILE '.qoder\settings.json'
  if (-not (Test-Path $settings)) { Log '[!] settings.json 不存在，跳过自愈'; return }
  try {
    $cfg = Get-Content $settings -Raw | ConvertFrom-Json
    $n = if ($cfg.providers) { @($cfg.providers.PSObject.Properties.Name).Count } else { 0 }
    if ($n -eq 0) { Log '[!] providers 为空，由 Invoke-ProviderConfigCheck 恢复'; return }
    # 先删除再无 BOM 写入：保证文件变化能被 Qoder 的 settings watcher 捕获
    Remove-Item $settings -Force
    [IO.File]::WriteAllText($settings, ($cfg | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
    Log "[OK] 已无 BOM 重写 settings.json（$n 个 provider），触发 BYOK 目录重载，无需重启 Qoder"
  } catch { Log "[X] BYOK 目录自愈失败: $($_.Exception.Message)" }
}

function Invoke-Check {
  Invoke-ProviderConfigCheck
  Invoke-ByokModelDropCheck
  $ver = Read-StateIni
  if (-not $ver) {
    Log '[!] 未读到启动器 state.ini 的运行版本（Qoder 未安装或未运行过），跳过'
    Set-LastState 'unknown' 'no state.ini'
    return
  }
  $verName = Split-Path $ver.VersionDir -Leaf
  if ($ver.Layout -eq 'root') { $verName = "$(Split-Path $ver.InstallDir -Leaf) (root布局)" }
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
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'unlock-v2.ps1') 2>&1
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
    Log '[!] 未启用 -AutoRepair，请手动执行: powershell -ExecutionPolicy Bypass -File unlock-v2.ps1'
  }
}

# ---------- 入口 ----------
if ($CheckOnce) {
  Invoke-Check
  exit 0
}

# 单实例锁：登录触发器可能多次触发，避免两个守护进程同时检查/重复重打补丁
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\QoderByokWatchdog', ([ref]$createdNew))
if (-not $createdNew) {
  Log '[..] 已有一个看门狗在运行，本实例退出'
  $mutex.Dispose()
  exit 0
}
Log "看门狗启动 (interval=${IntervalSec}s, autoRepair=$AutoRepair)"
try {
  while ($true) {
    try { Invoke-Check } catch { Log "[X] 检查异常: $($_.Exception.Message)" }
    Start-Sleep $IntervalSec
  }
} finally {
  $mutex.ReleaseMutex()
  $mutex.Dispose()
}
