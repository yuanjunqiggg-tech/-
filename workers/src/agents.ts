// ============================================================
//  AI Agent 注册表 —— 给每个「能接活的 AI」发一个稳定编号
// ============================================================
//
//  解决的问题：游戏聊天框输入「AI Agent 帮我改个价」时，
//  到底该发给谁？连着 MCP 的可能是 Codex，也可能是 Claude、豆包；
//  一个都没连的时候，还有云端配好的模型（强大的GPT / DeepSeek）可以顶上。
//
//  所以做一张注册表，每个 agent 分到一个**稳定编号**：
//    · 号码按「第一次出现」的顺序发，之后永久保留（不随上下线变动）
//    · 玩家在游戏里说「AI Agent 2 xxx」就是精确点名 2 号
//    · 说「AI Agent xxx」（不带号码）= 发给所有在线的
//
//  三种 kind：
//    mcp   —— 外部 AI 客户端（Codex / Claude / 豆包…），靠 initialize + 工具调用心跳
//    model —— 云端 / Prism 里配好的模型（强大的GPT、DeepSeek…），有 key 就常驻可用
//    pc    —— 跑在电脑上的 CLI（Codex CLI / Claude Code…），由 PC 端 agent 心跳注册
// ============================================================

export const AGENT_ONLINE_MS = 120000; // 2 分钟没心跳算离线

export const AGENT_DDL = `
CREATE TABLE IF NOT EXISTS agent_registry (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  kind       TEXT NOT NULL,
  name       TEXT NOT NULL,
  label      TEXT NOT NULL DEFAULT '',
  no         INTEGER,
  meta       TEXT NOT NULL DEFAULT '',
  pinned     INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER,
  last_seen  INTEGER
)`;

// ------------------------------------------------------------
// 建表（D1 是懒迁移，每次用到时确保一次即可）
// ------------------------------------------------------------
export async function ensureAgentTables(db: any) {
  // D1 的 prepare().run() 一次只能跑一条语句，索引分开建
  await db.prepare(AGENT_DDL).run();
  await db
    .prepare('CREATE UNIQUE INDEX IF NOT EXISTS idx_ar_kind_name ON agent_registry(kind, name)')
    .run();
  await db
    .prepare('CREATE UNIQUE INDEX IF NOT EXISTS idx_ar_no ON agent_registry(no)')
    .run();
}

// ------------------------------------------------------------
// 登记 / 心跳 —— 返回分配到的编号
//  同一个 kind+name 重复调用 = 刷新心跳，编号不变
// ------------------------------------------------------------
export async function agentUpsert(
  db: any,
  opt: { kind: string; name: string; label?: string; meta?: string },
): Promise<{ no: number; label: string; isNew: boolean }> {
  await ensureAgentTables(db);
  const kind = String(opt.kind || 'mcp');
  const name = String(opt.name || '').trim();
  if (!name) throw new Error('agentUpsert 需要 name');

  const label = String(opt.label || name).trim() || name;
  const meta = String(opt.meta || '');
  const now = Date.now();

  const exist: any = await db
    .prepare('SELECT id, no, label FROM agent_registry WHERE kind=? AND name=?')
    .bind(kind, name)
    .first();

  if (exist && exist.no) {
    await db
      .prepare('UPDATE agent_registry SET last_seen=?, label=?, meta=? WHERE id=?')
      .bind(now, label, meta, exist.id)
      .run();
    return { no: Number(exist.no), label, isNew: false };
  }

  // 新来的：发下一个号（预留 1..N，取当前最大 +1）
  const mx: any = await db
    .prepare('SELECT COALESCE(MAX(no), 0) AS m FROM agent_registry')
    .first();
  const no = Number(mx?.m || 0) + 1;

  if (exist && !exist.no) {
    // 历史上注册过但没拿到号（异常数据），补上
    await db
      .prepare('UPDATE agent_registry SET no=?, last_seen=?, label=?, meta=? WHERE id=?')
      .bind(no, now, label, meta, exist.id)
      .run();
    return { no, label, isNew: false };
  }

  await db
    .prepare(
      `INSERT INTO agent_registry (kind, name, label, no, meta, pinned, created_at, last_seen)
       VALUES (?, ?, ?, ?, ?, 0, ?, ?)`,
    )
    .bind(kind, name, label, no, meta, now, now)
    .run();

  return { no, label, isNew: true };
}

