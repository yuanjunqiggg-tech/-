// ============================================================
//  AI 模型管理 + 任意 OpenAI 兼容模型的聊天代理
// ============================================================
//
// 为什么需要这个：
//   Prism 内置的那个 AI 是写死的（prism自动，BaseURL 指向官方）。
//   用户要求「原本内置的那个 AI 我们可以自己选、自己添加」。
//
//   所以这里做两件事：
//     1. 模型注册表（D1）—— 用户可增删改任意 OpenAI 兼容的模型
//     2. 聊天代理 —— 网关拿着用户存的 key 去调对应厂商，
//        密钥不出云端，被控端和控制端都不用各自配一遍
//
// 安全：
//   · 列表接口永远不返回完整 api_key，只给前 4 位 + 掩码
//   · 所有接口走管理密钥鉴权（除 chat 可按需要放开）
// ============================================================

export interface AiModel {
  id: string;
  name: string;          // 显示名，如「DeepSeek-V3」
  base_url: string;      // 如 https://api.deepseek.com/v1
  api_key: string;
  model: string;         // 如 deepseek-chat
  is_default: number;    // 0/1
  created_at: number;
}

/** 对外返回时脱敏，绝不带完整密钥 */
function mask(m: AiModel | any) {
  const k = m.api_key || '';
  return {
    id: m.id,
    name: m.name,
    base_url: m.base_url,
    model: m.model,
    is_default: !!m.is_default,
    created_at: m.created_at,
    api_key_hint: k ? k.slice(0, 4) + '****' + k.slice(-2) : '',
  };
}

function newId(p: string) {
  return p + '_' + Math.random().toString(36).slice(2, 12) + Date.now().toString(36).slice(-4);
}

export const AI_MODELS_DDL = `
CREATE TABLE IF NOT EXISTS ai_models (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  base_url    TEXT NOT NULL,
  api_key     TEXT NOT NULL DEFAULT '',
  model       TEXT NOT NULL,
  is_default  INTEGER NOT NULL DEFAULT 0,
  created_at  INTEGER NOT NULL
);
`;

// ------------------------------------------------------------
// 列表
// ------------------------------------------------------------
export async function listModels(db: D1Database): Promise<Response> {
  const r = await db.prepare(
    'SELECT * FROM ai_models ORDER BY is_default DESC, created_at DESC'
  ).all<AiModel>();
  return json({ ok: true, data: { models: (r.results || []).map(mask) } });
}

// ------------------------------------------------------------
// 新增
// ------------------------------------------------------------
export async function createModel(db: D1Database, body: any): Promise<Response> {
  const name = String(body?.name || '').trim();
  const base_url = String(body?.base_url || '').trim().replace(/\/+$/, '');
  const model = String(body?.model || '').trim();
  const api_key = String(body?.api_key || '').trim();

  if (!name || !base_url || !model) {
    return json({ ok: false, error: 'name / base_url / model 必填' }, 400);
  }
  if (!/^https?:\/\//.test(base_url)) {
    return json({ ok: false, error: 'base_url 必须是 http(s) 开头' }, 400);
  }

  const id = newId('mdl');

  // 第一个模型自动设为默认；或用户显式指定
  const cnt = await db.prepare('SELECT COUNT(*) AS c FROM ai_models').first<any>();
  const wantDefault = body?.is_default === true || body?.is_default === 1 || !(cnt?.c > 0);

  if (wantDefault) {
    await db.prepare('UPDATE ai_models SET is_default = 0').run();
  }

  await db.prepare(
    'INSERT INTO ai_models (id,name,base_url,api_key,model,is_default,created_at) VALUES (?,?,?,?,?,?,?)'
  ).bind(id, name, base_url, api_key, model, wantDefault ? 1 : 0, Date.now()).run();

  return json({ ok: true, data: { id, is_default: wantDefault } });
}

