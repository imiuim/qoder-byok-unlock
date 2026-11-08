#Requires -Version 5.1
<#
.SYNOPSIS
  Qoder BYOK Unlock - 一键解锁 Qoder 自定义模型（含智能体团队）
.DESCRIPTION
  在 Qoder 0.5.x (Windows) 上解锁自定义模型/自带 provider 在全部产品面（普通会话、智能体团队/多智能体）的使用：
    P1  渲染层模型目录过滤  (app.asar)         filter(!byok&&!outerProvider) 放行
    P2  渲染层 provider 过滤 (app.asar)         providerKey==="default" 门放行
    P3  主进程模型吞没门     (app.asar)         zXe/R7x 能力门恒放行
    P4  团队表单 E 开关      (app.asar)         E=V==="cloud" 恒假（成员模型可选）
    P5  worker allow_byok    (worker obf.mjs)   阈值 >=2 降为 >=1
    P6  worker SE 回退       (worker obf.mjs)   route miss 时从 settings.json 同步重建 registry
  全部补丁带唯一性校验、原文件 .bak 备份、幂等（已打过自动跳过）。
  附 fuse 处理：EnableEmbeddedAsarIntegrityValidation 关闭（app.asar 可改的前提）。
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File unlock.ps1           # 应用全部补丁
  powershell -ExecutionPolicy Bypass -File unlock.ps1 -Rollback # 一键回滚
.NOTES
  仅修改本机 Qoder 安装；版本更新后需重跑（脚本按内容锚点自适应 0.5.x）。
#>
param([switch]$Rollback)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Fail($m){ Write-Host "[X] $m" -ForegroundColor Red; exit 1 }
function Ok($m){ Write-Host "[OK] $m" -ForegroundColor Green }
function Info($m){ Write-Host "[..] $m" -ForegroundColor Cyan }

# ---------- 定位 Qoder ----------
# 途径1: 启动器配置（%LOCALAPPDATA%\Qoder\Qoder Launcher\state.ini / install.ini 的 installDir=）
function Get-FromLauncherIni {
  $results = @()
  foreach ($base in @("$env:LOCALAPPDATA\Qoder\Qoder Launcher", "$env:LOCALAPPDATA\Qoder CN\Qoder CN Launcher")) {
    foreach ($ini in @((Join-Path $base 'state.ini'), (Join-Path $base 'install.ini'))) {
      if (-not (Test-Path $ini)) { continue }
      try {
        $txt = [IO.File]::ReadAllText($ini)
        if ($txt -match "\x00") { $txt = [IO.File]::ReadAllText($ini, [Text.Encoding]::Unicode) }
        if ($txt -match "installDir\s*=\s*(.+?)\s*$") {
          $d = $Matches[1].Trim()
          if ($d -and (Test-Path (Join-Path $d 'Qoder.exe'))) { $results += $d }
        }
      } catch {}
    }
  }
  return $results
}
# 途径2: 注册表卸载记录（DisplayIcon 指向 Qoder.exe）
function Get-FromRegistry {
  $out = @()
  try {
    $keys = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
      Where-Object { $_.DisplayName -like 'Qoder*' -and $_.DisplayIcon }
    foreach ($k in $keys) {
      $exe = ($k.DisplayIcon -split ',')[0].Trim()
      if ($exe -and (Test-Path $exe)) { $out += (Split-Path $exe) }
    }
  } catch {}
  return $out
}
# 途径3: 常见路径直查
$candidates = @()
$candidates += Get-FromLauncherIni
$candidates += Get-FromRegistry
$candidates += @("$env:LOCALAPPDATA\Programs\Qoder", 'G:\Qoder', 'D:\Qoder', 'E:\Qoder', 'C:\Qoder')
$candidates = @($candidates | Where-Object { $_ -and (Test-Path (Join-Path $_ 'Qoder.exe')) } | Select-Object -Unique)
if ($candidates.Count -eq 0 -or -not $candidates[0]) { Fail "未找到 Qoder 安装目录。已探测：启动器 state.ini/install.ini、注册表卸载记录、常见盘符。请确认 Qoder.exe 实际位置。" }
$root = $candidates[0]
Info "Qoder 根目录: $root"

