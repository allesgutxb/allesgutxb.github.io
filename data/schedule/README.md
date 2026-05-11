# 课表数据源（放入仓库，避免桌面文件被删）

请在此目录放置两个 Excel 文件（**固定文件名**，便于脚本与一键发布）：

| 文件名 | 说明 |
|--------|------|
| `timetable.xlsx` | 春季总课表（与原先「2025-2026学年第二学期春季课表…xlsx」同结构：含 `4.6七年级课表` / `4.6八年级课表` / `4.6九年级课表` 三个工作表） |
| `teachers.xlsx` | 任课老师表（与原先「任课老师.xlsx」同结构：列 `班级、科目、老师`） |

更新课表时：用新课表**覆盖**上述两个文件，然后在仓库根目录执行：

```powershell
.\scripts\publish_schedule_data.ps1
```

该脚本会：运行 `build_schedule_import.py` 生成 `scripts/schedule_replace_generated.sql` 与 CSV → `git add` 相关文件 → `commit` → `push`。

**数据库**：推送后仍需在 Supabase SQL Editor 中执行 `scripts/schedule_replace_generated.sql`（会先 `delete` 再 `insert`），执行前请自行备份 `schedule` 表。
