// ============================================================
//  PC 桥 —— 手机上遥控电脑里跑的 AI CLI（Codex / Claude Code / …）
// ============================================================
//
//  场景：人在外面，手机装了控制台 App，想在自己电脑上开一个 Codex 干活，
//        还能实时看到输出、继续追问、收文件。
//
//  链路：
//    手机 → 云端（下指令 / 看输出） ← 电脑上的 pc_agent.py（跑 CLI，回传输出）
//
//  电脑那条是「拨出去」的（长轮询），所以不需要公网 IP、不用开端口、
//  不用内网穿透 —— 跟云手机被控端一个思路。
//
//  会话状态机：
//    pending  → 手机发起，等电脑来领
//    running  → 电脑已领，正在跑
//    done     → 这一轮跑完（还能继续追问）
//    error    → 跑挂了
// ============================================================

export const PC_SESSION_DDL = `
CREATE TABLE IF NOT EXISTS pc_session (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL DEFAULT '',
  cli        TEXT NOT NULL DEFAULT 'auto',
  cwd        TEXT NOT NULL DEFAULT '',
  status     TEXT NOT NULL DEFAULT 'pending',
  created_at INTEGER,
  updated_at INTEGER,
  last_seen  INTEGER
)`;

export const PC_MSG_DDL = `
CREATE TABLE IF NOT EXISTS pc_msg (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  role       TEXT NOT NULL,
  text       TEXT NOT NULL DEFAULT '',
  created_at INTEGER
)`;

export async function ensurePcTables(db: any) {
  await db.prepare(PC_SESSION_DDL).run();
  await db.prepare(PC_MSG_DDL).run();
  try {
    await db.prepare('CREATE INDEX IF NOT EXISTS idx_pcm_sid ON pc_msg(session_id, id)').run();
  } catch {
    /* 已存在 */
  }
}

function newId(p: string) {
  return p + '_' + Math.random().toString(36).slice(2, 10) + Date.now().toString(36).slice(-4);
}

export async function pcCreateSession(db: any, body: any) {
  await ensurePcTables(db);
  const id = newId('pc');
  const now = Date.now();
  const name = String(body?.name || '').trim() || '未命名会话';
  const cli = String(body?.cli || 'auto').trim();
  const cwd = String(body?.cwd || '').trim();
  const first = String(body?.message || body?.text || '').trim();

  await db
    .prepare(
      `INSERT INTO pc_session (id, name, cli, cwd, status, created_at, updated_at, last_seen)
       VALUES (?,?,?,?, 'pending', ?,?,?)`,
    )
    .bind(id, name, cli, cwd, now, now, now)
    .run();

  if (first) {
    await db
      .prepare('INSERT INTO pc_msg (session_id, role, text, created_at) VALUES (?,?,?,?)')
      .bind(id, 'user', first, now)
      .run();
  }
  return { id, name, cli, cwd, status: 'pending' };
}

export async function pcListSessions(db: any) {
  await ensurePcTables(db);
  const r = await db
    .prepare('SELECT * FROM pc_session ORDER BY created_at DESC LIMIT 50')
    .all();
  const now = Date.now();
  return (r.results || []).map((s: any) => ({
    ...s,
    idle_ms: s.last_seen ? now - Number(s.last_seen) : null,
    pc_online: s.last_seen ? now - Number(s.last_seen) < 90000 : false,
  }));
}

/** 电脑端来领活：返回所有 pending 会话 + 指定会话里还没喂进去的用户消息 */
export async function pcPoll(db: any, body: any) {
  await ensurePcTables(db);
  const now = Date.now();
  const pcName = String(body?.pc || '').trim();

  const pend = await db
    .prepare("SELECT * FROM pc_session WHERE status='pending' ORDER BY created_at ASC LIMIT 5")
    .all();

  // 电脑心跳：把它领过的 running 会话都刷新一下
  if (pcName) {
    await db
      .prepare("UPDATE pc_session SET last_seen=? WHERE status IN ('running','done')")
      .bind(now)
      .run();
  }

  const sessions = (pend.results || []).map((s: any) => ({ ...s }));
  for (const s of sessions) {
    const msgs = await db
      .prepare(
        "SELECT id, role, text FROM pc_msg WHERE session_id=? AND role IN ('user','file') AND id > ? ORDER BY id ASC",
      )
      .bind(s.id, Number(s.last_input_id || 0))
      .all();
    s.pending_inputs = msgs.results || [];
  }

  return { sessions, now };
}

