// ============================================================
//  MCP over HTTP —— 给外部 AI Agent（Codex / Claude / 任意）用的端点
// ============================================================
//
//  外部 Agent 只要在它的 MCP 配置里填这一行就能操控云手机里的 Prism：
//
//      https://ai-api.youyuanqi.dpdns.org/mcp?key=<平台密钥>
//
//  协议：JSON-RPC 2.0，单端点 POST。
//  实现：MCP 2024-11-05 + 2025-06-18 兼容（initialize / tools/list / tools/call）。
//
//  鉴权两种都支持：
//    · Authorization: Bearer <key>
//    · ?key=<key>
//  因为很多 MCP 客户端只会让你填 URL，所以必须支持 query 传 key。
// ============================================================

import { runOnDevice, pickDevice } from './relay';
import { listModels, chatProxy } from './models';

export const MCP_PROTOCOL_VERSION = '2024-11-05';
export const MCP_SERVER_INFO = { name: 'prism-remote', version: '1.0.0' };

// ------------------------------------------------------------
// 工具定义（对外的能力清单）
// ------------------------------------------------------------
const TOOLS: any[] = [
  {
    name: 'list_devices',
    description:
      '列出所有已注册的被控端（云手机）。返回设备 id、名称、是否在线、最后心跳时间。' +
      '调用 prism_* 系列工具前可以先看这个确认设备在线。',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'prism_chat',
    description:
      '让云手机里 Prism 的内置 AI 跑一段对话（走 Prism 自己的模型和工具链）。' +
      '这是驱动 Prism 干活的主入口。prompt 写清楚要它做什么。',
    inputSchema: {
      type: 'object',
      properties: {
        prompt: { type: 'string', description: '要让 Prism AI 做的事（自然语言）' },
        device_id: { type: 'string', description: '可选，指定设备；不填用最近在线的那台' },
        session_name: { type: 'string', description: '可选，会话名，用于连续追问' },
        timeout_ms: { type: 'number', description: '可选，等待上限，默认 45000' },
      },
      required: ['prompt'],
    },
  },
  {
    name: 'prism_tool',
      description:
        '⚠ 这个工具是「让 Prism 内置 AI 帮你调工具」，中间隔了一层 AI。\n' +
        '  它的身份是「插件开发助手」，经常会拒绝执行、或干脆不发起 tool_call，' +
        '  返回 executed=false。\n' +
        '★ 想直接操作，优先用 prism_rest（自己就是执行者，不经任何 AI）。\n' +
        '  只有 prism_rest 里找不到对应端点时，才退回用这个。\n' +
        '\n' +
        '调用 Prism 内置的某个工具（共 29 个）。工具在 Prism 进程内执行。' +
        '不传 device_id 时用最近在线的设备。\n' +
        '★ 这是权限最大的一个工具，等于把 Prism 的能力整个交给外部 AI：\n' +
        '  · write_plugin_file / lua_call —— 改写 Prism 的插件与底层行为\n' +
        '  · game_call / send_command_wait_output —— 直接操作游戏内\n' +
        '  · system_shell —— 在云主机上跑 shell 命令【高危】\n' +
        '  · read_file / write_file / edit_lines / list_dir —— 读写云主机文件\n' +
        '  · listen_packet / send_packet / query_packets —— 抓包与发包\n' +
        '调用前确认这是你想要的；密钥等同于这些权限，别外泄。',
    inputSchema: {
      type: 'object',
      properties: {
        tool_name: { type: 'string', description: 'Prism 工具名，例如 list_packets' },
        arguments: { type: 'object', description: '工具参数（JSON 对象）' },
        device_id: { type: 'string', description: '可选，指定设备' },
        timeout_ms: { type: 'number', description: '可选，等待上限，默认 45000' },
      },
      required: ['tool_name'],
    },
  },
  {
    name: 'prism_rest',
    description:
      '★ 直接操作 Prism 的主通道 —— 不经任何 AI，你自己就是执行者。\n' +
      'Prism 有一百多个本机 REST 端点，绝大多数能力都在这里，支持任意 HTTP 方法。\n' +
      '\n' +
      '【直接操作机器人 / 游戏】\n' +
      '  POST /api/bot/console        {"input":"say 你好"}  ← 给机器人发命令\n' +
      '  POST /api/bot/connect        {"token","server","use_new_protocol","auth","password"} ← 连机器人\n' +
      '  GET  /api/bot/status         机器人连没连、在哪个服、是不是 OP\n' +
      '  POST /api/mcfunction/execute {"content","global","groups","tests"} ← 批量执行指令\n' +
      '  GET  /api/mcfunction/status  执行进度\n' +
      '【移动 / 飞行】/api/fly/start|stop|jump|down|look|move|teleport|position|sprint-start…\n' +
      '【插件】/api/plugin/list|run|stop|reload|delete|import|export|create|config\n' +
      '        POST /api/plugin/run {"id":"插件id"}\n' +
      '        GET  /api/plugin/file/read?id=..&scope=code|docs&file=..\n' +
      '        POST /api/plugin/file/write\n' +
      '【文件】/api/files/scan|read|write\n' +
      '【任务】/api/task/list|start|stop|resume|delete    GET /api/task/list\n' +
      '【节点】/api/node/status|start|stop\n' +
      '【AI帮写会话】/api/ai/sessions（GET 列表 / POST 保存 / DELETE 删除）\n' +
      '              /api/ai/sessions/load /recent /rename\n' +
      '【模型】/api/ai/models、/api/ai/models/fetch\n' +
      '【地图绘制】/api/draw/create|stroke|apply|state|undo|redo|palette\n' +
      '【音乐】/api/music/play|stop|note|queue|upload\n' +
      '【皮肤/相机/预览】/api/skin/*、/api/camera/*、/api/preview/*\n' +
      '\n' +
      '调用前先 GET /api/bot/status 确认机器人状态；写操作要谨慎，直接影响云手机。',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: '如 /api/bot/console' },
        method: { type: 'string', description: 'GET / POST / DELETE，默认 GET' },
        body: { type: 'object', description: 'POST/DELETE 时的 JSON 请求体' },
        device_id: { type: 'string', description: '可选，指定设备' },
      },
      required: ['path'],
    },
  },
  {
    name: 'packet_history',
    description: '查看抓包历史（从云端抓包表查）。action 可选 list / stats / query。',
    inputSchema: {
      type: 'object',
      properties: {
        action: { type: 'string', description: 'list | stats | query，默认 list' },
        limit: { type: 'number', description: '条数，默认 50' },
        packet_type: { type: 'string', description: '按类型过滤（query 时有效）' },
        device_id: { type: 'string', description: '可选，指定设备' },
      },
      required: [],
    },
  },
  {
    name: 'packet_send',
    description: '通过 Prism 发一个包。',
    inputSchema: {
      type: 'object',
      properties: {
        packet_type: { type: 'string', description: '包类型' },
        data: { type: 'object', description: '包内容' },
        device_id: { type: 'string', description: '可选，指定设备' },
      },
      required: ['packet_type'],
    },
  },
  {
    name: 'prism_session',
    description:
      '管理 Prism 内置「AI帮写」的会话记录 —— 这些记录存在 Prism 自己的存储里，' +
      '用户在 APK 里打开 AI帮写 能看到同一份。action：\n' +
      '  list   列出会话（recent=true 只看最近）\n' +
      '  load   读取某个会话的完整对话\n' +
      '  save   写入/覆盖一个会话\n' +
      '  delete 删除一个会话\n' +
      '配合 prism_chat 的 session_name，就能让 AI Agent 的对话在 Prism 里长期留存。',
    inputSchema: {
      type: 'object',
      properties: {
        action: { type: 'string', description: 'list | load | save | delete' },
        session_name: { type: 'string', description: '会话名（load/save/delete 必填）' },
        messages: { type: 'array', description: 'save 时的消息数组 [{role,content}]' },
        plugin_id: { type: 'string', description: '可选，按插件过滤' },
        recent: { type: 'boolean', description: 'list 时是否只看最近' },
        device_id: { type: 'string', description: '可选，指定设备' },
      },
      required: ['action'],
    },
  },
  {
    name: 'prism_status',
    description:
      '检查云手机里 Prism 引擎的状态：APK 是否安装、8080 是否响应、机器人是否已连接。' +
      '指令超时/失败时先调这个定位是 Prism 挂了还是网络问题。',
    inputSchema: {
      type: 'object',
      properties: { device_id: { type: 'string', description: '可选，指定设备' } },
      required: [],
    },
  },
  {
    name: 'list_ai_models',
    description: '列出控制台里已配置的 AI 模型（不返回密钥）。',
    inputSchema: { type: 'object', properties: {}, required: [] },
  },
  {
    name: 'ai_chat',
    description:
      '用控制台配置的外部大模型聊天（OpenAI 兼容，非流式）。' +
      '这是「让 AI 思考」的通道；prism_chat 是「让 Prism 干活」的通道，别混。',
    inputSchema: {
      type: 'object',
      properties: {
        messages: {
          type: 'array',
          description: '[{role:"user"|"system"|"assistant", content:"..."}]',
        },
        prompt: { type: 'string', description: '便捷写法：一句话当 user message' },
        model_id: { type: 'string', description: '可选，用哪个模型；不填用默认' },
      },
      required: [],
    },
  },
];

