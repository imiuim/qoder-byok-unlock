#!/usr/bin/env python -I
"""把旧团队会话(source=discussion)批量转为普通 BYOK 会话(source=workspace)。
服务端在协作重构时已清除旧 discussion,旧团队会话被标记 CHAT_SESSION_TEAM_READ_ONLY(只读)。
转换后: 同一对话框、完整历史保留、发送走已验证可用的普通 BYOK 路径。
用法:
  python -I batch-convert.py --dry-run   # 只打印计划
  python -I batch-convert.py             # 执行(Qoder 会由 wrapper 启停, 此脚本假设 Qoder 已停)
"""
import sqlite3, os, json, sys, datetime, shutil

DBDIR = r'C:\Users\Administrator\AppData\Roaming\com.qoder.app.stable'
DB = os.path.join(DBDIR, 'main.sqlite')
DRY = '--dry-run' in sys.argv

con = sqlite3.connect(DB)
con.row_factory = sqlite3.Row
rows = con.execute("""select session_id, title, extra_json from chat_sessions
                      where deleted_at is null and extra_json like '%discussionTeamContext%'""").fetchall()
print(f'待转换团队会话: {len(rows)}')
plan = []
for r in rows:
    ex = json.loads(r['extra_json'])
    ctx = ex.get('discussionTeamContext') or {}
    plan.append((r['session_id'], (r['title'] or '')[:40], ctx.get('discussionTeamId'), ctx.get('teamProfileId')))
    if DRY:
        print(f"  [dry] {r['session_id'][:8]} | {(r['title'] or '')[:30]} | disc={str(ctx.get('discussionTeamId'))[:8]} team={str(ctx.get('teamProfileId'))[:8]}")

if DRY:
    con.close(); print('\n(dry-run 结束, 未写入)'); sys.exit(0)

bak = DB + '.before-batchconvert-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
shutil.copy2(DB, bak)
print('backup:', bak)

n_ok = 0
for r in rows:
    ex = json.loads(r['extra_json'])
    ex.pop('discussionTeamContext', None)
    ex.pop('discussionVisibility', None)
    ex.pop('historyRecoveryBackgroundAgents', None)
    ex['source'] = 'workspace'
    new_extra = json.dumps(ex, ensure_ascii=False, separators=(',', ':'))
    con.execute("update chat_sessions set extra_json=? where session_id=?", (new_extra, r['session_id']))
    n_ok += 1
con.commit()
# verify
left = con.execute("select count(*) from chat_sessions where deleted_at is null and extra_json like '%discussionTeamContext%'").fetchone()[0]
ws = con.execute("select count(*) from chat_sessions where deleted_at is null and extra_json like '%\"source\":\"workspace\"%'").fetchone()[0]
print(f'converted={n_ok} 残留团队上下文={left} 普通会话总数={ws}')
con.close()