// ------------------------------------------------------------
// 修改
// ------------------------------------------------------------
export async function updateModel(db: D1Database, id: string, body: any): Promise<Response> {
  const cur = await db.prepare('SELECT * FROM ai_models WHERE id = ?').bind(id).first<AiModel>();
  if (!cur) return json({ ok: false, error: '模型不存在' }, 404);

  // 允许改的字段；api_key 传空字符串表示「保持不变」
  const name = body?.name !== undefined ? String(body.name).trim() : cur.name;
  const base_url = body?.base_url !== undefined
    ? String(body.base_url).trim().replace(/\/+$/, '') : cur.base_url;
  const model = body?.model !== undefined ? String(body.model).trim() : cur.model;
  const api_key = body?.api_key ? String(body.api_key).trim() : cur.api_key;

  if (body?.is_default === true || body?.is_default === 1) {
    await db.prepare('UPDATE ai_models SET is_default = 0').run();
  }
  const isDefault = (body?.is_default === true || body?.is_default === 1)
    ? 1
    : (body?.is_default === false || body?.is_default === 0) ? 0 : cur.is_default;

  await db.prepare(
    'UPDATE ai_models SET name=?, base_url=?, api_key=?, model=?, is_default=? WHERE id=?'
  ).bind(name, base_url, api_key, model, isDefault, id).run();

  return json({ ok: true, data: { id } });
}

// ------------------------------------------------------------
// 删除
// ------------------------------------------------------------
export async function deleteModel(db: D1Database, id: string): Promise<Response> {
  const cur = await db.prepare('SELECT * FROM ai_models WHERE id = ?').bind(id).first<AiModel>();
  if (!cur) return json({ ok: false, error: '模型不存在' }, 404);

  await db.prepare('DELETE FROM ai_models WHERE id = ?').bind(id).run();

  // 删掉的是默认模型 → 随便挑一个顶上
  if (cur.is_default) {
    const next = await db.prepare(
      'SELECT id FROM ai_models ORDER BY created_at DESC LIMIT 1'
    ).first<any>();
    if (next?.id) {
      await db.prepare('UPDATE ai_models SET is_default=1 WHERE id=?').bind(next.id).run();
    }
  }
  return json({ ok: true, data: { id } });
}

// ------------------------------------------------------------
// 取默认模型（内部用，带完整 key）
// ------------------------------------------------------------
async function pickModel(db: D1Database, modelId?: string): Promise<AiModel | null> {
  if (modelId) {
    const m = await db.prepare('SELECT * FROM ai_models WHERE id = ?').bind(modelId).first<AiModel>();
    if (m) return m;
  }
  const d = await db.prepare(
    'SELECT * FROM ai_models WHERE is_default = 1 LIMIT 1'
  ).first<AiModel>();
  if (d) return d;
  return await db.prepare(
    'SELECT * FROM ai_models ORDER BY created_at DESC LIMIT 1'
  ).first<AiModel>();
}

// ------------------------------------------------------------
// 聊天代理
// ------------------------------------------------------------
//
// ★ 重要：Prism 现在跑在云手机里，Cloudflare 直连不到它。
//   所以这里代理的是【用户在控制台配置的外部模型】，
//   而不是去连某台固定机器的 Prism。
//   想用 Prism 内置 AI，走的是「下发指令给被控端」那条路（/api/v1/devices/:id/command）。
//
export async function chatProxy(db: D1Database, body: any): Promise<Response> {
  const m = await pickModel(db, body?.model_id);
  if (!m) {
    return json({ ok: false, error: '还没有配置任何 AI 模型，请先在控制台添加一个' }, 400);
  }

  const messages = body?.messages;
  if (!Array.isArray(messages) || messages.length === 0) {
    return json({ ok: false, error: 'messages 必须是非空数组' }, 400);
  }

  const url = m.base_url.replace(/\/+$/, '') + '/chat/completions';
  const payload = {
    model: m.model,
    messages,
    stream: body?.stream !== false,
    temperature: body?.temperature ?? 0.7,
    max_tokens: body?.max_tokens ?? 2048,
  };

  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (m.api_key) headers['Authorization'] = 'Bearer ' + m.api_key;

  try {
    const upstream = await fetch(url, {
      method: 'POST',
      headers,
      body: JSON.stringify(payload),
    });

    // 流式：原样透传 SSE，控制端按 OpenAI 格式解析即可
    if (payload.stream && upstream.body) {
      return new Response(upstream.body, {
        status: upstream.status,
        headers: {
          'Content-Type': 'text/event-stream; charset=utf-8',
          'Cache-Control': 'no-cache',
          'X-Model-Id': m.id,
          'X-Model-Name': m.name,
        },
      });
    }

    const txt = await upstream.text();
    let parsed: any;
    try { parsed = JSON.parse(txt); } catch { parsed = { raw: txt }; }
    return json(parsed, upstream.status);
  } catch (e: any) {
    return json({ ok: false, error: `调用模型失败：${e?.message || e}` , model: m.name }, 502);
  }
}

// ------------------------------------------------------------
function json(obj: any, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
  });
}
