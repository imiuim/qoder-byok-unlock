#Requires -Version 5.1
<#
.SYNOPSIS
  Qoder BYOK 解锁补丁 —— 支持 0.5.6 旧布局(.qoder-versions) 与 0.5.7+ 新布局(根目录 resources)
.DESCRIPTION
  0.5.7 起 Qoder 更新后把 app.asar 直接放在 <root>\resources\，不再使用 .qoder-versions\<ver>\，
  且部分混淆名变化(SE->DE, hn->En, zXe/R7x 门控消失)。本脚本自动识别布局与版本锚点。
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File unlock-v2.ps1
#>
param([switch]$Rollback)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
function Fail($m){ Write-Host "[X] $m" -ForegroundColor Red; exit 1 }
function Ok($m){ Write-Host "[OK] $m" -ForegroundColor Green }
function Info($m){ Write-Host "[..] $m" -ForegroundColor Cyan }
function Warn($m){ Write-Host "[!] $m" -ForegroundColor Yellow }
$script:missed = @()

# ---------- 定位 Qoder ----------
$ini = "$env:LOCALAPPDATA\Qoder\Qoder Launcher\state.ini"
$root = $null
if (Test-Path $ini) {
  $txt = [IO.File]::ReadAllText($ini)
  if ($txt -match "\x00") { $txt = [IO.File]::ReadAllText($ini,[Text.Encoding]::Unicode) }
  foreach ($line in ($txt -split "\r?\n")) {
    if ($line -match '^\s*installDir\s*=\s*(.+?)\s*$') { $root = $Matches[1].Trim(); break }
  }
}
if (-not $root) {
  foreach ($d in @((Get-PSDrive -PSProvider FileSystem).Root)) {
    if (Test-Path (Join-Path (Join-Path $d 'Qoder') 'Qoder.exe')) { $root = Join-Path $d 'Qoder'; break }
  }
}
if (-not $root -or -not (Test-Path (Join-Path $root 'Qoder.exe'))) { Fail '未找到 Qoder 安装目录' }
Info "Qoder 根目录: $root"

# ---------- 布局判定 ----------
$rootAsar = Join-Path $root 'resources\app.asar'
$rootWorker = Join-Path $root 'resources\app.asar.unpacked\node_modules\@qoder-ai\qoder-agent-sdk\dist\_worker\qoder-worker-runtime.obf.mjs'
if (Test-Path $rootAsar) {
  $asarPath = $rootAsar; $workerPath = $rootWorker; $exePath = Join-Path $root 'Qoder.exe'
  $layout = 'root(0.5.7+)'
} else {
  $vdir = Join-Path $root '.qoder-versions'
  $ver = Get-ChildItem $vdir -Directory | Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
  if (-not $ver) { Fail '找不到 app.asar' }
  $asarPath = Join-Path $ver.FullName 'resources\app.asar'
  $workerPath = Join-Path $ver.FullName 'resources\app.asar.unpacked\node_modules\@qoder-ai\qoder-agent-sdk\dist\_worker\qoder-worker-runtime.obf.mjs'
  $exePath = Join-Path $ver.FullName 'Qoder.exe'
  $layout = "versions($($ver.Name))"
}
Info "布局: $layout"
foreach ($f in @($asarPath,$workerPath,$exePath)) { if (-not (Test-Path $f)) { Fail "缺文件: $f" } }

# ---------- 停进程 ----------
$procs = @(Get-Process Qoder -ErrorAction SilentlyContinue)
if ($procs.Count -gt 0) {
  Info "结束 $($procs.Count) 个 Qoder 进程..."
  Stop-Process -Name Qoder -Force -ErrorAction SilentlyContinue
  $w=0; while($w -lt 15){ Start-Sleep 1; $w++; if(@(Get-Process Qoder -ErrorAction SilentlyContinue).Count -eq 0){break} }
  if(@(Get-Process Qoder -ErrorAction SilentlyContinue).Count -gt 0){ Fail 'Qoder 未能退出' }
}
Ok "Qoder 已退出"

