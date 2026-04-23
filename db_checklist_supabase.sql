-- 教务巡查系统（Supabase/PostgreSQL）性能排查与优化脚本
-- 使用方式：在 Supabase SQL Editor 分段执行（建议先在低峰时段）

-- ============================================================
-- 0) 基础信息与数据规模
-- ============================================================
select now() as current_time;

select
  (select count(*) from inspections) as inspections_count,
  (select count(*) from schedule) as schedule_count,
  (select count(*) from teachers) as teachers_count,
  (select count(*) from classes) as classes_count,
  (select count(*) from inspectors) as inspectors_count;

-- inspections 的时间分布（判断近期数据量是否突增）
select date_trunc('day', created_at) as day, count(*) as cnt
from inspections
group by 1
order by 1 desc
limit 30;

-- ============================================================
-- 1) 查询热点和慢 SQL（需 pg_stat_statements 扩展可用）
-- ============================================================
-- 若报错“relation pg_stat_statements does not exist”，跳过本节。
select
  calls,
  round(total_exec_time::numeric, 2) as total_ms,
  round(mean_exec_time::numeric, 2) as avg_ms,
  round(max_exec_time::numeric, 2) as max_ms,
  rows,
  left(query, 300) as sample_query
from pg_stat_statements
where query ilike '%from "inspections"%'
   or query ilike '%from inspections%'
   or query ilike '%from "schedule"%'
   or query ilike '%from schedule%'
order by mean_exec_time desc
limit 30;

-- ============================================================
-- 2) 检查当前索引
-- ============================================================
select
  tablename,
  indexname,
  indexdef
from pg_indexes
where schemaname = 'public'
  and tablename in ('inspections', 'schedule', 'teachers', 'classes', 'inspectors')
order by tablename, indexname;

-- ============================================================
-- 3) 建议索引（与你当前页面查询强相关）
-- 说明：IF NOT EXISTS 可重复执行；索引建立后请执行 ANALYZE
-- ============================================================

-- query.html: 时间范围 + keyset 分页（date/created_at/id 倒序）
create index if not exists idx_inspections_date_created_at_id_desc
  on public.inspections (date, created_at desc, id desc);

-- 提交页查重与冲突检测高频组合
create index if not exists idx_inspections_date_class_period
  on public.inspections (date, class_name, period);

-- 多维筛选常见组合（可按实际慢 SQL 再继续细化）
create index if not exists idx_inspections_filter_core
  on public.inspections (inspector, subject, arrival_status, week_day);

-- 若存在仅按 created_at 最新数据列表的查询，再补充此索引
create index if not exists idx_inspections_created_at_desc
  on public.inspections (created_at desc);

-- inspect_form.html: 按班级+星期+节次 查 schedule 自动填充
create index if not exists idx_schedule_class_week_period
  on public.schedule (class_name, week_day, period);

-- 若业务上课表该组合必须唯一，建议启用唯一索引（先检查重复，再决定是否执行）
-- create unique index if not exists uq_schedule_class_week_period
--   on public.schedule (class_name, week_day, period);

-- teachers / inspectors / classes 下拉按名称排序
create index if not exists idx_teachers_teacher_name
  on public.teachers (teacher_name);

create index if not exists idx_inspectors_inspector_name
  on public.inspectors (inspector_name);

create index if not exists idx_classes_class_name
  on public.classes (class_name);

-- ============================================================
-- 3.4) 角色字段（下载权限使用，query.html 读取 inspectors.is_admin）
-- ============================================================
alter table public.inspectors
add column if not exists is_admin boolean not null default false;

-- 示例：将指定查课人员设为管理员（按需替换姓名后执行）
-- update public.inspectors set is_admin = true where inspector_name in ('管理员');

-- ============================================================
-- 3.5) inspections 索引瘦身（仅删除明确重复项，安全优先）
-- 说明：以下索引与其他索引功能重复，保留会增加写入成本与规划复杂度
-- ============================================================

-- teacher_name 完全重复索引：二选一保留即可
drop index if exists public.idx_inspections_teacher;

-- 与 idx_inspections_date_class_period 完全重复
drop index if exists public.idx_inspections_dup_check;

-- 若历史上保留了旧分页索引，可删除（已由三列索引覆盖）
-- drop index if exists public.idx_inspections_date_created_at_desc;

-- ============================================================
-- 4) 查重与数据质量检查（先看再改）
-- ============================================================

-- inspections: 同日期+班级+节次重复记录
select date, class_name, period, count(*) as dup_cnt
from inspections
group by date, class_name, period
having count(*) > 1
order by dup_cnt desc, date desc
limit 100;

-- schedule: 同班级+星期+节次重复（会导致 maybeSingle 报错或不稳定）
select class_name, week_day, period, count(*) as dup_cnt
from schedule
group by class_name, week_day, period
having count(*) > 1
order by dup_cnt desc, class_name
limit 100;

-- 可选：inspections 去重预览（保留每组最新 created_at）
with ranked as (
  select
    id,
    row_number() over (
      partition by date, class_name, period
      order by created_at desc, id desc
    ) as rn
  from inspections
)
select id
from ranked
where rn > 1
limit 200;

-- 可选：确认无误后再执行去重删除（默认注释）
-- with ranked as (
--   select
--     id,
--     row_number() over (
--       partition by date, class_name, period
--       order by created_at desc, id desc
--     ) as rn
--   from inspections
-- )
-- delete from inspections i
-- using ranked r
-- where i.id = r.id
--   and r.rn > 1;

-- 可选：schedule 去重后增加唯一约束，防止重复再次写入（默认注释）
-- alter table public.schedule
-- add constraint uq_schedule_class_week_period
-- unique (class_name, week_day, period);

-- ============================================================
-- 5) 执行计划验证（改完索引后再跑）
-- 目标：看到 Index Scan / Bitmap Index Scan，而非 Seq Scan
-- ============================================================

explain analyze
select *
from inspections
where date >= current_date - interval '7 day'
  and date <= current_date
order by date desc, created_at desc, id desc
limit 200;

explain analyze
select subject, teacher_name
from schedule
where class_name = '七年级1班'
  and week_day = '星期一'
  and period = 1;

-- ============================================================
-- 6) 统计信息更新（建索引后建议执行）
-- ============================================================
analyze public.inspections;
analyze public.schedule;
analyze public.teachers;
analyze public.classes;
analyze public.inspectors;

-- ============================================================
-- 7) 可选：为高峰时段做只读物化视图（如果查询页数据量继续增长）
-- ============================================================
-- 示例（按需启用）：
-- create materialized view if not exists mv_inspections_recent_30d as
-- select *
-- from inspections
-- where date >= current_date - interval '30 day';
--
-- create index if not exists idx_mv_inspections_recent_30d_created_at
--   on mv_inspections_recent_30d (created_at desc);
--
-- 刷新：refresh materialized view concurrently mv_inspections_recent_30d;
