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
 * ============================================================
 */

export interface Env {
  DB: D1Database;
  AI: Ai;
  API_PREFIX: string;
  PRISM_TUNNEL_URL: string;
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
  const auth = req.headers.get('Authorization') || '';
  const token = auth.replace(/^Bearer\s+/i, '').trim();
  return token.length > 0 && token === env.PLATFORM_ACCESS_KEY;
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

  // 构造转发给 Prism 的请求
  const upstreamBody = { ...body, messages: workingMessages };
  const targetUrl = `${env.PRISM_TUNNEL_URL}/api/ai/chat`;

  let upstream: Response;
  try {
    upstream = await fetch(targetUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        // 透传 Prism 需要的头（如有）
        ...(req.headers.get('X-Prism-Password')
          ? { 'X-Prism-Password': req.headers.get('X-Prism-Password')! }
          : {}),
      },
      body: JSON.stringify(upstreamBody),
    });
  } catch (e: any) {
    return fail(`无法连接 Prism 本地服务：${e?.message || e}`, 502);
  }

  if (!upstream.ok || !upstream.body) {
    const txt = await upstream.text().catch(() => '');
    return new Response(txt || 'Prism 返回错误', { status: upstream.status });
  }

  // ★ 用 TransformStream 逐块透传，并在结束时旁路入库
  const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
  const writer = writable.getWriter();
  const reader = upstream.body.getReader();
  const decoder = new TextDecoder();

  let collected = '';
  let usage = { input: 0, output: 0 };

  (async () => {
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        // 原样透传给客户端
        await writer.write(value);

        // 旁路解析用于统计（不阻塞）
        collected += decoder.decode(value, { stream: true });
      }
    } catch (e) {
      console.error('stream relay error:', e);
    } finally {
      // 解析 usage（ai_usage 事件）
      for (const block of collected.split('\n\n')) {
        if (!block.includes('ai_usage')) continue;
        const m = block.match(/data:\s*(\{.*\})/);
        if (!m) continue;
        try {
          const d = JSON.parse(m[1]);
          if (d.input) usage.input = Math.max(usage.input, d.input);
          if (d.output) usage.output = Math.max(usage.output, d.output);
        } catch { /* ignore */ }
      }

      // ★ 旁路写库
      await captureMessages(env, {
        sessionId,
        pluginId,
        modelName,
        messages: workingMessages,
        usage,
        templateId: template?.id,
      });

      await writer.close().catch(() => {});
    }
  })();

  return new Response(readable, {
    status: 200,
    headers: {
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive',
      'Access-Control-Allow-Origin': '*',
    },
  });
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

/** 健康检查 */
async function health(req: Request, env: Env): Promise<Response> {
  const targetUrl = `${env.PRISM_TUNNEL_URL}/api/config`;
  let prismOnline = false;
  let prismError = '';
  try {
    const r = await fetch(targetUrl, { method: 'GET' });
    prismOnline = r.ok;
    if (!r.ok) prismError = `HTTP ${r.status}`;
  } catch (e: any) {
    prismError = e?.message || String(e);
  }
  return ok({
    gateway: 'online',
    prism_tunnel_url: env.PRISM_TUNNEL_URL,
    prism_online: prismOnline,
    prism_error: prismError,
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
          'Access-Control-Allow-Headers': 'Content-Type, Authorization',
          'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
        },
      });
    }

    // 健康检查 / 状态（无需鉴权，便于面板探测）
    if (path === '/health' || path === '/api/v1/ai-assist/health') {
      return health(req, env);
    }

    // 其余全部要求鉴权
    if (!checkAuth(req, env)) {
      return fail('未授权：请提供正确的 Bearer 密钥', 401);
    }

    try {
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

      return fail(`未找到路由: ${path}`, 404);
    } catch (e: any) {
      console.error('handler error:', e);
      return fail(`服务器错误：${e?.message || e}`, 500);
    }
  },
};
