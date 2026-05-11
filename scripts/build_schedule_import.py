# -*- coding: utf-8 -*-
"""
从春季课表 xlsx + 任课老师 xlsx 生成与 schedule 表一致的数据，并写出 SQL 与 CSV。

表字段（与 schedule_rows 一致）: class_name, week_day, period, subject, teacher_name
不含 id（由数据库自增）或含默认 id 由导入方式决定；此处 SQL 不显式写 id。

默认数据源放在仓库内：data/schedule/timetable.xlsx、data/schedule/teachers.xlsx
（可用命令行参数覆盖路径。）
"""
from __future__ import annotations

import argparse
import math
import re
import sys
from pathlib import Path

import pandas as pd

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_TIMETABLE = REPO_ROOT / "data" / "schedule" / "timetable.xlsx"
DEFAULT_TEACHER = REPO_ROOT / "data" / "schedule" / "teachers.xlsx"
OUT_DIR = Path(__file__).resolve().parent
OUT_CSV = OUT_DIR / "schedule_generated.csv"
OUT_SQL = OUT_DIR / "schedule_replace_generated.sql"

SHEET_GRADE = {
    "4.6七年级课表": "七",
    "4.6八年级课表": "八",
    "4.6九年级课表": "九",
}

BLOCK_STRIDE = 17  # 每个年级块纵向占约 17 行（含晚辅导行，解析时跳过）


def norm_space(s: str) -> str:
    s = str(s).replace("\r", "").replace("\n", "")
    s = re.sub(r"\s+", "", s)
    return s.strip()


def norm_subject_key(s: str) -> str:
    """用于匹配任课老师表：去空白、换行。"""
    return norm_space(s)


def subject_for_teacher_lookup(subject: str) -> str | None:
    """
    任课老师表仅有基础学科：自习/实验映射到主学科；其它未覆盖科目返回 None（教师留空）。
    """
    s = norm_subject_key(subject)
    if not s:
        return None
    if s.endswith("自习"):
        base = s[: -len("自习")]
        return base or None
    if s.endswith("实验"):
        base = s[: -len("实验")]
        return base or None
    if s == "科普":
        return "生物"  # 课表中新增科目，映射到生物教师（若需可改）
    if "阳光体育" in s or s == "班会":
        return None
    return s


def code_to_class_name(code, grade_cn: str) -> str | None:
    if code is None or (isinstance(code, float) and math.isnan(code)):
        return None
    try:
        n = int(float(code))
    except (TypeError, ValueError):
        return None
    digit = n % 10
    if digit < 1 or digit > 9:
        return None
    return f"{grade_cn}{digit}班"


def sql_escape(s: str) -> str:
    return s.replace("'", "''")


def load_teacher_map(teacher_path: Path) -> dict[tuple[str, str], str]:
    df = pd.read_excel(teacher_path, sheet_name=0)
    # 列名：班级、科目、老师
    m: dict[tuple[str, str], str] = {}
    for _, row in df.iterrows():
        cls = norm_space(row.iloc[0])
        sub = norm_space(row.iloc[1])
        teacher = str(row.iloc[2]).strip() if pd.notna(row.iloc[2]) else ""
        if cls and sub:
            m[(cls, sub)] = teacher
    return m


def lookup_teacher(teacher_map: dict[tuple[str, str], str], class_name: str, subject: str) -> str:
    key_sub = subject_for_teacher_lookup(subject)
    if not key_sub:
        return ""
    t = teacher_map.get((class_name, key_sub))
    if t:
        return t.strip()
    # 尝试「李 奎」类：任课表可能无空格
    t2 = teacher_map.get((class_name, key_sub.replace(" ", "")))
    if t2:
        return t2.strip()
    # 任课老师.xlsx 当前无九年级「生物」行；生物实验映射到生物后与旧课表一致回退
    if class_name.startswith("九") and key_sub == "生物":
        return "尤艳蕾"
    return ""


