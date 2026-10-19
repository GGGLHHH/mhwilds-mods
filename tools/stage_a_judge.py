#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
stage_a_judge.py：docs/autoparry/SPEED.md 7.1「A 阶段：机制检验」的正式判定（只用 Python 标准库）。

为什么单独成一个脚本，而不是给 atp_analyze.py 加 --stage-a：
  - 7.1 的单位（每个结果对象 × 每个 reqset 的最早条目）、配对窗 [0.5·A/60 − 0.1, 1.6·A/60 + 0.3]、
    cids 不能用时退回 a5 = reqset（atp_analyze 的 C3 退回的是时间窗）、用 hs 自己的递减当时钟的 E5c，
    都和 atp_analyze「一次 initData 一段、os.clock 积分」的框架不同。塞进去要改它的数据流，容易碰到已有口径。
  - 这里只 import atp_analyze 的加载器和 C3 的零假设对照（build_segments / match_candidates / decide_truth），
    所以「cids 能不能用」和 atp_analyze 报告里的 C3 表是同一段代码算出来的；atp_analyze.py 不改一个字节，
    它的 --selftest 不受影响。import 时关掉 .pyc 写盘，不在 tools/ 下留 __pycache__。

输入：同 atp_analyze —— 数据目录里的 ATP_*.json、同一次游戏的 APCal_*.json、AutoParryGS_*.json（定放刀开着的时段）。

口径（逐条对应 SPEED.md 7.1；原文没写清的地方选最保守的做法，报告第 1 节逐条写明）：
  单位   每个结果对象（APCal MSG，tme=1）、每个 reqset 的最早条目：有 DANGER 样本、非弹体（ENT 或 INIT 任一说是弹体就剔除）、
         有 reqset；最早 = 首个 SER 的 hs 最小。A = 首个 SER 的 hs（登记后第一个帧回调），t1 = 它的时刻。
  配对   怪种的 cids 通过 atp_analyze C3 的零假设对照 → a5 ∈ CollidableIDList（INIT 的 cids）；否则 a5 = reqset。
         同一只怪（em 带 # 编号）、消息之后第一次满足条件的 ATK，el = t_ATK − t1 落在 [0.5·A/60 − 0.1, 1.6·A/60 + 0.3]
         才算配上；第一次就落在窗外 → 没配上（不再往后找）。窗口碰到 ATK 钩子停掉 / 记录结束 → 剔除（不算没配上）。
  剔除   放刀模块开着的时段（AutoParryGS HDR/CFG）里的消息；设计阶段见过的怪种（em18/19/20/23/27）。
  残差   r = t_ATK − T̂_E5c − b，b = −0.022（冻结）。T̂_E5c：v1.6 的 E5c 原样离线重放 —— 登记后第一个帧回调起，
         X += Δhs·(m − 1)（hs 自己的递减当时钟，SER 稀疏时按 EMSPD 的变化点切段取时间加权），m = max(1, C)，
         Q = (hs − X)/m，T̂ = t + Q/60；只在 SER 上真实存在的点求值（主口径：激活前最后一个真实 SER 点 = 全程积分；
         敏感性：L=28/25 的触发帧）。C = EMSPD 重建的逐帧 _CoreState（同一帧的 EMSPD 比 SER 早 0~1 ms，容差 3 ms）。
  判据   1 |中位 r| ≤ 0.03；2 IQR ≤ 0.10；3 E0 残差对 x = −A(1−1/C1)/60 的 Theil–Sen 斜率 ∈ [0.8, 1.3]（sd(x) ≥ 0.03 才判；
         两两斜率只取 |Δx| > 0.01 的对，同 v9_calib）；4 计时器：相邻 SER 对（0 < Δt ≤ 0.1 s）|Δhs + 60Δt| ≤ 2 帧
         （单帧 > 0.133 s 的钳制除外），序列速率中位 1.000 ± 0.005；5 INIT 的 hs − AttackStartFrame 按 C 分档（每档 ≥ 5），
         各档中位 |·| ≤ 2 帧。
  逐只怪 |中位 r| > 0.06 或 IQR > 0.15 → 「系统性失败嫌疑」。
  E5 判定 存活期 C 变过的单位上，中位 |r_E5c| ≤ 中位 |r_E1| → 保持 E5c，否则改用 E1。

用法：
  python tools/stage_a_judge.py tools/out/stageA_data --out tools/out/stageA_report.md [--json summary.json]
  python tools/stage_a_judge.py --selftest
