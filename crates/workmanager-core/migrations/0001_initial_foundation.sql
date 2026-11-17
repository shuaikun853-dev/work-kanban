-- WorkManager schema migration 0001：基础数据库骨架
--
-- 约定：
-- 1. 本文件只描述单个 migration 的 DDL/DML；事务与 user_version 由 Rust migration 引擎负责。
-- 2. 不得在本文件写入 BEGIN / COMMIT / ROLLBACK。
-- 3. 本 migration 只建立数据库底座，不创建项目、工作事项、每日计划、复盘、附件等业务表；
--    业务表在后续开发任务中以新的编号 migration 增加。
-- 4. 使用 STRICT 表，尽早拒绝类型不匹配的数据。

CREATE TABLE schema_migrations (
    version    INTEGER PRIMARY KEY,
    name       TEXT NOT NULL UNIQUE,
    applied_at TEXT NOT NULL
) STRICT;

-- 应用业务设置（key/value JSON）。T1-01 只建表，不写入任何未经用户确认的默认业务设置。
CREATE TABLE settings (
    key        TEXT PRIMARY KEY,
    value_json TEXT NOT NULL,
    updated_at TEXT NOT NULL
) STRICT;