function Backup($p){
  $bak="$p.bak-unlock"
  if(-not (Test-Path $bak)){ Copy-Item $p $bak; Ok "备份 $bak" } else { Info "保留首次备份 $bak" }
}
function Find-Count([byte[]]$hay,[byte[]]$needle){
  $c=0;$i=-1
  while(($i=[Array]::IndexOf($hay,$needle[0],$i+1)) -ge 0){
    if($i+$needle.Length -le $hay.Length){$ok=$true;for($j=1;$j -lt $needle.Length;$j++){if($hay[$i+$j] -ne $needle[$j]){$ok=$false;break}};if($ok){$c++;if($c -gt 2){return 3}}}
  }
  $c
}
function Replace-Once([byte[]]$buf,[string]$old,[string]$new,[string]$tag,[string]$already){
  if($already){ $aB=[Text.Encoding]::UTF8.GetBytes($already); if((Find-Count $buf $aB) -ge 1){ Info "$tag 已打过"; return ,$buf } }
  $oldB=[Text.Encoding]::UTF8.GetBytes($old)
  if($old.Length -ne $new.Length){ Fail "$tag 等长失败" }
  $c=Find-Count $buf $oldB
  if($c -eq 0){ Warn "$tag 未命中"; $script:missed += $tag; return ,$buf }
  if($c -gt 1){ Fail "$tag 锚点不唯一($c)" }
  $idx=-1;$i=-1
  while(($i=[Array]::IndexOf($buf,$oldB[0],$i+1)) -ge 0){
    $ok=$true;for($j=0;$j -lt $oldB.Length;$j++){if($buf[$i+$j] -ne $oldB[$j]){$ok=$false;break}}
    if($ok){$idx=$i;break}
  }
  $newB=[Text.Encoding]::UTF8.GetBytes($new)
  [Array]::Copy($newB,0,$buf,$idx,$newB.Length)
  Ok "$tag 已打 @$idx"
  return ,$buf
}
function Pad($core,$target){
  $tb=[Text.Encoding]::UTF8.GetByteCount($target);$cb=[Text.Encoding]::UTF8.GetByteCount($core)
  if($tb-$cb -lt 4){ Fail '填充空间不足' }
  $core + ('/*' + (' ' * ($tb-$cb-4)) + '*/')
}

# ---------- 回滚 ----------
if($Rollback){
  foreach($f in @($asarPath,$workerPath,$exePath)){
    $bak="$f.bak-unlock"
    if(Test-Path $bak){ Copy-Item $bak $f -Force; Ok "回滚 $f" } else { Warn "无备份 $bak" }
  }
  exit 0
}

