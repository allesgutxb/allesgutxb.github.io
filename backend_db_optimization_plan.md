# 教务巡查系统后端/数据库优化执行单（Supabase）

## 目标

- 扫码后首次可用时间尽量控制在 2 秒内。
- 查询页首个数据返回控制在 1 秒内（P95）。
- 高峰时段失败率控制在 0.5% 以下。

## 你当前系统的关键结论

- 当前项目是静态页面直连 Supabase（PostgreSQL），没有独立后端服务层。
- 主要性能瓶颈大概率在：
  - `inspections` 表的筛选和排序；
  - `schedule` 表按班级/星期/节次自动匹配；
  - 首屏初始化阶段并发加载多个下拉数据源。

## 按顺序执行（建议）

### 1. 先执行 SQL 排查脚本

- 文件：`db_checklist_supabase.sql`
- 先执行 0~2 节，确认数据量、慢 SQL、现有索引情况。
- 再执行 3 节创建建议索引。
- 最后执行 5~6 节验证执行计划并 `ANALYZE`。

### 2. 重点看这两个结果

- `EXPLAIN ANALYZE` 是否从 `Seq Scan` 变为 `Index Scan`。
- `pg_stat_statements` 里与 `inspections` / `schedule` 相关 SQL 的平均耗时是否明显下降。

### 3. 若发现重复数据，先清理再加唯一约束

- `inspections` 可按“日期+班级+节次”判断业务重复风险。
- `schedule` 若存在同“班级+星期+节次”多条，自动填充会不稳定。
- 清理重复后再考虑唯一索引，避免后续脏数据继续产生。

## 与前端调用对应的索引说明

- 查询页：
  - 时间范围 + 多条件筛选 + `created_at desc` 排序。
  - 推荐索引：`date`、`created_at desc`、`(date, class_name, period)` 及常用筛选字段索引。
- 填报页自动课表：
  - 条件是 `class_name + week_day + period`。
  - 推荐复合索引：`idx_schedule_class_week_period`。
- 下拉列表：
  - `teachers.teacher_name`、`inspectors.inspector_name`、`classes.class_name` 排序读取，建议单列索引。

## 本周验收指标（建议）

- 查询页：
  - 首次查询 P95 < 1000ms；
  - 常见筛选组合 P95 < 700ms。
- 填报页自动填充课表：
  - 自动填充接口 P95 < 400ms。
- 稳定性：
  - 错误率 < 0.5%，且无明显高峰抖动。

## 额外建议（可选）

- 近期（1-2 周）：
  - 保持 `db_checklist_supabase.sql` 每周复跑一次，观察慢 SQL 演变。
- 中期：
  - 将查询页默认时间窗口限制在近 7/30 天，降低一次拉全量数据的概率。
  - 若数据持续增长，可为“近 30 天”建立物化视图。
