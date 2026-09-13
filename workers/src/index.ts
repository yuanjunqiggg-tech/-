/**
 * ============================================================
 * Ds Platform · AI 帮写 外部控制网关
 * Cloudflare Workers 入口
 *
 * 职责：
 *   1. 鉴权（平台访问密钥 / API Key）
 *   2. 把 /api/v1/ai-assist/chat 转发到 Prism 本地 /api/ai/chat
 *   3. ★ SSE 流式透传，同时旁路捕获完整 prompt 存入 D1
 *   4. ★ 提示词可编辑：启用模板时用平台版本替换 Prism 本地提示词
 *   5. 记录 token 消耗、请求日志
 *
 * 设计要点：
 *   - SSE 必须用 TransformStream 逐块转发，不能 await 全部读完再返回
 *   - 旁路捕获在流结束（flush）时写库，不阻塞响应
 *   - 提示词替换在请求发出前完成
 *   - 多设备中继：被控端(云手机) 主动外连领取指令，控制端远程下达
 *     详见 ./devices.ts
 * ============================================================
 */

import {
  deviceRegister, deviceHeartbeat, devicePoll, deviceReport,
  listDevices, getDevice, deleteDevice, patchDevice,
  pushCommand, getCommand, deviceStream, devicePackets,
  deviceSessions, deviceOverview,
} from './devices';
import { listModels, createModel, updateModel, deleteModel, chatProxy } from './models';
import { handleMcp } from './mcphttp';
import { runOnDevice, pickDevice, streamCommandSSE } from './relay';

/**
 * 构建标记。改代码时顺手改一下这个值，
 * 就能用 GET /api/v1/__build 确认线上跑的到底是哪一版 ——
 * 排查「部署了但没生效」时省大量时间。
 */
const BUILD_TAG = '2026-09-13-botkeeper-v1.4';

export interface Env {
  DB: D1Database;
  AI: Ai;
  API_PREFIX: string;
  /** @deprecated 2026-09-13 架构纠正：Prism 跑在云手机里，网关不再直连任何固定机器。
   *  仅保留兼容旧配置，新代码一律走 ./relay.ts 的设备中继。 */
  PRISM_TUNNEL_URL?: string;
  PLATFORM_ACCESS_KEY: string;
}

// ------------------------------------------------------------
// 工具函数
// ------------------------------------------------------------

/** 统一 JSON 响应 */
function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization',
      'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
    },
  });
}

function ok(data: unknown, msg?: string) {
  return json({ ok: true, data, message: msg });
}

function fail(msg: string, status = 400) {
  return json({ ok: false, error: msg }, status);
}

/** 计算内容指纹（用于提示词去重） */
async function fingerprint(text: string): Promise<string> {
  const buf = new TextEncoder().encode(text);
  const hash = await crypto.subtle.digest('SHA-256', buf);
  return Array.from(new Uint8Array(hash))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
    .slice(0, 16);
}

/** 从消息数组里识别系统提示词 */
function extractSystemPrompt(messages: any[]): string | null {
  if (!Array.isArray(messages)) return null;
  // Prism 可能把 system 放在第一条，也可能混在 user 里
  const sys = messages.find((m) => m && m.role === 'system');
  if (sys && typeof sys.content === 'string' && sys.content.length > 50) {
    return sys.content;
  }
  return null;
}

/** 校验访问密钥 */
function checkAuth(req: Request, env: Env): boolean {
  return tokenFromRequest(req) === env.PLATFORM_ACCESS_KEY;
}

/**
 * 取密钥：优先 Authorization 头，其次 ?key= 查询参数。
 *
 * ★ 为什么必须支持 query：很多 MCP 客户端（以及网页接入）只允许你填一个 URL，
 *   没法自定义请求头。不支持 query 的话用户根本配不进去。
 */
function tokenFromRequest(req: Request): string {
  const auth = req.headers.get('Authorization') || '';
  const hdr = auth.replace(/^Bearer\s+/i, '').trim();
  if (hdr) return hdr;
  try {
    return new URL(req.url).searchParams.get('key') || '';
  } catch {
    return '';
  }
}

// ------------------------------------------------------------
// ★ 提示词模板：查询是否有启用的模板，用于替换
// ------------------------------------------------------------
async function getActiveTemplate(
  env: Env,
  pluginId: string,
): Promise<{ id: number; content: string } | null> {
  const row = await env.DB.prepare(
    `SELECT id, content FROM prompt_templates
     WHERE enabled = 1
       AND (scope = 'global' OR (scope = 'plugin' AND plugin_id = ?))
     ORDER BY priority DESC, id DESC
     LIMIT 1`,
  )
    .bind(pluginId)
    .first<{ id: number; content: string }>();
  return row || null;
}

