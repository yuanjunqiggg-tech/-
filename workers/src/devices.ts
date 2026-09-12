/**
 * ============================================================
 * Ds Platform · 多设备控制模块
 *
 * 职责：让「被控端（云手机 APK）」和「控制端（网页/APK）」通过
 *       Workers + D1 完成跨网通信，无需在云手机上装隧道。
 *
 * 通信模型（被控端主动外连）：
 *
 *   被控端                          云端                          控制端
 *     │                              │                             │
 *     ├─ POST /device/register ─────►│  发 device_id + token        │
 *     │                              │                             │
 *     ├─ POST /device/heartbeat ────►│  上报在线/电量/Prism状态      │
 *     │                              │◄── POST /cmd 下发指令 ───────┤
 *     ├─ GET  /device/poll ─────────►│  长轮询领指令（挂起 25s）      │
 *     │◄──── 指令 JSON ──────────────┤                             │
 *     ├─ 本机执行（转发 Prism:8080）  │                             │
 *     ├─ POST /device/report ───────►│  chunk/tool_done/packet      │
 *     │                              ├── 写入 device_events ────────►│
 *     │                              │                             ├─ GET /stream 拉取
 *     │                              │                             │  (游标增量)
 *
 * 为什么用长轮询而不是 WebSocket：
 *   Workers 免费版对 WebSocket 支持受限，且 Durable Objects 需付费。
 *   长轮询（挂起 25 秒）在免费额度内完全够用，延迟也在可接受范围。
 * ============================================================
 */

export interface DeviceEnv {
  DB: D1Database;
  PLATFORM_ACCESS_KEY: string;
}

// ------------------------------------------------------------
// 工具函数
// ------------------------------------------------------------
function jr(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-Device-Id, X-Device-Token',
      'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
    },
  });
}

function jok(data: unknown, msg?: string) {
  return jr({ ok: true, data, message: msg });
}

function jfail(msg: string, status = 400) {
  return jr({ ok: false, error: msg }, status);
}

/** 生成随机 ID */
function rid(prefix: string, len = 20): string {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  const buf = new Uint8Array(len);
  crypto.getRandomValues(buf);
  let s = '';
  for (const b of buf) s += chars[b % chars.length];
  return `${prefix}_${s}`;
}

/** 恒定时间比较，防时序攻击 */
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** 校验控制端密钥（人用） */
function checkAdmin(req: Request, env: DeviceEnv): boolean {
  const auth = req.headers.get('Authorization') || '';
  const token = auth.replace(/^Bearer\s+/i, '').trim();
  return token.length > 0 && safeEqual(token, env.PLATFORM_ACCESS_KEY);
}

/** 校验被控端身份（设备用） */
async function checkDevice(
  req: Request,
  env: DeviceEnv,
  deviceId?: string,
): Promise<{ ok: boolean; device?: any }> {
  const id = deviceId || req.headers.get('X-Device-Id') || '';
  const token = req.headers.get('X-Device-Token') || '';
  if (!id || !token) return { ok: false };

  const row = await env.DB.prepare(
    'SELECT * FROM devices WHERE id = ? AND status = 1',
  )
    .bind(id)
    .first<any>();
  if (!row) return { ok: false };
  if (!safeEqual(row.token, token)) return { ok: false };
  return { ok: true, device: row };
}

// ------------------------------------------------------------
// ★ 被控端 API
// ------------------------------------------------------------

/**
 * 设备注册
 * POST /api/v1/device/register
 * body: { name, platform, model, android_ver, app_ver, prism_port, memo }
 *
 * 两种模式：
 *   a) 首次注册：不带 device_id → 服务端生成，返回 {device_id, token}
 *   b) 重新绑定：带 device_id + token → 校验后更新信息，token 不变
 */