/** 电脑领走一个会话，开始跑 */
export async function pcClaim(db: any, body: any) {
  await ensurePcTables(db);
  const id = String(body?.id || '').trim();
  if (!id) throw new Error('缺少 id');
  const now = Date.now();
  await db
    .prepare("UPDATE pc_session SET status='running', updated_at=?, last_seen=? WHERE id=?")
    .bind(now, now, id)
    .run();
  return { id, status: 'running' };
}

/** 电脑回传输出（增量追加，不清空） */
export async function pcOutput(db: any, body: any) {
  await ensurePcTables(db);
  const id = String(body?.session_id || body?.id || '').trim();
  const text = String(body?.text ?? '').slice(0, 20000);
  if (!id) throw new Error('缺少 session_id');
  const now = Date.now();
  await db
    .prepare('INSERT INTO pc_msg (session_id, role, text, created_at) VALUES (?,?,?,?)')
    .bind(id, String(body?.role || 'output'), text, now)
    .run();
  if (body?.done) {
    await db
      .prepare("UPDATE pc_session SET status=?, updated_at=?, last_seen=? WHERE id=?")
      .bind(String(body?.status || 'done'), now, now, id)
      .run();
  } else {
    await db.prepare('UPDATE pc_session SET last_seen=? WHERE id=?').bind(now, id).run();
  }
  return { ok: true };
}

/** 手机发一句话（追问） */
export async function pcInput(db: any, body: any) {
  await ensurePcTables(db);
  const id = String(body?.session_id || body?.id || '').trim();
  const text = String(body?.text ?? body?.message ?? '').trim();
  if (!id) throw new Error('缺少 session_id');
  if (!text) throw new Error('缺少 text');
  const now = Date.now();
  await db
    .prepare('INSERT INTO pc_msg (session_id, role, text, created_at) VALUES (?,?,?,?)')
    .bind(id, 'user', text, now)
    .run();
  // 已经跑完的会话被追问 → 重新置为 pending 让电脑再跑一轮
  await db
    .prepare(
      "UPDATE pc_session SET status='pending', updated_at=? WHERE id=? AND status IN ('done','error')",
    )
    .bind(now, id)
    .run();
  return { ok: true };
}

/**
 * 手机把文件送过去。
 *   {session_id, path, content_base64}
 * 存在 pc_msg 里 role='file'，电脑领活时落盘。
 * 限制 1.5MB（base64 后约 2MB），再大走别的通道。
 */
export async function pcUpload(db: any, body: any) {
  await ensurePcTables(db);
  const id = String(body?.session_id || body?.id || '').trim();
  const path = String(body?.path || '').trim();
  const b64 = String(body?.content_base64 || '');
  if (!id) throw new Error('缺少 session_id');
  if (!path) throw new Error('缺少 path');
  if (!b64) throw new Error('缺少 content_base64');
  if (b64.length > 2_000_000) throw new Error('文件太大（上限约 1.5MB），换个方式传');

  const now = Date.now();
  const payload = JSON.stringify({ path, content_base64: b64 });
  await db
    .prepare('INSERT INTO pc_msg (session_id, role, text, created_at) VALUES (?,?,?,?)')
    .bind(id, 'file', payload, now)
    .run();
  // 已经跑完的会话被追加文件 → 重新置 pending 让电脑处理
  await db
    .prepare(
      "UPDATE pc_session SET status='pending', updated_at=? WHERE id=? AND status IN ('done','error')",
    )
    .bind(now, id)
    .run();
  return { ok: true, bytes: Math.floor(b64.length * 3 / 4) };
}

export async function pcMessages(db: any, sessionId: string, since: number) {
  await ensurePcTables(db);
  const r = await db
    .prepare('SELECT id, role, text, created_at FROM pc_msg WHERE session_id=? AND id>? ORDER BY id ASC LIMIT 500')
    .bind(sessionId, Number(since) || 0)
    .all();
  const s: any = await db.prepare('SELECT * FROM pc_session WHERE id=?').bind(sessionId).first();
  return { messages: r.results || [], session: s || null };
}