// ------------------------------------------------------------
// JSON-RPC 外壳
// ------------------------------------------------------------
function rpc(id: any, result: any) {
  return new Response(JSON.stringify({ jsonrpc: '2.0', id: id ?? null, result }), {
    headers: { 'Content-Type': 'application/json; charset=utf-8', 'Access-Control-Allow-Origin': '*' },
  });
}
function rpcErr(id: any, code: number, message: string, data?: any) {
  return new Response(
    JSON.stringify({ jsonrpc: '2.0', id: id ?? null, error: { code, message, ...(data ? { data } : {}) } }),
    { headers: { 'Content-Type': 'application/json; charset=utf-8', 'Access-Control-Allow-Origin': '*' } },
  );
}

// ------------------------------------------------------------
// 工具实现
// ------------------------------------------------------------
async function callTool(env: any, name: string, args: any): Promise<any> {
  const db: D1Database = env.DB;
  const a = args || {};

  if (name === 'list_devices') {
    const r = await db
      .prepare('SELECT id, name, platform, status, last_seen, created_at FROM devices ORDER BY last_seen DESC LIMIT 100')
      .all<any>();
    const now = Date.now();
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(
            {
              devices: (r.results || []).map((d: any) => ({
                ...d,
                online: now - (d.last_seen || 0) < 90_000,
                last_seen_ago_sec: Math.floor((now - (d.last_seen || 0)) / 1000),
              })),
            },
            null,
            2,
          ),
        },
      ],
    };
  }

  if (name === 'prism_chat') {
    if (!a.prompt) throw new Error('缺少 prompt');
    const r = await runOnDevice(
      db,
      a.device_id,
      'chat',
      {
        message: a.prompt,          // ★ 被控端读 p.message，不是 p.prompt
        prompt: a.prompt,           // 兼容旧字段
        session_name: a.session_name,
        plugin_id: a.plugin_id,
        model_name: a.model_name,
        mode: a.mode,
      },
      { timeoutMs: a.timeout_ms ?? 45_000 },
    );
    return {
      content: [{ type: 'text', text: JSON.stringify(r, null, 2) }],
      isError: !r.ok,
    };
  }

  if (name === 'prism_tool') {
    if (!a.tool_name) throw new Error('缺少 tool_name');
    const r = await runOnDevice(
      db,
      a.device_id,
      'tool',
      { tool_name: a.tool_name, arguments: a.arguments || {} },
      { timeoutMs: a.timeout_ms ?? 45_000 },
    );
    // 被控端回传 { ok, tool, executed, result, ai_comment } —— 摊平一层，AI 更好读
    const env: any = r.result && typeof r.result === 'object' ? r.result : {};

    // ★ executed 必须用严格判断。
    //   之前写的是 `env.executed !== false`，指令根本没被执行时（比如设备离线）
    //   env 是空对象，executed 是 undefined，`undefined !== false` 竟然是 true ——
    //   于是「设备离线、指令压根没跑」会被报成 executed:true，
    //   外部 AI 会以为自己成功操作了游戏，其实什么都没发生。这种错最坑。
    const executed = env.executed === true;

    const flat = {
      ok: r.ok,
      tool: env.tool || a.tool_name,
      executed,
      result: env.result !== undefined ? env.result : env,
      ai_comment: env.ai_comment || null,
      device_id: r.device_id,
      device_name: r.device_name,
      command_id: r.command_id,
      error: r.error || null,
      timeout: !!r.timeout,
      // 失败时给 AI 一句人话，别让它自己猜
      hint: (!r.ok || !executed)
        ? (r.error
            ? ('没执行成功：' + r.error)
            : '工具没有被执行（executed=false）。可能是 Prism 内置 AI 没有发起 tool_call，'
              + '或工具名不在它的 29 个工具里。可以先调 prism_status 确认引擎正常。')
        : null,
    };
    return { content: [{ type: 'text', text: JSON.stringify(flat, null, 2) }], isError: !r.ok };
  }

  if (name === 'prism_rest') {
    if (!a.path) throw new Error('缺少 path');
    const r = await runOnDevice(db, a.device_id, 'prism_rest', {
      path: a.path,
      method: a.method || 'GET',
      body: a.body,
    });
    return { content: [{ type: 'text', text: JSON.stringify(r, null, 2) }], isError: !r.ok };
  }

  if (name === 'packet_history') {
    const dev = await pickDevice(db, a.device_id);
    const act = a.action || 'list';
    if (act === 'stats') {
      const r = await runOnDevice(db, dev?.id, 'tool', {
        tool_name: 'packet_stats',
        arguments: {},
      });
      return { content: [{ type: 'text', text: JSON.stringify(r, null, 2) }], isError: !r.ok };
    }
    if (act === 'query') {
      const r = await runOnDevice(db, dev?.id, 'tool', {
        tool_name: 'query_packets',
        arguments: { limit: a.limit ?? 50, ...(a.packet_type ? { type: a.packet_type } : {}) },
      });
      return { content: [{ type: 'text', text: JSON.stringify(r, null, 2) }], isError: !r.ok };
    }
    const r = await runOnDevice(db, dev?.id, 'tool', {
      tool_name: 'list_packets',
      arguments: {},
    });
    return { content: [{ type: 'text', text: JSON.stringify(r, null, 2) }], isError: !r.ok };
  }

  if (name === 'packet_send') {
    if (!a.packet_type) throw new Error('缺少 packet_type');
    const r = await runOnDevice(db, a.device_id, 'packet_send', {
      packet_type: a.packet_type,
      data: a.data || {},
    });
    return { content: [{ type: 'text', text: JSON.stringify(r, null, 2) }], isError: !r.ok };
  }

  if (name === 'prism_session') {
    const act = (a.action || 'list').toString().toLowerCase();
    const map: Record<string, string> = {
      list: 'session_list', load: 'session_load', save: 'session_save', delete: 'session_delete',
    };
    const kind = map[act];
    if (!kind) throw new Error(`action 只支持 list/load/save/delete，收到：${act}`);
    if (act !== 'list' && !a.session_name) throw new Error(`${act} 需要 session_name`);
    const r = await runOnDevice(db, a.device_id, kind, {
      session_name: a.session_name,
      messages: a.messages,
      plugin_id: a.plugin_id,
      recent: !!a.recent,
    });
    return { content: [{ type: 'text', text: JSON.stringify(r, null, 2) }], isError: !r.ok };
  }

  if (name === 'prism_status') {
    const r = await runOnDevice(db, a.device_id, 'prism_status', {});
    return { content: [{ type: 'text', text: JSON.stringify(r, null, 2) }], isError: !r.ok };
  }

  if (name === 'list_ai_models') {
    const resp = await listModels(db);
    const j = await resp.json<any>();
    return { content: [{ type: 'text', text: JSON.stringify(j, null, 2) }] };
  }

  if (name === 'ai_chat') {
    let messages = a.messages;
    if (!Array.isArray(messages) || !messages.length) {
      if (!a.prompt) throw new Error('messages 和 prompt 至少给一个');
      messages = [{ role: 'user', content: a.prompt }];
    }
    // MCP 是请求-响应模型，这里强制非流式
    const resp = await chatProxy(db, {
      messages,
      model_id: a.model_id,
      stream: false,
      max_tokens: a.max_tokens ?? 2048,
    });
    const txt = await resp.text();
    let parsed: any;
    try {
      parsed = JSON.parse(txt);
    } catch {
      parsed = { raw: txt };
    }
    const content =
      parsed?.choices?.[0]?.message?.content ?? parsed?.raw ?? JSON.stringify(parsed);
    return {
      content: [{ type: 'text', text: String(content) }],
      isError: resp.status >= 400,
    };
  }

  throw new Error(`未知工具：${name}`);
}