// ------------------------------------------------------------
// ★ 旁路捕获：记录完整消息到 D1
// ------------------------------------------------------------
async function captureMessages(
  env: Env,
  opts: {
    sessionId: string;
    pluginId: string;
    modelName: string;
    messages: any[];
    usage?: { input: number; output: number };
    templateId?: number;
  },
): Promise<void> {
  const { sessionId, pluginId, messages, usage, templateId } = opts;
  const now = Date.now();

  try {
    // 1. 确保会话存在
    await env.DB.prepare(
      `INSERT INTO ai_assist_sessions (id, plugin_id, model_name, title, message_count, created_at, updated_at)
       VALUES (?, ?, ?, ?, 0, ?, ?)
       ON CONFLICT(id) DO UPDATE SET updated_at = ?, model_name = ?`,
    )
      .bind(
        sessionId,
        pluginId,
        opts.modelName,
        sessionId,
        now,
        now,
        now,
        opts.modelName,
      )
      .run();

    // 2. 找出该会话已存的最大 seq，避免重复写入
    const maxRow = await env.DB.prepare(
      'SELECT COALESCE(MAX(seq), 0) AS maxSeq FROM ai_assist_messages WHERE session_id = ?',
    )
      .bind(sessionId)
      .first<{ maxSeq: number }>();
    let seq = maxRow?.maxSeq ?? 0;

    // 3. 写入消息（只写还未入库的尾部）
    const existing = await env.DB.prepare(
      'SELECT COUNT(*) AS c FROM ai_assist_messages WHERE session_id = ?',
    )
      .bind(sessionId)
      .first<{ c: number }>();
    const alreadyHave = existing?.c ?? 0;
    const toWrite = messages.slice(alreadyHave);

    let sysPrompt: string | null = null;

    for (const m of toWrite) {
      if (!m || typeof m !== 'object') continue;
      seq += 1;

      const isSys =
        m.role === 'system' && typeof m.content === 'string' && m.content.length > 50
          ? 1
          : 0;
      if (isSys) sysPrompt = m.content;

      await env.DB.prepare(
        `INSERT INTO ai_assist_messages
           (session_id, role, content, tool_calls, tool_results, is_system_prompt, seq, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      )
        .bind(
          sessionId,
          String(m.role || 'unknown'),
          typeof m.content === 'string' ? m.content : JSON.stringify(m.content ?? ''),
          m.tool_calls ? JSON.stringify(m.tool_calls) : null,
          m.tool_results ? JSON.stringify(m.tool_results) : null,
          isSys,
          seq,
          now,
        )
        .run();
    }

    // 4. 更新会话统计
    await env.DB.prepare(
      `UPDATE ai_assist_sessions
         SET message_count = message_count + ?,
             total_in  = total_in  + ?,
             total_out = total_out + ?,
             updated_at = ?
       WHERE id = ?`,
    )
      .bind(toWrite.length, usage?.input ?? 0, usage?.output ?? 0, now, sessionId)
      .run();

    // 5. ★ 提示词指纹存库（去重，便于「分出来」查看）
    if (sysPrompt) {
      const fp = await fingerprint(sysPrompt);
      await env.DB.prepare(
        `INSERT INTO prompt_captures
           (fingerprint, content, char_count, plugin_id, model_name, hit_count, first_seen, last_seen)
         VALUES (?, ?, ?, ?, ?, 1, ?, ?)
         ON CONFLICT(fingerprint) DO UPDATE SET
           hit_count = hit_count + 1,
           last_seen = ?`,
      )
        .bind(
          fp,
          sysPrompt,
          sysPrompt.length,
          pluginId,
          opts.modelName,
          now,
          now,
          now,
        )
        .run();
    }

    // 6. 记录请求日志
    await env.DB.prepare(
      `INSERT INTO request_log (model_name, tokens, in_tokens, out_tokens, endpoint, success, time)
       VALUES (?, ?, ?, ?, ?, 1, ?)`,
    )
      .bind(
        opts.modelName,
        (usage?.input ?? 0) + (usage?.output ?? 0),
        usage?.input ?? 0,
        usage?.output ?? 0,
        '/ai-assist/chat',
        now,
      )
      .run();
  } catch (e) {
    console.error('captureMessages failed:', e);
  }
}

// ------------------------------------------------------------
// ★ 核心：SSE 透传 + 旁路捕获
// ------------------------------------------------------------
async function handleChat(req: Request, env: Env): Promise<Response> {
  let body: any;
  try {
    body = await req.json();
  } catch {
    return fail('请求体不是合法 JSON');
  }

  const messages: any[] = body.messages || [];
  if (!messages.length) return fail('messages 不能为空');

  const pluginId: string = body.plugin_id || 'unknown';
  const sessionId: string = body.session_name || `sess_${Date.now()}`;
  const modelName: string = body.model_name || 'default';

  // ★ 提示词替换：若平台有启用的模板，则覆盖 Prism 本地 system 提示词
  const template = await getActiveTemplate(env, pluginId);
  let workingMessages = messages;
  if (template) {
    const sysIdx = messages.findIndex((m) => m && m.role === 'system');
    if (sysIdx >= 0) {
      workingMessages = messages.map((m, i) =>
        i === sysIdx ? { ...m, content: template.content } : m,
      );
    } else {
      // Prism 没传 system 时，主动插入平台模板
      workingMessages = [{ role: 'system', content: template.content }, ...messages];
    }
  }

  // ★ 2026-09-13 架构纠正：Prism 跑在云手机里，网关不再直连任何固定机器。
  //   这里把请求下发给被控端，被控端在云手机内 127.0.0.1:8080 调 Prism，
  //   再把流式事件回传；网关边轮询边转成 SSE 给控制台。
  const deviceId = body.device_id || undefined;

  const payload = {
    model_name: modelName,
    plugin_id: pluginId,
    mode: body.mode || '',
    session_name: sessionId,
    messages: workingMessages,
  };

  // 旁路入库（提示词捕获），不阻塞响应
  //   注意：这里只能捕获「发出去的」；被控端回传的 AI 全文由 device_events 承载
  captureMessages(env, {
    sessionId,
    pluginId,
    modelName,
    messages: workingMessages,
    templateId: template?.id,
  }).catch(() => {});

  return streamCommandSSE(env.DB, deviceId, payload);
}


// ------------------------------------------------------------
// 管理接口
// ------------------------------------------------------------

/** 会话列表 */
async function listSessions(env: Env, url: URL): Promise<Response> {
  const pluginId = url.searchParams.get('plugin_id');
  const limit = Math.min(parseInt(url.searchParams.get('limit') || '50'), 200);

  const stmt = pluginId
    ? env.DB.prepare(
        `SELECT * FROM ai_assist_sessions WHERE plugin_id = ?
         ORDER BY updated_at DESC LIMIT ?`,
      ).bind(pluginId, limit)
    : env.DB.prepare(
        `SELECT * FROM ai_assist_sessions ORDER BY updated_at DESC LIMIT ?`,
      ).bind(limit);

  const { results } = await stmt.all();
  return ok(results);
}

/** 会话消息 */
async function getMessages(env: Env, sessionId: string): Promise<Response> {
  const { results } = await env.DB.prepare(
    `SELECT * FROM ai_assist_messages WHERE session_id = ?
     ORDER BY seq ASC LIMIT 1000`,
  )
    .bind(sessionId)
    .all();
  return ok(results);
}

/** ★ 捕获到的提示词列表 */
async function listPrompts(env: Env): Promise<Response> {
  const { results } = await env.DB.prepare(
    `SELECT id, fingerprint, char_count, plugin_id, model_name,
            hit_count, first_seen, last_seen,
            substr(content, 1, 500) AS preview
     FROM prompt_captures ORDER BY last_seen DESC LIMIT 100`,
  ).all();
  return ok(results);
}

/** ★ 单条提示词全文 */
async function getPrompt(env: Env, id: string): Promise<Response> {
  const row = await env.DB.prepare(
    'SELECT * FROM prompt_captures WHERE id = ?',
  )
    .bind(id)
    .first();
  if (!row) return fail('未找到', 404);
  return ok(row);
}

/** ★ 提示词模板列表 */
async function listTemplates(env: Env): Promise<Response> {
  const { results } = await env.DB.prepare(
    'SELECT * FROM prompt_templates ORDER BY updated_at DESC LIMIT 100',
  ).all();
  return ok(results);
}

/** ★ 保存/更新提示词模板 */
async function saveTemplate(req: Request, env: Env): Promise<Response> {
  const b: any = await req.json().catch(() => null);
  if (!b || !b.name || typeof b.content !== 'string') {
    return fail('name 与 content 必填');
  }
  const now = Date.now();

  if (b.id) {
    await env.DB.prepare(
      `UPDATE prompt_templates
         SET name = ?, content = ?, scope = ?, plugin_id = ?,
             enabled = ?, priority = ?, version = version + 1, updated_at = ?
       WHERE id = ?`,
    )
      .bind(
        b.name,
        b.content,
        b.scope || 'global',
        b.plugin_id || null,
        b.enabled ? 1 : 0,
        b.priority ?? 0,
        now,
        b.id,
      )
      .run();
    return ok({ id: b.id }, '已更新');
  }

  const r = await env.DB.prepare(
    `INSERT INTO prompt_templates
       (scope, plugin_id, name, content, enabled, priority, version, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)`,
  )
    .bind(
      b.scope || 'global',
      b.plugin_id || null,
      b.name,
      b.content,
      b.enabled ? 1 : 0,
      b.priority ?? 0,
      now,
      now,
    )
    .run();
  return ok({ id: r.meta.last_row_id }, '已创建');
}

/** 删除模板 */
async function deleteTemplate(env: Env, id: string): Promise<Response> {
  await env.DB.prepare('DELETE FROM prompt_templates WHERE id = ?').bind(id).run();
  return ok(null, '已删除');
}

/** 从捕获的提示词一键转成模板 */
async function promoteToTemplate(req: Request, env: Env): Promise<Response> {
  const b: any = await req.json().catch(() => null);
  if (!b?.capture_id) return fail('capture_id 必填');

  const cap = await env.DB.prepare(
    'SELECT * FROM prompt_captures WHERE id = ?',
  )
    .bind(b.capture_id)
    .first<any>();
  if (!cap) return fail('未找到该提示词', 404);

  const now = Date.now();
  const r = await env.DB.prepare(
    `INSERT INTO prompt_templates
       (scope, plugin_id, name, content, enabled, priority, version, created_at, updated_at)
     VALUES ('plugin', ?, ?, ?, 0, 0, 1, ?, ?)`,
  )
    .bind(
      cap.plugin_id,
      `来自抓取 #${cap.id}`,
      cap.content,
      now,
      now,
    )
    .run();
  return ok({ id: r.meta.last_row_id }, '已转为模板（默认未启用）');
}

/** 统计概览 */
async function stats(env: Env): Promise<Response> {
  const [sessions, msgs, prompts, today] = await Promise.all([
    env.DB.prepare('SELECT COUNT(*) AS c FROM ai_assist_sessions').first(),
    env.DB.prepare('SELECT COUNT(*) AS c FROM ai_assist_messages').first(),
    env.DB.prepare('SELECT COUNT(*) AS c FROM prompt_captures').first(),
    env.DB.prepare(
      `SELECT COALESCE(SUM(tokens),0) AS tokens, COUNT(*) AS reqs
       FROM request_log WHERE time > ?`,
    )
      .bind(Date.now() - 86400000)
      .first(),
  ]);
  return ok({
    sessions: (sessions as any)?.c ?? 0,
    messages: (msgs as any)?.c ?? 0,
    prompts: (prompts as any)?.c ?? 0,
    today_tokens: (today as any)?.tokens ?? 0,
    today_requests: (today as any)?.reqs ?? 0,
  });
}

// ------------------------------------------------------------
// ★ MCP 中转（手机 Codex / 异地电脑接入）
//
// 原理：Prism 的原生工具在它进程内执行，没有独立 HTTP 端点。
//      本网关提供 /api/v1/mcp/tool，接收 {tool_name, arguments}，
//      改写成一次 /api/ai/chat 请求驱动 Prism 的 AI 发起该工具调用，
//      再从 SSE 流里截取 ai_tool_done 的真实结果返回。
//      MCP 客户端（Codex）只需对这一个端点发 POST 即可。
// ------------------------------------------------------------

/** 解析 SSE 文本，抽取工具执行结果 */
function parseToolFromSSE(sse: string): {
  found: boolean;
  tool?: string;
  result?: unknown;
  is_error?: boolean;
  executed?: boolean;
  ai_text?: string;
  error?: string;
} {
  const blocks = sse.split('\n\n');
  let lastTool: any = null;
  let aiText = '';
  let aiError = '';

  for (const block of blocks) {
    let ev = '';
    let payload: any = null;
    for (const line of block.split('\n')) {
      if (line.startsWith('event:')) ev = line.slice(6).trim();
      else if (line.startsWith('data:')) {
        try {
          payload = JSON.parse(line.slice(5).trim());
        } catch {
          payload = { raw: line.slice(5).trim() };
        }
      }
    }
    if (!ev) continue;
    if (ev === 'ai_tool_done') lastTool = payload;
    else if (ev === 'ai_chunk' && payload?.text) aiText += payload.text;
    else if (ev === 'ai_error') aiError = payload?.error || 'AI 报错';
  }

  if (aiError) return { found: false, error: aiError, ai_text: aiText };
  if (!lastTool) return { found: false, ai_text: aiText };

  let parsed: unknown = lastTool.result;
  if (typeof parsed === 'string') {
    try {
      parsed = JSON.parse(parsed);
    } catch {
      /* 保留原字符串 */
    }
  }
  return {
    found: true,
    tool: lastTool.name,
    result: parsed,
    is_error: !!lastTool.is_error,
    executed: lastTool.evidence === 'executed',
    ai_text: aiText.slice(0, 800),
  };
}

/**
 * 驱动云手机里 Prism 的 AI 调用一个工具。
 *
 * ★ 走设备中继，不再直连任何固定机器的隧道。
 *   被控端收到 kind=tool 后会用「系统提示词强制 tool_calls」的方式让 Prism
 *   的内置 AI 去调这个工具，并把 ai_tool_done 的 result 回传。
 */
async function driveTool(
  env: Env,
  toolName: string,
  toolArgs: Record<string, unknown>,
  opts: { deviceId?: string; sessionName?: string; timeoutMs?: number } = {},
): Promise<Response> {
  const r = await runOnDevice(
    env.DB,
    opts.deviceId,
    'tool',
    { tool_name: toolName, arguments: toolArgs || {} },
    { timeoutMs: opts.timeoutMs ?? 45_000, sessionId: opts.sessionName },
  );

  if (r.timeout) {
    return json({ ok: false, pending: true, command_id: r.command_id, error: r.error }, 504);
  }
  if (!r.ok) {
    return json({ ok: false, error: r.error || '被控端执行失败', command_id: r.command_id });
  }

  // 被控端回传的信封是 { ok, tool, executed, result, ai_comment }
  //   ★ 不要只取 res.result 就把 tool / executed 丢了 —— 外层调用方要靠它们判断成败
  const res = r.result || {};
  return json({
    ok: res.ok !== undefined ? !!res.ok && !res.is_error : true,
    tool: res.tool || toolName,
    executed: res.executed !== false,
    result: res.result !== undefined ? res.result : res,
    ai_comment: res.ai_comment || null,
    device_id: r.device_id,
    device_name: r.device_name,
    command_id: r.command_id,
  });
}

/**
 * 直连云手机里 Prism 的一个 REST 端点（状态/模型/插件等）。
 * 同样走设备中继（kind=prism_rest）。
 */
async function prismPassthrough(
  env: Env,
  subPath: string,
  method = 'GET',
  body?: unknown,
  deviceId?: string,
): Promise<Response> {
  const r = await runOnDevice(env.DB, deviceId, 'prism_rest', {
    path: subPath,
    method,
    body,
  });

  if (r.timeout) {
    return json({ ok: false, pending: true, command_id: r.command_id, error: r.error }, 504);
  }
  if (!r.ok) {
    return json({ ok: false, error: r.error || 'Prism 不可达', command_id: r.command_id }, 502);
  }
  return json({ ok: true, device_id: r.device_id, data: r.result });
}


/** MCP 工具目录（供客户端发现） */
function mcpToolCatalog(): Response {
  return ok({
    endpoint: 'POST /api/v1/mcp/tool',
    usage: '{"tool_name":"list_packets","arguments":{}}',
    local: [
      { name: 'status', desc: '机器人状态' },
      { name: 'models', desc: '模型列表' },
      { name: 'skills', desc: '技能库列表' },
      { name: 'plugins', desc: '插件列表' },
    ],
    packet: [
      { name: 'packet_history', desc: '历史抓包回看' },
      { name: 'packet_subscribe', desc: '实时抓包订阅（长轮询）' },
      { name: 'packet_send', desc: '发包' },
    ],
    native: '任意 Prism 原生工具名（list_packets / query_packets / send_packet / game_call / write_plugin_file ...）',
  });
}

/** 实时抓包订阅（网关侧长轮询，适合手机端） */
async function packetSubscribe(req: Request, env: Env): Promise<Response> {
  let b: any = {};
  try {
    b = await req.json();
  } catch {
    /* 允许空 body */
  }
  const duration = Math.min(Math.max(parseInt(b.duration ?? '10', 10) || 10, 1), 60);
  const ptype = (b.packet_type || '').toString();
  const collected: unknown[] = [];
  const deadline = Date.now() + duration * 1000;
  let rounds = 0;

  while (Date.now() < deadline && rounds < 30) {
    rounds++;
    const wargs: Record<string, unknown> = { seconds: 3 };
    if (ptype) wargs.packet_type = ptype;

    const resp = await driveTool(env, 'wait_packet', wargs);
    const data: any = await resp.clone().json().catch(() => null);
    if (data?.ok && data.result) {
      collected.push(data.result);
    } else if (collected.length === 0 && data && !data.ok) {
      return json({
        ok: false,
        error: data.error || '抓包失败',
        hint: '机器人可能未连接服务器，先调 status 确认 connected',
      });
    }
  }

  return ok({
    action: 'subscribe',
    duration,
    packet_type: ptype || '(全部)',
    rounds,
    captured: collected.length,
    packets: collected.slice(0, 100),
  });
}

/**
 * 健康检查
 * ★ 不再探测任何固定隧道，改为汇报「云端被控端」的在线情况。
 */
async function health(req: Request, env: Env): Promise<Response> {
  let devices: any[] = [];
  let online = 0;
  try {
    const r = await env.DB.prepare(
      'SELECT id, name, platform, status, last_seen FROM devices ORDER BY last_seen DESC LIMIT 50',
    ).all<any>();
    const now = Date.now();
    devices = (r.results || []).map((d: any) => {
      const on = d.status === 1 && now - (d.last_seen || 0) < 90_000;
      if (on) online++;
      return {
        id: d.id,
        name: d.name,
        platform: d.platform,
        online: on,
        last_seen_ago_sec: Math.floor((now - (d.last_seen || 0)) / 1000),
      };
    });
  } catch (e: any) {
    /* 表还没建时不要 500 */
  }

  return ok({
    gateway: 'online',
    mode: 'cloud-relay',
    note: 'Prism 跑在云手机内，被控端主动外连本网关；不依赖任何固定机器的隧道',
    devices_online: online,
    devices_total: devices.length,
    devices: devices.slice(0, 20),
    mcp_endpoint: '/mcp',
    time: new Date().toISOString(),
  });
}

// ------------------------------------------------------------
// 入口
// ------------------------------------------------------------
export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const path = url.pathname;

    // CORS 预检
    if (req.method === 'OPTIONS') {
      return new Response(null, {
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-Device-Id, X-Device-Token',
          'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
        },
      });
    }

    // 健康检查 / 状态（无需鉴权，便于面板探测）
    //   /health               —— 网关存活 + Prism 隧道可达性
    //   /api/v1/health        —— 同上（带前缀，供前端统一调用）
    //   /api/v1/ai-assist/health —— 兼容旧路径
    if (path === '/health' || path === '/api/v1/health' || path === '/api/v1/ai-assist/health') {
      return health(req, env);
    }

    // 构建标记：用来确认线上跑的到底是哪一版（排查部署没生效时非常有用）
    if (path === '/api/v1/__build') {
      return ok({ build: BUILD_TAG, features: ['bot_keeper', 'prism_status', 'mcp_v1'] });
    }

    // --------------------------------------------------------
    // ★ 被控端 API（云手机 App 调用，用设备 token 鉴权，不用管理密钥）
    //   所以这部分必须在 checkAuth 之前分流
    // --------------------------------------------------------
    if (path === '/api/v1/device/register' && req.method === 'POST') {
      return deviceRegister(req, env);
    }
    if (path === '/api/v1/device/heartbeat' && req.method === 'POST') {
      return deviceHeartbeat(req, env);
    }
    if (path === '/api/v1/device/poll' && req.method === 'POST') {
      return devicePoll(req, env);
    }
    if (path === '/api/v1/device/report' && req.method === 'POST') {
      return deviceReport(req, env);
    }

    // --------------------------------------------------------
    // ★ MCP over HTTP —— 外部 AI Agent 的接入端点
    //   支持 ?key= 传鉴权（客户端只能填 URL 的场景），所以单独鉴权
    //   地址：https://ai-api.youyuanqi.dpdns.org/mcp?key=<平台密钥>
    // --------------------------------------------------------
    if (path === '/mcp' || path === '/api/v1/mcp' || path === '/api/v1/mcp/rpc') {
      if (!checkAuth(req, env)) {
        return fail('未授权：MCP 端点需要 ?key=<平台密钥> 或 Authorization: Bearer <密钥>', 401);
      }
      return handleMcp(req, env);
    }

    // 其余全部要求鉴权
    if (!checkAuth(req, env)) {
      return fail('未授权：请提供正确的 Bearer 密钥', 401);
    }

    try {
      // --------------------------------------------------------
      // ★ 控制端 · 设备管理 API
      // --------------------------------------------------------
      if (path === '/api/v1/devices' && req.method === 'GET') {
        return listDevices(req, env, url);
      }
      if (path === '/api/v1/devices/overview' && req.method === 'GET') {
        return deviceOverview(req, env);
      }
      const devMatch = path.match(/^\/api\/v1\/devices\/([^/]+)(\/.*)?$/);
      if (devMatch) {
        const devId = decodeURIComponent(devMatch[1]);
        const sub = devMatch[2] || '';

        if (sub === '' && req.method === 'GET') return getDevice(req, env, devId);
        if (sub === '' && req.method === 'DELETE') return deleteDevice(req, env, devId, url);
        if (sub === '' && req.method === 'PATCH') return patchDevice(req, env, devId);

        if (sub === '/command' && req.method === 'POST') return pushCommand(req, env, devId);
        if (sub === '/stream' && req.method === 'GET') return deviceStream(req, env, devId, url);
        if (sub === '/packets' && req.method === 'GET') return devicePackets(req, env, devId, url);
        if (sub === '/sessions' && req.method === 'GET') return deviceSessions(req, env, devId);

        const cmdMatch = sub.match(/^\/command\/([^/]+)$/);
        if (cmdMatch && req.method === 'GET') {
          return getCommand(req, env, devId, decodeURIComponent(cmdMatch[1]));
        }
      }

      // ★ 核心：AI 对话
      if (path === '/api/v1/ai-assist/chat' && req.method === 'POST') {
        return handleChat(req, env);
      }

      // 会话
      if (path === '/api/v1/ai-assist/sessions' && req.method === 'GET') {
        return listSessions(env, url);
      }
      const msgMatch = path.match(/^\/api\/v1\/ai-assist\/sessions\/([^/]+)\/messages$/);
      if (msgMatch && req.method === 'GET') {
        return getMessages(env, decodeURIComponent(msgMatch[1]));
      }

      // 提示词（抓取）
      if (path === '/api/v1/ai-assist/prompts' && req.method === 'GET') {
        return listPrompts(env);
      }
      const pMatch = path.match(/^\/api\/v1\/ai-assist\/prompts\/(\d+)$/);
      if (pMatch && req.method === 'GET') {
        return getPrompt(env, pMatch[1]);
      }

      // 提示词模板（可编辑）
      if (path === '/api/v1/ai-assist/templates' && req.method === 'GET') {
        return listTemplates(env);
      }
      if (path === '/api/v1/ai-assist/templates' && req.method === 'POST') {
        return saveTemplate(req, env);
      }
      const tMatch = path.match(/^\/api\/v1\/ai-assist\/templates\/(\d+)$/);
      if (tMatch && req.method === 'DELETE') {
        return deleteTemplate(env, tMatch[1]);
      }
      if (path === '/api/v1/ai-assist/templates/promote' && req.method === 'POST') {
        return promoteToTemplate(req, env);
      }

      // 统计
      if (path === '/api/v1/ai-assist/stats' && req.method === 'GET') {
        return stats(env);
      }

      // --------------------------------------------------------
      // ★ AI 模型管理（用户自己选、自己添加）
      // --------------------------------------------------------
      if (path === '/api/v1/models' && req.method === 'GET') {
        return listModels(env.DB);
      }
      if (path === '/api/v1/models' && req.method === 'POST') {
        let b: any = {};
        try { b = await req.json(); } catch { return fail('请求体必须是 JSON'); }
        return createModel(env.DB, b);
      }
      const mMatch = path.match(/^\/api\/v1\/models\/([^/]+)$/);
      if (mMatch) {
        const mid = decodeURIComponent(mMatch[1]);
        if (req.method === 'PUT' || req.method === 'PATCH') {
          let b: any = {};
          try { b = await req.json(); } catch { return fail('请求体必须是 JSON'); }
          return updateModel(env.DB, mid, b);
        }
        if (req.method === 'DELETE') return deleteModel(env.DB, mid);
      }

      // ★ 用控制台配置的模型聊天（密钥只在云端，不落客户端）
      if (path === '/api/v1/chat' && req.method === 'POST') {
        let b: any = {};
        try { b = await req.json(); } catch { return fail('请求体必须是 JSON'); }
        return chatProxy(env.DB, b);
      }

      // --------------------------------------------------------
      // ★ MCP 中转路由（Codex / 手机端接入）
      // --------------------------------------------------------
      if (path === '/api/v1/mcp/tools' && req.method === 'GET') {
        return mcpToolCatalog();
      }

      // ------------------------------------------------------------
      // Prism 引擎自检（控制台「设备」页用）
      // 查的是被控端所在机器里 Prism 本体的状态：装没装、8080 活不活
      // ------------------------------------------------------------
      if (path === '/api/v1/prism/status' && (req.method === 'POST' || req.method === 'GET')) {
        let b: any = {};
        try { b = await req.json(); } catch { /* GET 无体 */ }
        const r = await runOnDevice(env.DB, b.device_id, 'prism_status', {});
        return ok(r);
      }

      // ------------------------------------------------------------
      // 机器人连接守护（控制台「设备」页的开关）
      //   POST /api/v1/bot/keeper  {action, mode, interval_sec, device_id}
      //   Prism 的 AI帮写 自己不会重连，这层补上。
      // ------------------------------------------------------------
      if (path === '/api/v1/bot/keeper' && req.method === 'POST') {
        let b: any = {};
        try { b = await req.json(); } catch { /* 允许空体 */ }
        const act = (b.action || 'status').toString().toLowerCase();
        if (!['status', 'set', 'connect', 'probe', 'interval'].includes(act)) {
          return fail('action 只支持 status/set/connect/probe/interval');
        }
        if (act === 'set' && !['off', 'once', 'always'].includes((b.mode || '').toString())) {
          return fail('mode 只支持 off/once/always');
        }
        const r = await runOnDevice(env.DB, b.device_id, 'bot_keeper', {
          action: act,
          mode: b.mode,
          interval_sec: b.interval_sec,
        });
        return ok(r);
      }

      // ------------------------------------------------------------
      // AI帮写 会话（数据存在 Prism 自己的存储里，不是网页的）
      // ------------------------------------------------------------
      if (path === '/api/v1/prism/sessions' && req.method === 'POST') {
        let b: any = {};
        try { b = await req.json(); } catch { return fail('请求体必须是 JSON'); }
        const act = (b.action || 'list').toString().toLowerCase();
        const map: Record<string, string> = {
          list: 'session_list', load: 'session_load',
          save: 'session_save', delete: 'session_delete',
        };
        const kind = map[act];
        if (!kind) return fail('action 只支持 list/load/save/delete');
        const r = await runOnDevice(env.DB, b.device_id, kind, {
          session_name: b.session_name,
          messages: b.messages,
          plugin_id: b.plugin_id,
          recent: !!b.recent,
        });
        return ok(r);
      }

      // 通用工具调用入口：驱动 Prism AI 执行任意工具
      if (path === '/api/v1/mcp/tool' && req.method === 'POST') {
        let b: any = {};
        try {
          b = await req.json();
        } catch {
          return fail('请求体必须是 JSON');
        }
        const tn = b.tool_name || b.name;
        if (!tn) return fail('缺少 tool_name');

        // 目标设备（不填就用最近在线的那台）
        const devId: string | undefined = b.device_id || undefined;

        // Prism 本地 REST 直通类（经被控端中继）
        if (tn === 'status') return prismPassthrough(env, '/api/bot/status', 'GET', undefined, devId);
        if (tn === 'models') return prismPassthrough(env, '/api/ai/models', 'GET', undefined, devId);
        if (tn === 'skills') return prismPassthrough(env, '/api/ai/skills', 'GET', undefined, devId);
        if (tn === 'plugins') return prismPassthrough(env, '/api/plugin/list', 'GET', undefined, devId);
        if (tn === 'packet_history') {
          const act = b.arguments?.action || 'list';
          if (act === 'list') return driveTool(env, 'list_packets', {}, { deviceId: devId });
          if (act === 'stats') return driveTool(env, 'packet_stats', {}, { deviceId: devId });
          return driveTool(env, 'query_packets', {
            limit: b.arguments?.limit ?? 50,
            ...(b.arguments?.packet_type ? { type: b.arguments.packet_type } : {}),
          }, { deviceId: devId });
        }
        if (tn === 'packet_send') {
          return driveTool(env, 'send_packet', {
            type: b.arguments?.packet_type,
            data: b.arguments?.data || {},
          }, { deviceId: devId });
        }

        // 其余一律视为 Prism 原生工具名
        return driveTool(env, tn, b.arguments || {}, {
          deviceId: devId,
          sessionName: b.session_name,
        });
      }

      // 实时抓包订阅
      if (path === '/api/v1/mcp/packet/subscribe' && req.method === 'POST') {
        return packetSubscribe(req, env);
      }

      // --------------------------------------------------------
      // 运维：清理腐烂的指令 + 过期事件
      //   GET/POST /api/v1/admin/cleanup?minutes=60
      //   被控端掉线时指令会卡在 pending/taken，不清理会一直堆积
      // --------------------------------------------------------
      if (path === '/api/v1/admin/cleanup') {
        const mins = Math.min(
          Math.max(parseInt(url.searchParams.get('minutes') || '60', 10) || 60, 1),
          60 * 24 * 7,
        );
        const cutoff = Date.now() - mins * 60_000;

        const stale = await env.DB.prepare(
          `UPDATE device_commands
             SET status='failed', error='超时未执行（自动清理）', finished_at=?
           WHERE status IN ('pending','taken') AND created_at < ?`,
        )
          .bind(Date.now(), cutoff)
          .run();

        // 事件流只保留 7 天，避免 D1 无限膨胀
        const evCut = Date.now() - 7 * 24 * 3600_000;
        const ev = await env.DB.prepare('DELETE FROM device_events WHERE created_at < ?')
          .bind(evCut)
          .run();

        // ------------------------------------------------------
        // 僵尸设备清理（可选，默认不做）
        //   /api/v1/admin/cleanup?devices=1&offline_minutes=1440
        // 开发期间反复注册会留下一堆假在线的设备，控制台看着很乱。
        // 默认 24h 才删，很保守：真被控端断了超过一天，重开也会重新注册。
        // ------------------------------------------------------
        let deadDevices = 0;
        if (url.searchParams.get('devices') === '1') {
          const offMins = Math.min(
            Math.max(parseInt(url.searchParams.get('offline_minutes') || '1440', 10) || 1440, 1),
            60 * 24 * 30,
          );
          const offCut = Date.now() - offMins * 60_000;
          await env.DB.prepare('DELETE FROM device_events WHERE device_id IN (SELECT id FROM devices WHERE last_seen < ?)')
            .bind(offCut)
            .run();
          await env.DB.prepare('DELETE FROM device_commands WHERE device_id IN (SELECT id FROM devices WHERE last_seen < ?)')
            .bind(offCut)
            .run();
          const dd = await env.DB.prepare('DELETE FROM devices WHERE last_seen < ?')
            .bind(offCut)
            .run();
          deadDevices = dd.meta?.changes ?? 0;
        }

        return ok({
          stale_commands_closed: stale.meta?.changes ?? 0,
          old_events_deleted: ev.meta?.changes ?? 0,
          dead_devices_deleted: deadDevices,
          cutoff_minutes: mins,
        }, '清理完成');
      }

      return fail(`未找到路由: ${path}`, 404);
    } catch (e: any) {
      console.error('handler error:', e);
      return fail(`服务器错误：${e?.message || e}`, 500);
    }
  },
};
