const http = require('http');
const fs = require('fs');
function getTargets(){return new Promise((res,rej)=>{http.get({host:'127.0.0.1',port:9222,path:'/json'},r=>{let d='';r.on('data',c=>d+=c);r.on('end',()=>res(JSON.parse(d)))}).on('error',rej)})}
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
(async()=>{
  const targets = await getTargets();
  const t = targets.find(x=>x.url && x.url.includes('workbenchScope=primary')) || targets[0];
  const ws = new WebSocket(t.webSocketDebuggerUrl);
  let id=0; const pending=new Map();
  ws.addEventListener('message',e=>{const m=JSON.parse(e.data); if(m.id&&pending.has(m.id)){const p=pending.get(m.id);pending.delete(m.id); m.error?p.rej(new Error(m.error.message)):p.res(m.result)}});
  const send=(expr)=>new Promise((res,rej)=>{const mid=++id;pending.set(mid,{res,rej});ws.send(JSON.stringify({id:mid,method:'Runtime.evaluate',params:{expression:expr,returnByValue:true,awaitPromise:true}}))});
  async function call(obj,tries=10){
    const expr=`(async()=>{try{const v=await window.qoderDesktop.requestCollaboration(${JSON.stringify(obj)});return JSON.stringify(v)}catch(e){return 'ERR '+String(e&&e.message||e).slice(0,200)}})()`;
    for(let i=0;i<tries;i++){
      const r = await send(expr);
      const v = r.result?.result?.value;
      if(v && !String(v).startsWith('ERR')) return v;
      await sleep(1500);
    }
    return null;
  }
  ws.addEventListener('open',async()=>{
    // 1) 团队列表
    let v = await call({type:'team-profiles.list'});
    let teams=[]; try{teams=JSON.parse(v).data.data||[]}catch(e){console.log('team list fail:',v&&v.slice(0,200))}
    console.log('团队列表:');
    for(const tm of teams) console.log(' ',tm.id, tm.name, 'cfg='+tm.configurationVersion, 'leader='+tm.leaderAgentProfileId);
    // 2) 旧会话所属团队
    const TEAM='98b4704b-e233-843a-80f9-af5f17d8a8d5';
    const target = teams.find(x=>x.id===TEAM) || teams[0];
    console.log('\n选用团队:', target.id, target.name, 'cfg', target.configurationVersion);
    // 3) 创建 discussion
    v = await call({type:'discussions.create', input:{title:'项目最后一步', description:'续接旧会话"项目最后一步"（服务端旧 discussion 已被清除，本地重绑）'}});
    console.log('\ncreate 结果:', v);
    let disc=null; try{disc=JSON.parse(v).data}catch(e){}
    if(!disc){console.log('创建失败');ws.close();process.exit(1)}
    console.log('新 discussionId:', disc.id);
    // 4) add-team
    v = await call({type:'discussion-members.add-team', discussionId:disc.id, input:{kind:'team', teamProfileId:target.id, configurationVersion:target.configurationVersion}});
    console.log('\nadd-team:', v);
    let added=null; try{added=JSON.parse(v).data}catch(e){}
    if(added && added.localPreparationFailures && added.localPreparationFailures.length){
      console.log('本地准备失败:', JSON.stringify(added.localPreparationFailures));
      // 5) 对失败 agent 逐个 prepare
      for(const f of added.localPreparationFailures){
        const pv = await call({type:'agent-profile.prepare', localProfileId:f.agentProfileId});
        console.log('prepare', f.agentProfileId.slice(0,8), '->', (pv||'').slice(0,200));
      }
    }
    // 6) 成员列表
    v = await call({type:'discussion-members.list', discussionId:disc.id});
    console.log('\nmembers:', (v||'').slice(0,900));
    // 保存结果供后续 DB 重绑
    fs.writeFileSync('new-disc.json', JSON.stringify({discussionId:disc.id, teamProfileId:target.id, configurationVersion:target.configurationVersion, teamName:target.name},null,1));
    console.log('\n保存 new-disc.json');
    ws.close();process.exit(0);
  });
  setTimeout(()=>{console.log('WS_TIMEOUT');process.exit(0)},240000);
})();