// ------------------------------------------------------------
// 收件箱补一列 agent_no（点名用）
//   线上表早就建好了，这里用 ALTER 补列；已经补过就静默跳过
// ------------------------------------------------------------
export async function ensureInboxAgentNo(db: any) {
  try {
    await db.prepare('ALTER TABLE agent_inbox ADD COLUMN agent_no INTEGER').run();
  } catch {
    /* 列已存在 */
  }
}

// ------------------------------------------------------------
// 把云端配好的模型同步成 kind='model' 的 agent
//  这样「没连 MCP」时也能点名用 强大的GPT / DeepSeek
// ------------------------------------------------------------
export async function syncModelAgents(db: any) {
  let rows: any[] = [];
  try {
    const r = await db
      .prepare('SELECT id, name, model, is_default FROM ai_models ORDER BY is_default DESC, created_at DESC')
      .all();
    rows = r.results || [];
  } catch {
    return; // 表还没建，跳过即可
  }
  for (const m of rows) {
    const nm = 'model:' + String(m.id);
    try {
      await agentUpsert(db, {
        kind: 'model',
        name: nm,
        label: String(m.name || m.model || nm),
        meta: JSON.stringify({ model_id: m.id, model: m.model }),
      });
    } catch {
      /* 单条失败不影响整体 */
    }
  }
}

// ------------------------------------------------------------
// 查编号
// ------------------------------------------------------------
export async function agentByNo(db: any, no: number): Promise<any | null> {
  await ensureAgentTables(db);
  const r: any = await db.prepare('SELECT * FROM agent_registry WHERE no=?').bind(Number(no)).first();
  return r || null;
}

// ------------------------------------------------------------
// 列出全部（带在线状态）
//   kind='model' 的永远算「可用」，不靠心跳
// ------------------------------------------------------------
export async function agentList(
  db: any,
  opt: { onlyOnline?: boolean; syncModels?: boolean } = {},
): Promise<any[]> {
  if (opt.syncModels !== false) await syncModelAgents(db);
  await ensureAgentTables(db);

  const r = await db.prepare('SELECT * FROM agent_registry ORDER BY no ASC').all();
  const now = Date.now();
  const list = (r.results || []).map((a: any) => {
    const live =
      a.kind === 'model'
        ? true
        : a.last_seen && now - Number(a.last_seen) < AGENT_ONLINE_MS;
    return {
      no: Number(a.no),
      kind: a.kind,
      name: a.name,
      label: a.label || a.name,
      online: !!live,
      idle_ms: a.last_seen ? now - Number(a.last_seen) : null,
      meta: a.meta || '',
    };
  });

  return opt.onlyOnline ? list.filter((a: any) => a.online) : list;
}

// ------------------------------------------------------------
// 给 AI 看的一段话：你是几号、还有谁在线、怎么点名
// ------------------------------------------------------------
export function agentRosterText(list: any[], me: { no: number; label: string } | null): string {
  const online = list.filter((a: any) => a.online);
  const kindName: Record<string, string> = {
    mcp: '外部 AI（MCP 直连）',
    model: '模型（走密钥 API）',
    pc: '电脑上的 CLI',
  };
  const lines = online.map((a: any) => {
    const tag = me && a.no === me.no ? '  ← 你' : '';
    const idle =
      a.kind === 'model'
        ? '常驻'
        : a.idle_ms == null
          ? '未知'
          : a.idle_ms < 60000
            ? Math.floor(a.idle_ms / 1000) + ' 秒前'
            : Math.floor(a.idle_ms / 60000) + ' 分钟前';
    return `  ${a.no}. ${a.label}   [${kindName[a.kind] || a.kind}]  ${idle}${tag}`;
  });

  const head = me
    ? `你是 **${me.no} 号 · ${me.label}**。\n管理员在游戏聊天框输入「AI Agent ${me.no} 要说的话」就是点名找你；\n不带编号的「AI Agent xxx」会发给所有在线的 AI。\n`
    : '你还**没有编号**。在 MCP 网址后面加 &agent=<你的名字>（例如 &agent=codex）再重连一次即可领取编号。\n';

  return (
    head +
    '\n当前在线的 AI Agent：\n' +
    (lines.length ? lines.join('\n') : '  （除了你没有别的，管理员不带编号发消息会直接到你这）') +
    '\n\n收到点名给你的消息才需要动手；点名别人的请无视，别抢活。'
  );
}
