#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
e2e_analyze.py：放刀模块 ↔ 离线分析的端到端核对（只用 Python 标准库）。

为什么要有：run.lua 按 V16 第 6 节核对放刀模块写出的记录，apcal_analyze.py --selftest 按同一节生成合成数据核对解析，
两边各自「符合规格」也可能对不上（集成时就抓到过：分析脚本的「影子对真 FIRE」固定按 L=28 比，滑块改过的放刀被误报成
实现错误；探针版本号写成 apcal-1.0.2，B 阶段数据会被整段判需复核）。这里把 mock 每个场景的真实输出（放刀模块的
JSON / 日志 + 探针数据）直接喂给 apcal_analyze.py --strict，查：
  1. 不崩溃、报告里「内部错误 0 处」；
  2. v1.6 的 FIRE 一致性核对全部一致（V16 第 7 节第 4 条）；
  3. 1.6 影子对真 FIRE：nchg = 0 的放刀相差 ≤ 1 帧（第 7 节第 5 条）；影子不触发 / 没有条目的真放刀逐条有原因、「原因不明」
     的为 0；nchg = 0 的放刀影子算的 Q 和 FIRE 的 Q0 差 ≤ 0.5 帧（审查修订，V16 第 14 节：以前影子不触发的放刀被静默剔除）；
  4. rc 自评 RES 和离线结局判定一致（没有探针数据、离线判 UNKNOWN 的场景不比）；
  5. 载入了引用记账修过的探针（apcal-1.1 起）时，D16 的探针版本项是「通过」。

用法（先跑 run.lua）：
  lua tools/mock/run.lua
  python tools/mock/e2e_analyze.py [mock 输出目录，默认 tools/mock/out] [--reports 报告目录，默认写进各场景目录的 analyze.md]
只分析 run.lua --list 里现有的场景（输出目录里改名、删掉的旧场景目录跳过并列出）；找不到 lua 时全部分析。

合并模式（docs/autoparry/MERGE.md 第 6.6 节）：
  lua tools/mock/run.lua --merged
  python tools/mock/e2e_analyze.py --sub merged_on      把 B 组（合并版、调试日志开）的输出 out/<场景>/merged_on/ 喂给分析脚本，
                                                        查的项同上（合并版的 FIRE 没有 Qe1，一致性核对按没有 Qe1 的写法）
  不带 --sub 时分析 A0（out/<场景>/ 顶层的文件）：场景目录里另有 merged_on/ 等子目录时，只把顶层文件拷进临时目录再分析——
  分析脚本会递归找 JSON，B / C 两组的探针 JSON 和 A0 是同一个 session 号，混进来就串了。合并模式的新场景（只有子目录）跳过。
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
ANALYZER = os.path.join(REPO, "tools", "apcal_analyze.py")
LUA_DEFAULT = "C:/Users/Administrator/AppData/Local/Programs/Lua/bin/lua.exe"