def parse_sheet(df: pd.DataFrame, grade_cn: str, teacher_map: dict) -> list[dict]:
    rows: list[dict] = []
    n = len(df)
    for block_start in range(0, n, BLOCK_STRIDE):
        code_row = block_start
        wd_row = block_start + 1
        if wd_row >= n:
            break
        for base_col in (1, 7, 13):
            code = df.iloc[code_row, base_col]
            class_name = code_to_class_name(code, grade_cn)
            if not class_name:
                continue
            for r in range(block_start + 2, min(block_start + BLOCK_STRIDE, n)):
                label = df.iloc[r, 0]
                if pd.isna(label):
                    continue
                if isinstance(label, str):
                    ls = str(label).strip()
                    if "阳光体育" in ls or ls in ("晚1", "晚2"):
                        continue
                try:
                    period = int(float(label))
                except (TypeError, ValueError):
                    continue
                if period < 1 or period > 8:
                    continue
                for dow in range(5):
                    col = base_col + dow
                    wd_cell = df.iloc[wd_row, col]
                    sub_cell = df.iloc[r, col]
                    if pd.isna(sub_cell):
                        continue
                    subject = str(sub_cell).strip()
                    if not subject:
                        continue
                    subject = subject.replace("\n", "").strip()
                    if "阳光体育" in subject:
                        continue
                    week_day = str(wd_cell).strip() if pd.notna(wd_cell) else ""
                    if week_day not in (
                        "星期一",
                        "星期二",
                        "星期三",
                        "星期四",
                        "星期五",
                    ):
                        continue
                    teacher = lookup_teacher(teacher_map, class_name, subject)
                    rows.append(
                        {
                            "class_name": class_name,
                            "week_day": week_day,
                            "period": period,
                            "subject": subject,
                            "teacher_name": teacher,
                        }
                    )
    return rows


def main(timetable_path: Path, teacher_path: Path) -> None:
    if not timetable_path.is_file():
        print(f"错误：找不到课表文件：{timetable_path}", file=sys.stderr)
        print("请将新课表保存为 data/schedule/timetable.xlsx，或使用 --timetable 指定路径。", file=sys.stderr)
        sys.exit(1)
    if not teacher_path.is_file():
        print(f"错误：找不到任课老师文件：{teacher_path}", file=sys.stderr)
        print("请将文件保存为 data/schedule/teachers.xlsx，或使用 --teachers 指定路径。", file=sys.stderr)
        sys.exit(1)

    teacher_map = load_teacher_map(teacher_path)
    all_rows: list[dict] = []
    xl = pd.ExcelFile(timetable_path)
    for sheet in xl.sheet_names:
        if sheet not in SHEET_GRADE:
            continue
        df = pd.read_excel(timetable_path, sheet_name=sheet, header=None)
        part = parse_sheet(df, SHEET_GRADE[sheet], teacher_map)
        all_rows.extend(part)

    # 去重：同一 class/day/period 保留最后一条（理论上不应重复）
    dedup: dict[tuple, dict] = {}
    for rec in all_rows:
        k = (rec["class_name"], rec["week_day"], rec["period"])
        dedup[k] = rec
    final_rows = list(dedup.values())

    # CSV
    pd.DataFrame(final_rows).to_csv(OUT_CSV, index=False, encoding="utf-8-sig")

    missing = [r for r in final_rows if not r["teacher_name"]]
    warn_path = OUT_DIR / "schedule_missing_teachers.txt"
    warn_path.write_text(
        "\n".join(
            f"{r['class_name']},{r['week_day']},{r['period']},{r['subject']}"
            for r in sorted(missing, key=lambda x: (x["class_name"], x["week_day"], x["period"]))
        ),
        encoding="utf-8",
    )

    # SQL：整表替换（执行前请自行备份）
    lines = [
        "-- 自动生成：build_schedule_import.py",
        "-- 执行前请在 Supabase 备份 schedule（如已有 schedule_backup 可先 insert into schedule_backup select * from schedule;）",
        "begin;",
        "delete from public.schedule;",
    ]
    batch: list[str] = []
    for rec in sorted(
        final_rows,
        key=lambda x: (x["class_name"], x["week_day"], x["period"]),
    ):
        batch.append(
            "insert into public.schedule (class_name, week_day, period, subject, teacher_name) values ("
            f"'{sql_escape(rec['class_name'])}',"
            f"'{sql_escape(rec['week_day'])}',"
            f"{int(rec['period'])},"
            f"'{sql_escape(rec['subject'])}',"
            f"'{sql_escape(rec['teacher_name'])}'"
            ");"
        )
    lines.extend(batch)
    lines.append("commit;")
    OUT_SQL.write_text("\n".join(lines), encoding="utf-8")

    print("rows", len(final_rows))
    print("missing_teacher_rows", len(missing))
    print("csv", OUT_CSV)
    print("sql", OUT_SQL)
    print("warn", warn_path)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="从课表与任课老师 Excel 生成 schedule 导入 SQL/CSV")
    parser.add_argument(
        "--timetable",
        type=Path,
        default=DEFAULT_TIMETABLE,
        help=f"春季课表 xlsx（默认：{DEFAULT_TIMETABLE}）",
    )
    parser.add_argument(
        "--teachers",
        type=Path,
        default=DEFAULT_TEACHER,
        help=f"任课老师 xlsx（默认：{DEFAULT_TEACHER}）",
    )
    args = parser.parse_args()
    main(args.timetable.resolve(), args.teachers.resolve())
