-- ============================================================
-- Ds Platform · AI 帮写 外部控制 —— D1 建表 SQL
-- 数据库：ds-platform（复用现有）
-- 执行方式：wrangler d1 execute ds-platform --file=./sql/schema.sql
-- 日期：2026-09-13
-- ============================================================

-- ------------------------------------------------------------
-- 1. api_keys —— 访问平台的密钥（用户原方案）
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS api_keys (
  id          TEXT PRIMARY KEY,
  key         TEXT NOT NULL UNIQUE,          -- 密钥明文（前缀 dsp_）
  owner       TEXT,                          -- 归属人
  quota       INTEGER DEFAULT 100000,        -- 配额（token 数）
  used        INTEGER DEFAULT 0,             -- 已用
  status      INTEGER DEFAULT 1,             -- 1=启用 0=禁用
  create_time INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_api_keys_key ON api_keys(key);

-- ------------------------------------------------------------
-- 2. request_log —— 请求日志（用户原方案 + 扩展）
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS request_log (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  model_name  TEXT,
  tokens      INTEGER DEFAULT 0,
  in_tokens   INTEGER DEFAULT 0,
  out_tokens  INTEGER DEFAULT 0,
  key_id      TEXT,
  endpoint    TEXT,                          -- 调用端点
  success     INTEGER DEFAULT 1,
  error_msg   TEXT,
  latency_ms  INTEGER DEFAULT 0,
  time        INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_request_log_time ON request_log(time);

-- ------------------------------------------------------------
-- 3. ai_assist_sessions —— AI 帮写会话
--    对应 Prism 的 session_name，按 plugin_id 归属
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ai_assist_sessions (
  id            TEXT PRIMARY KEY,            -- 会话 ID（Prism 的 session_name）
  plugin_id     TEXT NOT NULL,               -- 归属插件
  model_name    TEXT,                        -- 使用的模型
  title         TEXT,                        -- 会话标题
  message_count INTEGER DEFAULT 0,
  total_in      INTEGER DEFAULT 0,           -- 累计输入 token
  total_out     INTEGER DEFAULT 0,           -- 累计输出 token
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_aas_plugin  ON ai_assist_sessions(plugin_id);
CREATE INDEX IF NOT EXISTS idx_aas_updated ON ai_assist_sessions(updated_at DESC);

-- ------------------------------------------------------------
-- 4. ai_assist_messages —— ★ 核心：完整旁路记录每一次 prompt
--    is_system_prompt 字段用于筛出「提示词」
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ai_assist_messages (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id       TEXT NOT NULL,
  role             TEXT NOT NULL,            -- system/user/assistant/tool_result
  content          TEXT,                     -- 完整正文（不截断）
  tool_calls       TEXT,                     -- JSON
  tool_results     TEXT,                     -- JSON
  tool_name        TEXT,                     -- 工具名（如 write_plugin_file）
  evidence         TEXT,                     -- 'executed' 表示真实执行
  prompt_tokens    INTEGER DEFAULT 0,
  out_tokens       INTEGER DEFAULT 0,
  is_system_prompt INTEGER DEFAULT 0,        -- ★ 1=这条是被捕获的系统提示词
  is_injected      INTEGER DEFAULT 0,        -- ★ 1=这条被平台改写过
  original_content TEXT,                     -- 改写前的原文（可编辑功能用）
  seq              INTEGER DEFAULT 0,        -- 会话内顺序
  created_at       INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_aam_session    ON ai_assist_messages(session_id, seq);
CREATE INDEX IF NOT EXISTS idx_aam_sysprompt  ON ai_assist_messages(is_system_prompt);
CREATE INDEX IF NOT EXISTS idx_aam_created    ON ai_assist_messages(created_at DESC);

-- ------------------------------------------------------------
-- 5. prompt_templates —— ★ 提示词模板（抓取+可编辑）
--    平台可下发替身提示词，覆盖 Prism 本地版本
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS prompt_templates (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  scope       TEXT NOT NULL,                 -- 'system' | 'plugin' | 'global'
  plugin_id   TEXT,                          -- scope=plugin 时生效
  name        TEXT NOT NULL,                 -- 模板名
  content     TEXT NOT NULL,                 -- 提示词内容
  enabled     INTEGER DEFAULT 0,             -- 1=启用（启用后覆盖 Prism 本地）
  priority    INTEGER DEFAULT 0,             -- 越大越优先
  version     INTEGER DEFAULT 1,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_ptpl_scope ON prompt_templates(scope, plugin_id, enabled);

-- ------------------------------------------------------------
-- 6. prompt_captures —— ★ 抓取到的原始系统提示词（指纹去重）
--    同一套提示词只存一份，便于「分出来」查看
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS prompt_captures (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  fingerprint TEXT NOT NULL UNIQUE,          -- 提示词内容哈希
  content     TEXT NOT NULL,                 -- 完整提示词
  char_count  INTEGER DEFAULT 0,
  plugin_id   TEXT,
  model_name  TEXT,
  hit_count   INTEGER DEFAULT 1,             -- 出现次数
  first_seen  INTEGER NOT NULL,
  last_seen   INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_pcap_seen ON prompt_captures(last_seen DESC);

-- ------------------------------------------------------------
-- 7. build_tasks —— 长任务（用户原方案，二期 MC 插件用）
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS build_tasks (
  id           TEXT PRIMARY KEY,
  player       TEXT,
  task_content TEXT,
  progress     INTEGER DEFAULT 0,
  status       TEXT DEFAULT 'pending',       -- pending/running/done/failed
  result       TEXT,
  create_time  INTEGER NOT NULL,
  update_time  INTEGER
);
CREATE INDEX IF NOT EXISTS idx_bt_status ON build_tasks(status);