export async function deviceRegister(req: Request, env: DeviceEnv): Promise<Response> {
  let b: any = {};
  try {
    b = await req.json();
  } catch {
    return jfail('请求体必须是 JSON');
  }

  const now = Date.now();
  const incomingId = (b.device_id || '').toString().trim();
  const incomingToken = (b.token || '').toString().trim();

  // --- 重新绑定已有设备 ---
  if (incomingId && incomingToken) {
    const row = await env.DB.prepare('SELECT * FROM devices WHERE id = ?')
      .bind(incomingId)
      .first<any>();
    if (!row) return jfail('设备不存在，请清除 App 数据后重新注册', 404);
    if (!safeEqual(row.token, incomingToken)) return jfail('设备凭据错误', 401);

    await env.DB.prepare(
      `UPDATE devices SET name=?, platform=?, model=?, android_ver=?, app_ver=?,
         prism_port=?, memo=?, last_seen=?, status=1 WHERE id=?`,
    )
      .bind(
        b.name ?? row.name, b.platform ?? row.platform,
        b.model ?? row.model, b.android_ver ?? row.android_ver,
        b.app_ver ?? row.app_ver, b.prism_port ?? row.prism_port,
        b.memo ?? row.memo, now, incomingId,
      )
      .run();
    return jok({ device_id: incomingId, token: incomingToken, rebound: true });
  }

  // --- 首次注册 ---
  const deviceId = rid('dev');
  const token = rid('dtk', 32);
  await env.DB.prepare(
    `INSERT INTO devices
       (id, token, name, platform, model, android_ver, app_ver,
        prism_port, memo, status, last_seen, created_at)
     VALUES (?,?,?,?,?,?,?,?,?,1,?,?)`,
  )
    .bind(
      deviceId, token,
      b.name || `云手机-${deviceId.slice(-4)}`,
      b.platform || 'android',
      b.model || '', b.android_ver || '', b.app_ver || '',
      b.prism_port ?? 8080, b.memo || '',
      now, now,
    )
    .run();

  return jok({
    device_id: deviceId,
    token,
    register_url_hint: '请妥善保存 token，App 会持久化它用于后续鉴权',
  });
}

/**
 * 心跳
 * POST /api/v1/device/heartbeat
 * headers: X-Device-Id, X-Device-Token
 * body: { prism_online, bot_connected, bot_server, battery, ip_hint }
 */
export async function deviceHeartbeat(req: Request, env: DeviceEnv): Promise<Response> {
  const chk = await checkDevice(req, env);
  if (!chk.ok) return jfail('设备鉴权失败', 401);

  let b: any = {};
  try {
    b = await req.json();
  } catch {
    /* 允许空 body */
  }
  const now = Date.now();

  await env.DB.prepare(
    `UPDATE devices SET last_seen=?, prism_online=?, bot_connected=?,
       bot_server=?, battery=?, ip_hint=? WHERE id=?`,
  )
    .bind(
      now,
      b.prism_online ? 1 : 0,
      b.bot_connected ? 1 : 0,
      b.bot_server ?? chk.device.bot_server ?? '',
      typeof b.battery === 'number' ? b.battery : chk.device.battery,
      (req.headers.get('CF-Connecting-IP') || b.ip_hint || '').replace(/\.\d+$/, '.x'),
      chk.device.id,
    )
    .run();

  // 顺带回传：有没有待办指令（让被控端少一次请求）
  const pend = await env.DB.prepare(
    `SELECT COUNT(*) AS c FROM device_commands WHERE device_id=? AND status='pending'`,
  )
    .bind(chk.device.id)
    .first<any>();

  return jok({ server_time: now, pending: pend?.c ?? 0 });
}

/**
 * ★ 长轮询领指令
 * POST /api/v1/device/poll
 * headers: X-Device-Id, X-Device-Token
 * body: { wait: 25 }   最多挂起的秒数
 *
 * Workers 有 CPU 时间限制，但等待 I/O 不计入 CPU 时间，
 * 因此这里用 setTimeout 挂起是安全的（wall time 上限约 30s / 请求）。
 */