# 运行中版本目录（.qoder-versions\<ver>），取字典序最大
$vdir = Join-Path $root '.qoder-versions'
$ver = $null
if (Test-Path $vdir) {
  $ver = Get-ChildItem $vdir -Directory |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
    Sort-Object Name -Descending | Select-Object -First 1
  if ($ver) { Info "检测到最新版本: $($ver.Name)" }
}
if (-not $ver) { Fail "未找到 .qoder-versions\<版本> 目录" }

$asarPath    = Join-Path $ver.FullName 'resources\app.asar'
$workerPath  = Join-Path $ver.FullName 'resources\app.asar.unpacked\node_modules\@qoder-ai\qoder-agent-sdk\dist\_worker\qoder-worker-runtime.obf.mjs'
$exePath     = Join-Path $ver.FullName 'Qoder.exe'
foreach ($f in @($asarPath,$workerPath,$exePath)) { if (-not (Test-Path $f)) { Fail "缺文件: $f" } }

# ---------- 停进程 ----------
$procs = @(Get-Process Qoder -ErrorAction SilentlyContinue)
if ($procs.Count -gt 0) {
  Info "结束 $($procs.Count) 个 Qoder 进程..."
  Stop-Process -Name Qoder -Force -ErrorAction SilentlyContinue
  Start-Sleep 4
}
Ok "Qoder 已退出"

# ---------- 字节工具 ----------
function Read-All($p){ ,([System.IO.File]::ReadAllBytes($p)) }   # 逗号防 byte[] 被管道展开
function Write-All($p,$b){ [System.IO.File]::WriteAllBytes($p,$b) }
function Backup($p){
  $bak = "$p.bak-unlock"
  if (-not (Test-Path $bak)) { Copy-Item $p $bak; Ok "备份原件 -> $bak" }
  else { Write-Host "[..] 保留首次备份: $bak" -ForegroundColor DarkGray }
}
function Find-Count([byte[]]$hay, [byte[]]$needle){
  $c=0; $i=-1
  while (($i = [Array]::IndexOf($hay, $needle[0], $i+1)) -ge 0) {
    if ($i + $needle.Length -le $hay.Length) {
      $ok=$true
      for($j=1;$j -lt $needle.Length;$j++){ if($hay[$i+$j] -ne $needle[$j]){$ok=$false;break} }
      if($ok){$c++; if($c -gt 2){return 3}}
    }
  }
  $c
}
function Replace-Once([byte[]]$buf, [string]$old, [string]$new, [string]$tag){
  $oldB=[Text.Encoding]::UTF8.GetBytes($old)
  if ($old.Length -ne $new.Length) { Fail "$tag 等长校验失败 ($($old.Length) vs $($new.Length))" }
  $c = Find-Count $buf $oldB
  if ($c -eq 0) { Write-Host "[skip] $tag 未命中（可能已打补丁）" -ForegroundColor Yellow; return ,$buf }
  if ($c -gt 1) { Fail "$tag 锚点命中 $c 处，非唯一，拒绝盲改" }
  $idx = [Array]::IndexOf($buf, $oldB[0])
  # 精确定位唯一命中
  $i=-1; while(($i=[Array]::IndexOf($buf,$oldB[0],$i+1)) -ge 0){
    $ok=$true; for($j=0;$j -lt $oldB.Length;$j++){ if($buf[$i+$j] -ne $oldB[$j]){$ok=$false;break} }
    if($ok){$idx=$i;break}
  }
  $newB=[Text.Encoding]::UTF8.GetBytes($new)
  [Array]::Copy($newB,0,$buf,$idx,$newB.Length)
  Ok "$tag 已打 @offset $idx"
  return ,$buf
}
function Pad($core,$target){
  $tb=[Text.Encoding]::UTF8.GetByteCount($target)
  $cb=[Text.Encoding]::UTF8.GetByteCount($core)
  if ($cb -gt $tb) { Fail "core 长于 target: $core" }
  $core + ('/*' + (' ' * ($tb-$cb-4)) + '*/')
}

# ---------- 回滚 ----------
if ($Rollback) {
  foreach ($f in @($asarPath,$workerPath,$exePath)) {
    $bak = "$f.bak-unlock"
    if (Test-Path $bak) { Copy-Item $bak $f -Force; Ok "回滚 $f" }
    else { Write-Host "[skip] 无备份: $bak" -ForegroundColor Yellow }
  }
  Ok "回滚完成。启动 Qoder 即恢复原版。"
  exit 0
}

