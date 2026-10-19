#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
atp_analyze.py：怪物攻击「真正打过来的时刻」离线分析（只用 Python 标准库）。

输入（数据目录里递归找）：
  ATP_<session>_<seq>.json    probes/AttackTimingProbe.lua（[ATP]）：INIT / GAR / EMF / EMSPD / EMACT / PERF / ERR …
  APCal_<session>_<seq>.json  probes/AutoParryCalib.lua（[APCal]）同一次游戏：SER（条目逐帧 hs/he）、ATK（攻击判定激活）、
                              CT（攻击碰到主角）、MSG、ENT。
  AutoParryGS_<session>_<seq>.json（可选，1.2）放刀模块：HDR / CFG 的 auto_parry 定出「放刀模块开着」的时段，C7 把这段的
                              片段单列（放刀会改变怪物后续的行为和主角的受击）。
  两个探针的 t 都是 os.clock()（进程启动以来的墙钟秒数），按时间段重叠配对，不要求 session 号相同；另外要求是同一个
  游戏进程：session（加载时的 os.time）− 加载时的 os.clock 是进程启动时刻，两边相差 ≤5 s（第 1~2c 轮四次加载都是
  1791619432±0.4，实测）。多个 ATP session 默认合并分析（留一只怪需要尽量多的怪种），--separate 分开出报告。

检验（报告里分清「数据算出来的」和「推测」）：
  C0 建结果调用（GAR）：探测器 getAttackAreaResult 的两个 Nullable<Single> 实参是什么、和 sgl/速度/动作帧的关系；
     返回的结果对象能不能对上 APCal 的 obj（能 → 以后可以直接按结果对象关联）
  C1 initData：hs 初值和 Single 参数、AttackStartFrame、动作帧、速度的关系（候选公式逐个算残差 + 最小二乘）；
     initData 时的快照和下一帧 EMF 的动作 / motion 是否一致（审查 F3），动作层帧号的单位是不是 1/60 s
  C2 倒数机制：APCal SER 里同一条目的 hs(t) 是按真实时间扣，还是按怪物速度扣；每帧扣的量和引擎 DeltaTime 比
     （审查 F4：相邻两帧开头之间扣的量对的是「前一帧开头读到的 DeltaTime」，两种配法都报）
  C3 真值：ATK 匹配到条目，带零假设对照（审查 F1）。现有数据（round1~2c 的 APCal ATK）a4 ∈ {1, 6}、a5 在 0~100、
     多数是 0~9 的小整数，em40 只有 {3, 5, 100} —— 「a5 ∈ CollidableIDList」偶然命中可能很多。所以按怪种比较
     「真实时间带里命中」和「把时间带平移到别处命中」的比例，明显更高才用 cids 口径，否则退回时间窗（只给最早一段），
     时间窗也不可靠的怪种不进主表。弹体条目（ShellIndex 有值）单列，不进主表。CT 取这只怪的第一次接触
  C4 候选估计量在决策点（基线剩余帧降到 30、60 的那一帧）对真实激活时刻的残差，按怪物分；
     决策点到真值之间有卡顿（引擎帧时长 >2 帧或帧间隔 >35 ms，审查 F5）的样本单列
  C5 留一只怪交叉验证：偏置用其余怪的中位数；再按抵消窗口 [0.328, 0.944] s 模拟放刀，提前量 λ 用其余怪选
  C6 速度：攻击前摇期间各怪的速度、哪些 _MotionSpeed 分量不是 1，和基线残差的关系（真值口径和 C4 相同）
  C7 速度来源（1.2）：修正时该积分哪一个速度 —— tot（_TotalMotionSpeedThisFream，= 12 个分量之积）还是只积 CoreState
     （docs/autoparry/SPEED.md 2.1 g：旧数据认为 tot 里的招式因子 Sequence/BlendTree 已经算进名义帧）。
     分量按 EMSPD 逐帧重建；机制旁证（动作层帧号按哪个速度走、激活时刻的名义进度）；新估计量和 E0/E2t/E3a 一张表；
     关键子集 = 倒数期间 Sequence×BlendTree ≠ 1 的段（两种假设只在这里给出不同的预测），配对比较 + 斜率（按招整簇重抽）；
     放刀模块开着的时段（同目录 AutoParryGS_*.json 的 HDR/CFG）的片段单列，不进 C7 的表
  pre/post 可能配错的 INIT（同一帧有 depth>1、ORPH 或多个线程上下文，审查 F8）整帧剔除，概况里报条数。

估计量（T̂ = 预测的激活时刻；N0 = 名义剩余帧，hs0 按 C1 的结论解释）：
  E0  基线               t + hs/60                                  （现在 AutoParryGS 用的）
  E1  朴素换算           t + hs/(60·tot)                            （只用当前速度换算倒数，不看已经过去的部分）
  E2t 积分（tot）        t + (N0 − Σ60·tot·Δt)/(60·tot)             （名义剩余 = 初值减去按每帧速度积分的进度）
  E2m 积分（层速度）     同上，速度用动作层 TreeLayer.Speed
  E2g 积分（引擎帧时长） 同上，每段用「段首帧开头读到的」DeltaTime（比 os.clock 的 1 ms 分辨率细；审查 F4 的错位已改）
  E3  动作帧（锚定）     t + (mf1 + N1 − mf)/(60·ms)                （名义剩余帧 / 当前速度；锚点 = initData 之后第一条 EMF，
                                                                    N1 = N0 − 到锚点为止的积分进度；审查 F3）
  E3a 动作帧（绝对）     t + (ast − mf)/(60·ms)                     （「AttackStartFrame − 动作当前帧」，不用 hs0）
  E4  chara 时间（锚定） t + (ace1 + N1/60 − ace)/tot               （动作的 CharaElapsedSecond 若按速度走）
  E3/E3a 在 motion 变了（mid ≠ 锚点）、E4 在动作变了时退回 E2t，不记空（退回的比例单独报）。
  1.2 新增（C7；积分框架和 E2t 完全一样，只换积分的速度 v：t + (N0 − Σ60·v·Δt)/(60·v)，分量来自 EMSPD）：
  E2c    只积 CoreState                                             （SPEED.md 的结论：招式因子已在名义帧里）
  E2c1   积 max(1, CoreState)                                       （v1.6 拟定的 E5c 口径，时钟换成 os.clock）
  E2cs   积 CoreState×Scale
  E2nseq 积 tot ÷ (Sequence×BlendTree)                              （总速度去掉招式因子）
  E2seq  只积 Sequence                                              （招式因子单独的作用，诊断用）
  C4/C5 的表里也列出它们；C4 按怪分的「最好的一个」和 C5 的「接住率最高」只在 1.1 的估计量里挑（不改已有口径）。

用法：
  python tools/atp_analyze.py <数据目录> [--apcal-dir 目录] [--session N] [--apcal-session M] [--separate]
                              [--out report.md] [--json summary.json] [--decision 30,60] [--hs0-model auto|nominal|scaled]
  python tools/atp_analyze.py --selftest [--keep 目录]
没有 ATP 数据时给出提示并以 2 退出；有 ATP、没有同一次游戏的 APCal 时只做 C0、C1、C6（这时用 GAR 的 tme=1 筛打主角的条目）。
自测用合成数据（按「名义帧初值 + 真实时间倒数 + 动作按速度走」生成，另有「初值按速度换算」、只有 ATP、两个进程混放几种），
检验每一节的判定方向和估计量的精度。1.2 另有两种「速度拆成 CoreState × Sequence」的合成数据：激活跟动作层帧号走
（应当判成积 tot）、Sequence 已经算进名义帧（应当判成只积 CoreState），检验 C7 分得开两种假设；外加一份放刀模块记录。
"""

import argparse
import bisect
import json
import math
import os
import random
import re
import shutil
import statistics
import sys
import tempfile
from collections import Counter, defaultdict

VERSION = "atp_analyze 1.2"

W0, W1 = 0.328, 0.944          # 抵消窗口（NOTES 第 1 轮机关扫描：以进入 (2,23) 为 0，首个接触落在这里就接住；W1 是扫描上限）
SER_MATCH_DT = 0.004           # 同一帧的 EMF 和 SER：都在帧开头记，os.clock 分辨率约 1 ms
LINK_LEAD = 0.002              # SER 不会早于 INIT
LINK_MAX = 12.0                # 一次 initData 之后最多看 12 s 的 SER
JUMP_CUT = 2.0                 # SER 的 hs 回跳超过 2 帧：条目被别人重新初始化了，截断
CT_AFTER_ACT = (-0.05, 0.60)   # ATK 之后找第一次接触
SPEED_MIN = 0.05               # 速度低于这个（定身、卡肉）不拿来做除数
EPOCH_TOL = 5.0                # 同一个游戏进程：os.time() − os.clock() 是进程启动的墙钟时刻，ATP 和 APCal 应当相同
LAMBDA_GRID = [round(0.20 + 0.01 * i, 2) for i in range(81)]   # 放刀提前量 0.20~1.00 s
DEFAULT_DECISIONS = (30.0, 60.0)
# 真值匹配（审查 F1）：ATK 要落在名义时刻的 0.5~2 倍带内（速度实测 0.81~1.47 → 实际/名义 0.68~1.23）
BAND_LO, BAND_HI, BAND_PAD_LO, BAND_PAD_HI = 0.5, 2.0, 0.05, 0.10
NULL_SHIFTS = (-3, -2, -1, 1, 2, 3)   # 零假设：时间带平移 k ×（带宽 + 2 s），不和真实的带重叠
NULL_GAP = 2.0
TRUTH_MIN_N = 5                # 每个怪种至少这么多段才判口径
TRUTH_NULL_MAX = 0.25          # 平移后的命中率上限（偶然命中太多 → 这个口径不可信）
TRUTH_MARGIN = 0.40            # 真实命中率至少高出平移命中率这么多
ANCHOR_MAX = 0.10              # 锚点 = initData 之后 0.1 s 内的第一条 EMF
HITCH_GDT, HITCH_DT = 2.0, 0.035   # 卡顿：引擎帧时长 >2 帧，或相邻帧开头间隔 >35 ms（审查 F5）
DEFAULT_EMF_FIELDS = ["tot", "ms", "mf", "mid", "bank", "pls", "ts", "ael", "ace", "act", "gdt", "gfc", "spt", "spf"]
INT_FIELDS = {"mid", "bank", "gfc"}
STR_FIELDS = {"act"}
FNAME_RE = re.compile(r"^(ATP|APCal)_(\d+)_(\d+)\.json$")

ESTIMATORS = [
    ("E0", "基线 t+hs/60"),
    ("E1", "朴素换算 t+hs/(60·tot)"),
    ("E2t", "积分 tot·Δt"),
    ("E2m", "积分 层速度·Δt"),
    ("E2g", "积分 tot·DeltaTime"),
    ("E3", "动作帧（锚定）(mf1+N1−mf)/(60·ms)"),
    ("E3a", "动作帧（绝对）(ast−mf)/(60·ms)"),
    ("E4", "chara 时间（锚定）"),
]
# 1.1 就有的估计量：C4 按怪分的「最好的一个」、C5 的「接住率最高」只在这些里挑，1.2 加了估计量也不改这两处的结论口径
BASE_EST_NAMES = [e[0] for e in ESTIMATORS]
# 1.2：速度来源（C7）。积分框架同 E2t，只换积分的速度；分量来自 EMSPD（见 AtpSession.comp_at、speed_value）
SPEED_ESTIMATORS = [
    ("E2c", "积分 CoreState·Δt"),
    ("E2c1", "积分 max(1,CoreState)·Δt（v1.6 E5c 口径）"),
    ("E2cs", "积分 CoreState×Scale·Δt"),
    ("E2nseq", "积分 tot÷(Sequence×BlendTree)·Δt"),
    ("E2seq", "积分 Sequence·Δt"),
]
SPEED_NAMES = [e[0] for e in SPEED_ESTIMATORS]
ESTIMATORS = ESTIMATORS + SPEED_ESTIMATORS
FALLBACK_EST = ("E3", "E3a", "E4")     # 这几个在 motion / 动作变了时退回 E2t
EST_NAMES = [e[0] for e in ESTIMATORS]
EST_DESC = dict(ESTIMATORS)
C7_NAMES = ["E0", "E2t", "E3a"] + SPEED_NAMES      # C7 的对比表
COMP_DEV = 0.001               # 分量 ≠1 的判定（EMSPD 写 4 位小数）
COMP_MATCH = 0.002             # ∏分量 和 tot 的相对差在这以内算对得上
C7_STRONG = 0.03               # 两种假设在决策点的预测差 ≥ 这么多秒，才算这个样本「分得开」
C7_BOOT = 400                  # 斜率区间：按招（怪种 + 动作）整簇重抽的次数
C7_WIN = 20                    # 机制旁证：动作层帧号推进的窗口（帧）
PARRY_RE = re.compile(r"^AutoParryGS_(\d+)_(\d+)\.json$")

NO_DATA_HINT = """没有找到 ATP_*.json（在 {root} 里递归找过）。
要采数据：
  1. 把 probes/AttackTimingProbe.lua 和 probes/AutoParryCalib.lua 一起放进游戏的 reframework/autorun/
     （探针只记录、不改游戏；ATP 负责 initData 和每帧速度，APCal 负责 SER/ATK/CT 真值）。
  2. 进游戏打几只不同的怪，尽量让它们对你出招（按住抵消蓄力挨打也行），怒、疲劳、不同招式都覆盖一些。
  3. REF 菜单「攻击时刻探针」里点「写出数据」，或者 Reset Scripts（会写出最后一份）。
  4. 把 reframework/data/ 下同一次的 ATP_*.json 和 APCal_*.json 拷到一个目录里，再运行：
       python tools/atp_analyze.py <那个目录>