export async function devicePoll(req: Request, env: DeviceEnv): Promise<Response> {
  const chk = await checkDevice(req, env);
  if (!chk.ok) return jfail('设备鉴权失败', 401);
  const deviceId = chk.device.id;

  let b: any = {};
  try {
    b = await req.json();
  } catch {
    /* 允许空 body */
  }
  const maxWait = Math.min(Math.max(parseInt(b.wait ?? '25', 10) || 25, 1), 27);
  const deadline = Date.now() + maxWait * 1000;

  let picked: any = null;
  while (Date.now() < deadline) {
    // 原子领取：先查出待办，再带状态条件更新，避免多实例重复领取
    const cand = await env.DB.prepare(
      `SELECT * FROM device_commands
       WHERE device_id=? AND status='pending'
       ORDER BY created_at ASC LIMIT 1`,
    )
      .bind(deviceId)
      .first<any>();

    if (cand) {
      const upd = await env.DB.prepare(
        `UPDATE device_commands SET status='taken', taken_at=?
         WHERE id=? AND status='pending'`,
      )
        .bind(Date.now(), cand.id)
        .run();
      if (upd.meta.changes > 0) {
        picked = cand;
        break;
      }
      continue; // 被别人抢了，再试
    }
    await new Promise((r) => setTimeout(r, 1000));
  }

  if (!picked) {
    return jok({ command: null, hint: '暂无指令' });
  }

  return jok({
    command: {
      id: picked.id,
      kind: picked.kind,
      payload: safeJSON(picked.payload),
      session_id: picked.session_id,
    },
  });
}

/**
 * 上报执行结果 / 事件
 * POST /api/v1/device/report
 * body: { command_id, events: [{type, payload}], done, result, error }
 *
 * events.type:
 *   chunk        流式文本片段
 *   thinking     思考中
 *   tool_start   工具开始
 *   tool_done    工具完成（含真实结果）
 *   packet       抓到的数据包
 *   status       状态变化
 *   error        错误
 */
export async function deviceReport(req: Request, env: DeviceEnv): Promise<Response> {
  const chk = await checkDevice(req, env);
  if (!chk.ok) return jfail('设备鉴权失败', 401);

  let b: any = {};
  try {
    b = await req.json();
  } catch {
    return jfail('请求体必须是 JSON');
  }

  const deviceId = chk.device.id;
  const now = Date.now();
  const cmdId = b.command_id || null;
  const sessionId = b.session_id || null;
  const events: any[] = Array.isArray(b.events) ? b.events : [];

  // --- 批量写入事件流 ---
  if (events.length) {
    const stmts = events.slice(0, 200).map((e) =>
      env.DB.prepare(
        `INSERT INTO device_events (device_id, command_id, session_id, type, payload, created_at)
         VALUES (?,?,?,?,?,?)`,
      ).bind(
        deviceId, cmdId, sessionId,
        (e.type || 'log').toString(),
        JSON.stringify(e.payload ?? e.data ?? null),
        now,
      ),
    );
    await env.DB.batch(stmts);

    // --- 抓包数据单独落库，便于历史回看 ---
    const pktEvents = events.filter((e) => e.type === 'packet');
    if (pktEvents.length) {
      const pstmts = pktEvents.slice(0, 200).map((e) => {
        const p = e.payload || {};
        const fieldsStr = typeof p.fields === 'string' ? p.fields : JSON.stringify(p.fields ?? null);
        const raw = (p.raw_hex || '').toString();
        return env.DB.prepare(
          `INSERT INTO device_packets
             (device_id, packet_seq, packet_type, packet_id, direction, bot_index,
              fields, raw_hex, size, captured_at)
           VALUES (?,?,?,?,?,?,?,?,?,?)`,
        ).bind(
          deviceId,
          p.seq ?? null,
          p.packet_type ?? p.type ?? null,
          p.packet_id ?? null,
          p.direction ?? null,
          p.bot ?? p.bot_index ?? 0,
          fieldsStr,
          raw.slice(0, 4000),
          raw.length / 2,
          now,
        );
      });
      await env.DB.batch(pstmts);
    }
  }

  // --- 指令收尾 ---
  if (cmdId && (b.done || b.error)) {
    await env.DB.prepare(
      `UPDATE device_commands SET status=?, result=?, error=?, finished_at=?
       WHERE id=? AND device_id=?`,
    )
      .bind(
        b.error ? 'failed' : 'done',
        b.result === undefined ? null : JSON.stringify(b.result),
        b.error ?? null,
        now, cmdId, deviceId,
      )
      .run();
  }

  // 顺便更新心跳
  await env.DB.prepare('UPDATE devices SET last_seen=? WHERE id=?')
    .bind(now, deviceId)
    .run();

  return jok({ accepted: events.length });
}