// ------------------------------------------------------------
// 主入口
// ------------------------------------------------------------
export async function handleMcp(req: Request, env: any): Promise<Response> {
  if (req.method === 'OPTIONS') {
    return new Response(null, {
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization',
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      },
    });
  }

  // GET：给人类看的说明页，方便用户确认 URL 配对了
  if (req.method === 'GET') {
    const u = new URL(req.url);
    return new Response(
      JSON.stringify(
        {
          ok: true,
          service: 'Prism 远程控制 · MCP 端点',
          protocol: MCP_PROTOCOL_VERSION,
          server: MCP_SERVER_INFO,
          usage: '把这个 URL 填到 AI Agent 的 MCP 服务器配置里（HTTP 类型）',
          tools: TOOLS.map((t) => t.name),
        },
        null,
        2,
      ),
      {
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
          'Access-Control-Allow-Origin': '*',
        },
      },
    );
  }

  if (req.method !== 'POST') return rpcErr(null, -32000, '只支持 POST / GET / OPTIONS');

  let msg: any;
  try {
    msg = await req.json();
  } catch {
    return rpcErr(null, -32700, '解析 JSON 失败');
  }

  const { id, method, params } = msg || {};

  try {
    switch (method) {
      case 'initialize':
        return rpc(id, {
          protocolVersion: MCP_PROTOCOL_VERSION,
          serverInfo: MCP_SERVER_INFO,
          capabilities: { tools: { listChanged: false } },
          instructions:
            '你有 Prism 工具箱的远程控制权。' +
            'prism_chat = 让云手机里的 Prism AI 干活；' +
            'prism_tool = 调 Prism 的 29 个内置工具；' +
            'ai_chat = 用用户配置的大模型思考。' +
            '先 list_devices 确认设备在线。',
        });

      case 'notifications/initialized':
      case 'initialized':
        return new Response(null, { status: 202 });

      case 'ping':
        return rpc(id, {});

      case 'tools/list':
        return rpc(id, { tools: TOOLS });

      case 'tools/call': {
        const tname = params?.name;
        const targs = params?.arguments || {};
        if (!tname) return rpcErr(id, -32602, '缺少 params.name');
        try {
          const out = await callTool(env, tname, targs);
          return rpc(id, out);
        } catch (e: any) {
          return rpc(id, {
            content: [{ type: 'text', text: `工具执行失败：${e?.message || e}` }],
            isError: true,
          });
        }
      }

      case 'resources/list':
        return rpc(id, { resources: [] });

      case 'prompts/list':
        return rpc(id, { prompts: [] });

      default:
        return rpcErr(id, -32601, `不支持的方法：${method}`);
    }
  } catch (e: any) {
    return rpcErr(id, -32603, `内部错误：${e?.message || e}`);
  }
}
