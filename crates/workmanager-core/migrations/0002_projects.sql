-- WorkManager schema migration 0002：项目
--
-- 约定：
-- 1. 本文件只描述单个 migration 的 DDL/DML；事务与 user_version 由 Rust migration 引擎负责。
-- 2. 不得在本文件写入 BEGIN / COMMIT / ROLLBACK。
-- 3. 字段范围以 PRD / 技术设计定义为准：id、name、is_archived、创建时间、更新时间。
--    不擅自增加业务字段；项目名称唯一性等规则 PRD 未定义，因此不建立唯一约束。
-- 4. 归档是 UPDATE（is_archived = 1），不是 DELETE；项目记录与未来工作历史关联必须保留。
-- 5. 使用 STRICT 表，尽早拒绝类型不匹配的数据。

CREATE TABLE projects (
    id          TEXT PRIMARY KEY NOT NULL,
    name        TEXT NOT NULL CHECK (length(trim(name)) > 0),
    is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
) STRICT;

-- 项目列表查询：默认未归档在前，归档项目在后；同组按创建时间倒序，id 作为稳定次级键。
CREATE INDEX idx_projects_archived_created_at
    ON projects (is_archived, created_at DESC, id DESC);
