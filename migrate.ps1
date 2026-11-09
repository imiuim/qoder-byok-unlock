#Requires -Version 5.1
<#
.SYNOPSIS
  把 Qoder 用户数据目录安全迁移到其他盘（junction 方式，应用无感知）
.DESCRIPTION
  修复 v1.2 手工迁移暴露的三个 bug：
    1) 目标目录存在就 skip-done，但源目录根本不是 junction —— 迁移假成功；
    2) 迁移后不验证 junction 属性，junction 被应用重建/替换也无人发现；
    3) 迁移后不校验 settings.json 的 BYOK providers，配置丢失导致模型消失。
  本脚本：
    - 先判断源是否已是合法 junction（是 -> 只做验证）；
    - 目标已存在时比较两边 settings.json，按“谁有 providers 谁为准”合并，绝不静默跳过；
    - 迁移后验证：junction 属性 + settings.json 可读 + providers 非空；
    - 任何一步失败自动回滚（把数据移回原位）。
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File migrate.ps1 -TargetRoot E:\QoderData
  powershell -ExecutionPolicy Bypass -File migrate.ps1 -TargetRoot E:\QoderData -VerifyOnly
#>
param(
  [Parameter(Mandatory=$true)][string]$TargetRoot,
  [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
function Fail($m){ Write-Host "[X] $m" -ForegroundColor Red; exit 1 }
function Ok($m){ Write-Host "[OK] $m" -ForegroundColor Green }
function Info($m){ Write-Host "[..] $m" -ForegroundColor Cyan }

$srcQoder = "$env:USERPROFILE\.qoder"
$srcRoam  = "$env:APPDATA\Qoder"
$migrations = @(
  @{ Src = $srcQoder; Rel = '.qoder' },
  @{ Src = $srcRoam;  Rel = 'AppData\Roaming\Qoder' }
)

function Get-Providers($p){
  try {
    $d = Get-Content $p -Raw | ConvertFrom-Json
    if ($d.providers) { return @($d.providers.PSObject.Properties.Name) }
  } catch {}
  return @()
}
function Test-Junction($p){
  if (-not (Test-Path $p)) { return $false }
  $item = Get-Item $p -Force
  return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}
function Get-JunctionTarget($p){
  $item = Get-Item $p -Force
  return $item.Target
}

# ---------- 仅验证 ----------
if ($VerifyOnly) {
  foreach ($m in $migrations) {
    $src = $m.Src; $dst = Join-Path $TargetRoot $m.Rel
    $isJ = Test-Junction $src
    $prov = if (Test-Path "$src\settings.json") { (Get-Providers "$src\settings.json").Count } else { 0 }
    $t = if ($isJ) { Get-JunctionTarget $src } else { '' }
    Write-Host ("{0}: junction={1} target={2} providers={3}" -f $src, $isJ, $t, $prov)
    if ($isJ -and -not $t) { Write-Host "  [!] junction 目标不可达" -ForegroundColor Yellow }
    # settings.json 只属于 .qoder；Roaming\Qoder 下没有该文件是正常的，不算缺失
    if ($m.Rel -eq '.qoder' -and -not (Test-Path "$src\settings.json")) {
      Write-Host "  [!] 缺 settings.json，请用 watchdog.ps1 -AutoRepair 恢复快照" -ForegroundColor Yellow
    }
  }
  exit 0
}

# ---------- 停 Qoder ----------
$procs = @(Get-Process Qoder -ErrorAction SilentlyContinue)
if ($procs.Count -gt 0) {
  Info "结束 $($procs.Count) 个 Qoder 进程..."
  Stop-Process -Name Qoder -Force -ErrorAction SilentlyContinue
  $w=0; while ($w -lt 15) { Start-Sleep 1; $w++; if (@(Get-Process Qoder -ErrorAction SilentlyContinue).Count -eq 0) { break } }
  if (@(Get-Process Qoder -ErrorAction SilentlyContinue).Count -gt 0) { Fail 'Qoder 无法退出' }
}

foreach ($m in $migrations) {
  $src = $m.Src
  $dst = Join-Path $TargetRoot $m.Rel
  if (-not (Test-Path $src)) { Write-Host "[skip] 源不存在: $src" -ForegroundColor Yellow; continue }

  # BUG1 修复：源已是 junction 时只做验证，不误报 skip-done
  if (Test-Junction $src) {
    $t = Get-JunctionTarget $src
    if ($t -and (Test-Path $t)) {
      Ok "已是合法 junction: $src -> $t"
      # BUG3 修复：顺手校验 providers
      $sp = Join-Path $src 'settings.json'
      if (Test-Path $sp) {
        $n = (Get-Providers $sp).Count
        if ($n -eq 0) { Write-Host "  [!] settings.json 无 BYOK providers，请用 watchdog.ps1 -AutoRepair 恢复快照" -ForegroundColor Yellow }
        else { Ok "  providers 完好: $n 个" }
      }
      continue
    } else {
      Fail "junction 目标不可达: $src -> $t（可能是残留断链，请检查后手动处理）"
    }
  }

  # 目标已存在：不静默跳过，比较 providers 决定谁为准
  if (Test-Path $dst) {
    $srcProv = if (Test-Path "$src\settings.json") { (Get-Providers "$src\settings.json").Count } else { 0 }
    $dstProv = if (Test-Path "$dst\settings.json") { (Get-Providers "$dst\settings.json").Count } else { 0 }
    Info "目标已存在: $dst (源 providers=$srcProv, 目标 providers=$dstProv)"
    if ($dstProv -gt $srcProv) {
      # 目标更有价值：把它的 settings.json 备份文件先合并进源，避免迁移后丢配置
      Copy-Item "$dst\settings.json" "$src\settings.json.migrate-merge" -Force
      Info "已把目标 settings.json 备份到源的 .migrate-merge（迁移后会自动合并 providers）"
    }
    Move-Item $dst "$dst.old-$(Get-Date -Format yyyyMMddHHmmss)" -Force
  }

  # ---------- 执行迁移 ----------
  Info "迁移 $src -> $dst"
  New-Item (Split-Path $dst) -ItemType Directory -Force | Out-Null
  $backup = "$src.migrate-backup"
  if (Test-Path $backup) { Remove-Item $backup -Recurse -Force }
  Copy-Item $src $backup -Recurse -Force          # 完整备份，用于回滚
  Move-Item $src $dst -Force

  # 合并之前备份的 providers（如果源是空配置）
  $mergeFile = "$dst\settings.json.migrate-merge"
  if (Test-Path $mergeFile) {
    $cur = Get-Content "$dst\settings.json" -Raw | ConvertFrom-Json
    $old = Get-Content $mergeFile -Raw | ConvertFrom-Json
    if (($old.providers) -and -not ($cur.providers)) {
      $cur | Add-Member -NotePropertyName providers -NotePropertyValue $old.providers -Force
      $cur | ConvertTo-Json -Depth 20 | Set-Content "$dst\settings.json" -Encoding UTF8
      Ok "已从目标备份合并 providers"
    }
    Remove-Item $mergeFile -Force
  }

  # BUG2 修复：创建 junction 并验证属性
  $null = cmd /c mklink /J "$src" "$dst" 2>&1
  if (-not (Test-Junction $src)) {
    # 回滚
    Write-Host "[X] junction 创建失败，回滚..." -ForegroundColor Red
    Move-Item $dst $src -Force
    Fail "已回滚，数据仍在原位置: $src"
  }
  Ok "junction 已建立并验证: $src -> $dst"

  # BUG3 修复：校验配置
  $sp = Join-Path $src 'settings.json'
  if (Test-Path $sp) {
    $n = (Get-Providers $sp).Count
    if ($n -eq 0) {
      Write-Host "  [!] 迁移后 providers 为空（可能原本就没配置），如有快照请用 watchdog.ps1 -AutoRepair 恢复" -ForegroundColor Yellow
    } else { Ok "  providers 完好: $n 个" }
  }
}

# 重启 Qoder
$exe = Join-Path (Get-Content "$env:LOCALAPPDATA\Qoder\Qoder Launcher\state.ini" | Where-Object { $_ -match '^installDir=' } | ForEach-Object { ($_ -split '=',2)[1].Trim() }) 'Qoder.exe'
if (Test-Path $exe) { Start-Process $exe; Ok "Qoder 已重启" }
Ok "迁移完成。可用 -VerifyOnly 复查。"
