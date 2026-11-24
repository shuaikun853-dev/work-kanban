-- WorkManager schema migration 0004：多项目创建组与成员关系（T1-04）
--
-- 约定：
-- 1. 本文件只描述单个 migration 的 DDL/DML；事务与 user_version 由 Rust migration 引擎负责。
-- 2. 不得在本文件写入 BEGIN / COMMIT / ROLLBACK。
-- 3. 字段范围以 PRD 5.2 / DEC-007 / DEC-034 / 技术设计 5.1 / 5.4 为准：
--    创建组只记录来源标题与创建时间；成员关系只记录 group_id 与 work_item_id，
--    不共享工作状态、进度、日志、计划或附件。
-- 4. 同一工作事项最多属于一个创建组：work_item_id UNIQUE。
-- 5. 删除工作事项时只允许清除该事项自身的成员关联：
--    work_item_id 外键 ON DELETE CASCADE，绝不连带删除同组其他工作副本或创建组。
-- 6. 删除创建组时只清除成员关系，不删除工作副本：
--    group_id 外键 ON DELETE CASCADE。
-- 7. 标题不是业务唯一键：source_title 允许相同标题重复出现。
-- 8. 使用 STRICT 表，尽早拒绝类型不匹配的数据。

CREATE TABLE work_item_creation_groups (
    id           TEXT PRIMARY KEY NOT NULL,
    source_title TEXT NOT NULL CHECK (length(trim(source_title)) > 0),
    created_at   TEXT NOT NULL
) STRICT;

CREATE TABLE work_item_creation_group_members (
    group_id     TEXT NOT NULL
                 REFERENCES work_item_creation_groups(id) ON DELETE CASCADE ON UPDATE RESTRICT,
    work_item_id TEXT NOT NULL UNIQUE
                 REFERENCES work_items(id) ON DELETE CASCADE ON UPDATE RESTRICT,
    PRIMARY KEY (group_id, work_item_id)
) STRICT;

-- 创建组按创建时间倒序查询（后续历史/溯源使用）；id 为稳定次级键。
-- 成员关系按组查询由 PRIMARY KEY (group_id, work_item_id) 的最左列索引满足，
-- 按工作事项反查由 work_item_id UNIQUE 索引满足，不重复增加索引。
CREATE INDEX idx_work_item_creation_groups_created_at
    ON work_item_creation_groups (created_at DESC, id DESC);