"""

import argparse
import bisect
import json
import math
import os
import random
import sys
from collections import Counter, defaultdict

sys.dont_write_bytecode = True          # import atp_analyze 时不在 tools/ 下留 __pycache__（SPEED 8.16）
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import atp_analyze as aa  # noqa: E402

VERSION = "stage_a_judge 1.0"

# ---- 7.1 冻结的常数和门槛（原文照抄，不许改）
B_FROZEN = -0.022             # r = t_ATK − T̂_E5c − b
TH_MED = 0.03                 # 判据 1：|r 中位| ≤ 0.03 s
TH_IQR = 0.10                 # 判据 2：IQR ≤ 0.10 s
TH_SLOPE = (0.8, 1.3)         # 判据 3：Theil–Sen 斜率
TH_SDX = 0.03                 # 判据 3：x 的标准差 ≥ 0.03 s 才判
TH_JUMP = 2.0                 # 判据 4：没有超过 2 帧的跳变
TH_CLAMP = 0.133              # 判据 4：单帧 > 0.133 s 的钳制除外
TH_RATE = 0.005               # 判据 4：速率 1.000 ± 0.005
TH_INIT = 2.0                 # 判据 5：各档中位绝对值 ≤ 2 帧
INIT_BIN_MIN = 5              # 判据 5：每档 ≥ 5 个
FLAG_MED, FLAG_IQR = 0.06, 0.15   # 逐只怪「系统性失败嫌疑」
UNIT_MIN, PAIR_MIN = 60, 0.60     # 每只怪至少 60 个单位、配对率 ≥ 60%
WIN_LO_K, WIN_LO_C, WIN_HI_K, WIN_HI_C = 0.5, -0.1, 1.6, 0.3     # 配对窗 [0.5·A/60 − 0.1, 1.6·A/60 + 0.3]
DESIGN_SPECIES = ("em18", "em19", "em20", "em23", "em27")       # 设计阶段见过的怪种（SPEED 开头的记号）

# ---- 规则参数（V16.md：用户在 A 之前定了 L = 28；L_min 22）与只报告项用的常数（SPEED 3.3、3.4、附录 B）
L_USER, L_ALT, L_MIN = 28, 25, 22
D_BAR = 0.46                  # 放刀那一帧读数平均比 L 低 0.46 帧
W0 = aa.W0                    # 0.328 s
LEFT_TAIL = -0.10             # 左尾：r < −0.10 s
SUCC_LEAD = 0.45              # 后继结果的登记提前量 < 0.45 s 的比例

# ---- 实现细节（不是判据）
FRAME_TOL = 0.003             # 同一帧：ATP 的 EMF/EMSPD 比 APCal 的 SER 早 0~1 ms（实测），帧间隔 ≥ 7 ms
JUMP_CUT = aa.JUMP_CUT        # SER 的 hs 回跳 > 2 帧：条目被重新初始化，这次倒数到此为止
INIT_MAX_LAG = 0.1            # 条目的 INIT 最多比首个 SER 早 0.1 s
SER_GAP_WARN = 0.10           # 激活前最后一个真实 SER 点离激活超过这么多秒，单列
COMP_DEV = 0.001              # 分量 ≠ 1 的判定（EMSPD 写 4 位小数）
C_SAME = 0.0005               # 两个 CoreState 读数算「一样」
CT_AFTER = aa.CT_AFTER_ACT    # 激活之后找第一次接触：(−0.05, 0.60)
BOOT_N, BOOT_SLOPE_N, BOOT_SEED = 2000, 400, 17
NONE_STR = (None, "none", "-", "None", "")
SPD_SHORT = {"_Base": "Base", "_Action": "Action", "_Scale": "Scale", "_MoveAction": "MoveAction",
             "_MoveSpeed": "MoveSpeed", "_Random": "Random", "_CoreState": "CoreState", "_Replica": "Replica",
             "_WaitPacketReserved": "WaitPacketReserved", "_WaitPacket": "WaitPacket", "_Sequence": "Sequence",
             "_BlendTree": "BlendTree"}


# ================================================================ 小工具
def q(xs, p):
    return aa.quant([x for x in xs if x is not None], p)


def med(xs):
    return q(xs, 0.5)


def iqr(xs):
    a, b = q(xs, 0.25), q(xs, 0.75)
    return None if a is None or b is None else b - a


def fmt(x, nd=3):
    return aa.fmt(x, nd)


def sfmt(x, nd=3):
    """带符号。"""
    return "-" if x is None else f"{x:+.{nd}f}"


def pct(a, b):
    return aa.pct(a, b)


def pop_sd(xs):
    xs = [x for x in xs if x is not None]
    if len(xs) < 2:
        return None
    m = sum(xs) / len(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / len(xs))


def theil(xs, ys, min_dx=0.01):
    """Theil–Sen 斜率：两两斜率的中位数，只取 |Δx| > min_dx 的对（同 SPEED 审查复算 v9_calib / phaseA_check）。"""
    sl = []
    n = len(xs)
    for i in range(n):
        for j in range(i + 1, n):
            dx = xs[j] - xs[i]
            if abs(dx) > min_dx:
                sl.append((ys[j] - ys[i]) / dx)
    return med(sl) if sl else None


def binom_cdf_table(n):
    pm = [math.comb(n, k) * 0.5 ** n for k in range(n + 1)]
    out, acc = [], 0.0
    for p in pm:
        acc += p
        out.append(acc)
    return out


def median_ci(xs, conf=0.95):
    """中位数的次序统计量区间（假设样本独立；不独立时偏窄，所以另给按招整簇重抽的区间）。"""
    xs = sorted(x for x in xs if x is not None)
    n = len(xs)
    if n < 6:
        return None
    cdf = binom_cdf_table(n)
    a = (1.0 - conf) / 2.0
    k = 0
    while k + 1 <= n and cdf[k] <= a:      # P(B ≤ k) ≤ a → 下界可取第 k+1 小
        k += 1
    if k < 1:
        return None
    return xs[k - 1], xs[n - k]


def cluster_boot(units, stat, key, n_boot, seed, strata=None):
    """按簇（招）整簇重抽；strata 给了就在每层（怪）里各自重抽，保持每只怪的招数不变。返回统计量列表。"""
    rng = random.Random(seed)
    if strata is None:
        strata = lambda u: 0  # noqa: E731
    layers = defaultdict(lambda: defaultdict(list))
    for u in units:
        layers[strata(u)][key(u)].append(u)
    lay = [(sorted(g, key=str), g) for _, g in sorted(layers.items(), key=lambda x: str(x[0]))]
    out = []
    for _ in range(n_boot):
        smp = []
        for keys, g in lay:
            for _ in keys:
                smp.extend(g[keys[rng.randrange(len(keys))]])
        v = stat(smp)
        if v is not None:
            out.append(v)
    return out


def pint(vals, lo=0.025, hi=0.975):
    return (q(vals, lo), q(vals, hi)) if vals else (None, None)


def ci_txt(ci, nd=3, signed=True):
    if not ci or ci[0] is None:
        return "-"
    f = sfmt if signed else fmt
    return f"{f(ci[0], nd)}~{f(ci[1], nd)}"


def to_int(x):
    try:
        return int(float(x))
    except (TypeError, ValueError):
        return None


def group_by(xs, key):
    out = defaultdict(list)
    for x in xs:
        out[key(x)].append(x)
    return out


def cp_interval(k, n, conf=0.95):
    """Clopper–Pearson 区间（二分求二项分布的分位，不依赖 scipy）。"""
    if n <= 0:
        return None

    def cdf(kk, p):
        return sum(math.comb(n, i) * p ** i * (1 - p) ** (n - i) for i in range(0, kk + 1))
    a = (1.0 - conf) / 2.0

    def solve(f):
        lo, hi = 0.0, 1.0
        for _ in range(60):
            mid = (lo + hi) / 2.0
            if f(mid):
                hi = mid
            else:
                lo = mid
        return (lo + hi) / 2.0
    low = 0.0 if k == 0 else solve(lambda p: 1.0 - cdf(k - 1, p) >= a)
    up = 1.0 if k == n else solve(lambda p: cdf(k, p) <= a)
    return low, up


# ================================================================ 读数据
class Raw:
    """APCal 里 7.1 要按 (结果对象, 条目) 用、而 atp_analyze.ApcalData 只按条目地址存的记录（条目地址会被重用）。"""

    def __init__(self, apcal_sessions, picked):
        self.msg, self.ent = {}, {}
        self.ser = defaultdict(list)
        self.ct = defaultdict(list)
        self.emhit = defaultdict(list)
        self.hitch = []
        self.stop = None
        self.vers = Counter()
        self.n_err_atk = 0
        for s in picked:
            for _, p in apcal_sessions.get(s, []):
                try:
                    d = aa.load_json(p)
                except (OSError, ValueError):
                    continue
                if d.get("kind") != "APCal":
                    continue
                self.vers[str(d.get("ver"))] += 1
                for r in d.get("records", []):
                    t = aa.num(r.get("t"))
                    if t is None:
                        continue
                    k = r.get("k")
                    if k == "SER":
                        hs = aa.num(r.get("hs"))
                        if hs is not None:
                            self.ser[(r.get("obj"), r.get("ent"))].append(
                                (t, hs, aa.num(r.get("he")), r.get("type"), r.get("f")))
                    elif k == "MSG" and r.get("tme") == 1:
                        o = r.get("obj")
                        if o not in self.msg or t < self.msg[o]["t"]:
                            rr = dict(r)
                            rr["t"] = t
                            self.msg[o] = rr
                    elif k == "ENT":
                        self.ent.setdefault((r.get("obj"), r.get("ent")), r)
                    elif k == "CT":
                        self.ct[r.get("em")].append((t, r.get("cls"), r.get("res")))
                    elif k == "EMHIT":
                        self.emhit[r.get("em")].append(t)
                    elif k in ("HITCH", "GAP"):
                        self.hitch.append((t, aa.num(r.get("dt")), aa.num(r.get("gdt")), k))
                    elif k == "STOP":
                        self.stop = t if self.stop is None else min(self.stop, t)
                    elif k == "ERR" and r.get("mod") == "ATK":
                        self.n_err_atk += 1
        for v in self.ser.values():
            v.sort(key=lambda x: x[0])
        for d in (self.ct, self.emhit):
            for v in d.values():
                v.sort(key=lambda x: x[0] if isinstance(x, tuple) else x)
        self.ct_t = {k: [x[0] for x in v] for k, v in self.ct.items()}
        self.hitch.sort()
        self.hitch_t = [x[0] for x in self.hitch]
        self.ents_of = defaultdict(list)
        for (o, e) in self.ser:
            self.ents_of[o].append(e)


class Speed:
    """一只怪的 _MotionSpeed 分量时间线：EMSPD 只在分量变化时记（开始盯这只怪的第一帧必记一条），
    每一帧的分量 = 这一帧开头之前（含同一帧）最近的一条。"""

    def __init__(self, ts, vs, ix):
        self.ts, self.vs, self.ix = ts, vs, ix
        self.i_core = ix.get("_CoreState")

    @classmethod
    def of(cls, atp, em):
        return cls(atp.emspd_t.get(em, []), atp.emspd_v.get(em, []), atp.spd_ix)

    def at(self, t):
        """SER 帧开头 t 这一帧读到的分量（同一帧的 EMSPD 比 SER 早 0~1 ms，容差 FRAME_TOL）。"""
        i = bisect.bisect_right(self.ts, t + FRAME_TOL) - 1
        return self.vs[i] if i >= 0 else None

    def core(self, comp):
        return None if comp is None or self.i_core is None else comp[self.i_core]

    def core_at(self, t):
        return self.core(self.at(t))

    def pieces(self, ta, tb):
        """[ta, tb) 里分量的分段 [(起, 止, 分量)]：ta、tb 都是 SER 帧开头；tb 那一帧自己的 EMSPD 不算进来。"""
        c = self.at(ta)
        i = bisect.bisect_right(self.ts, ta + FRAME_TOL)
        j = bisect.bisect_right(self.ts, tb - FRAME_TOL)
        out, t0 = [], ta
        for k in range(i, j):
            out.append((t0, self.ts[k], c))
            t0, c = self.ts[k], self.vs[k]
        out.append((t0, tb, c))
        return out


def e5_track(samples, spd, use_max=True):
    """v1.6 的 E5c 离线重放（SPEED 5.2 伪代码）。samples = 同一条目、同一次初始化的真实 SER 点 [(t, hs)]，
    第一个点 = 登记后第一个帧回调（X 从这里起累加）。每一段 (t_{k−1}, t_k] 怪物多走的名义帧 = Δhs·(m̄ − 1)，
    Δhs 是 hs 自己的递减（当时钟）；m̄ = 这一段里 m 的时间加权平均 —— SER 每帧都有时就是上一帧读到的 m（同伪代码），
    SER 每 4 帧一格时按 EMSPD 的变化点切段。Q = (hs − X)/m（m 用这一帧读到的），T̂ = t + Q/60。
    use_max=False 时 m = C（不按 1 截，SPEED 2.1 n 的 E5）。返回 [(t, hs, X, m, Q, T̂)]；读不到 C → None。"""
    out = []
    x = 0.0
    prev = None
    for t, hs in samples:
        c = spd.core_at(t)
        if c is None:
            return None
        m = max(1.0, c) if use_max else c
        if m < aa.SPEED_MIN:
            return None
        if prev is not None:
            tp, hp, mp = prev
            if t > tp:
                acc = 0.0
                for a, b, cc in spd.pieces(tp, t):
                    v = spd.core(cc)
                    if v is None:
                        v = mp
                    acc += (max(1.0, v) if use_max else v) * (b - a)
                mbar = acc / (t - tp)
            else:
                mbar = mp
            x += (hp - hs) * (mbar - 1.0)
        qv = (hs - x) / m
        out.append((t, hs, x, m, qv, t + qv / 60.0))
        prev = (t, hs, m)
    return out


def split_seq(xs, init_ts):
    """一个 (对象, 条目) 的 SER 按「重新初始化」切开：hs 回跳 > 2 帧，或这一段里有这个条目地址的新 INIT。返回序列列表。"""
    seqs, cur = [], []
    for x in xs:
        if cur:
            reinit = x[1] - cur[-1][1] > JUMP_CUT
            if not reinit and init_ts:
                i = bisect.bisect_right(init_ts, cur[-1][0] + 1e-6)
                reinit = i < len(init_ts) and init_ts[i] <= x[0] + 1e-6
            if reinit:
                seqs.append(cur)
                cur = []
        cur.append(x)
    if cur:
        seqs.append(cur)
    return seqs


def load_inputs(data_dir, session=None):
    atp_sessions = aa.group_sessions(aa.find_files(data_dir, "ATP"))
    if not atp_sessions:
        raise SystemExit(f"{data_dir} 里没有 ATP_*.json")
    if session is None:
        session = max(atp_sessions, key=lambda s: len(atp_sessions[s]))
    if session not in atp_sessions:
        raise SystemExit(f"没有 ATP session {session}")
    apcal_sessions = aa.group_sessions(aa.find_files(data_dir, "APCal"))
    parry_sessions = aa.find_parry_files(data_dir)
    atp = aa.AtpSession(session, atp_sessions[session])
    ap, picked = aa.load_apcal_for(atp, apcal_sessions, None)
    if ap is None:
        raise SystemExit("没有同一次游戏的 APCal 数据：7.1 要 SER / ATK")
    atp.parry_on, atp.parry_fires = aa.load_parry_for(atp, parry_sessions)
    raw = Raw(apcal_sessions, picked)
    # C3：cids 能不能用（atp_analyze 的零假设对照，原样复用）
    segs = aa.build_segments(atp, ap)
    aa.match_candidates(segs, ap)
    verdict = aa.decide_truth(segs)
    return atp, ap, raw, verdict, picked


# ================================================================ 单位
def in_parry(parry_on, ta, tb):
    return any(a <= tb and ta <= b for a, b in parry_on)


def build_units(atp, ap, raw, verdict, design=DESIGN_SPECIES):
    """7.1 的单位 + 配对 + 每个单位的各种预测。返回 (units, 计数, 被剔除的消息计数)。"""
    by_ent = defaultdict(list)
    for r in atp.inits:
        t = aa.num(r.get("t"))
        if t is not None:
            by_ent[r.get("ent")].append((t, r))
    for v in by_ent.values():
        v.sort(key=lambda x: x[0])
    init_ts = {e: [x[0] for x in v] for e, v in by_ent.items()}
    spd_cache = {}

    def init_for(e, t1):
        ts = init_ts.get(e, [])
        i = bisect.bisect_right(ts, t1 + 1e-6) - 1
        if i >= 0 and t1 - ts[i] <= INIT_MAX_LAG:
            return by_ent[e][i][1]
        return None

    def spd(em):
        if em not in spd_cache:
            spd_cache[em] = Speed.of(atp, em)
        return spd_cache[em]

    cnt = defaultdict(Counter)
    excl = Counter()
    units = []
    for obj, m in raw.msg.items():
        em = m.get("em")
        sp = aa.species_of(em)
        t_msg = m["t"]
        ents = raw.ents_of.get(obj, [])
        if sp in design:
            excl["design_species"] += 1
            continue
        groups = defaultdict(list)
        n_shell = n_noreq = 0
        has_danger = False
        for e in ents:
            xs = raw.ser[(obj, e)]
            if not any(x[3] == "DANGER" for x in xs):
                continue
            has_danger = True
            en = raw.ent.get((obj, e)) or {}
            t1 = xs[0][0]
            ini = init_for(e, t1)
            sh_ent = str(en.get("shell")) if en else None
            sh_ini = str(ini.get("shell")) if ini else None
            is_shell = (sh_ent not in NONE_STR) or (sh_ini not in NONE_STR)
            rq = to_int(en.get("reqset")) if en else None
            if rq is None and ini is not None:
                rq = to_int(ini.get("req"))
            if is_shell:
                n_shell += 1
                continue
            if rq is None:
                n_noreq += 1
                continue
            groups[rq].append({"ent": e, "xs": xs, "en": en, "ini": ini, "hs1": xs[0][1], "t1": t1,
                               "idx": en.get("idx")})
        if has_danger and in_parry(atp.parry_on, t_msg, t_msg + 12.0):
            excl["parry_on"] += 1
            continue
        if not has_danger:
            continue
        c = cnt[sp]
        c["danger_obj"] += 1
        c["shell_ent"] += n_shell
        c["noreq_ent"] += n_noreq
        for rq, lst in groups.items():
            lst.sort(key=lambda z: (z["hs1"], z["t1"], str(z["idx"])))
            z = lst[0]
            u = make_unit(m, obj, rq, z, verdict, ap, raw, spd(em), init_ts.get(z["ent"], []))
            u["n_same_rq"] = len(lst)
            c["cand"] += 1
            c[u["status"]] += 1
            units.append(u)
    contact_layer(units, raw)
    return units, cnt, excl


def make_unit(m, obj, rq, z, verdict, ap, raw, spd, init_ts_ent):
    em = m.get("em")
    sp = aa.species_of(em)
    ini = z["ini"] or {}
    en = z["en"] or {}
    a_nom = z["hs1"]
    t1 = z["t1"]
    cids = aa.parse_cids(ini.get("cids")) if ini else set()
    comp_hook = aa.parse_comp(ini.get("scomp"), len(spd.ix)) if ini else None
    u = {"sp": sp, "em": em, "obj": obj, "act": m.get("keep"), "t_msg": m["t"], "rq": rq, "ent": z["ent"],
         "A": a_nom, "t1": t1, "lag": t1 - m["t"], "guard": en.get("guard"), "dmg": en.get("dmgtype"),
         "pbreak": en.get("pbreak"), "n_same_rq": None, "angry": ini.get("angry"), "tired": ini.get("tired"),
         "ast": aa.num(ini.get("ast")), "hs_init": aa.num(ini.get("hs")), "sgl": aa.num(ini.get("sgl")),
         "C_hook": spd.core(comp_hook) if comp_hook else None, "has_init": bool(ini), "ncids": len(cids),
         "rq_in_cids": rq in cids}
    rule = "cids" if (verdict.get(sp) or {}).get("verdict") == "cids" else "reqset"
    u["rule"] = rule
    lo = WIN_LO_K * a_nom / 60.0 + WIN_LO_C
    hi = WIN_HI_K * a_nom / 60.0 + WIN_HI_C
    u["win"] = (lo, hi)
    # 这次倒数的真实 SER 点：到重新初始化为止
    seqs = split_seq(z["xs"], init_ts_ent)
    seq = seqs[0]
    samples = [(x[0], x[1]) for x in seq]
    u["ser_end"] = samples[-1][0]
    u["C1"] = spd.core_at(t1)
    # ATK 钩子活着、记录没结束（7.1：剔除 ATK 守卫关掉的时段）
    if not ap.atk_ok(t1 + lo, t1 + hi):
        u["status"] = "atk_dead"
        return u
    if u["C1"] is None:
        u["status"] = "no_C"
        return u
    # 配对：同一只怪、消息之后第一次 a5 满足条件的 ATK
    atks = ap.atk.get(em, [])
    tl = ap.atk_t.get(em, [])
    i = bisect.bisect_right(tl, m["t"])
    first = None
    for t, a4, a5 in atks[i:]:
        if t > t1 + hi:
            break
        ok = (a5 is not None and a5 in cids) if rule == "cids" else (a5 == rq)
        if ok:
            first = (t, a4, a5)
            break
    # 另一种 a5 口径（只报告：cids 怪种看 reqset、reqset 怪种看 cids）
    alt = None
    for t, a4, a5 in atks[i:]:
        if t > t1 + hi:
            break
        ok = (a5 == rq) if rule == "cids" else (a5 is not None and a5 in cids)
        if ok:
            alt = t
            break
    u["alt_paired"] = alt is not None and lo <= alt - t1 <= hi
    u["alt_t_atk"] = alt if u["alt_paired"] else None
    # 消息之前 ≤ 20 ms（同一帧）就有满足条件的激活：按 7.1「消息之后」不算；phaseA_check 允许消息前 0.02 s（只报告）
    pre = None
    for t, a4, a5 in atks[bisect.bisect_left(tl, m["t"] - 0.02):i]:
        ok = (a5 is not None and a5 in cids) if rule == "cids" else (a5 == rq)
        if ok and lo <= t - t1 <= hi:
            pre = t
    u["pre_msg_atk"] = pre
    tr = e5_track(samples, spd, True)
    trr = e5_track(samples, spd, False)
    u["track"] = tr
    u["track_raw"] = trr
    if tr is None:
        u["status"] = "no_C"
        return u
    u["P0"] = tr[0][5] + B_FROZEN       # 登记时的预测激活时刻（含 b）：接触层归属用
    if first is None:
        u["status"] = "unpaired_none"
    elif first[0] - t1 < lo:
        u["status"] = "unpaired_early"
        u["el_first"] = first[0] - t1
    else:
        u["status"] = "paired"
        u["t_atk"], u["a5"] = first[0], first[2]
    if u["status"] == "paired":
        eval_unit(u, raw, spd, tr, trr)
    elif u["alt_paired"]:
        # 没配上、但另一种 a5 口径能配上的：只为敏感性分析算残差，不进主口径
        eval_unit(u, raw, spd, tr, trr, t_atk=u["alt_t_atk"], prefix="alt_")
    return u


def last_before(track, t):
    k = -1
    for i, row in enumerate(track):
        if row[0] < t:
            k = i
        else:
            break
    return k


def decision(track, kmax, lv):
    """L 的触发帧：第一个 Q ≤ L 的真实 SER 点（只看 kmax 之前）。另返回「Q 有没有落进 [22, L]」（会不会真的放）。"""
    k_dec = None
    trig = False
    for i in range(0, kmax + 1):
        qv = track[i][4]
        if k_dec is None and qv <= lv:
            k_dec = i
        if L_MIN <= qv <= lv:
            trig = True
    return k_dec, trig


def eval_unit(u, raw, spd, tr, trr, t_atk=None, prefix=""):
    t_atk = u["t_atk"] if t_atk is None else t_atk
    t1, a_nom, c1 = u["t1"], u["A"], u["C1"]
    k = last_before(tr, t_atk)
    early_atk = k < 0           # 激活在登记后第一个帧回调之前（极短的招）：用第一个点
    k = max(k, 0)
    that = tr[k][5]
    out = {
        "k": k, "ser_gap": t_atk - tr[k][0], "atk_before_first": early_atk,
        "r": t_atk - that - B_FROZEN, "r_raw": t_atk - that,
        "r_e5raw": (t_atk - trr[k][5] - B_FROZEN) if trr else None,
        "r_e1": t_atk - (t1 + a_nom / (60.0 * c1)) - B_FROZEN,
        "r_e1c": t_atk - (t1 + a_nom / (60.0 * max(1.0, c1))) - B_FROZEN,
        "r0": t_atk - (t1 + a_nom / 60.0),
        "x": -a_nom * (1.0 - 1.0 / c1) / 60.0,
    }
    for lv in (L_USER, L_ALT):
        kd, trig = decision(tr, k, lv)
        if kd is None:
            out[f"dec{lv}"] = None
        else:
            out[f"dec{lv}"] = {"k": kd, "t": tr[kd][0], "Q": tr[kd][4], "That": tr[kd][5],
                               "r": t_atk - tr[kd][5] - B_FROZEN, "r_raw": t_atk - tr[kd][5], "trig": trig}
    # 存活期（登记后第一个帧回调 → 激活）C 变没变；各分量
    pcs = spd.pieces(t1, t_atk) if t_atk > t1 else [(t1, t1 + 1e-9, spd.at(t1))]
    cores = [spd.core(c) for _, _, c in pcs if c is not None]
    out["changed"] = any(abs(c - c1) > C_SAME for c in cores)
    out["m_changed"] = any(abs(max(1.0, c) - max(1.0, c1)) > C_SAME for c in cores)
    out["C_min"] = min(cores) if cores else None
    out["C_max"] = max(cores) if cores else None
    comps = {}
    span = sum(b - a for a, b, c in pcs if c is not None)
    for name, ix in spd.ix.items():
        vals = [(b - a, c[ix]) for a, b, c in pcs if c is not None]
        if not vals:
            continue
        mean = sum(w * v for w, v in vals) / span if span > 0 else vals[0][1]
        comps[name] = {"mean": mean, "min": min(v for _, v in vals), "max": max(v for _, v in vals),
                       "dev": any(abs(v - 1.0) > COMP_DEV for _, v in vals)}
    out["comps"] = comps
    # 接触：激活之后第一次（g = 首个接触 − 激活）
    cts = raw.ct.get(u["em"], [])
    ctl = raw.ct_t.get(u["em"], [])
    j = bisect.bisect_left(ctl, t_atk + CT_AFTER[0])
    out["g"] = (cts[j][0] - t_atk) if j < len(cts) and cts[j][0] <= t_atk + CT_AFTER[1] else None
    out["t_ct"] = cts[j][0] if out["g"] is not None else None
    eh = raw.emhit.get(u["em"], [])
    i0 = bisect.bisect_right(eh, u["t_msg"])
    out["emhit"] = i0 < len(eh) and eh[i0] <= t_atk
    for kk, vv in out.items():
        u[prefix + kk] = vv


def contact_layer(units, raw):
    """接触层（7.1：没配上的招「到接触层单独检查」；配上的也算，作对照）。
    接触（CT）不带是哪一段攻击打的，所以先归属：配对窗 [t1 + max(lo, 0), t1 + hi + 0.6] 里第一次接触，
    归给「登记时预测的激活时刻（含 b）不晚于接触 + 0.05 s、而且最晚」的那个单位（同一只怪的所有单位里挑，
    含没配上的）—— 接触总在激活之后（SPEED 2.1 j，本批 g ≥ 0.01 s）。归到别的单位 → 记「多半是另一段攻击」。
    每个单位记：接触相对 E5c 预测的残差 r_ct（接触前最后一个真实 SER 点求值、减 b），以及按 L 的触发帧放刀会不会
    放早（接触 − 放刀 < W0；Q 没落进 [22, L] 的不会放刀，记 None）。"""
    by_em = defaultdict(list)
    for u in units:
        if u.get("track") and u.get("P0") is not None:
            by_em[u["em"]].append(u)
    for v in by_em.values():
        v.sort(key=lambda u: u["P0"])
    for em, us in by_em.items():
        cts = raw.ct.get(em, [])
        ctl = raw.ct_t.get(em, [])
        p0s = [u["P0"] for u in us]
        for u in us:
            lo, hi = u["win"]
            tr = u["track"]
            j = bisect.bisect_left(ctl, u["t1"] + max(lo, 0.0))
            if j >= len(cts) or cts[j][0] > u["t1"] + hi + CT_AFTER[1]:
                u["cl"] = None
                continue
            t_ct = cts[j][0]
            i = bisect.bisect_right(p0s, t_ct + 0.05) - 1
            owner = us[i] if i >= 0 else None
            mine = owner is not None and (owner is u or (owner["obj"] == u["obj"] and abs(owner["P0"] - u["P0"]) < 0.02))
            k = max(last_before(tr, t_ct), 0)
            res = {"t_ct": t_ct, "r_ct": t_ct - tr[k][5] - B_FROZEN, "mine": mine,
                   "owner": None if (owner is None or mine) else (owner["act"], owner["rq"], owner["status"])}
            for lv in (L_USER, L_ALT):
                kd, trig = decision(tr, k, lv)
                res[f"early{lv}"] = None if kd is None or not trig else (t_ct - tr[kd][0] < W0)
            u["cl"] = res


# ================================================================ 判据
def crit_timer(raw, atp, objs):
    """判据 4。测法同设计阶段（SPEED 2.1 d，synthesis/mech.py）：同一 (对象, 条目) 的相邻 SER 对、0 < Δt ≤ 0.1 s，
    d = Δhs + 60·Δt；序列速率 = hs 对 t 的最小二乘斜率 ÷ (−60)（≥ 10 个点、跨度 > 0.3 s）。另报两种对照测法：
    按引擎 DeltaTime（C2 实测 hs 每帧扣的是「前一帧开头读到的」DeltaTime）、相邻两对合起来的 d。"""
    by_ent_init = defaultdict(list)
    for r in atp.inits:
        t = aa.num(r.get("t"))
        if t is not None:
            by_ent_init[r.get("ent")].append(t)
    for v in by_ent_init.values():
        v.sort()
    emf_gdt = {}
    for em, rows in atp.emf.items():
        emf_gdt[em] = ([x["t"] for x in rows], [x.get("gdt") for x in rows])
    n_pairs = 0
    big, clamp = [], []
    lag_d = []
    net2 = []
    rates = []
    n_seq = 0
    for (obj, e), xs in raw.ser.items():
        if obj not in objs:
            continue
        em = raw.msg[obj].get("em")
        gt, gv = emf_gdt.get(em, ([], []))
        for seq in split_seq(xs, by_ent_init.get(e, [])):
            n_seq += 1
            ds = []
            recs = []
            for a, b in zip(seq, seq[1:]):
                dt = b[0] - a[0]
                if not (0 < dt <= 0.1):
                    ds.append(None)
                    continue
                n_pairs += 1
                d = (b[1] - a[1]) + 60.0 * dt
                ds.append(d)
                if abs(d) > TH_JUMP:
                    j0 = bisect.bisect_left(raw.hitch_t, a[0] - 0.002)
                    j1 = bisect.bisect_right(raw.hitch_t, b[0] + 0.002)
                    hg = raw.hitch[j0:j1]
                    rec = {"t": a[0], "obj": obj, "ent": e, "em": em, "dt": dt, "dhs": b[1] - a[1], "d": d,
                           "hitch": [(round(h[0], 3), h[1], h[2], h[3]) for h in hg], "i": len(ds) - 1}
                    recs.append(rec)
                    if any((h[1] or 0) > TH_CLAMP for h in hg):
                        clamp.append(rec)
                    else:
                        big.append(rec)
                # 引擎 DeltaTime：a 这一帧开头读到的 gdt（帧），APCal 帧号连续的对才比
                if a[4] is not None and b[4] == a[4] + 1 and gt:
                    i = bisect.bisect_left(gt, a[0] - FRAME_TOL)
                    if i < len(gt) and abs(gt[i] - a[0]) <= FRAME_TOL and gv[i] is not None:
                        lag_d.append((b[1] - a[1]) + gv[i])
            for rec in recs:       # 前后各 2 对的 d：看是不是下一两帧就抵消（DeltaTime 晚生效）还是一直错下去（真跳变）
                i = rec.pop("i")
                ctx = ds[max(0, i - 2):i + 3]
                rec["ctx"] = [None if x is None else round(x, 2) for x in ctx]
                rec["net5"] = sum(x for x in ctx if x is not None)
            for d1, d2 in zip(ds, ds[1:]):
                if d1 is not None and d2 is not None:
                    net2.append(d1 + d2)
            if len(seq) >= 10 and seq[-1][0] - seq[0][0] > 0.3:
                n = len(seq)
                mt = sum(x[0] for x in seq) / n
                mh = sum(x[1] for x in seq) / n
                sxx = sum((x[0] - mt) ** 2 for x in seq)
                sxy = sum((x[0] - mt) * (x[1] - mh) for x in seq)
                if sxx > 0:
                    rates.append(-sxy / sxx / 60.0)
    # 同一时刻的几条条目（同一个结果对象的不同条目）各记一对：按 (时刻, 怪) 合成「事件」
    ev = sorted({(round(r["t"], 3), r["em"]) for r in big})
    events = []
    for t, em in ev:
        rs = [r for r in big if round(r["t"], 3) == t and r["em"] == em]
        events.append({"t": t, "em": em, "n_pairs": len(rs), "dt": rs[0]["dt"], "dhs": rs[0]["dhs"], "d": rs[0]["d"],
                       "hitch": rs[0]["hitch"], "ctx": rs[0]["ctx"], "net5": max(abs(r["net5"]) for r in rs)})
    rate_med = med(rates)
    out = {"n_pairs": n_pairs, "n_seq": n_seq, "n_big": len(big), "events": events, "n_clamp": len(clamp),
           "rate_med": rate_med, "rate_q05": q(rates, 0.05), "rate_q95": q(rates, 0.95), "n_rates": len(rates),
           "rate_out": sum(1 for r in rates if abs(r - 1.0) > TH_RATE),
           "lag_n": len(lag_d), "lag_absmax": max((abs(x) for x in lag_d), default=None),
           "lag_big": sum(1 for x in lag_d if abs(x) > TH_JUMP), "lag_p99": q([abs(x) for x in lag_d], 0.99),
           "net2_n": len(net2), "net2_absmax": max((abs(x) for x in net2), default=None),
           "net2_big": sum(1 for x in net2 if abs(x) > TH_JUMP),
           "net5_max": max((abs(r["net5"]) for r in big), default=None)}
    out["rate_ok"] = rate_med is not None and abs(rate_med - 1.0) <= TH_RATE
    out["jump_ok_literal"] = len(big) == 0
    return out


def crit_init(rows, key):
    """判据 5：rows = [(C, hs − ast)]，按 C（3 位小数）分档，每档 ≥ 5 个才判。"""
    bins = defaultdict(list)
    for c, d in rows:
        if c is None or d is None:
            continue
        bins[round(c, 3)].append(d)
    tab = []
    ok = True
    judged = 0
    for c, v in sorted(bins.items()):
        mv = med(v)
        j = len(v) >= INIT_BIN_MIN
        p = abs(mv) <= TH_INIT if j else None
        if j:
            judged += 1
            ok = ok and p
        tab.append({"C": c, "n": len(v), "med": mv, "q10": q(v, 0.1), "q90": q(v, 0.9), "judged": j, "pass": p})
    return {"key": key, "bins": tab, "judged": judged, "pass": (ok and judged > 0), "n": sum(len(v) for v in bins.values())}


def design_hitch_check(dirs):
    """判据 4 的旁证：设计阶段数据（round*_data 的 APCal）里，同一测法（相邻 SER 对、0 < Δt ≤ 0.1 s）有没有 |d| > 2，
    以及 ≥ 45 ms 的卡顿帧（HITCH/GAP）有没有落在逐帧（帧号连续）的 SER 相邻对上 —— 7.1 表里「0 次」的标定有没有碰到过卡顿。"""
    out = []
    for d in dirs:
        sess = aa.group_sessions(aa.find_files(d, "APCal"))
        for s, paths in sorted(sess.items()):
            ser = defaultdict(list)
            hitch = []
            vers = set()
            for _, p in paths:
                try:
                    j = aa.load_json(p)
                except (OSError, ValueError):
                    continue
                vers.add(str(j.get("ver")))
                for r in j.get("records", []):
                    t = aa.num(r.get("t"))
                    if t is None:
                        continue
                    if r.get("k") == "SER" and aa.num(r.get("hs")) is not None:
                        ser[(r.get("obj"), r.get("ent"))].append((t, aa.num(r.get("hs")), r.get("f")))
                    elif r.get("k") in ("HITCH", "GAP") and (aa.num(r.get("dt")) or 0) >= 0.045:
                        hitch.append((t, aa.num(r.get("dt"))))
            n = big = 0
            hit = {}
            for xs in ser.values():
                xs.sort(key=lambda x: x[0])
                for a, b in zip(xs, xs[1:]):
                    dt = b[0] - a[0]
                    if not (0 < dt <= 0.1):
                        continue
                    n += 1
                    dd = (b[1] - a[1]) + 60.0 * dt
                    big += 1 if abs(dd) > TH_JUMP else 0
                    if a[2] is not None and b[2] == a[2] + 1:
                        for ht, hdt in hitch:
                            if abs(b[0] - ht) < 0.002:
                                hit[round(ht, 3)] = max(hit.get(round(ht, 3), 0.0), abs(dd))
            out.append({"dir": os.path.basename(os.path.normpath(d)), "session": s, "ver": sorted(vers), "pairs": n,
                        "big": big, "n_hitch": len(hitch), "n_hitch_le100": sum(1 for _, x in hitch if x <= 0.1),
                        "hitch_on_dense": len(hit), "max_d_on_hitch": max(hit.values(), default=None)})
    return out


def pooled_stats(us):
    rs = [u["r"] for u in us]
    xs = [u["x"] for u in us]
    r0 = [u["r0"] for u in us]
    sdx = pop_sd(xs)
    sl = theil(xs, r0) if (sdx is not None and sdx >= TH_SDX) else None
    return {"n": len(us), "med": med(rs), "iqr": iqr(rs), "q25": q(rs, 0.25), "q75": q(rs, 0.75), "sdx": sdx,
            "slope": sl, "q10": q(rs, 0.1), "q90": q(rs, 0.9)}


def judge_pooled(st):
    p1 = st["med"] is not None and abs(st["med"]) <= TH_MED
    p2 = st["iqr"] is not None and st["iqr"] <= TH_IQR
    p3 = None if st["slope"] is None else (TH_SLOPE[0] <= st["slope"] <= TH_SLOPE[1])
    return p1, p2, p3


# ================================================================ 主判定
def judge(atp, ap, raw, verdict, picked, opts):
    units, cnt, excl = build_units(atp, ap, raw, verdict)
    new_sp = sorted({u["sp"] for u in units} | set(cnt), key=lambda s: (len(s), s))
    paired = [u for u in units if u["status"] == "paired"]
    res = {"version": VERSION, "atp_session": atp.session, "apcal_sessions": picked, "units": units, "cnt": cnt,
           "excl": excl, "verdict_c3": verdict, "species": new_sp, "parry_on": atp.parry_on,
           "apcal_vers": dict(raw.vers), "atp_ver": sorted({f.get("ver") for f in atp.files}), "stop": raw.stop,
           "n_err_atk": raw.n_err_atk, "atk_dead": list(ap.atk_dead)}
    # 所有新怪「打主角」的消息（判据 4/5 的扩大口径、只报告项用）：含没有 DANGER 条目的 em1、em17
    new_all = sorted({aa.species_of(m.get("em")) for m in raw.msg.values()} - set(DESIGN_SPECIES))
    objs = {o for o, m in raw.msg.items() if aa.species_of(m.get("em")) in new_all
            and not in_parry(atp.parry_on, m["t"], m["t"] + 12.0)}
    res["n_obj_all"] = len(objs)
    res["new_all"] = new_all

    # ---- 合并判据 1~3
    st = pooled_stats(paired)
    p1, p2, p3 = judge_pooled(st)
    res["pooled"] = st
    res["p1"], res["p2"], res["p3"] = p1, p2, p3
    # ---- 判据 4
    tm = crit_timer(raw, atp, objs)
    res["timer"] = tm
    dd = list(getattr(opts, "design_dirs", None) or [])
    res["design_hitch"] = design_hitch_check(dd) if dd else []
    # ---- 判据 5：主口径 = 7.1 的候选单位（不要求配上）；扩大口径 = 新怪所有打主角的 INIT
    cand = [u for u in units if u["status"] != "atk_dead" and u.get("ast") is not None and u.get("hs_init") is not None]
    res["c5_units_hook"] = crit_init([(u["C_hook"], u["hs_init"] - u["ast"]) for u in cand], "单位，INIT 快照 C")
    # 设计阶段（SPEED 2.1 b）用的是「消息时刻回推」的初值 hs_first + 60·(t_first − t_msg)，对照用
    res["c5_msg_backext"] = med([u["hs_init"] - u["ast"] + 60.0 * u["lag"] for u in cand])
    res["lag_med"] = med([u["lag"] for u in cand])
    res["c5_units_first"] = crit_init([(u["C1"], u["hs_init"] - u["ast"]) for u in cand], "单位，首帧 C")
    all_rows = []
    spd_cache = {}
    for r in atp.inits:
        if r.get("tme") != 1 or aa.species_of(r.get("em")) not in new_all:
            continue
        t = aa.num(r.get("t"))
        if t is None or in_parry(atp.parry_on, t, t + 12.0):
            continue
        hs, ast = aa.num(r.get("hs")), aa.num(r.get("ast"))
        comp = aa.parse_comp(r.get("scomp"), len(atp.spd_ix))
        sp_ = spd_cache.setdefault(r.get("em"), Speed.of(atp, r.get("em")))
        if hs is not None and ast is not None:
            all_rows.append((sp_.core(comp) if comp else None, hs - ast, r))
    res["c5_all_hook"] = crit_init([(c, d) for c, d, _ in all_rows], "所有新怪（含 em1、em17）打主角的 INIT，INIT 快照 C")
    res["c5_all_rows"] = [(c, d, aa.species_of(r.get("em")), r.get("act"), r.get("rt"), aa.num(r.get("sgl")))
                          for c, d, r in all_rows]
    # ---- 逐只怪
    per = {}
    for sp in new_sp:
        us = [u for u in paired if u["sp"] == sp]
        rs = [u["r"] for u in us]
        d = {"n": len(us), "med": med(rs), "iqr": iqr(rs), "q25": q(rs, 0.25), "q75": q(rs, 0.75),
             "n_act": len({u["act"] for u in us}),
             "tail": sum(1 for x in rs if x < LEFT_TAIL), "tail_raw": sum(1 for u in us if u["r_raw"] < LEFT_TAIL)}
        d["flag"] = bool(us) and (abs(d["med"]) > FLAG_MED or d["iqr"] > FLAG_IQR)
        d["med_ci_os"] = median_ci(rs)
        if us:
            def fl(s):
                rr = [u["r"] for u in s]
                return abs(med(rr)) > FLAG_MED or iqr(rr) > FLAG_IQR
            bm = cluster_boot(us, lambda s: med([u["r"] for u in s]), lambda u: u["act"], BOOT_N, BOOT_SEED)
            bi = cluster_boot(us, lambda s: iqr([u["r"] for u in s]), lambda u: u["act"], BOOT_N, BOOT_SEED + 1)
            bf = cluster_boot(us, fl, lambda u: u["act"], BOOT_N, BOOT_SEED + 2)
            d["med_ci"] = pint(bm)
            d["iqr_ci"] = pint(bi)
            d["flag_p"] = sum(1 for x in bf if x) / len(bf) if bf else None
            # 不分簇（把单位当独立）：偏乐观，作对照
            uid = {id(u): i for i, u in enumerate(us)}
            bm2 = cluster_boot(us, lambda s: med([u["r"] for u in s]), lambda u: uid[id(u)], BOOT_N, BOOT_SEED + 6)
            bi2 = cluster_boot(us, lambda s: iqr([u["r"] for u in s]), lambda u: uid[id(u)], BOOT_N, BOOT_SEED + 7)
            bf2 = cluster_boot(us, fl, lambda u: uid[id(u)], BOOT_N, BOOT_SEED + 8)
            d["med_ci_iid"] = pint(bm2)
            d["iqr_ci_iid"] = pint(bi2)
            d["flag_p_iid"] = sum(1 for x in bf2 if x) / len(bf2) if bf2 else None
            d["inds"] = {em: {"n": len(v), "med": med([u["r"] for u in v]), "iqr": iqr([u["r"] for u in v])}
                         for em, v in sorted(group_by(us, lambda u: u["em"]).items())}
        per[sp] = d
    res["per"] = per
    # ---- 合并判据的不确定性：按怪分层、按招整簇重抽
    key = lambda u: u["act"]  # noqa: E731
    strata = lambda u: u["sp"]  # noqa: E731
    bmed = cluster_boot(paired, lambda s: med([u["r"] for u in s]), key, BOOT_N, BOOT_SEED + 3, strata)
    biqr = cluster_boot(paired, lambda s: iqr([u["r"] for u in s]), key, BOOT_N, BOOT_SEED + 4, strata)

    def slope_stat(s):
        xs = [u["x"] for u in s]
        sdx = pop_sd(xs)
        if sdx is None or sdx < TH_SDX:
            return ("nojudge", sdx)
        return ("ok", theil(xs, [u["r0"] for u in s]))
    bsl = cluster_boot(paired, slope_stat, key, BOOT_SLOPE_N, BOOT_SEED + 5, strata)
    res["boot"] = {
        "med": pint(bmed), "med_pass": sum(1 for x in bmed if abs(x) <= TH_MED) / len(bmed) if bmed else None,
        "iqr": pint(biqr), "iqr_pass": sum(1 for x in biqr if x <= TH_IQR) / len(biqr) if biqr else None,
        "slope": pint([v for k, v in bsl if k == "ok" and v is not None]),
        "slope_pass": (sum(1 for k, v in bsl if k == "ok" and v is not None and TH_SLOPE[0] <= v <= TH_SLOPE[1])
                       / len(bsl)) if bsl else None,
        "slope_nojudge": sum(1 for k, _ in bsl if k == "nojudge"), "n_slope": len(bsl), "n": len(bmed),
        "n_clusters": {sp: len({u["act"] for u in paired if u["sp"] == sp}) for sp in new_sp}}
    # ---- E5 对 E1（存活期 C 变过的单位）
    chg = [u for u in paired if u.get("changed")]
    e5 = {"n": len(chg), "n_mchg": sum(1 for u in chg if u.get("m_changed")),
          "e5": med([abs(u["r"]) for u in chg]), "e1": med([abs(u["r_e1"]) for u in chg]),
          "e1c": med([abs(u["r_e1c"]) for u in chg]), "e5raw": med([abs(u["r_e5raw"]) for u in chg if u.get("r_e5raw") is not None]),
          "med_e5": med([u["r"] for u in chg]), "med_e1": med([u["r_e1"] for u in chg]),
          "med_e1c": med([u["r_e1c"] for u in chg])}
    e5["keep_e5c"] = None if not chg else (e5["e5"] <= e5["e1"])
    e5["keep_e5c_vs_e1c"] = None if not chg else (e5["e5"] <= e5["e1c"])
    mchg = [u for u in chg if u.get("m_changed")]
    e5["m_e5"] = med([abs(u["r"]) for u in mchg])
    e5["m_e1c"] = med([abs(u["r_e1c"]) for u in mchg])
    e5["m_e1"] = med([abs(u["r_e1"]) for u in mchg])
    res["e5"] = e5
    # ---- 敏感性：决策点（L=28 / 25 的触发帧）求值、em3 等 cids 怪种改用 reqset
    sens = {}
    for lv in (L_USER, L_ALT):
        us = [u for u in paired if u.get(f"dec{lv}")]
        tmp = [dict(u, r=u[f"dec{lv}"]["r"]) for u in us]
        s = pooled_stats(tmp)
        s["pass"] = judge_pooled(s)
        s["per"] = {sp: {"n": len([u for u in tmp if u["sp"] == sp]), "med": med([u["r"] for u in tmp if u["sp"] == sp]),
                         "iqr": iqr([u["r"] for u in tmp if u["sp"] == sp])} for sp in new_sp}
        sens[f"dec{lv}"] = s
    alt = []
    for u in units:
        if u["rule"] == "cids":
            if u.get("alt_paired") and "alt_r" in u:
                alt.append(dict(u, r=u["alt_r"], r0=u["alt_r0"], x=u["alt_x"], status="paired"))
            elif u.get("alt_paired") and u["status"] == "paired":
                alt.append(u)
        elif u["status"] == "paired":
            alt.append(u)
    s = pooled_stats(alt)
    s["pass"] = judge_pooled(s)
    s["per"] = {sp: {"n": len([u for u in alt if u["sp"] == sp]), "med": med([u["r"] for u in alt if u["sp"] == sp]),
                     "iqr": iqr([u["r"] for u in alt if u["sp"] == sp])} for sp in new_sp}
    sens["reqset_all"] = s

    def sub(name, us):
        s = pooled_stats(us)
        s["pass"] = judge_pooled(s)
        s["per"] = {sp: {"n": len([u for u in us if u["sp"] == sp]), "med": med([u["r"] for u in us if u["sp"] == sp]),
                         "iqr": iqr([u["r"] for u in us if u["sp"] == sp]),
                         "flag": bool([u for u in us if u["sp"] == sp]) and (
                             abs(med([u["r"] for u in us if u["sp"] == sp])) > FLAG_MED
                             or iqr([u["r"] for u in us if u["sp"] == sp]) > FLAG_IQR)} for sp in new_sp}
        sens[name] = s
    # 激活前最后一个真实 SER 点离激活 ≤ 0.1 s 的（SER 断在激活前很久的单位不进）
    sub("ser_gap", [u for u in paired if u["ser_gap"] <= SER_GAP_WARN])
    # 去掉 a5 标签和 reqset 对不上的多段招（em31 (0,49)，见报告 2.3）
    sub("no_em31_049", [u for u in paired if not (u["sp"] == "em31" and u["act"] == "(0,49)")])
    # 判据 3：两两斜率不设 |Δx| 下限
    sl_all = theil([u["x"] for u in paired], [u["r0"] for u in paired], min_dx=0.0)
    sens["slope_all_pairs"] = sl_all
    # 只用激活前最后一个点就是「全程积分」；E1（首帧 C）当 T̂ 时的合并判据（参考）
    sub("e1", [dict(u, r=u["r_e1"]) for u in paired])
    res["sens"] = sens
    report_only(res, paired, units, atp, raw, new_sp, objs)
    conclude(res)
    return res


def report_only(res, paired, units, atp, raw, new_sp, objs):
    ro = {}
    # 左尾、g、放早率
    rows = {}
    for sp in new_sp + ["合计"]:
        us = [u for u in paired if (u["sp"] == sp or sp == "合计")]
        gs = [u["g"] for u in us if u.get("g") is not None]
        d = {"n": len(us), "tail": sum(1 for u in us if u["r"] < LEFT_TAIL),
             "tail_raw": sum(1 for u in us if u["r_raw"] < LEFT_TAIL), "n_g": len(gs), "g_med": med(gs),
             "g_q10": q(gs, 0.1), "g_q90": q(gs, 0.9), "g_min": min(gs) if gs else None, "g_neg": sum(1 for g in gs if g < 0)}
        for lv in (L_ALT, L_USER):
            thr = W0 - (lv - D_BAR) / 60.0
            withg = [u for u in us if u.get("g") is not None and u.get(f"dec{lv}")]
            trig = [u for u in withg if u[f"dec{lv}"]["trig"]]
            d[f"early{lv}"] = sum(1 for u in trig if u[f"dec{lv}"]["r_raw"] + u["g"] < thr)
            d[f"early{lv}_n"] = len(trig)
            d[f"early{lv}_direct"] = sum(1 for u in trig if u["t_ct"] - u[f"dec{lv}"]["t"] < W0)
            allu = [u for u in us if u.get(f"dec{lv}") and u[f"dec{lv}"]["trig"]]
            d[f"g0_{lv}"] = sum(1 for u in allu if u[f"dec{lv}"]["r_raw"] < thr)
            d[f"g0_{lv}_n"] = len(allu)
            d[f"notrig{lv}"] = sum(1 for u in us if not (u.get(f"dec{lv}") and u[f"dec{lv}"]["trig"]))
        rows[sp] = d
    ro["tail_g"] = rows
    # 物理激活去重：同一只怪、同一次 ATK
    phys = defaultdict(list)
    for u in paired:
        phys[(u["em"], round(u["t_atk"], 4))].append(u)
    lead, joint, joint28, dedup = [], [], [], []
    for (em, t), us in phys.items():
        us.sort(key=lambda u: u["t1"])
        t_first_reg = us[0]["t1"]
        for u in us:
            if u["t1"] > t_first_reg + 0.05 and u["obj"] != us[0]["obj"]:
                lead.append({"sp": u["sp"], "act": u["act"], "lead": t - u["t1"], "first_act": us[0]["act"], "r": u["r"],
                             "first_r": us[0]["r"]})
        joint.append({"sp": us[0]["sp"], "r": t - min(u["t_atk"] - u["r"] - B_FROZEN for u in us) - B_FROZEN,
                      "n": len(us)})
        trig = [u for u in us if u.get(f"dec{L_USER}")]
        if trig:
            f = min(trig, key=lambda u: u[f"dec{L_USER}"]["t"])
            joint28.append({"sp": f["sp"], "r": f[f"dec{L_USER}"]["r"]})
        dedup.append(min(us, key=lambda u: u["A"]))
    ro["phys_n"] = len(phys)
    ro["phys_multi"] = sum(1 for v in phys.values() if len(v) > 1)
    # SER 断在激活前很久的单位：断的时候 Q 还剩多少、是不是正好有后继结果登记
    gap = []
    for u in paired:
        if u["ser_gap"] <= SER_GAP_WARN:
            continue
        tr = u.get("track") or []
        q_last = tr[u["k"]][4] if tr and u["k"] < len(tr) else None
        succ = [v for v in phys[(u["em"], round(u["t_atk"], 4))] if v["t1"] > u["t1"] + 0.05]
        s0 = min(succ, key=lambda v: v["t1"]) if succ else None
        gap.append({"sp": u["sp"], "act": u["act"], "rq": u["rq"], "r": u["r"], "gap": u["ser_gap"], "q_last": q_last,
                    "succ_act": s0["act"] if s0 else None, "succ_r": s0["r"] if s0 else None,
                    "succ_msg_minus_end": (s0["t_msg"] - u["ser_end"]) if s0 else None})
    ro["gap_units"] = gap
    # 左尾按招、右尾最大的几个
    ro["tail_moves"] = [{"sp": sp, "act": act, "n": len(v), "n_act": sum(1 for u in paired if u["sp"] == sp and u["act"] == act),
                         "r_min": min(u["r"] for u in v), "r_max": max(u["r"] for u in v)}
                        for (sp, act), v in sorted(group_by([u for u in paired if u["r"] < LEFT_TAIL],
                                                            lambda u: (u["sp"], u["act"])).items(), key=lambda x: -len(x[1]))]
    ro["right_top"] = {sp: [(u["act"], u["rq"], u["r"], u["A"]) for u in sorted([u for u in paired if u["sp"] == sp],
                                                                                  key=lambda u: -u["r"])[:3]] for sp in new_sp}
    ro["lead"] = lead
    ro["joint"] = joint
    ro["joint28"] = joint28
    ro["dedup"] = [{"sp": u["sp"], "r": u["r"], "r_raw": u["r_raw"]} for u in dedup]
    # C 的范围
    c1s = [u["C1"] for u in paired]
    cmins = [u["C_min"] for u in paired if u.get("C_min") is not None]
    cmaxs = [u["C_max"] for u in paired if u.get("C_max") is not None]
    ro["C"] = {"c1_min": min(c1s) if c1s else None, "c1_max": max(c1s) if c1s else None,
               "life_min": min(cmins) if cmins else None, "life_max": max(cmaxs) if cmaxs else None,
               "values": Counter(round(c, 3) for c in c1s),
               "per": {sp: sorted(Counter(round(u["C1"], 3) for u in paired if u["sp"] == sp).items()) for sp in new_sp},
               "outside": sum(1 for u in paired if not (0.92 <= u["C1"] <= 1.27)),
               "chg": sum(1 for u in paired if u.get("changed"))}
    # 各分量
    names = list(atp.spd_ix)
    comp_tab = {}
    for name in names:
        dev = [u for u in paired if u["comps"].get(name, {}).get("dev")]
        vals = [u["comps"][name] for u in paired if name in u["comps"]]
        xs, ys = [], []
        for u in paired:
            c = u["comps"].get(name)
            if c is None or c["mean"] <= 0:
                continue
            xs.append(-u["A"] * (1.0 - 1.0 / c["mean"]) / 60.0)
            ys.append(u["r"])
        sdx = pop_sd(xs)
        dev_x = [x for x in xs if abs(x) > 1e-9]
        comp_tab[name] = {"n_dev": len(dev), "n": len(vals), "min": min((v["min"] for v in vals), default=None),
                          "max": max((v["max"] for v in vals), default=None),
                          "by_sp": dict(Counter(u["sp"] for u in dev)), "sdx": sdx, "n_x": len(dev_x),
                          "slope": theil(xs, ys) if (sdx is not None and sdx > 0 and len(dev_x) >= 3) else None,
                          "slope_judgeable": sdx is not None and sdx >= TH_SDX,
                          "acts": Counter((u["sp"], u["act"]) for u in dev).most_common(6)}
    ro["comps"] = comp_tab
    # 倒数期间各分量（扩大口径：新怪所有打主角的条目，从首个 SER 到最后一个 SER，不要求配上）
    life = defaultdict(lambda: {"ents": 0, "dev": 0, "time": 0.0, "dev_time": 0.0, "min": None, "max": None})
    sp_cache = {}
    for (obj, e), xs in raw.ser.items():
        if obj not in objs:
            continue
        em = raw.msg[obj]["em"]
        s_ = sp_cache.setdefault(em, Speed.of(atp, em))
        ta, tb = xs[0][0], xs[-1][0]
        if tb <= ta:
            continue
        pcs = s_.pieces(ta, tb)
        for name, ix in atp.spd_ix.items():
            d = life[name]
            d["ents"] += 1
            anyd = False
            for a, b, c in pcs:
                if c is None:
                    continue
                v = c[ix]
                d["time"] += b - a
                d["min"] = v if d["min"] is None else min(d["min"], v)
                d["max"] = v if d["max"] is None else max(d["max"], v)
                if abs(v - 1.0) > COMP_DEV:
                    d["dev_time"] += b - a
                    anyd = True
            d["dev"] += 1 if anyd else 0
    ro["life"] = dict(life)
    # 钩子时刻（INIT 快照）vs 首帧
    hk = [u for u in units if u.get("C_hook") is not None and u.get("C1") is not None]
    dis = [u for u in hk if abs(u["C_hook"] - u["C1"]) > C_SAME]
    ro["hook"] = {"n": len(hk), "same": len(hk) - len(dis),
                  "by_act": Counter((u["sp"], u["act"], round(u["C_hook"], 3), round(u["C1"], 3)) for u in dis).most_common(),
                  "paired_n": sum(1 for u in hk if u["status"] == "paired"),
                  "paired_dis": sum(1 for u in dis if u["status"] == "paired")}
    # 钩子时刻的值若被用来放刀：这些单位的残差（只报告，v1.6 不在钩子里读）
    hook_r = []
    for u in dis:
        if u["status"] != "paired":
            continue
        ch = u["C_hook"]
        hook_r.append(u["t_atk"] - (u["t1"] + u["A"] / (60.0 * max(1.0, ch))) - B_FROZEN)
    ro["hook_r"] = hook_r
    # UNABLE_GUARD、C < 1、EMHIT
    ug = [u for u in units if str(u.get("guard")) == "UNABLE_GUARD"]
    ugp = [u for u in ug if u["status"] == "paired"]
    same = sum(1 for u in ugp if any(v is not u and v["obj"] == u["obj"] and str(v.get("guard")) != "UNABLE_GUARD"
                                     and abs(v["t_atk"] - u["t_atk"]) < 1e-6 for v in paired))
    ro["unable"] = {"n": len(ug), "paired": ugp, "same_as_normal": same,
                    "by": Counter((u["sp"], u["act"], u["status"]) for u in ug).most_common(),
                    "dmg": Counter(str(u.get("dmg")) for u in ug)}
    sc = [u for u in paired if u["comps"].get("_Scale", {}).get("dev")]
    xs_sc = [-u["A"] * (1.0 - 1.0 / u["comps"]["_Scale"]["mean"]) / 60.0 for u in sc]
    ro["scale_units"] = {"n": len(sc), "med": med([u["r"] for u in sc]),
                         "absmax": max((abs(u["r"]) for u in sc), default=None),
                         "mean_rng": (min((u["comps"]["_Scale"]["mean"] for u in sc), default=None),
                                      max((u["comps"]["_Scale"]["mean"] for u in sc), default=None)),
                         "x_absmax": max((abs(x) for x in xs_sc), default=None),
                         "big": sorted({(u["act"], round(u["r"], 3)) for u in sc if abs(u["r"]) > 0.10}, key=lambda z: -z[1])}
    lt1 = [u for u in paired if (u["C1"] < 1.0 - C_SAME) or (u.get("C_min") is not None and u["C_min"] < 1.0 - C_SAME)]
    ro["lt1"] = lt1
    eh = [u for u in paired if u.get("emhit")]
    ro["emhit"] = {"with": eh, "without_n": len(paired) - len(eh),
                   "without_med": med([u["r"] for u in paired if not u.get("emhit")]),
                   "without_iqr": iqr([u["r"] for u in paired if not u.get("emhit")])}
    # V16 9.1 补充（ENT）：DANGER 条目（候选单位）的 GuardType / pbreak / DamageType
    ent_tab = {}
    for sp in new_sp:
        us = [u for u in units if u["sp"] == sp]
        ent_tab[sp] = {"guard": Counter(str(u.get("guard")) for u in us), "pbreak": Counter(str(u.get("pbreak")) for u in us),
                       "dmg": Counter(str(u.get("dmg")) for u in us)}
    sg = [u for u in units if str(u.get("guard")).startswith("SKILL_GUARD")]
    ro["ent"] = ent_tab
    ro["skill_guard"] = Counter((u["sp"], u["act"], str(u.get("guard")), str(u.get("dmg"))) for u in sg).most_common()
    # 接触层：没配上的招（配上的作对照）
    cl = {}
    for sp in new_sp:
        for st in ("paired", "unpaired"):
            us = [u for u in units if u["sp"] == sp and (u["status"] == "paired") == (st == "paired")
                  and u["status"] in ("paired", "unpaired_none", "unpaired_early")]
            w = [u for u in us if u.get("cl")]
            mine = [u for u in w if u["cl"]["mine"]]
            e28 = [u for u in mine if u["cl"].get(f"early{L_USER}") is not None]
            e25 = [u for u in mine if u["cl"].get(f"early{L_ALT}") is not None]
            cl[(sp, st)] = {"n": len(us), "n_ct": len(w), "n_mine": len(mine),
                            "r_ct_med": med([u["cl"]["r_ct"] for u in mine]),
                            "r_ct_min": min((u["cl"]["r_ct"] for u in mine), default=None),
                            "early28": sum(1 for u in e28 if u["cl"][f"early{L_USER}"]), "n28": len(e28),
                            "early25": sum(1 for u in e25 if u["cl"][f"early{L_ALT}"]), "n25": len(e25),
                            "early28_other": sum(1 for u in w if not u["cl"]["mine"] and u["cl"].get(f"early{L_USER}"))}
    ro["contact"] = cl
    res["ro"] = ro


def conclude(res):
    """7.1「结论怎么下」。判据 4 按最保守的读法（设计阶段的 os.clock 逐对测法）定通过与否；按计时器自己的时钟
    （引擎 DeltaTime）测的结果另记，只用来说明，不改判定。"""
    per = res["per"]
    flagged = [sp for sp, d in per.items() if d.get("flag")]
    tm = res["timer"]
    c4 = tm["jump_ok_literal"] and tm["rate_ok"]
    c4_engine = tm["lag_big"] == 0 and tm["rate_ok"]
    c5 = res["c5_units_hook"]["pass"] and res["c5_units_first"]["pass"] and res["c5_all_hook"]["pass"]
    res["p4"], res["p4_engine"], res["p5"] = c4, c4_engine, c5
    c123 = bool(res["p1"]) and bool(res["p2"]) and bool(res["p3"])
    res["flagged"] = flagged
    # 系统性失败的迹象（7.1 举的例子）：CoreState 以外某个分量 ≠ 1、x 能判（sd ≥ 0.03）且斜率「约为 1」（0.5~1.5）
    sysc = []
    for name, c in res["ro"]["comps"].items():
        if name == "_CoreState":
            continue
        if c["n_dev"] >= 3 and c["slope"] is not None and c["slope_judgeable"] and 0.5 <= c["slope"] <= 1.5:
            sysc.append(name)
    res["sys_components"] = sysc
    res["all5"] = c123 and c4 and c5
    if res["all5"] and not flagged:
        v = "pass"
    elif sysc or not c123 or not c5 or (not c4 and not c4_engine):
        v = "systematic_fail"
    elif flagged:
        v = "left_tail_only"      # 合并判据都过、只有个别怪被标：要逐只诊断（报告第 4 节），这里先归「个别」
    else:
        v = "inconclusive"        # 只差判据 4 的字面测法：3 种结论都不对应，交用户裁定
    res["verdict_auto"] = v


# ================================================================ 报告
SP_NAME = {"em2": "护火龙", "em3": "铠龙", "em31": "暗器蛸", "em15": "护凶爪龙", "em14": "护雷颚龙"}
STATUS_TXT = {"paired": "配上", "unpaired_none": "窗里没有满足条件的 ATK", "unpaired_early": "第一次满足条件的 ATK 在窗前",
              "atk_dead": "窗口里 ATK 钩子停了 / 记录结束（剔除）", "no_C": "读不到 C（剔除）"}
VERDICT_TXT = {"pass": "机制通过", "systematic_fail": "系统性失败（需要修订机制）", "left_tail_only": "只是个别招的左尾",
               "inconclusive": "按字面不能下「机制通过」，交用户裁定一处口径（判据 4）"}


def yn(x):
    return "-" if x is None else ("**过**" if x else "**不过**")


def sp_label(sp):
    return f"{sp}（{SP_NAME[sp]}）" if sp in SP_NAME else sp


def p_txt(p):
    return "-" if p is None else f"{100.0 * p:.1f}%"


def share_txt(a, b):
    if not b:
        return "-"
    x = 100.0 * a / b
    return f"{x:.2f}%" if 0 < x < 1 else f"{x:.1f}%"


def rng(vals, nd=3, signed=True):
    vals = [v for v in vals if v is not None]
    if not vals:
        return "-"
    f = sfmt if signed else fmt
    return f"{f(min(vals), nd)}~{f(max(vals), nd)}"


class Rep(aa.Report):
    """每段后面空一行：Markdown 里连续的行会并成一段，「数据」「推测」要分开。"""

    def p(self, text=""):
        self.lines.append(text)
        if text:
            self.lines.append("")


def render(res, data_dir):
    R = Rep()

    def T(header, rows):          # 表格前留空行，否则 Markdown 不把它当表格
        R.p()
        R.table(header, rows)

    U = res["units"]
    P = [u for u in U if u["status"] == "paired"]
    sps = [sp for sp in res["species"] if res["cnt"].get(sp, {}).get("cand")]
    per, ro, tm, st, bt, e5, sens, v3 = (res["per"], res["ro"], res["timer"], res["pooled"], res["boot"], res["e5"],
                                         res["sens"], res["verdict_c3"])
    n_hitch_ev = sum(1 for e in tm["events"] if e["hitch"])
    c5_all = [b["med"] for k in ("c5_units_hook", "c5_units_first", "c5_all_hook") for b in res[k]["bins"] if b["judged"]]
    dh = [x for x in res.get("design_hitch", []) if not x["dir"].startswith("stageA")]
    dh_hitch = sum(x["n_hitch_le100"] for x in dh)
    dh_dense = sum(x["hitch_on_dense"] for x in dh)
    dh_pairs = sum(x["pairs"] for x in dh)
    dh_big = sum(x["big"] for x in dh)
    gap = ro["gap_units"]
    g57 = [g for g in gap if g["sp"] == "em3" and g["act"] == "(0,57)" and g["succ_act"]]
    u57 = [u for u in P if u["sp"] == "em3" and u["act"] == "(0,57)"]
    lead = ro["lead"]
    l58 = [x for x in lead if x["sp"] == "em3" and x["act"] == "(0,58)"]

    def r_span(t):
        return sfmt(t["r_min"], 2) if abs(t["r_min"] - t["r_max"]) < 5e-4 else f"{sfmt(t['r_min'], 2)}~{sfmt(t['r_max'], 2)}"
    tail_txt = "；".join(f"{t['sp']} {t['act']} {t['n']}/{t['n_act']} 个（r {r_span(t)}）" for t in ro["tail_moves"])

    R.h("A 阶段正式判定（SPEED.md 7.1）：ATP session %s" % res["atp_session"], 1)
    R.p(f"{VERSION}；`python tools/stage_a_judge.py {data_dir} --out tools/out/stageA_report.md`。数据：ATP "
        f"{', '.join(map(str, res['atp_ver']))} + APCal {', '.join(res['apcal_vers'])}（session {res['apcal_sessions'][0] if res['apcal_sessions'] else '-'}）"
        " + AutoParryGS。标「**数据**」的是本批数据直接算出来的，标「**推测**」的是解释。判据、门槛照 SPEED.md 7.1 原文；"
        "原文没写清的地方选最保守的做法，第 1.2 节逐条写明。")

    # ------------------------------------------------------------ 0 结论
    R.h("0. 结论")
    v = res["verdict_auto"]
    R.p(f"**最终结论（按 7.1「结论怎么下」）：{VERDICT_TXT[v]}。**")
    rows = [
        ["1", "r 的中位", f"|·| ≤ {TH_MED} s", sfmt(st["med"]), yn(res["p1"]),
         f"{ci_txt(bt['med'])}；{p_txt(bt['med_pass'])}"],
        ["2", "r 的 IQR", f"≤ {TH_IQR:.2f} s", fmt(st["iqr"]), yn(res["p2"]),
         f"{ci_txt(bt['iqr'], signed=False)}；{p_txt(bt['iqr_pass'])}"],
        ["3", "E0 残差对 −A(1−1/C)/60 的 Theil–Sen 斜率", f"{TH_SLOPE[0]}~{TH_SLOPE[1]}（sd(x) ≥ {TH_SDX} s 才判）",
         f"{fmt(st['slope'], 3)}（sd(x) {fmt(st['sdx'], 3)} s）", yn(res["p3"]),
         f"{ci_txt(bt['slope'], signed=False)}；{p_txt(bt['slope_pass'])}"],
        ["4", "计时器", "没有 > 2 帧的跳变（单帧 > 0.133 s 的钳制除外）；速率 1.000 ± 0.005",
         f"跳变 {tm['n_big']} 对（{n_hitch_ev} 次卡顿）；速率中位 {fmt(tm['rate_med'], 5)}",
         yn(res["p4"]) + "（字面）", f"按引擎 DeltaTime 比：{tm['lag_big']} 对 > 2 帧（{tm['lag_n']} 对里最大 {fmt(tm['lag_absmax'], 3)} 帧）"],
        ["5", "初值是名义帧：hs − AttackStartFrame 按 C 分档", "各档中位 |·| ≤ 2 帧（每档 ≥ 5 个）",
         f"三种口径共 {len(c5_all)} 档，中位 {rng(c5_all, 2)} 帧", yn(res["p5"]), "-"],
    ]
    T(["#", "判据（合并所有新怪）", "门槛", f"本批（{st['n']} 个单位）", "通过", "按怪分层、按招整簇重抽的 95% 区间；重抽下通过的比例"], rows)
    fl = res["flagged"]
    R.p(f"- 逐只怪「系统性失败嫌疑」（|中位| > {FLAG_MED} s 或 IQR > {FLAG_IQR} s）：" + ("**没有一只被标**" if not fl else
        "**被标：" + "、".join(fl) + "**") + "（第 4 节）。")
    R.p(f"- 预注册的 E5 判定：存活期 C 变过的单位 **{e5['n']} 个**，没有可比的样本；改用 E1 的条件不成立 → **保持 E5c**（第 5 节）。")
    R.p("- 系统性失败的迹象（7.1 的例子：某个分量 ≠ 1 且残差对它的斜率约为 1）：" + (
        "**没有**" if not res["sys_components"] else "**有：" + "、".join(res["sys_components"]) + "**") + "（第 6.3 节）。")
    R.p()
    R.p("**怎么得出这个结论**：")
    R.p(f"1. **数据**：判据 1、2、3、5 都过，按招整簇重抽下也几乎总是过（{p_txt(bt['med_pass'])} / {p_txt(bt['iqr_pass'])} / "
        f"{p_txt(bt['slope_pass'])}；判据 5 各档离门槛 1 帧以上）。5 只新怪没有一只被标。CoreState 以外只有 Sequence 和 Scale "
        "在倒数期间 ≠ 1：残差对 Sequence 的斜率约为 0（招式因子已在名义帧里，和 atp_analyze C7 一致），Scale 的修正量太小判不了；"
        "其余 9 个分量恒为 1。")
    R.p(f"2. **数据**：判据 4 的速率过（{fmt(tm['rate_med'], 5)}）。「跳变」按设计阶段的测法（SPEED 2.1 d：同一条目的相邻 SER 对、"
        f"os.clock 计时）数出 **{tm['n_big']} 对 > 2 帧**，全部来自 **{n_hitch_ev} 次 50~70 ms 的卡顿帧**："
        f"卡顿那一对 hs 只扣了上一帧的量（d = {rng([e['d'] for e in tm['events'] if e['d'] > 0], 1)} 帧），之后 1~2 对把差补回来"
        f"（d = {rng([e['d'] for e in tm['events'] if e['d'] < 0], 1)} 帧），前后 5 对合计最多 {fmt(tm['net5_max'], 2)} 帧。"
        f"按计时器自己扣的量（引擎 DeltaTime；atp_analyze C2 实测 hs 每帧扣的是前一帧开头读到的 DeltaTime）比，{tm['lag_n']} 对里最大偏差 "
        f"{fmt(tm['lag_absmax'], 3)} 帧。")
    R.p("3. **推测**：这几对是 APCal 记 SER 的 os.clock 和引擎记帧时长在卡顿帧上错开 1~2 帧的测量伪影，计时器本身没有跳变。"
        f"旁证（**数据**）：设计阶段 4 段数据（{dh_pairs} 个相邻对，|d| > 2 的 {dh_big} 对）里有 {dh_hitch} 次 45~100 ms 的卡顿，"
        f"落在逐帧 SER 相邻对上的 {dh_dense} 次 —— 7.1 表里「0 次」的标定从来没碰到过这种情况（第 3.1 节）。")
    R.p("4. 7.1 原文只写「没有超过 2 帧的跳变（单帧 > 0.133 s 的钳制除外）」，没写拿什么时钟比。按任务要求选最保守的读法："
        "沿用设计阶段的 os.clock 逐对测法、不因「之后抵消」豁免 → 判据 4 **字面不过** → 「1~5 全过」不成立，不能下「机制通过」。"
        "又没有系统性失败的迹象（判据 1~3、5 都过，没有分量 ≠ 1 且斜率约为 1，计时器对引擎时钟没有偏差），也不是左尾问题 → "
        "7.1 的三种结论都对不上，只能交给用户。")
    R.p(f"5. **要用户拍板的只有一件事**：判据 4 的这 {tm['n_big']} 对算不算「跳变」。")
    R.p("   - 认定为测量伪影（我的建议，理由见第 3.1 节）→ 1~5 全过、没有怪被标 → **机制通过**，A 的 5 只怪可以直接用于 B。"
        "同时把判据 4 的测法写清（「按引擎 DeltaTime 比」或「前后 5 对合计」），并注明这是看过 A 数据之后的口径澄清。")
    R.p("   - 坚持字面 → A 不通过。数据里没有指向机制本身的问题，要改的只是计时器判据的测法；按 SPEED.md 第 7 节的原则这算新迭代，"
        "这批怪变成设计数据，B 要另找 4 只。")
    R.p(f"6. **个别招的左尾（只报告，不改规则）**：{tail_txt or '无'}。em3 (0,57) 的 {len(u57)} 个单位残差 "
        f"{rng([u['r'] for u in u57], 2)} s，两个方向都有：它的 SER 在激活前 {rng([g['gap'] for g in g57], 2, False)} s 就断了，"
        f"同一次激活由后继 (0,58) 重新登记（登记提前量 {rng([x['lead'] for x in l58], 2, False)} s，"
        f"(0,58) 自己的残差 {rng([x['r'] for x in l58], 3)} s）；(0,57) 断的时候 Q 还剩 "
        f"{rng([g['q_last'] for g in g57], 0, False)} 帧，L = 28 不会在它上面放刀（第 6.2 节）。em31 (0,49)：a5 和条目 reqset 的对应"
        "在不同几次里不一样，按 a5 = reqset 配错了段，按时间顺序对误差 ≤ 0.02 s（第 2.4 节）。em15 的两个是孤立的单个单位。")
    c3n = res["cnt"].get("em3", {})
    R.p(f"7. **样本量**：每只怪 60 个单位的目标只有 em2 达到（{per.get('em2', {}).get('n')} 个）；em3 配对率 "
        f"{pct(c3n.get('paired', 0), c3n.get('cand', 0))} 低于 60%。合并判据受影响小（{st['n']} 个单位，标定用的是 240 个），"
        f"但逐只怪的中位、IQR 区间很宽：「没有被标」对 em3（{per.get('em3', {}).get('n')} 个、{per.get('em3', {}).get('n_act')} 招）只是弱证据，"
        f"按招整簇重抽时它被标的概率 {p_txt(per.get('em3', {}).get('flag_p'))}（第 7 节）。")

    # ------------------------------------------------------------ 1 数据与口径
    R.h("1. 数据与口径")
    R.h("1.1 数据", 3)
    on = res["parry_on"]
    R.p(f"- ATP session {res['atp_session']}、APCal session {', '.join(map(str, res['apcal_sessions']))}；两边都在 os.clock "
        f"{fmt(res['stop'], 1) if res['stop'] else '-'} 自停（加载后 90 分钟，`STOP why=auto90`），之后没有记录。")
    R.p("- 放刀模块开着的时段（AutoParryGS HDR/CFG）：" + "，".join(
        f"{fmt(a, 3)}~{fmt(b, 3) if b != math.inf else '结束'}" for a, b in on)
        + f"；这段只有 em19、em18，和其他设计阶段怪种（{'、'.join(DESIGN_SPECIES)}）一起按怪种剔除"
        f"（{res['excl'].get('design_species', 0)} 个打主角的结果对象）；新怪的消息都在放刀关掉之后（另按时段剔除 {res['excl'].get('parry_on', 0)} 个）。")
    R.p(f"- APCal 的 ATK 频率守卫：`ERR mod=ATK` {res['n_err_atk']} 条，整段没停过；配对窗超出记录结束的单位按「ATK 停了」剔除。")
    rows = []
    for sp in res["species"]:
        c = res["cnt"].get(sp, {})
        inds = sorted({u["em"] for u in U if u["sp"] == sp})
        rows.append([sp_label(sp), "、".join(inds) or "-", c.get("danger_obj", 0), c.get("cand", 0)])
    T(["新怪", "个体（em#SystemIndex）", "有 DANGER 条目的打主角结果对象", "候选单位"], rows)
    R.p("em1、em17 在放刀关掉之后有打主角的消息，但没有 DANGER 条目，没有单位。")

    R.h("1.2 口径：逐条对应 7.1，原文没写清处的选择", 3)
    rows = [
        ["单位：每个结果对象、每个 reqset 的最早条目", "APCal MSG（tme=1）的对象 × ENT 的 reqset；最早 = 首个 SER 的 hs 最小（同 phaseA_check 的「首见 hs 最小」）；A = 首个 SER 的 hs",
         "7.1 没说 DANGER；按附录 B「激活单位：DANGER」和设计阶段标定（phaseA_check）只取有 DANGER 样本的条目"],
        ["剔除弹体条目", "ENT.shell 或 INIT.shell 任一不是 none 就剔除", "两边不一致时取剔除（保守）"],
        ["a5 ∈ CollidableIDList，按 6.1 的零假设对照决定能不能用，不能用就退回 a5 = reqset",
         "直接用 atp_analyze 1.2 C3 的判定（import 同一段代码，门槛：平移命中 ≤ 0.25、真实高出 ≥ 0.40、≥ 5 段）",
         "6.1 写「退回时间窗」，7.1 写「退回 a5 = reqset」；判定以 7.1 为准"],
        ["同一只怪、消息之后的第一次激活，落在 [0.5·A/60 − 0.1, 1.6·A/60 + 0.3] 内",
         "同一个 em#编号；消息之后第一次 a5 满足条件的 ATK；el = t_ATK − t1（t1 = 首个 SER）在窗外就算没配上，不再往后找",
         "字面读法：phaseA_check 允许激活比消息早 0.02 s，这里不允许（只影响 em2 (0,146) 的 6 个，见 2.3）"],
        ["剔除 ATK 守卫关掉的时段", "`ERR mod=ATK` 0 条；配对窗超出记录结束的剔除", "-"],
        ["T̂_E5c 用 EMF / EMSPD 的逐帧 CoreState（m = max(1, C)）积分",
         "v1.6 E5c 原样重放：登记后第一个帧回调起 X += Δhs·(m − 1)，hs 自己当时钟（SER 稀疏时按 EMSPD 变化点切段）；"
         "C = EMSPD 重建的逐帧 _CoreState；只在 SER 上真实存在的点求值",
         "7.1 没指定求值点。主口径 = 激活前最后一个真实 SER 点（全程积分，即机制检验）；本批单位存活期内 C 从没变过，"
         f"任何求值点的 T̂ 都一样，差别只在单位取舍：在 L=28 的触发帧求值要去掉 {st['n'] - sens[f'dec{L_USER}']['n']} 个 Q 从没降到 28 的单位，判定不变（第 8 节）"],
        ["判据 3", "x 用首帧 C 原值（不按 1 截）；两两斜率只取 |Δx| > 0.01", "同 phaseA_check / v9_calib；不设下限的结果见第 8 节"],
        ["判据 4「跳变」", "设计阶段测法：同一 (对象, 条目) 相邻 SER 对、0 < Δt ≤ 0.1 s，d = Δhs + 60·Δt（os.clock）；"
         "「钳制」= 这一对里有 dt > 0.133 s 的 HITCH/GAP；范围 = 所有新怪（含没有 DANGER 的 em1、em17）打主角的结果对象，不只单位",
         "**最保守**：逐对计数，不因下一两帧抵消而豁免；按引擎 DeltaTime 比的结果只作说明，不进判定"],
        ["判据 5「按 C 分档」", "C 取 3 位小数分档；C 分别用 INIT 快照（钩子时刻）和首帧；另用所有新怪（含 em1、em17）打主角的 INIT 再判一次",
         "三种都过才算过（保守）"],
        ["逐只怪", "按怪种（em 编号）合并个体，同设计阶段", "-"],
        ["E5 判定的「存活期 C 变过」", "登记后第一个帧回调 → 激活之间，原值 CoreState 变过（> 0.0005）；E1 = 首帧 C 原值", "另报 E1 用 max(1, C1) 的对照"],
        ["左尾（只报告）", "r < −0.10 s（r 含 −b，同 phaseA_check）", "另报 r_raw（不减 b）< −0.10 的个数（SPEED 2.4 的口径）"],
        ["「招」（重抽的簇、没配上的招）", "消息时的动作（MSG 的 keep）", "-"],
    ]
    T(["7.1 原文", "本脚本的做法", "原文没写清处的选择 / 理由"], rows)

    # ------------------------------------------------------------ 2 单位与配对
    R.h("2. 单位与配对")
    R.h("2.1 a5 口径：atp_analyze C3 的零假设对照（6.1）", 3)
    rows = []
    for sp in res["species"]:
        d = v3.get(sp)
        if not d:
            continue
        rows.append([sp_label(sp), d["n_c"], fmt(d.get("real_c"), 2), fmt(d.get("p_c"), 2),
                     "过" if d["verdict"] == "cids" else "不过",
                     "a5 ∈ cids" if d["verdict"] == "cids" else "a5 = reqset（7.1）"])
    T(["怪", "有 cids 的段", "带里 a5 ∈ cids", "平移后 a5 ∈ cids", "对照", "本判定用的配对"], rows)

    R.h("2.2 每只新怪的单位数、配对率", 3)
    rows = []
    for sp in sps:
        c = res["cnt"][sp]
        n_c = c.get("cand", 0)
        n_p = c.get("paired", 0)
        dead = c.get("atk_dead", 0) + c.get("no_C", 0)
        rate = n_p / (n_c - dead) if n_c - dead > 0 else None
        rows.append([sp_label(sp), c.get("danger_obj", 0), c.get("shell_ent", 0), n_c, dead, n_p,
                     f"{100 * rate:.0f}%" if rate is not None else "-",
                     "是" if n_p >= UNIT_MIN else "**否**", "是" if (rate or 0) >= PAIR_MIN else "**否**",
                     f"{c.get('unpaired_none', 0)} / {c.get('unpaired_early', 0)}"])
    tot_c = sum(res["cnt"][sp].get("cand", 0) for sp in sps)
    tot_p = sum(res["cnt"][sp].get("paired", 0) for sp in sps)
    rows.append(["合计", sum(res["cnt"][sp].get("danger_obj", 0) for sp in sps), sum(res["cnt"][sp].get("shell_ent", 0) for sp in sps),
                 tot_c, sum(res["cnt"][sp].get("atk_dead", 0) + res["cnt"][sp].get("no_C", 0) for sp in sps), tot_p,
                 f"{100 * tot_p / tot_c:.0f}%" if tot_c else "-", "-", "-", "-"])
    T(["怪", "有 DANGER 的打主角对象", "弹体条目（剔除）", "候选单位", "剔除（ATK 停 / 读不到 C）", "配上", "配对率",
       f"≥ {UNIT_MIN} 个", f"≥ {int(PAIR_MIN * 100)}%", "没配上：窗里没有 / 第一次在窗前"], rows)
    R.p("**数据**：只有 em2 两条都达到；em3 两条都没达到；em31、em15、em14 配对率够、个数不够。按 7.1，达不到的都要列出没配上的招、"
        "到接触层单独检查（下一节）。")

    R.h("2.3 没配上的招，和接触层的单独检查", 3)
    R.p("接触层的做法：配对窗里第一次接触（CT）先归属到「登记时预测的激活时刻（含 b）不晚于接触 + 0.05 s、而且最晚」的单位（同一只怪的所有单位里挑，"
        "含没配上的；接触总在激活之后，本批 g ≥ 0.01 s），归到别的单位的记「多半是另一段攻击」。归到本单位的，看接触相对 E5c 预测的残差 "
        "r_ct（减 b），以及按 L = 28 的触发帧放刀会不会放早（接触 − 放刀 < W0 = 0.328 s；Q 没落进 [22, 28] 的不会放刀，不计）。")
    rows = []
    for sp in sps:
        us = [u for u in U if u["sp"] == sp and u["status"] in ("unpaired_none", "unpaired_early")]
        for act, g in sorted(group_by(us, lambda u: u["act"]).items(), key=lambda x: (-len(x[1]), str(x[0]))):
            alt_ok = sum(1 for u in g if u.get("alt_paired"))
            alt_r = [u["alt_r"] for u in g if u.get("alt_r") is not None]
            w = [u for u in g if u.get("cl")]
            mine = [u for u in w if u["cl"]["mine"]]
            e28 = [u for u in mine if u["cl"].get(f"early{L_USER}") is not None]
            reasons = Counter(u["status"] for u in g)
            rows.append([sp, act, len(g), "；".join(f"{STATUS_TXT[k]} {v}" for k, v in reasons.items()),
                         "、".join(sorted({str(u["rq"]) for u in g}, key=lambda s: int(s))),
                         f"{alt_ok}/{len(g)}" + (f"（r 中位 {sfmt(med(alt_r))}）" if alt_r else ""),
                         f"{len(w)} / {len(mine)}", sfmt(med([u['cl']['r_ct'] for u in mine])) if mine else "-",
                         f"{sum(1 for u in e28 if u['cl'][f'early{L_USER}'])}/{len(e28)}" if e28 else "-"])
    T(["怪", "招（消息时的动作）", "没配上", "原因", "reqset", "换另一种 a5 口径能配上（残差中位）", "接触：有 / 归到本单位",
       "r_ct 中位", "L=28 放早"], rows)
    cl = ro["contact"]
    tot_mine = sum(cl[(sp, "unpaired")]["n_mine"] for sp in sps)
    tot_e28 = sum(cl[(sp, "unpaired")]["early28"] for sp in sps)
    tot_n28 = sum(cl[(sp, "unpaired")]["n28"] for sp in sps)
    tot_other = sum(cl[(sp, "unpaired")]["early28_other"] for sp in sps)
    rmin = min((cl[(sp, 'unpaired')]['r_ct_min'] for sp in sps if cl[(sp, 'unpaired')]['r_ct_min'] is not None), default=None)
    R.p(f"**数据**：没配上的单位里，有接触、而且接触归到它自己的 {tot_mine} 个，r_ct 最小 {sfmt(rmin)} s，按 L = 28 放刀会放早的 "
        f"{tot_e28}/{tot_n28}。另有 {tot_other} 个「接触按 L=28 会算放早」的，接触都归到了同一招里更早的一段（多段招前一段打到人），"
        "不算这一段放早。对照：配上的单位按同样做法，放早 " + "、".join(f"{sp} {cl[(sp, 'paired')]['early28']}/{cl[(sp, 'paired')]['n28']}" for sp in sps) + "。")
    pre = [u for u in U if u["status"] in ("unpaired_none", "unpaired_early") and u.get("pre_msg_atk") is not None]
    if pre:
        rp = [u["pre_msg_atk"] - u["P0"] for u in pre]
        R.p(f"**数据**：没配上的里有 {len(pre)} 个（" + "、".join(f"{sp} {a}×{n}" for (sp, a), n in Counter((u['sp'], u['act']) for u in pre).most_common())
            + f"）满足条件的激活比消息早 {rng([u['t_msg'] - u['pre_msg_atk'] for u in pre], 3, False)} s（同一帧，A 只有 "
            f"{rng([u['A'] for u in pre], 1, False)} 帧）：按 7.1「消息之后」字面不算配上；设计阶段 phaseA_check 允许消息前 0.02 s，"
            f"那样能配上，残差 {rng(rp, 3)} s。")
    R.p("**推测**：没配上的招在接触层没有显出早到；它们没配上多是 a5 规则的问题（下一节），不是攻击来得早。")

    R.h("2.4 配对规则的盲区（只报告，不改口径）", 3)
    cu = [u for u in U if u["rule"] == "cids" and u["status"] not in ("atk_dead", "no_C")]
    if cu:
        n1 = sum(1 for u in cu if u["ncids"] == 1)
        rin = sum(1 for u in cu if u["rq_in_cids"])
        sr = sens["reqset_all"]["per"].get("em3", {})
        R.p(f"- **数据**：em3 通过了 C3 的对照，按 7.1 用 a5 ∈ cids。它的候选单位里 cids 只有 1 个元素的 {n1}/{len(cu)}，"
            f"reqset 在 cids 里的 {rin}/{len(cu)}；没配上的 {sum(1 for u in cu if u['status'] != 'paired')} 个里改用 a5 = reqset 能配上 "
            f"{sum(1 for u in cu if u['status'] != 'paired' and u.get('alt_paired'))} 个。全部改用 reqset 时 em3 配上 {sr.get('n')} 个，"
            f"中位 {sfmt(sr.get('med'))}、IQR {fmt(sr.get('iqr'))}，合并判据不变（第 8 节）。**推测**：铠龙的 a5 多是 RequestSetID，"
            "C3 的对照过了是因为它的 cids 恰好常含 reqset，不说明 a5 是碰撞体编号。")
    ex = [u for u in P if u["sp"] == "em31" and u["act"] == "(0,49)"]
    grp = [g for g in group_by(ex, lambda u: u["obj"]).values() if len(g) >= 3]
    if grp:
        rows = []
        for g in sorted(grp, key=lambda g: g[0]["t1"]):
            t0 = min(u["t1"] for u in g)
            pred = sorted(g, key=lambda u: u["P0"])
            acts = sorted(u["t_atk"] for u in g)
            for u, ta in zip(pred, acts):
                rows.append([fmt(t0, 1), u["rq"], fmt(u["A"], 1), fmt(u["P0"] - t0, 3), f"{fmt(u['t_atk'] - t0, 3)}（a5={u['a5']}）",
                             sfmt(u["r"]), fmt(ta - t0, 3), sfmt(ta - u["P0"])])
        R.p("- **数据**：em31 (0,49) 是 4 段的招。4 段都配上的几次里，按 a5 = reqset 配到的激活和按时间顺序对的激活（时刻相对 t1，秒）：")
        T(["这一次（os.clock）", "reqset", "A", "预测激活（含 b）", "a5 = reqset 配到的 ATK", "r（a5 = reqset）", "按时间顺序的 ATK",
           "残差（按时间顺序）"], rows)
        R.p("  激活的 a5 顺序每次都是 3、4、2、5；条目的 reqset 和 A 的对应在不同几次里不一样（有一次 reqset 3 是最早的一段，另一次是 reqset 2）。"
            "a5 = reqset 和时间顺序一致的那次误差 ≤ 0.02 s；不一致的那次按 a5 = reqset 配就错开 ±0.25~0.33 s，按时间顺序对仍 ≤ 0.02 s。"
            "**推测**：这一招不同方位变体的烘焙表把 reqset 标得不一样，激活用的是另一套编号；a5 = reqset 在这类多段招上不可靠。"
            "按 7.1 字面，它们仍以 a5 = reqset 进主口径；去掉这一招的结果见第 8 节。")

    # ------------------------------------------------------------ 3 合并判据
    R.h("3. 合并判据 1~5")
    R.p(f"单位 n = {st['n']}（" + "，".join(f"{sp} {per[sp]['n']}" for sp in sps) + f"）。r 的分位：Q10 {sfmt(st['q10'])}、Q25 {sfmt(st['q25'])}、"
        f"中位 {sfmt(st['med'])}、Q75 {sfmt(st['q75'])}、Q90 {sfmt(st['q90'])} s。重抽：按怪分层、每只怪按招（消息时的动作）整簇重抽 "
        f"{bt['n']} 次（斜率 {bt['n_slope']} 次），各怪的招数 " + "，".join(f"{sp} {n}" for sp, n in bt["n_clusters"].items() if n) + "。")
    R.p("设计集标定（7.1 表，4 只怪各 60 个）：中位 −0.002（−0.008~+0.003）、IQR 0.044、斜率 1.02（0.97~1.10）、计时器 0 次 / "
        f"0.9998~1.0000、初值各档 −0.33~−0.19 帧。本批中位、IQR 和标定相近；斜率 {fmt(st['slope'], 2)} 偏高（设计数据里 em27 是 1.10），"
        f"在门槛内。初值各档约 −0.9 帧、标定是 −0.3 帧，差在口径：7.1 判据 5 用 INIT 里 initData 的返回值，设计阶段（2.1 b）用的是"
        f"消息时刻回推的值 hs_first + 60·(t_first − t_msg)，首个 SER 比消息晚 {fmt(res['lag_med'], 3)} s（约 {fmt(60 * res['lag_med'], 2)} 帧）；"
        f"按设计阶段的口径回推，本批中位是 {sfmt(res['c5_msg_backext'], 2)} 帧，和标定一致（第 3.2 节）。")

    R.h("3.1 判据 4：计时器的细节", 3)
    R.p(f"- 范围：新怪（{'、'.join(res['new_all'])}）{res['n_obj_all']} 个打主角的结果对象，{tm['n_seq']} 条倒数序列，"
        f"{tm['n_pairs']} 个相邻对（0 < Δt ≤ 0.1 s）。")
    R.p(f"- 速率（≥ 10 点、跨度 > 0.3 s 的序列，最小二乘斜率 ÷ −60）：{tm['n_rates']} 条，中位 {fmt(tm['rate_med'], 5)}，"
        f"5%~95% {fmt(tm['rate_q05'], 4)}~{fmt(tm['rate_q95'], 4)}；超出 ±0.005 的 {tm['rate_out']} 条（判据看中位）。")
    R.p(f"- 钳制（这一对里有 dt > {TH_CLAMP} s 的帧）：{tm['n_clamp']} 对。")
    R.p(f"- |d| > 2 帧（设计阶段测法）：**{tm['n_big']} 对**；同一个结果对象的几条条目在同一时刻各记一对，按「时刻 + 怪」合起来是下表 "
        f"{len(tm['events'])} 行（{n_hitch_ev} 次卡顿，每次两行）：")
    rows = []
    for e in tm["events"]:
        hg = "；".join(f"{h[3]} dt={h[1]}" for h in e["hitch"]) or "（上一行的卡顿）"
        rows.append([fmt(e["t"], 3), e["em"], e["n_pairs"], fmt(e["dt"], 3), fmt(e["dhs"], 2), sfmt(e["d"], 2), hg,
                     " ".join("·" if x is None else f"{x:+.2f}" for x in e["ctx"]), fmt(e["net5"], 2)])
    T(["这一对的起点（os.clock）", "怪", "条目数", "Δt（s）", "Δhs（帧）", "d = Δhs + 60Δt", "这一对里的卡顿记录", "前后 5 对的 d",
       "5 对合计 |·|"], rows)
    R.p(f"- 按引擎 DeltaTime 比（APCal 帧号连续的对，d' = Δhs + 前一帧开头读到的 DeltaTime）：{tm['lag_n']} 对，最大 |d'| "
        f"{fmt(tm['lag_absmax'], 3)} 帧（P99 {fmt(tm['lag_p99'], 3)}），> 2 帧 {tm['lag_big']} 对。")
    if res.get("design_hitch"):
        rows = [[x["dir"] + ("（本批，含 em19 和全部怪，对照）" if x["dir"].startswith("stageA") else ""), x["session"], "、".join(x["ver"]),
                 x["pairs"], x["big"], x["n_hitch_le100"], x["hitch_on_dense"], fmt(x["max_d_on_hitch"], 2)] for x in res["design_hitch"]]
        R.p("- 同一测法用在各段数据上（APCal，0 < Δt ≤ 0.1 s 的相邻对；卡顿 = dt 在 45~100 ms 的 HITCH/GAP）：")
        T(["数据", "session", "APCal", "相邻对", "|d| > 2", "45~100 ms 卡顿", "落在逐帧 SER 相邻对上的", "那些对的 |d| 最大"], rows)
    R.p("- **数据**：每次都是「卡顿那一对少扣 → 之后 1~2 对多扣」，前后 5 对合计 ≤ " + fmt(tm["net5_max"], 2)
        + " 帧；hs 每帧扣的量和引擎 DeltaTime 一致到 " + fmt(tm["lag_absmax"], 2) + " 帧。设计阶段的数据里卡顿从没落在逐帧 SER 上，"
        "所以「0 次」的标定没有检验过这种情况。")
    R.p("- **推测**：APCal 的 os.clock 时间戳和引擎的 DeltaTime 在卡顿帧上错开 1~2 帧（引擎晚一两帧才把长帧计进 DeltaTime）；"
        "hs 按引擎时间扣，用 os.clock 逐对比就会在卡顿帧上出现一正一负的大 d。这不是计时器跳变 —— 但 7.1 的字面判据数得到它，所以判据 4 字面不过。")

    R.h("3.2 判据 5：初值按 C 分档", 3)
    for key in ("c5_units_hook", "c5_units_first", "c5_all_hook"):
        c = res[key]
        R.p(f"**{c['key']}**（n = {c['n']}，判 {c['judged']} 档，{'过' if c['pass'] else '不过'}）：")
        T(["C", "n", "hs − AttackStartFrame 中位（帧）", "Q10~Q90", "判"],
          [[fmt(b["C"], 3), b["n"], sfmt(b["med"], 3), f"{sfmt(b['q10'], 2)}~{sfmt(b['q90'], 2)}",
            ("过" if b["pass"] else "**不过**") if b["judged"] else "不到 5 个，不判"] for b in c["bins"]])
    big_sgl = [r for r in res["c5_all_rows"] if r[1] is not None and r[1] < -5]
    R.p(f"**数据**：判的各档中位 {rng(c5_all, 2)} 帧，和 C 无关；它就是 −Single 参数（initData 那一刻动作已经走过的帧数，atp_analyze C1 的 "
        f"hs0 = ast − sgl 在 1489 条上残差 0）。初值含速度时 A = 100、C = 1.1 就会差 9 帧。hs − ast < −5 帧的 INIT {len(big_sgl)} 条"
        "（动作中途才建的结果：" + "、".join(f"{sp} {act} {rt}×{n}" for (sp, act, rt), n in Counter((r[2], r[3], r[4]) for r in big_sgl).most_common(4))
        + "），不影响各档中位。")

    # ------------------------------------------------------------ 4 逐只怪
    R.h("4. 逐只怪：中位、IQR、「系统性失败嫌疑」标记（只报告、不判）")
    rows = []
    for sp in sps:
        d = per[sp]
        rows.append([sp_label(sp), f"{d['n']}（{d['n_act']} 招）", sfmt(d["med"]),
                     ci_txt(d.get("med_ci")), ci_txt(d.get("med_ci_os")), ci_txt(d.get("med_ci_iid")),
                     fmt(d["iqr"]), ci_txt(d.get("iqr_ci"), signed=False), ci_txt(d.get("iqr_ci_iid"), signed=False),
                     f"{d['tail']}/{d['n']}", "**是**" if d["flag"] else "否",
                     f"{p_txt(d.get('flag_p'))} / {p_txt(d.get('flag_p_iid'))}"])
    T(["怪", "n", "r 中位", "95%：按招整簇", "95%：次序统计量", "95%：不分簇", "IQR", "95%：按招整簇", "95%：不分簇",
       "左尾 r < −0.10", "标记", "重抽下被标的概率（整簇 / 不分簇）"], rows)
    inds = [(sp, em, x) for sp in sps for em, x in (per[sp].get("inds") or {}).items()]
    R.p("按个体：" + "；".join(f"{em} n={x['n']} 中位 {sfmt(x['med'])} IQR {fmt(x['iqr'])}" for sp, em, x in inds) + "。")
    R.p(f"**数据**：没有一只怪的 |中位| > {FLAG_MED} s 或 IQR > {FLAG_IQR} s，一个标记都没有。设计集 n = 60 时单只怪中位的 95% 范围是 "
        "−0.013~+0.037、IQR 的 97.5% 分位 ≤ 0.116；本批各怪的点估计都在这个范围里。")
    e3, e2 = per.get("em3", {}), per.get("em2", {})
    seen, top = set(), []
    for a, _, r, _ in (ro["right_top"].get("em2") or []):
        if a not in seen:
            seen.add(a)
            top.append(f"{a} {sfmt(r, 2)}")
    top2 = "、".join(top)
    R.p(f"**数据**：样本少的怪区间很宽。em3 只有 {e3.get('n_act')} 招、{e3.get('n')} 个单位，按招整簇重抽时中位的 95% 区间下到 "
        f"{sfmt((e3.get('med_ci') or (None, None))[0])}、IQR 上到 {fmt((e3.get('iqr_ci') or (None, None))[1])}，被标的概率 {p_txt(e3.get('flag_p'))}"
        f"（来自左尾的 (0,57) 被重抽多次）；em2 的 IQR 区间上到 {fmt((e2.get('iqr_ci') or (None, None))[1])}（被标的概率 {p_txt(e2.get('flag_p'))}，"
        f"来自晚到的招 {top2} 被重抽多次）。「没有被标」对 em3、em2 是弱证据；em14、em15、em31 的区间都离标记线很远。")

    # ------------------------------------------------------------ 5 E5 对 E1
    R.h("5. 预注册的 E5 判定（E5c 对 E1）")
    cvals = {sp: sorted({round(u["C1"], 3) for u in P if u["sp"] == sp}) for sp in sps}
    R.p(f"- **数据**：{st['n']} 个配上的单位里，从登记后第一个帧回调到激活之间原值 CoreState 变过的 **{e5['n']} 个**"
        f"（m = max(1, C) 变过的 {e5['n_mchg']} 个）。新怪的 CoreState 只在少数几个值之间切换（" + "；".join(
            f"{sp} " + "、".join(f"{c:.3f}" for c in v) for sp, v in cvals.items()) + "），切换没有落在任何单位的存活期里。")
    R.p("- 判定：规则是「E5 的 |r| 中位不大于 E1 的就保持 E5c，否则改用 E1」。没有可比的单位，改用 E1 的条件不成立 → **保持 E5c**，不算新迭代。")
    R.p(f"- 含义（**数据**）：本批单位上 E5c 和 E1 只差计时方式（hs 递减 vs os.clock）和 C < 1 的 1 个单位；合并残差中位 E5c {sfmt(st['med'])}、"
        f"E1 {sfmt(sens['e1']['med'])}，IQR {fmt(st['iqr'])} / {fmt(sens['e1']['iqr'])}。**A 阶段没有检验到「逐帧积分比首帧读一次更准」"
        "这一部分**（SPEED 8.3 的问题仍没回答），要等存活期内换招、换速度的数据。")

    # ------------------------------------------------------------ 6 只报告项
    R.h("6. 只报告项（7.1 列出的全部）")
    R.h("6.1 左尾、g、按 r_raw + g 预测的放早率", 3)
    rows = []
    for sp in sps + ["合计"]:
        d = ro["tail_g"][sp]
        ci = cp_interval(d["tail"], d["n"]) if d["n"] else None
        rows.append([sp, d["n"], f"{d['tail']}（{d['tail_raw']}）", f"{100 * ci[0]:.0f}%~{100 * ci[1]:.0f}%" if ci else "-", d["n_g"],
                     f"{fmt(d['g_med'])}（{fmt(d['g_q10'])}~{fmt(d['g_q90'])}）", fmt(d["g_min"]),
                     f"{d[f'early{L_ALT}']}/{d[f'early{L_ALT}_n']}", f"{d[f'early{L_USER}']}/{d[f'early{L_USER}_n']}",
                     f"{d[f'g0_{L_ALT}']}/{d[f'g0_{L_ALT}_n']}", f"{d[f'g0_{L_USER}']}/{d[f'g0_{L_USER}_n']}",
                     d[f"notrig{L_USER}"]])
    T(["怪", "单位", "左尾 r < −0.10（r_raw < −0.10）", "左尾比例 95% 区间", "有接触", "g 中位（Q10~Q90，s）", "g 最小",
       "L=25 放早", "L=28 放早", "g=0 上界 L=25", "g=0 上界 L=28", "L=28 不会触发"], rows)
    R.p(f"口径（附录 B）：放早 ⇔ r_raw + g < W0 − (L − {D_BAR})/60；r_raw = t_ATK − T̂_E5c（不减 b），在 L 的触发帧（第一个 Q ≤ L 的真实 SER 点）求值；"
        "g = 激活后第一次接触 − 激活（只有打到主角才有）。只算 Q 落进 [22, L] 会触发的单位；「g=0 上界」不看接触、把 g 当 0。"
        "左尾比例的区间是 Clopper–Pearson，把单位当独立，左尾按招成簇时偏窄。")
    thr = W0 - (L_USER - D_BAR) / 60.0
    early = [u for u in P if u.get("g") is not None and u.get(f"dec{L_USER}") and u[f"dec{L_USER}"]["trig"]
             and u[f"dec{L_USER}"]["r_raw"] + u["g"] < thr]
    for u in early:
        R.p(f"**数据**：L = 28 的「放早」是 {u['sp']} {u['act']} reqset {u['rq']}（r_raw {sfmt(u[f'dec{L_USER}']['r_raw'])}、g {fmt(u['g'])}）"
            + ("，正是 2.4 节 a5 配错段的那一招；按时间顺序对，它的激活只比预测早 0.01~0.02 s，不会放早。" if u["act"] == "(0,49)" else "。"))
    R.p("**数据**：g 从不为负（最小 " + fmt(ro["tail_g"]["合计"]["g_min"]) + " s）；em3、em14 的 g 中位只有 0.013~0.015 s，攻击一激活就碰到人，"
        "这两只怪的早侧余量几乎全靠 L 本身。")

    R.h("6.2 后继结果的登记提前量、按物理激活去重的联合预测残差", 3)
    R.p(f"- 物理激活（同一只怪、同一次 ATK）{ro['phys_n']} 次，被 ≥ 2 个单位预告的 {ro['phys_multi']} 次（多是同一个结果对象里同时激活的几个 reqset）。")
    R.p(f"- 后继结果（同一次激活、比最早预告晚登记 > 0.05 s 的另一个结果对象）{len(lead)} 个，登记提前量（激活 − 登记）"
        f"{rng([x['lead'] for x in lead], 2, False)} s，**< {SUCC_LEAD} s 的 {sum(1 for x in lead if x['lead'] < SUCC_LEAD)}/{len(lead)}**；招："
        + "，".join(f"{sp} {a}→{b} ×{n}" for (sp, a, b), n in Counter((x["sp"], x["first_act"], x["act"]) for x in lead).most_common())
        + f"；后继自己的残差 {rng([x['r'] for x in lead])} s，被它接替的前一个结果的残差 {rng([x['first_r'] for x in lead])} s。")
    for nm, lab in (("joint", "所有活着的结果取最早的预测"), ("joint28", f"L={L_USER} 时第一个触发的结果"),
                    ("dedup", "附录 B 的去重：同一次激活取 A 最小的")):
        rs = [x["r"] for x in ro[nm]]
        R.p(f"- 联合残差（{lab}）：n = {len(rs)}，中位 {sfmt(med(rs))}，IQR {fmt(iqr(rs))}，r < −0.10 的 {sum(1 for r in rs if r < LEFT_TAIL)} 个。")
    if gap:
        R.p(f"- SER 在激活前 > {SER_GAP_WARN} s 就断了的单位 {len(gap)} 个：" + "；".join(
            f"{g['sp']} {g['act']} r {sfmt(g['r'], 2)}、断在激活前 {fmt(g['gap'], 2)} s、断时 Q {fmt(g['q_last'], 0)} 帧"
            + (f"、后继 {g['succ_act']} 的消息比断点晚 {sfmt(g['succ_msg_minus_end'], 3)} s" if g["succ_act"] else "、没有后继")
            for g in gap) + "。")
    R.p(f"**数据**：em3 (0,57)→(0,58) 是这批里唯一成规模的后继链。(0,57) 的最后一个 SER 点和 (0,58) 的消息在同一帧或只差一两帧"
        f"（消息晚 {rng([g['succ_msg_minus_end'] for g in g57], 3, False)} s），那时它的 Q 还剩 {rng([g['q_last'] for g in g57], 0, False)} 帧，"
        f"L = 28 不会在它上面触发；(0,58) 在激活前 {rng([x['lead'] for x in l58], 2, False)} s 用同一个 reqset 重新登记，自己的残差 "
        f"{rng([x['r'] for x in l58], 3)} s。(0,57) 自己的残差两个方向都有（{rng([u['r'] for u in u57], 2)} s）：激活什么时候来由 (0,58) 决定，"
        "(0,57) 的倒数只是它被接替之前的计划。按物理激活合起来，左尾比逐单位的少。**推测**：和 SPEED 2.4 的 (0,107)→(0,108) 是同一种保护，"
        "这次后继来得足够早；新怪上没有看到 < 0.45 s 的后继。")

    R.h("6.3 C 的范围、各分量 ≠ 1 的比例和残差斜率", 3)
    cr = ro["C"]
    R.p(f"- 首帧 C：{fmt(cr['c1_min'], 3)}~{fmt(cr['c1_max'], 3)}（存活期内 {fmt(cr['life_min'], 3)}~{fmt(cr['life_max'], 3)}）；取值："
        + "，".join(f"{c:.3f}×{n}" for c, n in sorted(cr["values"].items())) + f"。超出已验证范围 0.92~1.27 的 {cr['outside']} 个。")
    R.p("- 按怪：" + "；".join(f"{sp} " + "、".join(f"{c:.3f}×{n}" for c, n in v) for sp, v in cr["per"].items() if v) + "。")
    rows = []
    life = ro["life"]
    for name in res["spd_fields"]:
        c = ro["comps"].get(name)
        lf = life.get(name)
        if c is None or lf is None:
            continue
        sl = "-"
        if c["n_dev"]:
            if c["slope"] is None or not c["slope_judgeable"]:
                sl = f"x 太集中（sd(x) {fmt(c['sdx'], 4)} s < {TH_SDX}），不判" + (f"；算出来 {fmt(c['slope'], 2)}" if c["slope"] is not None else "")
            else:
                sl = fmt(c["slope"], 3)
        rows.append([SPD_SHORT.get(name, name), f"{c['n_dev']}/{c['n']}",
                     f"{fmt(c['min'], 4)}~{fmt(c['max'], 4)}" if c["n_dev"] else "恒 1",
                     "、".join(f"{k} {v}" for k, v in sorted(c["by_sp"].items())) or "-",
                     f"{lf['dev']}/{lf['ents']}", share_txt(lf["dev_time"], lf["time"]),
                     f"{fmt(lf['min'], 4)}~{fmt(lf['max'], 4)}", sl])
    T(["分量", "配上的单位里倒数期间 ≠ 1", "取值", "按怪", "所有新怪打主角条目里倒数期间 ≠ 1", "≠ 1 的时间占比", "全部条目的取值",
       "r 对 −A(1 − 1/分量)/60 的 Theil–Sen 斜率"], rows)
    scu = ro["scale_units"]
    R.p("斜率的约定和判据 3 一样：x = −A(1 − 1/分量)/60（分量取存活期的时间加权平均），漏乘这个分量时 r ≈ x、斜率 ≈ 1；分量已经在名义帧里"
        "（或已经修正）时斜率 ≈ 0。CoreState 那一行是 E5c 修正过的残差，斜率约 0.1，说明大修正量处还略有修正不足（判据 3 的 "
        f"{fmt(st['slope'], 2)} 是同一件事）。Scale ≠ 1 的 {scu['n']} 个单位里 Scale 只在个别帧 ≠ 1（存活期平均 "
        f"{fmt(scu['mean_rng'][0], 3)}~{fmt(scu['mean_rng'][1], 3)}），对应的 |x| ≤ {fmt(scu['x_absmax'], 3)} s，解释不了任何残差；"
        "其中残差大的 " + ("、".join(f"{a} {sfmt(r, 2)}" for a, r in scu["big"]) or "无") + " 都是晚到（安全侧），和 Scale 无关。")
    R.p("**数据（任务要求写清）**：倒数期间（所有新怪、含 em1 和 em17 打主角的全部条目，从首个 SER 到最后一个 SER），Random、Replica、WaitPacket、"
        "WaitPacketReserved、BlendTree、Action、MoveAction、MoveSpeed、Base **恒为 1**（≠ 1 的条目 0 个、时间 0）；≠ 1 的只有 CoreState、"
        f"Sequence（{fmt(life['_Sequence']['min'], 2)}~{fmt(life['_Sequence']['max'], 2)}）和 Scale（{fmt(life['_Scale']['min'], 3)}~{fmt(life['_Scale']['max'], 3)}）。"
        f"Sequence ≠ 1 的 {ro['comps']['_Sequence']['n_dev']} 个单位残差对它的斜率 {fmt(ro['comps']['_Sequence']['slope'], 2)} ≈ 0 → "
        "招式因子已在名义帧里（和 atp_analyze C7「只积 CoreState」一致）。**推测**：如果这批里有历战个体，它的倍率没有走 Random 等分量"
        "（这些分量恒为 1）；若走 CoreState，已经被 E5c 修正。")

    R.h("6.4 钩子时刻（INIT 快照）与首帧 C 一致的比例", 3)
    hk = ro["hook"]
    R.p(f"**数据**：{hk['same']}/{hk['n']} 一致（{100.0 * hk['same'] / hk['n']:.0f}%；配上的 {hk['paired_n']} 个里不一致 {hk['paired_dis']} 个）。"
        + ("不一致的按招：" + "；".join(f"{a} {b} 钩子 {c} 首帧 {d}×{n}" for (a, b, c, d), n in hk["by_act"]) if hk["by_act"] else "没有不一致的招。")
        + "SPEED 3.7 担心钩子那一刻读到上一招的 C，这批新怪上没有出现；v1.6 仍按设计在首帧读，和验证口径一致。")

    R.h("6.5 UNABLE_GUARD 条目、C < 1 子集、EMHIT 两组", 3)
    ug = ro["unable"]
    R.p(f"- UNABLE_GUARD：候选单位里 {ug['n']} 个（" + "，".join(f"{sp} {act} {STATUS_TXT[s]}×{n}" for (sp, act, s), n in ug["by"])
        + f"；DamageType " + "，".join(f"{k} {v}" for k, v in ug["dmg"].most_common()) + f"）；配上的 {len(ug['paired'])} 个残差 "
        + "、".join(sfmt(u["r"]) for u in ug["paired"]) + f"，其中 {ug['same_as_normal']} 个和同一个结果对象里的 NORMAL 条目是同一次激活。")
    lt = ro["lt1"]
    R.p(f"- C < 1：{len(lt)} 个单位" + ("（" + "；".join(f"{u['sp']} {u['act']}，C={u['C1']:.3f}：r_E5c {sfmt(u['r'])}、E1 原值 {sfmt(u['r_e1'])}、"
                                                     f"E5 原值 {sfmt(u['r_e5raw'])}" for u in lt) + "）" if lt else "")
        + "。按 1 处理（E5c）预测偏早（安全侧），按原值预测准，和机制一致；样本太少，回答不了 SPEED 8.4。")
    eh = ro["emhit"]
    R.p(f"- EMHIT（主角先砍中）：落在单位存活期里的 {len(eh['with'])} 个（放刀关掉之后整段只有 1 条 EMHIT）；没有 EMHIT 的 "
        f"{eh['without_n']} 个中位 {sfmt(eh['without_med'])}、IQR {fmt(eh['without_iqr'])}。两组比不了（A 阶段只记录、不出刀，本来就很少砍中）。")

    R.h("6.6 V16.md 9.1 补的只报告项（ENT）", 3)
    rows = []
    for sp in sps:
        d = ro["ent"][sp]
        rows.append([sp, "，".join(f"{k} {v}" for k, v in d["guard"].most_common()), "，".join(f"{k} {v}" for k, v in d["pbreak"].most_common()),
                     "，".join(f"{k} {v}" for k, v in d["dmg"].most_common())])
    T(["怪", "GuardType", "pbreak", "DamageType"], rows)
    R.p("口径：7.1 的候选单位（DANGER、非弹体）的 ENT。SKILL_GUARD：" + ("；".join(f"{sp} {act} {g} {dmg}×{n}" for (sp, act, g, dmg), n in ro["skill_guard"]) or "无")
        + "（只出现在 CATCH 上，和 V16 3.4 的等价性一致）。pbreak = 1 的 0 个。放刀关掉之后没有手动抵消（PH 0 条），「PH 状态 vs pbreak」无数据。")

    # ------------------------------------------------------------ 7 样本量
    R.h("7. 样本量带来的不确定性")
    R.p(f"- 目标是每只怪 ≥ 60 个能配上的单位；实际 " + "，".join(f"{sp} {per[sp]['n']}" for sp in sps) + "。用户决定不补数据，影响如下。")
    R.p(f"- **合并判据**：{st['n']} 个单位、{sum(bt['n_clusters'].values())} 招。按怪分层、按招整簇重抽，判据 1、2、3 通过的比例 "
        f"{p_txt(bt['med_pass'])}、{p_txt(bt['iqr_pass'])}、{p_txt(bt['slope_pass'])}。中位的 95% 区间 {ci_txt(bt['med'])}，离门槛 ±{TH_MED} "
        f"至少 {fmt(TH_MED - max(abs(bt['med'][0]), abs(bt['med'][1])), 3)} s；IQR 区间上端 {fmt(bt['iqr'][1])}，离门槛还有 {fmt(TH_IQR - bt['iqr'][1], 3)} s。"
        f"斜率区间 {ci_txt(bt['slope'], signed=False)} 贴近上门槛 1.3，是 5 项里最不稳的：长预告 × 高 C 的招少，几招的取舍就能把它推到 1.27。")
    R.p(f"- **逐只怪**：样本少时中位、IQR 的区间很宽（第 4 节）。按招整簇的区间偏保守（em3 只有 {e3.get('n_act')} 招，整簇重抽几乎是在这几招里挑），"
        f"不分簇的偏乐观。em3 被标的概率 {p_txt(e3.get('flag_p'))} / {p_txt(e3.get('flag_p_iid'))}、em2 {p_txt(e2.get('flag_p'))} / {p_txt(e2.get('flag_p_iid'))}："
        "这两只「没被标」不能当作「确实没有系统性问题」的强证据；它们的尾巴都能追到具体的招（em3 (0,57) 后继链、em2 的几个晚到的招），"
        f"不是整体偏移。em14 虽然只有 {per.get('em14', {}).get('n')} 个，但 {per.get('em14', {}).get('n_act')} 招、残差很集中，区间离标记线很远。")
    t3 = ro["tail_g"].get("em3", {})
    ci3 = cp_interval(t3.get("tail", 0), t3.get("n", 0)) if t3.get("n") else None
    R.p(f"- **左尾比例**：em3 {t3.get('tail')}/{t3.get('n')}（95% 区间 {100 * ci3[0]:.0f}%~{100 * ci3[1]:.0f}%），其余每只 0~2 个；"
        "左尾按招成簇（em3 全来自 (0,57)），按单位算的比例会高估独立事件的个数。" if ci3 else "- **左尾比例**：-")
    R.p("- **没有覆盖到的**：存活期内 C 变化（E5 对 E1）0 个；C < 1 只有 1 个；EMHIT 0 个；Random 等分量 ≠ 1 的 0 个；C 最高 "
        f"{fmt(cr['c1_max'], 3)}（设计数据最高 1.264，长预告 × 高 C 只在设计数据的 em27 上有）。这些问题 A 阶段回答不了，不能算「通过」。")

    # ------------------------------------------------------------ 8 敏感性
    R.h("8. 敏感性（口径选择会不会改结论）")
    rows = []

    def srow(lab, s):
        p = s["pass"]
        fl_ = [sp for sp, d in (s.get("per") or {}).items() if d.get("flag")]
        rows.append([lab, s["n"], sfmt(s["med"]), fmt(s["iqr"]), fmt(s["slope"]),
                     " / ".join("过" if x else ("-" if x is None else "不过") for x in p), "、".join(fl_) or "无"])
    srow("主口径（激活前最后一个真实 SER 点）", dict(st, **{"pass": (res["p1"], res["p2"], res["p3"]),
                                                   "per": {sp: {"flag": per[sp]["flag"]} for sp in sps}}))
    srow(f"在 L={L_USER} 的触发帧求值", sens[f"dec{L_USER}"])
    srow(f"在 L={L_ALT} 的触发帧求值", sens[f"dec{L_ALT}"])
    srow(f"只用激活前 {SER_GAP_WARN} s 内有真实 SER 点的单位", sens["ser_gap"])
    srow("em3 也用 a5 = reqset", sens["reqset_all"])
    srow("去掉 em31 (0,49)", sens["no_em31_049"])
    srow("T̂ 用 E1（首帧 C 原值）", sens["e1"])
    T(["口径", "n", "中位", "IQR", "斜率", "判据 1 / 2 / 3", "被标的怪"], rows)
    R.p(f"判据 3 的两两斜率不设 |Δx| 下限：{fmt(sens['slope_all_pairs'], 3)}。判据 4、5 不依赖这些选择。**数据**：所有口径下判据 1~3 都过、"
        "没有怪被标；结论只取决于判据 4 的读法。")

    # ------------------------------------------------------------ 9 复现
    R.h("9. 复现与文件")
    R.p("- 判定：`python tools/stage_a_judge.py tools/out/stageA_data --out tools/out/stageA_report.md [--json 摘要.json]`。只用标准库；"
        "import tools/atp_analyze.py 的加载器和 C3 的零假设对照（atp_analyze.py 没有改动），设计阶段卡顿旁证默认读同级的 round*_data。")
    R.p("- 自测：`python tools/stage_a_judge.py --selftest`（E5c 重放的解析解、稀疏 SER、C < 1、分档、区间、整簇重抽）。")
    R.p("- 本次没有部署、没有提交、没有动游戏目录；只新增 tools/stage_a_judge.py 和本报告。")
    return R


def summary_json(res):
    per = {sp: {k: v for k, v in d.items() if k != "inds"} for sp, d in res["per"].items()}
    units = []
    for u in res["units"]:
        x = {k: v for k, v in u.items() if k not in ("track", "track_raw", "comps", "dec25", "dec28", "cl", "win")}
        if u.get("cl"):
            x["cl"] = dict(u["cl"])
        for lv in (L_ALT, L_USER):
            if u.get(f"dec{lv}"):
                x[f"dec{lv}"] = u[f"dec{lv}"]
        units.append(x)
    return {"version": VERSION, "atp_session": res["atp_session"], "verdict": res["verdict_auto"],
            "criteria": {"1_median": {"value": res["pooled"]["med"], "pass": res["p1"]},
                         "2_iqr": {"value": res["pooled"]["iqr"], "pass": res["p2"]},
                         "3_slope": {"value": res["pooled"]["slope"], "sdx": res["pooled"]["sdx"], "pass": res["p3"]},
                         "4_timer": {"jumps_literal": res["timer"]["n_big"], "rate": res["timer"]["rate_med"],
                                     "pass_literal": res["p4"], "jumps_engine_dt": res["timer"]["lag_big"],
                                     "pass_engine_dt": res["p4_engine"], "events": res["timer"]["events"]},
                         "5_init": {"pass": res["p5"], "units_hook": res["c5_units_hook"], "units_first": res["c5_units_first"],
                                    "all_hook": res["c5_all_hook"]}},
            "n_units": res["pooled"]["n"], "per_monster": per, "flagged": res["flagged"], "e5": res["e5"],
            "boot": res["boot"], "sens": res["sens"], "design_hitch": res.get("design_hitch"),
            "counts": {sp: dict(c) for sp, c in res["cnt"].items()}, "units": units}


# ================================================================ 自测
def selftest():
    fails = []

    def check(cond, what):
        print(("  ok   " if cond else "  FAIL ") + what)
        if not cond:
            fails.append(what)

    ix = {n: i for i, n in enumerate(["_Base", "_CoreState", "_Sequence"])}

    def comp(c, s=1.0):
        return (1.0, c, s)

    a_nom = 90.0
    # 1. C 不变：E5c 每个点的 T̂ 都 = t1 + A/(60·m)
    sp = Speed([0.0], [comp(1.1)], ix)
    tr = e5_track([(k / 60.0, a_nom - k) for k in range(0, 80)], sp, True)
    check(all(abs(row[5] - a_nom / 66.0) < 1e-9 for row in tr), "E5c：C 不变时 T̂ 处处等于 A/(60C)")
    # 2. 中途变速（帧开头切换）：激活前最后一点的 T̂ = 解析解
    sp = Speed([0.0, 0.5], [comp(1.0), comp(1.2)], ix)
    tr = e5_track([(k / 60.0, a_nom - k) for k in range(0, 80)], sp, True)
    t_true = 0.5 + (a_nom / 60.0 - 0.5) / 1.2
    k = last_before(tr, t_true)
    check(abs(tr[k][5] - t_true) < 1e-6, f"E5c：0.5 s 处 1.0→1.2，激活前最后一点 T̂ = {t_true:.4f}（得 {tr[k][5]:.4f}）")
    check(abs(tr[0][5] - a_nom / 60.0) < 1e-9, "E5c：首帧 T̂ = E1（首帧 C）")
    # 3. SER 每 4 帧一格、变速落在格子中间：按 EMSPD 变化点切段，结果仍是解析解
    smp = sorted(set([(k / 60.0, a_nom - k) for k in range(0, 80, 4)] + [(80 / 60.0, a_nom - 80)]))
    tr = e5_track(smp, sp, True)
    k = last_before(tr, t_true)
    check(abs(tr[k][5] - t_true) < 1e-6, "E5c：SER 稀疏（4 帧一格）时按变化点切段，T̂ 仍等于解析解")
    # 4. C < 1：E5c 按 1，E5 原值按 C
    sp = Speed([0.0], [comp(0.9)], ix)
    smp = [(k / 60.0, a_nom - k) for k in range(0, 10)]
    check(abs(e5_track(smp, sp, True)[-1][5] - a_nom / 60.0) < 1e-9, "E5c：C < 1 按 1")
    check(abs(e5_track(smp, sp, False)[-1][5] - a_nom / 54.0) < 1e-9, "E5（原值）：C < 1 按 C")
    # 5. 读不到 C → None
    check(e5_track([(0.0, 10.0)], Speed([], [], ix), True) is None, "读不到 C 时返回 None")
    # 6. 重新初始化切段
    xs = [(0.0, 50.0, 0, "DANGER", 1), (0.016, 49.0, 0, "DANGER", 2), (0.033, 80.0, 0, "DANGER", 3), (0.05, 79.0, 0, "DANGER", 4)]
    check(len(split_seq(xs, [])) == 2, "hs 回跳 > 2 帧切成两段")
    check(len(split_seq(xs[:2], [0.01])) == 2, "两点之间有同一条目的新 INIT 也切开")
    # 7. 区间
    ci = median_ci(list(range(1, 21)))
    check(ci == (6, 15), f"中位数 95% 次序统计量区间 n=20 → (6, 15)（得 {ci}）")
    lo, hi = cp_interval(6, 27)
    check(abs(lo - 0.0862) < 0.002 and abs(hi - 0.4243) < 0.002, f"Clopper–Pearson 6/27 ≈ 0.086~0.424（得 {lo:.4f}~{hi:.4f}）")
    check(cp_interval(0, 10)[0] == 0.0 and abs(cp_interval(0, 10)[1] - 0.3085) < 0.002, "Clopper–Pearson 0/10 上界 ≈ 0.308")
    # 8. Theil–Sen
    xs_ = [i * 0.01 for i in range(50)]
    ys_ = [1.1 * x + (0.5 if i == 7 else 0.0) for i, x in enumerate(xs_)]
    check(abs(theil(xs_, ys_) - 1.1) < 1e-9, "Theil–Sen 不受单个离群点影响")
    # 9. 判据 5 分档
    rows = [(1.0, -0.9)] * 6 + [(1.2, -3.0)] * 6 + [(1.3, -9.0)] * 4
    c = crit_init(rows, "t")
    check(c["judged"] == 2 and not c["pass"], "判据 5：|中位| > 2 帧的档判不过，不到 5 个的档不判")
    check(crit_init([(1.0, -0.9)] * 6, "t")["pass"], "判据 5：各档都在 2 帧内判过")
    # 10. 合并判据
    us = [{"r": 0.01 * ((i % 5) - 2), "x": -0.05 * (i % 7), "r0": -0.05 * (i % 7) + 0.001 * (i % 3)} for i in range(70)]
    s = pooled_stats(us)
    p1, p2, p3 = judge_pooled(s)
    check(p1 and p2 and p3 is not None and abs(s["slope"] - 1.0) < 0.05, "合并判据 1~3 的计算（斜率 ≈ 1）")
    us2 = [dict(u, x=-0.001 * (i % 3)) for i, u in enumerate(us)]
    check(judge_pooled(pooled_stats(us2))[2] is None, "判据 3：sd(x) < 0.03 时不判")
    # 11. 整簇重抽：只有一个簇时统计量不变
    b = cluster_boot([{"r": 0.1, "k": 1}, {"r": 0.2, "k": 1}], lambda s_: med([u["r"] for u in s_]), lambda u: u["k"], 50, 1)
    check(min(b) == max(b), "整簇重抽：一个簇时统计量不变")
    print(f"自测：{'全过' if not fails else f'{len(fails)} 项没过'}")
    return 0 if not fails else 1


def main(argv=None):
    ap_ = argparse.ArgumentParser(description="SPEED.md 7.1 A 阶段判定（stage_a_judge）")
    ap_.add_argument("data", nargs="?", help="数据目录（ATP_*.json、APCal_*.json、AutoParryGS_*.json）")
    ap_.add_argument("--session", type=int, help="ATP session（默认取文件最多的那个）")
    ap_.add_argument("--out", help="报告写到这个文件（Markdown）")
    ap_.add_argument("--json", help="摘要写到这个 JSON 文件")
    ap_.add_argument("--design-dir", action="append", default=None,
                     help="判据 4 旁证用的设计阶段数据目录（可重复；默认 = 数据目录同级的 round*_data，外加数据目录本身作对照）")
    ap_.add_argument("--selftest", action="store_true")
    a = ap_.parse_args(argv)
    if a.selftest:
        return selftest()
    if not a.data:
        ap_.print_help()
        return 2
    if a.design_dir is None:
        parent = os.path.dirname(os.path.normpath(os.path.abspath(a.data)))
        a.design_dir = sorted(os.path.join(parent, d) for d in os.listdir(parent)
                              if d.startswith("round") and d.endswith("_data") and os.path.isdir(os.path.join(parent, d)))
        a.design_dir.append(a.data)
    a.design_dirs = a.design_dir
    atp, ap, raw, verdict, picked = load_inputs(a.data, a.session)
    res = judge(atp, ap, raw, verdict, picked, a)
    res["spd_fields"] = list(atp.spd_fields or [])
    text = render(res, a.data.replace("\\", "/").rstrip("/")).text()
    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"报告写到 {a.out}；结论 {res['verdict_auto']}")
    else:
        print(text)
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump(summary_json(res), f, ensure_ascii=False, indent=1, default=str)
    return 0


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except (OSError, ValueError):
            pass
    sys.exit(main())