// ------------------------------------------------------------
// 控制端 API
// ------------------------------------------------------------

/** 设备列表（带在线判定） */
export async function listDevices(req: Request, env: DeviceEnv, url: URL): Promise<Response> {
  if (!checkAdmin(req, env)) return jfail('未授权', 401);
  const rows = await env.DB.prepare(
    `SELECT id, name, platform, model, android_ver, app_ver, prism_port,
            prism_online, bot_connected, bot_server, battery, ip_hint, memo,
            status, last_seen, created_at
     FROM devices ORDER BY last_seen DESC LIMIT 200`,
  ).all<any>();

  const now = Date.now();
  const ONLINE_MS = 90_000; // 90 秒内有心跳算在线
  const devices = (rows.results || []).map((d) => ({
    ...d,
    online: d.status === 1 && now - (d.last_seen || 0) < ONLINE_MS,
    idle_sec: Math.floor((now - (d.last_seen || 0)) / 1000),
  }));

  return jok({
    devices,
    counts: {
      total: devices.length,
      online: devices.filter((d) => d.online).length,
      prism_running: devices.filter((d) => d.prism_online).length,
      bot_connected: devices.filter((d) => d.bot_connected).length,
    },
  });
}

/** 单设备详情 */
export async function getDevice(req: Request, env: DeviceEnv, id: string): Promise<Response> {
  if (!checkAdmin(req, env)) return jfail('未授权', 401);
  const d = await env.DB.prepare('SELECT * FROM devices WHERE id=?').bind(id).first<any>();
  if (!d) return jfail('设备不存在', 404);
  delete d.token; // 不泄漏设备凭据

  const now = Date.now();
  const [pend, recentPkts] = await Promise.all([
    env.DB.prepare(
      `SELECT COUNT(*) AS c FROM device_commands WHERE device_id=? AND status IN ('pending','taken')`,
    )
      .bind(id)
      .first<any>(),
    env.DB.prepare(
      `SELECT COUNT(*) AS c FROM device_packets WHERE device_id=? AND captured_at > ?`,
    )
      .bind(id, now - 300_000)
      .first<any>(),
  ]);

  return jok({
    device: { ...d, online: d.status === 1 && now - (d.last_seen || 0) < 90_000 },
    pending_commands: pend?.c ?? 0,
    packets_5min: recentPkts?.c ?? 0,
  });
}

/** 删除/停用设备 */
export async function deleteDevice(req: Request, env: DeviceEnv, id: string, url: URL): Promise<Response> {
  if (!checkAdmin(req, env)) return jfail('未授权', 401);
  const hard = url.searchParams.get('hard') === '1';
  if (hard) {
    await env.DB.batch([
      env.DB.prepare('DELETE FROM devices WHERE id=?').bind(id),
      env.DB.prepare('DELETE FROM device_commands WHERE device_id=?').bind(id),
      env.DB.prepare('DELETE FROM device_events WHERE device_id=?').bind(id),
      env.DB.prepare('DELETE FROM device_packets WHERE device_id=?').bind(id),
      env.DB.prepare('DELETE FROM device_sessions WHERE device_id=?').bind(id),
    ]);
    return jok({ deleted: true, hard: true });
  }
  await env.DB.prepare('UPDATE devices SET status=0 WHERE id=?').bind(id).run();
  return jok({ deleted: true, hard: false, note: '设备已停用，可用硬删除彻底清除' });
}

/** 重命名 / 改备注 */
export async function patchDevice(req: Request, env: DeviceEnv, id: string): Promise<Response> {
  if (!checkAdmin(req, env)) return jfail('未授权', 401);
  let b: any = {};
  try {
    b = await req.json();
  } catch {
    return jfail('请求体必须是 JSON');
  }
  const d = await env.DB.prepare('SELECT * FROM devices WHERE id=?').bind(id).first<any>();
  if (!d) return jfail('设备不存在', 404);

  await env.DB.prepare('UPDATE devices SET name=?, memo=? WHERE id=?')
    .bind(b.name ?? d.name, b.memo ?? d.memo, id)
    .run();
  return jok({ updated: true });
}