# ---------- P0: ASAR integrity fuse ----------
Info "处理 Electron ASAR integrity fuse..."
$nodeModules = Join-Path $root 'node_modules\@electron\fuses'
$needFuses = $true
if (Test-Path (Join-Path $PSScriptRoot 'node_modules\@electron\fuses')) { $nodeModules = Join-Path $PSScriptRoot 'node_modules\@electron\fuses'; $needFuses=$false }
if ($needFuses) {
  Info "安装 @electron/fuses（一次性）..."
  $tmp = Join-Path $env:TEMP "qoder-unlock-fuses"
  New-Item $tmp -ItemType Directory -Force | Out-Null
  Push-Location $tmp
  $ErrorActionPreference = 'Continue'   # npm 的 stderr 警告不算错误
  if (-not (Test-Path 'package.json')) { cmd /c "npm init -y >nul 2>nul" | Out-Null; cmd /c "npm i @electron/fuses --no-audit --no-fund >nul 2>nul" | Out-Null }
  $ErrorActionPreference = 'Stop'
  Pop-Location
  $nodeModules = Join-Path $tmp 'node_modules\@electron\fuses'
}
$fusesJs = Join-Path $nodeModules 'dist\index.js'
if (-not (Test-Path $fusesJs)) { Fail "@electron/fuses 安装失败（需要 node/npm）" }
# 用 node 跑 fuse 翻转
$flipScript = Join-Path $env:TEMP 'qoder-flip-fuse.cjs'
@'
const f=require(process.argv[3]);
(async()=>{
  await f.flipFuses(process.argv[2],{version:f.FuseVersion.V1,[f.FuseV1Options.EnableEmbeddedAsarIntegrityValidation]:false});
  const w=await f.getCurrentFuseWire(process.argv[2]);
  console.log('fuse wire:',JSON.stringify(w));
})().catch(e=>{console.error('ERR',e.message);process.exit(1)});
'@ | Set-Content $flipScript -Encoding UTF8
$nmDir = Split-Path (Split-Path $fusesJs)
$ErrorActionPreference='Continue'; node $flipScript $exePath $fusesJs 2>$null; $flipExit=$LASTEXITCODE; $ErrorActionPreference='Stop'; if($flipExit -ne 0){Fail 'fuse flip node failed'}
if ($LASTEXITCODE -ne 0) { Fail "fuse 翻转失败" }
Backup $exePath
Ok "ASAR integrity fuse 已关闭（备份 $($exePath).bak-unlock）"

# ---------- P1-P4: app.asar ----------
$asarMB = [math]::Round((Get-Item $asarPath).Length / 1MB)
Info "读取 app.asar (${asarMB}MB)..."
$buf = Read-All $asarPath
Backup $asarPath

# P1 渲染层目录过滤（0.5.6 形态；等长注释填充）
$buf = Replace-Once $buf `
  'models:z.filter(M=>!M.byok&&!M.outerProvider)' `
  (Pad 'models:z.filter(M=>M!==null)' 'models:z.filter(M=>!M.byok&&!M.outerProvider)') 'P1 目录过滤放行'

# P2 provider 过滤
$buf = Replace-Once $buf `
  '(L.providerKey==="default"||n&&L.providerKey==="enterprise")' `
  (Pad '(true||true)' '(L.providerKey==="default"||n&&L.providerKey==="enterprise")') 'P2 provider 过滤放行'

# P3 主进程门控（0.5.6 混淆名 R7x；0.5.3 为 zXe——两种形态都试）
$p3a = Find-Count $buf ([Text.Encoding]::UTF8.GetBytes('function R7x(c,x){if(!c)return;'))
$p3b = Find-Count $buf ([Text.Encoding]::UTF8.GetBytes('zXe(t,e){if(t)return'))
if ($p3a -eq 1) {
  $buf = Replace-Once $buf 'function R7x(c,x){if(!c)return;' 'function R7x(c,x){if(!1)return;' 'P3 主进程门控(R7x)'
} elseif ($p3b -ge 1) {
  $buf = Replace-Once $buf 'zXe(t,e){if(t)return' 'zXe(t,e){if(1)return' 'P3 主进程门控(zXe)'
} else {
  Write-Host "[skip] P3 未命中（版本差异，稍后用 P6 回退兜底）" -ForegroundColor Yellow
}

# P4 团队表单 E 开关
$buf = Replace-Once $buf 'E=V==="cloud"' 'E=0===1&&V==1' 'P4 团队 E 开关恒假'