# ---------- P0 fuse ----------
Info '处理 ASAR integrity fuse...'
$mods = Join-Path $env:TEMP 'qoder-unlock-fuses\node_modules\@electron\fuses'
if(-not (Test-Path (Join-Path $mods 'dist\index.js'))){
  $tmp=Join-Path $env:TEMP 'qoder-unlock-fuses'
  New-Item $tmp -ItemType Directory -Force | Out-Null
  Push-Location $tmp
  if(-not (Test-Path 'package.json')){ cmd /c "npm init -y >nul 2>nul" | Out-Null; cmd /c "npm i @electron/fuses@1.3.0 --no-audit --no-fund --save-exact >nul 2>nul" | Out-Null }
  Pop-Location
}
$fusesJs=Join-Path $mods 'dist\index.js'
if(-not (Test-Path $fusesJs)){ Fail '@electron/fuses 不可用' }
Backup $exePath
$flip=Join-Path $env:TEMP 'qoder-flip-v2.cjs'
@'
// 不依赖 FuseV1Options 枚举(某些 @electron/fuses 版本只导出 2 项，导致
// EnableEmbeddedAsarIntegrityValidation===undefined，flipFuses 什么也不做)。
// 直接按 wire 布局把 index 4 置为 48('0'=disabled)。
const fs=require('fs');const path=require('path');
const f=require(process.argv[3]);
const {SENTINEL}=require(path.join(path.dirname(process.argv[3]),'constants.js'));
const exe=process.argv[2];
const b=fs.readFileSync(exe);
const pos=b.indexOf(Buffer.from(SENTINEL));
if(pos<0)throw new Error('fuse sentinel not found');
const wp=pos+Buffer.byteLength(SENTINEL);
const version=b[wp],len=b[wp+1];
if(String(version)!==String(f.FuseVersion.V1))throw new Error('fuse wire version mismatch: '+version);
if(len<=4)throw new Error('fuse wire too short: '+len);
b[wp+2+4]=48;
fs.writeFileSync(exe,b);
console.log('fuse wire:',JSON.stringify(Array.from(b.slice(wp+2,wp+2+len))));
'@ | Set-Content $flip -Encoding UTF8
node $flip $exePath $fusesJs 2>$null
if($LASTEXITCODE -ne 0){ Fail 'fuse 翻转失败' }
# 二次校验：确认 index 4 真的关了，否则改了 asar 应用会拒绝启动
$verify = Join-Path $env:TEMP 'qoder-fuse-verify.cjs'
$verifySource = @'
const fs=require('fs');const path=require('path');
const {SENTINEL}=require(path.join(path.dirname(process.argv[3]),'constants.js'));
const b=fs.readFileSync(process.argv[1]);
const wp=b.indexOf(Buffer.from(SENTINEL))+Buffer.byteLength(SENTINEL);
if(b[wp+2+4]!==48){console.error('fuse still ENABLED');process.exit(1)}
console.log('fuse OFF verified');
'@
[IO.File]::WriteAllText($verify, $verifySource, (New-Object Text.UTF8Encoding($false)))
node $verify $exePath $fusesJs 2>$null
if($LASTEXITCODE -ne 0){ Fail 'fuse 关闭校验失败（不要改 asar，应用会无法启动）' }
Ok 'fuse 已关闭并校验'

# ---------- P1-P4 asar ----------
Info "读取 app.asar ($([math]::Round((Get-Item $asarPath).Length/1MB))MB)..."
$buf = [IO.File]::ReadAllBytes($asarPath)
Backup $asarPath
$buf = Replace-Once $buf 'models:z.filter(M=>!M.byok&&!M.outerProvider)' (Pad 'models:z.filter(M=>M!==null)' 'models:z.filter(M=>!M.byok&&!M.outerProvider)') 'P1' 'models:z.filter(M=>M!==null)/*'
$buf = Replace-Once $buf '(L.providerKey==="default"||n&&L.providerKey==="enterprise")' (Pad '(true||true)' '(L.providerKey==="default"||n&&L.providerKey==="enterprise")') 'P2' '(true||true)/*'
# P3: 0.5.7 已移除 R7x/zXe 门控，跳过不算失败
$p3a=Find-Count $buf ([Text.Encoding]::UTF8.GetBytes('function R7x(c,x){if(!c)return;'))
$p3b=Find-Count $buf ([Text.Encoding]::UTF8.GetBytes('zXe(t,e){if(t)return'))
if($p3a -eq 1){ $buf=Replace-Once $buf 'function R7x(c,x){if(!c)return;' 'function R7x(c,x){if(!1)return;' 'P3(R7x)' }
elseif($p3b -ge 1){ $buf=Replace-Once $buf 'zXe(t,e){if(t)return' 'zXe(t,e){if(1)return' 'P3(zXe)' }
else { Info 'P3 门控在新版本已移除，无需补丁' }
$buf = Replace-Once $buf 'E=V==="cloud"' 'E=0===1&&V==1' 'P4' 'E=0===1&&V==1'
# P7 协作探针守卫(0.5.7+): z$0 的 x!==null 守卫导致探针异常时协作永关。
# 等长反转条件(34→34字符): 探针失败/无占用 → 默认全开。
$buf = Replace-Once $buf 'if(x!==null||e===void 0)return Mw;' 'if(x===null&&e===void 0)return Mw;' 'P7 协作探针守卫' 'if(x===null&&e===void 0)return Mw;'
$tmpAsar="$asarPath.tmp-unlock"
[IO.File]::WriteAllBytes($tmpAsar,$buf)
Remove-Item $asarPath -Force
Move-Item $tmpAsar $asarPath -Force
Ok 'app.asar 写回'

