-- WorkManager schema migration 0003：工作事项
--
-- 约定：
-- 1. 本文件只描述单个 migration 的 DDL/DML；事务与 user_version 由 Rust migration 引擎负责。
-- 2. 不得在本文件写入 BEGIN / COMMIT / ROLLBACK。
-- 3. 字段范围以 PRD 5.2 / 5.3 与技术设计 5.1 / 5.4 / 5.6 为准：
--    id、可空 project_id、title、lifecycle_status、可空 importance/urgency、可空 due_date/description、
--    创建/更新时间。T1-03 只写入 lifecycle_status = 'pending'；状态流转属于 T1-05。
-- 4. project_id 允许 NULL，表示尚未归属项目；外键显式 ON DELETE RESTRICT：
--    项目与工作事项均不允许级联删除，归档只更新 projects.is_archived，不改写既有工作关联。
-- 5. importance / urgency 未设置时保持 NULL，不伪造默认评分；非 NULL 时必须为 1–5。
--    pinned_rank（手动置顶排序）属于 T2-02/T2-03，不在本 migration 提前创建。
-- 6. 标题不是业务唯一键：相同标题允许创建多条独立工作事项记录。
-- 7. 使用 STRICT 表，尽早拒绝类型不匹配的数据。

CREATE TABLE work_items (
    id               TEXT PRIMARY KEY NOT NULL,
    project_id       TEXT REFERENCES projects(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    title            TEXT NOT NULL CHECK (length(trim(title)) > 0),
    lifecycle_status TEXT NOT NULL DEFAULT 'pending'
                     CHECK (lifecycle_status IN
                         ('pending', 'not_started', 'in_progress', 'completed', 'abandoned')),
    importance       INTEGER CHECK (importance IS NULL OR (importance BETWEEN 1 AND 5)),
    urgency          INTEGER CHECK (urgency IS NULL OR (urgency BETWEEN 1 AND 5)),
    due_date         TEXT,
    description      TEXT,
    created_at       TEXT NOT NULL,
    updated_at       TEXT NOT NULL
) STRICT;

-- 待安排查询：固定按创建时间倒序、id 作为稳定次级键；不实现手动排序。
CREATE INDEX idx_work_items_status_created_at
    ON work_items (lifecycle_status, created_at DESC, id DESC);

-- 按项目过滤工作事项（技术设计 5.5）。
CREATE INDEX idx_work_items_project_status
    ON work_items (project_id, lifecycle_status);
