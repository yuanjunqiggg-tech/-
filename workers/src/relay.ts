// ============================================================
//  设备中继：把「要 Prism 做的事」下发给云手机里的被控端，
//  并同步等待它执行完回传结果。
// ============================================================
//
//  ★ 这是 2026-09-13 11:45 架构纠正后的核心改动。
//
//    旧做法（错的）：网关 fetch(env.PRISM_TUNNEL_URL) —— 隧道指向用户
//    本地电脑，电脑一关就全瘫，而且 Prism 其实跑在云手机里。
//
//    新做法（对的）：
//      网关 → D1 写一条 pending 指令
//           → 被控端长轮询领走 → 在云手机内 127.0.0.1:8080 调 Prism
//           → 回传 result → 网关轮询到终态 → 返回给调用方
//
//    全程不碰用户电脑。
// ============================================================

const ONLINE_WINDOW_MS = 90_000;

function rid(prefix: string, len = 16): string {
  const cs = 'abcdefghijklmnopqrstuvwxyz0123456789';
  let s = '';
  for (let i = 0; i < len; i++) s += cs[Math.floor(Math.random() * cs.length)];
  return `${prefix}_${s}`;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** 被控端事件类型 → 控制台认得的 SSE 事件名 */
const SSE_MAP: Record<string, string> = {
  chunk: 'ai_chunk',
  thinking: 'ai_thinking',
  tool_start: 'ai_tool_start',
  tool_done: 'ai_tool_done',
  usage: 'ai_usage',
  error: 'ai_error',
  ai_round_done: 'ai_round_done',
};

/**
 * 下发一条 chat 指令，并把被控端回传的事件流**实时**转成 SSE 给控制台。
 *
 * 为什么这么绕：控制台要的是流式打字机效果，而 D1 只能轮询。
 * 所以这里边轮询边往外写 SSE —— 延迟约 1.2s，但保留了流式体验。
 */
export function streamCommandSSE(
  db: D1Database,
  deviceId: string | undefined,
  payload: Record<string, unknown>,
  timeoutMs = 120_000,
): Promise<Response> {
  const enc = new TextEncoder();

  const stream = new ReadableStream({
    async start(controller) {
      let closed = false;
      const send = (event: string, data: unknown) => {
        if (closed) return;
        try {
          controller.enqueue(enc.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`));
        } catch {
          closed = true;
        }
      };

      // 先选设备，失败也要用 SSE 报出来（控制台是按 SSE 解析的）
      const dev = await pickDevice(db, deviceId);
      if (!dev) {
        send('ai_error', { error: '云端没有任何被控端设备，请先在云手机上运行 Prism被控端' });
        controller.close();
        return;
      }
      const offlineFor = Date.now() - (dev.last_seen || 0);
      if (dev.status !== 1 || offlineFor > ONLINE_WINDOW_MS) {
        send('ai_error', {
          error: `设备 ${dev.name || dev.id} 离线（最后心跳 ${Math.floor(offlineFor / 1000)} 秒前）`,
        });
        controller.close();
        return;
      }

      const cmdId = rid('cmd');
      await db
        .prepare(
          `INSERT INTO device_commands (id, device_id, kind, payload, session_id, status, created_at)
           VALUES (?,?, 'chat',?,?,'pending',?)`,
        )
        .bind(cmdId, dev.id, JSON.stringify(payload), (payload as any)?.session_name ?? null, Date.now())
        .run();

      send('ai_meta', { command_id: cmdId, device_id: dev.id, device_name: dev.name || dev.id });

      let cursor = 0;
      let finalText = '';
      const deadline = Date.now() + timeoutMs;
      let done = false;

      while (Date.now() < deadline && !closed) {
        await sleep(1200);

        const evs = await db
          .prepare(
            `SELECT seq, type, payload FROM device_events
             WHERE command_id=? AND seq>? ORDER BY seq ASC LIMIT 200`,
          )
          .bind(cmdId, cursor)
          .all<any>();

        for (const e of evs.results || []) {
          cursor = e.seq;
          let p: any = null;
          try {
            p = e.payload ? JSON.parse(e.payload) : {};
          } catch {
            p = { raw: e.payload };
          }
          const name = SSE_MAP[e.type] || e.type;
          send(name, p);
          if (e.type === 'chunk' && p?.text) finalText += p.text;
        }

        const st = await db
          .prepare('SELECT status, result, error FROM device_commands WHERE id=?')
          .bind(cmdId)
          .first<any>();

        if (st && (st.status === 'done' || st.status === 'failed')) {
          if (st.status === 'failed') {
            send('ai_error', { error: st.error || '被控端执行出错' });
          } else if (!finalText && st.result) {
            // 没攒到流式文本（比如被控端先攒批后上报）→ 补发全文
            try {
              const r = JSON.parse(st.result);
              if (r?.text) send('ai_chunk', { text: r.text });
            } catch {
              /* ignore */
            }
          }
          send('ai_done', { command_id: cmdId });
          done = true;
          break;
        }
      }

      if (!done && !closed) {
        send('ai_error', {
          error: '等待被控端超时，指令仍在队列中',
          command_id: cmdId,
        });
      }

      if (!closed) {
        try {
          controller.close();
        } catch {
          /* ignore */
        }
      }
    },
  });

  return Promise.resolve(
    new Response(stream, {
      headers: {
        'Content-Type': 'text/event-stream; charset=utf-8',
        'Cache-Control': 'no-cache, no-transform',
        Connection: 'keep-alive',
        'Access-Control-Allow-Origin': '*',
        'X-Accel-Buffering': 'no',
      },
    }),
  );
}

/** 选设备：显式 id > 最近在线的那台 */
export async function pickDevice(db: D1Database, deviceId?: string): Promise<any | null> {
  if (deviceId) {
    const d = await db.prepare('SELECT * FROM devices WHERE id=?').bind(deviceId).first<any>();
    if (d) return d;
  }
  const d = await db.prepare(
    `SELECT * FROM devices WHERE status=1 ORDER BY last_seen DESC LIMIT 1`,
  ).first<any>();
  return d || null;
}

/**
 * 下发指令并等待结果。
 *
 * @returns { ok, command_id, device_id, result, error, events, timeout }
 *   timeout=true 表示指令已入队但还没跑完 —— 调用方可以拿 command_id 轮询
 */
export async function runOnDevice(
  db: D1Database,
  deviceId: string | undefined,
  kind: string,
  payload: Record<string, unknown>,
  opts: { timeoutMs?: number; sessionId?: string } = {},
): Promise<any> {
  const timeoutMs = opts.timeoutMs ?? 45_000;

  const dev = await pickDevice(db, deviceId);
  if (!dev) {
    return {
      ok: false,
      error: '云端没有任何被控端设备。请先在云手机上安装运行「Prism被控端」并完成注册。',
    };
  }
  if (dev.status !== 1) {
    return { ok: false, error: `设备 ${dev.id} 已停用`, device_id: dev.id };
  }

  const offlineFor = Date.now() - (dev.last_seen || 0);
  if (offlineFor > ONLINE_WINDOW_MS) {
    return {
      ok: false,
      device_id: dev.id,
      error:
        `设备 ${dev.name || dev.id} 离线（最后心跳 ${Math.floor(offlineFor / 1000)} 秒前）。` +
        `请确认云手机上的被控端在运行。`,
    };
  }

  const cmdId = rid('cmd');
  const now = Date.now();
  await db
    .prepare(
      `INSERT INTO device_commands (id, device_id, kind, payload, session_id, status, created_at)
       VALUES (?,?,?,?,?,'pending',?)`,
    )
    .bind(cmdId, dev.id, kind, JSON.stringify(payload ?? {}), opts.sessionId ?? null, now)
    .run();

  // 轮询终态。被控端最长 ~3s 领一次指令，这里 1.2s 一查。
  const deadline = Date.now() + timeoutMs;
  let last: any = null;
  while (Date.now() < deadline) {
    await sleep(1200);
    last = await db
      .prepare('SELECT status, result, error FROM device_commands WHERE id=?')
      .bind(cmdId)
      .first<any>();
    if (!last) break;
    if (last.status === 'done' || last.status === 'failed') {
      let res: any = null;
      try {
        res = last.result ? JSON.parse(last.result) : null;
      } catch {
        res = last.result;
      }
      return {
        ok: last.status === 'done',
        command_id: cmdId,
        device_id: dev.id,
        device_name: dev.name || dev.id,
        result: res,
        error: last.error || null,
        timeout: false,
      };
    }
  }

  return {
    ok: false,
    command_id: cmdId,
    device_id: dev.id,
    device_name: dev.name || dev.id,
    timeout: true,
    error: `等待被控端执行超时（${Math.round(timeoutMs / 1000)}s）。指令已入队，可拿 command_id 继续查。`,
  };
}