/**
 * ★ 下发指令
 * POST /api/v1/device/:id/command
 * body: { kind, payload, session_id }
 *
 * kind:
 *   chat            自然语言对话（驱动 Prism AI）
 *   tool            直接调用某个 Prism 工具
 *   packet_sub      订阅一段时间的数据包
 *   packet_send     发包
 *   prism_rest      直连 Prism REST 端点
 */
export async function pushCommand(req: Request, env: DeviceEnv, id: string): Promise<Response> {
  if (!checkAdmin(req, env)) return jfail('未授权', 401);

  let b: any = {};
  try {
    b = await req.json();
  } catch {
    return jfail('请求体必须是 JSON');
  }

  const d = await env.DB.prepare('SELECT id, status, last_seen FROM devices WHERE id=?')
    .bind(id)
    .first<any>();
  if (!d) return jfail('设备不存在', 404);
  if (d.status !== 1) return jfail('设备已停用', 403);

  const now = Date.now();
  const online = now - (d.last_seen || 0) < 90_000;
  if (!online) {
    return jfail(
      `设备离线（最后心跳 ${Math.floor((now - (d.last_seen || 0)) / 1000)} 秒前）。` +
        `请确认云手机上被控端 App 在运行、且已开启前台服务。`,
      409,
    );
  }

  const kind = (b.kind || 'chat').toString();
  const allowed = ['chat', 'tool', 'packet_sub', 'packet_send', 'prism_rest'];
  if (!allowed.includes(kind)) {
    return jfail(`不支持的指令类型：${kind}（可用：${allowed.join(', ')}）`);
  }

  const cmdId = rid('cmd', 16);
  await env.DB.prepare(
    `INSERT INTO device_commands (id, device_id, kind, payload, session_id, status, created_at)
     VALUES (?,?,?,?,?,'pending',?)`,
  )
    .bind(cmdId, id, kind, JSON.stringify(b.payload ?? {}), b.session_id ?? null, now)
    .run();

  return jok({
    command_id: cmdId,
    queued_at: now,
    note: '指令已入队，被控端最长 27 秒内领取',
  });
}

/**
 * 指令状态
 * GET /api/v1/device/:id/command/:cmdId
 */
export async function getCommand(
  req: Request,
  env: DeviceEnv,
  id: string,
  cmdId: string,
): Promise<Response> {
  if (!checkAdmin(req, env)) return jfail('未授权', 401);
  const c = await env.DB.prepare(
    'SELECT * FROM device_commands WHERE id=? AND device_id=?',
  )
    .bind(cmdId, id)
    .first<any>();
  if (!c) return jfail('指令不存在', 404);

  const evs = await env.DB.prepare(
    `SELECT seq, type, payload, created_at FROM device_events
     WHERE command_id=? ORDER BY seq ASC LIMIT 500`,
  )
    .bind(cmdId)
    .all<any>();

  return jok({
    command: {
      ...c,
      payload: safeJSON(c.payload),
      result: safeJSON(c.result),
    },
    events: (evs.results || []).map((e) => ({ ...e, payload: safeJSON(e.payload) })),
  });
}

/**
 * ★ 事件流（游标增量拉取，控制端轮询这个）
 * GET /api/v1/device/:id/stream?since=123&limit=200
 */
export async function deviceStream(req: Request, env: DeviceEnv, id: string, url: URL): Promise<Response> {
  if (!checkAdmin(req, env)) return jfail('未授权', 401);

  const since = parseInt(url.searchParams.get('since') || '0', 10) || 0;
  const limit = Math.min(parseInt(url.searchParams.get('limit') || '200', 10) || 200, 500);
  const cmdId = url.searchParams.get('command_id');

  let sql = `SELECT seq, command_id, session_id, type, payload, created_at
             FROM device_events WHERE device_id=? AND seq>?`;
  const binds: any[] = [id, since];
  if (cmdId) {
    sql += ' AND command_id=?';
    binds.push(cmdId);
  }
  sql += ' ORDER BY seq ASC LIMIT ?';
  binds.push(limit);

  const rows = await env.DB.prepare(sql).bind(...binds).all<any>();
  const events = (rows.results || []).map((e) => ({ ...e, payload: safeJSON(e.payload) }));
  const cursor = events.length ? events[events.length - 1].seq : since;

  return jok({ events, cursor, has_more: events.length >= limit });
}

