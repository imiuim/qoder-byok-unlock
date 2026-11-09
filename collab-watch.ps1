#Requires -Version 5.1
<#
.SYNOPSIS
  Qoder 协作服务恢复探针 - 检测官方何时修复 Discussion 服务
.DESCRIPTION
  定期通过 Qoder 渲染层(CDP)调用 discussions.list，检测协作服务是否恢复。
  判定恢复的标志：discussions.list 不再返回 COLLABORATION_BACKEND_UNAVAILABLE。
  恢复时：写日志 + Windows 通知 + 尝试重新注册 20 个队长 Agent。
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File collab-watch.ps1 -Once        # 查一次
  powershell -ExecutionPolicy Bypass -File collab-watch.ps1 -Loop         # 每30分钟查一次(常驻)
#>
param(
  [switch]$Once,
  [switch]$Loop,
  [int]$IntervalMin = 30
)
$ErrorActionPreference = 'Stop'
$Log = 'E:\QoderData\byok-watchdog\collab-watch.log'
function Log($m){ $line="{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$m; Write-Host $line; Add-Content $Log $line -Encoding UTF8 }

# 确保 Qoder 带 CDP 端口运行；没有就重启它
function Ensure-QoderCdp {
  $ok = $false
  try {
    $r = Invoke-RestMethod -Uri 'http://127.0.0.1:9222/json/version' -TimeoutSec 3
    $ok = $true
  } catch {
    Log '[..] Qoder 未带调试端口，重启...'
    Stop-Process -Name Qoder -Force -ErrorAction SilentlyContinue
    Start-Sleep 4
    Start-Process 'E:\Qoder\Qoder.exe' -ArgumentList '--remote-debugging-port=9222'
    Start-Sleep 15
    try { Invoke-RestMethod -Uri 'http://127.0.0.1:9222/json/version' -TimeoutSec 3 | Out-Null; $ok = $true } catch { $ok = $false }
  }
  return $ok
}

function Get-Target {
  $raw = Invoke-RestMethod -Uri 'http://127.0.0.1:9222/json' -TimeoutSec 5
  $t = $raw | Where-Object { $_.url -like '*workbenchScope=primary*' } | Select-Object -First 1
  if ($t) { return $t.id }
  if ($raw.Count -gt 0) { return $raw[0].id }
  return $null
}

function Invoke-Probe {
  param([string]$TargetId)
  # 用 node + CDP WebSocket 执行探针
  $script = Join-Path $env:TEMP 'collab-probe.cjs'
  $probeSource = @'
const http=require('http');
const targetId=process.argv[2];
// get target ws url
http.get({host:'127.0.0.1',port:9222,path:'/json'},res=>{
  let d='';res.on('data',c=>d+=c);res.on('end',()=>{
    const a=JSON.parse(d);
    const t=a.find(x=>x.webSocketDebuggerUrl&&x.url.includes('workbenchScope=primary'))||a.find(x=>x.webSocketDebuggerUrl);
    if(!t){console.log('NO_TARGET');process.exit(0)}
    const ws=new WebSocket(t.webSocketDebuggerUrl);
    let id=0;const pending=new Map();
    ws.addEventListener('message',e=>{const m=JSON.parse(e.data);if(m.id&&pending.has(m.id)){const p=pending.get(m.id);pending.delete(m.id);m.error?p.rej(new Error(m.error.message)):p.res(m.result)}});
    ws.addEventListener('open',async()=>{
      const expr=`(async()=>{const d=window.qoderDesktop||{};try{const r=await Promise.race([d.queryDiscussion({type:'discussions.list',status:'active'}),new Promise((_,re)=>setTimeout(()=>re(new Error('timeout')),10000))]);return JSON.stringify(r).slice(0,400)}catch(e){return 'ERR '+String(e).slice(0,150)}})()`;
      try{
        const r=await new Promise((res,rej)=>{const mid=++id;pending.set(mid,{res,rej});ws.send(JSON.stringify({id:mid,method:'Runtime.evaluate',params:{expression:expr,returnByValue:true,awaitPromise:true}}))});
        const v=r.result?.result;
        console.log('FULL:'+JSON.stringify(r.result));
      }catch(e){console.log('EVAL_ERR '+e.message)}
      ws.close();process.exit(0);
    });
    setTimeout(()=>{console.log('WS_TIMEOUT');process.exit(0)},45000);
  });
}).on('error',e=>{console.log('HTTP_ERR '+e.message);process.exit(0)});
'@
  [IO.File]::WriteAllText($script, $probeSource, (New-Object Text.UTF8Encoding($false)))
  $out = node $script $TargetId 2>$null
  return $out
}

function Test-Recovered($probeOut) {
  # 判定：探针返回中不再含 COLLABORATION_BACKEND_UNAVAILABLE 即视为恢复(该 code 为 ASCII，编码无关)
  if ($probeOut -match 'COLLABORATION_BACKEND_UNAVAILABLE') { return $false }
  if ($probeOut.Length -gt 40) { return $true }
  return $false
}

# ---------- 主流程 ----------
if ($Once) {
  if (-not (Ensure-QoderCdp)) { Log '[X] Qoder 无法启动(CDP)'; exit 1 }
  $t = Get-Target
  if (-not $t) { Log '[X] 无可用渲染目标'; exit 1 }
  $out = Invoke-Probe -TargetId $t
  Log "probe: $out"
  if (Test-Recovered $out) { Log '[OK] *** 协作服务已恢复！***' } else { Log '[..] 仍在重构中' }
  exit 0
}

if ($Loop) {
  Log "协作恢复探针启动 (interval=${IntervalMin}min)"
  while ($true) {
    try {
      if (Ensure-QoderCdp) {
        $t = Get-Target
        if ($t) {
          $out = Invoke-Probe -TargetId $t
          if (Test-Recovered $out) {
            Log '[OK] *** 协作服务已恢复！***'
            # Windows 通知
            try {
              [void][Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]
              $xml=[Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
              $xml.GetElementsByTagName('text').Item(0).AppendChild($xml.CreateTextNode('Qoder 协作服务已恢复')) | Out-Null
              $xml.GetElementsByTagName('text').Item(1).AppendChild($xml.CreateTextNode('旧团队会话可以继续了！重启 Qoder 并打开团队会话。')) | Out-Null
              $toast=[Windows.UI.Notifications.ToastNotification]::new($xml)
              [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Qoder.CollabWatch').Show($toast)
            } catch {}
            # 尝试重新注册队长 Agents
            try {
              $reg = Join-Path $PSScriptRoot 'register-agents2.js'
              if (Test-Path $reg) {
                Log '[..] 重新注册队长 Agents...'
                $t2 = Get-Target
                node $reg $t2 2>&1 | ForEach-Object { Log "  reg: $_" }
              }
            } catch {}
          } else {
            Log "[..] 仍在重构中 ($($out.Substring(0,[Math]::Min(60,$out.Length))))"
          }
        }
      }
    } catch { Log "[X] 探针异常: $($_.Exception.Message)" }
    Start-Sleep ($IntervalMin * 60)
  }
}