自测（不需要游戏数据）：python tools/atp_analyze.py --selftest"""


# ---------------------------------------------------------------- 小工具
def num(x):
    if isinstance(x, bool) or x is None:
        return None
    if isinstance(x, (int, float)):
        v = float(x)
        return None if math.isnan(v) or math.isinf(v) else v
    return None


def fnum(x):
    if x is None or x in ("-", ""):
        return None
    try:
        v = float(x)
    except (TypeError, ValueError):
        return None
    return None if math.isnan(v) or math.isinf(v) else v


def quant(lst, p):
    xs = sorted(v for v in lst if v is not None)
    if not xs:
        return None
    if len(xs) == 1:
        return xs[0]
    pos = p * (len(xs) - 1)
    lo = int(math.floor(pos))
    hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (pos - lo)


def med(lst):
    return quant(lst, 0.5)


def fmt(x, nd=3):
    if x is None:
        return "-"
    if isinstance(x, int):
        return str(x)
    return f"{x:.{nd}f}"


def pct(a, b):
    if not b:
        return f"{a}/0"
    return f"{a}/{b}（{100.0 * a / b:.0f}%）"


def pearson(xs, ys):
    pairs = [(x, y) for x, y in zip(xs, ys) if x is not None and y is not None]
    if len(pairs) < 3:
        return None
    mx = sum(p[0] for p in pairs) / len(pairs)
    my = sum(p[1] for p in pairs) / len(pairs)
    sxx = sum((p[0] - mx) ** 2 for p in pairs)
    syy = sum((p[1] - my) ** 2 for p in pairs)
    if sxx <= 0 or syy <= 0:
        return None
    return sum((p[0] - mx) * (p[1] - my) for p in pairs) / math.sqrt(sxx * syy)


def lstsq(rows, ys):
    """最小二乘（正规方程 + 部分主元消元）。返回系数列表，奇异时 None。"""
    if not rows:
        return None
    k = len(rows[0])
    a = [[0.0] * (k + 1) for _ in range(k)]
    for row, y in zip(rows, ys):
        for i in range(k):
            a[i][k] += row[i] * y
            for j in range(k):
                a[i][j] += row[i] * row[j]
    for c in range(k):
        p = max(range(c, k), key=lambda r: abs(a[r][c]))
        if abs(a[p][c]) < 1e-12:
            return None
        a[c], a[p] = a[p], a[c]
        for r in range(k):
            if r != c:
                f = a[r][c] / a[c][c]
                for j in range(c, k + 1):
                    a[r][j] -= f * a[c][j]
    return [a[i][k] / a[i][i] for i in range(k)]


def parse_cids(s):
    out = set()
    if not isinstance(s, str):
        return out
    for x in s.split(","):
        x = x.strip()
        if x and x != "-":
            try:
                out.add(int(float(x)))
            except ValueError:
                pass
    return out


def parse_emf_v(v, fields):
    parts = v.split("|") if isinstance(v, str) else []
    row = {}
    for i, name in enumerate(fields):
        x = parts[i] if i < len(parts) else "-"
        if name in STR_FIELDS:
            row[name] = None if x in ("-", "") else x
        elif name in INT_FIELDS:
            fv = fnum(x)
            row[name] = int(round(fv)) if fv is not None else None
        else:
            row[name] = fnum(x)
    return row


def parse_comp(s, n=None):
    """EMSPD 的 comp / INIT 的 scomp（_MotionSpeed 各分量，「/」分隔，顺序见 spd_fields）→ 浮点元组。
    有读不到的分量、或个数和 spd_fields 对不上 → None（不拿半截的分量去乘）。"""
    if not isinstance(s, str):
        return None
    parts = s.split("/")
    if n and len(parts) != n:
        return None
    v = tuple(fnum(x) for x in parts)
    return None if not v or any(x is None for x in v) else v


def comp_get(comp, ix, field, default=None):
    i = ix.get(field)
    if comp is None or i is None or i >= len(comp):
        return default
    return comp[i]


def comp_prod(comp):
    p = 1.0
    for x in comp:
        p *= x
    return p


def species_of(em):
    return (em or "-").split("#")[0]


# ---------------------------------------------------------------- 读文件
def find_files(root, kind):
    out = []
    if not root or not os.path.isdir(root):
        return out
    for dp, _, fns in os.walk(root):
        for fn in fns:
            m = FNAME_RE.match(fn)
            if m and m.group(1) == kind:
                out.append((int(m.group(2)), int(m.group(3)), os.path.join(dp, fn)))
    out.sort()
    return out


def group_sessions(files):
    by = defaultdict(list)
    for s, q, p in files:
        by[s].append((q, p))
    return {s: sorted(v) for s, v in by.items()}


def load_json(path):
    with open(path, encoding="utf-8-sig") as f:
        return json.load(f)


class AtpSession:
    def __init__(self, session, paths):
        self.session = session
        self.paths = paths
        self.records = []
        self.files = []
        self.emf_fields = None
        self.spd_fields = None
        self.bad_files = []
        self.parry_on = []          # 1.2：放刀模块开着的时段（load_parry_for 填；没有 AutoParryGS 记录就是空）
        self.parry_fires = []
        for q, p in paths:
            try:
                d = load_json(p)
            except (OSError, ValueError) as e:
                self.bad_files.append((p, str(e)))
                continue
            if d.get("kind") != "ATP":
                self.bad_files.append((p, "kind 不是 ATP"))
                continue
            self.files.append({"seq": q, "why": d.get("why"), "ver": d.get("ver"), "n": len(d.get("records", []))})
            if d.get("emf_fields"):
                self.emf_fields = str(d["emf_fields"]).split(",")
            if d.get("spd_fields"):
                self.spd_fields = str(d["spd_fields"]).split(",")
            self.records.extend(d.get("records", []))
        seqs = [f["seq"] for f in self.files]
        self.missing_seq = sorted(set(range(1, max(seqs) + 1)) - set(seqs)) if seqs else []
        self.last_why = self.files[-1]["why"] if self.files else None
        self.records.sort(key=lambda r: num(r.get("t")) or 0.0)
        self.parse()

    def parse(self):
        fields = self.emf_fields or DEFAULT_EMF_FIELDS
        self.inits, self.perf, self.errs, self.notes, self.gars = [], [], [], [], []
        self.orph, self.guards = [], []
        self.emf = defaultdict(list)
        self.emspd = defaultdict(list)
        self.emact = defaultdict(list)
        self.hdr = None
        self.selftest = None
        self.kinds = Counter()
        for r in self.records:
            k = r.get("k")
            self.kinds[k] += 1
            t = num(r.get("t"))
            if t is None:
                continue
            if k == "INIT":
                self.inits.append(r)
            elif k == "EMF":
                row = parse_emf_v(r.get("v"), fields)
                row["t"] = t
                row["f"] = r.get("f")
                self.emf[r.get("em")].append(row)
            elif k == "EMSPD":
                self.emspd[r.get("em")].append((t, r.get("comp")))
            elif k == "EMACT":
                self.emact[r.get("em")].append((t, r.get("act"), r.get("name")))
            elif k == "PERF":
                self.perf.append(r)
            elif k == "ERR":
                self.errs.append(r)
            elif k == "HDR" and self.hdr is None:
                self.hdr = r
                if r.get("emf_fields") and not self.emf_fields:
                    self.emf_fields = str(r["emf_fields"]).split(",")
            elif k == "SELFTEST":
                self.selftest = r
            elif k == "NOTE":
                self.notes.append(r)
            elif k == "GAR":
                self.gars.append(r)
            elif k == "ORPH":
                self.orph.append(r)
            elif k == "GUARD":
                self.guards.append(r)
        self.bad_frames = self.find_bad_frames()
        self.emf_t = {}
        for em, rows in self.emf.items():
            rows.sort(key=lambda x: x["t"])
            self.emf_t[em] = [x["t"] for x in rows]
        # 1.2：EMSPD 只在分量变化时记（每次开始盯一只怪的第一帧必记一条），每帧的分量 = 这一帧开头之前（含同一帧）最近的一条
        self.spd_ix = {n: i for i, n in enumerate(self.spd_fields or [])}
        self.emspd_t, self.emspd_v = {}, {}
        nf = len(self.spd_fields or [])
        for em, lst in self.emspd.items():
            ts, vs = [], []
            for t, comp in sorted(lst, key=lambda x: x[0]):
                v = parse_comp(comp, nf)
                if v is not None:
                    ts.append(t)
                    vs.append(v)
            self.emspd_t[em], self.emspd_v[em] = ts, vs
        ts = [num(r.get("t")) for r in self.records if num(r.get("t")) is not None]
        self.t_min = min(ts) if ts else None
        self.t_max = max(ts) if ts else None
        # 加载时刻只认 HDR（第 1 个文件丢了时最早的记录会晚于加载，拿它做「同一进程」校验会误杀，宁可不校验）
        self.t_load = num(self.hdr.get("t")) if self.hdr else None

    def find_bad_frames(self):
        """pre/post 可能配错的帧（审查 F8）：{帧号: 原因}。
        探针用一个栈配对 pre/post：A-pre、B-pre、A-post（拿到 B 的记录，depth 2）、B-post（拿到 A 的，depth 1）两条都错，
        第二条的 depth 还是 1 —— 所以只要这一帧有 depth>1、ORPH（pre 之后没等到 post）或多个线程上下文，整帧剔除。"""
        bad = {}
        ctx_by_f = defaultdict(set)
        for r in self.inits:
            f = r.get("f")
            if f is None:
                continue
            if (num(r.get("depth")) or 1) > 1:
                bad.setdefault(f, "depth")
            if r.get("ctx") is not None:
                ctx_by_f[f].add(r.get("ctx"))
        for r in self.orph:
            if r.get("f") is not None:
                bad.setdefault(r.get("f"), "orphan")
        for f, cs in ctx_by_f.items():
            if len(cs) > 1:
                bad.setdefault(f, "ctx")
        # GAR 的 depth>1 不算：getCurrentAttackAreaResult 里面很可能再调 getAttackAreaResult，同一线程里正常嵌套时
        # 栈配对是对的；跨线程交错由上面的「多个线程上下文」抓。initData 不会自己调自己，所以 INIT 的 depth>1 才算
        return bad

    def frames(self, em, ta, tb):
        """em 在 (ta, tb] 里的 EMF 行。"""
        rows = self.emf.get(em)
        if not rows:
            return []
        tl = self.emf_t[em]
        i = bisect.bisect_right(tl, ta)
        j = bisect.bisect_right(tl, tb)
        return rows[i:j]

    def comp_at(self, em, t):
        """em 在 t 这一帧开头的 _MotionSpeed 分量（spd_fields 顺序的元组）：t 之前（含同一帧，EMSPD 和 EMF 同一个 t）
        最近的一条 EMSPD；没有 → None。实测（stageA）∏分量 = tot 的帧 99.4%；分量变化的那一帧 tot 还是上一组的积
        （_TotalMotionSpeedThisFream 晚一帧更新），C7 报这个比例。"""
        ts = self.emspd_t.get(em)
        if not ts:
            return None
        i = bisect.bisect_right(ts, t + 1e-4) - 1
        return self.emspd_v[em][i] if i >= 0 else None


class ApcalData:
    def __init__(self):
        self.sessions = []
        self.ser = defaultdict(list)
        self.ent = {}
        self.msg = {}
        self.atk = defaultdict(list)
        self.ct = defaultdict(list)
        self.t_min = None
        self.t_max = None
        self.n_records = 0
        self.hdr_t = None
        # APCal 的 activateAttack 钩子被它自己的频率守卫停掉（round2b/2c 实测：一群小怪时 >3000 次/秒，会话后 58% 的
        # 时间没有 ATK），到下一次加载（HDR）才恢复。这段时间里「带里没有 ATK」不说明任何事，真值和零假设都不用它
        self.atk_offs = []
        self.hdr_ts = []
        self.atk_dead = []

    def add(self, session, paths):
        self.sessions.append(session)
        for _, p in paths:
            try:
                d = load_json(p)
            except (OSError, ValueError):
                continue
            if d.get("kind") != "APCal":
                continue
            for r in d.get("records", []):
                self.n_records += 1
                t = num(r.get("t"))
                if t is None:
                    continue
                self.t_min = t if self.t_min is None else min(self.t_min, t)
                self.t_max = t if self.t_max is None else max(self.t_max, t)
                k = r.get("k")
                if k == "HDR":
                    self.hdr_ts.append(t)
                    if self.hdr_t is None:
                        self.hdr_t = t
                if k == "SER":
                    hs, he = num(r.get("hs")), num(r.get("he"))
                    if hs is not None:
                        # f = APCal 自己的帧号（相邻帧判断用，审查 F4：只按 <50 ms 判相邻会混进隔 2~3 帧的配对）
                        self.ser[r.get("ent")].append((t, hs, he, r.get("type"), r.get("obj"), r.get("f")))
                elif k == "ATK":
                    a5 = num(r.get("a5"))
                    self.atk[r.get("em")].append((t, num(r.get("a4")), int(a5) if a5 is not None else None))
                elif k == "CT":
                    self.ct[r.get("em")].append((t, r.get("cls"), r.get("res")))
                elif k == "ENT":
                    self.ent.setdefault(r.get("ent"), r)
                elif k == "MSG" and r.get("tme") == 1:
                    self.msg.setdefault(r.get("obj"), r)
                elif k == "ERR" and r.get("mod") == "ATK":
                    self.atk_offs.append(t)

    def finalize(self):
        for d in (self.ser, self.atk, self.ct):
            for k in d:
                d[k].sort(key=lambda x: x[0])
        self.atk_t = {k: [x[0] for x in v] for k, v in self.atk.items()}
        self.ct_t = {k: [x[0] for x in v] for k, v in self.ct.items()}
        hdrs = sorted(self.hdr_ts)
        self.atk_dead = []
        for off in sorted(self.atk_offs):
            later = [h for h in hdrs if h > off]
            self.atk_dead.append((off, later[0] if later else math.inf))

    def atk_ok(self, a, b):
        """[a, b] 这段时间 ATK 钩子一直活着、而且在记录范围内（真值带和零假设的平移带都要满足）。"""
        if self.t_min is None or a < self.t_min or b > self.t_max:
            return False
        return all(b < d0 or a >= d1 for d0, d1 in self.atk_dead)


def load_apcal_for(atp, apcal_sessions, only=None):
    """挑同一次游戏的 APCal session：时间段重叠（os.clock 是进程时钟），并且是同一个进程 ——
    session 号是加载时的 os.time()，「session − 加载时的 os.clock()」= 进程启动的墙钟时刻，两个脚本必须一致。
    不比这个的话，两天的数据放在一个目录里，os.clock 范围可能碰巧重叠，会配错。"""
    ap = ApcalData()
    picked = []
    e_atp = atp.session - atp.t_load if atp.t_load is not None else None
    for s, paths in sorted(apcal_sessions.items()):
        if only is not None and s not in only:
            continue
        if only is None:
            probe = ApcalData()
            probe.add(s, paths[:1] + paths[-1:])
            if atp.t_min is None or probe.t_min is None:
                continue
            if probe.t_max < atp.t_min - 5.0 or probe.t_min > atp.t_max + 5.0:
                continue
            if e_atp is not None and probe.hdr_t is not None and abs((s - probe.hdr_t) - e_atp) > EPOCH_TOL:
                continue
        ap.add(s, paths)
        picked.append(s)
    ap.finalize()
    return (ap if picked else None), picked


def find_parry_files(root):
    """AutoParryGS_<session>_<seq>.json（放刀模块的 JSON），按 session 分组。"""
    out = defaultdict(list)
    if root and os.path.isdir(root):
        for dp, _, fns in os.walk(root):
            for fn in fns:
                m = PARRY_RE.match(fn)
                if m:
                    out[int(m.group(1))].append((int(m.group(2)), os.path.join(dp, fn)))
    return {s: sorted(v) for s, v in out.items()}


def load_parry_for(atp, parry_sessions):
    """同一次游戏的放刀模块记录 → (「放刀模块开着」的时段列表, FIRE 时刻列表)。
    时段：HDR（每次加载一条）和 CFG（菜单改设置）的 auto_parry 按时间顺序当开关；最后还开着就到 +∞。
    同一进程的判定同 load_apcal_for（session − 加载时的 os.clock 相差 ≤ EPOCH_TOL），session 号相同也算。
    为什么要单列：放刀会让怪物被抵消、硬直，主角也不再按原样挨打（stageA：em19 那段 auto_parry=1，14:00:34 的 CFG 才关）。"""
    e_atp = atp.session - atp.t_load if atp.t_load is not None else None
    events, fires = [], []
    for s, paths in sorted(parry_sessions.items()):
        recs = []
        for _, p in paths:
            try:
                d = load_json(p)
            except (OSError, ValueError):
                continue
            if d.get("kind") != "AutoParryGS":
                continue
            recs.extend(r for r in d.get("records", []) if num(r.get("t")) is not None)
        if not recs:
            continue
        hdr = min((r for r in recs if r.get("k") == "HDR"), key=lambda r: num(r.get("t")), default=None)
        same = s == atp.session
        if not same and e_atp is not None and hdr is not None:
            same = abs((s - num(hdr.get("t"))) - e_atp) <= EPOCH_TOL
        if not same:
            continue
        events.extend(r for r in recs if r.get("k") in ("HDR", "CFG") and r.get("auto_parry") is not None)
        fires.extend(num(r.get("t")) for r in recs if r.get("k") == "FIRE")
    on, t_on = [], None
    for r in sorted(events, key=lambda r: num(r.get("t"))):
        t = num(r.get("t"))
        if r.get("auto_parry") in (1, True, "1"):
            if t_on is None:
                t_on = t
        elif t_on is not None:
            on.append((t_on, t))
            t_on = None
    if t_on is not None:
        on.append((t_on, math.inf))
    return on, sorted(fires)


def seg_parry(s):
    """这一段（initData 到真值 / 接触 / 名义时刻，取最晚的）和「放刀模块开着」的时段有没有重叠。"""
    on = getattr(s.atp, "parry_on", None) if s.atp is not None else None
    if not on or s.t0 is None:
        return False
    ends = [x for x in (s.t_act, s.t_ct) if x is not None]
    t1 = max(ends + [s.t0 + max(s.hs0 or 0.0, 0.0) / 60.0])
    return any(a <= t1 and s.t0 <= b for a, b in on)


# ---------------------------------------------------------------- 条目片段（一次 initData = 一段）
class Seg:
    def __init__(self, r, t_next):
        self.r = r
        self.atp = None         # 所属的 ATP session（取 EMF 帧用）
        self.has_ap = False     # 这个 session 有没有配上 APCal
        self.t0 = num(r.get("t"))
        self.t_next = t_next
        self.f = r.get("f")
        self.ent = r.get("ent")
        self.em = r.get("em") or "-"
        self.species = species_of(self.em)
        self.hs0 = num(r.get("hs"))
        self.he0 = num(r.get("he"))
        self.ast = num(r.get("ast"))
        self.aen = num(r.get("aen"))
        self.sgl = num(r.get("sgl"))
        self.tot0 = num(r.get("tot"))
        self.ms0 = num(r.get("ms"))
        self.mf0 = num(r.get("mf"))
        self.mid0 = r.get("mid")
        self.ace0 = num(r.get("ace"))
        self.ael0 = num(r.get("ael"))
        self.act0 = r.get("act")
        self.cids = parse_cids(r.get("cids"))
        sh = r.get("shell")
        self.is_shell = sh not in (None, "none", "-", "")      # 弹体条目：激活的不是怪物自己的碰撞体
        self.gar = r.get("gar")
        self.tme = r.get("tme")
        self.ser = []
        self.ser_t = []
        self.t_act = None
        self.act_how = None        # cids / window（可信，进主表）/ unreliable（这个怪种的口径不可信，不进主表）
        self.truth_ok = False
        self.a4 = None
        self.a5 = None
        self.t_ct = None
        self.ct_cls = None
        self.lead = False
        self.danger = False
        self.excluded = None       # 剔除原因（depth / orphan / ctx，审查 F8）
        self.anc = None            # 锚点：initData 之后第一条 EMF（审查 F3）
        self.cand = None           # 真值候选（match_candidates）

    @property
    def linked(self):
        return len(self.ser) > 0

    def hs_at(self, t):
        """帧开头的基线剩余帧：同一帧有 SER 就用 SER，否则按真实时间推（C2 验证过这个模型才可靠）。"""
        if self.ser_t:
            i = bisect.bisect_left(self.ser_t, t - SER_MATCH_DT)
            if i < len(self.ser_t) and abs(self.ser_t[i] - t) <= SER_MATCH_DT:
                return self.ser[i][1], True
        if self.hs0 is None:
            return None, False
        return self.hs0 - 60.0 * (t - self.t0), False

    @property
    def truth(self):
        return self.t_act


def build_segments(atp, ap):
    """一次 initData = 一段。剔除的段（pre/post 可能配错的帧，审查 F8）照样参与切段（它的 initData 确实发生了，
    后面的 SER 不能算到前一段头上），但不返回；剔除数记在 atp.excl。"""
    by_ent = defaultdict(list)
    for r in atp.inits:
        if num(r.get("t")) is not None:
            by_ent[r.get("ent")].append(r)
    segs = []
    excl = Counter()
    for ent, lst in by_ent.items():
        lst.sort(key=lambda r: num(r.get("t")))
        for i, r in enumerate(lst):
            t_next = num(lst[i + 1].get("t")) if i + 1 < len(lst) else math.inf
            s = Seg(r, t_next)
            s.atp = atp
            s.has_ap = ap is not None
            s.excluded = atp.bad_frames.get(r.get("f"))
            if s.excluded:
                excl[s.excluded] += 1
                continue
            if ap is not None and s.t0 is not None:
                rows = []
                prev = None
                for x in ap.ser.get(ent, []):
                    if x[0] < s.t0 - LINK_LEAD:
                        continue
                    if x[0] >= min(t_next, s.t0 + LINK_MAX):
                        break
                    if prev is not None and x[1] - prev > JUMP_CUT:
                        break
                    rows.append(x)
                    prev = x[1]
                s.ser = rows
                s.ser_t = [x[0] for x in rows]
                s.danger = any(x[3] == "DANGER" for x in rows)
            # 锚点：initData 之后第一条 EMF（initData 若发生在动作进入事件里，快照可能还是上一个动作 / motion）
            if s.t0 is not None:
                fr = atp.frames(s.em, s.t0, s.t0 + ANCHOR_MAX)
                s.anc = fr[0] if fr else None
            segs.append(s)
    atp.excl = {"n": sum(excl.values()), "by": dict(excl), "frames": len(atp.bad_frames)}
    segs.sort(key=lambda s: (s.t0 or 0.0))
    # 同一只怪同一帧 initData 的一组条目里，hs 初值最小的那条是「最早一段」（放刀逻辑看的就是它）
    groups = defaultdict(list)
    for s in segs:
        if s.hs0 is not None and (ap is None or s.linked):
            groups[(s.em, s.f)].append(s)
    for g in groups.values():
        dang = [s for s in g if s.danger] or g
        min(dang, key=lambda s: s.hs0).lead = True
    return segs


def truth_band(s):
    """真值时间带：名义时刻的 0.5~2 倍（审查 F1）。速度实测 0.81~1.47 → 实际/名义 0.68~1.23，带子留了余量。"""
    nominal = max(s.hs0, 0.0) / 60.0
    return s.t0 + max(0.0, BAND_LO * nominal - BAND_PAD_LO), s.t0 + BAND_HI * nominal + BAND_PAD_HI


def first_atk(atks, tl, lo, hi, cids=None):
    """[lo, hi] 里第一条 ATK（给 cids 时只要 a5 ∈ cids）：(t, a4, a5) 或 None。"""
    i0 = bisect.bisect_left(tl, lo)
    for t, a4, a5 in atks[i0:]:
        if t > hi:
            break
        if cids is None or (a5 is not None and a5 in cids):
            return t, a4, a5
    return None


def match_candidates(segs, ap):
    """每段在自己 session 的 APCal 里找真值候选（不定口径）：带里第一条 a5∈cids 的 ATK、带里第一条任意 ATK；
    零假设：同样宽的带平移 k ×（带宽 + 2 s）到别处（不和真实的带重叠，ATK 钩子活着）时各命中几次。
    CT（接触）也在这里按带找一次，定了口径以后有可信的激活时刻再收窄。"""
    if ap is None:
        return
    for s in segs:
        if s.hs0 is None or s.t0 is None or not s.linked:
            continue
        lo, hi = truth_band(s)
        atks = ap.atk.get(s.em, [])
        tl = ap.atk_t.get(s.em, [])
        c = {"lo": lo, "hi": hi, "alive": ap.atk_ok(lo, hi), "cids": None, "win": None,
             "n_null": 0, "null_c": 0, "null_w": 0}
        if c["alive"]:
            if s.cids:
                c["cids"] = first_atk(atks, tl, lo, hi, s.cids)
            c["win"] = first_atk(atks, tl, lo, hi)
            width = hi - lo
            for k in NULL_SHIFTS:
                d = k * (width + NULL_GAP)
                a, b = lo + d, hi + d
                if not ap.atk_ok(a, b):
                    continue
                c["n_null"] += 1
                if s.cids and first_atk(atks, tl, a, b, s.cids):
                    c["null_c"] += 1
                if first_atk(atks, tl, a, b):
                    c["null_w"] += 1
        cts = ap.ct.get(s.em, [])
        ctl = ap.ct_t.get(s.em, [])
        j = bisect.bisect_left(ctl, lo)
        c["ct"] = (cts[j][0], cts[j][1]) if j < len(cts) and cts[j][0] <= hi + CT_AFTER_ACT[1] else None
        c["cts"], c["ctl"] = cts, ctl
        s.cand = c


def decide_truth(segs):
    """按怪种定真值口径（审查 F1），再给每段定真值。返回 {怪种: 统计}。
    cids 口径：这个怪种「带里有 a5∈cids 的 ATK」的比例，比「同一组 cids 在平移的带里命中」的比例高出 TRUTH_MARGIN，
      并且平移命中率 ≤ TRUTH_NULL_MAX（偶然命中少），才用；用的时候每段取带里第一条 a5∈cids 的 ATK。
    否则退回时间窗：只给每组 initData 的「最早一段」取带里第一条 ATK，标成仅供参考（时间窗的平移命中率一起报，
      round2a/2b 的 em27 实测约 0.41~0.45：它几乎一直在出招，时间窗本身就含糊）。
    弹体条目（ShellIndex 有值）不定真值：激活的是弹体，不是怪物自己的碰撞体。"""
    stat = defaultdict(lambda: {"n_c": 0, "hit_c": 0, "null_c": 0, "nn_c": 0, "n_w": 0, "hit_w": 0, "null_w": 0,
                                "nn_w": 0, "shell": 0, "dead": 0})
    for s in segs:
        c = s.cand
        if c is None:
            continue
        d = stat[s.species]
        if s.is_shell:
            d["shell"] += 1
            continue
        if not c["alive"]:
            d["dead"] += 1
            continue
        if s.cids:
            d["n_c"] += 1
            d["hit_c"] += 1 if c["cids"] else 0
            d["null_c"] += c["null_c"]
            d["nn_c"] += c["n_null"]
        if s.lead:
            d["n_w"] += 1
            d["hit_w"] += 1 if c["win"] else 0
            d["null_w"] += c["null_w"]
            d["nn_w"] += c["n_null"]
    verdict = {}
    for sp, d in stat.items():
        rc = d["hit_c"] / d["n_c"] if d["n_c"] else None
        pc = d["null_c"] / d["nn_c"] if d["nn_c"] else None
        rw = d["hit_w"] / d["n_w"] if d["n_w"] else None
        pw = d["null_w"] / d["nn_w"] if d["nn_w"] else None
        ok_c = (d["n_c"] >= TRUTH_MIN_N and rc is not None and pc is not None and pc <= TRUTH_NULL_MAX
                and rc - pc >= TRUTH_MARGIN)
        d.update({"real_c": rc, "p_c": pc, "real_w": rw, "p_w": pw, "verdict": "cids" if ok_c else "window"})
        verdict[sp] = d
    for s in segs:
        c = s.cand
        if c is None or s.is_shell:
            continue
        v = verdict.get(s.species, {}).get("verdict")
        pick = None
        if c["alive"]:
            if v == "cids" and c["cids"]:
                pick, s.act_how = c["cids"], "cids"
            elif v == "window" and s.lead and c["win"]:
                pick, s.act_how = c["win"], "window"
        if pick:
            s.t_act, s.a4, s.a5 = pick
            s.truth_ok = s.act_how == "cids"
        # 接触：有 cids 口径的激活时刻就在它后面找，否则在带里找（CT 只在打到主角时才有，偶然命中少；ATK 停了也能用）
        if s.truth_ok:
            j = bisect.bisect_left(c["ctl"], s.t_act + CT_AFTER_ACT[0])
            if j < len(c["cts"]) and c["cts"][j][0] <= s.t_act + CT_AFTER_ACT[1]:
                s.t_ct, s.ct_cls = c["cts"][j][0], c["cts"][j][1]
        elif c["ct"]:
            s.t_ct, s.ct_cls = c["ct"]
    return verdict


# ---------------------------------------------------------------- C0：建结果调用（GAR）
def c0_gar(groups):
    out = {"n": 0, "kinds": Counter(), "tme": 0, "p1_has": 0, "p2_has": 0, "p1": [], "p2": [], "res_tme": 0,
           "res_in_apcal": 0, "init_tagged": 0, "init_total": 0, "p1_bad": 0, "p2_bad": 0, "excl": 0}
    comp = defaultdict(list)
    for atp, ap, _ in groups:
        gmap = {g.get("id"): g for g in atp.gars}
        for g in atp.gars:
            if g.get("f") in atp.bad_frames:      # pre/post 可能配错的帧（审查 F8）：返回的结果地址不可信
                out["excl"] += 1
                continue
            out["n"] += 1
            out["kinds"][g.get("kind")] += 1
            if g.get("tme") == 1:
                out["tme"] += 1
            for pn in ("p1", "p2"):
                if g.get(pn + "s") == "val" and num(g.get(pn)) is not None:
                    out[pn + "_has"] += 1
                    out[pn].append(num(g.get(pn)))
                elif g.get(pn + "s") == "bad":
                    out[pn + "_bad"] += 1     # 地址检查没过（值类型实参不像指针），读不到
            if ap is not None and g.get("tme") == 1:
                out["res_tme"] += 1
                if g.get("res") in ap.msg:
                    out["res_in_apcal"] += 1
        for r in atp.inits:
            if r.get("f") in atp.bad_frames:
                continue
            out["init_total"] += 1
            g = gmap.get(r.get("gar"))
            if not g:
                continue
            out["init_tagged"] += 1
            ace = num(r.get("ace"))
            refs = (("sgl", num(r.get("sgl"))), ("mf", num(r.get("mf"))), ("tot", num(r.get("tot"))),
                    ("60·ace", None if ace is None else 60.0 * ace), ("hs", num(r.get("hs"))), ("ast", num(r.get("ast"))))
            for pn in ("p1", "p2"):
                v = num(g.get(pn)) if g.get(pn + "s") == "val" else None
                if v is None:
                    continue
                for ref, x in refs:
                    if x is not None:
                        comp[(pn, ref)].append(abs(v - x))
    return out, comp


# ---------------------------------------------------------------- C1：initData 参数与 hs 初值
C1_CANDIDATES = [
    ("A", "hs0 = ast", "nominal", lambda s: s.ast),
    ("B", "hs0 = ast − sgl", "nominal", lambda s: None if s.ast is None or s.sgl is None else s.ast - s.sgl),
    ("C", "hs0 = (ast − sgl)/tot", "scaled",
     lambda s: None if s.ast is None or s.sgl is None or not s.tot0 or s.tot0 < SPEED_MIN else (s.ast - s.sgl) / s.tot0),
    ("D", "hs0 = ast − mf", "nominal", lambda s: None if s.ast is None or s.mf0 is None else s.ast - s.mf0),
    ("E", "hs0 = (ast − mf)/ms", "scaled",
     lambda s: None if s.ast is None or s.mf0 is None or not s.ms0 or s.ms0 < SPEED_MIN else (s.ast - s.mf0) / s.ms0),
    ("F", "hs0 = ast − 60·ace", "nominal", lambda s: None if s.ast is None or s.ace0 is None else s.ast - 60.0 * s.ace0),
    ("G", "hs0 = ast − 60·ael", "nominal", lambda s: None if s.ast is None or s.ael0 is None else s.ast - 60.0 * s.ael0),
    ("H", "hs0 = ast/tot − sgl", "scaled",
     lambda s: None if s.ast is None or s.sgl is None or not s.tot0 or s.tot0 < SPEED_MIN else s.ast / s.tot0 - s.sgl),
]


# 审查 F3：initData 若发生在动作进入事件里，INIT 快照（mf/ace/ael）可能还是上一个动作的。D'~G' 改用锚点
# （initData 之后第一条 EMF）的值，按锚点的速度回推到 initData 时刻（回推量不到 1 帧，误差在 0.5 帧以内）
def _anc(s, key):
    a = s.anc
    if a is None or s.t0 is None or a.get(key) is None:
        return None, None
    return a[key], a["t"] - s.t0


def _mf_back(s):
    mf, dt = _anc(s, "mf")
    ms = s.anc.get("ms") if s.anc else None
    if mf is None or ms is None:
        return None
    return mf - 60.0 * ms * dt


def _ace_back(s):
    ace, dt = _anc(s, "ace")
    tot = s.anc.get("tot") if s.anc else None
    if ace is None or tot is None:
        return None
    return ace - tot * dt


def _ael_back(s):
    ael, dt = _anc(s, "ael")
    return None if ael is None else ael - dt


C1_CANDIDATES += [
    ("D'", "hs0 = ast − mf（锚点回推）", "nominal",
     lambda s: None if s.ast is None or _mf_back(s) is None else s.ast - _mf_back(s)),
    ("E'", "hs0 = (ast − mf)/ms（锚点回推）", "scaled",
     lambda s: None if s.ast is None or _mf_back(s) is None or not s.anc.get("ms") or s.anc["ms"] < SPEED_MIN
     else (s.ast - _mf_back(s)) / s.anc["ms"]),
    ("F'", "hs0 = ast − 60·ace（锚点回推）", "nominal",
     lambda s: None if s.ast is None or _ace_back(s) is None else s.ast - 60.0 * _ace_back(s)),
    ("G'", "hs0 = ast − 60·ael（锚点回推）", "nominal",
     lambda s: None if s.ast is None or _ael_back(s) is None else s.ast - 60.0 * _ael_back(s)),
]


def c1_anchor(segs):
    """INIT 快照和锚点（下一帧 EMF）的 motion / 动作是否一致，以及探针的 aeq 标记（快照动作 == 建结果的 ACTION_ID 实参）。"""
    out = {"n": len(segs), "anc": 0, "mid_cmp": 0, "mid_mis": 0, "act_cmp": 0, "act_mis": 0, "aeq": Counter()}
    for s in segs:
        if s.r.get("aeq") is not None:
            out["aeq"][int(num(s.r.get("aeq")) or 0)] += 1
        if s.anc is None:
            continue
        out["anc"] += 1
        if s.mid0 is not None and s.anc.get("mid") is not None:
            out["mid_cmp"] += 1
            out["mid_mis"] += 1 if s.anc["mid"] != s.mid0 else 0
        if s.act0 is not None and s.anc.get("act") is not None:
            out["act_cmp"] += 1
            out["act_mis"] += 1 if s.anc["act"] != s.act0 else 0
    return out


def c1_units(atps, max_pairs=50000):
    """动作层帧号的单位是不是 1/60 s：相邻两帧（ATP 帧号连续、同一个 motion、速度够大）
    Δmf ÷ (ms·DeltaTime)。审查 F4 的结论（帧开头读到的 DeltaTime 是刚过完那一帧的时长，下一帧的更新用它），
    所以 lag1 用前一帧开头的 gdt、本帧开头的 ms；lag0 用 os.clock 的帧间隔。≈1 → 单位是 1/60 s。"""
    r1, r0 = [], []
    for atp in atps:
        for em, rows in atp.emf.items():
            for a, b in zip(rows, rows[1:]):
                if len(r1) >= max_pairs:
                    break
                if a.get("f") is None or b.get("f") != a["f"] + 1:
                    continue
                if a.get("mid") is None or a.get("mid") != b.get("mid") or a.get("mf") is None or b.get("mf") is None:
                    continue
                ms = b.get("ms")
                dmf = b["mf"] - a["mf"]
                if ms is None or ms < 0.2 or dmf <= 0:
                    continue
                if a.get("gdt") is not None and a["gdt"] > 0:
                    r1.append(dmf / (ms * a["gdt"]))
                dt = b["t"] - a["t"]
                if dt > 0:
                    r0.append(dmf / (ms * 60.0 * dt))
    return {"n1": len(r1), "med1": med(r1), "q1": (quant(r1, 0.25), quant(r1, 0.75)),
            "n0": len(r0), "med0": med(r0), "q0": (quant(r0, 0.25), quant(r0, 0.75))}


def c1_eval(segs):
    out = []
    for key, desc, kind, fn in C1_CANDIDATES:
        res = []
        for s in segs:
            if s.hs0 is None:
                continue
            p = fn(s)
            if p is not None:
                res.append(s.hs0 - p)
        a = [abs(x) for x in res]
        out.append({
            "key": key, "desc": desc, "kind": kind, "n": len(res), "med": med(res), "mad": med(a),
            "p90": quant(a, 0.9), "f005": (sum(1 for x in a if x <= 0.05) / len(a)) if a else None,
            "f05": (sum(1 for x in a if x <= 0.5) / len(a)) if a else None,
        })
    ranked = sorted([c for c in out if c["n"] > 0], key=lambda c: (-(c["f005"] or 0), c["mad"] if c["mad"] is not None
                                                                     else 1e9))
    return out, (ranked[0] if ranked else None)


def c1_fit(segs):
    rows, ys = [], []
    for s in segs:
        if s.hs0 is not None and s.ast is not None and s.sgl is not None:
            rows.append([s.ast, s.sgl, 1.0])
            ys.append(s.hs0)
    if len(rows) < 4:
        return None
    coef = lstsq(rows, ys)
    if coef is None:
        return None
    pred = [sum(c * x for c, x in zip(coef, r)) for r in rows]
    res = [y - p for y, p in zip(ys, pred)]
    my = sum(ys) / len(ys)
    sst = sum((y - my) ** 2 for y in ys)
    sse = sum(x * x for x in res)
    return {"a": coef[0], "b": coef[1], "c": coef[2], "rms": math.sqrt(sse / len(res)),
            "r2": (1 - sse / sst) if sst > 0 else None, "n": len(rows)}


def c1_sgl(segs):
    out = {}
    sg = [s.sgl for s in segs if s.sgl is not None]
    out["n"] = len(sg)
    out["min"], out["med"], out["max"] = (min(sg), med(sg), max(sg)) if sg else (None, None, None)
    out["zero"] = sum(1 for x in sg if abs(x) < 1e-6)
    rel = {}
    for name, fn in (("mf", lambda s: s.mf0), ("60·ace", lambda s: None if s.ace0 is None else 60 * s.ace0),
                     ("60·ael", lambda s: None if s.ael0 is None else 60 * s.ael0), ("tot", lambda s: s.tot0)):
        d = [abs(s.sgl - fn(s)) for s in segs if s.sgl is not None and fn(s) is not None]
        rel[name] = {"n": len(d), "mad": med(d), "f01": (sum(1 for x in d if x <= 0.1) / len(d)) if d else None,
                     "r": pearson([s.sgl for s in segs if s.sgl is not None and fn(s) is not None],
                                  [fn(s) for s in segs if s.sgl is not None and fn(s) is not None])}
    out["rel"] = rel
    return out


def c1_baked(segs):
    """同一种怪、同一个动作、同一个 RequestSetID 的 AttackStartFrame 是不是常数（是 → 烘焙的名义帧）。
    动作优先用锚点（下一帧 EMF）的动作 ID：INIT 快照可能还是上一个动作（审查 F3）。"""
    groups = defaultdict(list)
    for s in segs:
        act = (s.anc.get("act") if s.anc else None) or s.r.get("act")
        if s.ast is not None and act and s.r.get("req") not in (None, "-"):
            groups[(s.species, act, s.r.get("req"))].append(s.ast)
    multi = {k: v for k, v in groups.items() if len(v) >= 2}
    const = sum(1 for v in multi.values() if max(v) - min(v) <= 0.01)
    return {"groups": len(multi), "const": const}


# ---------------------------------------------------------------- 速度积分工具
def integrate(seg, frames):
    """沿 EMF 帧算三种进度积分（单位：名义帧）。返回每帧 (cum_tot_dt, cum_ms_dt, cum_tot_gdt)。
    E2g（审查 F4）：帧开头读到的 DeltaTime 是刚过完那一帧的时长，引擎在接下来这一帧的更新里用它；本帧开头读到的
    tot 是这次更新算出来的速度。所以 (t_{k−1}, t_k] 这一段的进度 = tot_k × gdt_{k−1}（gdt 取上一行 EMF 的）。"""
    out = []
    ct = cm = cg = 0.0
    t_prev = seg.t0
    last_tot = seg.tot0
    last_ms = seg.ms0 if seg.ms0 is not None else seg.tot0
    gdt_prev = None
    first = True
    ok_t = ok_m = ok_g = True
    for fr in frames:
        dt = fr["t"] - t_prev
        t_prev = fr["t"]
        tot = fr.get("tot") if fr.get("tot") is not None else last_tot
        ms = fr.get("ms") if fr.get("ms") is not None else last_ms
        last_tot, last_ms = tot, ms
        if tot is None:
            ok_t = ok_g = False
        if ms is None:
            ok_m = False
        if ok_t:
            ct += 60.0 * tot * dt
        if ok_m:
            cm += 60.0 * ms * dt
        if ok_g:
            # 第一段是从 initData（帧中间）到下一帧开头：没有「上一帧开头」的 gdt，用 os.clock 的差
            if first or gdt_prev is None:
                cg += 60.0 * tot * dt
            else:
                cg += tot * gdt_prev
        gdt_prev = fr.get("gdt")
        first = False
        out.append((ct if ok_t else None, cm if ok_m else None, cg if ok_g else None))
    return out


def speed_value(name, tot, comp, ix):
    """1.2 新估计量积分用的速度。tot = 这一帧的 _TotalMotionSpeedThisFream，comp = 这一帧的分量（spd_fields 顺序），
    ix = {分量名: 下标}。缺分量、读不到 → None。"""
    if comp is None:
        return None
    core = comp_get(comp, ix, "_CoreState")
    if name == "E2c":
        return core
    if name == "E2c1":
        return None if core is None else max(1.0, core)
    if name == "E2cs":
        sc = comp_get(comp, ix, "_Scale")
        return None if core is None or sc is None else core * sc
    if name == "E2nseq":
        sq, bt = comp_get(comp, ix, "_Sequence"), comp_get(comp, ix, "_BlendTree")
        if tot is None or sq is None or bt is None or sq * bt <= 0:
            return None
        return tot / (sq * bt)
    if name == "E2seq":
        return comp_get(comp, ix, "_Sequence")
    return None


def integrate_speeds(seg, frames):
    """1.2 新估计量的进度积分（单位：名义帧），口径和 E2t 的 integrate 一样：(t_{k−1}, t_k] 的进度 = 60·v_k·Δt，
    v_k 用第 k 行 EMF 帧开头读到的值（第一段是 initData 到第一行，也用第一行的值），Δt 是 os.clock 的差；
    这一帧读不到就沿用上一帧，从来没读到过就从这里起记空。分量用 EMSPD 重建（atp.comp_at），第一行之前用 INIT 的 scomp。
    E2nseq 的 tot ÷ (Sequence×BlendTree) 在分量变化的那一帧会错一帧（tot 晚一帧更新），量级 < 0.2 帧，不处理。
    返回每帧 ({名: 累计进度或 None}, {名: 这一帧的速度或 None})。"""
    atp = seg.atp
    ix = getattr(atp, "spd_ix", None) or {}
    comp = parse_comp(seg.r.get("scomp"), len(atp.spd_fields or []))
    tot = seg.tot0
    cum = dict.fromkeys(SPEED_NAMES, 0.0)
    ok = dict.fromkeys(SPEED_NAMES, True)
    t_prev = seg.t0
    out = []
    for fr in frames:
        dt = fr["t"] - t_prev
        t_prev = fr["t"]
        c = atp.comp_at(seg.em, fr["t"])
        if c is not None:
            comp = c
        if fr.get("tot") is not None:
            tot = fr["tot"]
        vs = {}
        for n in SPEED_NAMES:
            v = speed_value(n, tot, comp, ix)
            vs[n] = v
            if v is None:
                ok[n] = False
            elif ok[n]:
                cum[n] += 60.0 * v * dt
        out.append(({n: (cum[n] if ok[n] else None) for n in SPEED_NAMES}, vs))
    return out


# ---------------------------------------------------------------- C2：倒数机制
def c2_eval(segs):
    """倒数机制：真实时间模型 vs 速度模型的残差；每帧扣的量和 DeltaTime 比。
    审查 F4：相邻两帧开头之间 hs 扣的量对的是「前一帧开头读到的」DeltaTime（round2c 实测：和上一帧时长相关 0.959、
    和当前帧时长 0.482），两种配法（lag1 = t1 那一行的 gdt，lag0 = t2 那一行的）都报，让数据自己选；
    相邻只认 APCal 帧号连续（f2 = f1 + 1）—— 只按 <50 ms 判会混进隔 2~3 帧的配对（2c 约 0.7%）。"""
    res_rt, res_sp, slopes, means, dgdt1, dgdt0 = [], [], [], [], [], []
    n_seg = 0
    n_pairs_t = n_pairs_skip = 0
    for s in segs:
        if not s.linked or s.hs0 is None or len(s.ser) < 3:
            continue
        frames = s.atp.frames(s.em, s.t0 - 1.0, s.ser[-1][0] + 0.001)
        ft = [fr["t"] for fr in frames]
        fr_after = [fr for fr in frames if fr["t"] > s.t0]
        fta = [fr["t"] for fr in fr_after]
        integ = integrate(s, fr_after)
        used = False
        tl, hl = [], []
        for t, hs, he, typ, obj, _f in s.ser:
            el = t - s.t0
            if el < 0.3:
                continue
            used = True
            tl.append(t)
            hl.append(hs)
            res_rt.append(hs - (s.hs0 - 60.0 * el))
            i = bisect.bisect_left(fta, t - SER_MATCH_DT)
            if i < len(fta) and abs(fta[i] - t) <= SER_MATCH_DT and integ[i][0] is not None:
                res_sp.append(hs - (s.hs0 - integ[i][0]))
        if used:
            n_seg += 1
        if len(tl) >= 5:
            coef = lstsq([[t - s.t0, 1.0] for t in tl], hl)     # 以 t0 为原点，免得 t≈数千秒时正规方程病态
            if coef:
                slopes.append(-coef[0])
                sp = [fr["tot"] for fr in fr_after if fr.get("tot") is not None and tl[0] <= fr["t"] <= tl[-1]]
                means.append(sum(sp) / len(sp) if sp else None)
        for a, b in zip(s.ser, s.ser[1:]):
            t1, h1, f1 = a[0], a[1], a[5]
            t2, h2, f2 = b[0], b[1], b[5]
            consecutive = f1 is not None and f2 == f1 + 1
            if 0 < t2 - t1 < 0.05:
                n_pairs_t += 1
                if not consecutive:
                    n_pairs_skip += 1
            if not consecutive:
                continue
            i1 = bisect.bisect_left(ft, t1 - SER_MATCH_DT)
            i2 = bisect.bisect_left(ft, t2 - SER_MATCH_DT)
            g1 = frames[i1].get("gdt") if i1 < len(ft) and abs(ft[i1] - t1) <= SER_MATCH_DT else None
            g2 = frames[i2].get("gdt") if i2 < len(ft) and abs(ft[i2] - t2) <= SER_MATCH_DT else None
            if g1 is not None and g2 is not None:
                dgdt1.append((h1 - h2) - g1)
                dgdt0.append((h1 - h2) - g2)
    a_rt = [abs(x) for x in res_rt]
    a_sp = [abs(x) for x in res_sp]
    a1 = [abs(x) for x in dgdt1]
    a0 = [abs(x) for x in dgdt0]
    return {
        "segs": n_seg, "n_rt": len(res_rt), "n_sp": len(res_sp),
        "rt_mad": med(a_rt), "rt_p90": quant(a_rt, 0.9), "rt_max": max(a_rt) if a_rt else None,
        "sp_mad": med(a_sp), "sp_p90": quant(a_sp, 0.9), "sp_max": max(a_sp) if a_sp else None,
        "slope_med": med(slopes), "slope_vs_speed_r": pearson(slopes, means),
        "speed_mean_med": med([m for m in means if m is not None]),
        "n_dgdt": len(dgdt1), "dgdt1_mad": med(a1), "dgdt1_p90": quant(a1, 0.9),
        "dgdt0_mad": med(a0), "dgdt0_p90": quant(a0, 0.9),
        "lag": None if not a1 else (1 if med(a1) <= med(a0) else 0),
        "pairs_time": n_pairs_t, "pairs_skip": n_pairs_skip,
        "model": None if not a_rt else ("realtime" if (not a_sp or med(a_rt) <= med(a_sp)) else "speed"),
    }


# ---------------------------------------------------------------- C4/C5：估计量
def run_estimators(seg, frames, hs0_model):
    """每帧 (t, hs, hs_from_ser, {估计量: 预测激活时刻}, {估计量: 这一帧退回了 E2t})。
    frames = initData 之后的 EMF 行；第一行若就是锚点（initData 之后 0.1 s 内的第一条 EMF），E3/E4 以它为起点：
    N1 = N0 − 积分到锚点的进度（审查 F3：不用 initData 时的快照，它可能还是上一个动作 / motion）。
    E3/E3a 在 motion 变了（mid ≠ 锚点）、E4 在动作变了（act ≠ 锚点）、或没有锚点时退回 E2t，不记空。"""
    if seg.hs0 is None:
        return []
    n0 = seg.hs0 if hs0_model == "nominal" else seg.hs0 * (seg.tot0 or 1.0)
    integ = integrate(seg, frames)
    integ2 = integrate_speeds(seg, frames)       # 1.2：速度来源（E2c 等）
    anc = seg.anc if (seg.anc is not None and frames and frames[0]["t"] == seg.anc["t"]) else None
    n1 = (n0 - integ[0][0]) if (anc is not None and integ[0][0] is not None) else None
    out = []
    for fr, (ct, cm, cg), (cum2, v2) in zip(frames, integ, integ2):
        t = fr["t"]
        hs, from_ser = seg.hs_at(t)
        tot, ms, mf, ace = fr.get("tot"), fr.get("ms"), fr.get("mf"), fr.get("ace")
        est = {"E0": None if hs is None else t + hs / 60.0}
        good_t = tot is not None and tot >= SPEED_MIN
        good_m = ms is not None and ms >= SPEED_MIN
        est["E1"] = t + hs / (60.0 * tot) if (good_t and hs is not None) else None
        est["E2t"] = t + (n0 - ct) / (60.0 * tot) if (good_t and ct is not None) else None
        est["E2m"] = t + (n0 - cm) / (60.0 * ms) if (good_m and cm is not None) else None
        est["E2g"] = t + (n0 - cg) / (60.0 * tot) if (good_t and cg is not None) else None
        for name in SPEED_NAMES:
            v, c = v2[name], cum2[name]
            est[name] = t + (n0 - c) / (60.0 * v) if (v is not None and v >= SPEED_MIN and c is not None) else None
        e2t = est["E2t"]
        fb = {}
        same_mid = anc is not None and fr.get("mid") is not None and fr.get("mid") == anc.get("mid")
        same_act = anc is not None and fr.get("act") is not None and fr.get("act") == anc.get("act")
        if good_m and mf is not None and n1 is not None and anc.get("mf") is not None and same_mid:
            est["E3"] = t + (anc["mf"] + n1 - mf) / (60.0 * ms)
        else:
            est["E3"], fb["E3"] = e2t, True
        if good_m and mf is not None and seg.ast is not None and same_mid:
            est["E3a"] = t + (seg.ast - mf) / (60.0 * ms)
        else:
            est["E3a"], fb["E3a"] = e2t, True
        if good_t and ace is not None and n1 is not None and anc.get("ace") is not None and same_act:
            est["E4"] = t + (anc["ace"] + n1 / 60.0 - ace) / tot
        else:
            est["E4"], fb["E4"] = e2t, True
        out.append((t, hs, from_ser, est, fb))
    return out


def decision_frame(rows, h):
    for i, row in enumerate(rows):
        hs = row[1]
        if hs is not None and hs <= h:
            return i
    return None


def hitch_between(frames, ta, tb):
    """(ta, tb] 里有没有卡顿或缺帧：引擎帧时长 >2 帧，或相邻两条 EMF 的帧开头间隔 >35 ms（审查 F5：写盘之类的卡顿
    会让这段时间的推进和预测都失真，混进主表会主导 |r| 最大值和 P95）。"""
    prev_t = None
    for fr in frames:
        if fr["t"] <= ta:
            prev_t = fr["t"]
            continue
        if fr["t"] > tb:
            break
        if fr.get("gdt") is not None and fr["gdt"] > HITCH_GDT:
            return True
        if prev_t is not None and fr["t"] - prev_t > HITCH_DT:
            return True
        prev_t = fr["t"]
    return False


def c4_eval(segs, hs0_model, decisions, trusted=True, keep=None, samples=None):
    """返回 ({h: {估计量: [(species, 残差)]}}, 每段每帧的估计, 附加信息)。
    trusted=True 只用 cids 口径（通过零假设对照）的真值；False 只用时间窗口径的（仅供参考）。
    决策点到真值之间有卡顿 / 缺帧的样本不进表，计数在 info["hitch"]；E3/E3a/E4 在决策点退回 E2t 的次数在 info["fallback"]。
    1.2：keep 给了就只用 keep(s) 为真的段（不给 = 和 1.1 一样全用）；samples 给一个列表时，把每个进表的样本
    {s, h, i, rows, frames, tt} 追加进去（C7 用，保证和 C4 是同一套样本）。"""
    table = {h: defaultdict(list) for h in decisions}
    per_seg = {}
    info = {"hitch": Counter(), "n_dec": Counter(), "fallback": {h: Counter() for h in decisions}}
    for s in segs:
        if keep is not None and not keep(s):
            continue
        tt = s.t_act
        if tt is None or s.hs0 is None or s.is_shell:
            continue
        if trusted and not s.truth_ok:
            continue
        if not trusted and s.act_how != "window":
            continue
        frames = s.atp.frames(s.em, s.t0, tt + 0.05)
        if not frames:
            continue
        rows = run_estimators(s, frames, hs0_model)
        per_seg[id(s)] = rows
        for h in decisions:
            if s.hs0 < h + 5:
                continue
            i = decision_frame(rows, h)
            if i is None or rows[i][0] >= tt:
                continue
            if hitch_between(frames, rows[i][0], tt):
                info["hitch"][h] += 1
                continue
            info["n_dec"][h] += 1
            for name in FALLBACK_EST:
                if rows[i][4].get(name):
                    info["fallback"][h][name] += 1
            for name in EST_NAMES:
                p = rows[i][3].get(name)
                if p is not None:
                    table[h][name].append((s.species, tt - p))
            if samples is not None:
                samples.append({"s": s, "h": h, "i": i, "rows": rows, "frames": frames, "tt": tt})
    return table, per_seg, info


def summarize_resid(pairs):
    r = [x for _, x in pairs]
    a = [abs(x) for x in r]
    return {"n": len(r), "med": med(r), "q25": quant(r, 0.25), "q75": quant(r, 0.75), "p90": quant(a, 0.9),
            "max": max(a) if a else None, "mad": med(a)}


def lomo_bias(pairs):
    """留一只怪：偏置 = 其余怪残差的中位数；返回 {怪: 修正后残差列表}。"""
    sp = sorted(set(k for k, _ in pairs))
    out = {}
    for h in sp:
        train = [x for k, x in pairs if k != h]
        if not train:
            continue
        b = med(train)
        out[h] = [x - b for k, x in pairs if k == h]
    return out


def catch_vector(rows, name, t_ct):
    """放刀规则「预测剩余时间 ≤ λ 的第一帧放」对 LAMBDA_GRID 每个 λ 是否接住。
    第一帧满足 rem ≤ λ 的位置 = 前缀最小值第一次 ≤ λ 的位置（前缀最小值单调不增，可以二分）。"""
    ts, neg = [], []
    m = math.inf
    for row in rows:
        t, est = row[0], row[3]
        p = est.get(name)
        if p is None:
            continue
        m = min(m, p - t)
        ts.append(t)
        neg.append(-m)          # 单调不减
    out = []
    for lam in LAMBDA_GRID:
        k = bisect.bisect_left(neg, -lam)
        if k >= len(ts):
            out.append(False)
            continue
        d = t_ct - ts[k]
        out.append(W0 <= d <= W1)
    return out


def choose_lambda(vecs):
    """vecs：每个样本的接住向量。返回（接住最多的 λ 们的中间那个，接住数）。"""
    if not vecs:
        return None, 0
    sums = [sum(v[i] for v in vecs) for i in range(len(LAMBDA_GRID))]
    best = max(sums)
    best_l = [LAMBDA_GRID[i] for i, x in enumerate(sums) if x == best]
    return best_l[len(best_l) // 2], best


def c5_catch(segs, hs0_model):
    """只用「最早一段」+ 有接触的条目：按 λ 规则放刀，接触落进 [W0, W1] 算接住。留一只怪选 λ。"""
    vec_by_sp = defaultdict(lambda: defaultdict(list))
    n_by_sp = Counter()
    n_hitch = 0
    for s in segs:
        if not s.lead or s.t_ct is None or s.hs0 is None or s.is_shell:
            continue
        frames = s.atp.frames(s.em, s.t0, s.t_ct + 0.01)
        if not frames:
            continue
        # 审查 F5：放刀到接触之间有卡顿的样本单列。放刀最早在接触前 λ_max + W1 ≈ 1.95 s，所以只看接触前 2 s
        if hitch_between(frames, max(s.t0, s.t_ct - (max(LAMBDA_GRID) + W1 + 0.05)), s.t_ct):
            n_hitch += 1
            continue
        rows = run_estimators(s, frames, hs0_model)
        n_by_sp[s.species] += 1
        for name in EST_NAMES:
            vec_by_sp[s.species][name].append(catch_vector(rows, name, s.t_ct))
    species = sorted(n_by_sp)
    out = {}
    for name in EST_NAMES:
        allv = [v for sp in species for v in vec_by_sp[sp][name]]
        lam_all, ok_all = choose_lambda(allv)
        lomo_ok, lomo_n, per_sp = 0, 0, {}
        for h in species:
            train = [v for sp in species if sp != h for v in vec_by_sp[sp][name]]
            if not train:
                continue
            lam, _ = choose_lambda(train)
            test = vec_by_sp[h][name]
            li = LAMBDA_GRID.index(lam) if lam is not None else None
            ok = sum(1 for v in test if li is not None and v[li])
            per_sp[h] = (ok, len(test), lam)
            lomo_ok += ok
            lomo_n += len(test)
        out[name] = {"insample_lambda": lam_all, "insample_ok": ok_all, "n": len(allv), "lomo_ok": lomo_ok,
                     "lomo_n": lomo_n, "per_species": per_sp}
    return out, dict(n_by_sp), n_hitch


# ---------------------------------------------------------------- C6：速度
def c6_speed(segs):
    by_sp = defaultdict(lambda: {"n": 0, "mean": [], "min": [], "max": [], "dev_time": [], "comp_dev": Counter()})
    for s in segs:
        spd_fields = s.atp.spd_fields or []
        if s.hs0 is None or s.t0 is None:
            continue
        t_end = s.t_act if s.t_act is not None else s.t0 + max(s.hs0, 0.0) / 60.0
        frames = s.atp.frames(s.em, s.t0, t_end)
        sp = [(fr["t"], fr["tot"]) for fr in frames if fr.get("tot") is not None]
        if len(sp) < 2:
            continue
        d = by_sp[s.species]
        d["n"] += 1
        tw = sum(b[0] - a[0] for a, b in zip(sp, sp[1:]))
        if tw > 0:
            d["mean"].append(sum(b[1] * (b[0] - a[0]) for a, b in zip(sp, sp[1:])) / tw)
            d["dev_time"].append(sum((b[0] - a[0]) for a, b in zip(sp, sp[1:]) if abs(b[1] - 1.0) > 0.01) / tw)
        d["min"].append(min(x[1] for x in sp))
        d["max"].append(max(x[1] for x in sp))
        for t, comp in s.atp.emspd.get(s.em, []):
            if s.t0 - 0.5 <= t <= t_end and isinstance(comp, str):
                for i, x in enumerate(comp.split("/")):
                    v = fnum(x)
                    if v is not None and abs(v - 1.0) > 0.001:
                        d["comp_dev"][spd_fields[i] if i < len(spd_fields) else f"#{i}"] += 1
    return by_sp


# ---------------------------------------------------------------- C7：速度来源（1.2）
def c7_profile(s, ta, tb):
    """(ta, tb] 里这只怪的 EMF 帧上重建的分量：Sequence×BlendTree、Scale 有没有 ≠1，CoreState 有没有 <1，取值。"""
    atp = s.atp
    ix = getattr(atp, "spd_ix", None) or {}
    out = {"n": 0, "seq": False, "scale": False, "core_lt1": False, "q": set(), "core_min": None, "bt": False,
           "tot1": 0}
    if "_CoreState" not in ix:
        return out
    for fr in atp.frames(s.em, ta, tb):
        c = atp.comp_at(s.em, fr["t"])
        if c is None:
            continue
        out["n"] += 1
        tot = fr.get("tot")
        if tot is not None and abs(tot - 1.0) < 1e-4 and abs(comp_prod(c) - 1.0) > COMP_MATCH:
            out["tot1"] += 1        # tot 被置成 1 而分量不是 1 的帧（见 c7_recon），E2t 和 E2c 在这里也会分开
        if abs(comp_get(c, ix, "_BlendTree", 1.0) - 1.0) > COMP_DEV:
            out["bt"] = True
        q = comp_get(c, ix, "_Sequence", 1.0) * comp_get(c, ix, "_BlendTree", 1.0)
        if abs(q - 1.0) > COMP_DEV:
            out["seq"] = True
            out["q"].add(round(q, 3))
        if abs(comp_get(c, ix, "_Scale", 1.0) - 1.0) > COMP_DEV:
            out["scale"] = True
        core = comp_get(c, ix, "_CoreState")
        if core is not None:
            out["core_min"] = core if out["core_min"] is None else min(out["core_min"], core)
            out["core_lt1"] = out["core_lt1"] or core < 1.0 - COMP_DEV
    return out


def c7_recon(atps):
    """逐帧检查分量重建：∏分量 = tot（对上）/ 分量变化那一帧 tot 还是上一组的积（lag，tot 晚一帧更新）/ tot 被置成 1
    而分量不是 1（tot1；stageA 实测 11 段，同时 ace 停走，推测是特殊状态）/ 其他对不上 / 没有分量 / tot 读不到。"""
    out = Counter()
    for atp in atps:
        if "_CoreState" not in (getattr(atp, "spd_ix", None) or {}):
            continue
        for em, rows in atp.emf.items():
            prev = None
            for r in rows:
                c = atp.comp_at(em, r["t"])
                tot = r.get("tot")
                if c is None:
                    out["nocomp"] += 1
                elif tot is None:
                    out["notot"] += 1
                elif comp_prod(c) > 0 and abs(tot / comp_prod(c) - 1.0) <= COMP_MATCH:
                    out["match"] += 1
                elif prev is not None and prev != c and comp_prod(prev) > 0 and abs(tot / comp_prod(prev) - 1.0) <= COMP_MATCH:
                    out["lag"] += 1
                elif abs(tot - 1.0) < 1e-4:
                    out["tot1"] += 1
                else:
                    out["miss"] += 1
                prev = c
    return out


C7_RATE = [("tot", None), ("CoreState", "E2c"), ("CoreState×Scale", "E2cs"), ("tot÷(Sequence×BlendTree)", "E2nseq")]


def _rate_windows(atp, em, run, win, res):
    ix = atp.spd_ix
    for i0 in range(0, len(run) - win, win):
        w = run[i0:i0 + win + 1]
        cs = [atp.comp_at(em, r["t"]) for r in w]
        if any(c is None for c in cs[1:]):
            continue
        dmf = w[-1]["mf"] - w[0]["mf"]
        seq = any(abs(comp_get(c, ix, "_Sequence", 1.0) * comp_get(c, ix, "_BlendTree", 1.0) - 1.0) > COMP_DEV
                  for c in cs[1:])
        for label, key in C7_RATE:
            acc0 = acc1 = 0.0
            for k in range(1, len(w)):
                v = w[k]["tot"] if key is None else speed_value(key, w[k]["tot"], cs[k], ix)
                if v is None:
                    acc0 = None
                    break
                acc0 += v * w[k]["gdt"]           # 同一行的 gdt
                acc1 += v * w[k - 1]["gdt"]       # 上一行的 gdt
            if acc0 is not None:
                res[seq][(label, 0)].append(dmf - acc0)
                res[seq][(label, 1)].append(dmf - acc1)


def c7_motion_rate(atps, win=C7_WIN):
    """机制旁证：动作层帧号 mf（TreeLayer 0 的 Frame，即动画）的累计推进 vs 各速度的累计积分。同一只怪、ATP 帧号连续、
    同一个 motion、mf 不倒退的 win 帧窗口：Δmf − Σ v_k·gdt（gdt 两种配法都算：同一行 / 上一行。stageA 实测动画配同一行，
    |差| 在 0.001 帧量级；hs 的倒数配的是上一行，见 C2；报告里用 Seq×BT = 1 的窗口上 tot 对得最好的那种）。
    按窗口里 Sequence×BlendTree 有没有 ≠1 分组：res[有没有][(速度, 配法)] = [差]。
    哪个速度的差 ≈ 0，动画就按哪个速度播 —— 但攻击激活不一定跟动画走，那要看 c7_progress 和 C7.4。"""
    res = {True: defaultdict(list), False: defaultdict(list)}
    for atp in atps:
        if "_CoreState" not in (getattr(atp, "spd_ix", None) or {}):
            continue
        for em, rows in atp.emf.items():
            run = []
            for r in rows:
                good = (r.get("mf") is not None and r.get("tot") is not None and r.get("gdt") is not None
                        and r.get("mid") is not None and isinstance(r.get("f"), int))
                if run and (not good or r["f"] != run[-1]["f"] + 1 or r["mid"] != run[-1]["mid"]
                            or r["mf"] < run[-1]["mf"]):
                    _rate_windows(atp, em, run, win, res)
                    run = []
                if good:
                    run.append(r)
            _rate_windows(atp, em, run, win, res)
    return res


def c7_progress(segs, keep, model):
    """激活时刻（真值）的名义进度 − N0（帧）：从 initData 起按 tot（E2t 的 integrate）/ 按 CoreState（E2c 的积分）积到
    真值之前最后一行 EMF，再按那一行的速度外推到真值时刻。名义帧模型下这个差应当贴着全局偏移 b（SPEED.md：约 −1.3 帧），
    而且和 Sequence 无关：哪种积分在 Sequence×BlendTree ≠1 的段上也贴着 b，激活就按哪个速度走。不依赖决策点。
    返回 {(真值口径, "seq"/"noseq"): {"tot": [...], "core": [...]}}。"""
    out = defaultdict(lambda: defaultdict(list))
    for s in segs:
        if not keep(s) or s.t_act is None or s.hs0 is None or s.is_shell or s.act_how not in ("cids", "window"):
            continue
        tt = s.t_act
        pre = s.atp.frames(s.em, s.t0, tt)
        if not pre:
            continue
        n0 = s.hs0 if model == "nominal" else s.hs0 * (s.tot0 or 1.0)
        last = pre[-1]
        key = (s.act_how, "seq" if c7_profile(s, s.t0, tt)["seq"] else "noseq")
        ct = integrate(s, pre)[-1][0]
        if ct is not None and last.get("tot") is not None:
            out[key]["tot"].append(ct + 60.0 * last["tot"] * (tt - last["t"]) - n0)
        cum, vs = integrate_speeds(s, pre)[-1]
        if cum.get("E2c") is not None and vs.get("E2c") is not None:
            out[key]["core"].append(cum["E2c"] + 60.0 * vs["E2c"] * (tt - last["t"]) - n0)
    return out


def c7_samples(segs, model, decisions, trusted, keep):
    """C7 的样本 = C4 的样本（c4_eval 的 samples，同一套决策点、卡顿剔除、真值口径），再带上各估计量的预测、残差，
    以及 initData 到真值之间的分量情况（c7_profile）。"""
    raw = []
    c4_eval(segs, model, decisions, trusted=trusted, keep=keep, samples=raw)
    recs = []
    for x in raw:
        s, i, tt = x["s"], x["i"], x["tt"]
        est = x["rows"][i][3]
        act = (s.anc.get("act") if s.anc else None) or s.act0
        recs.append({"sp": s.species, "act": act, "h": x["h"], "tt": tt, "pred": {n: est.get(n) for n in EST_NAMES},
                     "res": {n: (tt - est[n]) if est.get(n) is not None else None for n in EST_NAMES},
                     "prof": c7_profile(s, s.t0, tt)})
    return recs


def theil_sen(xs, ys, min_dx=0.005):
    """Theil–Sen 斜率（两两斜率的中位数；x 差不到 min_dx 的对不算）。重抽时要算几百次，所以就地排序取中位，不走 quant。"""
    sl = []
    n = len(xs)
    for i in range(n):
        xi, yi = xs[i], ys[i]
        for j in range(i + 1, n):
            dx = xs[j] - xi
            if dx >= min_dx or dx <= -min_dx:
                sl.append((ys[j] - yi) / dx)
    if not sl:
        return None
    sl.sort()
    m = len(sl)
    return sl[m // 2] if m % 2 else 0.5 * (sl[m // 2 - 1] + sl[m // 2])


def boot_slope(recs, xf, yf, n_boot=C7_BOOT, seed=17):
    """Theil–Sen 斜率的 90% 区间：按招（怪种 + 动作）整簇重抽 —— 同一招的样本彼此不独立。簇少于 3 个 → None。"""
    groups = defaultdict(list)
    for r in recs:
        groups[(r["sp"], r["act"])].append(r)
    keys = sorted(groups, key=str)
    if len(keys) < 3:
        return None
    rng = random.Random(seed)
    vals = []
    for _ in range(n_boot):
        smp = [r for _ in keys for r in groups[keys[rng.randrange(len(keys))]]]
        b = theil_sen([xf(r) for r in smp], [yf(r) for r in smp])
        if b is not None:
            vals.append(b)
    if len(vals) < n_boot // 2:
        return None
    return quant(vals, 0.05), quant(vals, 0.95)


def c7_pair(recs, a="E2c", b="E2t", boot=True):
    """两种假设的配对比较：x = T̂_b − T̂_a（决策点上两者的预测差），y = 真值 − T̂_a（a 的残差）。
    a 对 → y 和 x 无关（斜率 ≈ 0）；b 对 → y ≈ x + 常数（斜率 ≈ 1）。也数一数谁的 |残差| 更小。"""
    rr = [r for r in recs if r["pred"].get(a) is not None and r["pred"].get(b) is not None]
    xs = [r["pred"][b] - r["pred"][a] for r in rr]
    ys = [r["res"][a] for r in rr]
    out = {"n": len(rr), "a": a, "b": b, "better": sum(1 for r in rr if abs(r["res"][a]) < abs(r["res"][b])),
           "worse": sum(1 for r in rr if abs(r["res"][a]) > abs(r["res"][b])), "x_med": med(xs),
           "x_sd": statistics.pstdev(xs) if len(xs) >= 2 else None, "n_strong": sum(1 for x in xs if abs(x) >= C7_STRONG),
           "slope": theil_sen(xs, ys) if len(xs) >= 3 else None, "ci": None, "boot": False,
           "sp": sorted(set(r["sp"] for r in rr)), "q": sorted(set(q for r in rr for q in r["prof"]["q"])),
           "x_absmax": max((abs(x) for x in xs), default=None)}
    if boot and len(rr) >= 5:
        out["boot"] = True
        out["ci"] = boot_slope(rr, lambda r: r["pred"][b] - r["pred"][a], lambda r: r["res"][a])
    return out


def c7_verdict(pair):
    """按斜率的 90% 区间判：上限 < 0.5 → 只积 CoreState（core）；下限 > 0.5 → 积 tot（tot）；
    样本少（< 8）、预测差太集中（标准差 < 0.02 s，斜率没意义）、区间跨过 0.5 → 分不开（undecided）。"""
    if not pair or pair["n"] < 8 or pair["ci"] is None or (pair["x_sd"] or 0.0) < 0.02:
        return "undecided"
    lo, hi = pair["ci"]
    if hi < 0.5:
        return "core"
    if lo > 0.5:
        return "tot"
    return "undecided"


# ---------------------------------------------------------------- 报告
class Report:
    def __init__(self):
        self.lines = []

    def h(self, text, level=2):
        self.lines.append("")
        self.lines.append("#" * level + " " + text)
        self.lines.append("")

    def p(self, text=""):
        self.lines.append(text)

    def table(self, header, rows):
        def cell(x):
            return str(x).replace("|", "\\|")    # 单元格里的 | 会把表格拆开（「|残差|」这种）
        self.lines.append("| " + " | ".join(cell(x) for x in header) + " |")
        self.lines.append("|" + "|".join("---" for _ in header) + "|")
        for r in rows:
            self.lines.append("| " + " | ".join(cell(x) for x in r) + " |")
        self.lines.append("")

    def text(self):
        return "\n".join(self.lines) + "\n"


def session_overview(rep, atp, ap, picked, segs):
    rep.p(f"**ATP session {atp.session}**")
    rep.p(f"- ATP 文件 {len(atp.files)} 个（缺号 {atp.missing_seq or '无'}，最后一份 why={atp.last_why}），记录种类："
          + "，".join(f"{k} {v}" for k, v in sorted(atp.kinds.items(), key=lambda x: str(x[0]))))
    if atp.bad_files:
        rep.p(f"- 读不了的文件：{atp.bad_files}")
    if atp.selftest:
        rep.p(f"- 加载自检 {atp.selftest.get('ok')}/{atp.selftest.get('total')}，缺：{atp.selftest.get('failed') or '无'}")
    if atp.errs:
        acts = Counter((e.get("mod"), e.get("act") or ("stop" if num(e.get("stop")) == 1 else "err")) for e in atp.errs)
        rep.p(f"- ERR {len(atp.errs)} 条（模块:出错/暂停/停用）：" + "，".join(
            f"{m}:{a} ×{n}" for (m, a), n in sorted(acts.items(), key=lambda x: (str(x[0][0]), str(x[0][1])))))
        rep.p("  - 最早几条：" + "；".join(f"{e.get('mod')}:{str(e.get('msg'))[:80]}" for e in atp.errs[:4]))
    if atp.guards:
        rep.p("- 守卫停用（GUARD）：" + "；".join(f"{g.get('mod')} @{fmt(num(g.get('t')), 1)}：{g.get('why')}"
                                              for g in atp.guards))
    if atp.perf:
        ips = [num(r.get("init_ps")) for r in atp.perf]
        raw = [num(r.get("init_raw_ps")) for r in atp.perf if r.get("init_raw_ps") is not None]
        hms = [num(r.get("hook_ms_ps")) for r in atp.perf]
        fms = [num(r.get("frame_ms_avg")) for r in atp.perf]
        fps = [num(r.get("fps")) for r in atp.perf]
        rep.p(f"- PERF：fps 中位 {fmt(med(fps), 1)}；initData 记录 {fmt(med(ips), 1)} 次/秒（最大 "
              f"{fmt(max([x for x in ips if x is not None] or [0]), 1)}），钩子被调（原始，停用后照样计）中位 "
              f"{fmt(med(raw), 1)} 最大 {fmt(max(raw) if raw else None, 1)} 次/秒；钩子 {fmt(med(hms), 2)} ms/秒，"
              f"EMF 每帧 {fmt(med(fms), 3)} ms；post 拿到别人的记录（depth>1）"
              f"{sum(int(num(r.get('deep')) or 0) for r in atp.perf)} 次，孤儿 pre {sum(int(num(r.get('orphan')) or 0) for r in atp.perf)} 次")
        mon = {k: sum(int(num(r.get(k)) or 0) for r in atp.perf) for k in ("mon_full", "mon_evict", "mon_noidx", "mon_bad")}
        rep.p(f"- 监视表：满员没盯上的 initData {mon['mon_full']} 次，为打主角的怪挤掉 {mon['mon_evict']} 次，"
              f"没有 SystemIndex 盯不了 {mon['mon_noidx']} 次，读数坏掉踢出 {mon['mon_bad']} 次"
              "（满员没盯上的多是打随从 / NPC 的；打主角的一定拿得到位置）")
        merr = [r.get("merr") for r in atp.perf if r.get("merr")]
        if merr:
            rep.p(f"- 各模块出错 / 暂停（最后一条 PERF）：{merr[-1]}")
    whys = Counter(f.get("why") for f in atp.files)
    rep.p("- 写盘原因：" + "，".join(f"{k} {v}" for k, v in whys.most_common())
          + "（hard = 一直有预告在倒数、等够了才写，那几帧可能卡顿，C4/C5 会按帧时长剔除）")
    ctxs = Counter(r.get("ctx") for r in atp.inits)
    deep = sum(1 for r in atp.inits if (num(r.get("depth")) or 1) > 1)
    same = sum(1 for r in atp.inits if num(r.get("same")) == 1)
    ex = getattr(atp, "excl", None) or {"n": 0, "by": {}, "frames": 0}
    rep.p(f"- INIT {len(atp.inits)} 条，线程上下文 {len(ctxs)} 种（1 种 = 单线程调用，pre/post 配对可靠），"
          f"depth>1 {deep} 条，ORPH {len(atp.orph)} 条，初始化前后 hs/he 不变 {same} 条")
    rep.p(f"- **剔除** pre/post 可能配错的 INIT {ex['n']} 条（{ex['frames']} 帧；"
          + ("，".join(f"{k} {v}" for k, v in sorted(ex["by"].items())) or "无")
          + "）：同一帧有 depth>1、ORPH 或多个线程上下文就整帧剔除（审查 F8）")
    ems = Counter(r.get("ems") for r in atp.inits if r.get("ems"))
    if ems:
        rep.p("- em 编号不是当场读到的 INIT：" + "，".join(f"{k} {v}" for k, v in ems.items())
              + "（stale = 用这个地址上次读到的编号，none = 读不到、em 写成 @地址、不进监视表）")
    both = [(num(r.get("sgl")), num(r.get("sgl2"))) for r in atp.inits if num(r.get("sgl2")) is not None]
    if both:
        agree = sum(1 for a, b in both if a is not None and abs(a - b) <= 1e-3)
        rep.p(f"- Single 参数两种解码（栈槽低 32 位自己解 / sdk.to_float）一致 {pct(agree, len(both))}"
              "（不一致说明 REF 对浮点参数另有处理，sgl 要重新解释）")
    rts = Counter(r.get("rt") for r in atp.inits)
    rep.p("- initData 刚返回时的 ResultType：" + "，".join(f"{k} {v}" for k, v in rts.most_common()))
    if atp.gars:
        tagged = sum(1 for r in atp.inits if r.get("gar") is not None)
        rep.p(f"- 建结果调用（GAR）{len(atp.gars)} 次，其中目标是主角 {sum(1 for g in atp.gars if g.get('tme') == 1)} 次；"
              f"在建结果调用里发生的 initData {pct(tagged, len(atp.inits))}")
    caps = defaultdict(Counter)
    for sg_ in segs:
        c = sg_.r.get("cap")
        if isinstance(c, str) and c.count(",") >= 4:
            caps["对上 SER" if sg_.linked else "没对上"][c.split(",")[4]] += 1
    if caps:
        rep.p("- 目标胶囊半径 r（对上 SER = 打主角的条目）：" + "；".join(
            f"{k} " + "，".join(f"r={r} ×{n}" for r, n in v.most_common(4)) for k, v in sorted(caps.items())))
    by_sp = Counter(x.species for x in segs)
    rep.p("- 条目片段（一次 initData 一段）按怪：" + "，".join(f"{k} {v}" for k, v in sorted(by_sp.items())))
    if ap is None:
        rep.p("- **没有同一次游戏的 APCal 数据**：这个 session 只进 C1、C6；C2~C5 需要 APCal 的 SER/ATK/CT。"
              "下次把 AutoParryCalib.lua 和 AttackTimingProbe.lua 一起放进 autorun。")
    else:
        linked = [x for x in segs if x.linked]
        rep.p(f"- APCal session {picked}（{ap.n_records} 条记录）；对上 SER 的片段 {pct(len(linked), len(segs))}"
              f"（对不上的多半是怪物打的是别的目标，比如随从）")
        if ap.atk_dead:
            dead = sum(min(d1, ap.t_max) - d0 for d0, d1 in ap.atk_dead if d0 < ap.t_max)
            span = (ap.t_max - ap.t_min) if ap.t_max is not None else 0
            rep.p(f"- **APCal 的 ATK 钩子被它自己的频率守卫停过** {len(ap.atk_dead)} 次，没有 ATK 的时间 {fmt(dead, 0)} s / "
                  f"{fmt(span, 0)} s：这段时间的片段不定 ATK 真值、不进零假设（CT 照用）。"
                  "下次采数据避开一大群小怪的地方，看到 APCal 菜单里 ATK 停了就 Reset Scripts")
    rep.p()


def c7_cells(recs, name):
    return summarize_resid([(r["sp"], r["res"][name]) for r in recs if r["res"].get(name) is not None])


def c7_slope_txt(pr):
    if pr is None or pr.get("slope") is None:
        return "-"
    if not pr.get("boot"):
        return fmt(pr["slope"], 2)
    ci = pr.get("ci")
    return fmt(pr["slope"], 2) + (f"（{fmt(ci[0], 2)}~{fmt(ci[1], 2)}）" if ci else "（招不到 3 个，没有区间）")


def c7_pair_rows(label, h, sub, pr):
    cells = [label, fmt(h, 0), f"{len(sub)}（{'、'.join(pr['sp']) or '-'}）"]
    for n in ("E0", "E2t", "E2c", "E2nseq", "E3a"):
        sm = c7_cells(sub, n)
        cells.append(f"{fmt(sm['med'])} / {fmt(sm['mad'])}")
    cells += [f"{pr['better']} : {pr['worse']}", fmt(pr["x_med"]), c7_slope_txt(pr)]
    return cells


C7_PAIR_HEADER = ["真值口径", "决策点", "n（怪）", "E0", "E2t", "E2c", "E2nseq", "E3a", "|r| 更小：E2c : E2t",
                  "E2t−E2c 中位", "斜率（90% 区间）"]
VERDICT_TXT = {"core": "只积 CoreState", "tot": "积 tot", "undecided": "分不开"}


def c7_section(rep, segs, groups, model, decisions, any_trusted):
    """C7：修正时该积分哪一个速度。返回写进 summary 的字典。"""
    atps = [g[0] for g in groups]
    summ = {}
    rep.h("C7 速度来源：修正时该积分哪一个速度（1.2）")
    rep.p("背景：docs/autoparry/SPEED.md 2.1 g 用旧数据（EMINFO 稀疏采样，只有 Action/Random/CoreState/ScaleAdjusted/"
          "Replica/WaitPacket 六个分量）推断 tot 里还有一个动作级因子、它已经算进名义帧，所以只积 CoreState（v1.6 的 E5c）。"
          "ATP 每帧有 tot（_TotalMotionSpeedThisFream），分量变化时有 EMSPD（12 个分量，含 Sequence/BlendTree），这里直接比。"
          "新估计量的积分框架和 E2t 完全一样，只换积分的速度：")
    rep.table(["估计量", "积分的速度"], [[n, EST_DESC[n]] for n in ["E2t"] + SPEED_NAMES])
    if not any("_CoreState" in (getattr(a, "spd_ix", None) or {}) for a in atps):
        rep.p("**没有 EMSPD 分量记录**（ATP 版本太旧，或 SPDS 模块一直停着），C7 跳过。")
        return {"skipped": "no_emspd"}
    rc = c7_recon(atps)
    n_rc = sum(rc.values())
    rep.p(f"- 分量重建（EMSPD → 每帧）：∏分量 = tot 的帧 {pct(rc['match'], n_rc)}；分量变化的那一帧 tot 还是上一组的积 "
          f"{rc['lag']} 帧（tot 晚一帧更新）；tot 被置成 1 而分量不是 1 的 {rc['tot1']} 帧；其他对不上 {rc['miss']}；"
          f"没有分量 {rc['nocomp']}、tot 读不到 {rc['notot']}")
    summ["recon"] = dict(rc)
    on = [(a, b) for atp in atps for a, b in getattr(atp, "parry_on", [])]
    fires = [t for atp in atps for t in getattr(atp, "parry_fires", [])]
    par = [s for s in segs if seg_parry(s)]

    def keep(s):
        return not seg_parry(s)

    if on:
        rep.p("- 放刀模块开着的时段（AutoParryGS 的 HDR/CFG）：" + "，".join(
            f"{fmt(a, 1)}~{fmt(b, 1) if b != math.inf else '记录结束'}" for a, b in on)
            + f"，其间真放刀 {len(fires)} 次；和这些时段重叠的片段 {len(par)} 个（"
            + ("，".join(f"{k} {v}" for k, v in sorted(Counter(s.species for s in par).items())) or "无")
            + "），不进 C7.1~C7.5，在 C7.6 单列")
    else:
        rep.p("- 没有同一次游戏的放刀模块记录（AutoParryGS_*.json），所有片段都进本节的表")
    summ["parry_on"] = [[a, None if b == math.inf else b] for a, b in on]
    summ["parry_segs"] = dict(Counter(s.species for s in par))

    # ---- C7.1 机制旁证
    rep.h("C7.1 机制旁证（不用真值）", 3)
    mr = c7_motion_rate(atps)

    def _p90(lst):
        return quant([abs(x) for x in lst], 0.9)

    # gdt 的配法：Seq×BT = 1 的窗口上 tot 对得最好的那种（stageA 实测同一行；合成数据按审查 F4 的假定是上一行）
    lag_p = {lag: _p90(mr[False].get(("tot", lag), [])) for lag in (0, 1)}
    lag = min((l for l in lag_p if lag_p[l] is not None), key=lambda l: lag_p[l], default=0)
    rows = []
    for label, _ in C7_RATE:
        a_, b_ = mr[True].get((label, lag), []), mr[False].get((label, lag), [])
        rows.append([label, len(a_), fmt(med(a_)), fmt(_p90(a_)), len(b_), fmt(med(b_)), fmt(_p90(b_))])
    rep.p(f"动作层帧号（TreeLayer 0 的 Frame，即动画）每 {C7_WIN} 帧推进的 Δmf 减去 Σ v·gdt（帧；同一只怪、帧号连续、同一个 "
          f"motion）。gdt 配{'同一行' if lag == 0 else '上一行'}（Seq×BT = 1 的窗口上 tot 的 |差| P90：同一行 "
          f"{fmt(lag_p[0])}、上一行 {fmt(lag_p[1])} 帧；hs 的倒数配的是上一行，见 C2）：")
    rep.table(["速度 v", "Seq×BT≠1 的窗口", "差 中位", "|差| P90", "其余窗口", "差 中位", "|差| P90"], rows)
    p90 = {l: _p90(mr[True][(l, lag)]) for l, _ in C7_RATE if mr[True].get((l, lag))}
    best_rate = min(p90, key=p90.get) if p90 else None
    if best_rate:
        rep.p(f"**数据**：Sequence×BlendTree ≠1 时，动画按「{best_rate}」推进（|差| P90 {fmt(p90[best_rate])} 帧 / "
              f"{C7_WIN} 帧）。这只说明动画怎么播，攻击判定跟不跟动画走，看下面的激活时刻和 C7.4。")
    summ["motion_rate_best"] = best_rate
    summ["motion_rate_lag"] = lag
    summ["motion_rate_p90_seq"] = p90
    pg = c7_progress(segs, keep, model)
    rows = []
    for how, sub in sorted(pg):
        d = pg[(how, sub)]
        rows.append(["cids（主表）" if how == "cids" else "时间窗（仅供参考）", "≠1" if sub == "seq" else "=1", len(d["core"]),
                     fmt(med(d["tot"]), 2), f"{fmt(quant(d['tot'], 0.25), 2)}~{fmt(quant(d['tot'], 0.75), 2)}",
                     fmt(med(d["core"]), 2), f"{fmt(quant(d['core'], 0.25), 2)}~{fmt(quant(d['core'], 0.75), 2)}"])
    rep.p("激活时刻（真值）的名义进度 − N0（帧）：从 initData 起按 v 积分到激活。名义帧模型下这个差应当贴着全局偏移 b"
          "（SPEED.md：约 −1.3 帧），而且和 Sequence 无关（放刀模块开着的片段不算）：")
    rep.table(["真值口径", "倒数期间 Seq×BT", "n", "按 tot 积 中位", "IQR", "按 CoreState 积 中位", "IQR"], rows)
    sq = {k: [x for (how, sub), d in pg.items() if sub == "seq" for x in d[k]] for k in ("tot", "core")}
    ns = {k: [x for (how, sub), d in pg.items() if sub == "noseq" for x in d[k]] for k in ("tot", "core")}
    if sq["core"] and ns["core"]:
        rep.p(f"**数据**：Seq×BT ≠1 的 {len(sq['core'])} 段，激活时按 CoreState 积的名义进度 − N0 中位 {fmt(med(sq['core']), 2)} 帧，"
              f"按 tot 积 {fmt(med(sq['tot']), 2)} 帧；Seq×BT = 1 的 {len(ns['core'])} 段（两者相同，= 全局偏移 b）"
              f"{fmt(med(ns['core']), 2)} 帧。")
    summ["progress"] = {f"{how}/{sub}": {k: {"n": len(v), "med": med(v)} for k, v in d.items()} for (how, sub), d in pg.items()}

    # ---- C7.2 对比表
    calibers = ([("cids", True)] if any_trusted else []) + [("window", False)]
    cal_name = {"cids": "cids 口径（主表）", "window": "时间窗口径（仅供参考）"}
    recs_by = {}
    h0 = decisions[0]
    decs = list(decisions[:2])
    summ["table"] = {}
    for how, trusted in calibers:
        recs = c7_samples(segs, model, decs, trusted, keep)
        recs_by[how] = recs
        rep.h(f"C7.2 对比表：{cal_name[how]}", 3)
        if not recs:
            rep.p("没有样本。")
            continue
        sp_n = Counter(r["sp"] for r in recs if r["h"] == h0)
        rep.p(f"样本 = C4 同一套（决策点、卡顿剔除、真值口径都一样），去掉放刀模块开着的片段；决策点 ≤{fmt(h0, 0)} 的样本按怪："
              + "，".join(f"{k} {v}" for k, v in sorted(sp_n.items())) + "。残差 = 真值 − 预测（秒，负 = 攻击早到）。")
        rows = []
        for n in C7_NAMES:
            cells = [n, EST_DESC[n]]
            for h in decs:
                sm = c7_cells([r for r in recs if r["h"] == h], n)
                cells += [sm["n"], fmt(sm["med"]), f"{fmt(sm['q25'])}~{fmt(sm['q75'])}", fmt(sm["p90"])]
                summ["table"].setdefault(how, {}).setdefault(str(int(h)), {})[n] = sm
            lb = lomo_bias([(r["sp"], r["res"][n]) for r in recs if r["h"] == h0 and r["res"].get(n) is not None])
            a = [abs(x) for v in lb.values() for x in v]
            cells += [fmt(med(a)), fmt(sum(1 for x in a if x <= 0.05) / len(a), 2) if a else "-"]
            rows.append(cells)
        header = ["估计量", "说明"]
        for h in decs:
            header += [f"≤{fmt(h, 0)} n", "中位", "IQR", "|r| P90"]
        header += [f"留一只怪 |r| 中位（≤{fmt(h0, 0)}）", "≤0.05 s"]
        rep.table(header, rows)

    # ---- C7.3 放刀模拟
    rep.h("C7.3 放刀模拟（去掉放刀模块开着的片段）", 3)
    catch, n_sp, n_h = c5_catch([s for s in segs if keep(s)], model)
    rows = []
    for n in C7_NAMES:
        c = catch[n]
        per = "，".join(f"{sp} {ok}/{nn}@{fmt(lam, 2)}" for sp, (ok, nn, lam) in sorted(c["per_species"].items()))
        rows.append([n, pct(c["lomo_ok"], c["lomo_n"]), pct(c["insample_ok"], c["n"]), fmt(c["insample_lambda"], 2),
                     per or "-"])
    rep.p("口径同 C5（「最早一段」+ 有接触，λ 留一只怪选），接触前 2 s 有卡顿的 "
          f"{n_h} 个不算；样本数按怪：" + ("，".join(f"{k} {v}" for k, v in sorted(n_sp.items())) or "无"))
    rep.table(["估计量", "留一只怪接住", "全体最优（样本内）", "全体最优 λ", "各怪（接住/样本@λ）"], rows)
    summ["catch"] = {n: {k: v for k, v in catch[n].items() if k != "per_species"} for n in C7_NAMES}

    # ---- C7.4 关键子集
    rep.h("C7.4 关键子集：倒数期间 Sequence×BlendTree ≠ 1", 3)
    rep.p("Seq×BT = 1 时 tot 就是 CoreState × 其余分量，两种假设给出一样的预测，只有这里分得开。每格是「残差中位 / |残差|中位」"
          "（秒）；「|r| 更小」= E2c、E2t 各自 |残差| 更小的样本数（一样的不算）；斜率 = E2c 的残差对「E2t − E2c 的预测差」的 Theil–Sen 斜率"
          f"（90% 区间按招整簇重抽 {C7_BOOT} 次）：≈0 → 只积 CoreState 对（Sequence 已在名义帧里），≈1 → 积 tot 对。")
    labels = [how for how in recs_by if recs_by[how]]
    if len(labels) > 1:
        recs_by["合计"] = [r for how in labels for r in recs_by[how]]
    # 「合计」只在两种口径都有关键子集样本时才单列（否则和有样本的那一种一模一样）；判定总是用合计（= 全部口径）
    with_key = [how for how in labels if any(r["prof"]["seq"] for r in recs_by[how] if r["h"] == h0)]
    show = labels + (["合计"] if len(with_key) > 1 else [])
    main_label = "合计" if "合计" in recs_by else (labels[0] if labels else None)
    lname = {"cids": "cids", "window": "时间窗", "合计": "合计"}
    pairs_store = {}
    rows, rows_s, empty = [], [], []
    for label in show + ([main_label] if main_label and main_label not in show else []):
        for h in decs:
            sub = [r for r in recs_by[label] if r["h"] == h and r["prof"]["seq"]]
            pr = c7_pair(sub)
            pairs_store[(label, h)] = pr
            if label not in show:
                continue
            if not sub:
                empty.append(f"{lname[label]} ≤{fmt(h, 0)}")
                continue
            rows.append(c7_pair_rows(lname[label], h, sub, pr))
            strong = [r for r in sub if r["pred"].get("E2t") is not None and r["pred"].get("E2c") is not None
                      and abs(r["pred"]["E2t"] - r["pred"]["E2c"]) >= C7_STRONG]
            if strong:
                rows_s.append(c7_pair_rows(lname[label], h, strong, c7_pair(strong, boot=False)))
    if rows:
        rep.table(C7_PAIR_HEADER, rows)
    if empty:
        rep.p("倒数期间 Seq×BT 一直是 1、这个子集一个样本都没有的：" + "，".join(empty) + "。")
    if rows_s:
        rep.p(f"其中两种假设在决策点的预测差 ≥ {C7_STRONG} s 的样本（分得最开的那些；不重抽，只给斜率）：")
        rep.table(C7_PAIR_HEADER, rows_s)
    pr0 = pairs_store.get((main_label, h0))
    if pr0 and pr0["q"]:
        lt = sum(1 for q in pr0["q"] if q < 1)
        rep.p(f"子集里出现过的 Seq×BT 取值：{min(pr0['q'])}~{max(pr0['q'])}（<1 的 {lt} 种、>1 的 {len(pr0['q']) - lt} 种）。")
    # 对照：Seq×BT = 1 的样本上 E2t 和 E2c 的预测差（只剩 Scale 等其余分量 + tot 晚一帧，应当很小）
    rest = c7_pair([r for r in recs_by.get(main_label, []) if r["h"] == h0 and not r["prof"]["seq"]], boot=False) \
        if main_label else None
    if rest and rest["n"]:
        rep.p(f"对照：Seq×BT = 1 的 {rest['n']} 个样本上 E2t − E2c 的预测差中位 {fmt(rest['x_med'])} s、最大 "
              f"{fmt(rest['x_absmax'])} s（只剩 Scale 等其余分量和 tot 晚一帧更新），两者在这些样本上几乎一样。")
    t1 = [r["prof"]["tot1"] for how in labels for r in recs_by[how] if r["h"] == h0 and r["prof"]["tot1"]]
    if t1:
        rep.p(f"提醒：决策点 ≤{fmt(h0, 0)} 的样本里 {len(t1)} 个在倒数期间有「tot 被置成 1」的帧（每个 {min(t1)}~{max(t1)} 帧；"
              "E2t 和 E2c 在那几帧也会分开，几帧的影响在 1 帧以内）。")
    summ["key"] = {f"{lab}/{int(h)}": {k: v for k, v in pr.items()} for (lab, h), pr in pairs_store.items()}
    summ["key_rest"] = rest
    summ["main_label"] = main_label
    key_main = [r for r in recs_by.get(main_label, []) if r["h"] == h0 and r["prof"]["seq"]] if main_label else []
    summ["key_main"] = {n: c7_cells(key_main, n) for n in C7_NAMES}

    # ---- C7.5 其他分量
    rep.h("C7.5 其他分量：Scale ≠ 1、CoreState < 1", 3)
    rows = []
    pooled = recs_by.get(main_label, []) if main_label else []
    for h in decs:
        for sub_name, flag, other in (("倒数期间 Scale ≠ 1", "scale", "E2cs"), ("倒数期间 CoreState < 1", "core_lt1", "E2c1")):
            sub = [r for r in pooled if r["h"] == h and r["prof"][flag]]
            pr = c7_pair(sub, a="E2c", b=other)
            sa, sb = c7_cells(sub, "E2c"), c7_cells(sub, other)
            rows.append([sub_name, fmt(h, 0), f"{len(sub)}（{'、'.join(pr['sp']) or '-'}）", other,
                         f"{fmt(sa['med'])} / {fmt(sa['mad'])}", f"{fmt(sb['med'])} / {fmt(sb['mad'])}",
                         f"{pr['better']} : {pr['worse']}", fmt(pr["x_med"]), c7_slope_txt(pr)])
            summ.setdefault("other", {})[f"{flag}/{int(h)}"] = {"n": len(sub), "pair": pr, "E2c": sa, other: sb}
    rep.p(f"样本 = C7.4 的「{lname.get(main_label, '-')}」；斜率 = E2c 的残差对「另一个 − E2c 的预测差」，含义同 C7.4。")
    rep.table(["子集", "决策点", "n（怪）", "对照", "E2c", "对照", "|r| 更小：E2c : 对照", "对照−E2c 中位", "斜率（90% 区间）"],
              rows)

    # ---- C7.6 放刀模块开着的片段
    rep.h("C7.6 放刀模块开着的片段（单列，不进上面的表）", 3)
    parry_pair = None
    parry_gt1 = []
    if not par:
        rep.p("没有。")
    else:
        recs_p = []
        for how, trusted in calibers:
            recs_p += c7_samples(segs, model, decs, trusted, seg_parry)
        if not recs_p:
            rep.p(f"有 {len(par)} 个片段和放刀时段重叠，但没有一个有真值、能进决策点。")
        else:
            rows = []
            for n in C7_NAMES:
                cells = [n]
                for h in decs:
                    sm = c7_cells([r for r in recs_p if r["h"] == h], n)
                    cells += [sm["n"], fmt(sm["med"]), f"{fmt(sm['q25'])}~{fmt(sm['q75'])}"]
                rows.append(cells)
            header = ["估计量"]
            for h in decs:
                header += [f"≤{fmt(h, 0)} n", "中位", "IQR"]
            rep.p("全部样本（cids、时间窗口径合在一起，真值口径分布："
                  + "，".join(f"{k} {v}" for k, v in sorted(Counter(r["sp"] for r in recs_p if r["h"] == h0).items()))
                  + "）：")
            rep.table(header, rows)
            rows = []
            for h in decs:
                sub = [r for r in recs_p if r["h"] == h and r["prof"]["seq"]]
                pr = c7_pair(sub)
                if h == h0:
                    parry_pair = pr
                    parry_gt1 = [r for r in sub if any(q > 1 for q in r["prof"]["q"])]
                if sub:
                    rows.append(c7_pair_rows("放刀开着", h, sub, pr))
            if rows:
                rep.p("其中倒数期间 Sequence×BlendTree ≠ 1 的：")
                rep.table(C7_PAIR_HEADER, rows)
            if parry_pair and parry_pair["q"]:
                txt = f"子集里出现过的 Seq×BT 取值：{min(parry_pair['q'])}~{max(parry_pair['q'])}"
                if parry_gt1:
                    a_, b_ = c7_cells(parry_gt1, "E2c"), c7_cells(parry_gt1, "E2t")
                    txt += (f"；倒数期间有 >1 的样本 {len(parry_gt1)} 个（"
                            + "、".join(sorted(set(f"{r['sp']} {r['act']}" for r in parry_gt1)))
                            + f"）：E2c 残差中位 {fmt(a_['med'])}、E2t {fmt(b_['med'])}（Sequence > 1 时 E2t 预测偏早，"
                            "方向和 <1 时相反）")
                rep.p(txt + "。")
    summ["parry_key"] = parry_pair
    summ["parry_gt1"] = len(parry_gt1)

    # ---- C7.7 结论
    rep.h("C7.7 结论", 3)
    v0 = c7_verdict(pr0)
    v1 = c7_verdict(pairs_store.get((main_label, decs[1]))) if len(decs) > 1 else None
    vp = c7_verdict(parry_pair) if parry_pair else None
    summ["verdict"] = v0
    summ["verdict_h1"] = v1
    summ["verdict_parry"] = vp
    key_recs = [r for r in recs_by.get(main_label, []) if r["h"] == h0 and r["prof"]["seq"]] if main_label else []
    if pr0 is None or pr0["n"] == 0:
        rep.p("**数据**：放刀模块关着、有真值的样本里，倒数期间 Sequence×BlendTree 一直是 1 —— 两种假设给出完全一样的预测，"
              "这批数据分不开。要分开，需要倒数期间 Sequence 或 BlendTree ≠1、又能定出激活真值的攻击（见下）。")
    else:
        e2c, e2t = c7_cells(key_recs, "E2c"), c7_cells(key_recs, "E2t")
        cals = Counter(how for how in ("cids", "window") for r in recs_by.get(how, []) if r["h"] == h0 and r["prof"]["seq"])
        rep.p(f"**数据**（决策点 ≤{fmt(h0, 0)}）：倒数期间 Seq×BT ≠1 的 {pr0['n']} 个样本（"
              + "、".join(pr0["sp"]) + "；真值口径 " + "，".join(f"{cal_name[k]} {v}" for k, v in sorted(cals.items()))
              + f"），E2c 残差中位 {fmt(e2c['med'])}（|r| 中位 {fmt(e2c['mad'])}），E2t {fmt(e2t['med'])}（{fmt(e2t['mad'])}）；"
              f"|残差| 更小的 E2c {pr0['better']} 个、E2t {pr0['worse']} 个；E2c 的残差对预测差的斜率 {c7_slope_txt(pr0)} → 判定："
              f"**{VERDICT_TXT[v0]}**"
              + (f"；决策点 ≤{fmt(decs[1], 0)}（n={pairs_store[(main_label, decs[1])]['n']}）：{VERDICT_TXT[v1]}" if v1 else "")
              + (f"；放刀模块开着的那段（单列，n={parry_pair['n']}）：{VERDICT_TXT[vp]}" if vp else "") + "。")
        if sq["core"] and sq["tot"]:
            rep.p(f"**数据**：同一件事不看决策点（C7.1）：Seq×BT ≠1 的段激活时，按 CoreState 积的名义进度离 N0 "
                  f"{fmt(med(sq['core']), 2)} 帧、按 tot 积 {fmt(med(sq['tot']), 2)} 帧（Seq×BT = 1 时两者都是 "
                  f"{fmt(med(ns['core']), 2)} 帧）。")
        if v0 == "core":
            rep.p("**数据**：所以在这批数据上，激活时刻跟 ∫CoreState 走、不跟 ∫tot 走 —— Sequence 的变速已经体现在 "
                  "AttackStartFrame 里。v1.6 应当照 SPEED.md 积 CoreState（E5c / E2c1 口径），不该改成积 tot；积 tot 会在 "
                  "Sequence < 1 的招上把攻击预测晚（残差为负 = 攻击早到，放刀侧最危险的方向）。")
        elif v0 == "tot":
            rep.p("**数据**：所以在这批数据上，激活时刻跟 ∫tot 走 —— Sequence/BlendTree 没有算进名义帧，v1.6 的 E5c"
                  "（只积 CoreState）要改成积 tot（逐帧读 _TotalMotionSpeedThisFream 或各分量之积）。")
        else:
            rep.p("**数据**：分不开（样本太少、预测差太集中，或斜率区间跨过 0.5），先维持 SPEED.md 的 E5c，补数据（见下）。")
    if best_rate and v0 == "core" and best_rate.startswith("tot"):
        rep.p("**推测**：动画（动作层帧号）按 tot 播、攻击判定却按 CoreState 的时间走，说明 AttackStartFrame 是在招式自带的 "
              "Sequence 曲线下烘焙的「设计时间」（或攻击判定挂在不受 Sequence 影响的动作时间轴上）；这两种说法这批数据分不开，"
              "对估计量没有影响。")
    # 还缺什么：按这批数据实际覆盖到的情况列
    q_all = pr0["q"] if pr0 else []
    n_gt1 = sum(1 for q in q_all if q > 1)
    n_bt = sum(1 for r in key_recs if r["prof"]["bt"])
    n_lt1 = sum(1 for how in labels for r in recs_by[how] if r["h"] == h0 and r["prof"]["core_lt1"])
    n_cids_key = sum(1 for r in recs_by.get("cids", []) if r["h"] == h0 and r["prof"]["seq"])
    gaps = []
    if not n_gt1:
        gaps.append("倒数期间 Sequence > 1 的攻击（放刀模块关着的子集里 0 个；这批主要检验的是 Sequence < 1"
                    + (f"，放刀模块开着的那段有 {len(parry_gt1)} 个，见 C7.6" if parry_gt1 else "") + "）")
    if not n_bt:
        gaps.append("BlendTree ≠ 1 的攻击（0 个样本，BlendTree 一直是 1）")
    if n_lt1 < 8:
        gaps.append(f"CoreState < 1（疲劳）的攻击：只有 {n_lt1} 个样本，E2c1（max(1, C)）和 E2c 只在这里不同，分不出")
    if not n_cids_key:
        gaps.append("cids 口径（通过零假设对照）的怪种上的 Sequence ≠ 1 样本：关键子集全靠时间窗口径")
    if pr0 and len(pr0["sp"]) < 2:
        gaps.append(f"第二种（放刀模块关着的）Sequence ≠ 1 怪：关键子集只有 {'、'.join(pr0['sp']) or '-'}")
    if gaps:
        rep.p("**还缺的数据**（结论只覆盖子集里出现过的 Sequence 取值和怪）：" + "；".join(gaps) + "。")
    summ["gaps"] = gaps
    return summ


def analyze(groups, opts):
    """groups：[(atp, ap, picked)]。多个 session 合并分析：条目片段各自在自己的 session 里建（地址、时刻不串），
    留一只怪按怪物种类（em 编号）留，所以怪种越多越好。真值口径按怪种在所有 session 合起来判（审查 F1）。"""
    rep = Report()
    names = [g[0].session for g in groups]
    summary = {"version": VERSION, "atp_sessions": names, "apcal_sessions": sorted({x for g in groups for x in g[2]})}
    rep.h("攻击时刻分析：ATP session " + "、".join(str(x) for x in names), 1)
    rep.p(f"{VERSION}。结论里标「数据」的是本次数据算出来的，标「推测」的是解释，需要另外验证。")

    # ---- 0 概况
    rep.h("0 数据概况")
    segs = []
    for atp, ap_g, picked_g in groups:
        ss = build_segments(atp, ap_g)
        match_candidates(ss, ap_g)
        session_overview(rep, atp, ap_g, picked_g, ss)
        segs.extend(ss)
    any_ap = any(g[1] is not None for g in groups)
    verdict = decide_truth(segs) if any_ap else {}
    if len(groups) > 1:
        by_sp = Counter(x.species for x in segs)
        rep.p(f"合并 {len(groups)} 个 session：片段共 {len(segs)}，按怪："
              + "，".join(f"{k} {v}" for k, v in sorted(by_sp.items())))
    summary["n_segs"] = len(segs)
    summary["excluded"] = sum((getattr(g[0], "excl", None) or {}).get("n", 0) for g in groups)
    ap = True if any_ap else None       # 下面只用来判断「有没有真值」

    # ---- C0
    c0, comp = c0_gar(groups)
    if c0["n"]:
        rep.h("C0 建结果调用（getAttackAreaResult）：游戏自己怎么参数化预告")
        rep.p(f"调用 {c0['n']} 次（" + "，".join(f"{k} {v}" for k, v in c0["kinds"].most_common()) + f"），目标是主角 "
              f"{pct(c0['tme'], c0['n'])}；initData 发生在建结果调用里的 {pct(c0['init_tagged'], c0['init_total'])}"
              f"（pre/post 可能配错的帧里的 {c0['excl']} 次不算）。")
        rep.table(["实参", "有值", "地址检查没过（读不到）", "最小", "中位", "最大"],
                  [[pn, pct(c0[pn + "_has"], c0["n"]), pct(c0[pn + "_bad"], c0["n"]),
                    fmt(min(c0[pn]) if c0[pn] else None), fmt(med(c0[pn])), fmt(max(c0[pn]) if c0[pn] else None)]
                   for pn in ("p1", "p2")])
        if c0["p1_bad"] or c0["p2_bad"]:
            rep.p("**提醒**：有实参没过地址检查（探针假定值类型实参按指针传、地址 ≥ 4 GB）。比例高说明这个假定不对，"
                  "p1/p2 的统计不可信。")
        if comp:
            rep.p("有值时和同一次调用里 initData 的量比（|差|）：")
            rep.table(["实参", "和谁比", "n", "|差| 中位", "≤0.01 占比"],
                      [[k[0], k[1], len(v), fmt(med(v), 4), fmt(sum(1 for x in v if x <= 0.01) / len(v), 2)]
                       for k, v in sorted(comp.items())])
        if c0["res_tme"]:
            rep.p(f"目标是主角的调用返回的结果对象，出现在 APCal MSG（打主角的预告消息）里的 {pct(c0['res_in_apcal'], c0['res_tme'])}"
                  "（高 → 结果对象地址可以直接关联两边的数据）。")
        rep.p("**推测**：如果某个实参有值时恰好等于怪物当时的速度，说明游戏有按速度生成预告的路径（目前只知道 NPC AI 用 "
              "_HitRemainFrameRange 直接比剩余帧，没有按速度换算）。")
        summary["c0"] = {k: (dict(v) if isinstance(v, Counter) else v) for k, v in c0.items() if k not in ("p1", "p2")}

    # ---- C1
    rep.h("C1 initData：hs 初值从哪来")
    # 有 APCal 的 session 只用对上 SER 的（打主角的）条目；没有 APCal 的 session 有 GAR 标记就用 tme=1 的
    has_tme = {id(x.atp) for x in segs if x.tme is not None}
    use = [x for x in segs if x.linked or (not x.has_ap and (id(x.atp) not in has_tme or x.tme == 1))]
    if not use:
        use = segs
    cands, best = c1_eval(use)
    rep.table(["候选", "公式", "类型", "n", "残差中位", "|残差|中位", "|残差|P90", "≤0.05 帧", "≤0.5 帧"],
              [[c["key"], c["desc"], c["kind"], c["n"], fmt(c["med"]), fmt(c["mad"]), fmt(c["p90"]),
                fmt(c["f005"], 2), fmt(c["f05"], 2)] for c in cands])
    rep.p("D~G 用 initData 那一刻的快照；D'~G' 用 initData 之后第一条 EMF（锚点）的值，按锚点的速度回推到 initData 时刻"
          "（审查 F3）。")
    cdk = {c["key"]: c for c in cands}
    dd, dp = cdk.get("D", {}), cdk.get("D'", {})
    if (dd.get("f005") or 0) >= 0.9:
        rep.p(f"**数据**：快照可靠（D 在 0.05 帧内的占 {fmt(dd.get('f005'), 2)}）。D' 若整体偏一个常数（现在中位 "
              f"{fmt(dp.get('med'))} 帧），说明 initData 之后到下一帧开头动作没有按时长推进（initData 发生在这一帧的"
              "动作更新之后），E3 的锚点积分会因此多扣这么多，C4/C5 里看 E3a 和 E3 的差。")
    elif (dp.get("f05") or 0) >= 0.9:
        rep.p(f"**数据**：快照不可靠（D 在 0.05 帧内的只占 {fmt(dd.get('f005'), 2)}），锚点回推的 D' 在半帧内的占 "
              f"{fmt(dp.get('f05'), 2)} → initData 发生在动作 / motion 切换之前，E3/E4 以锚点为准（已经这样算）。")
    elif dd.get("n") or dp.get("n"):
        rep.p("**数据**：D 和 D' 都对不上 → hs0 不是「AttackStartFrame − 动作帧」，看 B/C 和下面的最小二乘。")
    an = c1_anchor(use)
    aeq_txt = "，".join(f"{'一致' if k == 1 else '不一致'} {v}" for k, v in sorted(an["aeq"].items())) or "没有"
    rep.p(f"快照 vs 锚点：有锚点 {pct(an['anc'], an['n'])}；motion 不一致 {pct(an['mid_mis'], an['mid_cmp'])}，"
          f"动作不一致 {pct(an['act_mis'], an['act_cmp'])}；探针的 aeq（快照动作 == 建结果的 ACTION_ID 实参）：{aeq_txt}")
    fit = c1_fit(use)
    if fit:
        rep.p(f"最小二乘 hs0 = a·ast + b·sgl + c：a={fmt(fit['a'], 4)} b={fmt(fit['b'], 4)} c={fmt(fit['c'], 3)}，"
              f"RMS {fmt(fit['rms'], 3)} 帧，R² {fmt(fit['r2'], 4)}（n={fit['n']}）")
    sg = c1_sgl(use)
    rep.p(f"Single 参数 sgl：n={sg['n']}，最小 {fmt(sg['min'])} 中位 {fmt(sg['med'])} 最大 {fmt(sg['max'])}，等于 0 的 {sg['zero']} 条")
    rep.table(["和谁比", "n", "|sgl−x| 中位", "≤0.1 占比", "相关系数"],
              [[k, v["n"], fmt(v["mad"]), fmt(v["f01"], 2), fmt(v["r"], 3)] for k, v in sg["rel"].items()])
    bk = c1_baked(use)
    rep.p(f"同一种怪 + 同一个动作 + 同一个 RequestSetID 出现 ≥2 次的组 {bk['groups']} 个，其中 AttackStartFrame 完全相同的 "
          f"{bk['const']} 个（全相同 → 传进 initData 的是烘焙的名义帧，不是已经扣过的剩余帧）")
    un = c1_units([g[0] for g in groups])
    rep.p(f"动作层帧号的单位（相邻两帧 Δmf ÷ (ms·DeltaTime)，≈1 → 1/60 s）：用前一帧开头的 DeltaTime n={un['n1']} 中位 "
          f"{fmt(un['med1'], 3)}（IQR {fmt(un['q1'][0], 3)}~{fmt(un['q1'][1], 3)}）；用 os.clock 帧间隔 n={un['n0']} 中位 "
          f"{fmt(un['med0'], 3)}（IQR {fmt(un['q0'][0], 3)}~{fmt(un['q0'][1], 3)}）。不是 1 → E3/E3a 的换算要改")
    model = opts.hs0_model
    if model == "auto":
        model = best["kind"] if (best and (best["f005"] or 0) >= 0.5) else "nominal"
    if best:
        rep.p(f"**数据**：最符合的是 {best['key']}（{best['desc']}），|残差|≤0.05 帧占 {fmt(best['f005'], 2)}。"
              f"后面的估计量按「hs0 是{'名义帧' if model == 'nominal' else '已按速度换算的帧'}」解释（--hs0-model {model}）。")
    summary["c1_best"] = best["key"] if best else None
    summary["c1_fit"] = fit
    summary["c1_anchor"] = {k: (dict(v) if isinstance(v, Counter) else v) for k, v in an.items()}
    summary["c1_units"] = un
    summary["hs0_model"] = model

    # ---- C2
    if ap is not None:
        rep.h("C2 倒数机制：hs 按什么扣")
        c2 = c2_eval(segs)
        rep.p(f"用了 {c2['segs']} 段（只看 initData 之后 ≥0.3 s 的 SER）。")
        rep.table(["模型", "样本", "|残差|中位（帧）", "P90", "最大"],
                  [["真实时间：hs0 − 60·Δt", c2["n_rt"], fmt(c2["rt_mad"]), fmt(c2["rt_p90"]), fmt(c2["rt_max"])],
                   ["怪物速度：hs0 − Σ60·tot·Δt", c2["n_sp"], fmt(c2["sp_mad"]), fmt(c2["sp_p90"]), fmt(c2["sp_max"])]])
        rep.p(f"每段线性拟合的倒数速度中位 {fmt(c2['slope_med'], 2)} 帧/秒（名义 60），段内平均速度中位 "
              f"{fmt(c2['speed_mean_med'], 3)}，倒数速度和平均速度的相关系数 {fmt(c2['slope_vs_speed_r'], 3)}"
              f"（≈0 → 和速度无关）。")
        rep.table(["每帧扣的量 − DeltaTime（APCal 帧号连续的相邻两行）", "n", "|差|中位（帧）", "|差| P90"],
                  [["配前一帧开头读到的 DeltaTime（lag1）", c2["n_dgdt"], fmt(c2["dgdt1_mad"], 4), fmt(c2["dgdt1_p90"], 4)],
                   ["配后一帧开头读到的 DeltaTime（lag0）", c2["n_dgdt"], fmt(c2["dgdt0_mad"], 4), fmt(c2["dgdt0_p90"], 4)]])
        rep.p(f"按 <50 ms 判相邻的 {c2['pairs_time']} 对里，帧号其实不连续的 {c2['pairs_skip']} 对（已排除）。")
        if c2["lag"] is not None:
            which = "前一帧开头读到的（lag1）" if c2["lag"] == 1 else "后一帧开头读到的（lag0）"
            tail = ("，和 round2b/2c 的 APCal 实测一致（引擎在帧开头算好上一帧时长，整帧更新都用它）。"
                    if c2["lag"] == 1 else "，和 round2b/2c 的实测相反，先查数据。")
            rep.p(f"**数据**：每帧扣的量对得上{which} DeltaTime{tail}")
        if c2["model"]:
            rep.p("**数据**：" + ("hs 按真实时间扣（和怪物速度无关）。" if c2["model"] == "realtime"
                                 else "hs 按怪物速度扣（和以前的观察不一致，先查数据）。"))
        summary["c2"] = c2

    # ---- C3
    any_trusted = any(s.truth_ok for s in segs)
    if ap is not None:
        rep.h("C3 真值：攻击判定激活（ATK）和接触（CT）")
        linked = [s for s in segs if s.linked]
        rep.p("现有数据（round1~2c 的 APCal ATK）a4 ∈ {1, 6}、a5 在 0~100、多数是 0~9 的小整数（em40 只有 3、5、100），"
              "「a5 ∈ CollidableIDList」偶然命中可能很多，所以按怪种做零假设对照（审查 F1）：时间带 = 名义时刻的 "
              f"{BAND_LO}~{BAND_HI} 倍；平移 = 同样宽的带挪到别处（不和真实的带重叠、APCal 的 ATK 钩子活着）。"
              f"cids 口径要求平移命中率 ≤ {TRUTH_NULL_MAX} 且真实命中率高出 ≥ {TRUTH_MARGIN}、至少 {TRUTH_MIN_N} 段；"
              "否则这个怪种退回时间窗（只给最早一段，仅供参考）。")
        rows = []
        for sp, d in sorted(verdict.items()):
            rows.append([sp, d["n_c"], fmt(d["real_c"], 2), fmt(d["p_c"], 2), d["n_w"], fmt(d["real_w"], 2),
                         fmt(d["p_w"], 2), d["shell"], d["dead"],
                         "cids（主表）" if d["verdict"] == "cids" else "时间窗（仅供参考）"])
        rep.table(["怪", "有 cids 的段", "带里 a5∈cids", "平移后 a5∈cids", "最早一段", "带里有 ATK", "平移后有 ATK",
                   "弹体（不定）", "ATK 钩子停了（不定）", "口径"], rows)
        how = Counter(s.act_how for s in linked)
        rep.p(f"对上 SER 的片段 {len(linked)}：cids 口径定了真值 {how.get('cids', 0)}，时间窗口径 {how.get('window', 0)}，"
              f"没有真值 {how.get(None, 0)}。")
        a4s = Counter(s.a4 for s in linked if s.act_how == "cids")
        rep.p("按 cids 对上的 ATK 的 a4 分布：" + ("，".join(f"{k}:{v}" for k, v in a4s.most_common(6)) or "-"))
        lead_ct = [s for s in segs if s.lead and s.t_ct is not None and not s.is_shell]
        rep.p(f"「最早一段」且有接触（CT）的片段 {len(lead_ct)}（放刀模拟用这些；CT 只在打到主角时才有，"
              "ATK 钩子停了也能用）。")
        if not any_trusted and linked:
            rep.p("**提醒**：没有一个怪种的 cids 口径通过零假设对照 —— 「a5 是碰撞体 ID」没有得到数据支持，"
                  "C4 的真值是时间窗匹配的 ATK，仅供参考；C5 的放刀模拟用 CT，不受影响。")
        summary["c3"] = {"linked": len(linked), "cids": how.get("cids", 0), "window": how.get("window", 0),
                         "lead_ct": len(lead_ct),
                         "verdict": {sp: dict(d) for sp, d in verdict.items()}}

    # ---- C4
    if ap is not None:
        rep.h("C4 估计量在决策点的残差（真值 − 预测，秒；负 = 攻击比预测早到）")
        table, _, info = c4_eval(segs, model, opts.decisions, trusted=any_trusted)
        rep.p("真值：" + ("cids 口径（通过零假设对照的怪种）。" if any_trusted
                         else "**时间窗匹配的 ATK，仅供参考**（没有怪种的 cids 口径通过对照）。")
              + "决策点到真值之间有卡顿或缺帧（引擎帧时长 >2 帧、相邻 EMF 间隔 >35 ms）的样本不进表（审查 F5）。")
        c4_sum = {}
        for h in opts.decisions:
            nd = info["n_dec"][h]
            fbk = info["fallback"][h]
            fb_txt = "，".join(f"{n} {pct(fbk.get(n, 0), nd)}" for n in FALLBACK_EST)
            rep.p(f"**决策点：基线剩余帧首次 ≤ {fmt(h, 0)}**（{nd} 个样本；卡顿 / 缺帧剔除 {info['hitch'][h]} 个；"
                  f"E3/E3a/E4 在决策点退回 E2t（motion 或动作变了、没有锚点）：{fb_txt}）")
            rows = []
            for name, desc in ESTIMATORS:
                pairs = table[h].get(name, [])
                sm = summarize_resid(pairs)
                rows.append([name, desc, sm["n"], fmt(sm["med"]), f"{fmt(sm['q25'])}~{fmt(sm['q75'])}", fmt(sm["p90"]),
                             fmt(sm["max"])])
                c4_sum.setdefault(str(int(h)), {})[name] = sm
            rep.table(["估计量", "说明", "n", "中位", "IQR", "|r| P90", "|r| 最大"], rows)
            # 按怪分（只列 E0 和全体最好的一个；1.2 起只在 1.1 的估计量里挑，新估计量的对比在 C7）
            best_name = min((n for n in BASE_EST_NAMES if summarize_resid(table[h].get(n, []))["n"] > 0),
                            key=lambda n: summarize_resid(table[h][n])["p90"] or 1e9, default=None)
            if best_name:
                rows = []
                for sp in sorted(set(k for k, _ in table[h].get("E0", []))):
                    r0 = [x for k, x in table[h].get("E0", []) if k == sp]
                    rb = [x for k, x in table[h].get(best_name, []) if k == sp]
                    rows.append([sp, len(r0), fmt(med(r0)), fmt(max((abs(x) for x in r0), default=None)), len(rb),
                                 fmt(med(rb)), fmt(max((abs(x) for x in rb), default=None))])
                rep.p(f"按怪分（E0 vs 本决策点 |r| P90 最小的 {best_name}）：")
                rep.table(["怪", "E0 n", "E0 中位", "E0 |r|最大", f"{best_name} n", f"{best_name} 中位",
                           f"{best_name} |r|最大"], rows)
            c4_sum.setdefault(str(int(h)), {})["_info"] = {"n_dec": nd, "hitch": info["hitch"][h],
                                                           "fallback": dict(fbk)}
        if any_trusted and any(s.act_how == "window" for s in segs):
            h0w = opts.decisions[0]
            tw, _, iw = c4_eval(segs, model, (h0w,), trusted=False)
            rows = []
            for name, desc in ESTIMATORS:
                sm = summarize_resid(tw[h0w].get(name, []))
                rows.append([name, sm["n"], fmt(sm["med"]), f"{fmt(sm['q25'])}~{fmt(sm['q75'])}", fmt(sm["p90"])])
            rep.p(f"时间窗口径的怪种（仅供参考，决策点 ≤ {fmt(h0w, 0)}，卡顿剔除 {iw['hitch'][h0w]}）：")
            rep.table(["估计量", "n", "中位", "IQR", "|r| P90"], rows)
        summary["c4"] = c4_sum
        summary["c4_truth"] = "cids" if any_trusted else "window"

        # ---- C5
        rep.h("C5 留一只怪交叉验证")
        h0 = opts.decisions[0]
        rows = []
        lomo_sum = {}
        for name, desc in ESTIMATORS:
            lb = lomo_bias(table[h0].get(name, []))
            allr = [x for v in lb.values() for x in v]
            a = [abs(x) for x in allr]
            rows.append([name, desc, len(allr), fmt(med(a)), fmt(quant(a, 0.95)), fmt(max(a) if a else None),
                         fmt(sum(1 for x in a if x <= 0.05) / len(a) if a else None, 2),
                         fmt(sum(1 for x in a if x <= 0.10) / len(a) if a else None, 2)])
            lomo_sum[name] = {"n": len(allr), "mad": med(a), "p95": quant(a, 0.95)}
        rep.p(f"偏置（常数提前量）用其余怪的残差中位数，套到留出的那只怪上；决策点 = 基线剩余帧 ≤ {fmt(h0, 0)}"
              f"（真值口径同 C4）：")
        rep.table(["估计量", "说明", "n", "|r| 中位", "|r| P95", "|r| 最大", "≤0.05 s", "≤0.10 s"], rows)
        catch, n_sp, n_hitch5 = c5_catch(segs, model)
        rep.p("放刀模拟（「最早一段」+ 有接触，弹体条目不算）：按估计量预测的剩余时间 ≤ λ 的第一帧放刀，接触落在放刀后 "
              f"[{W0}, {W1}] s 算接住。λ 在 0.20~1.00 s 里用其余怪选（留一只怪）；接触前 2 s 内有卡顿 / 缺帧的 "
              f"{n_hitch5} 个样本不算；样本数按怪："
              + ("，".join(f"{k} {v}" for k, v in sorted(n_sp.items())) or "无"))
        rows = []
        for name, desc in ESTIMATORS:
            c = catch[name]
            per = "，".join(f"{sp} {ok}/{n}@{fmt(lam, 2)}" for sp, (ok, n, lam) in sorted(c["per_species"].items()))
            rows.append([name, desc, pct(c["lomo_ok"], c["lomo_n"]), pct(c["insample_ok"], c["n"]),
                         fmt(c["insample_lambda"], 2), per or "-"])
        rep.table(["估计量", "说明", "留一只怪接住", "全体最优（样本内）", "全体最优 λ", "各怪（接住/样本@λ）"], rows)
        summary["c5"] = {"lomo_bias": lomo_sum, "hitch": n_hitch5,
                         "catch": {k: {kk: vv for kk, vv in v.items() if kk != "per_species"} for k, v in catch.items()}}
        ranked = sorted((n for n in BASE_EST_NAMES if catch[n]["lomo_n"] > 0),
                        key=lambda n: (-catch[n]["lomo_ok"] / catch[n]["lomo_n"], lomo_sum[n]["p95"] or 1e9))
        if ranked:
            b = ranked[0]
            e0 = catch["E0"]
            rep.p(f"**数据**：留一只怪接住率最高的是 {b}（{pct(catch[b]['lomo_ok'], catch[b]['lomo_n'])}），"
                  f"基线 E0 {pct(e0['lomo_ok'], e0['lomo_n'])}。")
            summary["best_estimator"] = b
        rep.p("（1.2 新增的 " + "、".join(SPEED_NAMES) + " 列在上面的表里，但不参加这里和 C4「按怪分」的挑选；"
              "它们和 E0/E2t/E3a 的对比、去掉放刀模块开着的片段后的结果见 C7。）")

    # ---- C6
    rep.h("C6 攻击前摇期间的速度")
    sp6 = c6_speed(segs)
    r0 = {}
    if ap is not None:
        # 真值口径和 C4 一样（审查 F1：旧版这里写死只用 cids，C4 回退到时间窗时两处口径不一致）
        t4, _, _ = c4_eval(segs, model, (opts.decisions[0],), trusted=any_trusted)
        for k, x in t4[opts.decisions[0]].get("E0", []):
            r0.setdefault(k, []).append(x)
    rows = []
    for sp, d in sorted(sp6.items()):
        comp = "，".join(f"{k}×{v}" for k, v in d["comp_dev"].most_common(4)) or "-"
        rows.append([sp, d["n"], fmt(med(d["mean"])), fmt(min(d["min"]) if d["min"] else None),
                     fmt(max(d["max"]) if d["max"] else None), fmt(med(d["dev_time"]), 2), comp, fmt(med(r0.get(sp, [])))])
    rep.table(["怪", "段数", "时间加权平均速度（中位）", "最小", "最大", "速度≠1 的时间占比", "不是 1 的分量（EMSPD 条数）",
               "E0 残差中位" + ("" if any_trusted else "（仅供参考）")], rows)
    rep.p("**推测**（待数据确认）：基线 E0 的残差应当和「平均速度 − 1」成反比（加速 → 负残差 = 早到）；"
          "如果 E2/E3 把各怪残差都压到一帧以内，就说明「名义帧 / 速度」对所有怪成立，不需要逐只怪调参。")

    # ---- C7（1.2）
    if ap is not None:
        summary["c7"] = c7_section(rep, segs, groups, model, opts.decisions, any_trusted)
    return rep.text(), summary


# ---------------------------------------------------------------- 主流程
def run(argv):
    ap_ = argparse.ArgumentParser(description="AttackTimingProbe 离线分析")
    ap_.add_argument("data", nargs="?", help="数据目录（递归找 ATP_*.json；APCal_*.json 默认也在这里找）")
    ap_.add_argument("--apcal-dir", help="APCal_*.json 所在目录（默认同数据目录）")
    ap_.add_argument("--session", type=int, help="只分析这个 ATP session")
    ap_.add_argument("--apcal-session", type=int, action="append", help="指定 APCal session（可重复）")
    ap_.add_argument("--out", help="报告写到这个文件（Markdown）；不给就打印")
    ap_.add_argument("--json", help="摘要写到这个 JSON 文件")
    ap_.add_argument("--decision", default=",".join(str(int(x)) for x in DEFAULT_DECISIONS),
                     help="决策点：基线剩余帧，逗号分隔（默认 30,60）")
    ap_.add_argument("--hs0-model", default="auto", choices=["auto", "nominal", "scaled"])
    ap_.add_argument("--separate", action="store_true", help="每个 ATP session 单独出一份报告（默认合并分析）")
    ap_.add_argument("--selftest", action="store_true")
    ap_.add_argument("--keep", help="自测时把合成数据留在这个目录")
    args = ap_.parse_args(argv)
    if args.selftest:
        return selftest(args.keep)
    if not args.data:
        print(NO_DATA_HINT.format(root="（没给目录）"))
        return 2
    try:
        args.decisions = tuple(float(x) for x in args.decision.split(",") if x.strip())
    except ValueError:
        print("--decision 要是逗号分隔的数字，例如 30,60")
        return 2
    if not args.decisions:
        args.decisions = DEFAULT_DECISIONS
    atp_files = find_files(args.data, "ATP")
    if not atp_files:
        print(NO_DATA_HINT.format(root=args.data))
        return 2
    atp_sessions = group_sessions(atp_files)
    apcal_sessions = group_sessions(find_files(args.apcal_dir or args.data, "APCal"))
    parry_sessions = find_parry_files(args.data)
    if args.apcal_dir:
        for s, lst in find_parry_files(args.apcal_dir).items():
            parry_sessions[s] = sorted(set(parry_sessions.get(s, []) + lst))
    texts, summaries, groups = [], [], []
    for s, paths in sorted(atp_sessions.items()):
        if args.session is not None and s != args.session:
            continue
        atp = AtpSession(s, paths)
        if not atp.inits:
            texts.append(f"> ATP session {s}：没有 INIT 记录（initData 钩子没装上或被守卫停了，看 ERR / SELFTEST）。\n")
            continue
        only = set(args.apcal_session) if args.apcal_session else None
        ap, picked = load_apcal_for(atp, apcal_sessions, only)
        atp.parry_on, atp.parry_fires = load_parry_for(atp, parry_sessions)
        groups.append((atp, ap, picked))
    if not groups:
        print("\n".join(texts) if texts else f"没有 session {args.session} 的 ATP 数据。")
        return 2
    if args.separate:
        for g in groups:
            text, summary = analyze([g], args)
            texts.append(text)
            summaries.append(summary)
    else:
        text, summary = analyze(groups, args)
        texts.append(text)
        summaries.append(summary)
    out = "\n".join(texts)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(out)
        print(f"报告写到 {args.out}")
    else:
        print(out)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(summaries, f, ensure_ascii=False, indent=1, default=str)
    return 0


# ---------------------------------------------------------------- 自测：合成数据
SPD_FIELDS_SYN = ["_Base", "_Action", "_Scale", "_MoveAction", "_MoveSpeed", "_Random", "_CoreState", "_Replica",
                  "_WaitPacketReserved", "_WaitPacket", "_Sequence", "_BlendTree"]
SYN_NOISY = "em39"       # 碰撞体编号含糊的怪种（模拟 em40/em39 实测：a5 只有几个值、ATK 很密）


def f32(x):
    import struct
    return struct.unpack("<f", struct.pack("<f", x))[0]


def synth_write(dirpath, seed=11, model="nominal", with_apcal=True, duration=150.0, session_base=1791700000,
                atk_off_frac=None, inject_bad=False, split=None, parry_frac=None):
    """按实测 / 推测的机制合成一次游戏的 ATP + APCal 数据（审查指出旧版自测测不出 F1、F3、F4，这里逐条补上）：
    - 帧开头读到的 DeltaTime 是刚过完那一帧的时长，引擎这一帧的更新用它（hs 倒数和动作推进都按它；审查 F4）；
      偶尔有 45 ms 的卡顿帧（审查 F5）
    - initData 给名义帧初值（model=nominal：hs0 = ast − sgl；scaled：(ast − sgl)/当时速度，用来测 C1 能不能分辨），
      之后 hs 按真实时间扣；动作按怪物速度走，动作帧越过 ast 时激活
    - 一半的 initData 发生在动作切换之前：INIT 快照还是上一个动作 / motion（aeq=0），下一帧 EMF 才是新的（审查 F3）
    - cids 从每个怪种 24 个碰撞体编号里取；噪声 ATK 有一半的 a5 也从这里取（可能偶然命中，审查 F1）；
      SYN_NOISY 怪种 cids 总是 {3}、ATK 里 a5=3 很密 → 应当判成时间窗口径；a4 偶尔是 6（实测有）
    - 少数条目是弹体（shell 有值）；atk_off_frac：APCal 的 ATK 钩子在这个时刻被守卫停掉（之后没有 ATK）
    - inject_bad：两帧 pre/post 配错（一帧 depth 2 且 hs 对调，一帧有 ORPH），应当整帧剔除（审查 F8）
    - 速度分量（1.2）：默认整个速度都记在 _Sequence 上（CoreState = 1，和 1.1 的合成数据逐字节相同）。
      split 给了时，上面的速度曲线当 CoreState，另给 60% 的招一段 Sequence 变速（0.6~0.9，15~40 帧）；动画（mf、tot）按
      CoreState × Sequence 走。split="motion"：动作层帧号越过 ast 时激活（Sequence 没算进名义帧 → C7 应判「积 tot」）；
      split="design"：∫60·CoreState·dt 越过 ast 时激活（Sequence 已算进名义帧 → C7 应判「只积 CoreState」）
    - parry_frac（1.2）：另写一份 AutoParryGS：加载时 auto_parry=1，duration×parry_frac 处 CFG 关掉，C7 应当把这段单列"""
    rng = random.Random(seed)
    session = session_base + (0 if model == "nominal" else 7)
    # 帧开头时刻（os.clock，1 ms 分辨率在写出时取整）；0.4% 的帧是 45 ms 的卡顿
    t = 7000.0
    ft = []
    while t < 7000.0 + duration:
        t += 0.045 if rng.random() < 0.004 else rng.uniform(0.0150, 0.0185)
        ft.append(t)
    atk_off_t = 7000.0 + duration * atk_off_frac if atk_off_frac else None
    species = [("em19", 301, 1.00, 0.00), ("em20", 302, 1.06, 0.03), ("em23", 303, 1.22, 0.05),
               ("em27", 304, 0.86, 0.04), ("em40", 305, 1.42, 0.04), (SYN_NOISY, 306, 1.10, 0.02)]
    atp_recs, ser, atk, ct, msg = [], [], [], [], []
    emf_rows = defaultdict(dict)        # em -> {帧号: 记录}
    emspd = []
    obj_seq = [0x13C6200000]
    gar_seq = [0]
    truth = []
    init_by_f = defaultdict(list)       # 帧号 -> 这一帧的 INIT 记录（注入配错用）

    def r3(x):
        return round(x, 3)

    for sp_i, (sp, idx, base, noise) in enumerate(species):
        em = f"{sp}#{idx}"
        emid = int(sp[2:])
        noisy = sp == SYN_NOISY
        ids = list(range(1, 25))
        pool = [0x13C6300000 + sp_i * 0x10000 + k * 0x120 for k in range(5)]
        pool_i = 0
        i = 40 + sp_i * 37
        a = 0
        last_comp = None
        while True:
            if i >= len(ft) - 700:
                break
            a += 1
            t_init = ft[i] + 0.002
            sgl = round(rng.uniform(0.0, 3.0), 2)
            ast = round(rng.uniform(40.0, 160.0), 1)
            n_ent = 1 if rng.random() < 0.6 else 2
            asts = [ast] + ([round(ast + rng.uniform(15.0, 40.0), 1)] if n_ent == 2 else [])
            # 这一招的速度曲线（按更新序号 k，k=0 是 initData 那一帧的更新）：基础速度 × 小波动；30% 前摇慢后段快；
            # 15% 中途卡肉 4 帧
            phase = rng.uniform(0, 6.28)
            step = rng.random() < 0.3
            stop_at = rng.randint(10, 60) if rng.random() < 0.15 else None

            def speed(k, _base=base, _noise=noise, _phase=phase, _step=step, _stop=stop_at, _ast=ast):
                s = _base * (1.0 + _noise * math.sin(2 * math.pi * k / 45.0 + _phase))
                if _step:
                    s *= 0.85 if k < 0.4 * _ast else 1.15
                if _stop is not None and _stop <= k < _stop + 4:
                    s = 0.0
                return s

            # 1.2 split：这一招的 Sequence 变速段（按更新序号 k）；默认不抽随机数，1.1 的合成数据不变
            seq_win = None
            if split:
                if rng.random() < 0.6:
                    a0 = rng.randint(0, max(1, int(0.3 * ast)))
                    seq_win = (a0, a0 + rng.randint(15, 40), round(rng.uniform(0.6, 0.9), 2))

            def seqf(k, _w=seq_win):
                return _w[2] if (_w is not None and _w[0] <= k < _w[1]) else 1.0

            s_init = speed(0)
            mid = 2000 + a
            act = f"(0,{a})"
            pre_switch = rng.random() < 0.5
            # 第 j 帧（j ≥ i）的更新用 dtp = ft[j] − ft[j−1]（帧开头读到的 DeltaTime）和速度 speed(j − i)；
            # 更新完的状态在第 j+1 帧开头读到（EMF 那一行的 tot 就是这次更新的速度）
            mf = sgl
            pd = sgl                         # 1.2 split="design"：按 CoreState 走的「设计时间」进度
            ace = 0.0
            ael = 0.0
            frames = []                      # (帧开头下标 k, 速度, mf, ace, ael, 这一行读到的 gdt, Sequence)
            t_act = [None] * n_ent
            j = i
            while j + 1 < len(ft):
                s = speed(j - i)
                q = seqf(j - i)
                dtp = ft[j] - ft[j - 1]
                mf += 60.0 * s * q * dtp
                pd += 60.0 * s * dtp
                ace += s * dtp
                ael += dtp
                prog = pd if split == "design" else mf
                for e_i, ae in enumerate(asts):
                    if t_act[e_i] is None and prog >= ae:
                        t_act[e_i] = ft[j] + 0.003        # 第 j 帧的更新里激活
                frames.append((j + 1, s, mf, ace, ael, 60.0 * (ft[j + 1] - ft[j]), q))
                j += 1
                if all(x is not None for x in t_act) and ft[j] > max(t_act) + 0.4:
                    break
            hs0s = [ae - sgl if model == "nominal" else (ae - sgl) / s_init for ae in asts]
            obj = obj_seq[0]
            obj_seq[0] += 0x200
            gar_seq[0] += 1
            gid = gar_seq[0]
            atp_recs.append({"k": "GAR", "t": r3(t_init), "id": gid, "kind": "gar", "f": i, "tme": 1, "act": act,
                             "flag": 1, "p1": sgl, "p1s": "val", "p2s": "none", "pos": 0, "res": f"{obj:X}",
                             "n_init": n_ent, "depth": 1})
            msg.append({"k": "MSG", "t": r3(t_init + 0.004), "obj": f"{obj:X}", "tme": 1, "em": em, "rt": "DANGER",
                        "new": 1})
            # initData 时的快照：一半还是上一个动作 / motion（审查 F3）
            if pre_switch:
                snap = {"mid": mid - 1000, "act": "(0,999)", "mf": round(rng.uniform(100.0, 200.0), 3),
                        "ace": round(rng.uniform(1.0, 3.0), 4), "ael": round(rng.uniform(1.0, 3.0), 4), "aeq": 0}
            else:
                snap = {"mid": mid, "act": act, "mf": sgl, "ace": 0.0, "ael": 0.0, "aeq": 1}
            for e_i, ae in enumerate(asts):
                ent = pool[pool_i % len(pool)]
                pool_i += 1
                if noisy:
                    cids = [3]
                else:
                    cids = rng.sample(ids, 2 if rng.random() < 0.5 else 1)
                shell = "0" if rng.random() < 0.05 else "none"
                hs0 = f32(hs0s[e_i])
                he0 = f32(hs0 + rng.uniform(5.0, 30.0))
                rec = {"k": "INIT", "t": r3(t_init), "f": i, "ctx": "7FF600001000", "ent": f"{ent:X}", "em": em,
                       "idx": idx, "sgl": sgl, "sbits": "-", "ast": ae, "aen": round(ae + 20, 1), "req": str(e_i + 1),
                       "shell": shell, "cids": ",".join(str(c) for c in cids), "ncid": len(cids),
                       "hs_pre": 0.0, "he_pre": 0.0, "hs": round(hs0, 3), "he": round(he0, 3), "rt": "DANGER",
                       "depth": 1, "same": 0, "tot": round(s_init, 4), "ms": round(s_init, 4), "mf": snap["mf"],
                       "mid": snap["mid"], "bank": 3, "pls": round(s_init, 4), "act": snap["act"],
                       "actn": f"Em{emid:04d}Action.cAtk{a}", "ace": snap["ace"], "ael": snap["ael"], "gar": gid,
                       "tme": 1, "aeq": snap["aeq"]}
                if split:
                    rec["tot"] = rec["ms"] = rec["pls"] = round(s_init * seqf(0), 4)
                    rec["scomp"] = "/".join("%.4f" % (s_init if n == "_CoreState" else seqf(0) if n == "_Sequence"
                                                      else 1.0) for n in SPD_FIELDS_SYN)
                atp_recs.append(rec)
                init_by_f[i].append(rec)
                # SER（APCal 只记打主角的结果；f = APCal 的帧号）：hs 在 initData 那一帧的更新里就扣了一帧，
                # 第 k 帧开头读到 hs0 − 60·(ft[k−1] − ft[i−1])
                for (kk, s, mfj, acej, aelj, gdt, _q) in frames:
                    hs = hs0 - 60.0 * (ft[kk - 1] - ft[i - 1])
                    if hs < -40:
                        break
                    ser.append({"k": "SER", "t": r3(ft[kk]), "f": kk, "obj": f"{obj:X}", "ent": f"{ent:X}",
                                "type": "DANGER", "hs": round(f32(hs), 2),
                                "he": round(f32(he0 - 60.0 * (ft[kk - 1] - ft[i - 1])), 2)})
                if t_act[e_i] is not None:
                    a4 = 6 if rng.random() < 0.1 else 1
                    if shell == "none" or rng.random() < 0.5:
                        atk.append({"k": "ATK", "t": r3(t_act[e_i]), "em": em, "a4": a4, "a5": cids[0]})
                    if e_i == 0 and rng.random() < 0.85:
                        ct.append({"k": "CT", "t": r3(t_act[e_i] + 0.15 + rng.uniform(-0.01, 0.02)), "em": em,
                                   "cls": "BODY", "res": "SUCCESS"})
                    truth.append((em, t_act[e_i]))
            # 打随从的一条（没有 SER）
            if rng.random() < 0.2:
                gar_seq[0] += 1
                atp_recs.append({"k": "GAR", "t": r3(t_init), "id": gar_seq[0], "kind": "gar", "f": i, "tme": 0,
                                 "p1": sgl, "p1s": "val", "p2s": "none", "res": "1FFFE0000", "n_init": 1, "depth": 1})
                orec = {"k": "INIT", "t": r3(t_init), "f": i, "ctx": "7FF600001000", "ent": "1FFFF0000",
                        "gar": gar_seq[0], "tme": 0, "em": em, "idx": idx, "sgl": sgl, "ast": ast, "aen": ast + 10,
                        "hs": round(ast - sgl, 3), "he": round(ast - sgl + 10, 3), "tot": round(s_init, 4),
                        "mf": snap["mf"], "mid": snap["mid"], "depth": 1, "same": 0, "cap": "0,0,0,0.9,0.350"}
                atp_recs.append(orec)
                init_by_f[i].append(orec)
            # 噪声 ATK：一般怪种每招一条（a5 一半从同一批碰撞体编号里取，可能偶然命中 cids）；
            # SYN_NOISY 每 0.25 s 一条 a5=3（偶然命中很多）
            if noisy:
                t_end = ft[frames[-1][0]] if frames else t_init + 3.0
                tt_ = t_init - 1.0
                while tt_ < t_end + 1.0:
                    atk.append({"k": "ATK", "t": r3(tt_ + rng.uniform(0.0, 0.05)), "em": em, "a4": 1, "a5": 3})
                    tt_ += 0.25
            else:
                a5n = rng.choice(ids) if rng.random() < 0.5 else 90 + rng.randint(0, 9)
                atk.append({"k": "ATK", "t": r3(t_init + rng.uniform(0.2, 1.5)), "em": em, "a4": 1, "a5": a5n})
            # EMF：从 initData 到 max(4 s, hs0/60+1 s)
            win = max(4.0, min(8.0, max(hs0s) / 60.0 + 1.0))
            for (kk, s, mfj, acej, aelj, gdt, q) in frames:
                if ft[kk] > t_init + win:
                    break
                if split:
                    comp = "/".join("%.4f" % (s if n == "_CoreState" else q if n == "_Sequence" else 1.0)
                                    for n in SPD_FIELDS_SYN)
                    s = s * q                   # tot / 层速度 / PlaySpeed 记总速度
                else:
                    comp = "/".join("%.4f" % (s if n == "_Sequence" else 1.0) for n in SPD_FIELDS_SYN)
                v = "|".join(["%.4f" % s, "%.4f" % s, "%.3f" % mfj, str(mid), "3", "%.4f" % s, "-1.0000", "%.4f" % aelj,
                              "%.4f" % acej, act, "%.4f" % gdt, str(kk), "-", "-"])
                emf_rows[em][kk] = {"k": "EMF", "t": r3(ft[kk]), "f": kk, "em": em, "v": v}
                if comp != last_comp:
                    last_comp = comp
                    emspd.append({"k": "EMSPD", "t": r3(ft[kk]), "f": kk, "em": em, "comp": comp})
            # 下一招
            i = (frames[-1][0] if frames else i) + rng.randint(60, 150)
    bad_n = 0
    if inject_bad:
        # 一帧 pre/post 配错：两条 INIT 的 hs 对调、depth 记成 2 / 1；另一帧有 ORPH（审查 F8）
        multi = sorted(f for f, lst in init_by_f.items() if len(lst) >= 2)
        single = sorted(f for f, lst in init_by_f.items() if len(lst) == 1)
        if multi and single:
            fa, fb = multi[len(multi) // 2], single[len(single) // 3]
            x, y = init_by_f[fa][0], init_by_f[fa][1]
            x["hs"], y["hs"] = y["hs"], x["hs"]
            x["depth"] = 2
            atp_recs.append({"k": "ORPH", "t": round(ft[fb + 1], 3), "kind": "init", "f": fb})
            bad_n = len(init_by_f[fa]) + len(init_by_f[fb])
    recs = atp_recs + [r for d in emf_rows.values() for r in d.values()] + emspd
    recs.append({"k": "HDR", "t": 7000.001, "ver": "atp-1.1", "emf_fields": ",".join(DEFAULT_EMF_FIELDS)})
    recs.append({"k": "SELFTEST", "t": 7000.002, "ok": 69, "total": 69})
    recs.append({"k": "PERF", "t": 7005.0, "fps": 60.0, "init_ps": 3.0, "init_raw_ps": 3.0, "hook_ms_ps": 0.4,
                 "frame_ms_avg": 0.05, "deep": 0, "orphan": 0, "mon_full": 0})
    recs.sort(key=lambda r: r["t"])
    half = len(recs) // 2
    hdr = {"kind": "ATP", "ver": "atp-1.1", "session": session, "emf_fields": ",".join(DEFAULT_EMF_FIELDS),
           "spd_fields": ",".join(SPD_FIELDS_SYN)}
    for q, part in ((1, recs[:half]), (2, recs[half:])):
        d = dict(hdr, seq=q, why="idle" if q == 1 else "reset", records=part)
        with open(os.path.join(dirpath, f"ATP_{session}_{q}.json"), "w", encoding="utf-8") as f:
            json.dump(d, f)
    if with_apcal:
        hdr_ap = {"k": "HDR", "t": 7000.002, "ver": "apcal-1.0", "session": session + 1}   # 和 ATP 同一个进程
        extra = []
        if atk_off_t is not None:
            atk = [r for r in atk if r["t"] < atk_off_t]
            extra.append({"k": "ERR", "t": round(atk_off_t, 3), "mod": "ATK", "level": "yellow",
                          "msg": "rate_guard:_activateAttack_3228_calls/s_for_3_periods"})
        arecs = sorted([hdr_ap] + ser + atk + ct + msg + extra, key=lambda r: r["t"])
        d = {"kind": "APCal", "ver": "apcal-1.0", "session": session + 1, "seq": 1, "why": "reset", "records": arecs}
        with open(os.path.join(dirpath, f"APCal_{session + 1}_1.json"), "w", encoding="utf-8") as f:
            json.dump(d, f)
    parry = None
    if parry_frac:
        # 1.2：放刀模块（加载时开着，parry_frac 处菜单关掉；中间一次 FIRE）。另放一个别的进程的，不能配上
        t_off = round(7000.0 + duration * parry_frac, 3)
        parry = (7000.003, t_off)
        precs = [{"k": "HDR", "t": 7000.003, "auto_parry": 1, "session": session, "ver": "1.5.1"},
                 {"k": "FIRE", "t": round(7000.0 + duration * parry_frac / 2, 3), "id": 1},
                 {"k": "CFG", "t": t_off, "auto_parry": 0}]
        for s_, recs_ in ((session, precs), (session + 999, [{"k": "HDR", "t": 3000.0, "auto_parry": 1}])):
            with open(os.path.join(dirpath, f"AutoParryGS_{s_}_1.json"), "w", encoding="utf-8") as f:
                json.dump({"kind": "AutoParryGS", "session": s_, "seq": 1, "records": recs_}, f)
    return {"session": session, "truth": truth, "bad_n": bad_n, "parry": parry}


def selftest(keep=None):
    fails = []

    def check(cond, what):
        print(("  ok   " if cond else "  FAIL ") + what)
        if not cond:
            fails.append(what)

    base = keep or tempfile.mkdtemp(prefix="atp_selftest_")
    if keep:
        os.makedirs(keep, exist_ok=True)
    try:
        # 1. 没有数据：提示 + 退出码 2
        empty = os.path.join(base, "empty")
        os.makedirs(empty, exist_ok=True)
        rc = run([empty])
        check(rc == 2, "没有 ATP 数据时退出码 2")

        # 2. EMF 解析：- 和缺字段
        row = parse_emf_v("1.2500|-|12.000|474|-|1.0|-1.0000|0.5|0.6|(0,79)|1.0128|99|-", DEFAULT_EMF_FIELDS)
        check(row["tot"] == 1.25 and row["ms"] is None and row["mid"] == 474 and row["act"] == "(0,79)"
              and row["spf"] is None and row["gfc"] == 99, "EMF 紧凑字符串解析（- 和缺字段）")
        check(lstsq([[1, 0], [0, 1], [1, 1]], [1, 2, 3]) is not None, "最小二乘")

        # 3. 名义帧模型的合成数据（带：快照在动作切换前、滞后一帧的倒数、偶然命中的噪声 ATK、配错的帧、卡顿、
        #    弹体、APCal 的 ATK 钩子在 85% 处停掉）
        d1 = os.path.join(base, "nominal")
        os.makedirs(d1, exist_ok=True)
        info = synth_write(d1, seed=11, model="nominal", atk_off_frac=0.85, inject_bad=True)
        atp_files = group_sessions(find_files(d1, "ATP"))
        apc = group_sessions(find_files(d1, "APCal"))
        check(len(atp_files) == 1 and len(apc) == 1, "找到 1 个 ATP session 和 1 个 APCal session")
        atp = AtpSession(info["session"], atp_files[info["session"]])
        ap, picked = load_apcal_for(atp, apc)
        check(ap is not None and picked == [info["session"] + 1], "按时间重叠配上 APCal（session 号不同也行）")
        segs = build_segments(atp, ap)
        match_candidates(segs, ap)
        verdict = decide_truth(segs)
        check(info["bad_n"] >= 3 and atp.excl["n"] == info["bad_n"] and set(atp.excl["by"]) == {"depth", "orphan"},
              f"F8：pre/post 可能配错的帧整帧剔除 {atp.excl['n']}/{info['bad_n']} 条（{atp.excl['by']}）")
        linked = [s for s in segs if s.linked]
        check(len(linked) >= 60, f"片段对上 SER：{len(linked)}")
        check(sum(1 for s in segs if not s.linked) >= 1, "打随从的 INIT 没有 SER（不误连）")
        reuse = Counter(s.ent for s in segs)
        check(max(reuse.values()) >= 3, "条目地址复用时按 initData 切段")
        cands, best = c1_eval(linked)
        check(best is not None and best["key"] == "B", f"C1 选中 B（hs0 = ast − sgl），实际 {best and best['key']}")
        cd = {c["key"]: c for c in cands}
        dp, dd = cd["D'"], cd["D"]
        check((dp["f05"] or 0) >= 0.9 and (dd["f05"] or 0) < 0.7,
              f"F3：D'（锚点回推）≤0.5 帧占 {fmt(dp['f05'], 2)}，D（快照）只占 {fmt(dd['f05'], 2)}")
        fit = c1_fit(linked)
        check(fit is not None and abs(fit["a"] - 1) < 0.01 and abs(fit["b"] + 1) < 0.01, "C1 最小二乘 a≈1 b≈−1")
        an = c1_anchor(linked)
        mis = an["mid_mis"] / an["mid_cmp"] if an["mid_cmp"] else 0
        check(an["anc"] >= 0.95 * an["n"] and 0.35 <= mis <= 0.65 and an["aeq"].get(0, 0) > 0 and an["aeq"].get(1, 0) > 0,
              f"F3：快照和锚点的 motion 不一致 {fmt(mis, 2)}（合成 0.5），aeq 两种都有")
        un = c1_units([atp])
        check(un["n1"] > 1000 and abs((un["med1"] or 0) - 1.0) < 0.01,
              f"动作帧单位检验：Δmf ÷ (ms·前一帧 DeltaTime) 中位 {fmt(un['med1'], 4)}")
        c2 = c2_eval(segs)
        check(c2["model"] == "realtime" and (c2["rt_mad"] or 9) < 0.25,
              f"C2 判为真实时间倒数（|残差|中位 {fmt(c2['rt_mad'])} 帧）")
        check((c2["sp_mad"] or 0) > (c2["rt_mad"] or 0) * 3, "C2 速度模型残差明显更大")
        check(c2["lag"] == 1 and (c2["dgdt1_mad"] or 9) < 0.02 and (c2["dgdt0_mad"] or 0) > 2 * (c2["dgdt1_mad"] or 9),
              f"F4：每帧扣的量对上前一帧的 DeltaTime（lag1 {fmt(c2['dgdt1_mad'], 4)} vs lag0 {fmt(c2['dgdt0_mad'], 4)}）")
        # F4：E2g 的积分（tot_k × 上一行的 gdt）和动作帧的推进逐帧对得上（错位一帧在决策点的残差里只差几 ms，
        # 中位数看不出来，所以直接比积分本身）
        e2g_err = []
        for s in linked[:80]:
            frs = s.atp.frames(s.em, s.t0, s.t0 + 3.0)
            if len(frs) < 10:
                continue
            integ = integrate(s, frs)
            for k in range(1, len(frs)):
                if frs[k].get("mid") != frs[0].get("mid") or integ[k][2] is None:
                    break
                e2g_err.append(abs((integ[k][2] - integ[0][2]) - (frs[k]["mf"] - frs[0]["mf"])))
        check(len(e2g_err) > 500 and max(e2g_err) < 0.05,
              f"F4：E2g 每段推进 = tot × 前一帧开头的 DeltaTime，和动作帧逐帧对上（最大差 "
              f"{fmt(max(e2g_err) if e2g_err else None, 4)} 帧）")
        good = [sp for sp in ("em19", "em20", "em23", "em27", "em40")]
        check(all(verdict.get(sp, {}).get("verdict") == "cids" for sp in good),
              "F1：碰撞体编号可分辨的怪种判成 cids 口径："
              + "，".join(f"{sp} {verdict.get(sp, {}).get('verdict')}({fmt(verdict.get(sp, {}).get('real_c'), 2)}/"
                         f"{fmt(verdict.get(sp, {}).get('p_c'), 2)})" for sp in good))
        nv = verdict.get(SYN_NOISY, {})
        check(nv.get("verdict") == "window" and (nv.get("p_c") or 0) > TRUTH_NULL_MAX,
              f"F1：碰撞体编号含糊的 {SYN_NOISY} 退回时间窗（平移命中率 {fmt(nv.get('p_c'), 2)}）")
        check(sum(d["shell"] for d in verdict.values()) > 0 and sum(d["dead"] for d in verdict.values()) > 0,
              "弹体条目和 ATK 钩子停了以后的片段不定 ATK 真值")
        check(not any(s.truth_ok and s.species == SYN_NOISY for s in segs) and not any(s.truth_ok and s.is_shell for s in segs),
              "含糊的怪种、弹体都不进主表")
        tr = {(em, round(t, 3)) for em, t in info["truth"]}
        ok_t = [s for s in segs if s.truth_ok]
        right = sum(1 for s in ok_t if (s.em, round(s.t_act, 3)) in tr)
        check(len(ok_t) >= 40 and right >= 0.97 * len(ok_t), f"cids 口径的真值几乎都对：{right}/{len(ok_t)}")
        table, _, c4i = c4_eval(segs, "nominal", (30.0,), trusted=True)
        sm = {n: summarize_resid(table[30.0].get(n, [])) for n in EST_NAMES}
        check(sm["E3"]["n"] >= 40 and (sm["E3"]["mad"] or 9) < 0.02, f"C4 E3 |r| 中位 {fmt(sm['E3']['mad'])} < 0.02 s")
        check((sm["E3a"]["mad"] or 9) < 0.02, f"C4 E3a |r| 中位 {fmt(sm['E3a']['mad'])} < 0.02 s")
        check((sm["E2t"]["mad"] or 9) < 0.025, f"C4 E2t |r| 中位 {fmt(sm['E2t']['mad'])} < 0.025 s")
        check((sm["E2g"]["mad"] or 9) < 0.02, f"C4 E2g |r| 中位 {fmt(sm['E2g']['mad'])} < 0.02 s")
        nd = c4i["n_dec"][30.0]
        fb3 = c4i["fallback"][30.0].get("E3", 0)
        check(nd >= 40 and fb3 <= 0.1 * nd,
              f"F3：一半快照在动作切换前，E3 在决策点仍然几乎不用退回（{fb3}/{nd}；旧版这些全是空）")
        check(c4i["hitch"][30.0] >= 1, f"F5：决策点到真值之间有卡顿的样本单列 {c4i['hitch'][30.0]} 个")
        r40 = [x for k, x in table[30.0]["E0"] if k == "em40"]
        check(r40 and med(r40) < -0.08, f"C4 em40（速度 1.42）基线 E0 早到：中位 {fmt(med(r40))}")
        check((sm["E0"]["p90"] or 0) > 3 * (sm["E3"]["p90"] or 9), "C4 E0 的 |r| P90 比 E3 大得多")
        catch, nsp, n_h5 = c5_catch(segs, "nominal")
        e3 = catch["E3"]
        e0 = catch["E0"]
        check(e3["lomo_n"] >= 30 and e3["lomo_ok"] >= 0.95 * e3["lomo_n"],
              f"C5 E3 留一只怪接住 {e3['lomo_ok']}/{e3['lomo_n']}")
        check(e0["lomo_ok"] < e3["lomo_ok"], f"C5 基线 E0 接住更少：{e0['lomo_ok']}/{e0['lomo_n']}")
        args = argparse.Namespace(hs0_model="auto", decisions=(30.0, 60.0))
        text, summary = analyze([(atp, ap, picked)], args)
        check(summary.get("c1_best") == "B" and summary.get("hs0_model") == "nominal", "报告摘要：C1=B、名义帧模型")
        check(summary.get("best_estimator") in ("E2t", "E2g", "E2m", "E3", "E3a", "E4"),
              f"报告选出的最好估计量 {summary.get('best_estimator')}")
        check(summary.get("c4_truth") == "cids" and summary.get("excluded") == info["bad_n"],
              "报告：C4 用 cids 口径、剔除数一致")
        c0s = summary.get("c0", {})
        check("C0 建结果调用" in text and c0s.get("res_tme", 0) > 50 and c0s.get("res_in_apcal") == c0s.get("res_tme"),
              f"C0：主角目标的结果对象全部对上 APCal 的 obj（{c0s.get('res_in_apcal')}/{c0s.get('res_tme')}）")
        check("| p1 | sgl |" in text, "C0：实参和 sgl 的对照表")
        check("C5 留一只怪交叉验证" in text and "| E3 |" in text and "| E3a |" in text and "时间窗口径的怪种" in text,
              "报告包含 C5 表、E3a、时间窗口径的参考表")
        check("APCal 的 ATK 钩子被它自己的频率守卫停过" in text and "**剔除**" in text, "报告写出 ATK 钩子停过、剔除条数")
        # 1.2：新估计量。这份合成数据把整个速度记在 _Sequence 上（CoreState = 1），激活跟动作层帧号走
        raw = []
        c4_eval(segs, "nominal", (30.0,), trusted=True, samples=raw)
        ests = [x["rows"][x["i"]][3] for x in raw]
        d_seq = [abs(e["E2seq"] - e["E2t"]) for e in ests if e.get("E2seq") is not None and e.get("E2t") is not None]
        one_none = sum(1 for e in ests if (e.get("E2seq") is None) != (e.get("E2t") is None))
        check(len(d_seq) >= 40 and one_none == 0 and max(d_seq) < 1e-6,
              f"1.2：速度全在 Sequence 时 E2seq 和 E2t 逐样本相同（{len(d_seq)}/{len(raw)}，只有一个是空的 {one_none}，"
              f"最大差 {fmt(max(d_seq or [0]), 9)} s；决策帧速度为 0 时两个都是空）")
        check((sm["E2c"]["p90"] or 0) > 3 * (sm["E2t"]["p90"] or 9),
              f"1.2：CoreState = 1 时 E2c 不做速度修正，|r| P90 {fmt(sm['E2c']['p90'])} ≫ E2t {fmt(sm['E2t']['p90'])}")
        c7s = summary.get("c7", {})
        check("C7 速度来源" in text and "| E2c |" in text and c7s.get("verdict") == "tot",
              f"1.2：速度全在 Sequence、激活跟动作层帧号 → C7 判「积 tot」（实际 {c7s.get('verdict')}）")
        check(summary.get("best_estimator") in BASE_EST_NAMES, "1.2：C5 的「接住率最高」只在 1.1 的估计量里挑")
        rc = run([d1, "--out", os.path.join(base, "report_nominal.md"), "--json", os.path.join(base, "s.json")])
        check(rc == 0 and os.path.getsize(os.path.join(base, "report_nominal.md")) > 2000, "命令行跑通并写出报告")

        # 4. 按速度换算的初值：C1 应当选 C，auto 切到 scaled，估计量仍然准
        d2 = os.path.join(base, "scaled")
        os.makedirs(d2, exist_ok=True)
        info2 = synth_write(d2, seed=5, model="scaled", duration=90.0)
        atp2 = AtpSession(info2["session"], group_sessions(find_files(d2, "ATP"))[info2["session"]])
        ap2, picked2 = load_apcal_for(atp2, group_sessions(find_files(d2, "APCal")))
        text2, summary2 = analyze([(atp2, ap2, picked2)], argparse.Namespace(hs0_model="auto", decisions=(30.0,)))
        check(summary2.get("c1_best") == "C" and summary2.get("hs0_model") == "scaled",
              f"scaled 合成：C1={summary2.get('c1_best')} 模型={summary2.get('hs0_model')}")
        e3s = summary2.get("c4", {}).get("30", {}).get("E3", {})
        check((e3s.get("mad") or 9) < 0.025, f"scaled 合成：E3 |r| 中位 {fmt(e3s.get('mad'))}")

        # 5. 只有 ATP、没有 APCal
        d3 = os.path.join(base, "atp_only")
        os.makedirs(d3, exist_ok=True)
        info3 = synth_write(d3, seed=3, model="nominal", with_apcal=False, duration=40.0)
        atp3 = AtpSession(info3["session"], group_sessions(find_files(d3, "ATP"))[info3["session"]])
        ap3, picked3 = load_apcal_for(atp3, {})
        text3, summary3 = analyze([(atp3, ap3, picked3)], argparse.Namespace(hs0_model="auto", decisions=(30.0,)))
        check(ap3 is None and "没有同一次游戏的 APCal 数据" in text3 and summary3.get("c1_best") == "B",
              "只有 ATP 时只做 C1/C6 并给出提示")

        # 6. 两次游戏（两个进程）的数据放在同一个目录：os.clock 范围重叠，但不能互相配错；默认合并分析
        d4 = os.path.join(base, "two_runs")
        os.makedirs(d4, exist_ok=True)
        ia = synth_write(d4, seed=21, model="nominal", duration=50.0, session_base=1791700000)
        ib = synth_write(d4, seed=22, model="nominal", duration=50.0, session_base=1791900000)
        atp_s = group_sessions(find_files(d4, "ATP"))
        apc_s = group_sessions(find_files(d4, "APCal"))
        ga = AtpSession(ia["session"], atp_s[ia["session"]])
        gb = AtpSession(ib["session"], atp_s[ib["session"]])
        apa, pa = load_apcal_for(ga, apc_s)
        apb, pb = load_apcal_for(gb, apc_s)
        check(pa == [ia["session"] + 1] and pb == [ib["session"] + 1], f"两个进程各配各的 APCal：{pa} / {pb}")
        text4, summary4 = analyze([(ga, apa, pa), (gb, apb, pb)], argparse.Namespace(hs0_model="auto", decisions=(30.0,)))
        check(summary4.get("atp_sessions") == [ia["session"], ib["session"]] and "合并 2 个 session" in text4
              and summary4.get("c1_best") == "B", "两个 session 合并分析")
        rc = run([d4, "--separate", "--out", os.path.join(base, "report_sep.md")])
        with open(os.path.join(base, "report_sep.md"), encoding="utf-8") as f:
            sep = f.read()
        check(rc == 0 and sep.count("# 攻击时刻分析") == 2, "--separate 每个 session 一份报告")

        # 7. 1.2：速度拆成 CoreState × Sequence 的两种合成数据，C7 要分得开两种假设；放刀模块那段要单列
        for split, want, seed in (("motion", "tot", 31), ("design", "core", 32)):
            d7 = os.path.join(base, f"split_{split}")
            os.makedirs(d7, exist_ok=True)
            info7 = synth_write(d7, seed=seed, model="nominal", duration=150.0, session_base=1792000000 + seed * 1000,
                                split=split, parry_frac=0.12)
            j7 = os.path.join(base, f"s_{split}.json")
            rc = run([d7, "--out", os.path.join(base, f"report_{split}.md"), "--json", j7])
            with open(j7, encoding="utf-8") as f:
                c7 = json.load(f)[0].get("c7", {})
            km = c7.get("key_main", {})
            e2c, e2t = km.get("E2c", {}), km.get("E2t", {})
            rcn = c7.get("recon", {})
            check(rc == 0 and rcn.get("match", 0) >= 0.99 * max(1, sum(rcn.values())),
                  f"1.2 {split}：EMSPD 重建的分量之积 = tot（{rcn.get('match')}/{sum(rcn.values())}）")
            check(c7.get("motion_rate_best") == "tot", f"1.2 {split}：动画按 tot 走（C7.1 判 {c7.get('motion_rate_best')}）")
            check((e2c.get("n") or 0) >= 15, f"1.2 {split}：关键子集（倒数期间 Sequence≠1）有 {e2c.get('n')} 个样本")
            if split == "motion":
                ok = abs(e2t.get("med") or 9) < 0.02 and (e2c.get("med") or -9) > 0.03
            else:
                ok = abs(e2c.get("med") or 9) < 0.02 and (e2t.get("med") or 9) < -0.03
            check(ok, f"1.2 {split}：关键子集 E2t 中位 {fmt(e2t.get('med'))}，E2c 中位 {fmt(e2c.get('med'))}")
            check(c7.get("verdict") == want, f"1.2 {split}：C7 判「{VERDICT_TXT.get(want)}」（实际 {c7.get('verdict')}）")
            po = c7.get("parry_on") or []
            check(len(po) == 1 and abs(po[0][0] - info7["parry"][0]) < 1e-6 and abs(po[0][1] - info7["parry"][1]) < 1e-6
                  and sum((c7.get("parry_segs") or {}).values()) > 0,
                  f"1.2 {split}：放刀模块开着的时段 {po}（别的进程的不算），重叠的片段 {c7.get('parry_segs')} 单列")
            if split == "design":
                lt = (c7.get("other") or {}).get("core_lt1/30", {})
                a_, b_ = lt.get("E2c") or {}, lt.get("E2c1") or {}
                check((lt.get("n") or 0) >= 5 and abs(a_.get("med") or 9) < 0.02 and (b_.get("med") or -9) > 0.02,
                      f"1.2 design：CoreState < 1 的 {lt.get('n')} 个样本 E2c 中位 {fmt(a_.get('med'))}，"
                      f"E2c1（max(1, C)）偏早 {fmt(b_.get('med'))}")

        # 8. 1.2：旧版 ATP（没有 spd_fields、没有 EMSPD）：新估计量记空，C7 跳过，其余照常
        d8 = os.path.join(base, "no_emspd")
        os.makedirs(d8, exist_ok=True)
        src = os.path.join(base, "split_motion")
        for fn in os.listdir(src):
            if not fn.endswith(".json"):
                continue
            with open(os.path.join(src, fn), encoding="utf-8") as f:
                dd = json.load(f)
            if dd.get("kind") == "ATP":
                dd.pop("spd_fields", None)
                dd["records"] = [r for r in dd.get("records", []) if r.get("k") != "EMSPD"]
            with open(os.path.join(d8, fn), "w", encoding="utf-8") as f:
                json.dump(dd, f)
        j8 = os.path.join(base, "s_no_emspd.json")
        rc = run([d8, "--out", os.path.join(base, "report_no_emspd.md"), "--json", j8])
        with open(j8, encoding="utf-8") as f:
            s8 = json.load(f)[0]
        c4e = (s8.get("c4") or {}).get("30", {})
        check(rc == 0 and (s8.get("c7") or {}).get("skipped") == "no_emspd" and (c4e.get("E2c") or {}).get("n") == 0
              and (c4e.get("E2t") or {}).get("n", 0) > 0,
              "1.2：没有 EMSPD 的旧版 ATP：新估计量记空、C7 跳过，E2t 等照常")
    finally:
        if not keep:
            shutil.rmtree(base, ignore_errors=True)
    print("SELFTEST OK" if not fails else f"SELFTEST FAILED（{len(fails)} 项）")
    return 0 if not fails else 1


def utf8_console():
    """Windows 控制台默认 GBK：报告里有 −、≤ 这类字符，统一按 UTF-8 输出，编不了的字符替换掉而不是抛错。"""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass


if __name__ == "__main__":
    utf8_console()
    sys.exit(run(sys.argv[1:]))