/**
 * 抓包历史（从 device_packets 查）
 * GET /api/v1/device/:id/packets?type=X&seconds=300&limit=100
 */
export async function devicePackets(req: Request, env: DeviceEnv, id: string, url: URL): Promise<Response> {
  if (!checkAdmin(req, env)) return jfail('未授权', 401);

  const seconds = Math.min(parseInt(url.searchParams.get('seconds') || '300', 10) || 300, 86400);
  const limit = Math.min(parseInt(url.searchParams.get('limit') || '100', 10) || 100, 500);
  const ptype = url.searchParams.get('type');
  const keyword = url.searchParams.get('keyword');

  let sql = `SELECT id, packet_seq, packet_type, packet_id, direction, bot_index,
                    fields, size, captured_at
             FROM device_packets WHERE device_id=? AND captured_at>?`;
  const binds: any[] = [id, Date.now() - seconds * 1000];
  if (ptype) {
    sql += ' AND packet_type=?';
    binds.push(ptype);
  }
  if (keyword) {
    sql += ' AND fields LIKE ?';
    binds.push(`%${keyword}%`);
  }
  sql += ' ORDER BY captured_at DESC LIMIT ?';
  binds.push(limit);

  const rows = await env.DB.prepare(sql).bind(...binds).all<any>();

  // 统计
  const st = await env.DB.prepare(
    `SELECT packet_type, COUNT(*) AS c FROM device_packets
     WHERE device_id=? AND captured_at>? GROUP BY packet_type ORDER BY c DESC LIMIT 40`,
  )
    .bind(id, Date.now() - seconds * 1000)
    .all<any>();

  return jok({
    packets: (rows.results || []).map((p) => ({ ...p, fields: safeJSON(p.fields) })),
    stats: st.results || [],
    window_sec: seconds,
  });
}

/** 会话列表（按设备） */
export async function deviceSessions(req: Request, env: DeviceEnv, id: string): Promise<Response> {
  if (!checkAdmin(req, env)) return jfail('未授权', 401);
  const rows = await env.DB.prepare(
    `SELECT * FROM device_sessions WHERE device_id=? ORDER BY updated_at DESC LIMIT 100`,
  )
    .bind(id)
    .all<any>();
  return jok({ sessions: rows.results || [] });
}

/** 全局概览（首页看板） */
export async function deviceOverview(req: Request, env: DeviceEnv): Promise<Response> {
  if (!checkAdmin(req, env)) return jfail('未授权', 401);
  const now = Date.now();
  const [dev, pkts, cmds] = await Promise.all([
    env.DB.prepare(
      `SELECT COUNT(*) AS total,
              SUM(CASE WHEN last_seen > ? THEN 1 ELSE 0 END) AS online,
              SUM(CASE WHEN prism_online = 1 THEN 1 ELSE 0 END) AS prism_on,
              SUM(CASE WHEN bot_connected = 1 THEN 1 ELSE 0 END) AS bot_on
       FROM devices WHERE status=1`,
    )
      .bind(now - 90_000)
      .first<any>(),
    env.DB.prepare(
      'SELECT COUNT(*) AS c FROM device_packets WHERE captured_at > ?',
    )
      .bind(now - 3_600_000)
      .first<any>(),
    env.DB.prepare(
      `SELECT COUNT(*) AS c FROM device_commands WHERE created_at > ?`,
    )
      .bind(now - 3_600_000)
      .first<any>(),
  ]);

  return jok({
    devices: {
      total: dev?.total ?? 0,
      online: dev?.online ?? 0,
      prism_running: dev?.prism_on ?? 0,
      bot_connected: dev?.bot_on ?? 0,
    },
    packets_1h: pkts?.c ?? 0,
    commands_1h: cmds?.c ?? 0,
    server_time: now,
  });
}

/** 安全解析 JSON 字符串 */
function safeJSON(v: unknown): unknown {
  if (typeof v !== 'string') return v ?? null;
  try {
    return JSON.parse(v);
  } catch {
    return v;
  }
}