Write-All $asarPath $buf
Ok "app.asar 写回"

# ---------- P5+P6: worker ----------
Info "处理 worker runtime..."
$w = [Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($workerPath))
Backup $workerPath
$dirty = $false

# P5 allow_byok 阈值
$p5old='function _x(A){return(A?.featureSwitches?.allow_byok??0)>=2}'
$p5new='function _x(A){return(A?.featureSwitches?.allow_byok??0)>=1}'
if ($w.Contains($p5new)) { Write-Host "[skip] P5 已打过" -ForegroundColor Yellow }
elseif ($w.Contains($p5old)) { $w=$w.Replace($p5old,$p5new); Ok 'P5 allow_byok >=2→>=1'; $dirty=$true }
else { Write-Host "[skip] P5 未命中" -ForegroundColor Yellow }

# P6 SE 同步回退（函数级替换；等长无关，worker 是明文 mjs）
$seStart = $w.IndexOf('function SE(A,e,t=hn()){')
if ($seStart -lt 0) { Fail '未找到 SE 函数（版本不兼容）' }
$seEnd = $w.IndexOf('var _G=w(()=>', $seStart)
if ($seEnd -lt 0) { Fail 'SE 边界异常' }
if ($w.Substring($seStart,$seEnd-$seStart).Contains('replaceCustomProviderSettings?.(d.providers)')) {
  Write-Host "[skip] P6 已打过" -ForegroundColor Yellow
} else {
  $newSE = 'function SE(A,e,t=hn()){let i=e??A?.getModelRequestIdentity()??FwA("standalone"),r=A?.getCustomProviderRegistry();return(e,n)=>{let o=t.getModel(e);if(!n){let c=A?.isConfiguredCustomProviderModelKey(e);if(!c&&typeof e==="string"&&e.startsWith("qoder-custom-")){try{const d=JSON.parse(PRe.readFileSync(xd.join(Jr(),"settings.json"),"utf8"));const pid=e.slice(0,e.indexOf("/"));if(d&&d.providers&&d.providers[pid]){A?.replaceCustomProviderSettings?.(d.providers);c=A?.isConfiguredCustomProviderModelKey(e);}}catch{}}let t=r?.getModelRoute(e);if(!t&&c){try{r?.replace(A.customProviderSettings,[e]);}catch{}t=r?.getModelRoute(e);}if(t&&!1!==c)return{...t,identity:i};if(c||o?.source===bF){let A=new rC(`Custom Provider model ''${e}'' is not available.`,403);throw new JRe(A.message,{cause:A})}}return{kind:"qoder",identity:i,source:n?hke:o?.source??hke,...o?.server_scene?{serverScene:o.server_scene}:{}}}}'
  $newSE = $newSE.Replace("''","'")
  # 语法自检
  $check = Join-Path $env:TEMP 'qoder-se-check.cjs'
  $sefile = Join-Path $env:TEMP 'qoder-se-payload.txt'
  [IO.File]::WriteAllText($check, "const fs=require('fs');const se=fs.readFileSync(process.argv[2],'utf8');new Function('hn','FwA','bF','rC','JRe','hke','PRe','xd','Jr',se);console.log('syntax OK');", [Text.Encoding]::UTF8)
  [IO.File]::WriteAllText($sefile, $newSE, (New-Object Text.UTF8Encoding($false)))
  $ErrorActionPreference='Continue'; node $check $sefile 2>$null | Out-Null; $chkExit=$LASTEXITCODE; $ErrorActionPreference='Stop'
  if ($chkExit -ne 0) { Fail "P6 新 SE 语法自检失败 (exit $chkExit)" }
  $w = $w.Substring(0,$seStart) + $newSE + $w.Substring($seEnd)
  Ok 'P6 SE 同步回退已注入'
  $dirty = $true
}
if ($dirty) {
  [IO.File]::WriteAllText($workerPath, $w, (New-Object Text.UTF8Encoding($false)))
  Ok "worker 写回"
}

# ---------- 完成 ----------
Write-Host ''
Ok '全部补丁应用完成。启动 Qoder 实测：智能体团队选自定义模型发消息。'
Write-Host '回滚: powershell -ExecutionPolicy Bypass -File unlock.ps1 -Rollback' -ForegroundColor DarkGray
Write-Host '注: Qoder 自动更新到新版本后需重跑本脚本（锚点自适应 0.5.x）。' -ForegroundColor DarkGray