def current_scenarios():
    """run.lua --list 里的场景名；输出目录里可能留着改名、删掉的旧场景，不分析它们。拿不到 lua 时返回 None（全部分析）。"""
    import shutil
    lua = os.environ.get("LUA") or shutil.which("lua") or (LUA_DEFAULT if os.path.exists(LUA_DEFAULT) else None)
    if not lua:
        return None
    p = subprocess.run([lua, os.path.join(HERE, "run.lua"), "--list"], cwd=REPO, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    names = {m.group(1) for m in re.finditer(r"^([A-Za-z0-9_]+)\s+\[", p.stdout, re.M)}
    return names or None


def top_level_copy(scen_dir):
    """场景目录里有子目录（合并模式的 merged_on/、merged_off/）时，把顶层的文件拷进临时目录：分析脚本递归找 JSON，子目录里
    B / C 两组的探针 JSON 和 A0 是同一个 session 号，混进来就串了。没有子目录时原样返回（不用拷）。"""
    subdirs = [d for d in os.listdir(scen_dir) if os.path.isdir(os.path.join(scen_dir, d))]
    if not subdirs:
        return scen_dir, None
    tmp = tempfile.mkdtemp(prefix="e2e_a0_")
    for f in os.listdir(scen_dir):
        src = os.path.join(scen_dir, f)
        if os.path.isfile(src):
            shutil.copy2(src, os.path.join(tmp, f))
    return tmp, tmp


def check_one(scen_dir, report):
    """返回（是不是 v1.6 session, 一致性核对的 FIRE 行数, 影子对真 FIRE 的刀数, 影子不触发的刀数, 问题列表）。"""
    env = dict(os.environ, PYTHONIOENCODING="utf-8")
    data_dir, tmp = top_level_copy(scen_dir)
    try:
        p = subprocess.run([sys.executable, "-B", ANALYZER, data_dir, "--strict", "--out", report], cwd=REPO, env=env,
                           capture_output=True, text=True, encoding="utf-8", errors="replace")
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)
    if p.returncode != 0:
        return False, 0, 0, 0, ["分析脚本退出码 %d：%s" % (p.returncode, (p.stderr or p.stdout).strip()[-300:])]
    bad = []
    m = re.search(r"内部错误 (\d+) 处", p.stdout)
    if not m or m.group(1) != "0":
        bad.append("内部错误：" + p.stdout.strip()[-200:])
    with open(report, encoding="utf-8") as fh:
        t = fh.read()
    v16 = "rc：版本 1.6" in t
    cons = re.search(r"一致性核对（每个 v1\.6 的 FIRE，(\d+) 行[^\n]*?：([^\n]*)", t)
    if cons and "全部一致" not in cons.group(2):
        bad.append("FIRE 一致性核对：" + cons.group(2)[:200])
    sh = re.search(r"影子触发时刻和真 FIRE 对照[^\n]*?：(\d+) 刀，\s*nchg = 0 的放刀相差超过 1 帧的 (\d+) 刀", t)
    if sh and sh.group(2) != "0":
        bad.append("影子对真 FIRE：" + sh.group(0)[-160:])
    # 审查修订：影子不触发 / 没有条目的真放刀逐条有原因，「原因不明」的（多半是放刀模块偏离规则）当问题报
    gap = re.search(r"真放刀 (\d+) 刀，影子也触发、参与上面对照的 (\d+) 刀；影子不触发 / 没有条目的 (\d+) 刀，其中原因不明 (\d+) 刀"
                    r"[^\n]*", t)
    if v16 and sh and not gap:
        bad.append("第 13 节缺「影子不触发 / 没有条目」那一行（分析脚本没按审查修订输出）")
    if gap and gap.group(4) != "0":
        bad.append("影子不触发、原因不明：" + gap.group(0)[:300])
    qd = re.search(r"影子在放刀那一刻算的 Q 和 FIRE 的 Q0（nchg = 0 的放刀）：差超过 [\d.]+ 帧的 (\d+) 刀[^\n]*", t)
    if qd and qd.group(1) != "0":
        bad.append("影子 Q 对 Q0：" + qd.group(0)[:300])
    agree = re.search(r"rc 自评 RES 与离线 CATCH 判定一致 [\d.]+%（(\d+)/(\d+)）", t)
    unknown = re.search(r"\| UNKNOWN \| (\d+) \|", t)
    if agree and agree.group(1) != agree.group(2) and not (unknown and int(unknown.group(1)) > 0):
        bad.append("rc 自评和离线判定不一致：" + agree.group(0))
    apv = re.search(r"\| 数据质量：探针版本 ≥ apcal-1\.1[^|]*\| ([^|]*) \|[^|]*\| ([^|]*) \|", t)
    if v16 and apv and "apcal-1.1" in apv.group(1) and apv.group(2).strip() != "通过":
        bad.append("探针版本项：" + apv.group(0))
    return v16, int(cons.group(1)) if cons else 0, int(sh.group(1)) if sh else 0, int(gap.group(3)) if gap else 0, bad


def main():
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    ap = argparse.ArgumentParser(description="mock 输出 → apcal_analyze.py 的端到端核对")
    ap.add_argument("mock_out", nargs="?", default=os.path.join(HERE, "out"), help="run.lua 的输出目录（每个场景一个子目录）")
    ap.add_argument("--reports", help="报告写到这个目录（默认写进各场景目录的 analyze.md）")
    ap.add_argument("--sub", help="分析各场景目录下的这个子目录（合并模式的 B 组：merged_on），MERGE 第 6.6 节")
    a = ap.parse_args()
    if a.reports:
        os.makedirs(a.reports, exist_ok=True)
    scen = sorted(d for d in os.listdir(a.mock_out) if os.path.isdir(os.path.join(a.mock_out, d)))
    known = current_scenarios()
    if known is not None:
        stale = [d for d in scen if d not in known]
        scen = [d for d in scen if d in known]
        if stale:
            print("跳过不在当前场景表里的目录（旧场景的输出）：" + "、".join(stale))
    n16 = n_fire = n_sh = n_gap = 0
    problems = []
    skipped = []
    todo = []
    for s in scen:
        d = os.path.join(a.mock_out, s)
        if a.sub:
            d = os.path.join(d, a.sub)
            if not os.path.isdir(d):
                skipped.append(s)
                continue
        elif not os.path.isfile(os.path.join(d, "ref.log")):
            skipped.append(s)      # 合并模式的新场景：只有各跑法的子目录
            continue
        todo.append((s, d))
    if skipped:
        print(("没有 %s 子目录、跳过的场景" % a.sub if a.sub else "没有顶层输出（合并模式的新场景）、跳过的") + "：" + "、".join(skipped))
    scen = [s for s, _d in todo]
    for s, d in todo:
        rep = os.path.join(a.reports, s + (("_" + a.sub) if a.sub else "") + ".md") if a.reports else os.path.join(d, "analyze.md")
        v16, nf, ns, ng, bad = check_one(d, rep)
        n16, n_fire, n_sh, n_gap = n16 + v16, n_fire + nf, n_sh + ns, n_gap + ng
        problems += [(s, b) for b in bad]
    print("场景 %d 个（v1.6 session %d）；FIRE 一致性核对 %d 行；影子对真 FIRE %d 刀，影子不触发（逐条有原因）%d 刀；问题 %d 处"
          % (len(scen), n16, n_fire, n_sh, n_gap, len(problems)))
    for s, b in problems:
        print("  ✗ %s：%s" % (s, b))
    return 1 if problems or not scen else 0


if __name__ == "__main__":
    sys.exit(main())