# ---------- P5+P6 worker ----------
Info '处理 worker...'
$w=[IO.File]::ReadAllText($workerPath)
Backup $workerPath
$dirty=$false

# P5: 0.5.7 同时有 iy(>=1) 和 _x(>=2)，把 _x 降到 >=1
$p5old='function _x(A){return(A?.featureSwitches?.allow_byok??0)>=2}'
$p5new='function _x(A){return(A?.featureSwitches?.allow_byok??0)>=1}'
if($w.Contains($p5new)){ Info 'P5 已打过' }
elseif($w.Contains($p5old)){ $w=$w.Replace($p5old,$p5new); Ok 'P5 >=2→>=1'; $dirty=$true }
else { Warn 'P5 未命中'; $script:missed += 'P5' }

# P6: 版本自适应函数名(0.5.6 SE/hn; 0.5.7 DE/En)
# 策略：保留当前版本原函数结构，仅在 getModelRoute 后注入"从 settings.json 重建 registry"的回退
$sigFound=$null;$fnLabel=$null
foreach($pair in @(@('SE','hn'),@('DE','En'))){
  $sig="function $($pair[0])(A,e,t=$($pair[1])()){"
  if($w.IndexOf($sig) -ge 0){ $sigFound=$sig; $fnLabel="$($pair[0])/$($pair[1])"; break }
}
if(-not $sigFound){ Fail '找不到模型路由函数(SE/DE)' }
$seStart=$w.IndexOf($sigFound)
$seEnd=$w.IndexOf('var _G=w(()=>',$seStart)
if($seEnd -lt 0){ Fail '路由函数边界异常' }
$span=$w.Substring($seStart,$seEnd-$seStart)
if($span.Contains('qoder-custom-')){ Info 'P6 已打过' }
else {
  $routeAnchor='let t=r?.getModelRoute(e);'
  if(-not $span.Contains($routeAnchor)){ Fail 'P6 找不到 getModelRoute 锚点' }
  # 单引号 here-string：不展开 ${} / $变量，避开 PowerShell 插值
  $inject = @'
let t=r?.getModelRoute(e);if(!t&&typeof e==="string"&&e.startsWith("qoder-custom-")){try{const d=JSON.parse(process.getBuiltinModule("fs").readFileSync(process.env.USERPROFILE+"/.qoder/settings.json","utf8"));if(d&&d.providers)A?.replaceCustomProviderSettings?.(d.providers);}catch{}t=r?.getModelRoute(e);}
'@
  $newSpan = $span.Replace($routeAnchor, $inject.Trim())
  $candidate = $w.Substring(0,$seStart) + $newSpan + $w.Substring($seEnd)
  # 对整个 worker 做语法校验(比 new Function 更严格，能发现真实语法/作用域问题)
  $chkFile = Join-Path $env:TEMP 'qoder-worker-v2-check.mjs'
  [IO.File]::WriteAllText($chkFile, $candidate, (New-Object Text.UTF8Encoding($false)))
  node --check $chkFile 2>&1 | Out-Null
  if($LASTEXITCODE -ne 0){ Fail 'P6 注入后 worker 语法校验失败，未写入' }
  Remove-Item $chkFile -Force
  $w = $candidate
  Ok "P6 已注入($fnLabel)"
  $dirty=$true
}
if($dirty){
  $tmpW="$workerPath.tmp-unlock"
  [IO.File]::WriteAllText($tmpW,$w,(New-Object Text.UTF8Encoding($false)))
  Remove-Item $workerPath -Force
  Move-Item $tmpW $workerPath -Force
  Ok 'worker 写回'
}

Write-Host ''
if($script:missed.Count -gt 0){ Fail "未命中: $($script:missed -join ', ')" }
Ok '全部补丁完成。重启 Qoder 生效。'
