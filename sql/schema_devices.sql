-- ============================================================
-- Ds Platform · 多设备控制 —— D1 建表 SQL（第二批）
-- 数据库：ds-platform
-- 执行：wrangler d1 execute ds-platform --file=./sql/schema_devices.sql
--
-- 架构：被控端(云手机 APK) 主动外连云端，领指令 / 报结果
--       控制端(网页 / APK) 通过 Workers 下发指令、订阅反馈
-- ============================================================

-- ------------------------------------------------------------
-- 8. devices —— 已注册的云手机设备
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS devices (
  id            TEXT PRIMARY KEY,            -- device_id（注册时生成，如 dev_xxxx）
  token         TEXT NOT NULL,               -- 设备专属密钥（被控端持有，鉴权用）
  name          TEXT,                        -- 自定义名称（如「云手机1号」）
  platform      TEXT DEFAULT 'android',      -- android / windows
  model         TEXT,                        -- 设备型号
  android_ver   TEXT,                        -- 安卓版本
  app_ver       TEXT,                        -- 被控端 App 版本
  prism_port    INTEGER DEFAULT 8080,        -- 该设备上 Prism 的端口
  prism_online  INTEGER DEFAULT 0,           -- Prism 是否在跑
  bot_connected INTEGER DEFAULT 0,           -- 机器人是否连服
  bot_server    TEXT,                        -- 所连服务器
  ip_hint       TEXT,                        -- 出口 IP（脱敏，便于识别）
  battery       INTEGER DEFAULT -1,          -- 电量 -1=未知
  memo          TEXT,                        -- 备注
  status        INTEGER DEFAULT 1,           -- 1=启用 0=停用
  last_seen     INTEGER DEFAULT 0,           -- 最后心跳时间
  created_at    INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_devices_seen   ON devices(last_seen DESC);
CREATE INDEX IF NOT EXISTS idx_devices_status ON devices(status);

-- ------------------------------------------------------------
-- 9. device_commands —— 指令队列（控制端下发 → 被控端领取）
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS device_commands (
  id           TEXT PRIMARY KEY,             -- 指令 ID（uuid）
  device_id    TEXT NOT NULL,
  kind         TEXT NOT NULL,                -- chat / tool / packet_sub / ping
  payload      TEXT,                         -- JSON：{tool_name, arguments} 或 {message}
  session_id   TEXT,                         -- 会话归属（chat 时用）
  status       TEXT DEFAULT 'pending',       -- pending / taken / done / failed / timeout
  result       TEXT,                         -- 执行结果（JSON）
  error        TEXT,
  created_at   INTEGER NOT NULL,
  taken_at     INTEGER,
  finished_at  INTEGER
);
CREATE INDEX IF NOT EXISTS idx_dc_queue  ON device_commands(device_id, status, created_at);
CREATE INDEX IF NOT EXISTS idx_dc_recent ON device_commands(created_at DESC);

-- ------------------------------------------------------------
-- 10. device_events —— 被控端上报的事件流（反馈 / 抓包数据）
--     控制端通过游标 since_seq 增量拉取
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS device_events (
  seq         INTEGER PRIMARY KEY AUTOINCREMENT,  -- 全局递增游标
  device_id   TEXT NOT NULL,
  command_id  TEXT,                          -- 关联指令（可为空）
  session_id  TEXT,
  type        TEXT NOT NULL,                 -- chunk / tool_start / tool_done / packet / status / error / done
  payload     TEXT,                          -- JSON
  created_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_de_dev_seq ON device_events(device_id, seq);
CREATE INDEX IF NOT EXISTS idx_de_cmd     ON device_events(command_id);
CREATE INDEX IF NOT EXISTS idx_de_type    ON device_events(type, created_at DESC);

-- ------------------------------------------------------------
-- 11. device_packets —— 抓包持久化（历史回看用，独立于事件流）
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS device_packets (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  device_id    TEXT NOT NULL,
  packet_seq   INTEGER,                      -- 设备侧原始 seq
  packet_type  TEXT,
  packet_id    INTEGER,
  direction    TEXT,                         -- in / out
  bot_index    INTEGER DEFAULT 0,
  fields       TEXT,                         -- JSON 字段
  raw_hex      TEXT,
  size         INTEGER DEFAULT 0,
  captured_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_dp_dev_time ON device_packets(device_id, captured_at DESC);
CREATE INDEX IF NOT EXISTS idx_dp_type     ON device_packets(device_id, packet_type, captured_at DESC);

-- ------------------------------------------------------------
-- 12. device_sessions —— 每台设备上的会话（替代全局 ai_assist_sessions）
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS device_sessions (
  id            TEXT NOT NULL,               -- session_id
  device_id     TEXT NOT NULL,
  title         TEXT,
  plugin_id     TEXT,
  model_name    TEXT,
  message_count INTEGER DEFAULT 0,
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL,
  PRIMARY KEY (id, device_id)
);
CREATE INDEX IF NOT EXISTS idx_ds_dev ON device_sessions(device_id, updated_at DESC);

-- ------------------------------------------------------------
-- 清理：已完成的指令保留 24 小时后可由定时任务删除
-- ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_dc_cleanup ON device_commands(status, finished_at);
