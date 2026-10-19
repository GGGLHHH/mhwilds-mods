#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
apcal_analyze.py：大剑自动放刀离线分析（第 1 轮标定 + 第 2 轮验收；只用 Python 标准库）。

依据：docs/autoparry/CONTRACT.md 第 2、3.4、4.2、6 节；docs/autoparry/PLAN.md 的
DECISION RULE B（结局互斥分类）、C1~C10、D，以及 PROBE SPEC P23 的预注册匹配规则；
第 2 轮（v1.5 发布版）的记录约定见 docs/autoparry/V15.md 第 2~4 节。
本文件里的规则在部署前写死（预注册），看到数据之后不许改；要改就改版本号并在报告里写明。
修订 1.1（第 2 轮验收前写死，见 ANALYZER_REV）：认 v1.5 的 HDR / CFG / STAT replica·readerr，D 节按第一次参数改动
截断并给出验收判定，--calib-dir 从别的目录取定标 session。轮换标定 session（第 1 轮）的全部数值与 1.0 相同。
修订 1.2（第 2 轮验收前、审查后写死）：D 的截断只看提前量（启用开关切换不截断、只排除关着的时段）；多个 session
按加载先后，前面改过参数、或加载时 HDR 不是 V15 冻结值的发布版 session 整段不计；D 的关键错误只算放刀模块的 RED，
探针 RED 是数据质量问题（判「需复核」）；PLAN D 的协议进判定；发布版报告第 9 节只作复核（不出 C9 的三选一）。
修订 1.3（v1.5.1，V15.md 第 9 节，复验前写死）：冻结参数按版本（1.5 → L=26，1.5.1 → L=30；L_min、W_long、H_veto 不变），
D「加载时是否为冻结值」按 session 自己的版本判断；解析 VETO 的 why（long / grab）；1.5.1 起的 session 影子回放加抓取否决
（抓取条目不进候选，hs≤H_veto、he≥0 时否决），漏报归因区分「被抓取规则否决」。1.5 和轮换标定 session 的数值不变。
修订 1.4（v1.6，docs/autoparry/V16.md 第 7 节，B 阶段验收前写死）：认 v1.6 的记录（E5c 字段、SKIP、UVIEW、RES to、STAT 新计数、
VETO why=sg），版本 ≥1.6（或版本号认不出、HDR 带 rule=E5c）按 v1.6 的冻结值（提前量 28，Q 单位）；(2,25) cParrySlashHitS
改判 RECOIL（G1 实测，对所有版本生效；第 1 轮没有 (2,25)，数值不变）；v1.6 的 D 按 V16 第 9.2 节（按怪、新怪合并判定、纯空挥、
打断单列、放刀模块 RED=0，数据质量问题判需复核）；另出 E5c 影子回放、G1 只报告项和 C 阶段监控（只报告，不进判定）。
1.4 集成修订（B 阶段之前，V16.md 第 13 节）：第 13 节「1.6 影子对真 FIRE」按这一刀 FIRE 自己的 L 重放（固定按 28 比会把
滑块改过的放刀误报成实现错误）；g1_class 按「确定的原因优先」（SKILL_GUARD 家族 > pb > UNABLE_GUARD > 读不准），和放刀模块、
mock 神谕同一口径。第 1 轮和 2a / 2b / 2c 的报告不受影响（这两处只作用于 1.6 起的 session）。
1.4 审查修订（B 阶段之前，V16.md 第 14 节；报告头另起一行 ANALYZER_REV_14R）：
  · E5c 影子的时钟上限随两格隔开的时间放宽（CLOCK_DMAX + 60 × 秒数，和放刀模块同一口径；SER 断档时不再整段丢掉 X）；
  · 第 13 节「1.6 影子对真 FIRE」：实际 Q 用 FIRE 的 Q0，影子 Q 和差另列；影子不触发 / 没有条目的真放刀逐条给原因
    （shadow_gap_reason：可解释 / 原因不明），nchg ≠ 0 的帧差单列只报告；
  · 探针 AP 停用（ERR mod=AP）之后属性不明的条目不按读不准（entry_g1x 的 unk）：影子放行、漏报另记「可能被该接过滤排除
    （探针 AP 停用，属性不明）」、第 14 节不进分布并写明停用时刻；
  · D16 的「放刀模块 RED」另算核心模块的红错误（ERR level=red / STAT red，2c 那类单发的 caught (...) exception），判不通过，
    不再放在「数据质量：需复核」里；
  · 自检补：D16 门槛的边界（75%、15 次接触、放早 3 次、em33 不算新怪）、E5c 影子参数的单元核对、上面几项各一例。
  第 1 轮报告和 2a / 2b / 2c 的 1.3 口径数值不变（只有第 13 节影子回放的时钟上限会让 SER 断档处的影子读数变化）。
修订 1.5（docs/autoparry/MERGE.md 第 4.4 节；报告头另起一行 ANALYZER_REV_15）：放刀逻辑并入 AutoGuardGS v1.5（「合并版」），
  放刀记录只剩 HDR、FIRE、RES、ERR、RED（调试日志开着才写 FIRE / RES，HDR 懒写在第一行之前），没有 JSON。
  · RES 认追加的 entered（FIRE_END 已删）：build_fires 取 entered 按 FIRE_END → RES 的 entered → 探针 ACT → 按已进入计；
  · FIRE 没有 Qe1（合并版删了 Qp、Qe1、src、mode、vq）时，一致性核对只查 |Q0 − (R0 − dX)/mf| 和 L_min ≤ Q0 ≤ L，不报缺字段；
  · HDR 带 host 字段的 session 是合并版（ver 仍是放刀规则版本 1.6，按 1.6 的冻结值）：报告头写明它没有哪些记录，D16 的开销项
    写「—（合并版没有 STAT；开销看 [AutoGuardGS] PERF 行）」、sidmis 项写「—（合并版不记…）」判需复核（审查修订：以前没有数据
    也判通过），所以合并版的 D16 只会是「样本不足」或「需复核」，不会「通过」；
  · 只对带 host 的 session、缺 Qe1 的 FIRE 生效：第 1 轮和 2a / 2b / 2c 的报告只多报告头这一行。

用法：
  python tools/apcal_analyze.py <数据目录> [--log re2_framework_log.txt] [--session N] [--out report.md]
  python tools/apcal_analyze.py <第 2 轮目录> --calib-session 1791644664 --calib-dir tools/out/round1_data --out r2.md
  python tools/apcal_analyze.py --selftest [--keep 目录]

输入：数据目录（递归）里的 APCal_<session>_<seq>.json、AutoParryGS_<session>_<seq>.json；
日志按 --log，或在数据目录、其上一两级目录里找 re2_framework_log.txt / ref.log。
JSON 优先；JSON 缺失（整份或某个 seq）时，用日志里同名记录补齐（SER/ANIM/HOLD 只进 JSON，日志里没有）。
v1.5 没有机关扫描：窗口 W0/W1、T_armor、δ 用 --calib-session（+ --calib-dir，第 1 轮数据在另一个目录时）取第 1 轮的。
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

ANALYZER_VERSION = "apcal_analyze 1.0（预注册版）"
# 1.1 的增补只改「参数冻结」session（v1.5 发布版，第 2 轮）的口径；1.0 那行版本号保持原样，好让第 1 轮报告
# 和基准逐行比对时只多出新增行（修订说明另起一行写进报告头，满足「改规则就改版本号并在报告里写明」）
ANALYZER_REV = ("1.2（第 2 轮验收前增补，预注册）：1.1 认 v1.5 的 HDR/CFG/STAT replica·readerr，D 节按第一次参数改动截断、"
                "给出验收判定，--calib-dir 从别的目录取定标 session；1.2 D 只按提前量改动截断（启用开关切换不截断，只排除关着的"
                "时段），多次加载按 session 先后、前面改过参数或加载时不是 V15 冻结值的整段不计，关键错误只算放刀模块的 RED"
                "（探针 RED 判需复核），协议（两只怪、新怪、无限蓄力）进判定，发布版第 9 节只作复核。"
                "只改参数冻结 session 的口径，轮换标定 session 的数值同 1.0")
# 1.3 另起一行写进报告头（上面 1.2 那行原样保留：第 1 轮、第 2 轮 a 的旧报告逐行比对时只多出新增行）
ANALYZER_REV_13 = ("1.3（v1.5.1，第 2 轮验收中止后、复验前增补，预注册，V15.md 第 9 节）：冻结的提前量按版本取（1.5 → 26，"
                   "1.5.1 → 30；L_min 22、W_long 60、H_veto 90 不变），D「加载时是否为冻结值」按 session 自己的版本判断；"
                   "解析 VETO 的 why（long 长窗口 / grab 抓取）；1.5.1 起的 session 影子回放加抓取否决（抓取条目不进候选，"
                   "hs≤H_veto、he≥0 时否决），漏报归因多一类「被抓取规则否决」。1.5 和轮换标定 session 的数值不变")
# 1.4 再另起一行（1.2、1.3 那两行原样保留：旧报告逐行比对时只多出新增行）
ANALYZER_REV_14 = ("1.4（v1.6，B 阶段验收前增补，预注册，V16.md 第 7 节）：认 v1.6 的记录（HDR 的 rule/filter/cfg_ver/c_lo/c_hi，"
                   "FIRE 的 E5c 字段，RES 的 to，STAT 的新计数，新增 UVIEW、SKIP，VETO 的 why=sg），版本 ≥1.6（或版本号认不出、"
                   "HDR 带 rule=E5c）按 v1.6：冻结值提前量 28（Q 单位，真实剩余帧）、L_min 22、W_long 60、H_veto 90、rule=E5c、"
                   "filter=g1；(2,25) cParrySlashHitS 改判 RECOIL（G1 实测），对所有版本生效（第 1 轮没有 (2,25)，数值不变）；"
                   "v1.6 的 D 按 V16 第 9.2 节（按怪统计，新怪合并判定接住率、纯空挥率、开销、放刀模块 RED=0，打断单列，数据质量"
                   "问题判需复核），漏报归因多一类「被该接过滤排除」；另出 E5c 影子回放、G1 只报告项、C 阶段监控（只报告，不进判定）")

# 1.4 审查修订再另起一行（上面各行原样保留）
ANALYZER_REV_14R = ("1.4 审查修订（B 阶段之前，V16.md 第 14 节）：E5c 影子的时钟上限随两格隔开的时间放宽（同放刀模块）；第 13 节 1.6 的"
                    "「实际 Q」用 FIRE 的 Q0、另列影子 Q 和差，影子不触发 / 没有条目的真放刀逐条给原因（可解释 / 原因不明）；探针 AP "
                    "停用之后属性不明的条目不按读不准（影子放行、漏报另记一类、第 14 节不进分布）；D16 的「放刀模块 RED」另算核心模块"
                    "红错误（ERR level=red / STAT red），判不通过、不再只判需复核。第 1 轮和 2a / 2b / 2c 的 1.3 口径数值不变")

# 1.5 再另起一行（上面各行原样保留：旧报告逐行比对时只多出这一行）
ANALYZER_REV_15 = ("1.5（放刀逻辑并入 AutoGuardGS v1.5，MERGE.md 第 4.4 节）：认合并版的放刀日志（HDR 带 host、enum_skip，没有 "
                   "rotation/scan/cfg_ver；FIRE 没有 src/Qp/Qe1/mode/vq；RES 带 entered；没有 FIRE_END、VETO、SKIP、UVIEW、STAT、"
                   "CFG、JSON），HDR 的 ver 仍是放刀规则版本 1.6、按 1.6 的冻结值；entered 先取 FIRE_END、再取 RES；没有 Qe1 的 FIRE "
                   "一致性核对只查 Q0 和 L_min ≤ Q0 ≤ L；合并版 D16 的开销项写「—」（没有 STAT）、sidmis 判需复核（不记）。只对带 host 的 session、缺 Qe1 的"
                   " FIRE 生效，旧数据的数值不变")

# ---------------------------------------------------------------- 预注册常数
# 全部出自 PLAN.md 的 DECISION RULE / PARAMETERS；改动即视为改规则。
CREDIT = 1.3              # B1/B2：放刀后 1.3 s 内进入 (2,25..27) 才算接住（1.4：只认 (2,26)/(2,27)，(2,25) 改判 RECOIL）
TAIL_MAX = 4.0            # B4：收尾挨打一直统计到离开 (2,23)，最长 4 s
WHIFF_PAD = 0.30          # B6：空放 = 到 t_req + he/60 + 0.3 s 都没有该攻击者接触
MATCH_PRE = 0.35          # P23：接触落在 [t_hs0-0.35, t_he0+0.30]
MATCH_POST = 0.30
M_E, M_L = 0.02, 0.03     # 窗口余量（早侧、晚侧）
L_GRID = list(range(18, 46))
DEFAULTS = {"L": 28, "L_min": 18, "W_long": 60, "H_veto": 90, "alpha": 0.0}
DELTA_PRIOR = 0.012       # δ 先验（PLAN 参数表），只在无样本时使用并标注
W_PRIOR = (0.33, 0.75)    # 窗口先验（PLAN KEY INSIGHTS：W0≈0.30~0.36，W1≥0.654），只在扫描样本不足时用并标注
POTENTIAL_WIN = 1.2       # C8：潜在接住 = t_L + 1.2 s 内有该攻击者接触
SHADOW_CHARGE_WIN = 1.2   # C7：影子回合要求 [t_L, t_L+1.2] 全程在蓄力中
SCAN_CONTACT_MAX = 1.6    # P20：1.6 s 内没有接触即作废
HITCH_DT = 0.035          # RISKS：dt>0.035 s 的样本做标记、分析时剔除
SER_STALE = 0.10          # 影子回放：条目最近一格超过 0.1 s 视为过期（SER 稀疏时每 4 帧一格）
SEG_BRIDGE = 0.5          # 1.3 修订：数影子否决段时，同一条目相邻两格隔 ≤0.5 s（卡顿）按连续算（rc 每帧求值，卡顿不断段）
SESSION_PAIR_TOL = 120    # 两个脚本各取一次 os.time()，同一次 Reset 加载相差应在几秒内
GATE_MIN_REMOVED, GATE_MAX_LOST, GATE_MAX_N = 4, 1, 2   # C8
IQR_GAIN = 0.20           # C6：IQR 小 20% 以上才换
BOOT_N, BOOT_SEED = 400, 20261010
# D（第 2 轮验收，PLAN D）：有接触的放刀接住率 ≥75%、空放 ≤25%（空放按 PLAN 原口径，先砍中打断 INTERRUPTED 计入）。
# D 本身没写样本量；样本太少时「通过」没有意义，所以沿用 C9(b)(c) 的 n≥15 / n≥20，不够判「样本不足」（不算通过）
D_CATCH_MIN, D_WHIFF_MAX = 0.75, 0.25
D_N_CONTACT, D_N_FIRE = 15, 20
# 1.2：v1.5 冻结的参数（docs/autoparry/V15.md 第 1 节）。发布版 session 加载时（HDR）不是这些值 = 参数在这次加载之前
# 就改过（滑块改动存进了配置），按 PLAN D「只用第一次改动之前的数据」整段不计
FROZEN = (("提前量", "lead0", 26), ("L_min", "lmin", 22), ("W_long", "wlong", 60), ("H_veto", "hveto", 90))
V15_DEFAULTS = {"L": 26, "L_min": 22, "W_long": 60, "H_veto": 90, "alpha": 0.0}   # 第 2 轮报告的默认列、样本不足时的回退值
# 1.3：冻结的提前量按发布版的版本号取（V15 第 9 节：1.5 → 26，1.5.1 → 30）；L_min、W_long、H_veto 各版本相同。
# 比 1.5.1 新的版本沿用最近的已知版本；版本号认不出来按 1.5（1.2 的口径）。抓取否决从 1.5.1 起才有（GRAB_SINCE）
# 1.4：v1.6 的提前量 28 是 Q 单位（真实剩余帧，V16 第 1 节）；比 1.6 新的版本沿用 1.6
FROZEN_LEAD_BY_VER = (((1, 5), 26), ((1, 5, 1), 30), ((1, 6), 28))
GRAB_SINCE = (1, 5, 1)
GRAB_DT = ("CATCH", "CATCH_ZAKO", "CATCH_SLINGER")     # app.HitDef.DAMAGE_TYPE 里的抓取（ENT 的 dmgtype 按名字认）
# 1.4（V16）：E5c 触发量、「该接」过滤（g1）、SKILL_GUARD 家族否决都从 1.6 起。版本号认不出来、但 HDR 带 rule=E5c 的也按 1.6
E5C_SINCE = G1_SINCE = (1, 6)
FROZEN_RULE_16 = (("rule", "E5c"), ("filter", "g1"))   # v1.6 的冻结值里两项文本（第 7 节第 4 条）
L_MIN_16, W_LONG_16, H_VETO_16, LEAD_16 = 22, 60, 90, 28
C_LO, C_HI = 0.5, 2.0       # CoreState 合法范围（只用来剔除坏值，V16 第 1 节）
C_SEEN = (0.92, 1.27)       # 已验证过的 CoreState 范围；超出的放刀单独报告（外推）
CLOCK_DMAX = 30             # 时钟条目一对读数之间 hs 递减的上限：30 + 60 × 两次读数隔开的秒数（V16 第 1 节，审查修订）
C1_WIN = 2.0                # 影子回放：消息之后 2 s 内同一只怪的第一条 EMINFO 当首帧 C（V16 第 7 节第 5 条）
Q_SHADOW_TOL = 0.5          # 审查修订：nchg = 0 的 1.6 放刀，影子算的 Q 和 FIRE 的 Q0 差超过这么多帧就列出（EMINFO 的 C 三位小数、SER 外推）
G1_OK_GUARDS = ("NORMAL", "ALL_RANGE")                  # 该接过滤的 GuardType 白名单（V16 第 3.1 节）
SG_GUARDS = ("SKILL_GUARD", "SKILL_GUARD_ALL_RANGE")    # SKILL_GUARD 家族：否决（why=sg，V16 第 3.4 节）
# D16（V16 第 9.2 节）：设计集是验收协议的一部分（不进规则）；训练机关 em33（Em0165）不算怪
DESIGN_EMIDS = (18, 19, 20, 23, 27)
DUMMY_EMID = 33
D16_CATCH_MIN, D16_WHIFF_MAX = 0.75, 0.25
D16_MIN_MONSTERS, D16_MIN_CONTACT = 4, 15
D16_FLAG_CATCH, D16_FLAG_EARLY = 0.60, 3     # 逐只怪「左尾诊断」标记（只标不判）
APCAL_MIN = (1, 1)          # B 阶段 v1.6 必须和 APCal ≥1.1 一起跑（引用记账，V16 第 5.4 节）
MON_EARLY, MON_NOCATCH = 3, 3                # C 阶段监控：某一招放早或 NOCATCH ≥3 次、或任何 RECOIL 就报告（V16 第 9.3 节）
# 1.2：PLAN D 的协议「两只出招风格不同的怪各打约 10 分钟，其中一只是新怪，至少一只关掉无限蓄力」进判定。
# 一只怪「打过」= D 范围内它的 DANGER 回合 ≥10（第 1 轮 B 段约 15 分钟里 em19/em20 各 22/37 个；宁松勿严：
# 不够只判样本不足、不判不通过）
D_PROTO_MIN_DANGER = 10

CHARGE = {(2, 21), (2, 22)}
SLASH = (2, 23)
# 1.4（V16 第 4 节，G1 实测）：(2,25) cParrySlashHitS 是抵消被破（PARRY_STATE RECOIL，被弹并随即身体挨打），不是接住；
# 只有 (2,26) HitM（WAIT→HIT）、(2,27) HitL（WAIT→SUCCESS）算接住。对所有版本生效（第 1 轮 ACT 里没有 (2,25)）
CATCH_ACTS = {(2, 26), (2, 27)}
CATCH_ACTS_13 = {(2, 25), (2, 26), (2, 27)}     # 1.3 及以前的口径：只用来数「改判了几次」
RECOIL_ACT = (2, 25)
SUB_RECOIL25 = "进 (2,25)"

# 怪物「受击类」动作类名（INTERRUPTED 子类用）。预注册：类名含下列词之一。
REACT_RE = re.compile(r"(?i)(damage|flinch|stagger|knockback|stun|faint)")

# 关键枚举的默认数值：2026-10-10 用只读脚本解析 REFramework.NET.application.dll 元数据得到
# （HunterDef.PARRY_STATE、AttackAreaResult.RESULT_TYPE、HitDef.DAMAGE_TYPE、Hit.GUARD_TYPE、
#  TARGET_ACCESS_KEY.CATEGORY）。探针 HDR 的 enums 串能解析时以它为准。
ENUMS = {
    "RT": {"SAFE": 0, "CAUTION": 1, "DANGER": 2},
    "PS": {"NONE": 0, "WAIT": 1, "HIT": 2, "SUCCESS": 3, "RECOIL": 4},
    "DT": {"QUAKE": 1, "EAR": 2, "WIND": 4},
    # 1.4：GUARD_TYPE 5 个值（V16 第 3.1 节：APCal HDR 读到 NORMAL 0、ALL_RANGE 1、UNABLE_GUARD 2、SKILL_GUARD 3、
    # SKILL_GUARD_ALL_RANGE 4）。ENT 一般写名字，写成数字时按这张表认
    "GUARD": {"NORMAL": 0, "ALL_RANGE": 1, "UNABLE_GUARD": 2, "SKILL_GUARD": 3, "SKILL_GUARD_ALL_RANGE": 4},
    "CAT": {"PLAYER": 0, "ENEMY": 1, "OTOMO": 2, "PORTER": 3, "NPC": 5},
}
EFFECT_DT = ("EAR", "WIND", "QUAKE")

# ---------------------------------------------------------------- 记录字段表
# 以 CONTRACT 3.4 / 4.2 为准。类型：n 浮点 i 整数 b 布尔 s 字符串 a 地址(十六进制串)
# act 动作 (c,i) e 枚举（数字或名字，名字统一大写）
SCHEMA_SPEC = {
    "rc": {
        # 1.4：v1.6 追加 rule（E5c）、filter（g1）、cfg_ver、c_lo、c_hi（V16 第 6.1 节）；旧版本没有，读出来是 None
        # 1.5：合并版（AutoGuardGS v1.5）追加 host（写放刀记录的脚本，例如 AutoGuardGS-v1.5）、enum_skip（加载时没读到的抓取名 /
        # 黑名单名，都读到写 -），删了 rotation、scan、cfg_ver（读出来是 None）。ver 仍是放刀规则版本（1.6）
        "HDR": "ver:s session:i auto_parry:b lead:n rotation:s scan:b L_min:n W_long:n H_veto:n credit:n "
               "rule:s filter:s cfg_ver:i c_lo:n c_hi:n host:s enum_skip:s",
        # 1.4：v1.6 追加 E5c 的字段（V16 第 6.2 节）：C1 首帧 C、Cf 放刀帧 C（读不到写 -）、mf 算 Q0 用的 m、nchg m 变过几次、
        # dX = X − X0_e、A0 触发条目首次读到的 hs、Q0 放刀帧的 Q、Qp 上一个帧回调的 Q（穿越判断）、Qe1 影子 E1、mode、vq
        "FIRE": "id:i t:n L:n R0:n he0:n src:s ent:a res:a em:s keep:act from:act "
                "C1:n Cf:n mf:n nchg:i dX:n A0:n Q0:n Qp:n Qe1:n mode:s vq:b",
        "FIRE_END": "id:i t:n R1:n n:i entered:b",
        # 1.3：v1.5.1 在原字段后追加 why（long 长窗口 / grab 抓取，取触发 hs 最小的那条）；更早的版本没有，读出来是 None
        # 1.4：v1.6 的 why 多一个 sg（SKILL_GUARD 家族、伤害类型不是抓取）
        "VETO": "t:n hs:n he:n res:a ent:a em:s why:s",
        # 1.4：v1.6 追加 to（离开 (2,23)/(2,24) 后的第一个动作，(c,i)；没离开写 -），outcome 分 CATCH26 / CATCH27 / RECOIL / NOCATCH
        # 1.5：合并版删了 FIRE_END，它的 entered 追加在 RES 末尾（1 = 这一刀进了 (2,23)）
        "RES": "id:i t:n outcome:s dt:n to:act entered:b",
        "SCAN": "id:i t:n phase:s X:n t0:n Dc:n t_req:n status:s reason:s",
        # STAT：CONTRACT 3.4 的 6 个字段之后，rc 追加了 red yellow lua_ms_avg lua_ms_max hook_ms_ps readfail；
        # v1.5 再追加 replica（登记时判为联机副本的预告结果数）、readerr（出过逐条读取错误的预告结果数）；
        # closest 兜底删了，fb 恒为 0。按字段名取值，缺的字段是 None，新旧版本（以及不写 fb 的写法）的 STAT 都能读
        # 1.4：v1.6 再追加 recoils speedfail speedhold clockskip vetoq fclosed excl uview sidmis（V16 第 6.3 节）
        "STAT": "fires:i catches:i vetoes:i fb:i failopen:i errors:i red:i yellow:i lua_ms_avg:n lua_ms_max:n "
                "hook_ms_ps:n readfail:i replica:i readerr:i "
                "recoils:i speedfail:i speedhold:i clockskip:i vetoq:i fclosed:i excl:i uview:i sidmis:i",
        "ERR": "mod:s level:s msg:s",
        "RED": "t:n mod:s why:s",
        # v1.5 新增（V15 第 4 节）：启用开关或提前量滑块每次改动写一行（总写日志和 JSON，不受 debug_log 控制）。
        # D 节「验收只用第一次改动之前的数据」用它截断（见 rc_config）
        "CFG": "t:n auto_parry:b lead:n",
        # 1.4（v1.6 新增，V16 第 6.1 节）：放刀 streak 第一帧视野内有「不该接」的非弹体条目（pb=1 或 UNABLE_GUARD）时紧跟
        # FIRE 写一行（id = FIRE 的 id，U 里 hs 最小的那条；why = pb 优先，否则 ug；same = 和触发条目同一个结果）
        "UVIEW": "id:i t:n hs:n he:n why:s em:s keep:act same:b res:a ent:a",
        # 1.4（v1.6 新增）：蓄力中、条目进了窗口（L_min ≤ Q ≤ L、0 ≤ he−hs ≤ 60、DANGER、不是副本）却被该接过滤挡掉，
        # why ∈ {pb, ug, fc}；每个结果的每条条目一次
        "SKIP": "t:n why:s hs:n he:n Q:n em:s keep:act res:a ent:a",
    },
    "pr": {
        "HDR": "ver:s session:i net:s guard_deg:n aim_deg:n overheat_parry:n cfg_guard:s cfg_parry:s enums:s",
        "SELFTEST": "stage:i ok:i total:i failed:s",
        "HITCH": "t:n f:i dt:n",
        "GAP": "t:n f:i dt:n",
        "PERF": "t:n fps:n maxdt:n hooks:s lua_ms_avg:n lua_ms_max:n tracked:i red:i yellow:i hook_ms_ps:n actfail:i "
                "red_state:b",
        "MSG": "t:n f:i obj:a new:b tme:b em:s keep:act rt:e n:i mstart:n mend:n closest:a fin:b",
        "TYP": "t:n f:i obj:a ent:a type:e hs:n he:n",
        "SER": "t:n f:i obj:a ent:a type:e hs:n he:n charge:b",
        "ENT": "obj:a ent:a idx:i closest:b shell:s reqset:s guard:e dmgtype:e dmglv:n filter:s vguard:n "
               "pbreak:b pfix:b pstock:b tgbreak:b block:b name:s",
        "ACT": "t:n f:i from:act to:act from_name:s to_name:s raw_prev:n raw_new:n chara_new:n",
        "ARM": "t:n f:i act:act sa:b ha:b nd:b raw:n",
        "PT": "id:i t_obs:n raw0:n t_start:n from:act hold:n lv:s contacts_blade:i contacts_body:i ph:s ps:s "
              "hit_t:n hit_idx:s recoil:b emhit:b dmg:n online_class:s",
        "CT": "t:n f:i k:i atk:s atk_em:s dmgobj:s layer:s cls:s ps:e res:s act:act raw:n sa:b shell:b px:n py:n pz:n",
        "DMG": "t:n total:n react:s",
        "PH": "t:n state:e target:s raw:n chara:n delay:n",
        "PS": "t:n state:e",
        "PMSG": "t:n state:e",
        "EMPARRY": "t:n em:s ap:a",
        "EMHIT": "t:n raw:n chara:n dmgobj:s layer:s em:s",
        "EMSTATE": "t:n em:s act:s",
        "EMINFO": "t:n em:s when:s tgt:s speed_t:n speed_f:n ts:n master:b x:n y:n z:n",
        "ATK": "t:n em:s a4:s a5:s",
        "SIG": "t:n name:s val:s raw:n chara:n frame:n",
        "ANIM": "t:n raw:n frame:n speed:n motion:s",
        "HOLD": "t:n n:i addrs:s",
        "POSE": "t:n when:s px:n pz:n fx:n fz:n ex:n ez:n theta:n dist:n",
        "EP": "id:i obj:a epoch:i em:s keep:act reason:s n_msg:i first_type:e first_hs:n types:s rate_med:n "
              "rate_min:n rate_max:n stall:i maxdt:n charge_all:b atk_on:b t0:n t1:n",
        "PROG": "t:n phase:s swings:i scan_pt:i b_pt:i b_contact:i b_danger:i",
        "ERR": "mod:s level:s msg:s",
        "RED": "t:n mod:s why:s",
        # 表外、探针头注释约定的标记行：「停止记录」区间（菜单开关或加载满 90 分钟自停，P22）。
        # 区间内探针什么都不记，放刀的结局不能按「没看到接触」判（见 classify_fire）
        "STOP": "t:n why:s",
        "RESUME": "t:n why:s",
    },
}
# 日志里约定的辅助行：rc 的 DBG（配置 debug_log，CONTRACT 3.1）只给人看，不解析，只在报告里计数
AUX_LOG_KINDS = {("rc", "DBG")}
SCHEMA = {src: {k: [tuple(x.split(":")) for x in spec.split()] for k, spec in kinds.items()}
          for src, kinds in SCHEMA_SPEC.items()}
JSON_ONLY = {"SER", "ANIM", "HOLD"}          # ★：只进 JSON，不打日志
TAG2SRC = {"APCal": "pr", "AutoParryGS": "rc"}
SRC2TAG = {v: k for k, v in TAG2SRC.items()}

# ---------------------------------------------------------------- 取值转换
_NIL = {"", "-", "nil", "none", "null", "nan", "inf", "-inf", "?"}
_ACT_RE = re.compile(r"^\(?\s*(-?\d+)\s*[,_:/]\s*(-?\d+)\s*\)?")


def _is_nil(v):
    return v is None or (isinstance(v, str) and v.strip().lower() in _NIL)


def to_num(v):
    if isinstance(v, bool):
        return 1.0 if v else 0.0
    if _is_nil(v):
        return None
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if math.isfinite(f) else None


def to_int(v):
    f = to_num(v)
    return None if f is None else int(round(f))


def to_bool(v):
    if isinstance(v, bool):
        return v
    if _is_nil(v):
        return None
    if isinstance(v, (int, float)):
        return v != 0
    s = str(v).strip().lower()
    if s in ("1", "true", "yes", "on", "t", "y"):
        return True
    if s in ("0", "false", "no", "off", "f", "n"):
        return False
    f = to_num(s)
    return None if f is None else f != 0


def to_str(v):
    if _is_nil(v):
        return None
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    if isinstance(v, bool):
        return "1" if v else "0"
    return str(v)


def to_addr(v):
    if _is_nil(v):
        return None
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        v = int(v)
        return None if v == 0 else format(v, "X")
    s = str(v).strip()
    if s.lower().startswith("0x"):
        s = s[2:]
    s = s.upper()
    return None if s in ("", "0") else s


def to_act(v):
    if _is_nil(v):
        return None
    if isinstance(v, (list, tuple)) and len(v) >= 2:
        a, b = to_int(v[0]), to_int(v[1])
        return None if a is None or b is None else (a, b)
    if isinstance(v, dict):
        a = next((v[k] for k in ("c", "cat", "_Category", "category") if k in v), None)
        b = next((v[k] for k in ("i", "idx", "_Index", "index") if k in v), None)
        a, b = to_int(a), to_int(b)
        return None if a is None or b is None else (a, b)
    m = _ACT_RE.match(str(v).strip())
    return (int(m.group(1)), int(m.group(2))) if m else None


def to_enum(v):
    """枚举值：数字保留为 int（按 ENUMS 映射时再解释），名字统一大写。"""
    if _is_nil(v):
        return None
    if isinstance(v, bool):
        return int(v)
    if isinstance(v, (int, float)):
        return int(v)
    s = str(v).strip()
    f = to_num(s)
    if f is not None and re.fullmatch(r"-?\d+(\.0+)?", s):
        return int(f)
    return s.upper()


CONVERT = {"n": to_num, "i": to_int, "b": to_bool, "s": to_str, "a": to_addr, "act": to_act, "e": to_enum}


def enum_is(v, table, name):
    """v 是不是枚举 table 里的 name（v 可能是名字也可能是数值）。"""
    if v is None:
        return False
    if isinstance(v, str):
        return v.upper() == name or v.upper().endswith("." + name)
    return ENUMS[table].get(name) == v


def is_danger(v):
    return enum_is(v, "RT", "DANGER")


ENUM_GROUPS = {"RT": "RT", "RESULT_TYPE": "RT", "PS": "PS", "PARRY_STATE": "PS", "DT": "DT", "DAMAGE_TYPE": "DT",
               "GT": "GUARD", "GUARD_TYPE": "GUARD", "GUARD": "GUARD", "TAK": "CAT", "CATEGORY": "CAT"}


def update_enums_from_hdr(enums_str):
    """探针 HDR 的 enums 是「关键枚举数值的紧凑串」。探针实现写成 RT{SAFE:0,CAUTION:1,DANGER:2};PS{...}，
    也兼容 RESULT_TYPE:SAFE=0,... 这种。组名认缩写（RT/PS/DT/GT/TAK）和全名；值为 ? 的跳过。
    解析不出来就保留默认（默认值本身来自游戏元数据）。"""
    if not enums_str:
        return 0
    hits = 0
    for seg in re.split(r"[;|]", str(enums_str)):
        m = re.match(r"\s*([A-Za-z_.]+)", seg)
        if not m:
            continue
        group = m.group(1).upper().split(".")[-1]
        table = ENUM_GROUPS.get(group)
        if table is None:
            continue
        for name, val in re.findall(r"([A-Z][A-Z0-9_]*)\s*[:=]\s*(-?\d+)", seg[m.end():]):
            if table != "DT" or name in EFFECT_DT:
                ENUMS[table][name] = int(val)
                hits += 1
    return hits


# CT 的「本帧第几次」字段名也叫 k，和 JSON 记录的种类键 "k" 撞名（CONTRACT 2 与 4.2 的歧义）。
# 内部改存为 kn；JSON 里如果 k 被它覆盖成数字，种类按字段签名推断（见 json_kind）。
FIELD_RENAME = {("CT", "k"): "kn"}
_KIND_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")


def json_kind(src, raw):
    v = raw.get("k")
    if isinstance(v, str) and _KIND_RE.match(v.strip()):
        return v.strip().upper()
    for key in ("kind", "K", "_k"):
        v = raw.get(key)
        if isinstance(v, str) and _KIND_RE.match(v.strip()):
            return v.strip().upper()
    keys = set(raw) - {"k", "kind", "K", "_k"}
    scored = []
    for kind, fields in SCHEMA.get(src, {}).items():
        names = {n for n, _t in fields} - {"k"}
        if names:
            scored.append((len(keys & names) / len(keys | names), kind))
    scored.sort(reverse=True)
    if scored and scored[0][0] >= 0.5 and (len(scored) == 1 or scored[0][0] - scored[1][0] >= 0.15):
        return scored[0][1]
    return None


def convert_record(src, kind, raw, origin):
    """把一条原始记录（JSON dict 或日志 k=v）按字段表转换成统一的 dict。"""
    rec = {"k": kind, "_src": src, "_o": origin}
    schema = SCHEMA.get(src, {}).get(kind)
    known = {"k"}
    if schema:
        for name, typ in schema:
            dst = FIELD_RENAME.get((kind, name), name)
            val = raw.get(name)
            if dst != name:
                known.add(dst)
                # JSON 里 k 是种类名时，这个字段可能被探针改名存放
                if origin == "json" and isinstance(val, str) and _KIND_RE.match(val.strip()):
                    val = raw.get(dst, raw.get("kk"))
            known.add(name)
            rec[dst] = CONVERT[typ](val)
    if "t" not in known:
        rec["t"] = to_num(raw.get("t"))   # JSON 记录按 CONTRACT 总带 t；日志里没有就是 None
        known.add("t")
    for k, v in raw.items():          # 字段表以外的字段原样保留（探针可能多记了东西）
        if k not in known and not k.startswith("_"):
            rec[k] = v
    return rec


# ---------------------------------------------------------------- 读取：JSON
_FN_RE = re.compile(r"^(APCal|AutoParryGS)_(\d+)_(\d+)\.json$", re.I)


def find_json_files(data_dir):
    out = []
    for root, _dirs, files in os.walk(data_dir):
        depth = os.path.relpath(root, data_dir).count(os.sep)
        if depth > 3:
            continue
        for fn in files:
            m = _FN_RE.match(fn)
            if m:
                tag = "APCal" if m.group(1).lower() == "apcal" else "AutoParryGS"
                out.append((TAG2SRC[tag], int(m.group(2)), int(m.group(3)), os.path.join(root, fn)))
    return out


def load_json_files(files, problems):
    """返回 {(src, session): [record, ...]}，同一 session 内按 seq、文件内顺序排列。"""
    by_key = defaultdict(list)
    for src, sess, seq, path in files:
        try:
            with open(path, "r", encoding="utf-8-sig") as fh:
                doc = json.load(fh)
        except (OSError, ValueError) as e:
            problems.append(f"JSON 读不了：{os.path.basename(path)}（{e}）")
            continue
        why = None
        if isinstance(doc, dict):
            sess = to_int(doc.get("session")) or sess
            seq = to_int(doc.get("seq")) or seq
            recs = doc.get("records")
            why = to_str(doc.get("why"))
        else:
            recs = doc
        if not isinstance(recs, list):
            problems.append(f"JSON 结构不对（没有 records 数组）：{os.path.basename(path)}")
            continue
        by_key[(src, sess)].append((seq, path, recs, why))
    out = {}
    for key, items in by_key.items():
        items.sort(key=lambda x: x[0])
        seqs = [s for s, _p, _r, _w in items]
        whys = [(s, w) for s, _p, _r, w in items]
        recs = []
        n_infer = n_drop = 0
        for seq, path, rs, _why in items:
            for raw in rs:
                if not isinstance(raw, dict):
                    n_drop += 1
                    continue
                kind = json_kind(key[0], raw)
                if kind is None:
                    n_drop += 1
                    continue
                if not (isinstance(raw.get("k"), str) and raw["k"].strip().upper() == kind):
                    n_infer += 1
                rec = convert_record(key[0], kind, raw, "json")
                rec["_seq"] = seq
                recs.append(rec)
        if n_infer:
            problems.append(f"{SRC2TAG[key[0]]} session {key[1]}：{n_infer} 条 JSON 记录的种类键 k 不是种类名"
                            f"（多半是 CT 的 k 字段覆盖了它），已按字段签名推断")
        if n_drop:
            problems.append(f"{SRC2TAG[key[0]]} session {key[1]}：{n_drop} 条 JSON 记录认不出种类，已跳过")
        out[key] = {"records": recs, "seqs": seqs, "files": [p for _s, p, _r, _w in items], "whys": whys}
    return out


# ---------------------------------------------------------------- 读取：日志兜底
_LOG_RE = re.compile(r"\[(APCal|AutoParryGS)\]\s+([A-Z][A-Z0-9_]*)(?:\s+(.*))?$")
# 日志里和「崩溃」有关的行（只扫所选 session 的范围，见 session_log_events）。
# 以前对整份日志做 (unhandled exception|access violation|exception_access|crash) 匹配：REF 启动时拷贝/加载
# CrashHandler.dll、CrashReportDll.dll，IntegrityCheckBypass 的 crasher_fn，被 REF 截住的 VMContext 访问冲突
# （HitboxViewer 等引起）全都会命中——当前游戏日志里已有 17 行，C9(d) 永远判「有崩溃」（审查 measurement-critical）。
# 现在分三类：
#   crash      真崩溃迹象（REF 的未处理异常处理器、崩溃转储），排除上面那些启动行
#   caught_av  REF 截住并转成 Lua 错误的访问冲突（VMContext: Caught exception），只作警告，附时间和方法名
#   release    「REManagedObject:release attempted to release an object that was not managed by our Lua state」
#              （两个脚本各自 add_ref/release 同一对象时可能出现；Reset 时出现的另计）
#   reload     ScriptRunner 重新加载脚本（Reset Scripts）
_CRASH_RE = re.compile(r"(?i)(unhandled exception|reframework_crash|crash ?dump|minidump|fatal error)")
_CRASH_EXCLUDE_RE = re.compile(r"(?i)(crashhandler|crashreport|crasher_fn|crasher fn)")
_CAUGHT_AV_RE = re.compile(r"VMContext: Caught exception")
_AV_METHOD_RE = re.compile(r"Exception thrown in REMethodDefinition::invoke for (\S+)")
_RELEASE_WARN_RE = re.compile(r"REManagedObject:release attempted to release an object that was not managed")
_RELOAD_RE = re.compile(r"\[ScriptRunner\] Loading scripts")
_TS_RE = re.compile(r"^\[(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d(?:\.\d+)?)\]")


def log_ts(line):
    """日志行开头的时间戳 → 当天秒数（只用来比先后和算间隔）；没有就 None。"""
    m = _TS_RE.match(line)
    if not m:
        return None
    return int(m.group(4)) * 3600 + int(m.group(5)) * 60 + float(m.group(6))


def find_log_file(data_dir, explicit):
    if explicit:
        return explicit if os.path.isfile(explicit) else None
    cands = []
    d = os.path.abspath(data_dir)
    for _ in range(3):   # 数据目录、上一级、上两级（游戏目录下 reframework/data 的上两级就是日志所在）
        for name in ("re2_framework_log.txt", "ref.log"):
            cands.append(os.path.join(d, name))
        d = os.path.dirname(d)
    for c in cands:
        if os.path.isfile(c):
            return c
    return None


class LogInfo:
    """parse_log 的结果：记录（按 (src, session) 分）、每个 session 第一行 HDR 的行号、和崩溃有关的事件行。"""

    def __init__(self):
        self.recs = defaultdict(list)
        self.hdr_line = {}          # (src, session) -> 第一行 HDR 的行号
        self.events = []            # Obj(line, ts, kind, text, method)
        self.n_lines = 0
        self.path = None
        # 1.4：约定的辅助行（rc 的 DBG）按 k=v 拆开另存，不进记录表、不参与合并去重（报告头的计数不变）。
        # 只用来按怪数 v1.6 的 DBG ev=speed_fail（idx = EmSystemIndex；调试日志关着时没有）
        self.aux = defaultdict(list)


def parse_log(path, problems, notes=None):
    """返回 LogInfo。session 按每个脚本最近一行 HDR 切分；HDR 之前的行归到 session=None。
    值里没有空格（CONTRACT 2），按空格切 k=v。崩溃相关的行只记下来，按 session 范围筛选在 session_log_events。"""
    info = LogInfo()
    info.path = path
    unknown = Counter()
    aux = Counter()
    cur = {"pr": None, "rc": None}
    try:
        fh = open(path, "r", encoding="utf-8", errors="replace")
    except OSError as e:
        problems.append(f"日志读不了：{e}")
        return info
    last_av = None
    with fh:
        for lineno, line in enumerate(fh, 1):
            line = line.rstrip("\r\n")
            info.n_lines = lineno
            m = _LOG_RE.search(line)
            if not m:
                kind = None
                if _CAUGHT_AV_RE.search(line):
                    kind = "caught_av"
                elif _RELEASE_WARN_RE.search(line):
                    kind = "release"
                elif _RELOAD_RE.search(line):
                    kind = "reload"
                elif _CRASH_RE.search(line) and not _CRASH_EXCLUDE_RE.search(line):
                    kind = "crash"
                if kind:
                    ev = Obj(line=lineno, ts=log_ts(line), kind=kind, text=line[:200], method=None)
                    info.events.append(ev)
                    if kind == "caught_av":
                        last_av = ev
                elif last_av is not None and lineno - last_av.line < 200:
                    mm = _AV_METHOD_RE.search(line)
                    if mm and last_av.method is None:
                        last_av.method = mm.group(1)
                continue
            src, kind, rest = TAG2SRC[m.group(1)], m.group(2), m.group(3) or ""
            if kind not in SCHEMA[src]:
                if (src, kind) in AUX_LOG_KINDS:
                    aux[(src, kind)] += 1
                    raw = {"k": kind, "_line": lineno}
                    for tok in rest.split():
                        k_, eq_, v_ = tok.partition("=")
                        if eq_ and k_:
                            raw[k_] = v_
                    info.aux[(src, cur[src])].append(raw)
                else:
                    unknown[(src, kind)] += 1
                continue
            raw = {}
            for tok in rest.split():
                k, eq, v = tok.partition("=")
                if eq and k:
                    raw[k] = v
            rec = convert_record(src, kind, raw, "log")
            rec["_line"] = lineno
            if kind == "HDR" and rec.get("session") is not None:
                cur[src] = rec["session"]
                info.hdr_line.setdefault((src, cur[src]), lineno)
            info.recs[(src, cur[src])].append(rec)
    if unknown:
        problems.append("日志里不在 CONTRACT 记录表中的行（未解析）：" +
                        "，".join(f"[{SRC2TAG[s_]}] {k_} {n_}" for (s_, k_), n_ in unknown.most_common(8)))
    if aux and notes is not None:
        notes.append("约定的辅助行（不在 CONTRACT 记录表里，不解析）：" +
                     "，".join(f"[{SRC2TAG[s_]}] {k_} {n_} 行" for (s_, k_), n_ in aux.most_common(8)))
    return info


def session_log_range(loginfo, chosen):
    """所选 session 在日志里的行号范围 [起, 止)：起 = 这一对 session 里最早的那行 HDR，
    止 = 之后任何别的 session 的第一行 HDR（Reset 重新加载）或文件尾。日志里没有这个 session 的 HDR 时返回 None。"""
    starts = [loginfo.hdr_line[(src, s)] for src, s in chosen.items() if s is not None and (src, s) in loginfo.hdr_line]
    if not starts:
        return None
    a = min(starts)
    mine = {(src, s) for src, s in chosen.items() if s is not None}
    later = [ln for key, ln in loginfo.hdr_line.items() if key not in mine and ln > a]
    return (a, min(later) if later else loginfo.n_lines + 1)


def session_log_events(loginfo, rng):
    """把崩溃相关事件按 session 范围筛出来，并把 release 告警分成「Reset 时」和「其他时候」。"""
    out = Obj(range=rng, crash=[], caught_av=[], release_reset=[], release_other=[], scoped=rng is not None)
    if rng is None:
        return out
    a, b = rng
    # Reset 时刻：范围内外的 ScriptRunner 重新加载行都算（本 session 结束时的那次在范围末尾之后几行）
    reload_ts = [e.ts for e in loginfo.events if e.kind == "reload" and e.ts is not None]
    for e in loginfo.events:
        if not (a <= e.line < b):
            continue
        if e.kind == "crash":
            out.crash.append(e)
        elif e.kind == "caught_av":
            out.caught_av.append(e)
        elif e.kind == "release":
            at_reset = e.ts is not None and any(0.0 <= r - e.ts <= 1.0 for r in reload_ts)
            (out.release_reset if at_reset else out.release_other).append(e)
    return out


# ---------------------------------------------------------------- 合并与 session 选择
def _same_value(a, b):
    if a is None or b is None:
        return True        # 一边缺字段不算冲突
    fa, fb = to_num(a) if not isinstance(a, tuple) else None, to_num(b) if not isinstance(b, tuple) else None
    if fa is not None and fb is not None:
        return abs(fa - fb) <= 1e-3 * max(1.0, abs(fa), abs(fb))
    return str(a).replace(" ", "_") == str(b).replace(" ", "_")


def _first_field_value(r):
    schema = SCHEMA.get(r.get("_src"), {}).get(r["k"])
    if not schema:
        return None
    name = FIELD_RENAME.get((r["k"], schema[0][0]), schema[0][0])
    v = r.get(name)
    return round(v, 3) if isinstance(v, float) else v


def merge_sources(json_recs, log_recs):
    """JSON 为主；日志里找不到对应 JSON 记录的行补进来（比如某个 seq 的文件丢了、或崩溃前没写出）。
    对应关系：同 KIND 且 t 相差 ≤0.6 ms（日志 t 是 %.4f），有 id 的还要 id 相同；
    没有 t 的 KIND（ENT、HDR、STAT 等）要求日志行里的每个字段都与某条 JSON 记录相同。"""
    by_kind_t = defaultdict(list)
    by_first = defaultdict(list)       # (KIND, 首字段值) -> JSON 记录：无 t 的日志行按它找候选，免得两两比较
    for r in json_recs:
        if r.get("t") is not None:
            by_kind_t[r["k"]].append((r["t"], r))
        by_first[(r["k"], _first_field_value(r))].append(r)
    for v in by_kind_t.values():
        v.sort(key=lambda x: x[0])
    keys_t = {k: [x[0] for x in v] for k, v in by_kind_t.items()}
    added = []
    for r in log_recs:
        kind = r["k"]
        dup = False
        if r.get("t") is not None and kind in keys_t:
            ts = keys_t[kind]
            i = bisect.bisect_left(ts, r["t"] - 6e-4)
            while i < len(ts) and ts[i] <= r["t"] + 6e-4:
                j = by_kind_t[kind][i][1]
                if r.get("id") is None or j.get("id") is None or r.get("id") == j.get("id"):
                    dup = True
                    break
                i += 1
        elif r.get("t") is None:
            fields = [k for k in r if not k.startswith("_") and k not in ("k", "t")]
            for j in by_first.get((kind, _first_field_value(r)), []):
                if all(_same_value(r.get(f), j.get(f)) for f in fields):
                    dup = True
                    break
        if not dup:
            added.append(r)
    return json_recs + added, len(added)


def select_sessions(json_by_key, log_by_key, want):
    """默认取最新 session；两个脚本各自的 session 取离目标最近、且相差 ≤120 s 的那个。"""
    sessions = defaultdict(set)
    for (src, sess) in list(json_by_key) + list(log_by_key):
        if sess is not None:
            sessions[src].add(sess)
    allsess = sessions["pr"] | sessions["rc"]
    if want is not None:
        target = want
    elif allsess:
        target = max(allsess)
    else:
        target = None
    chosen = {}
    for src in ("pr", "rc"):
        cands = [s for s in sessions[src] if target is not None and abs(s - target) <= SESSION_PAIR_TOL]
        chosen[src] = min(cands, key=lambda s: (abs(s - target), -s)) if cands else None
    return target, chosen, {k: sorted(v) for k, v in sessions.items()}


class Data:
    """合并后的记录：data.get(src, kind) 按 t 排序（没有 t 的保持原顺序，排在最后）。"""

    def __init__(self):
        self.by = defaultdict(list)
        self.info = {"files": [], "log": None, "target": None, "chosen": {}, "sessions": {}, "notes": [],
                     "log_added": {}, "used_log_only": {}, "problems": [], "crash": [], "seqs": {},
                     "log_events": session_log_events(LogInfo(), None), "json_why": {}, "dbg": []}

    def get(self, src, kind):
        return self.by[(src, kind)]

    def count(self):
        return sum(len(v) for v in self.by.values())


def display_path(p):
    """报告里显示的路径：绝对路径、统一正斜杠。同一份数据用相对或绝对路径调用，报告头一字不差（回归比对用）。"""
    return None if not p else os.path.abspath(p).replace("\\", "/")


def load_all(data_dir, log_path=None):
    """读数据目录里的全部 JSON 和日志（一次），供按 session 组装 Data。"""
    problems, notes = [], []
    files = find_json_files(data_dir) if data_dir and os.path.isdir(data_dir) else []
    json_by_key = load_json_files(files, problems)
    lp = find_log_file(data_dir or ".", log_path)
    loginfo = parse_log(lp, problems, notes) if lp else LogInfo()
    return Obj(files=files, json_by_key=json_by_key, log=display_path(lp), loginfo=loginfo, problems=problems,
               notes=notes)


def load_data(data_dir, log_path=None, session=None):
    """一个 session 的数据（默认最新）。多个 session 用 load_all + session_data。"""
    return session_data(load_all(data_dir, log_path), session)


def session_data(src_all, session=None):
    data = Data()
    problems = data.info["problems"]
    problems.extend(src_all.problems)
    data.info["notes"].extend(src_all.notes)
    files, json_by_key, loginfo = src_all.files, src_all.json_by_key, src_all.loginfo
    log_by_key = loginfo.recs
    data.info["log"] = src_all.log
    # 日志里完全没有 HDR 的脚本：它的行都在 session=None 里，只好整体认作目标 session
    target, chosen, sessions = select_sessions(json_by_key, log_by_key, session)
    data.info.update(target=target, chosen=chosen, sessions=sessions)
    data.info["files"] = [os.path.basename(p) for src, ss, _q, p in files if chosen.get(src) == ss]
    rng = session_log_range(loginfo, chosen)
    ev = session_log_events(loginfo, rng)
    data.info["log_events"] = ev
    data.info["crash"] = [(e.line, e.text) for e in ev.crash]
    for src in ("pr", "rc"):
        sess = chosen[src]
        jr = json_by_key.get((src, sess), {}).get("records", []) if sess is not None else []
        data.info["seqs"][src] = json_by_key.get((src, sess), {}).get("seqs", []) if sess is not None else []
        whys = json_by_key.get((src, sess), {}).get("whys", []) if sess is not None else []
        data.info["json_why"][src] = whys[-1][1] if whys else None
        lr = list(log_by_key.get((src, sess), [])) if sess is not None else []
        if sess is None or not any(s == src for (s, ss) in log_by_key if ss is not None):
            lr += log_by_key.get((src, None), [])
        if jr:
            recs, n_added = merge_sources(jr, lr)
            data.info["log_added"][src] = n_added
            data.info["used_log_only"][src] = False
        else:
            recs = lr
            data.info["log_added"][src] = len(lr)
            data.info["used_log_only"][src] = bool(lr)
        last_t = None
        keyed = []
        for i, r in enumerate(recs):
            t = r.get("t")
            if t is not None:
                last_t = t
            keyed.append(((t if t is not None else (last_t if last_t is not None else -1e18)), i, r))
        keyed.sort(key=lambda x: (x[0], x[1]))
        for _t, _i, r in keyed:
            data.by[(src, r["k"])].append(r)
    hdr = data.get("pr", "HDR")
    if hdr:
        data.info["enum_hits"] = update_enums_from_hdr(hdr[-1].get("enums"))
    # 1.4：rc 的 DBG 行（只在日志里，调试日志开着才有），按 session 取出来备用
    aux = getattr(loginfo, "aux", {}) or {}
    data.info["dbg"] = [r for r in aux.get(("rc", chosen.get("rc")), []) if r.get("k") == "DBG"] \
        if chosen.get("rc") is not None else []
    return data


# ---------------------------------------------------------------- 统计工具
def median(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def quantile(xs, q):
    """线性插值分位数（type 7，与 numpy 默认一致）。"""
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    if len(xs) == 1:
        return xs[0]
    pos = (len(xs) - 1) * q
    lo = int(math.floor(pos))
    hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (pos - lo)


def iqr(xs):
    a, b = quantile(xs, 0.25), quantile(xs, 0.75)
    return None if a is None else b - a


def _ranks(xs):
    order = sorted(range(len(xs)), key=lambda i: xs[i])
    ranks = [0.0] * len(xs)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and xs[order[j + 1]] == xs[order[i]]:
            j += 1
        avg = (i + j) / 2.0 + 1.0
        for k in range(i, j + 1):
            ranks[order[k]] = avg
        i = j + 1
    return ranks


def pearson(xs, ys):
    n = len(xs)
    if n < 3:
        return None
    mx, my = sum(xs) / n, sum(ys) / n
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    sxx = sum((x - mx) ** 2 for x in xs)
    syy = sum((y - my) ** 2 for y in ys)
    if sxx <= 0 or syy <= 0:
        return None
    return sxy / math.sqrt(sxx * syy)


def spearman(xs, ys):
    if len(xs) < 3:
        return None
    return pearson(_ranks(xs), _ranks(ys))


def theil_sen(xs, ys):
    """斜率取两两斜率的中位数：样本少、有离群点时比最小二乘稳。"""
    sl = [(ys[j] - ys[i]) / (xs[j] - xs[i]) for i in range(len(xs)) for j in range(i + 1, len(xs))
          if xs[j] != xs[i]]
    return median(sl)


def wilson(k, n, z=1.2816):
    """Wilson 区间，默认 z=1.2816 即双侧 80%。"""
    if not n:
        return None, None
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return max(0.0, c - h), min(1.0, c + h)


def _binom_cdf(k, n, p):
    """P(X ≤ k)，X ~ Binomial(n, p)；按对数逐项相加（n 到几千都不会溢出）。"""
    if k < 0:
        return 0.0
    if k >= n or p <= 0.0:
        return 1.0
    if p >= 1.0:
        return 0.0
    lp, lq, lc = math.log(p), math.log1p(-p), math.lgamma(n + 1)
    s = 0.0
    for i in range(k + 1):
        s += math.exp(lc - math.lgamma(i + 1) - math.lgamma(n - i + 1) + i * lp + (n - i) * lq)
    return min(1.0, s)


def clopper_pearson(k, n, conf=0.90):
    """1.4（V16 第 7 节第 4 条：接住率、纯空挥率给 90% Clopper–Pearson 区间）：精确二项区间，二分求根。n=0 返回 (None, None)。"""
    if not n:
        return None, None
    a = (1.0 - conf) / 2.0

    def root(f):        # f 在 [0, 1] 上单调增，求 f(p) = 0
        lo, hi = 0.0, 1.0
        for _ in range(80):
            mid = (lo + hi) / 2.0
            if f(mid) < 0.0:
                lo = mid
            else:
                hi = mid
        return (lo + hi) / 2.0
    lower = 0.0 if k <= 0 else root(lambda p: (1.0 - _binom_cdf(k - 1, n, p)) - a)
    upper = 1.0 if k >= n else root(lambda p: a - _binom_cdf(k, n, p))
    return lower, upper


def logistic_x50(xs, ys, iters=60):
    """y∈{0,1} 对 x 做 logistic 回归（Newton，带极小岭项防发散），返回 P=0.5 的 x；失败返回 None。"""
    if len(set(ys)) < 2 or len(set(xs)) < 2:
        return None
    mx = sum(xs) / len(xs)
    sx = (max(xs) - min(xs)) or 1.0
    zs = [(x - mx) / sx for x in xs]
    a = b = 0.0
    lam = 1e-4
    for _ in range(iters):
        g0 = g1 = h00 = h01 = h11 = 0.0
        for z, y in zip(zs, ys):
            eta = max(-30.0, min(30.0, a + b * z))
            p = 1.0 / (1.0 + math.exp(-eta))
            w = p * (1 - p)
            g0 += y - p
            g1 += (y - p) * z
            h00 += w
            h01 += w * z
            h11 += w * z * z
        g0 -= lam * a
        g1 -= lam * b
        h00 += lam
        h11 += lam
        det = h00 * h11 - h01 * h01
        if det <= 1e-12:
            return None
        da = (h11 * g0 - h01 * g1) / det
        db = (h00 * g1 - h01 * g0) / det
        a += da
        b += db
        if abs(da) + abs(db) < 1e-9:
            break
    if abs(b) < 1e-9:
        return None
    return mx + (-a / b) * sx


def fmt(v, nd=3, unit=""):
    if v is None:
        return "—"
    if isinstance(v, bool):
        return "是" if v else "否"
    if isinstance(v, int):
        return f"{v}{unit}"
    if isinstance(v, float):
        return f"{v:.{nd}f}{unit}"
    return f"{v}{unit}"


def pct(k, n):
    return "—" if not n else f"{100.0 * k / n:.0f}%（{k}/{n}）"


def cp_str(k, n):
    """1.4：k/n = x%（90% 区间 a~b%，Clopper–Pearson）。"""
    lo, hi = clopper_pearson(k, n)
    return "—" if lo is None else f"{k}/{n} = {100.0 * k / n:.0f}%（90% 区间 {100 * lo:.0f}~{100 * hi:.0f}%）"


# ---------------------------------------------------------------- 主角动作时间线
def in_family(a):
    return a is not None and a[0] == 2 and 23 <= a[1] <= 29


class ActTimeline:
    """由 ACT 记录还原「任一时刻主角在哪个动作」。ACT 的 t 是新动作首帧被读到的时刻。"""

    def __init__(self, acts):
        self.acts = [a for a in acts if a.get("t") is not None and a.get("to") is not None]
        self.ts = [a["t"] for a in self.acts]

    def at(self, t):
        i = bisect.bisect_right(self.ts, t) - 1
        if i < 0:
            return self.acts[0].get("from") if self.acts else None
        return self.acts[i]["to"]

    def rec_at(self, t):
        i = bisect.bisect_right(self.ts, t) - 1
        return self.acts[i] if i >= 0 else None

    def changes(self, t0, t1):
        i = bisect.bisect_right(self.ts, t0)
        j = bisect.bisect_right(self.ts, t1)
        return self.acts[i:j]

    def in_charge(self, t):
        return self.at(t) in CHARGE

    def charge_through(self, t0, t1):
        if not self.acts or not self.in_charge(t0):
            return False
        return all(c["to"] in CHARGE for c in self.changes(t0, t1))

    def first(self, t0, t1, pred):
        i = bisect.bisect_left(self.ts, t0)
        while i < len(self.acts) and self.ts[i] <= t1:
            if pred(self.acts[i]):
                return self.acts[i]
            i += 1
        return None

    def leave_family(self, t_from, cap):
        """t_from 之后第一次离开抵消动作族 (2,23..29) 的时刻，最晚 cap。"""
        c = self.first(t_from + 1e-6, cap, lambda a: not in_family(a["to"]))
        return c["t"] if c else cap

    def leave_slash(self, t_from, cap):
        """离开 (2,23) 的时刻（B4 收尾挨打统计到这里），最晚 cap。"""
        c = self.first(t_from + 1e-6, cap, lambda a: a["to"] != SLASH)
        return c["t"] if c else cap


# ---------------------------------------------------------------- 攻击者身份
# 预注册匹配规则要求「攻击者相同」：发送者/攻击者的 EnemyCharacter 地址，退一步用 EmSystemIndex。
# CONTRACT 里预告侧只有 em=em<EmID>#<SystemIndex>，接触侧 CT 是攻击者名/地址和 EnemyCharacter 地址，
# 两边不一定有共同的键。所以分三层：① 直接相同的键；② 同一条记录里同时出现的两种键；
# ③ 共现学习：地址 A 的接触落在 em#idx 回合匹配窗口里的次数占绝对多数（≥2 次且 ≥ 次多者 2 倍；
#    全场只有一只有预告的怪时 1 次即可）。学到的别名表写进报告。
_EM_SYS = re.compile(r"(?i)(?:em)?(\d+)\s*#\s*(\d+)")
_EM_ID = re.compile(r"(?i)^em(\d+)$")
_HEX = re.compile(r"(?i)^(?:0x)?[0-9a-f]{5,16}$")


def ident_keys(*vals):
    keys = set()
    for v in vals:
        if _is_nil(v) or isinstance(v, bool):
            continue
        for part in re.split(r"[@|;]", str(v)):
            part = part.strip()
            if not part or part.lower() in _NIL or "?" in part:
                continue
            m = _EM_SYS.search(part)
            if m:
                keys.add(("sys", int(m.group(2))))
                keys.add(("emid", int(m.group(1))))
                continue
            m = _EM_ID.match(part)
            if m:
                keys.add(("emid", int(m.group(1))))
                continue
            if _HEX.match(part):
                keys.add(("addr", part.upper().replace("0X", "")))
                continue
            keys.add(("name", part))
    return frozenset(keys)


def emid_of(keys):
    for k in keys:
        if k[0] == "emid":
            return k[1]
    return None


class Ident:
    STRONG = ("sys", "addr", "name")

    def __init__(self):
        self.alias = {}       # 非 sys 键 -> ("sys", n)
        self.table = []       # 报告用：(键, sys, 次数, 次多者, 方式)

    def expand(self, keys):
        extra = {self.alias[k] for k in keys if k in self.alias}
        return keys | extra if extra else keys

    def same(self, a, b):
        if not a or not b:
            return False
        A, B = self.expand(a), self.expand(b)
        return any(k in B for k in A if k[0] in self.STRONG)

    def learn(self, contacts, episodes):
        # 键集合是 frozenset，迭代顺序随 Python 的字符串哈希种子变（每次运行都可能不同）：别名表的行序、
        # 并列时 most_common 取哪个都会跟着变。一律按排好序的键迭代，同一份数据每次跑出的报告逐字相同
        sys_all = {k for e in episodes for k in e.keys if k[0] == "sys"}
        co = defaultdict(Counter)
        same_rec = defaultdict(Counter)
        for c in contacts:
            sk = sorted(k for k in c.keys if k[0] == "sys")
            if sk:      # ② 同一条接触记录里既有 em#idx 又有地址/名字：记为别名候选
                for ck in sorted(c.keys):
                    if ck[0] in ("addr", "name"):
                        same_rec[ck][sk[0]] += 1
                continue
            for e in episodes:
                if e.t_hs0 is None or not (e.t_hs0 - MATCH_PRE <= c.t <= e.t_he0 + MATCH_POST):
                    continue
                for sk in sorted(k for k in e.keys if k[0] == "sys"):
                    for ck in sorted(c.keys):
                        if ck[0] in ("addr", "name"):
                            co[ck][sk] += 1
        for ck, cnt in same_rec.items():
            ranked = cnt.most_common()
            if len(ranked) == 1:
                self.alias[ck] = ranked[0][0]
                self.table.append((ck, ranked[0][0], ranked[0][1], 0, "同记录"))
            else:   # 同名的两只同种怪等：一个键对上多个 em#idx，不能用
                self.table.append((ck, ranked[0][0], ranked[0][1], ranked[1][1], "冲突（对上多个 em#idx，不用）"))
        for ck, cnt in co.items():
            if ck in self.alias or ck in same_rec:
                continue
            ranked = cnt.most_common()
            best, nb = ranked[0]
            second = ranked[1][1] if len(ranked) > 1 else 0
            if (nb >= 2 and nb >= 2 * second) or (len(sys_all) == 1 and nb >= 1 and second == 0):
                self.alias[ck] = best
                self.table.append((ck, best, nb, second, "共现"))
            else:
                self.table.append((ck, best, nb, second, "未定（不够多或不占优）"))


# ---------------------------------------------------------------- 组装：接触、条目、回合、放刀、扫描
class Obj:
    def __init__(self, **kw):
        self.__dict__.update(kw)


def contact_class(rec):
    cls = (rec.get("cls") or "").upper()
    if cls in ("BLADE", "BODY", "OTHER"):
        return cls
    layer = str(rec.get("layer") or "").upper()
    if "ATTACK_PARRY_GET" in layer:
        return "BLADE"
    if "ATTACK_GET" in layer:
        return "BODY"
    return "OTHER"


def build_contacts(data):
    out = []
    for r in data.get("pr", "CT"):
        if r.get("t") is None:
            continue
        # atk_em（EnemyCharacter 地址）、atk（攻击者名/地址），探针实现另带 em（em#idx）：三者都算攻击者身份
        out.append(Obj(t=r["t"], cls=contact_class(r), keys=ident_keys(r.get("atk_em"), r.get("atk"), r.get("em")),
                       sa=r.get("sa"), shell=bool(r.get("shell")), rec=r, ep=None, ncand=0, sys_demoted=False))
    return out


def demote_contact_sys(contacts, episodes, data):
    """P23「攻击者相同」在两侧没有共同的地址键时只能靠 SystemIndex，而两侧来源不同：CT 的 em 用
    _Context._Em:get_SystemIndex()，MSG 的 em 用 AttackAreaResult:get_EmSystemIndex()，是否同一套编号只在自检2 记了一笔。
    一旦不同，所有接触都对不上回合，报告只会显示大量「未匹配」（审查 conformance/measurement）。处理：
    ① 接触的 sys 键从没在任何回合里出现过 → 去掉它（只留地址/名字），让 Ident.learn 走共现学习；
    ② 自检2 失败项含 sysidx → 全部接触的 sys 键都去掉（编号可能碰巧和别的怪撞上）。返回说明。"""
    ep_sys = {k for e in episodes for k in e.keys if k[0] == "sys"}
    ct_sys = {k for c in contacts for k in c.keys if k[0] == "sys"}
    st2_sysidx = any("sysidx" in str(r.get("failed") or "") for r in data.get("pr", "SELFTEST")
                     if r.get("stage") == 2)
    n = 0
    for c in contacts:
        sk = {k for k in c.keys if k[0] == "sys"}
        if sk and (st2_sysidx or not (sk & ep_sys)):
            c.keys = frozenset(k for k in c.keys if k[0] != "sys")
            c.sys_demoted = True
            n += 1
    disjoint = bool(ct_sys) and bool(ep_sys) and not (ct_sys & ep_sys)
    return Obj(n=n, st2_sysidx=st2_sysidx, disjoint=disjoint, ct_sys=len(ct_sys), ep_sys=len(ep_sys))


def build_entries(data):
    """条目时间序列：优先 SER（只进 JSON、每帧或每 4 帧一格）；某条目完全没有 SER 时用 TYP
    （日志里有，只在类型变化、hs 回跳、条目增减时记一格），按名义倒数 60/s 外推，标为近似。
    条目对象会被怪物复用（探针每个新回合重写 ENT）：ENT 属性按时间保存（attrs_list），用时按回合取（entry_attrs）。"""
    entries = {}
    for kind, approx in (("SER", False), ("TYP", True)):
        for r in data.get("pr", kind):
            if r.get("t") is None or not r.get("obj") or not r.get("ent") or r.get("hs") is None:
                continue
            key = (r["obj"], r["ent"])
            e = entries.get(key)
            if e is None:
                e = entries[key] = Obj(obj=r["obj"], ent=r["ent"], samples=[], approx=approx, attrs=None, src=kind,
                                       attrs_list=[])
            elif e.src != kind:
                continue          # 已有 SER 的条目不掺 TYP
            e.samples.append((r["t"], r.get("f"), r.get("type"), r["hs"], r.get("he"), r.get("charge")))
    for e in entries.values():
        e.samples.sort(key=lambda s: s[0])
        e.ts = [s[0] for s in e.samples]
    for r in data.get("pr", "ENT"):
        e = entries.get((r.get("obj"), r.get("ent")))
        if e is not None:
            e.attrs = r
            e.attrs_list.append(r)
    for e in entries.values():
        e.attrs_list.sort(key=lambda r: (r.get("t") is None, r.get("t") or 0.0))
    by_obj = defaultdict(list)
    for e in entries.values():
        by_obj[e.obj].append(e)
    return entries, by_obj


def entry_attrs(e, t=None):
    """t 时刻条目的 ENT 属性：取 t 之前（+0.05 s）最近一次写的那条（ENT 在条目每个回合第一次出现时写）。
    日志兜底的 ENT 没有 t，或没给 t：退回最后一条。"""
    if e is None or not e.attrs_list:
        return None
    if t is None:
        return e.attrs_list[-1]
    best = None
    for r in e.attrs_list:
        rt = r.get("t")
        if rt is None:
            return e.attrs_list[-1]
        if rt <= t + 0.05:
            best = r
    return best


def entry_state(e, t, lo=None, hi=None):
    """t 时刻条目的 (type, hs, he, f)：取 t 之前最近一格并按 60/s 外推；超过陈旧上限返回 None。"""
    i = bisect.bisect_right(e.ts, t) - 1
    if i < 0:
        return None
    st, f, typ, hs, he, _ch = e.samples[i]
    if lo is not None and st < lo:
        return None
    gap = t - st
    if gap > (8.0 if e.approx else SER_STALE):
        return None
    return (typ, hs - 60.0 * gap, (he - 60.0 * gap) if he is not None else None, f)


def entry_shell(e, t=None):
    """ShellIndex 有值 = 弹体（t 时刻那个回合的 ENT）。ENT 读不到时返回 None（按 fail-open 处理）。"""
    a = entry_attrs(e, t)
    if a is None:
        return None
    v = a.get("shell")
    if v is None:
        return False
    s = str(v).strip().lower()
    if s in ("false", "novalue", "no", "nil", "-"):
        return False
    return True


def entry_effect(e, t=None):
    """DamageType ∈ {EAR, WIND, QUAKE}（t 时刻那个回合的 ENT）。读不到时 None（fail-open）。"""
    a = entry_attrs(e, t)
    if a is None or a.get("dmgtype") is None:
        return None
    return any(enum_is(a.get("dmgtype"), "DT", n) for n in EFFECT_DT)


def entry_grab(e, t=None):
    """1.3：DamageType ∈ {CATCH, CATCH_ZAKO, CATCH_SLINGER}（t 时刻那个回合的 ENT）。读不到时 None（fail-open，和 v1.5.1
    一样按「不是抓取」）。探针 ENT 的 dmgtype 写的是名字；抓取类型的数值没核对过，数字形态不认（按不是抓取）。"""
    a = entry_attrs(e, t)
    if a is None or a.get("dmgtype") is None:
        return None
    v = a.get("dmgtype")
    return isinstance(v, str) and any(enum_is(v, "DT", n) for n in GRAB_DT)


def entry_sg(e, t=None):
    """1.4（V16 第 3.4 节）：GuardType ∈ SKILL_GUARD 家族（t 时刻那个回合的 ENT）。读不到时 None（否决侧 fail-open：按不是）。"""
    a = entry_attrs(e, t)
    if a is None or a.get("guard") is None:
        return None
    return any(enum_is(a.get("guard"), "GUARD", n) for n in SG_GUARDS)


def g1_class(a):
    """1.4（V16 第 3.1、3.2 节）：一条 ENT 属性按「该接」过滤的结论。
    ok 该接（_IsParryBreak 为假、GuardType ∈ {NORMAL, ALL_RANGE}、伤害类型读得到）；pb _IsParryBreak 为真；
    ug UNABLE_GUARD；sg SKILL_GUARD 家族（候选侧被白名单挡掉、视野内另外否决，不写 SKIP）；
    fc 读不准（攻击参数为空：探针 ENT 的 guard / dmgtype / pbreak 全空；或某个字段读不到；或 GuardType 是枚举外的值）。
    弹体、效果攻击、抓取是旧规则（v1.5 / v1.5.1），这里不管。a 为 None（没有 ENT）也按 fc：V16 第 7 节第 5 条「读不到按 fc」。
    一条条目有几种属性时「确定的原因优先」（V16 第 3.2 节的集成澄清，和放刀模块、mock 神谕同一口径）：SKILL_GUARD 家族（否决
    家族，静默排除）> pb=1 > UNABLE_GUARD > 读不准；所以 pb=1 又是 SKILL_GUARD 的条目记 sg（漏报归「被抓取规则否决」）。"""
    if a is None:
        return "fc"
    pb, gt, dt = a.get("pbreak"), a.get("guard"), a.get("dmgtype")
    if pb is None and gt is None and dt is None:
        return "fc"
    if gt is not None and any(enum_is(gt, "GUARD", n) for n in SG_GUARDS):
        return "sg"
    if pb is True:
        return "pb"
    if gt is None:
        return "fc"
    if enum_is(gt, "GUARD", "UNABLE_GUARD"):
        return "ug"
    if not any(enum_is(gt, "GUARD", n) for n in G1_OK_GUARDS):
        return "fc"
    if pb is None or dt is None:
        return "fc"
    return "ok"


def entry_g1(e, t=None):
    return g1_class(entry_attrs(e, t))


def entry_g1x(ctx, e, t=None):
    """1.4 审查修订：同 entry_g1，但探针 AP 模块在这个 session 停用过（ctx.ap_off）、而这条条目的 ENT 是停用之后写的、攻击参数
    三项全空时返回 "unk"（探针读不到，属性不明），不按 fc：fc 说的是「放刀模块读不准、不放刀」，这里是探针自己不读了，放刀模块
    读没读到不知道（它放了刀就说明读到了）。影子回放按 unk 放行，漏报归因另记「属性不明」一类。"""
    a = entry_attrs(e, t)
    t_off = getattr(ctx, "ap_off", None) if ctx is not None else None
    if t_off is not None and a is not None and a.get("pbreak") is None and a.get("guard") is None \
            and a.get("dmgtype") is None and (a.get("t") is None or a.get("t") >= t_off - 0.05):
        return "unk"
    return g1_class(a)


def types_have_danger(types):
    for tok in re.split(r"[>,|/;\s]+", str(types or "").upper()):
        if tok in ("D", "DANGER") or (tok.lstrip("-").isdigit() and int(tok) == ENUMS["RT"]["DANGER"]):
            return True
    return False


def sender_keys(rec):
    """预告侧的攻击者键：em<EmID>#<SystemIndex>，再加上发送者的 EnemyCharacter 地址和 GameObject 名（探针 SND 模块；
    PLAN P23 首选「发送者或攻击者的 EnemyCharacter 地址」，和 CT 的 atk_em / atk 直接比）。
    发送者不是怪物（snd_em 为空）时不加名字键：不能让所有回合共用一个管理器对象的名字"""
    snd_em = rec.get("snd_em")
    if _is_nil(snd_em):
        return ident_keys(rec.get("em"))
    return ident_keys(rec.get("em"), snd_em, rec.get("snd"))


def build_episodes(data, by_obj):
    eps = []
    recs = [r for r in data.get("pr", "EP") if r.get("obj")]
    if recs:
        for r in recs:
            eps.append(Obj(id=r.get("id"), obj=r["obj"], epoch=r.get("epoch") or 0, em=r.get("em"),
                           keys=sender_keys(r), keep=r.get("keep"), t0=r.get("t0"), t1=r.get("t1"),
                           types=str(r.get("types") or ""), first_type=r.get("first_type"),
                           first_hs=r.get("first_hs"), charge_all=r.get("charge_all"), atk_on=r.get("atk_on"),
                           reason=str(r.get("reason") or ""), n_msg=r.get("n_msg"), src="EP",
                           end=to_str(r.get("end"))))
    else:
        # 没有 EP（探针 JSON 和日志都缺这一类）：从 MSG 合成，KeepActionID 变化或相隔 >8 s 切开
        by = defaultdict(list)
        for m in data.get("pr", "MSG"):
            if m.get("obj") and m.get("t") is not None:
                by[m["obj"]].append(m)
        for obj, ms in by.items():
            cur = None
            for m in ms:
                if cur is None or m.get("keep") != cur.keep or m["t"] - cur.t1 > 8.0:
                    cur = Obj(id=None, obj=obj, epoch=(cur.epoch + 1 if cur else 0), em=m.get("em"),
                              keys=sender_keys(m), keep=m.get("keep"), t0=m["t"], t1=m["t"],
                              types="", first_type=m.get("rt"), first_hs=None, charge_all=None, atk_on=None,
                              reason="msg", n_msg=0, src="MSG", end=None)
                    eps.append(cur)
                cur.t1 = m["t"]
                cur.n_msg += 1
                if is_danger(m.get("rt")) and not types_have_danger(cur.types):
                    cur.types += (">" if cur.types else "") + "DANGER"
    msgs = defaultdict(list)
    for m in data.get("pr", "MSG"):
        if m.get("obj") and m.get("t") is not None:
            msgs[m["obj"]].append(m)
    for ep in eps:
        ents = by_obj.get(ep.obj, [])
        if ep.t0 is None:
            ts = [s[0] for e in ents for s in e.samples]
            ep.t0 = min(ts) if ts else None
        if ep.t1 is None:
            ts = [s[0] for e in ents for s in e.samples if ep.t0 is None or s[0] >= ep.t0]
            ep.t1 = max(ts) if ts else ep.t0
        ep.ents = ents
        ep.msgs = [m for m in msgs.get(ep.obj, []) if ep.t0 is None or ep.t0 - 0.05 <= m["t"] <= (ep.t1 or 0) + 0.05]
        if not ep.keys and ep.msgs:
            ep.keys = sender_keys(ep.msgs[0])
        if ep.msgs and not any(k[0] == "addr" for k in ep.keys):
            # EP 没带发送者地址（日志兜底或旧探针）：从同一回合的 MSG 补
            extra = frozenset().union(*(sender_keys(m) for m in ep.msgs))
            ep.keys = ep.keys | extra
        if ep.keep is None and ep.msgs:
            ep.keep = ep.msgs[0].get("keep")
        ep.fire = None
        ep.contacts = []
        ep.danger = (is_danger(ep.first_type) or types_have_danger(ep.types)
                     or any(is_danger(m.get("rt")) for m in ep.msgs)
                     or any(is_danger(s[2]) for e in ents for s in e.samples
                            if ep.t0 is not None and ep.t0 - 0.05 <= s[0] <= ep.t1 + 0.05))
        ep.t_hs0, ep.t_he0, ep.timing = None, None, None
    return eps


def episode_samples(ep, e):
    if ep.t0 is None:
        return e.samples
    return [s for s in e.samples if ep.t0 - 0.05 <= s[0] <= ep.t1 + 0.05]


def shadow_timing(ep):
    """没放刀的回合：用最早归零的 DANGER 条目，最后一格 hs≥0 的样本按名义倒数投影 hs、he 归零时刻。"""
    best = None
    for want_danger in (True, False):
        for e in ep.ents:
            smp = [s for s in episode_samples(ep, e) if (is_danger(s[2]) or not want_danger) and s[3] is not None]
            if not smp:
                continue
            last = None
            for s in smp:
                if s[3] >= 0:
                    last = s
            last = last or smp[0]
            ths = last[0] + last[3] / 60.0
            the = last[0] + (last[4] if last[4] is not None else last[3]) / 60.0
            if best is None or ths < best[0]:
                best = (ths, max(the, ths), "TYP" if e.approx else "SER")
        if best:
            break
    if best is None and ep.first_hs is not None and ep.t0 is not None:
        best = (ep.t0 + ep.first_hs / 60.0, ep.t0 + ep.first_hs / 60.0 + 0.3, "EP")
    if best:
        ep.t_hs0, ep.t_he0, ep.timing = best


def build_fires(data, tl):
    ends = {r.get("id"): r for r in data.get("rc", "FIRE_END") if r.get("id") is not None}
    ress = {r.get("id"): r for r in data.get("rc", "RES") if r.get("id") is not None}
    fires = []
    for r in data.get("rc", "FIRE"):
        if r.get("t") is None:
            continue
        fe = ends.get(r.get("id"))
        res = ress.get(r.get("id"))
        entered = fe.get("entered") if fe else None
        # 1.5：合并版没有 FIRE_END，entered 记在 RES 里
        if entered is None and res is not None:
            entered = res.get("entered")
        assumed = False
        if entered is None and tl.acts:
            entered = tl.first(r["t"], r["t"] + 0.25, lambda a: a["to"] == SLASH) is not None
        if entered is None:
            # FIRE_END、RES 的 entered 和 ACT 都没有：按「被接受」处理（v1.3 的 5 次请求都是首次即被接受），并在报告里计数
            entered, assumed = True, True
        fires.append(Obj(id=r.get("id"), t_req=r["t"], L=r.get("L"), R0=r.get("R0"), he0=r.get("he0"),
                         src=r.get("src"), ent=r.get("ent"), res=r.get("res"), em=r.get("em"),
                         keys=ident_keys(r.get("em")), keep=r.get("keep"), frm=r.get("from"),
                         entered=entered, n=fe.get("n") if fe else None, R1=fe.get("R1") if fe else None,
                         t_fe=fe.get("t") if fe else None,
                         rc_outcome=res.get("outcome") if res else None, pt=None, t_start=None,
                         t_start_src=None, ep=None, contacts=[], c_first=None, outcome=None, sub=None,
                         hp=None, clean=None, tier=None, hitch=False, kind="auto", entered_assumed=assumed,
                         # 1.4：v1.6 的 E5c 字段（旧版本都是 None）和 RES 的 to；e5c 由 prepare_session 按 HDR 定
                         C1=r.get("C1"), Cf=r.get("Cf"), mf=r.get("mf"), nchg=r.get("nchg"), dX=r.get("dX"),
                         A0=r.get("A0"), Q0=r.get("Q0"), Qp=r.get("Qp"), Qe1=r.get("Qe1"), mode=r.get("mode"),
                         vq=r.get("vq"), rc_to=res.get("to") if res else None, e5c=False))
    return fires


def fire_reading(f):
    """1.4：放刀那一帧的触发读数。v1.6 的 L、L_min 是 Q 单位（真实剩余帧，V16 第 7 节第 2 条），读数用 FIRE 的 Q0；
    更早的版本和 1.3 一样用原始 hs 的 R0。C2 残差、C3、d̄ 都按它算，单位和 L 一致。"""
    if getattr(f, "e5c", False) and getattr(f, "Q0", None) is not None:
        return f.Q0
    return f.R0


def build_scan(data):
    out = []
    for r in data.get("rc", "SCAN"):
        t_req = r.get("t_req")
        out.append(Obj(id=r.get("id"), t=r.get("t"), phase=(r.get("phase") or "").lower(),
                       status=(r.get("status") or "").upper(), X=r.get("X"), t_req=t_req, reason=r.get("reason"),
                       pt=None, t_start=None, t_start_src=None, c_first=None, label=None, outcome=None,
                       contact=None, kind="scan"))
    return out


def link_pts(data, tl, requests):
    """PT 与 rc 请求（FIRE / SCAN）按时间关联：请求后 0.25 s 内最近的一条 PT。
    请求被拒、连续重试时 streak 可能更长（P08 的口径是「距最后一次请求 ≤0.05 s」）：FIRE_END（rc 看到进入
    (2,23) 的那一帧，和探针 PT 的 t_obs 是同一帧）比 0.25 s 晚时，窗口放宽到 FIRE_END 后 0.05 s。
    t_start = (2,23) 首帧读到的时刻 − 当时的 _RawTotalElapsedSecond（PT 自带；缺 PT 时用 ACT 的 raw_new）。"""
    pts = []
    for r in data.get("pr", "PT"):
        t_obs = r.get("t_obs") if r.get("t_obs") is not None else r.get("t")
        if t_obs is None:
            continue
        ts = r.get("t_start")
        if ts is None and r.get("raw0") is not None:
            ts = t_obs - r["raw0"]
        pts.append(Obj(rec=r, t_obs=t_obs, t_start=ts, frm=r.get("from"), used=False, owner=None))
    pts.sort(key=lambda p: p.t_obs)
    pt_ts = [p.t_obs for p in pts]
    for q in sorted(requests, key=lambda q: q.t_req if q.t_req is not None else 1e18):
        if q.t_req is None:
            continue
        hi = q.t_req + 0.25
        t_fe = getattr(q, "t_fe", None)
        if t_fe is not None and q.entered:
            hi = max(hi, t_fe + 0.05)
        i = bisect.bisect_left(pt_ts, q.t_req - 0.005)
        while i < len(pts) and pts[i].t_obs <= hi:
            if not pts[i].used:
                pts[i].used = True
                pts[i].owner = q
                q.pt = pts[i]
                if pts[i].t_start is not None:
                    q.t_start, q.t_start_src = pts[i].t_start, "PT"
                break
            i += 1
        if q.t_start is None and tl.acts:
            a = tl.first(q.t_req - 0.005, q.t_req + 0.25, lambda a: a["to"] == SLASH)
            if a is not None:
                if a.get("raw_new") is not None:
                    q.t_start, q.t_start_src = a["t"] - a["raw_new"], "ACT"
                else:
                    q.t_start, q.t_start_src = a["t"], "ACT≈"
    return pts


# ---------------------------------------------------------------- 放刀 ↔ 回合、P23 匹配
def link_fire_episodes(fires, episodes):
    by_obj = defaultdict(list)
    for e in episodes:
        by_obj[e.obj].append(e)
    synth = []
    for f in fires:
        cands = [e for e in by_obj.get(f.res, []) if e.t0 is not None]
        inside = [e for e in cands if e.t0 - 0.1 <= f.t_req <= (e.t1 if e.t1 is not None else e.t0) + 0.1]
        pool = inside or [e for e in cands if e.t0 <= f.t_req + 0.1]
        ep = max(pool, key=lambda e: e.t0) if pool else None
        if ep is None or ep.fire is not None:
            # 找不到对应回合（探针缺 EP/MSG，或同一回合第二次放刀）：用放刀记录自己合成一个回合
            ep = Obj(id=None, obj=f.res, epoch=-1, em=f.em, keys=f.keys, keep=f.keep, t0=f.t_req, t1=f.t_req,
                     types="DANGER", first_type="DANGER", first_hs=f.R0, charge_all=None, atk_on=None,
                     reason="fire", n_msg=0, src="FIRE", ents=[], msgs=[], fire=None, contacts=[], danger=True,
                     t_hs0=None, t_he0=None, timing=None, end=None)
            synth.append(ep)
        ep.fire = f
        f.ep = ep
        if not ep.keys:
            ep.keys = f.keys
        if ep.keep is None:
            ep.keep = f.keep
        ep.danger = True
        if f.R0 is not None:
            # 放过刀的回合：t_he0 用触发条目在 t_req 时的读数；t_hs0 取「触发条目归零」和「本回合在 t_req 时最早归零的
            # DANGER 条目」中较早的那个 —— 和没放刀回合的 shadow_timing（最早归零的 DANGER 条目）同一口径。
            # 多段攻击：前段条目 hs<L_min 不是候选，后段触发放刀，前段先打中；只按触发条目算窗口会把前段接触排除在外
            t_trig = f.t_req + f.R0 / 60.0
            t_min = t_trig
            for e in ep.ents:
                st = entry_state(e, f.t_req, lo=(ep.t0 - 0.05) if ep.t0 is not None else None)
                if st is not None and is_danger(st[0]) and st[1] is not None:
                    t_min = min(t_min, f.t_req + st[1] / 60.0)
            ep.t_hs0 = t_min
            ep.t_he0 = f.t_req + (f.he0 if f.he0 is not None else f.R0) / 60.0
            ep.timing = "FIRE"
    return synth


def match_contacts(contacts, episodes, ident):
    """P23：攻击者相同；接触落在 [t_hs0−0.35, t_he0+0.30]；多个候选取 |t−t_hs0| 最小；报告未匹配和歧义。"""
    usable = sorted((e for e in episodes if e.t_hs0 is not None), key=lambda e: e.t_hs0)
    st = Obj(total=len(contacts), matched=0, unmatched=0, ambiguous=0, no_pred_attacker=0)
    for e in usable:
        e.contacts = []
    for c in contacts:
        cands = [e for e in usable if e.t_hs0 - MATCH_PRE <= c.t <= e.t_he0 + MATCH_POST and ident.same(e.keys, c.keys)]
        c.ncand = len(cands)
        if cands:
            best = min(cands, key=lambda e: (abs(c.t - e.t_hs0), e.t_hs0))
            c.ep = best
            best.contacts.append(c)
            st.matched += 1
            if len(cands) > 1:
                st.ambiguous += 1
        else:
            c.ep = None
            st.unmatched += 1
            if not any(ident.same(e.keys, c.keys) for e in usable):
                st.no_pred_attacker += 1
    for e in usable:
        e.contacts.sort(key=lambda c: c.t)
    return st


# ---------------------------------------------------------------- T_armor（A1 空挥）
ARMOR_MIN_RUN = 3.0 / 60.0      # T_armor：短于 3 帧的 sa=0 段当作瞬时值忽略


def estimate_t_armor(data, tl, pts, contacts):
    """空挥：放刀后到离开 (2,23)（≥2 s，空放会停到有输入为止）之间没有任何敌方接触、没有 EMHIT。
    T_armor = 离开 (2,23) 前最后一段持续 sa=0 的起点（ARM 行的 raw，缺 raw 用 t−t_start）。"""
    arms = [a for a in data.get("pr", "ARM") if a.get("t") is not None]
    arm_ts = [a["t"] for a in arms]
    emhit_ts = sorted(h["t"] for h in data.get("pr", "EMHIT") if h.get("t") is not None)
    ct_ts = sorted(c.t for c in contacts)
    vals, n_swing = [], 0
    for p in pts:
        if p.t_start is None:
            continue
        t0 = p.t_obs
        leave = tl.leave_slash(t0, t0 + TAIL_MAX + 2.0)
        if leave - t0 < 2.0:
            continue
        i = bisect.bisect_left(ct_ts, t0 - 0.05)
        if i < len(ct_ts) and ct_ts[i] <= leave:
            continue
        i = bisect.bisect_left(emhit_ts, t0 - 0.05)
        if i < len(emhit_ts) and emhit_ts[i] <= leave:
            continue
        n_swing += 1
        # (2,23) 里 SUPER_ARMOR 的变化序列；T_armor = 离开 (2,23) 前最后一段「持续」sa=0 的起点。
        # 以前取第一条 sa=0：进 (2,23) 第一帧霸体标志若短暂为 0（下一帧才置位，推测），三次空挥都会得到约 0.01 s，
        # W1_eff 变成负数、覆盖曲线全 0（审查 measurement）。短于 3 帧又变回 1 的 sa=0 段忽略
        seq = []
        i = bisect.bisect_left(arm_ts, p.t_start - 0.02)
        while i < len(arms) and arms[i]["t"] <= leave:
            a = arms[i]
            if a.get("act") == SLASH and a.get("sa") is not None:
                seq.append((a["t"], a.get("sa"), a["raw"] if a.get("raw") is not None else a["t"] - p.t_start))
            i += 1
        # 分段（每段到下一条变化为止，最后一段到离开 (2,23)），去掉短于 3 帧的中间段（瞬时翻转），再合并同值相邻段
        segs = []
        for k, (t_a, sa, raw) in enumerate(seq):
            t_b = seq[k + 1][0] if k + 1 < len(seq) else leave
            segs.append([t_a, t_b, sa, raw])
        segs = [s for k, s in enumerate(segs) if k == len(segs) - 1 or s[1] - s[0] >= ARMOR_MIN_RUN]
        merged = []
        for s in segs:
            if merged and merged[-1][2] == s[2]:
                merged[-1][1] = s[1]
            else:
                merged.append(list(s))
        if merged and merged[-1][2] is False:
            vals.append(merged[-1][3])
    return median(vals), vals, n_swing


# ---------------------------------------------------------------- C1 窗口
def _boot_x50(xs, ys, rng):
    out = []
    n = len(xs)
    for _ in range(BOOT_N):
        idx = [rng.randrange(n) for _ in range(n)]
        v = logistic_x50([xs[i] for i in idx], [ys[i] for i in idx])
        if v is not None and math.isfinite(v):
            out.append(v)
    if len(out) < BOOT_N // 4:
        return None
    return quantile(out, 0.10), quantile(out, 0.90)


def estimate_window(points, rng):
    """points: [(x=c_first, ok)]。C1：可分用中点；重叠用 logistic（P=0.5）+ bootstrap 80% 区间；
    下方没有失败 → W0 左删失（≤ 最小 PARRY）；上方没有失败 → W1 右删失（≥ 最大 PARRY）。
    上下两段按 PARRY 的中位数切开，各自独立判断。"""
    P = sorted(x for x, ok in points if ok)
    F = sorted(x for x, ok in points if not ok)
    res = Obj(n=len(points), nP=len(P), nF=len(F), W0=None, W1=None, m0=None, m1=None,
              ci0=None, ci1=None, cens0=False, cens1=False, ok=False)
    if len(P) < 2 or len(points) < 4:
        return res
    split = median(P)
    lowP, lowF = [x for x in P if x <= split], [x for x in F if x < split]
    highP, highF = [x for x in P if x >= split], [x for x in F if x > split]
    if not lowF:
        res.W0, res.m0, res.cens0 = min(P), "左删失（下方无失败）", True
    elif max(lowF) < min(lowP):
        res.W0, res.m0 = (max(lowF) + min(lowP)) / 2.0, "可分·中点"
    else:
        xs = lowF + lowP
        ys = [0] * len(lowF) + [1] * len(lowP)
        res.W0, res.m0 = logistic_x50(xs, ys), "重叠·logistic"
        res.ci0 = _boot_x50(xs, ys, rng)
    if not highF:
        res.W1, res.m1, res.cens1 = max(P), "右删失（上方无失败）", True
    elif min(highF) > max(highP):
        res.W1, res.m1 = (max(highP) + min(highF)) / 2.0, "可分·中点"
    else:
        xs = highP + highF
        ys = [1] * len(highP) + [0] * len(highF)
        res.W1, res.m1 = logistic_x50(xs, ys), "重叠·logistic"
        res.ci1 = _boot_x50(xs, ys, rng)
    res.ok = res.W0 is not None and res.W1 is not None and res.W0 < res.W1
    return res


def window_agreement(samples, W0, W1, cens1):
    """真怪核对：c_first∈窗口 与 CATCH 是否一致，±0.03 s 内两种标签都算一致；W1 右删失时上沿只约束失败样本。"""
    n = ok = 0
    bad = []
    for c, catch in samples:
        loose_hi = math.inf if cens1 else W1 + 0.03
        in_loose = W0 - 0.03 <= c <= loose_hi
        in_tight = W0 + 0.03 <= c <= W1 - 0.03
        good = in_loose if catch else not in_tight
        n += 1
        ok += good
        if not good:
            bad.append((c, catch))
    return n, ok, bad


# ---------------------------------------------------------------- B 结局分类
def is_recoil_act(a):
    # 1.4：进 (2,25) cParrySlashHitS 也是 RECOIL（G1 实测：都是抵消状态 RECOIL、随即身体挨打；V16 第 4 节）
    return str(a.get("to_name") or "").endswith("cRecoil") or a.get("to") == RECOIL_ACT


class TimeIndex:
    def __init__(self, recs):
        self.recs = sorted((r for r in recs if r.get("t") is not None), key=lambda r: r["t"])
        self.ts = [r["t"] for r in self.recs]

    def window(self, t0, t1):
        return self.recs[bisect.bisect_left(self.ts, t0):bisect.bisect_right(self.ts, t1)]

    def last_before(self, t, pred):
        i = bisect.bisect_right(self.ts, t) - 1
        while i >= 0:
            if pred(self.recs[i]):
                return self.recs[i]
            i -= 1
        return None


def stop_intervals(data):
    """探针 STOP / RESUME 配成 [停, 恢复] 区间；最后一次停了没恢复的，区间到 +inf。"""
    evs = sorted([(r["t"], 0) for r in data.get("pr", "STOP") if r.get("t") is not None]
                 + [(r["t"], 1) for r in data.get("pr", "RESUME") if r.get("t") is not None])
    out, start = [], None
    for t, kind in evs:
        if kind == 0 and start is None:
            start = t
        elif kind == 1 and start is not None:
            out.append((start, t))
            start = None
    if start is not None:
        out.append((start, math.inf))
    return out


class Ctx:
    """分析上下文：各类记录的时间索引。"""

    def __init__(self, data):
        self.data = data
        self.tl = ActTimeline(data.get("pr", "ACT"))
        self.contacts = build_contacts(data)
        self.ct_ts = [c.t for c in self.contacts]
        self.ph = [r for r in data.get("pr", "PH") if r.get("t") is not None]
        self.ph_ts = [r["t"] for r in self.ph]
        st = [r for k in ("PS", "PMSG") for r in data.get("pr", k) if r.get("t") is not None]
        self.recoil_ts = sorted(r["t"] for r in st if enum_is(r.get("state"), "PS", "RECOIL"))
        self.dmg = [(r["t"], r.get("total") or 0.0) for r in data.get("pr", "DMG") if r.get("t") is not None]
        self.dmg_ts = [d[0] for d in self.dmg]
        hit = [r for k in ("HITCH", "GAP") for r in data.get("pr", k) if r.get("t") is not None]
        self.hitch_ts = sorted(r["t"] for r in hit if (r.get("dt") or 0) > HITCH_DT)
        # 怪物侧记录按时间建索引：真数据里 EMINFO/POSE 可能上千条，逐条扫会很慢
        self.emhit = TimeIndex(data.get("pr", "EMHIT"))
        self.emstate = TimeIndex(data.get("pr", "EMSTATE"))
        self.eminfo = TimeIndex(data.get("pr", "EMINFO"))
        self.pose = TimeIndex(data.get("pr", "POSE"))
        self.atk = TimeIndex(data.get("pr", "ATK"))
        # 动画层时钟（ANIM 只进 JSON）：离线 1 对照 raw / chara / Frame 三种时钟
        self.anim = sorted((r for r in data.get("pr", "ANIM") if r.get("t") is not None), key=lambda r: r["t"])
        self.anim_ts = [r["t"] for r in self.anim]
        # 探针覆盖：放刀前后 ±6 s 内有任何探针记录才算探针在记（PERF 每 5 s 一行）。
        # 没覆盖时不能把「没看到接触」当成空放，否则只有 rc 数据时会全判成 WHIFF。
        self.probe_ts = sorted(r["t"] for (src, _k), v in data.by.items() if src == "pr"
                               for r in v if r.get("t") is not None)
        self.msgs_by_obj = defaultdict(list)
        for m in data.get("pr", "MSG"):
            if m.get("obj") and m.get("t") is not None:
                self.msgs_by_obj[m["obj"]].append(m)
        self.ident = Ident()
        self.delta = DELTA_PRIOR
        self.W0, self.W1, self.W1_eff, self.cens1 = W_PRIOR[0], W_PRIOR[1], W_PRIOR[1], False
        # 探针「停止记录」区间（STOP → 下一条 RESUME；没恢复就到最后）。区间内探针什么都不记，
        # 只靠 ±6 s 内有没有探针记录判断「探针在记」会把停止前后的放刀误判成空放
        self.stops = stop_intervals(data)
        # 1.4 审查修订：探针 AP 模块停用的时刻（第一条 ERR mod=AP；没有 t 的按会话开头）。APCal 的加载自检 2 在会话第一个 DANGER
        # 条目上读攻击参数，读到空的就报黄并停用 AP（探针原有行为），之后的 ENT 没有 guard / pbreak / dmgtype —— 那是探针读不到，
        # 不是游戏数据，G1 相关的输出不能把它当成「读不准（fc）」（见 entry_g1x）
        ap_err = [r for r in data.get("pr", "ERR") if str(r.get("mod") or "").upper() == "AP"]
        self.ap_off = min((r.get("t") if r.get("t") is not None else -math.inf) for r in ap_err) if ap_err else None

    def contacts_in(self, t0, t1):
        i = bisect.bisect_left(self.ct_ts, t0)
        j = bisect.bisect_right(self.ct_ts, t1)
        return self.contacts[i:j]

    def any_in(self, ts, t0, t1):
        i = bisect.bisect_left(ts, t0)
        return i < len(ts) and ts[i] <= t1

    def in_stop(self, t0, t1):
        return any(a <= t1 and t0 <= b for a, b in self.stops)

    def probe_cover(self, t):
        return self.any_in(self.probe_ts, t - 6.0, t + 6.0)

    def hp_loss(self, t0, t1):
        i = bisect.bisect_left(self.dmg_ts, t0)
        j = bisect.bisect_right(self.dmg_ts, t1)
        return sum(d[1] for d in self.dmg[i:j])

    def recoil_in(self, t0, t1):
        return self.any_in(self.recoil_ts, t0, t1) or self.tl.first(t0, t1, is_recoil_act) is not None


SUB_INT_FALLBACK = "先砍中、招式在 hs 归零前结束（缺受击动作证据）"


def attempt_bounds(t, t_start, next_req, ctx):
    """一次放刀的判定上限：
    t_cr  = CATCH/RECOIL 的搜索上限 = min(t_req+CREDIT, 这一刀离开 (2,23..29) 的时刻, 下一次放刀请求)。
            以前固定 [t_req, t_req+1.3]：空放后很快重新蓄力、0.95 s 内再放一刀接住，会把后一刀的接住记到前一刀上
            （审查 measurement 合成数据：F_actual 0.5 → 0.0）。
    t_nx  = 下一次放刀请求（没有就 +inf）：之后的接触、PH 归下一刀。"""
    t_nx = next_req if next_req is not None else math.inf
    t_cr = min(t + CREDIT, t_nx)
    if ctx.tl.acts:
        t_cr = min(t_cr, ctx.tl.leave_family(t_start, t + CREDIT))
    return t_cr, t_nx


def classify_fire(f, ctx):
    """DECISION RULE B：互斥，按优先级取第一个；时刻都相对 t_req。
    c_first 按 PLAN 的字面定义：t_req 之后「该攻击者」的首个接触（含弹体路径），不经过 P23 回合匹配。
    以前只取 P23 匹配进本回合的接触（窗口按触发条目算），r<−0.35 的早到接触（多段攻击前段先打中、L=36 档）
    判成 FAIL_OTHER、没有 c_first，C2 残差左尾被截掉、L_min* 偏小（审查 conformance/measurement，exp_early）。
    接触窗口 = [t_req, max(t_cr, 空放判定期末)]，并在下一次放刀请求处截断；晚于它、离开 (2,23) 之前的该攻击者接触
    算「晚到接触」（PLAN 测量-14）。f.contacts 存这一刀的全部同攻击者接触，回合归因也用它。"""
    tl, t = ctx.tl, f.t_req
    t_start = f.t_start if f.t_start is not None else t + ctx.delta
    f.t_start_used = t_start
    f.c_first_rec = None
    if not ctx.probe_cover(t):
        # B 节分类只用探针数据（PLAN：测量链去掉「自己给自己打分」），rc 的 RES 只写进说明
        f.outcome = "UNKNOWN"
        f.sub = "探针无数据" + (f"（rc 自评 {f.rc_outcome}）" if f.rc_outcome else "")
        return
    t_leave = tl.leave_slash(t_start, t_start + TAIL_MAX)
    he = f.he0 if f.he0 is not None else (f.R0 if f.R0 is not None else 0.0)
    t_whiff_end = t + he / 60.0 + WHIFF_PAD
    if ctx.in_stop(t - 0.1, max(t_leave, t_whiff_end)):
        # 判定要看到的这段时间（到离开 (2,23) 或空放判定期末）里探针停止过记录：数据不全，不判
        f.outcome = "UNKNOWN"
        f.sub = "探针停止记录" + (f"（rc 自评 {f.rc_outcome}）" if f.rc_outcome else "")
        return
    t_cr, t_nx = attempt_bounds(t, t_start, f.next_req, ctx)
    t_cw = min(max(t_cr, t_whiff_end), t_nx)        # c_first 的接触窗口上限
    t_ph = min(t_whiff_end, t_nx)
    f.hp = ctx.hp_loss(t, min(tl.leave_family(t_start, t_start + TAIL_MAX), t_nx))
    same = [c for c in ctx.contacts_in(t, min(max(t_leave, t_cw), t_nx)) if ctx.ident.same(f.keys, c.keys)]
    f.contacts = same
    first = next((c for c in same if c.t <= t_cw), None)
    f.c_first = (first.t - t_start) if first else None
    f.c_first_rec = first
    f.hitch = ctx.any_in(ctx.hitch_ts, t - 0.05, (first.t if first else t_whiff_end))
    catch = tl.first(t, t_cr, lambda a: a["to"] in CATCH_ACTS)
    if catch:
        f.outcome, f.tier = "CATCH", catch["to"][1]
        f.clean = f.hp <= 0
        return
    if ctx.recoil_in(t, t_cr):
        f.outcome = "RECOIL"
        if tl.first(t, t_cr, lambda a: a["to"] == RECOIL_ACT) is not None:
            # 1.4：进了 (2,25)（1.3 及以前算 CATCH，档位 25）：子类单列，好数改判了几次
            f.sub, f.tier = SUB_RECOIL25, 25
        return
    if first and f.c_first < ctx.W0:
        f.outcome = "FAIL_EARLY"
        return
    ph_in = ctx.any_in(ctx.ph_ts, t, t_ph)
    # 收尾挨打只认「明确没有 SUPER_ARMOR」的身体接触；sa 读不到时不下这个结论
    tail = [c for c in ctx.contacts_in(t, min(t_leave, t_nx)) if c.cls == "BODY" and c.sa is False]
    # 「晚于空放判定期的接触归入 FAIL_LATE」（PLAN 测量-14）只针对本来会判空放的情况
    late = [c for c in same if c.t > t_cw] if not (first or ph_in) else []
    if (first and f.c_first > ctx.W1) or tail or late:
        f.outcome = "FAIL_LATE"
        # 收尾挨打（没有霸体、吃完整受击）是代价最大的一种，PLAN 要求单独统计：优先标它
        f.sub = "收尾挨打" if tail else ("c_first>W1" if first else "晚到接触")
        return
    if first or ph_in:
        f.outcome = "FAIL_OTHER"
        return
    f.outcome = "WHIFF"
    t_hs = f.ep.t_hs0 if (f.ep is not None and f.ep.t_hs0 is not None) else t + (f.R0 or 0) / 60.0
    hits = [h for h in ctx.emhit.window(t, t_hs) if ctx.ident.same(f.keys, ident_keys(h.get("em")))]
    react = [s for s in ctx.emstate.window(t, t_hs + 0.05) if ctx.ident.same(f.keys, ident_keys(s.get("em")))
             and REACT_RE.search(str(s.get("act") or ""))]
    if hits and react:
        f.sub = "INTERRUPTED"
    elif hits and f.ep is not None and str(getattr(f.ep, "end", "") or "").lower() == "fin" \
            and f.ep.t1 is not None and f.ep.t1 < t_hs:
        # 兜底：砍中之后这一招在预测的 hs 归零之前就结束了（回合 end=fin），但没记到受击动作。
        # 不算进 INTERRUPTED（PLAN 要求「进入受击类动作」的证据），单列
        f.sub = SUB_INT_FALLBACK
    elif hits:
        f.sub = "先砍中但缺受击动作证据"


def classify_manual(p, ctx):
    t = p.t_obs - 1.0 / 60.0
    t_start = p.t_start if p.t_start is not None else p.t_obs
    t_cr, t_nx = attempt_bounds(t, t_start, getattr(p, "next_req", None), ctx)
    # 1.4：(2,25) 改判 RECOIL（口径同 classify_fire）；p.recoil25 记下来，报告里数改判了几次
    p.recoil25 = ctx.tl.first(t, t_cr, lambda a: a["to"] == RECOIL_ACT) is not None \
        and ctx.tl.first(t, t_cr, lambda a: a["to"] in CATCH_ACTS) is None
    if ctx.tl.first(t, t_cr, lambda a: a["to"] in CATCH_ACTS):
        return "CATCH"
    if ctx.recoil_in(t, t_cr):
        return "RECOIL"
    if ctx.contacts_in(t, t_cr) or ctx.any_in(ctx.ph_ts, t, t_cr):
        return "有接触未接住"
    return "无接触"


# ---------------------------------------------------------------- C2 残差、C3 L*、留一招式交叉验证
def residual_samples(fires, cal):
    """C2：有接触、触发时在蓄力中的真放刀；r = c_first − R0/60 + δ。卡顿样本（dt>0.035）剔除。
    附带：是否「先砍中」（首个接触之前有同一只怪的 EMHIT，离线 1 分组用）、是否穿越触发（f.crossing，C3 用）。"""
    out, excluded = [], Counter()
    for f in fires:
        if not f.entered or f.c_first is None:
            continue
        if f.frm is not None and f.frm not in CHARGE:
            excluded["触发时不在蓄力中"] += 1
            continue
        if f.R0 is None:
            excluded["缺 R0"] += 1
            continue
        if f.hitch:
            excluded["窗口内卡顿 dt>0.035"] += 1
            continue
        # 1.4：v1.6 的放刀按 Q0（真实剩余帧）算残差，和它的 L 同一单位；旧版本 fire_reading 就是 R0，数值不变
        R0 = fire_reading(f)
        out.append(Obj(f=f, r=f.c_first - R0 / 60.0 + cal.delta, R0=R0, catch=f.outcome == "CATCH",
                       group=(emid_of(f.keys), f.keep), late=(f.crossing is False), emhit_first=f.emhit_first))
    return out, excluded


def residual_model(samples):
    xs = [s.R0 for s in samples]
    ys = [s.r for s in samples]
    rho = spearman(xs, ys)
    corrected = rho is not None and abs(rho) >= 0.4
    b = theil_sen(xs, ys) if corrected else 0.0
    if b is None:
        corrected, b = False, 0.0
    return Obj(rho=rho, b=b, corrected=corrected, n=len(samples))


def trigger_reading(s, L, dbar):
    """档位 L 下触发时读到的剩余帧 R(L)。正常「穿越 L」的样本：L − d̄（帧离散化偏差）。
    晚触发的样本（DANGER 出现时、或开始蓄力时、或否决结束时 hs 已低于 L —— 触发前一格读数没有高于 L）：
    L ≥ R0 时规则在同一帧就触发，读数就是它自己的 R0；L < R0 时才按穿越算（审查 measurement：
    以前一律用 L − d̄，这类样本的 L − R0 可达十几帧，会把 d̄ 拉大、C3 系统性偏早）。"""
    if s.late and L >= s.R0:
        return s.R0
    return L - dbar


def r_at(s, L, model):
    """C2：r_i(L) = r_i + b·(L − R0_i)（|ρ|≥0.4 才校正）。晚触发样本在 L ≥ R0 时触发读数不变，不校正。"""
    if not model.corrected:
        return s.r
    Lx = min(L, s.R0) if s.late else L
    return s.r + model.b * (Lx - s.R0)


def contact_at(s, L, model, cal, dbar):
    return trigger_reading(s, L, dbar) / 60.0 + r_at(s, L, model) - cal.delta


def coverage_curve(samples, model, ctx, dbar, lo=None, hi=None):
    lo = ctx.W0 + M_E if lo is None else lo
    hi = ctx.W1_eff - M_L if hi is None else hi
    return {L: sum(1 for s in samples if lo <= contact_at(s, L, model, ctx, dbar) <= hi) for L in L_GRID}


def pick_plateau(N):
    """最大覆盖平台的中点（四舍五入）；多个平台取 L 较小的那个。全为 0 时无定义。"""
    m = max(N.values()) if N else 0
    if m <= 0:
        return None, m
    runs, cur = [], []
    for L in L_GRID:
        if N[L] == m:
            cur.append(L)
        elif cur:
            runs.append(cur)
            cur = []
    if cur:
        runs.append(cur)
    a, b = runs[0][0], runs[0][-1]
    return int(math.floor((a + b) / 2.0 + 0.5)), m


def cross_validate(samples, ctx, dbar):
    """留一招式：去掉一个 (EmID, KeepActionID) 组，用剩下的样本重算残差模型和 L*，
    再看被去掉那组在该 L 下预计接触是否落进 [W0, W1_eff]。"""
    groups = defaultdict(list)
    for s in samples:
        groups[s.group].append(s)
    if len(groups) < 2:
        return None
    succ = tot = 0
    detail = []
    for g, held in sorted(groups.items(), key=lambda kv: str(kv[0])):
        rest = [s for s in samples if s.group != g]
        model = residual_model(rest)
        Lg, _m = pick_plateau(coverage_curve(rest, model, ctx, dbar))
        used = Lg if Lg is not None else DEFAULTS["L"]
        k = sum(1 for s in held if ctx.W0 <= contact_at(s, used, model, ctx, dbar) <= ctx.W1_eff)
        succ += k
        tot += len(held)
        detail.append((g, len(held), Lg, k))
    return Obj(p=succ / tot if tot else None, n=tot, groups=len(groups), detail=detail)


def lmin_star(samples, ctx, Lstar):
    """C4：L_min* = clamp(⌈60·(W0 + 0.02 + δ − Q25(r))⌉, 15, L*−6)。"""
    if len(samples) < 4 or Lstar is None:
        return None, None
    q25 = quantile([s.r for s in samples], 0.25)
    raw = int(math.ceil(60.0 * (ctx.W0 + M_E + ctx.delta - q25) - 1e-9))
    return max(15, min(raw, Lstar - 6)), raw


def wlong_star(fires):
    """C5：只有 he−hs∈(30,60] 这组（有接触的真放刀）接住率 <50%（n≥4）才降到 30。"""
    grp = [f for f in fires if f.entered and f.outcome in CONTACT_OUTCOMES
           and f.he0 is not None and f.R0 is not None and 30 < f.he0 - f.R0 <= 60]
    k = sum(1 for f in grp if f.outcome == "CATCH")
    n = len(grp)
    return (30 if n >= 4 and k / n < 0.5 else 60), k, n


CONTACT_OUTCOMES = ("CATCH", "RECOIL", "FAIL_EARLY", "FAIL_LATE", "FAIL_OTHER")
BAD_OUTCOMES = ("WHIFF", "FAIL_EARLY", "FAIL_LATE", "FAIL_OTHER")
# 1.4：C8 的「空放/失败」另含 RECOIL —— (2,25) 改判之后 RECOIL 是抵消被破、被弹并随即身体挨打（G1），比不放还糟。
# PLAN 原口径把 RECOIL 单列、不算时机误差，那时 RECOIL 指 cRecoil / 抵消力不够；第 1 轮 RECOIL 为 0，数值不变
C8_BAD = BAD_OUTCOMES + ("RECOIL",)


# ---------------------------------------------------------------- 影子回放（离线按 SER 重算规则 A）
class Shadow:
    """按 DECISION RULE A 重放：DANGER、hs≥L_min、0≤he−hs≤W_long、非弹体、非 EAR/WIND/QUAKE（读不到按通过），
    长窗口否决（任一 DANGER 条目 he−hs>W_long 且 hs≤H_veto 且 he≥0），Q=hs+α(he−hs)，Q*≤L 且在蓄力中就触发。
    1.3：grab=True（v1.5.1 起的 session）另加抓取：抓取条目不进候选；DANGER 抓取条目 hs≤H_veto 且 he≥0 时同样否决
    （否决区间分开存，归因时分得出是长窗口还是抓取）。grab=False 时和 1.2 完全一样。
    影子数据只用来估空放率和评估闸门，只看有没有接触，不看接触时刻（PLAN 测量-3）。
    1.4：sg=True（v1.6 起的 session，或 v1.5.x 上「加该接过滤的假设」）另加 SKILL_GUARD 家族的否决（伤害类型不是抓取的
    GuardType ∈ {SKILL_GUARD, SKILL_GUARD_ALL_RANGE}，口径同抓取，V16 第 3.4 节；同 hs 时 long > grab > sg）；
    replay 的 lmin_q=True 时 L_min 按触发量 q（E5c 的 Q）判断，不按原始 hs（v1.6：22 ≤ Q ≤ L）。sg=False、lmin_q=False 同 1.3。"""

    def __init__(self, ctx, entries, Lmin, Wlong, Hveto, grab=False, sg=False):
        self.ctx, self.Lmin, self.Wlong, self.Hveto, self.grab = ctx, Lmin, Wlong, Hveto, grab
        self.sg = sg
        self.entries = entries
        self.veto = []          # (起, 止)：长窗口
        self.veto_g = []        # (起, 止)：抓取（1.3，只在 grab=True 时有）
        self.veto_s = []        # (起, 止)：SKILL_GUARD 家族（1.4，只在 sg=True 时有）
        # 1.3 修订：数否决段用（shadow_veto_segments）的 (起, 止, 原因, 采样时刻, 采样 hs)。和上面的区间只差一点：同一条目
        # 相邻两格 SER 隔 ≤SEG_BRIDGE（卡顿）时止于下一格、不截在 0.1 s —— rc 每帧求值，卡顿那几帧没有就不会断开否决 streak
        self.veto_info = []
        for e in entries.values():
            for i, s in enumerate(e.samples):
                t, _f, typ, hs, he, _c = s
                if not is_danger(typ) or he is None:
                    continue
                is_long = he - hs > Wlong
                is_grab = grab and entry_grab(e, t) is True
                is_sg = sg and not is_grab and entry_sg(e, t) is True
                if not is_long and not is_grab and not is_sg:
                    continue
                nxt = e.samples[i + 1][0] if i + 1 < len(e.samples) else t + (8.0 if e.approx else SER_STALE)
                if not e.approx:
                    nxt = min(nxt, t + SER_STALE)
                a = max(t, t + (hs - Hveto) / 60.0)
                b = min(nxt, t + he / 60.0)
                if a <= b:
                    if is_long:
                        self.veto.append((a, b))
                    if is_grab:
                        self.veto_g.append((a, b))
                    if is_sg:
                        self.veto_s.append((a, b))
                b2 = b
                if not e.approx and i + 1 < len(e.samples) and e.samples[i + 1][0] - t <= SEG_BRIDGE:
                    b2 = min(e.samples[i + 1][0], t + he / 60.0)
                if a <= b2:
                    if is_long:
                        self.veto_info.append((a, b2, "long", t, hs))
                    if is_grab:
                        self.veto_info.append((a, b2, "grab", t, hs))
                    if is_sg:
                        self.veto_info.append((a, b2, "sg", t, hs))
        self.veto.sort()
        self.veto_starts = [v[0] for v in self.veto]
        self.veto_g.sort()
        self.veto_g_starts = [v[0] for v in self.veto_g]
        self.veto_s.sort()
        self.veto_s_starts = [v[0] for v in self.veto_s]
        self.veto_info.sort()

    @staticmethod
    def _in(ivs, starts, t):
        i = bisect.bisect_right(starts, t)
        return any(a <= t <= b for a, b in ivs[max(0, i - 64):i])

    def veto_at(self, t):
        return (self._in(self.veto, self.veto_starts, t)
                or (bool(self.veto_g) and self._in(self.veto_g, self.veto_g_starts, t))
                or (bool(self.veto_s) and self._in(self.veto_s, self.veto_s_starts, t)))

    def veto_kind_at(self, t):
        """1.3：t 时刻否决的原因：long（长窗口，两种都有时也记 long）/ grab（只有抓取）/ None（没否决）。
        1.4：再加 sg（只有 SKILL_GUARD 家族在否决）。"""
        if self._in(self.veto, self.veto_starts, t):
            return "long"
        if self.veto_g and self._in(self.veto_g, self.veto_g_starts, t):
            return "grab"
        if self.veto_s and self._in(self.veto_s, self.veto_s_starts, t):
            return "sg"
        return None

    def charging(self, t, ep, sample_charge=None):
        tl = self.ctx.tl
        if ep.fire is not None and t >= ep.fire.t_req - 0.02:
            return True       # 反事实：放刀是 mod 造成的，不放的话玩家会一直按住
        if tl.acts:
            return tl.in_charge(t)
        return bool(sample_charge)

    def times(self, ep):
        ts = {s[0] for e in ep.ents for s in episode_samples(ep, e)}
        if ts and any(e.approx for e in ep.ents) and ep.t0 is not None:
            # 只有 TYP（稀疏）时按 60 fps 补一张帧网格，条目状态靠名义倒数外推
            t, t1 = min(ts), (ep.t1 if ep.t1 is not None else max(ts))
            while t <= t1 + 1e-9:
                ts.add(round(t, 6))
                t += 1.0 / 60.0
        return sorted(ts)

    def replay(self, ep, L, alpha=0.0, extra=None, qfun=None, lmin=None, lmin_q=False, after=None):
        """返回第一次触发 Obj(t_L, q, ent, hs, he)；不触发返回 None。qfun(ep,e,t,hs,he) 可替换触发量。
        1.4：lmin_q=True 时 L_min 按 q 判断（E5c：22 ≤ Q ≤ L）；after 给了就只看 t ≥ after 的时刻。"""
        lmin = self.Lmin if lmin is None else lmin
        for t in self.times(ep):
            if after is not None and t < after:
                continue
            best = None
            charge_flag = False
            for e in ep.ents:
                st = entry_state(e, t, lo=(ep.t0 - 0.05) if ep.t0 is not None else None)
                if st is None:
                    continue
                typ, hs, he, _f = st
                i = bisect.bisect_right(e.ts, t) - 1
                charge_flag = charge_flag or bool(e.samples[i][5])
                if not is_danger(typ):
                    continue
                he = hs if he is None else he
                if (not lmin_q and hs < lmin) or not (0 <= he - hs <= self.Wlong):
                    continue
                if entry_shell(e, t) is True or entry_effect(e, t) is True:
                    continue
                if self.grab and entry_grab(e, t) is True:
                    continue          # 1.3：抓取永远不进候选（v1.5.1）
                if extra is not None and not extra(ep, e, t, hs, he):
                    continue
                q = qfun(ep, e, t, hs, he) if qfun else hs + alpha * (he - hs)
                if q is None:
                    continue
                if lmin_q and q < lmin:
                    continue
                if best is None or q < best[0]:
                    best = (q, e, hs, he)
            if best is None or best[0] > L:
                continue
            if not self.charging(t, ep, charge_flag) or self.veto_at(t):
                continue
            return Obj(t_L=t, q=best[0], ent=best[1], hs=best[2], he=best[3])
        return None


def _merge_ivs(ivs, eps=1e-6):
    """区间求并（首尾相接或相隔 ≤eps 的连成一段），返回按起点排序的 [起, 止] 列表。"""
    out = []
    for a, b in sorted(ivs):
        if out and a <= out[-1][1] + eps:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return out


def _intersect_ivs(xs, ys):
    """两组已排序、互不重叠的区间求交。"""
    out, i, j = [], 0, 0
    while i < len(xs) and j < len(ys):
        a, b = max(xs[i][0], ys[j][0]), min(xs[i][1], ys[j][1])
        if a <= b:
            out.append([a, b])
        if xs[i][1] < ys[j][1]:
            i += 1
        else:
            j += 1
    return out


def charge_intervals(tl):
    """主角在 (2,21)/(2,22) 的时间段（ACT 时间线，口径同 ActTimeline.in_charge：第一行 ACT 之前按它的 from）。"""
    acts = tl.acts
    if not acts:
        return []
    out = [[-math.inf, acts[0]["t"]]] if acts[0].get("from") in CHARGE else []
    for i, a in enumerate(acts):
        if a["to"] in CHARGE:
            out.append([a["t"], acts[i + 1]["t"] if i + 1 < len(acts) else math.inf])
    return _merge_ivs(out)


def enabled_intervals(cfg):
    """rc 的启用开关开着的时间段（HDR + CFG 时间线，rc_config 的 state_at；读不到当开着）。"""
    if cfg is None:
        return [[-math.inf, math.inf]]
    ts = sorted(it.t for it in list(cfg.changes) + list(cfg.toggles) + list(cfg.noops))
    edges = [-math.inf] + ts + [math.inf]
    out = []
    for a, b in zip(edges, edges[1:]):
        if cfg.state_at(a if a != -math.inf else (ts[0] - 1.0 if ts else 0.0))[0] is not False:
            out.append([a, b])
    return _merge_ivs(out)


def shadow_veto_segments(shadow, tl, cfg=None):
    """1.3 修订（第 1 轮审查）：影子回放按 rc 的口径数否决段，和 rc 的 VETO 行并列对照（V15 第 9 节第 4 条澄清）。
    rc 每个否决 streak 写一行 VETO：主角在 (2,21)/(2,22)、启用开关开着、否决成立的连续帧算一段，离开蓄力或关开关就断开；
    段首那一帧取触发否决的条目里 hs 最小的那条定原因（long 长窗口 / grab 抓取），hs 一样记 long。这里用影子回放的否决区间
    （按 SER 重建，跨怪）同样连段、同样取段首原因。返回 Counter（键 long / grab）。只作诊断，不进判定。"""
    info = getattr(shadow, "veto_info", None) or []
    if not info or not tl.acts:
        return Counter()
    union = _merge_ivs([(a, b) for a, b, _k, _t, _h in info])
    segs = _merge_ivs(_intersect_ivs(_intersect_ivs(union, charge_intervals(tl)), enabled_intervals(cfg)))
    starts = [x[0] for x in info]
    max_len = max(b - a for a, b, _k, _t, _h in info)
    out = Counter()
    rank = {"long": 0, "grab": 1, "sg": 2}      # 1.4：同 hs 时 long > grab > sg（V16 第 2.4 节）
    for s0, _s1 in segs:
        best = None
        i = bisect.bisect_right(starts, s0 + 1e-6) - 1
        while i >= 0 and info[i][0] >= s0 - max_len - 1e-6:
            a, b, kind, t, hs = info[i]
            i -= 1
            if b < s0 - 1e-6:
                continue
            h = hs - 60.0 * (s0 - t)
            if best is None or h < best[0] - 1e-6 or (abs(h - best[0]) <= 1e-6 and rank[kind] < rank[best[1]]):
                best = (h, kind)
        if best is not None:
            out[best[1]] += 1
    return out


# ---------------------------------------------------------------- 1.4：E5c 影子回放（V16 第 2 节的规则按探针数据离线复算）
def eminfo_core(r):
    """EMINFO 的 comp = get_MotionSpeed_{Action, Random, CoreState, ScaleAdjusted, Replica, WaitPacket}（探针 SPEED_PARTS 的顺序），
    取第 3 个。合法 = 有限数且 C_LO ≤ C ≤ C_HI（V16 第 2.2 节），否则 None（读不到）。"""
    comp = r.get("comp")
    if _is_nil(comp):
        return None
    parts = str(comp).split("/")
    if len(parts) < 3:
        return None
    c = to_num(parts[2])
    return c if c is not None and C_LO <= c <= C_HI else None


class E5c:
    """1.4（V16 第 7 节第 5 条）：E5c 的离线复算。对每个回合（预告结果）：
      m：C1 = 同一只怪（按 SystemIndex）在消息之后 2 s 内的第一条 EMINFO 的 CoreState；之后同一只怪的 EMINFO 按采样时刻
         分段常数更新（SPEED 2.1 n「采到新值那一刻」）；m = max(1, C)。消息后 2 s 内没有合法的 EMINFO = 首帧读不到：永不触发
         （v1.6 的 speedfail 口径），但照样参与否决（否决按原始 hs，在 Shadow 里）。
      X：沿这个结果的 SER 采样帧累加 Δhs·(m_prev − 1)，Δ 取时钟条目（两帧都在的同一条，优先沿用上一帧的）相邻两格 hs 的递减，
         没有共同条目或 Δ 不在 [0, CLOCK_DMAX + 60 × 两格隔开的秒数] 时这一格不累加（V16 第 2.1 节；审查修订：上限随隔开的
         时间放宽，和放刀模块一致——SER 断档、卡顿让一对读数跨好几帧时照常累加，固定 30 会整段丢掉）。
      X0_e、A0_e = 条目第一格 SER 时的 X 和 hs；Q = (hs − (X − X0_e)) / m。
    C 不变时 Q 恒等于 E1 = hs − A0·(1 − 1/m)（自检核对）。采样之间按名义倒数（60/s）外推。只作样本内对照，不进任何判定。"""

    def __init__(self, ctx):
        self.ctx = ctx
        self.core = defaultdict(list)       # SystemIndex -> [(t, C)]，只收合法值
        for r in ctx.eminfo.recs:
            c = eminfo_core(r)
            if c is None:
                continue
            for k in ident_keys(r.get("em")):
                if k[0] == "sys":
                    self.core[k[1]].append((r["t"], c))
        for v in self.core.values():
            v.sort()
        self.cache = {}

    @staticmethod
    def sys_of(ep):
        ks = sorted(k[1] for k in (ep.keys or ()) if k[0] == "sys")
        return ks[0] if ks else None

    def model(self, ep):
        M = self.cache.get(id(ep))
        if M is None:
            M = self.cache[id(ep)] = self._build(ep)
        return M

    def _build(self, ep):
        t_msg = ep.msgs[0]["t"] if getattr(ep, "msgs", None) else ep.t0
        series = self.core.get(self.sys_of(ep), [])
        M = Obj(t_msg=t_msg, c1=None, t_c1=None, nofire=True, why=None, frames=[], ts=[], x0={}, a0={}, skip=0,
                nchg=0, cs=[], cts=[])
        if t_msg is None:
            M.why = "没有消息时刻"
            return M
        ts = [x[0] for x in series]
        i = bisect.bisect_left(ts, t_msg - 1e-6)
        if i >= len(series) or series[i][0] > t_msg + C1_WIN:
            M.why = "消息后 2 s 内没有这只怪的合法 EMINFO（首帧读不到 C）"
            return M
        M.c1, M.t_c1, M.nofire = series[i][1], series[i][0], False
        M.cs, M.cts = series[i:], ts[i:]
        rows = defaultdict(dict)
        for e in ep.ents:
            for s in episode_samples(ep, e):
                if s[3] is not None:
                    rows[s[0]][e.ent] = s[3]
        order = [e.ent for e in ep.ents]
        X, clock, prev = 0.0, None, None
        for t in sorted(rows):
            hm = rows[t]
            m_now = self.m_at(M, t)
            if prev is not None:
                phm, pm, pt = prev
                c = clock if (clock in phm and clock in hm) else next((x for x in order if x in phm and x in hm), None)
                if c is None:
                    M.skip += 1
                else:
                    d = phm[c] - hm[c]
                    if 0.0 <= d <= CLOCK_DMAX + 60.0 * (t - pt):
                        X += d * (pm - 1.0)
                    else:
                        M.skip += 1
                    clock = c
            M.frames.append((t, X, m_now))
            for ent, hs in hm.items():
                if ent not in M.x0:
                    M.x0[ent], M.a0[ent] = X, hs
            prev = (hm, m_now, t)
        M.ts = [x[0] for x in M.frames]
        M.nchg = sum(1 for a, b in zip(M.frames, M.frames[1:]) if abs(a[2] - b[2]) > 1e-4)
        return M

    @staticmethod
    def m_at(M, t):
        """t 时刻的 m：首帧 C 一直用到同一只怪的下一条 EMINFO，之后取 t 之前最近一条（分段常数）。"""
        if not M.cs:
            return None
        i = bisect.bisect_right(M.cts, t) - 1
        return max(1.0, M.cs[max(0, i)][1])

    def q(self, ep, e, t, hs, he=None):
        """E5c 的 Q（真实剩余帧）；首帧读不到 C、或这条条目还没出现时返回 None（不触发）。"""
        M = self.model(ep)
        if M.nofire or not M.frames or e is None:
            return None
        x0 = M.x0.get(e.ent)
        i = bisect.bisect_right(M.ts, t + 1e-9) - 1
        if x0 is None or i < 0:
            return None
        tk, Xk, mk = M.frames[i]
        X = Xk + max(0.0, 60.0 * (t - tk)) * (mk - 1.0)
        return (hs - (X - x0)) / self.m_at(M, t)

    def e1(self, ep, e, t, hs, he=None):
        """影子 E1：hs − A0·(1 − 1/max(1, C1))（C 不变时与 E5c 相同）。"""
        M = self.model(ep)
        if M.nofire or e is None or M.a0.get(e.ent) is None:
            return None
        return hs - M.a0[e.ent] * (1.0 - 1.0 / max(1.0, M.c1))


def g1_extra(ep, e, t, hs, he):
    """Shadow.replay 的 extra：v1.6 的「该接」过滤（V16 第 3 节；读不到按 fc，不进候选）。1.4 审查修订：探针 AP 停用之后
    属性不明（entry_g1x 的 unk）的条目放行，不按 fc —— 那是探针读不到，不是放刀模块读不准（这个 session 的 G1 输出标不可用）。"""
    return entry_g1x(getattr(ep, "ctx", None), e, t) in ("ok", "unk")


def nearest_rec(index, t, keys, ident, before=1.0, after=0.3):
    best = None
    for r in index.window(t - before, t + after):
        if ident.same(keys, ident_keys(r.get("em"))):
            if best is None or abs(r["t"] - t) < abs(best["t"] - t):
                best = r
    return best


def latest_rec(index, lo, hi, keys, ident):
    """[lo, hi] 内同一攻击者最后一条记录（判定时刻能看到的最新信息）。"""
    best = None
    for r in index.window(lo, hi):
        if ident.same(keys, ident_keys(r.get("em"))):
            best = r
    return best


def tgt_is_me(tgt):
    """目标键与 PLAYER/0 比较（PLAN 机制-5：正常抵消时主角的键实测为 PLAYER/0）。读不懂返回 None。"""
    if _is_nil(tgt):
        return None
    s = str(tgt).upper().replace(" ", "")
    m = re.match(r"^([A-Z_]+|-?\d+)(?:[/:_,#.](-?\d+))?$", s)
    if not m:
        return None
    cat, idx = m.group(1), m.group(2)
    is_player = cat == "PLAYER" or (re.fullmatch(r"-?\d+", cat) is not None and int(cat) == ENUMS["CAT"]["PLAYER"])
    if not is_player:
        return False
    return idx is None or int(idx) == 0


def pose_theta(p):
    """来向角（度）：θ = atan2(f.x·v.z − f.z·v.x, f.x·v.x + f.z·v.z)，v = 怪物 − 主角。分量缺失时用 theta 字段。"""
    vals = [p.get(k) for k in ("px", "pz", "fx", "fz", "ex", "ez")]
    if all(v is not None for v in vals):
        px, pz, fx, fz, ex, ez = vals
        vx, vz = ex - px, ez - pz
        if abs(vx) + abs(vz) > 1e-9 and abs(fx) + abs(fz) > 1e-9:
            return math.degrees(math.atan2(fx * vz - fz * vx, fx * vx + fz * vz))
    return p.get("_theta_deg")


def normalize_pose_units(poses):
    """theta 字段按度（探针实现用 math.deg 写，f1 格式）；有 px/pz/fx/fz/ex/ez 分量时优先自己算。"""
    for p in poses:
        p["_theta_deg"] = p.get("theta")
    return "度（有分量时用分量重算）"


SER_MAX_FGAP = 4      # 探针 SER 稀疏时每 4 帧一格；相邻两格帧号差超过它说明中间断了（跟踪中断、换了回合）


def danger_run_frames(e, t, lo=None):
    """触发条目到 t 为止连续 DANGER 的帧数：有帧号用帧号（再加上最后一格到 t 的帧数），否则按时间×60。
    TYP 只在变化时记一格，所以按「本段 DANGER 开始到 t」的时间算。
    往前数时不跨回合（lo = 回合开始）、不跨断档（相邻格帧号差 >4）：条目对象会被怪物复用，以前会把上一招的
    DANGER 也数进来，g5（不足 6 帧）几乎不可能成立、退路 A 的「≥12 帧」被高估（审查 measurement）。"""
    i = bisect.bisect_right(e.ts, t) - 1
    if i < 0 or not is_danger(e.samples[i][2]) or (lo is not None and e.samples[i][0] < lo):
        return None
    j = i
    while j - 1 >= 0 and is_danger(e.samples[j - 1][2]):
        prev, cur = e.samples[j - 1], e.samples[j]
        if lo is not None and prev[0] < lo:
            break
        if not e.approx:
            if prev[1] is not None and cur[1] is not None:
                if cur[1] - prev[1] > SER_MAX_FGAP:
                    break
            elif cur[0] - prev[0] > (SER_MAX_FGAP + 0.5) / 60.0:
                break
        j -= 1
    tail = int(round((t - e.samples[i][0]) * 60.0))
    fi, fj = e.samples[i][1], e.samples[j][1]
    if fi is not None and fj is not None and not e.approx:
        return fi - fj + 1 + tail
    return int(round((t - e.samples[j][0]) * 60.0)) + 1


def em_action_at(ctx, keys, t):
    best = ctx.emstate.last_before(t, lambda s: ctx.ident.same(keys, ident_keys(s.get("em"))))
    return best.get("act") if best else None


GATES = [
    ("g1", "怪物当前目标不是我（getTarget(false,FIRST)≠PLAYER/0）",
     "AI 在打随从/别人时，打我的预告是接收者视角的（TargetCharacter 恒为接收者），攻击多半不来"),
    ("g2", "|来向角|>120°（放刀帧 AxisZ 与怪物根位置）",
     "背后来的攻击，刀在身前，上捞斩的刀上碰撞够不着"),
    ("g3", "_IsParryBreak 为真或 _GuardType=UNABLE_GUARD",
     "攻击参数声明不可抵消/不可防御，放了也接不住"),
    ("g4", "怪物距离 >7 m", "远处的判定多是范围性或会落空的，近身攻击才需要放刀"),
    ("g5", "DANGER 连续不足 6 帧", "刚标 DANGER 就到点，常是评估抖动或转招前的瞬时标记"),
    ("g6", "按怪物总速度缩放 hs/(60·speed)（改触发量，非过滤型）",
     "倒数是名义计时，怪物加速时攻击早到；按速度缩放能把早到拉回"),
    ("g7", "KeepActionID 与怪物当前动作不一致（以动作类变化代替）",
     "怪物已离开预告所属动作（AI 转招），攻击不会按原时间来"),
]


def ep_lo(ep):
    return (ep.t0 - 0.05) if (ep is not None and ep.t0 is not None) else None


def gate_value(gid, ev, ctx=None):
    """返回 True=拦下、False=放行、None=无法判定（按放行处理并计数）。ctx 用事件自己的 session（ev.ctx）。"""
    ctx = getattr(ev, "ctx", None) or ctx
    t, keys, e = ev.t, ev.keys, ev.entry
    if gid == "g1":
        # 判定时刻能看到的最新目标键：[回合开始−0.1（或 t−1 s）, t+0.05] 内同一只怪最后一条 EMINFO。
        # 以前取 t 前 1.0 s / 后 0.3 s 内时间最近的一条：没放刀回合的「首次 DANGER」那条常在这个窗口外，
        # g1 返回无法判定，「目标不是我」被系统性低估（审查 measurement）。+0.05 s 容下 PT 首帧（晚 1 帧）写的 FIRE
        t0 = getattr(ev, "t_first", None)
        lo = min(t - 1.0, t0 - 0.1) if t0 is not None else t - 1.0
        r = latest_rec(ctx.eminfo, lo, t + 0.05, keys, ctx.ident)
        me = tgt_is_me(r.get("tgt")) if r else None
        return None if me is None else (not me)
    if gid in ("g2", "g4"):
        # 只认同一只怪的 POSE（探针 PT 首帧对每只有未结束 DANGER 回合的怪各写一条，带 em）：以前取 ±0.25 s 内
        # 时间最近的一条、不核对 em，场上有第二只怪时会拿另一只怪的角度和距离去评估闸门（审查 measurement）
        best = None
        for p in ctx.pose.window(t - 0.25, t + 0.25):
            if not ctx.ident.same(keys, ident_keys(p.get("em"))):
                continue
            if best is None or abs(p["t"] - t) < abs(best["t"] - t):
                best = p
        if best is None:
            return None
        if gid == "g2":
            th = pose_theta(best)
            return None if th is None else abs(th) > 120.0
        d = best.get("dist")
        return None if d is None else d > 7.0
    if gid == "g3":
        a = entry_attrs(e, t)
        if a is None:
            return None
        pb = a.get("pbreak")
        gt = a.get("guard")
        if pb is None and gt is None:
            return None
        return bool(pb) or enum_is(gt, "GUARD", "UNABLE_GUARD")
    if gid == "g5":
        if e is None:
            return None
        n = danger_run_frames(e, t, lo=ep_lo(ev.ep))
        return None if n is None else n < 6
    if gid == "g7":
        a_now = em_action_at(ctx, keys, t)
        a_0 = em_action_at(ctx, keys, ev.t_first) if ev.t_first is not None else None
        if a_now is None or a_0 is None:
            return None
        return a_now != a_0
    return None      # g6 不是过滤型，见 C6


def build_gate_events(fires, episodes, shadow, entries, ctx, Lstar):
    """C8 评估集：真放刀（用实际结局）+ 在 L* 处会触发、但没真放、且 [t_L, t_L+1.2] 全程在蓄力中的影子回合。
    bad = 空放或失败；潜在接住 = 触发后 1.2 s 内有该攻击者接触。"""
    evs = []
    for f in fires:
        if not f.entered or f.outcome in (None, "UNKNOWN"):
            continue
        e = entries.get((f.res, f.ent))
        pot = any(ctx.ident.same(f.keys, c.keys) for c in ctx.contacts_in(f.t_req, f.t_req + POTENTIAL_WIN))
        evs.append(Obj(kind="real", t=f.t_req, keys=f.keys, entry=e, ep=f.ep, bad=f.outcome in C8_BAD,
                       whiff=f.outcome == "WHIFF", potential=pot, t_first=f.ep.t0 if f.ep else None, fire=f,
                       ctx=ctx))
    shadows = []
    for ep in episodes:
        if ep.fire is not None or not ep.danger or not ep.ents:
            continue
        sh = shadow.replay(ep, Lstar)
        if sh is None:
            continue
        he = sh.he if sh.he is not None else sh.hs
        full = ctx.tl.charge_through(sh.t_L, sh.t_L + SHADOW_CHARGE_WIN) if ctx.tl.acts else bool(ep.charge_all)
        cont = [c for c in ctx.contacts_in(sh.t_L, sh.t_L + he / 60.0 + WHIFF_PAD) if ctx.ident.same(ep.keys, c.keys)]
        whiff = not cont and not ctx.any_in(ctx.ph_ts, sh.t_L, sh.t_L + he / 60.0 + WHIFF_PAD)
        pot = any(ctx.ident.same(ep.keys, c.keys) for c in ctx.contacts_in(sh.t_L, sh.t_L + POTENTIAL_WIN))
        ev = Obj(kind="shadow", t=sh.t_L, keys=ep.keys, entry=sh.ent, ep=ep, bad=whiff, whiff=whiff,
                 potential=pot, t_first=ep.t0, full=full, sh=sh, ctx=ctx)
        shadows.append(ev)
        if full:
            evs.append(ev)
    return evs, shadows


def evaluate_gates(evs, ctx=None):
    """C8：每个候选算「去掉的空放/失败数」和「损失的潜在接住数」；按净收益（去掉−3×损失）贪心，最多 2 个。
    事件可以来自多个 session，各用自己的 ev.ctx 取 EMINFO/POSE/EMSTATE。"""
    table, evaluated = [], 0
    vals = {gid: [gate_value(gid, ev, ctx) for ev in evs] for gid, _d, _m in GATES}
    remaining = list(range(len(evs)))
    chosen = []
    for step in range(GATE_MAX_N):
        best = None
        for gid, desc, mech in GATES:
            if gid == "g6" or gid in [c[0] for c in chosen]:
                continue
            evaluated += 1
            rem = [i for i in remaining if vals[gid][i] is True]
            removed = sum(1 for i in rem if evs[i].bad)
            lost = sum(1 for i in rem if evs[i].potential)
            unknown = sum(1 for i in remaining if vals[gid][i] is None)
            row = Obj(step=step + 1, gid=gid, desc=desc, mech=mech, removed=removed, lost=lost,
                      net=removed - 3 * lost, unknown=unknown, n=len(remaining),
                      ok=removed >= GATE_MIN_REMOVED and lost <= GATE_MAX_LOST)
            table.append(row)
            if row.ok and (best is None or row.net > best.net):
                best = row
        if best is None:
            break
        chosen.append((best.gid, best))
        remaining = [i for i in remaining if vals[best.gid][i] is not True]
    return Obj(table=table, chosen=chosen, evaluated=evaluated, n_events=len(evs),
               n_real=sum(1 for e in evs if e.kind == "real"), n_shadow=sum(1 for e in evs if e.kind == "shadow"))


def fallback_a(evs, ctx):
    """退路 A 回放：只对单条目、he−hs≤30、DANGER 持续 ≥12 帧的条目放刀。用同一评估集统计保留与去掉的结果。"""
    kept = Obj(n=0, bad=0, whiff=0, potential=0)
    dropped = Obj(n=0, bad=0, potential=0, unknown=0)
    for ev in evs:
        e, t = ev.entry, ev.t
        if e is None:
            dropped.unknown += 1
            continue
        lo = ep_lo(ev.ep)
        st = entry_state(e, t, lo=lo)
        n_alive = sum(1 for x in (ev.ep.ents if ev.ep else []) if entry_state(x, t, lo=lo) is not None)
        run = danger_run_frames(e, t, lo=lo)
        width = (st[2] - st[1]) if (st and st[2] is not None) else None
        ok = n_alive <= 1 and width is not None and width <= 30 and run is not None and run >= 12
        tgt = kept if ok else dropped
        tgt.n += 1
        tgt.bad += ev.bad
        tgt.potential += ev.potential
        if ok:
            kept.whiff += ev.whiff
    return kept, dropped


# ---------------------------------------------------------------- C6 估计量与 α
def compare_estimators(episodes, shadow, ctx, L_eval):
    """在「全程在蓄力中」（回合开始到首个接触都在蓄力）的回合上，比较 V0、V1(closest)、α=0.25、α=0.5
    以及 g6（按怪物速度缩放）的残差 IQR。用留一招式中心化：残差减去其他招式残差的中位数后再取 IQR。"""
    msgs_by_obj = defaultdict(list)
    for m in ctx.data.get("pr", "MSG"):
        if m.get("obj") and m.get("t") is not None:
            msgs_by_obj[m["obj"]].append(m)

    def q_v1(ep, e, t, hs, he):
        ms = [m for m in msgs_by_obj.get(ep.obj, []) if m["t"] <= t]
        if not ms or not ms[-1].get("closest"):
            return None
        return hs if ms[-1]["closest"] == e.ent else None

    def q_g6(ep, e, t, hs, he):
        r = nearest_rec(ctx.eminfo, t, ep.keys, ctx.ident, before=2.0, after=0.5)
        sp = r.get("speed_t") if r else None
        return hs / sp if sp and sp > 0.1 else None

    variants = [(C6_VARIANTS[0], dict(alpha=0.0)), (C6_VARIANTS[1], dict(qfun=q_v1)),
                (C6_VARIANTS[2], dict(alpha=0.25)), (C6_VARIANTS[3], dict(alpha=0.5)), (C6_VARIANTS[4], dict(qfun=q_g6))]
    rows = defaultdict(dict)
    for ep in episodes:
        if not ep.danger or not ep.contacts or not ep.ents or ep.t0 is None:
            continue
        tc = ep.contacts[0].t
        # 「全程在蓄力中」= 回合开始（或接触前 1.5 s，取较晚者）到首个接触一直在蓄力：
        # L≤45 时各方案的触发时刻都落在接触前 1.5 s 以内，这样接触时刻是自然到达、没被放刀改变
        if ctx.tl.acts and not ctx.tl.charge_through(max(ep.t0, tc - 1.5), tc - 1e-3):
            continue
        if not ctx.tl.acts and not ep.charge_all:
            continue
        for name, kw in variants:
            sh = shadow.replay(ep, L_eval, **kw)
            if sh is not None and sh.t_L < tc:
                rows[name][(id(ctx), id(ep))] = (tc - (sh.t_L + sh.q / 60.0), (emid_of(ep.keys), ep.keep))
    return rows


C6_VARIANTS = ["V0（逐条最小 hs，α=0）", "V1（closest）", "α=0.25", "α=0.5", "g6 速度缩放"]


def summarize_estimators(rows):
    """C6：各方案和 V0 的共同样本上算残差 IQR 和留一招式 IQR（多个 session 的行先合并）。"""
    base = rows.get(C6_VARIANTS[0], {})
    out = []
    for name in C6_VARIANTS:
        common = [k for k in base if k in rows.get(name, {})]
        rs = [rows[name][k] for k in common]
        out.append(Obj(name=name, n=len(rs), iqr=iqr([r for r, _g in rs]), logo=_logo_iqr(rs),
                       base_logo=_logo_iqr([base[k] for k in common])))
    return out


def _logo_iqr(rs):
    groups = defaultdict(list)
    for r, g in rs:
        groups[g].append(r)
    if len(groups) < 2 or len(rs) < 4:
        return None
    errs = []
    for g, vals in groups.items():
        others = [r for r, gg in rs if gg != g]
        m = median(others)
        errs += [v - m for v in vals]
    return iqr(errs)


# ---------------------------------------------------------------- 归因：DANGER 回合 9 类、漏报 6 类
EP_CLASSES = ["刀上抵消（含刀上接触）", "身体命中", "收尾挨打", "AI 转招", "被打断", "激活但没打中",
              "激活未观测", "目标不是我", "弹体"]
EP_UNKNOWN = "未知（放刀前后没有探针数据）"
MISS_CLASSES = ["没收到消息（攻击者全场无预告）", "没收到消息", "只有 CAUTION", "DANGER 首次出现时已低于 L_min",
                "跨动作", "被长窗口规则否决", "被弹体或效果攻击规则排除", "其他（规则未触发）",
                "放刀区间内不在蓄力"]
# 1.3：v1.5.1 的抓取否决（V15 第 9 节）。排在最后、不插在中间：前面各类的下标和旧报告的行都不动；
# 只有 1.5.1 起的 session（或这一类真的有数）才在报告表里出现
MISS_GRAB = "被抓取规则否决"
MISS_CLASSES.append(MISS_GRAB)
# 1.4：v1.6 的「该接」过滤（V16 第 3 节）：这一招的 DANGER 条目全被排除、其中有只因该接过滤（pb / UNABLE_GUARD / 读不准）
# 排除的 → 这一类。同样追加在最后，只对 1.6 起的 session 生效、只在有 1.6 起的 session（或真的有数）时列出
MISS_G1 = "被该接过滤排除（游戏判定接不住）"
MISS_CLASSES.append(MISS_G1)
# 1.4 审查修订：探针 AP 停用之后，条目的攻击参数探针读不到（entry_g1x 的 unk）：可能是被该接过滤排除，也可能不是，单列，
# 不算进上一类（不按 fc 处理）。同样追加在最后、只在有数时列出
MISS_G1_UNK = "可能被该接过滤排除（探针 AP 停用，属性不明）"
MISS_CLASSES.append(MISS_G1_UNK)


def danger_entries(ep):
    return [e for e in ep.ents if any(is_danger(s[2]) for s in episode_samples(ep, e))]


def ep_contacts(ep):
    """回合的接触：放过刀（且结局已知）的回合用这一刀自己的同攻击者接触（classify_fire 的 f.contacts，
    不经 P23 竞争）；其余回合用 P23 匹配进来的接触。"""
    f = ep.fire
    if f is not None and f.outcome not in (None, "UNKNOWN"):
        return f.contacts
    return ep.contacts


def keep_changed_before(ep, ctx, t_lim, eps_by_obj):
    for m in ctx.msgs_by_obj.get(ep.obj, []):
        if ep.t0 is not None and ep.t0 < m["t"] <= t_lim and m.get("keep") is not None \
                and ep.keep is not None and m["keep"] != ep.keep:
            return True
    for nxt in eps_by_obj.get(ep.obj, []):
        if nxt is not ep and nxt.t0 is not None and ep.t0 is not None and ep.t0 < nxt.t0 <= t_lim \
                and "KEEP" in str(nxt.reason).upper():
            return True
    return False


def attribute_episodes(episodes, ctx):
    eps_by_obj = defaultdict(list)
    for e in episodes:
        eps_by_obj[e.obj].append(e)
    out = Counter()
    notes = Counter()
    for ep in episodes:
        if not ep.danger:
            continue
        f = ep.fire
        cts = ep_contacts(ep)
        if f is not None and f.outcome == "UNKNOWN":
            cls = EP_UNKNOWN
        elif f is not None and f.outcome in ("CATCH", "RECOIL"):
            cls = EP_CLASSES[0]
        elif f is not None and f.outcome == "FAIL_LATE" and f.sub == "收尾挨打":
            cls = EP_CLASSES[2]
        elif any(c.cls == "BLADE" for c in cts):
            cls = EP_CLASSES[0]
        elif cts:
            cls = EP_CLASSES[1]
        else:
            t_ref = f.t_req if f is not None else ((ep.t_hs0 - 0.5) if ep.t_hs0 is not None else ep.t0)
            dents = danger_entries(ep)
            g1 = gate_value("g1", Obj(t=t_ref, keys=ep.keys, entry=None, t_first=ep.t0, ep=ep, ctx=ctx), ctx) \
                if t_ref else None
            t_lim = ep.t_hs0 if ep.t_hs0 is not None else (ep.t1 or 0)
            t_ent = ep.t_hs0 if ep.t_hs0 is not None else ep.t0
            if dents and all(entry_shell(e, t_ent) is True for e in dents):
                cls = EP_CLASSES[8]
            elif g1 is True:
                cls = EP_CLASSES[7]
            elif f is not None and f.sub == "INTERRUPTED":
                cls = EP_CLASSES[4]
            elif keep_changed_before(ep, ctx, t_lim, eps_by_obj):
                cls = EP_CLASSES[3]
            elif ep.t_hs0 is not None and any(
                    ep.t_hs0 - 0.5 <= a["t"] <= ep.t_he0 + WHIFF_PAD and ctx.ident.same(ep.keys, ident_keys(a.get("em")))
                    for a in ctx.atk.window(ep.t_hs0 - 0.5, ep.t_he0 + WHIFF_PAD)):
                cls = EP_CLASSES[5]
            else:
                cls = EP_CLASSES[6]
                notes["ATK 模块全程开启" if ep.atk_on else "ATK 模块未全程开启（未知）"] += 1
        ep.attrib = cls
        out[cls] += 1
    return out, notes


def b_segment_start(ctx, episodes, scans):
    """B 段（真怪）从哪儿算起：第一个 DANGER 回合开始；没有 DANGER 回合时取最后一行 SCAN done；都没有就从头。
    A2 机关扫描里，学习周期和没放出去的周期机关都会打到蓄力中的主角，不能算漏报（审查 measurement：
    mock machine_scan 漏报 4 次、机关覆盖率 0%，会稀释 B 段漏报的比例）。"""
    t_d = [e.t0 for e in episodes if e.danger and e.t0 is not None and e.ents]
    if t_d:
        return min(t_d)
    t_s = [s.t for s in scans if s.phase == "done" and s.t is not None]
    return max(t_s) if t_s else -math.inf


def lead_at(fires_all, t, default_L):
    """t 时刻 rc 用的提前量 L：轮换只在进入 (2,23) 后前进，所以等于 t 之后第一次 FIRE 的 L；之后没有 FIRE 就用默认。"""
    for f in fires_all:
        if f.t_req > t and f.L is not None:
            return f.L
    return default_L


def attribute_misses(ctx, episodes, request_ts, Lmin, Wlong, shadow=None, b_start=-math.inf, fires_all=(),
                     default_L=DEFAULTS["L"], lead_fn=None, auto_fn=None, qfun=None, g1=False):
    """漏报：B 段里蓄力中被敌方打中、且之前 1.5 s 内没有 rc 请求（FIRE/SCAN）的攻击。
    同一攻击者 0.5 s 内的接触算同一次攻击。
    1.1：auto_fn(t) 为 False（rc 的启用开关当时是关的，按 HDR + CFG）时不算漏报，另计 off；
    1.2：这一招的预告回合开始时开关是关的也算 off —— 关着时 v1.5 释放全部跟踪、不收消息，重新打开后不重发消息的预告
    它看不到，不是规则漏了；
    lead_fn(t) 给了就用它取当时的提前量 L（参数冻结的 session 按 CFG 时间线），否则按 1.0 的 lead_at（下一次 FIRE 的 L）。
    「被长窗口规则否决」按规则 A 的全局否决判断：在这一招的 DANGER 条目 Q 落进 [L_min, L] 且主角在蓄力中的时刻，
    影子回放（按 SER 重建的、跨怪的否决区间）是否在否决。以前要求 VETO 的 em 等于被漏的攻击者、且在接触前 1.6 s 内：
    「A 怪的长窗口否决 B 怪的短招」这种设计内的情况、以及否决持续超过 1.6 s 的情况都落进「其他（规则未触发）」，
    读起来像 rc 出了问题（审查 conformance/measurement，exp_veto、mock long_veto）。
    Q 在 [L_min, L] 时主角不在蓄力（之后才按住被打）单列「放刀区间内不在蓄力」。
    1.3：shadow.grab（v1.5.1 起的 session）时按 v1.5.1 的规则归因 —— 抓取条目和弹体、效果攻击一样不进候选；这一招的
    DANGER 条目全被排除且里面有抓取 → 被抓取规则否决；Q 落进区间、在蓄力的时刻全被否决：全在长窗口否决里 → 被长窗口
    规则否决（同 1.2），有的时刻只有抓取在否决（同一只怪的抓取段，或别的怪正在来的抓取）→ 被抓取规则否决。
    1.4：v1.6 起的 session（g1=True、qfun = E5c 的 Q）按 v1.6 的规则归因 —— 触发量用 Q（L、L_min 都是 Q 单位）；「该接」过滤
    （pb / UNABLE_GUARD / 读不准，按探针 ENT）排除的条目和弹体、效果攻击一样不进候选；SKILL_GUARD 家族和抓取一样排除并否决
    （归「被抓取规则否决」）；这一招的 DANGER 条目全被排除、且有只因该接过滤排除的 → 被该接过滤排除。g1=False 时和 1.3 一样。"""
    if not ctx.tl.acts:
        return None
    grab_rule = shadow is not None and getattr(shadow, "grab", False)

    def old_ex(e, t_ent):
        return (entry_shell(e, t_ent) is True or entry_effect(e, t_ent) is True
                or (grab_rule and entry_grab(e, t_ent) is True))

    def g1c(e, t_ent):
        return entry_g1x(ctx, e, t_ent) if g1 else "ok"

    def excluded(e, t_ent):
        return old_ex(e, t_ent) or g1c(e, t_ent) != "ok"

    def q_of(ep, e, s):
        if qfun is None:
            return s[3]
        return qfun(ep, e, s[0], s[3], s[4])
    attacks = []
    for c in ctx.contacts:
        prev = next((a for a in reversed(attacks[-8:])
                     if c.t - a.t_last <= 0.5 and (ctx.ident.same(a.keys, c.keys) or a.keys == c.keys)), None)
        if prev:
            prev.t_last = c.t
            continue
        attacks.append(Obj(t=c.t, t_last=c.t, keys=c.keys, first=c, ctx=ctx))
    rts = sorted(request_ts)
    out = Counter()
    detail = []
    off = []
    for a in attacks:
        if a.t < b_start:
            continue
        if not ctx.tl.in_charge(a.t - 1.0 / 60.0):
            continue
        i = bisect.bisect_left(rts, a.t - 1.5)
        if i < len(rts) and rts[i] <= a.t:
            continue
        ep = a.first.ep
        if auto_fn is not None and (auto_fn(a.t) is False
                                    or (ep is not None and ep.t0 is not None and auto_fn(ep.t0) is False)):
            off.append(a)           # mod 关着时蓄力挨打、或预告在关着时就来了：不是规则漏了
            continue
        same_eps = [e for e in episodes if ctx.ident.same(e.keys, a.keys)]
        if not same_eps or not any(e.ents for e in same_eps):
            # 没有任何预告，或预告从来没有条目（训练机关只发空预告）：都算「全场无预告」
            cls = MISS_CLASSES[0]
        elif ep is None:
            near = [e for e in same_eps if e.t_hs0 is not None and abs(e.t_hs0 - a.t) <= 1.5]
            cls = MISS_CLASSES[4] if any(e.danger for e in near) else (MISS_CLASSES[2] if near else MISS_CLASSES[1])
        elif not ep.danger:
            cls = MISS_CLASSES[2]
        else:
            dents = danger_entries(ep)
            t_ent = ep.t_hs0 if ep.t_hs0 is not None else ep.t0
            L = lead_fn(a.t) if lead_fn is not None else None
            if L is None:
                L = lead_at(fires_all, a.t, default_L)
            # 规则 A 在这一招里本该触发的时刻：DANGER、Q∈[L_min, L]、0≤he−hs≤W_long、非弹体/效果（1.5.1 起另除抓取），
            # 且在接触之前
            win = []
            for e in dents:
                if excluded(e, t_ent):
                    continue
                for s in episode_samples(ep, e):
                    if s[0] >= a.t or not is_danger(s[2]) or s[4] is None:
                        continue
                    q = q_of(ep, e, s)      # 1.4：v1.6 起是 E5c 的 Q；更早的版本就是 hs
                    if q is not None and Lmin <= q <= L and 0 <= s[4] - s[3] <= Wlong:
                        win.append(s[0])
            firsts = [(e, next(s for s in episode_samples(ep, e) if is_danger(s[2]))) for e in dents]
            charging = [t for t in win if ctx.tl.in_charge(t)]
            q_firsts = [q for q in (q_of(ep, e, s) for e, s in firsts) if q is not None]
            if dents and all(excluded(e, t_ent) for e in dents):
                # 1.3：被排除的条目里有抓取 → 被抓取规则否决（抓取本身就会否决整帧）；1.5 及更早的 session 不会走到这里
                # 1.4：SKILL_GUARD 家族（v1.6）同抓取；只因该接过滤排除的 → 被该接过滤排除
                if grab_rule and any(entry_grab(e, t_ent) is True or g1c(e, t_ent) == "sg" for e in dents):
                    cls = MISS_GRAB
                elif g1 and any(not old_ex(e, t_ent) and g1c(e, t_ent) in ("pb", "ug", "fc") for e in dents):
                    cls = MISS_G1
                elif g1 and any(not old_ex(e, t_ent) and g1c(e, t_ent) == "unk" for e in dents):
                    cls = MISS_G1_UNK
                else:
                    cls = MISS_CLASSES[6]
            elif charging and shadow is not None and all(shadow.veto_at(t) for t in charging):
                # 1.3：全在长窗口否决里同 1.2；有的时刻只有抓取在否决 → 被抓取规则否决（grab=False 时没有抓取区间）
                # 1.4：SKILL_GUARD 家族的否决（v1.6）也归「被抓取规则否决」
                cls = MISS_CLASSES[5] if all(shadow.veto_kind_at(t) == "long" for t in charging) else MISS_GRAB
            elif charging:
                cls = MISS_CLASSES[7]
            elif win:
                cls = MISS_CLASSES[8]
            elif firsts and all(s[4] is not None and s[4] - s[3] > Wlong for _e, s in firsts):
                cls = MISS_CLASSES[5]       # 只有长窗口条目：本身不触发，只否决
            elif q_firsts and min(q_firsts) < Lmin:
                cls = MISS_CLASSES[3]
            else:
                cls = MISS_CLASSES[7]
        out[cls] += 1
        detail.append((a, cls))
    return Obj(counts=out, detail=detail, n=len(detail), off=off)


# ---------------------------------------------------------------- C9、C10、D
OVERHEAD_MAX = 0.05     # C9(d)：mod 开销占帧时间的比例 ≤5%（即估计的 fps 中位数下降 ≤5%）


def _num_field(rec, name):
    return to_num(rec.get(name)) if rec is not None else None


def perf_check(data, t_max=None, t_ok=None):
    """t_max：只用 t < t_max 的 PERF 周期（1.1：D 节只用第一次参数改动之前的数据；C9(d) 不给，用全程）。
    t_ok(t)：另外只用它返回真的周期（1.2：D 不用启用开关关着的时段，那时 rc 几乎不干活，开销会偏低）。
    C9(d) 的 fps 部分（部署前定的口径，见报告 C9 节）：
    以前拿「第一条 PERF 起 10 s 内的中位数」（刚 Reset 完、多半在训练场）和全程中位数（大半是野外 B 段）比：
    本机同一会话、mod 不变，训练场/标题 147~163 fps、野外约 80~99 fps，场景差异远大于 5% 门槛，(d) 几乎必然判否
    （审查 conformance/measurement）。第 1 轮没有「mod 关着」的同场景基线，所以改成直接估 mod 的开销：
      开销占比 = （探针每帧帧回调耗时 + rc 每帧帧回调耗时）× fps + 两个脚本钩子体每秒耗时，再除以 1000 ms
    ——主线程上多出这么多毫秒，fps 大约就降这么多比例。取各 PERF 周期的中位数，≤5% 通过。
    REF 的钩子分发开销 os.clock 量不到（PLAN「性能与日志预算」），只能报各钩子每秒调用次数作参考。
    fps 只按场景（PROG 阶段、一帧 >1 s 的断档）分段描述，不当门槛。"""
    perf = [p for p in data.get("pr", "PERF") if p.get("t") is not None and p.get("fps") is not None
            and (t_max is None or p["t"] < t_max) and (t_ok is None or t_ok(p["t"]))]
    stats = sorted((s for s in data.get("rc", "STAT") if s.get("t") is not None), key=lambda s: s["t"])
    stat_ts = [s["t"] for s in stats]
    shares, n_rc, n_rc_missing = [], 0, 0
    for p in perf:
        fps = p["fps"]
        lua = _num_field(p, "lua_ms_avg")
        if lua is None or not fps:
            continue
        hook = _num_field(p, "hook_ms_ps") or 0.0
        ms_ps = lua * fps + hook
        i = bisect.bisect_left(stat_ts, p["t"])
        st = stats[i] if i < len(stats) else (stats[-1] if stats else None)
        rl = _num_field(st, "lua_ms_avg")
        if rl is not None:
            ms_ps += rl * fps + (_num_field(st, "hook_ms_ps") or 0.0)
            n_rc += 1
        else:
            n_rc_missing += 1
        shares.append(ms_ps / 1000.0)
    # 场景分段：PROG 的阶段（A1/A2/B）× 断档（GAP > 1 s，读盘/切场景）
    progs = sorted((r for r in data.get("pr", "PROG") if r.get("t") is not None), key=lambda r: r["t"])
    prog_ts = [r["t"] for r in progs]
    gaps = sorted(r["t"] for r in data.get("pr", "GAP") if r.get("t") is not None and (r.get("dt") or 0) > 1.0)
    segs = defaultdict(list)
    for p in perf:
        i = bisect.bisect_right(prog_ts, p["t"]) - 1
        ph = str(progs[i].get("phase")) if i >= 0 else "?"
        k = bisect.bisect_right(gaps, p["t"])
        segs[(k, ph)].append(p["fps"])
    hooks = defaultdict(list)
    for p in perf:
        for part in str(p.get("hooks") or "").split(","):
            name, _c, v = part.partition(":")
            if _c and to_num(v) is not None:
                hooks[name.strip()].append(to_num(v))
    if not perf:
        return None
    actfail = sum(to_int(p.get("actfail")) or 0 for p in perf)
    readfail = max([to_int(s.get("readfail")) or 0 for s in stats] or [0])
    return Obj(n=len(perf), share=median(shares), share_max=max(shares) if shares else None, n_share=len(shares),
               actfail=actfail, readfail=readfail,
               n_rc=n_rc, n_rc_missing=n_rc_missing, med=median([p["fps"] for p in perf]),
               segs=[(k, ph, len(v), median(v)) for (k, ph), v in sorted(segs.items())],
               hooks={k: median(v) for k, v in hooks.items()})


def critical_errors(data):
    """关键错误 = 进入「红」状态的记录（两个脚本的 RED：核心模块 10 s 内 ≥3 次、rc 自停、加载缺核心项、自检2 核心项失败），
    和 HUD 标红、用户按协议停下的口径一致。以前把每一条 level=red 的 ERR（核心模块的任何一次出错）都算关键错误：
    HUD 只标黄、协议说黄色继续打，分析却判补测、C9(d) 不通过（审查 measurement）。零星核心错误单列。"""
    red_states = [r for s in ("pr", "rc") for r in data.get(s, "RED")]
    core = [r for s in ("pr", "rc") for r in data.get(s, "ERR") if str(r.get("level") or "").lower() == "red"]
    yellow = [r for s in ("pr", "rc") for r in data.get(s, "ERR") if str(r.get("level") or "").lower() == "yellow"]
    st_fail = [r for r in data.get("pr", "SELFTEST") if r.get("ok") is not None and r.get("total") is not None
               and r["ok"] < r["total"]]
    # rc 的 STAT 计数和 ERR 记录对一对：STAT 的核心错误数比 ERR level=red 的行多，说明有错误没记下来
    gap = None
    stats = [s for s in data.get("rc", "STAT") if to_num(s.get("red")) is not None]
    if stats:
        n_stat = to_int(stats[-1].get("red")) or 0
        n_rows = sum(1 for r in core if r.get("_src") == "rc")
        if n_stat > n_rows:
            gap = (n_stat, n_rows)
    return Obj(red=len(red_states), red_rows=red_states, core=len(core), core_rows=core, yellow=len(yellow),
               yellow_rows=yellow, selftest_fail=st_fail, stat_gap=gap)


def _hdr_flag(v):
    """HDR 的 rotation / scan：rc 写 1/0（JSON 里是数字，日志里是文本），也认 true/on 和轮换档列表（含逗号）。"""
    s = str(v if v is not None else "").strip().lower()
    return s in ("1", "true", "on", "yes") or "," in s


def _onoff(v):
    return "—" if v is None else ("开" if v else "关")


def _lead_s(v):
    return "—" if v is None else (str(int(v)) if float(v).is_integer() else f"{v:.1f}")


def rc_config(data, fires=()):
    """rc 的参数状态时间线：加载时的 HDR + 之后每次改动的 CFG（v1.5，V15 第 4 节）。
    D 节「验收只用第一次改动之前的数据」（PLAN D：滑块的改动）的截断点 cut 取下面几个来源里最早的：
      ① 第一条改了提前量的 CFG：和上一个状态（第一条和 HDR 比）相比提前量变了。和上一状态完全相同的 CFG
         不算改动、单列计数 —— rc 只在改动时写 CFG，万一实现在加载时也写一行基线，不能因此把整轮数据都截掉；
         上一状态未知（缺 HDR）或提前量字段缺失时按改动算（宁可多截）。
         1.2：只改了启用开关的 CFG（toggles）不截断 —— 开关不改规则参数，关着的时段本来就不放刀、挨打另计（off），
         D 再排除关着的时段（acceptance）。1.1 把开关也当改动：第 1 轮后关掉、第 2 轮开局在菜单打开，整轮就全截掉了；
      ② 兜底（1.0 原有）：L 不轮换时第一个 FIRE.L ≠ HDR.lead 的放刀（CFG 丢了也截得住滑块改动）；
      ③ 1.0 认过的 SLIDER / LEAD 记录（没有哪个版本写过，保留兼容）。
    轮换（标定轮）session 的 FIRE.L 本来就在变，不做 ②。
    release = 发布版（ver 不含 rc、不轮换、没有扫描）：参数冻结，D 是正式验收；漏报归因用 HDR 的 L_min、W_long、H_veto
    和 CFG 时间线上的提前量（_analyze_core）。"""
    hdr = data.get("rc", "HDR")
    h = hdr[-1] if hdr else None
    ver = str(h.get("ver") or "") if h else ""
    rotating = _hdr_flag(h.get("rotation")) if h else False
    scan_cfg = _hdr_flag(h.get("scan")) if h else False
    has_scan = bool(data.get("rc", "SCAN"))
    lead0 = to_num(h.get("lead")) if h else None
    auto0 = to_bool(h.get("auto_parry")) if h else None
    timeline, changes, noops, toggles = [], [], [], []
    st_a, st_l = auto0, lead0
    for r in sorted((r for r in data.get("rc", "CFG") if r.get("t") is not None), key=lambda r: r["t"]):
        a, l = to_bool(r.get("auto_parry")), to_num(r.get("lead"))
        same_a = a is not None and st_a is not None and a == st_a
        same_l = l is not None and st_l is not None and abs(l - st_l) <= 1e-6
        what = []
        if not same_a:
            what.append(f"开关 {_onoff(st_a)}→{_onoff(a)}")
        if not same_l:
            what.append(f"提前量 {_lead_s(st_l)}→{_lead_s(l)}")
        item = Obj(t=r["t"], auto=a, lead=l, prev=(st_a, st_l), what="，".join(what) or "未变", rec=r)
        if a is not None:
            st_a = a
        if l is not None:
            st_l = l
        timeline.append((r["t"], st_a, st_l))
        (noops if (same_a and same_l) else toggles if same_l else changes).append(item)
    t_inf = f_inf = None
    if h is not None and not rotating and lead0 is not None:
        for f in sorted((f for f in fires if f.t_req is not None), key=lambda f: f.t_req):
            if f.L is not None and abs(f.L - lead0) > 1e-6:
                t_inf, f_inf = f.t_req, f
                break
    t_leg = None
    for kind in ("SLIDER", "LEAD"):
        for r in data.get("rc", kind):
            if r.get("t") is not None and (t_leg is None or r["t"] < t_leg):
                t_leg = r["t"]
    cands = ([(changes[0].t, "CFG")] if changes else []) + ([(t_inf, "推断")] if t_inf is not None else []) \
        + ([(t_leg, "SLIDER/LEAD")] if t_leg is not None else [])
    cut, cut_src = min(cands) if cands else (None, None)
    ts = [x[0] for x in timeline]

    def state_at(t):
        """t 时刻 rc 的（启用开关, 提前量）：HDR，之后按 CFG 逐条更新。"""
        i = bisect.bisect_right(ts, t) - 1
        return (auto0, lead0) if i < 0 else (timeline[i][1], timeline[i][2])

    release = h is not None and not rotating and not scan_cfg and not has_scan and "rc" not in ver.lower()
    # 1.3：这个 session 的 rc 有没有抓取否决（v1.5.1 起）：按版本号；版本号认不出来时，VETO 带 why 也说明是 1.5.1 起的
    # 1.4：版本号认不出来、但 HDR 带 rule=E5c 的按 1.6（rc_version）
    rule = to_str(h.get("rule")) if h else None
    vt = rc_version(ver, rule)
    grab = (vt is not None and vt >= GRAB_SINCE) or any(r.get("why") is not None for r in data.get("rc", "VETO"))
    return Obj(hdr=h, ver=ver, rotating=rotating, scan_cfg=scan_cfg, has_scan=has_scan, release=release,
               lead0=lead0, auto0=auto0, lmin=to_num(h.get("L_min")) if h else None,
               wlong=to_num(h.get("W_long")) if h else None, hveto=to_num(h.get("H_veto")) if h else None,
               changes=changes, noops=noops, toggles=toggles, cut=cut, cut_src=cut_src, t_inf=t_inf, f_inf=f_inf,
               state_at=state_at, grab=grab,
               # 1.4（V16 第 6.1 节）：HDR 的新字段；e5c / g1 = 这个 session 的 rc 是不是按 v1.6 的规则（E5c 触发量、该接过滤）
               rule=rule, filter=to_str(h.get("filter")) if h else None, cfg_ver=to_int(h.get("cfg_ver")) if h else None,
               c_lo=to_num(h.get("c_lo")) if h else None, c_hi=to_num(h.get("c_hi")) if h else None, vt=vt,
               e5c=vt is not None and vt >= E5C_SINCE, g1=vt is not None and vt >= G1_SINCE,
               # 1.5：HDR 带 host = 合并版（AutoGuardGS v1.5 写的放刀记录，MERGE 第 4 节）：只有 HDR、FIRE、RES、ERR、RED
               host=to_str(h.get("host")) if h else None, enum_skip=to_str(h.get("enum_skip")) if h else None,
               merged=bool(h and to_str(h.get("host"))))


def version_tuple(ver):
    """1.3：版本号「1.5.1」→ (1, 5, 1)；带 rc 等后缀、或者认不出来的返回 None。"""
    m = re.fullmatch(r"\s*v?(\d+(?:\.\d+)*)\s*", str(ver or ""))
    return tuple(int(x) for x in m.group(1).split(".")) if m else None


def rc_version(ver, rule=None):
    """1.4（V16 第 7 节第 2 条）：rc 的有效版本。版本号认得出来就用它（比 1.6 新的沿用 1.6 的口径）；认不出来、但 HDR 带
    rule=E5c 的按 1.6；都不是返回 None（按 1.5，1.2 的口径）。"""
    vt = version_tuple(ver)
    if vt is None and str(rule or "").strip().upper() == "E5C":
        return E5C_SINCE
    return vt


def frozen_table(ver, rule=None):
    """1.3：发布版 ver 的冻结参数 ((名字, cfg 属性, 值), ...)。提前量按 FROZEN_LEAD_BY_VER 取不超过 ver 的最新一档
    （1.5 → 26，1.5.1 → 30）；版本号认不出来按 1.5（1.2 的口径）。L_min、W_long、H_veto 各版本相同。
    1.4：1.6 及以后 → 28（Q 单位）；版本号认不出、但 rule=E5c 的按 1.6。v1.6 另有两项文本冻结值（rule、filter），见 frozen_mismatch。"""
    vt = rc_version(ver, rule)
    lead = FROZEN_LEAD_BY_VER[0][1]
    for v, L in FROZEN_LEAD_BY_VER:
        if vt is not None and vt >= v:
            lead = L
    return (("提前量", "lead0", lead),) + FROZEN[1:]


def frozen_doc(ver, rule=None):
    """1.4：冻结值出自哪份规格（报告措辞）：1.6 起是 V16，更早的是 V15（旧报告的文字不变）。"""
    vt = rc_version(ver, rule)
    return "V16" if vt is not None and vt >= E5C_SINCE else "V15"


def release_defaults(ver, rule=None):
    """1.3：发布版报告的默认列、样本不足时的回退值：V15_DEFAULTS 的提前量换成这个版本的冻结值。"""
    d = dict(V15_DEFAULTS)
    d["L"] = frozen_table(ver, rule)[0][2]
    return d


def newest_version(vers):
    """1.3：几个版本号里最新的那个（按 version_tuple；认不出来的排在最前）；没有返回 None。"""
    vers = [v for v in vers if v]
    return max(vers, key=lambda v: version_tuple(v) or (0,)) if vers else None


def frozen_mismatch(cfg):
    """1.2：发布版 session 加载时（HDR）和 V15 冻结值不一样的参数（读不到的也算不一样）。
    1.3：冻结值按这个 session 自己的版本取（frozen_table：1.5 的提前量 26，1.5.1 的 30）。"""
    bad = []
    rule = getattr(cfg, "rule", None)
    for name, attr, want in frozen_table(getattr(cfg, "ver", ""), rule):
        v = getattr(cfg, attr, None)
        if v is None or abs(v - want) > 1e-6:
            bad.append(f"{name}={_lead_s(v)}（冻结值 {want}）")
    # 1.4：v1.6 的冻结值另有 rule=E5c、filter=g1（V16 第 7 节第 4 条）；大小写不论
    if getattr(cfg, "e5c", False):
        for attr, want in FROZEN_RULE_16:
            v = getattr(cfg, attr, None)
            if str(v or "").strip().lower() != want.lower():
                bad.append(f"{attr}={v if v is not None else '—'}（冻结值 {want}）")
    return bad


def slider_cutoff(data, fires):
    """（1.0 的接口，保留）D 的截断时刻和是否轮换；口径见 rc_config。"""
    c = rc_config(data, fires)
    return c.cut, c.rotating


def stat_total(stats, name):
    """STAT 里某个累计计数的合计。rc 的计数从加载（或菜单「清零统计」）起累加，每 60 s 写一行：
    后一行比前一行小 = 中间清零过，从新值接着加。清零前最后一行 STAT 之后的增量看不到，所以合计是下界。
    返回 (合计, 带这个字段的行数)；一行都没有返回 (None, 0)（旧版 rc 没有这个字段）。"""
    total = prev = n = 0
    for s in stats:
        v = to_int(s.get(name))
        if v is None:
            continue
        n += 1
        total += (v - prev) if v >= prev else v
        prev = v
    return (total if n else None), n


# ---------------------------------------------------------------- 主流程
class Section:
    """每节独立计算；非 strict 模式下出错只记进报告，不让整份报告崩掉（CONTRACT 6：样本不足如实报告）。"""

    def __init__(self, R, strict):
        self.R, self.strict = R, strict

    def run(self, name, fn):
        try:
            return fn()
        except Exception as e:  # noqa: BLE001  分析脚本对任何数据形态都要能出报告
            if self.strict:
                raise
            self.R.errors.append(f"{name}：{type(e).__name__}: {e}")
            return None


def label_scan(scans, ctx):
    used = []
    for s in scans:
        if s.phase != "fire" or s.status != "OK" or s.t_req is None:
            continue
        t_start = s.t_start if s.t_start is not None else s.t_req + ctx.delta
        cs = ctx.contacts_in(s.t_req - 0.05, s.t_req + SCAN_CONTACT_MAX)
        i = bisect.bisect_left(ctx.ph_ts, s.t_req - 0.05)
        ph = ctx.ph[i] if i < len(ctx.ph_ts) and ctx.ph_ts[i] <= s.t_req + SCAN_CONTACT_MAX else None
        cands = [(c.t, c.rec) for c in cs] + ([(ph["t"], ph)] if ph is not None else [])
        if not cands:
            s.label = "无接触"
            continue
        tc, rec = min(cands, key=lambda x: x[0])
        s.c_first = tc - t_start
        s.first_rec = rec
        s.t_start_used = t_start
        t_cr, _t_nx = attempt_bounds(s.t_req, t_start, getattr(s, "next_req", None), ctx)
        if ctx.tl.first(s.t_req, t_cr, lambda a: a["to"] in CATCH_ACTS):
            s.label = "PARRY"
        elif ctx.recoil_in(s.t_req, t_cr):
            s.label = "RECOIL"
        else:
            s.label = "FAIL"
        used.append(s)
    return used


def reset_outcome(f):
    f.outcome = f.sub = f.tier = f.clean = None
    f.c_first = None
    f.c_first_rec = None
    f.contacts = []


def crossing_of(f, entries):
    """这一刀是不是「穿越 L」触发的：触发条目在请求前一帧（同一回合里、半帧以上之前、0.05 s 以内）的读数是 DANGER、
    hs > L、主角在蓄力中 → True；读数已经 ≤ L、或前一帧还没有这个条目 / 不在蓄力 / 不是 DANGER → False（晚触发）；
    只有日志兜底的 TYP（稀疏）或缺 L → None（按穿越处理）。C3 的 d̄ 只用 True 的样本（PLAN：d̄ 是帧离散化偏差）。
    1.4：v1.6 的放刀直接看 FIRE 的 Qp（触发条目上一个帧回调的 Q；那一帧没在蓄力或没算过 Q 就没有）：Qp > L ⇔ 穿越 L 触发
    （V16 第 6.2 节），没有 Qp 就是晚触发；缺 L 按穿越处理。"""
    if getattr(f, "e5c", False):
        if f.L is None:
            return None
        return f.Qp is not None and f.Qp > f.L
    e = entries.get((f.res, f.ent))
    if e is None or e.approx or f.L is None or f.R0 is None:
        return None
    i = bisect.bisect_left(e.ts, f.t_req - 0.004) - 1
    if i < 0:
        return False
    s = e.samples[i]
    if f.t_req - s[0] > 0.05:
        return False
    return bool(is_danger(s[2]) and s[3] is not None and s[3] > f.L and s[5])


class Sess:
    """一个 session（一次 Reset 加载）的数据和各自的时间轴（os.clock 在游戏重启后归零，不同 session 不能合并时间轴）。
    analysis：它的放刀、回合、接触进 B/C2~C10；calib：它的扫描、空挥、δ 进定窗口（C1）和 T_armor。"""

    def __init__(self, data, analysis=True, calib=True):
        self.data, self.analysis, self.calib = data, analysis, calib
        ch = data.info.get("chosen") or {}
        self.label = f"APCal {fmt(ch.get('pr'))} / AutoParryGS {fmt(ch.get('rc'))}"
        self.target = data.info.get("target")
        self.ctx = None
        self.entries, self.by_obj, self.episodes = {}, {}, []
        self.fires_all, self.fires, self.scans, self.pts, self.manual, self.scan_void_pts = [], [], [], [], [], []
        self.ds, self.swing_vals, self.n_swing, self.scan_used = [], [], 0, []
        self.match = Obj(total=0, matched=0, unmatched=0, ambiguous=0, no_pred_attacker=0)
        self.demote = Obj(n=0, st2_sysidx=False, disjoint=False, ct_sys=0, ep_sys=0)
        self.cfg = None             # rc 参数状态（HDR + CFG，rc_config）
        self.miss_params = None     # 漏报归因实际用的 L_min / W_long（参数冻结的 session 取 HDR）
        self.e5 = None              # 1.4：E5c 的离线复算（_analyze_core 里建）


def prepare_session(ss, S):
    """第一步（与定标无关）：组装条目、回合、放刀、扫描、PT，P23 匹配，收集 δ 和空挥样本。"""
    data = ss.data
    try:
        ctx = Ctx(data)
    except Exception:  # noqa: BLE001  记录结构坏到连索引都建不起来：用空上下文
        if S.strict:
            raise
        ctx = Ctx(Data())
        ctx.data = data
    ss.ctx = ctx
    entries, by_obj = build_entries(data)
    ss.entries, ss.by_obj = entries, by_obj
    episodes = build_episodes(data, by_obj)
    fires_all = build_fires(data, ctx.tl)
    scans = build_scan(data)
    req = sorted([q.t_req for q in fires_all if q.t_req is not None] + [s.t_req for s in scans if s.t_req is not None])
    for q in fires_all + scans:
        q.ctx, q.sess = ctx, ss.label
        q.next_req = None
        if q.t_req is not None:
            i = bisect.bisect_right(req, q.t_req + 1e-6)
            q.next_req = req[i] if i < len(req) else None
    fires = [f for f in fires_all if f.entered]
    # 1.4：这个 session 的 rc 是不是 v1.6（E5c）：放刀的 L、Q0 是 Q 单位（fire_reading、crossing_of 按它）
    cfg0 = rc_config(data, fires_all)
    for f in fires_all:
        f.e5c = bool(cfg0.e5c)
    for f in fires:
        f.crossing = crossing_of(f, entries)
        f.emhit_first = None
    ss.fires_all, ss.fires, ss.scans = fires_all, fires, scans
    pts = link_pts(data, ctx.tl, fires + [s for s in scans if s.phase == "fire" and s.status == "OK"])
    ss.pts = pts
    marks = sorted(req + [p.t_obs for p in pts])
    for p in pts:
        i = bisect.bisect_right(marks, p.t_obs + 1e-6)
        p.next_req = marks[i] if i < len(marks) else None
    # 没对上 rc 请求的 PT：附近有作废的扫描样本（VOID 行常常没有 t_req）就算扫描作废，其余才是手动放刀
    void_ts = sorted(s.t for s in scans if s.phase == "fire" and s.status != "OK" and s.t is not None)
    ss.scan_void_pts = [p for p in pts if p.owner is None and ctx.any_in(void_ts, p.t_obs - 0.25, p.t_obs + 2.5)]
    ss.manual = [p for p in pts if p.owner is None and p not in ss.scan_void_pts]
    ss.ds = [q.t_start - q.t_req for q in fires + scans
             if q.t_start is not None and q.t_req is not None and q.t_start_src in ("PT", "ACT")
             and -0.05 <= q.t_start - q.t_req <= 0.25]
    # 回合时刻、身份、P23 匹配
    synth = link_fire_episodes(fires, episodes)
    episodes = episodes + synth
    for ep in episodes:
        ep.ctx = ctx
        if ep.timing is None:
            shadow_timing(ep)
    ss.episodes = episodes
    ss.demote = demote_contact_sys(ctx.contacts, episodes, data)
    ctx.ident.learn(ctx.contacts, episodes)
    ss.match = match_contacts(ctx.contacts, episodes, ctx.ident)
    ss.t_armor_med, ss.swing_vals, ss.n_swing = S.run(f"T_armor（{ss.label}）",
                                                      lambda: estimate_t_armor(data, ctx.tl, pts, ctx.contacts)) \
        or (None, [], 0)


def set_calibration(sessions, cal):
    for ss in sessions:
        ss.ctx.W0, ss.ctx.W1, ss.ctx.W1_eff, ss.ctx.cens1, ss.ctx.delta = cal.W0, cal.W1, cal.W1_eff, cal.cens1, cal.delta


def first_contact_clocks(rec, ctx, t_contact):
    """离线 1：首个接触在三种时钟下的时刻（相对 (2,23) 开始）：raw（动作的 _RawTotalElapsedSecond）、
    chara（get_CharaElapsedSecond，含顿帧）、动画层 Frame/60。只在接触时主角动作是 (2,23) 时有意义。"""
    if rec is None:
        return None, None, None
    act = rec.get("act")
    raw = chara = anim = None
    if act == SLASH or rec.get("k") == "PH":
        raw, chara = rec.get("raw"), rec.get("chara")
    i = bisect.bisect_left(ctx.anim_ts, t_contact - 0.02)
    best = None
    while i < len(ctx.anim) and ctx.anim_ts[i] <= t_contact + 0.02:
        a = ctx.anim[i]
        if best is None or abs(a["t"] - t_contact) < abs(best["t"] - t_contact):
            best = a
        i += 1
    if best is not None and best.get("frame") is not None and ctx.tl.at(best["t"]) == SLASH:
        anim = best["frame"] / 60.0
    return raw, chara, anim


def init_result(data, ctx):
    """所有报告字段先填默认值：主流程中途出错时报告照样能出，缺的部分写「样本不足」或内部错误。"""
    return Obj(errors=[], data=data, info=data.info, ctx=ctx, fatal=None, entries={}, ser_mode="无",
               fires_all=[], fires=[], scans=[], pts=[], manual=[], scan_void_pts=[], manual_out=Counter(), episodes=[],
               match=Obj(total=0, matched=0, unmatched=0, ambiguous=0, no_pred_attacker=0), n_danger=0,
               t_armor=None, t_armor_vals=[], n_swing=0, scan_used=[], win_scan=estimate_window([], None),
               win_real=None, win_source="先验（扫描样本不足）", win_prior=True, agree=(0, 0, []),
               delta_n=0, delta_prior=True, dbar=0.5, dbar_vals=[], dbar_prior=True, dbar_late=0, res=[],
               res_excluded=Counter(), model=residual_model([]), N={L: 0 for L in L_GRID}, Lstar=None, Nmax=0, cv=None,
               lmin=None, lmin_raw=None, wlong=DEFAULTS["W_long"], wlong_k=0, wlong_n=0, L_use=DEFAULTS["L"],
               lmin_use=DEFAULTS["L_min"], c6=[], gate_events=[], shadows=[], gates=None, fbA=None, pose_unit="—",
               F_actual=None, F_actual_noint=None, F_shadow=None, F_shadow_n=0, F=None, F_noint=None, n_int=0,
               ep_attr=(Counter(), Counter()), misses=None,
               err=Obj(red=0, red_rows=[], core=0, core_rows=[], yellow=0, yellow_rows=[], selftest_fail=[],
                       stat_gap=None), fps=None, perf=[], c9=[], c9_pass=False, c10=[], n_contact=0, d_cut=None,
               d_rotating=False, d_catch=(0, 0), d_whiff=(0, 0), d_per={}, sessions=[], calib_sessions=[],
               cal=Obj(W0=W_PRIOR[0], W1=W_PRIOR[1], W1_eff=W_PRIOR[1], cens1=False, delta=DELTA_PRIOR),
               t_armor_conflict=False, outside_p23=0, crashed_flag=False, offline1=None, unclean=[],
               # 1.1：D 验收（acceptance）和定标 session 缺失的提示
               d_sess=[], d_mode="fixed", d_whiff_noint=(0, 0), d_int=0, d_first_hit_other=0, d_unknown=0,
               d_miss_by={}, d_off=0, d_protocol=None, d_stat=[], d_items=[], d_verdict=None, calib_missing=[],
               d_scope=None, release_all=False,
               # 1.3：发布版的版本、按版本的默认列（冻结值），VETO 的 why 计数，有没有 1.5.1 起的 session（抓取否决）；
               # 1.3 修订：影子否决段（1.5.1 起的 session，按 rc 的口径）和同一批 session 的 VETO why
               release_ver=None, release_dflt=None, veto_why=Counter(), grab_rule=False,
               veto_shadow=None, veto_shadow_rc=Counter(), veto_shadow_n=0,
               # 1.4：v1.6 的 D（D16）、E5c 影子回放、G1 只报告项、C 阶段监控；有没有 1.6 起的 session（该接过滤）
               release_e5c=False, release_rule=None, d16=None, e5r=None, g1r=None, mon16=None, g1_rule=False)


def analyze(data, strict=False, calib=None, crashed=False):
    """data：一个 Data，或多个 Data 的列表（多个 session 合并分析，每个 session 各自做时间关联，派生样本合并）。
    calib：只用来定标（扫描窗口、T_armor、δ）的 session 列表；不给就用全部分析 session。
    crashed：用户报告过游戏崩溃（命令行 --crashed）。"""
    datas = list(data) if isinstance(data, (list, tuple)) else [data]
    if not datas:
        datas = [Data()]
    sessions = [Sess(d, analysis=True, calib=calib is None) for d in datas]
    for cd in (calib or []):
        same = next((ss for ss in sessions if ss.data is cd or (ss.target is not None
                                                                 and ss.target == cd.info.get("target"))), None)
        if same is not None:
            same.calib = True
        else:
            sessions.append(Sess(cd, analysis=False, calib=True))
    primary = sessions[0]
    R = init_result(primary.data, None)
    R.sessions = sessions
    R.crashed_flag = bool(crashed)
    # 给了 --calib-session 却一条记录都没读到（session 号不对、或第 1 轮数据在别的目录却没给 --calib-dir）：
    # 定标会悄悄退回先验，报告头要说清楚
    R.calib_missing = [cd.info.get("target") for cd in (calib or []) if cd.count() == 0]
    S = Section(R, strict)
    S.strict = strict
    for ss in sessions:
        try:
            prepare_session(ss, S)
        except Exception as e:  # noqa: BLE001
            if strict:
                raise
            R.errors.append(f"session {ss.label} 组装中断：{type(e).__name__}: {e}")
            if ss.ctx is None:
                ss.ctx = Ctx(Data())
    R.ctx = primary.ctx
    try:
        _analyze_core(R, S, [ss for ss in sessions if ss.analysis], [ss for ss in sessions if ss.calib])
    except Exception as e:  # noqa: BLE001
        if strict:
            raise
        R.fatal = f"{type(e).__name__}: {e}"
        R.errors.append("主流程中断：" + R.fatal)
    ana = [ss for ss in sessions if ss.analysis]
    R.err = S.run("错误统计", lambda: merge_errors([critical_errors(ss.data) for ss in ana])) or R.err
    R.perf = S.run("帧率与开销", lambda: [(ss.label, perf_check(ss.data)) for ss in ana]) or []
    R.fps = next((p for _l, p in R.perf if p is not None), None)
    S.run("C9 判定", lambda: verdict(R, R.cal))
    S.run("C10 补测", lambda: retest(R))
    S.run("D 验收口径", lambda: acceptance(R, R.cal))
    if R.d_mode == "release" and getattr(R, "d_scope", None) is not None:
        # 1.2：第 2 轮的 C9 只作复核，数据范围和 D 一致（第一次参数改动之前、开关开着、放刀模块的 RED）
        S.run("C9 复核（D 的数据范围）", lambda: verdict(R, R.cal, scope=R.d_scope))
    # 1.4：只报告的三节（V16 第 7 节第 5、6 条，第 9.1 节）
    S.run("E5c 影子回放", lambda: e5c_replay(R))
    S.run("G1 只报告项", lambda: g1_report(R))
    S.run("C 阶段监控", lambda: monitor16(R))
    return R


def merge_errors(errs):
    out = Obj(red=0, red_rows=[], core=0, core_rows=[], yellow=0, yellow_rows=[], selftest_fail=[], stat_gap=None)
    for e in errs:
        out.red += e.red
        out.red_rows += e.red_rows
        out.core += e.core
        out.core_rows += e.core_rows
        out.yellow += e.yellow
        out.yellow_rows += e.yellow_rows
        out.selftest_fail += e.selftest_fail
        if e.stat_gap and out.stat_gap is None:
            out.stat_gap = e.stat_gap
    return out


def _analyze_core(R, S, ana, cal_sessions):
    rng = random.Random(BOOT_SEED)
    R.calib_sessions = cal_sessions
    # 汇总（分析 session）
    R.entries = {(ss.label, k): v for ss in ana for k, v in ss.entries.items()}
    R.ser_mode = "SER" if any(not e.approx for e in R.entries.values()) else ("TYP（近似）" if R.entries else "无")
    R.fires_all = [f for ss in ana for f in ss.fires_all]
    R.fires = [f for ss in ana for f in ss.fires]
    R.scans = [s for ss in ana for s in ss.scans]
    R.pts = [p for ss in ana for p in ss.pts]
    R.manual = [p for ss in ana for p in ss.manual]
    R.scan_void_pts = [p for ss in ana for p in ss.scan_void_pts]
    R.episodes = [e for ss in ana for e in ss.episodes]
    R.n_danger = sum(1 for e in R.episodes if e.danger)
    R.match = Obj(**{k: sum(getattr(ss.match, k) for ss in ana)
                     for k in ("total", "matched", "unmatched", "ambiguous", "no_pred_attacker")})

    # 定标（C 记号、C1）：只用定标 session 的 δ、空挥、扫描
    cal = R.cal
    ds = [d for ss in cal_sessions for d in ss.ds]
    cal.delta = median(ds) if ds else DELTA_PRIOR
    R.delta_n, R.delta_prior = len(ds), not ds
    R.t_armor_vals = [v for ss in cal_sessions for v in ss.swing_vals]
    R.n_swing = sum(ss.n_swing for ss in cal_sessions)
    R.t_armor = median(R.t_armor_vals)
    set_calibration(R.sessions, cal)
    R.scan_used = []
    for ss in cal_sessions:
        R.scan_used += S.run(f"C1 扫描样本（{ss.label}）", lambda ss=ss: label_scan(ss.scans, ss.ctx)) or []
    pts_scan = [(s.c_first, s.label == "PARRY") for s in R.scan_used if s.label in ("PARRY", "FAIL")]
    R.win_scan = estimate_window(pts_scan, rng)
    R.win_prior = not R.win_scan.ok
    if R.win_scan.ok:
        cal.W0, cal.W1, cal.cens1 = R.win_scan.W0, R.win_scan.W1, R.win_scan.cens1
    cal.W1_eff = cal.W1
    set_calibration(R.sessions, cal)
    for f in R.fires:
        S.run(f"B 分类（预分类 #{f.id}）", lambda f=f: classify_fire(f, f.ctx))
    real = [(f.c_first, f.outcome == "CATCH") for f in R.fires if f.c_first is not None and f.outcome != "RECOIL"]
    R.agree = window_agreement(real, cal.W0, cal.W1, cal.cens1)
    R.win_real, R.win_source = None, ("扫描" if R.win_scan.ok else "先验（扫描样本不足）")
    n_ag, ok_ag, _bad = R.agree
    if n_ag >= 10 and ok_ag / n_ag < 0.80:
        R.win_real = estimate_window(real, rng)
        if R.win_real.ok:
            if R.win_scan.ok:
                w0, w1 = max(cal.W0, R.win_real.W0), min(cal.W1, R.win_real.W1)
                if w0 < w1:
                    cal.W0, cal.W1 = w0, w1
                    cal.cens1 = R.win_scan.cens1 and R.win_real.cens1
                    R.win_source = "扫描 ∩ 真怪标签"
                else:
                    cal.W0, cal.W1, cal.cens1 = R.win_real.W0, R.win_real.W1, R.win_real.cens1
                    R.win_source = "真怪标签（与扫描窗口交集为空，冲突）"
            else:
                cal.W0, cal.W1, cal.cens1 = R.win_real.W0, R.win_real.W1, R.win_real.cens1
                R.win_source = "真怪标签"
    # W1_eff = min(W1, T_armor − 0.05)；截完比 W0+m_e+m_l 还小就是矛盾（T_armor 多半读错），报告里标出、不用它截
    cal.W1_eff = cal.W1
    if R.t_armor is not None:
        w1e = min(cal.W1, R.t_armor - 0.05)
        if w1e <= cal.W0 + M_E + M_L:
            R.t_armor_conflict = True
        else:
            cal.W1_eff = w1e
    set_calibration(R.sessions, cal)
    for f in R.fires:
        reset_outcome(f)
        S.run(f"B 分类 #{f.id}", lambda f=f: classify_fire(f, f.ctx))
    R.manual_out = Counter(S.run("手动放刀", lambda: [classify_manual(p, ss.ctx) for ss in ana for p in ss.manual])
                           or [])
    # 放刀的首个接触落在自己回合 P23 窗口外的次数（c_first 不再依赖 P23，单独报）
    out_n = 0
    for f in R.fires:
        c, ep = f.c_first_rec, f.ep
        if c is not None and ep is not None and ep.t_hs0 is not None and ep.t_he0 is not None \
                and not (ep.t_hs0 - MATCH_PRE <= c.t <= ep.t_he0 + MATCH_POST):
            out_n += 1
    R.outside_p23 = out_n
    # 首个接触之前有没有同一只怪的 EMHIT（「先砍中」分组，离线 1）
    for f in R.fires:
        c = f.c_first_rec
        if c is None:
            continue
        t0 = f.t_start_used if getattr(f, "t_start_used", None) is not None else f.t_req
        f.emhit_first = any(f.ctx.ident.same(f.keys, ident_keys(h.get("em"))) for h in f.ctx.emhit.window(t0, c.t))

    # d̄（只用穿越触发的放刀）。1.4：v1.6 的放刀按 L − Q0（Q 单位，V16 第 6.2 节）；旧版本 fire_reading 就是 R0
    cross = [f for f in R.fires if f.L is not None and fire_reading(f) is not None and f.crossing is not False]
    R.dbar_vals = [f.L - fire_reading(f) for f in cross]
    R.dbar_late = sum(1 for f in R.fires if f.crossing is False)
    R.dbar = median(R.dbar_vals) if R.dbar_vals else 0.5
    R.dbar_prior = not R.dbar_vals

    # C2~C5
    R.res, R.res_excluded = residual_samples(R.fires, cal)
    R.model = residual_model(R.res)
    R.N = coverage_curve(R.res, R.model, cal, R.dbar) if R.res else {L: 0 for L in L_GRID}
    R.Lstar, R.Nmax = pick_plateau(R.N)
    R.cv = S.run("C3 交叉验证", lambda: cross_validate(R.res, cal, R.dbar))
    R.lmin, R.lmin_raw = lmin_star(R.res, cal, R.Lstar)
    R.wlong, R.wlong_k, R.wlong_n = wlong_star(R.fires)
    # 1.2：分析的 session 全是参数冻结的发布版（第 2 轮）时，样本不足的回退值用 V15 冻结值（L 26、L_min 22），
    # 不用 rc 的默认 28/18（影子回放、退路 A 的回放都按 v1.5 实际在用的参数算）
    # 1.3：冻结的提前量按版本（1.5 → 26，1.5.1 → 30）；几个版本合并分析时取最新的那个版本
    cfgs_ana = [rc_config(ss.data, ss.fires_all) for ss in ana]
    R.release_all = bool(ana) and all(c.release for c in cfgs_ana)
    R.release_ver = newest_version([c.ver for c in cfgs_ana]) if R.release_all else None
    # 1.4：版本号认不出来、但带 rule=E5c 的按 1.6（取最新版本那个 session 的 rule）
    rule_new = next((c.rule for c in cfgs_ana if c.ver == R.release_ver), None) if R.release_all else None
    R.release_e5c = R.release_all and any(c.e5c for c in cfgs_ana)
    R.release_rule = rule_new
    R.release_dflt = release_defaults(R.release_ver, rule_new) if R.release_all else None
    dflt = R.release_dflt if R.release_all else DEFAULTS
    L_use = R.Lstar if R.Lstar is not None else dflt["L"]
    lmin_use = R.lmin if R.lmin is not None else dflt["L_min"]
    R.L_use, R.lmin_use = L_use, lmin_use

    # 影子回放：C6、C7、C8、退路 A（每个 session 自己的时间轴，事件带上 ctx 再合并）。
    # 1.3：1.5.1 起的 session 按它实际的规则加抓取否决（grab）；更早的 session 和 1.2 一样
    rows6 = defaultdict(dict)
    R.gate_events, R.shadows = [], []
    for ss, cfg_a in zip(ana, cfgs_ana):
        # 1.4：v1.6 起的 session 另加 SKILL_GUARD 家族的否决（sg）；更早的 session sg=False，同 1.3
        ss.shadow = Shadow(ss.ctx, ss.entries, lmin_use, R.wlong, DEFAULTS["H_veto"], grab=cfg_a.grab, sg=cfg_a.g1)
        ss.e5 = E5c(ss.ctx)
        rows = S.run(f"C6 估计量（{ss.label}）",
                     lambda ss=ss: compare_estimators(ss.episodes, ss.shadow, ss.ctx, L_use)) or {}
        for name, d in rows.items():
            rows6[name].update(d)
        gate_out = S.run(f"C8 影子事件（{ss.label}）",
                         lambda ss=ss: build_gate_events(ss.fires, ss.episodes, ss.shadow, ss.entries, ss.ctx, L_use))
        if gate_out:
            R.gate_events += gate_out[0]
            R.shadows += gate_out[1]
    R.c6 = summarize_estimators(rows6)
    R.gates = S.run("C8 闸门", lambda: evaluate_gates(R.gate_events))
    R.fbA = S.run("退路 A 回放", lambda: fallback_a(R.gate_events, None))
    R.pose_unit = normalize_pose_units([p for ss in ana for p in ss.ctx.pose.recs])

    # C7 空放率
    known = [f for f in R.fires if f.outcome != "UNKNOWN"]
    n_f = len(known)
    wh = [f for f in known if f.outcome == "WHIFF"]
    n_int = sum(1 for f in wh if f.sub == "INTERRUPTED")
    R.F_actual = (len(wh) / n_f) if n_f else None
    R.F_actual_noint = ((len(wh) - n_int) / (n_f - n_int)) if n_f - n_int > 0 else None
    sh_full = [e for e in R.shadows if e.full]
    R.F_shadow = (sum(1 for e in sh_full if e.whiff) / len(sh_full)) if sh_full else None
    R.F_shadow_n = len(sh_full)
    fs = [x for x in (R.F_actual, R.F_shadow) if x is not None]
    R.F = max(fs) if fs else None
    fs2 = [x for x in (R.F_actual_noint, R.F_shadow) if x is not None]
    R.F_noint = max(fs2) if fs2 else None
    R.n_int = n_int

    # 归因（每个 session 自己算，再合并）
    ea, en = Counter(), Counter()
    mi = None
    vsh, vsh_rc, vsh_n = Counter(), Counter(), 0      # 1.3 修订：影子否决段 / 同一批 session 里 rc 的 VETO why / session 数
    for ss in ana:
        out = S.run(f"回合归因（{ss.label}）", lambda ss=ss: attribute_episodes(ss.episodes, ss.ctx))
        if out:
            ea.update(out[0])
            en.update(out[1])
        req_ts = [f.t_req for f in ss.fires_all] + [s.t_req for s in ss.scans if s.t_req is not None]
        b0 = b_segment_start(ss.ctx, ss.episodes, ss.scans)
        hdr = ss.data.get("rc", "HDR")
        rot = str(hdr[-1].get("rotation") or "").lower() if hdr else ""
        dflt_L = max(ROTATION_LS) if rot in ("1", "true", "on") else \
            (to_num(hdr[-1].get("lead")) if hdr and hdr[-1].get("lead") is not None else DEFAULTS["L"])
        cfg = ss.cfg = S.run(f"rc 参数状态（{ss.label}）", lambda ss=ss: rc_config(ss.data, ss.fires_all))
        # 1.1：参数冻结（不轮换）的 session 按 rc 当时实际生效的规则归因漏报 —— HDR 的 L_min / W_long / H_veto、
        # CFG 时间线上的提前量。v1.5 的 L_min=22，而 C4 在第 2 轮数据上重估的 L_min*（或 1.0 默认 18）可能更小：
        # 「DANGER 首次出现时已低于 22」会被错归成「其他（规则未触发）」，读起来像 rc 出了问题。
        # 轮换标定 session（第 1 轮）照 1.0：L_min 用 C4 的 L_min*，L 用下一次 FIRE 的轮换档
        frozen = cfg is not None and cfg.hdr is not None and not cfg.rotating
        lmin_m, wlong_m, shadow_m, lead_fn = lmin_use, R.wlong, ss.shadow, None
        q_m, g1_m = None, False
        if frozen:
            lmin_m = cfg.lmin if cfg.lmin is not None else lmin_use
            wlong_m = cfg.wlong if cfg.wlong is not None else R.wlong
            hveto_m = cfg.hveto if cfg.hveto is not None else DEFAULTS["H_veto"]
            shadow_m = Shadow(ss.ctx, ss.entries, lmin_m, wlong_m, hveto_m, grab=cfg.grab, sg=cfg.g1)
            lead_fn = (lambda t, cfg=cfg: cfg.state_at(t)[1])
            # 1.4：v1.6 起的 session 按它的规则归因：触发量 E5c 的 Q、该接过滤（V16 第 7 节第 4 条最后一项）
            if cfg.e5c:
                q_m, g1_m = ss.e5.q, bool(cfg.g1)
        auto_fn = (lambda t, cfg=cfg: cfg.state_at(t)[0]) if cfg is not None else None
        ss.miss_params = Obj(frozen=frozen, lmin=lmin_m, wlong=wlong_m)
        m = S.run(f"漏报归因（{ss.label}）",
                  lambda ss=ss, req_ts=req_ts, b0=b0, dflt_L=dflt_L, lmin_m=lmin_m, wlong_m=wlong_m,
                  shadow_m=shadow_m, lead_fn=lead_fn, auto_fn=auto_fn, q_m=q_m, g1_m=g1_m: attribute_misses(
                      ss.ctx, ss.episodes, req_ts, lmin_m, wlong_m, shadow=shadow_m, b_start=b0,
                      fires_all=sorted(ss.fires_all, key=lambda f: f.t_req), default_L=dflt_L,
                      lead_fn=lead_fn, auto_fn=auto_fn, qfun=q_m, g1=g1_m))
        if m is not None:
            if mi is None:
                mi = Obj(counts=Counter(), detail=[], n=0, off=[])
            mi.counts.update(m.counts)
            mi.detail += m.detail
            mi.n += m.n
            mi.off += m.off
        # 1.3 修订（第 1 轮审查）：1.5.1 起的 session 按 rc 的口径数影子否决段（V15 第 9 节第 4 条澄清），诊断里和同一批
        # session 的 rc VETO 并列。以前只拿漏报归因的「被抓取规则否决」去比 VETO 的 why，两边口径不同，对不上也看不出毛病
        if cfg is not None and cfg.grab:
            vs = S.run(f"影子否决段（{ss.label}）",
                       lambda ss=ss, shadow_m=shadow_m, cfg=cfg: shadow_veto_segments(shadow_m, ss.ctx.tl, cfg))
            if vs is not None:
                vsh.update(vs)
                vsh_rc.update(str(v.get("why")) if v.get("why") is not None else "—" for v in ss.data.get("rc", "VETO"))
                vsh_n += 1
    R.ep_attr = (ea, en)
    R.misses = mi
    R.veto_shadow = vsh if vsh_n else None
    R.veto_shadow_rc = vsh_rc
    R.veto_shadow_n = vsh_n
    # 1.3：rc 自己记的否决原因（VETO 的 why，v1.5.1 起才有；更早的版本记「—」）。漏报归因按影子回放算，这里只作对照
    R.veto_why = Counter(str(v.get("why")) if v.get("why") is not None else "—"
                         for ss in ana for v in ss.data.get("rc", "VETO"))
    R.grab_rule = any(c.grab for c in cfgs_ana)
    R.g1_rule = any(c.g1 for c in cfgs_ana)
    R.offline1 = S.run("离线 1 时钟对照", lambda: offline1_clocks(R))
    R.unclean = [ss.label for ss in ana if not clean_end(ss.data)]


ROTATION_LS = (20, 24, 28, 32, 36)


def clean_end(data):
    """这一轮有没有正常收尾：两个脚本最后一份 JSON 都是「写出数据」按钮、停止记录或 Reset 写出的。
    不是的话可能是崩溃，也可能只是忘了点「写出数据」：只作提示，不算崩溃（崩溃由用户报告，命令行 --crashed）。"""
    whys = data.info.get("json_why") or {}
    for src in ("pr", "rc"):
        w = whys.get(src)
        if w is not None and str(w).lower() not in ("button", "reset", "stop"):
            return False
    return True


def offline1_clocks(R):
    """离线 1（PLAN）：窗口跟随哪种时钟、是否「先砍中」。扫描窗口在 wall/raw/chara/anim 四种时钟下各估一次；
    真怪有接触的放刀按「首个接触之前有没有同一只怪的 EMHIT」分组，报一致率、残差和 C9(a) 的不一致数。只作描述，不改判定。"""
    rng = random.Random(BOOT_SEED + 1)
    clocks = ("wall", "raw", "chara", "anim")
    scan_pts = {k: [] for k in clocks}
    for s in R.scan_used:
        if s.label not in ("PARRY", "FAIL"):
            continue
        raw, chara, anim = first_contact_clocks(getattr(s, "first_rec", None), s.ctx, s.c_first + s.t_start_used)
        for k, v in zip(clocks, (s.c_first, raw, chara, anim)):
            if v is not None:
                scan_pts[k].append((v, s.label == "PARRY"))
    wins = {k: estimate_window(v, rng) for k, v in scan_pts.items()}
    real = {k: [] for k in clocks}
    groups = {True: [], False: []}
    for f in R.fires:
        if f.c_first is None or f.outcome == "RECOIL":
            continue
        rec = f.c_first_rec.rec if f.c_first_rec is not None else None
        raw, chara, anim = first_contact_clocks(rec, f.ctx, f.c_first_rec.t if f.c_first_rec else None)
        for k, v in zip(clocks, (f.c_first, raw, chara, anim)):
            if v is not None:
                real[k].append((v, f.outcome == "CATCH", bool(f.emhit_first)))
        groups[bool(f.emhit_first)].append(f)
    rows = []
    for k in clocks:
        w = wins[k]
        for g in (False, True):
            smp = [(c, catch) for c, catch, eg in real[k] if eg == g]
            if w.ok and smp:
                n, ok, _b = window_agreement(smp, w.W0, w.W1, w.cens1)
            else:
                n, ok = len(smp), None
            rows.append((k, g, w, n, ok))
    res_by = {g: [s.r for s in R.res if bool(s.emhit_first) == g] for g in (False, True)}
    c9a = {}
    cal = R.cal
    for g in (False, True):
        n = bad = 0
        for f in groups[g]:
            if cal.cens1 and f.c_first > cal.W1:
                continue
            n += 1
            bad += (cal.W0 <= f.c_first <= cal.W1) != (f.outcome == "CATCH")
        c9a[g] = (bad, n)
    return Obj(wins=wins, scan_n={k: len(v) for k, v in scan_pts.items()}, rows=rows, res_by=res_by, c9a=c9a)


def verdict(R, cal, scope=None):
    """C9。1.2：scope 给了（第 2 轮发布版，acceptance 之后再算一遍）就在 D 的数据范围上复核 —— 放刀、残差、空放率、影子
    回合只用第一次参数改动之前、启用开关开着的；(d) 的关键错误只算放刀模块的 RED，帧率用 D 范围内的 PERF。
    第 2 轮的 C9 只作复核，验收结论看第 11 节 D。"""
    fires = R.fires if scope is None else scope.fires
    cv = R.cv if scope is None else scope.cv
    F, F_shadow_n = (R.F, R.F_shadow_n) if scope is None else (scope.F, scope.F_shadow_n)
    red = R.err.red if scope is None else scope.red
    items = []
    # (a) c_first∈[W0,W1] 与 CATCH 的一致性；W1 右删失且 c_first 超过下界的样本无法判断，剔除
    n = bad = skipped = 0
    for f in fires:
        if f.c_first is None or f.outcome == "RECOIL":
            continue
        if cal.cens1 and f.c_first > cal.W1:
            skipped += 1
            continue
        inside = cal.W0 <= f.c_first <= cal.W1
        n += 1
        bad += inside != (f.outcome == "CATCH")
    lim = max(2, int(math.floor(0.10 * n)))
    items.append(Obj(key="a", name="c_first∈[W0,W1] 与 CATCH 不一致次数", value=f"{bad}/{n}",
                     rule=f"≤ max(2, 10%) = {lim}", ok=(n > 0 and bad <= lim), insufficient=n == 0,
                     note=(f"W1 右删失，{skipped} 个样本超出下界未计入" if skipped else "")))
    ok_b = cv is not None and cv.n >= 15 and cv.p is not None and cv.p >= 0.75
    items.append(Obj(key="b", name="留一招式交叉验证接住率 P_CV", value=(fmt(cv.p, 2) + f"（n={cv.n}，{cv.groups} 组）") if cv and cv.p is not None else "—",
                     rule="≥0.75，有接触的回合 n≥15", ok=ok_b, insufficient=(cv is None or cv.n < 15), note=""))
    n_f = sum(1 for f in fires if f.outcome != "UNKNOWN")
    ok_c = F is not None and n_f >= 20 and F <= 0.25
    items.append(Obj(key="c", name="空放率 F = max(F_actual, F_shadow)",
                     value=f"{fmt(F, 2)}（真放 n={n_f}，影子 n={F_shadow_n}）",
                     rule="≤0.25，n≥20", ok=ok_c, insufficient=n_f < 20, note=""))
    # (d) 关键错误（进入红状态的 RED 记录）为 0；没有崩溃（用户报告 --crashed，或本 session 日志范围内的未处理异常/崩溃转储）；
    #     fps 下降 ≤5% 用 mod 开销占帧时间的比例估（口径见 perf_check）
    crash_lines = sum(len(ss.data.info.get("crash") or []) for ss in R.sessions if ss.analysis)
    crash = R.crashed_flag or crash_lines > 0
    shares = ([p.share for _l, p in R.perf if p is not None and p.share is not None] if scope is None
              else scope.shares)
    share = max(shares) if shares else None
    fps_ok = share is not None and share <= OVERHEAD_MAX
    ok_d = red == 0 and not crash and fps_ok
    items.append(Obj(key="d", name="关键错误 / 崩溃 / fps 下降（按 mod 开销占帧时间估）",
                     value=f"{'放刀模块' if scope is not None else ''}红 {red}，崩溃{'（用户报告）' if R.crashed_flag else ''}"
                           f"迹象 {crash_lines} 行，"
                           f"开销占比 {fmt(share * 100 if share is not None else None, 2, '%')}",
                     rule="关键错误 0、无崩溃、开销占比 ≤5%", ok=ok_d, insufficient=share is None,
                     note=("没有带 lua_ms_avg 的 PERF，fps 部分无法判定" if share is None else
                           "开销含两个脚本的帧回调和钩子体耗时，不含 REF 的钩子分发开销（os.clock 量不到）")))
    R.c9 = items
    R.c9_pass = all(i.ok for i in items)


def retest(R):
    reasons = []
    if R.err.red:
        reasons.append(f"关键错误（进入红状态）{R.err.red} 次")
    n_contact = sum(1 for f in R.fires if f.outcome in CONTACT_OUTCOMES)
    if n_contact < 15:
        reasons.append(f"有接触的放刀 {n_contact} 次 < 15")
    if R.n_danger < 30:
        reasons.append(f"DANGER 回合 {R.n_danger} 个 < 30")
    ana = [ss for ss in R.sessions if ss.analysis] or [Sess(R.data)]
    if sum(ss.data.count() for ss in ana) == 0:
        reasons.append("日志和 JSON 都没有数据")
    else:
        for src, name in (("pr", "探针 APCal"), ("rc", "放刀模块 AutoParryGS")):
            if not any(v for ss in ana for (s2, _k), v in ss.data.by.items() if s2 == src):
                reasons.append(f"{name} 的日志和 JSON 都没有数据")
    R.c10 = reasons
    R.n_contact = n_contact


FIRST_HIT_SUBS = (SUB_INT_FALLBACK, "先砍中但缺受击动作证据")     # 先砍中、但不够 INTERRUPTED 的空放子类


def _cfg_flag(cfg_str, key):
    """探针 HDR 的 cfg_guard / cfg_parry 是 mod 配置的 JSON 串（去空格）。读某个布尔键；读不出来返回 None。"""
    if _is_nil(cfg_str):
        return None
    try:
        v = json.loads(str(cfg_str)).get(key)
        return v if isinstance(v, bool) else None
    except (ValueError, AttributeError):
        m = re.search(r'"%s"\s*:\s*(true|false)' % re.escape(key), str(cfg_str))
        return None if not m else m.group(1) == "true"


def _d_item(name, value, rule, ok, insufficient=False, pending=False, review=False):
    """D 的一项判定：ok 通过；insufficient 样本不足；pending 待用户确认；review 需复核（不判通过也不判不通过）。"""
    return Obj(name=name, value=value, rule=rule, ok=ok, insufficient=insufficient, pending=pending, review=review)


def session_order_key(i, ss):
    """1.2：多个 session 按加载先后排 —— session 号就是加载时的 os.time()（rc 的优先，没有就用探针的、目标 session 号）。"""
    ch = ss.data.info.get("chosen") or {}
    k = next((v for v in (ch.get("rc"), ch.get("pr"), ss.target) if v is not None), None)
    return (k is None, k if k is not None else 0, i)


def acceptance(R, cal):
    """D 第 2 轮验收（PLAN D）。
    1.1：每个分析 session 按自己的 rc 参数状态（rc_config）截断 —— 放刀、DANGER 回合、漏报、PERF 都只用第一次参数改动
    之前的；关键错误和崩溃看全程（同 C9(d)：任何时候出现都算）。
    1.2：① 截断只看提前量（rc_config）；启用开关关着的时段不进 D（关着时开始的回合、PERF 不计，挨打另计 off）。
    ② 多个 session 按加载先后（session_order_key）：发布版 session 加载时（HDR）不是 V15 冻结值、或者更早加载的
       session 已经改过参数，这次加载整段不计 —— 滑块改动会存进配置，下次加载就带着改过的值（1.1 各 session 各自截断，
       两次加载合并时会把改过参数的那次也算进验收）。
    ③ 关键错误只算放刀模块的 RED（v1.5 自己出错）；探针的 RED 只说明数据可信度存疑，单列「数据质量」判「需复核」，
       不判 v1.5 不通过（探针不随发布版发布，PLAN D 的验收标准里也没有它）。
    ④ 发布版加协议项（PLAN D：两只出招风格不同的怪、其中一只是新怪、至少一只关掉无限蓄力）：D 范围内 DANGER 回合
       ≥D_PROTO_MIN_DANGER 的怪不到两只判样本不足；有定标 session 时这些怪里没有新怪判样本不足；没有定标 session
       （新怪无法核对）、无限蓄力读不到或加载时都是开的，待用户确认。
    判定：接住率 ≥75%（n≥15）、空放 ≤25%（PLAN 原口径，先砍中打断计入；n≥20）、帧率不变（开销占比 ≤5%）、
    关键错误 0 且无崩溃；观感只能由用户确认。轮换标定 session 的结果只作预览。"""
    ana = [ss for _i, ss in sorted(enumerate(ss for ss in R.sessions if ss.analysis),
                                   key=lambda x: session_order_key(*x))]
    fires = []
    R.d_cut, R.d_rotating = None, False
    R.d_sess = []
    cut_of, cfg_of = {}, {}
    # 第一次参数改动所在的发布版 session：之后加载的发布版 session 一律不计。
    # 1.4：按规则代分开记（1.6 起 / 更早）：v1.6 加载时 cfg_ver < 3 的配置一律迁成 28（V16 第 2.7 节），旧版本的滑块改动带不过来；
    # 只有更早版本的 session 时和 1.3 完全一样
    first_change = {}
    for ss in ana:
        cfg = ss.cfg or rc_config(ss.data, ss.fires_all)
        ss.cfg = cfg
        cut, excluded = cfg.cut, None
        if cfg.release:
            era = bool(getattr(cfg, "e5c", False))
            bad = frozen_mismatch(cfg)
            if first_change.get(era) is not None:
                cut, excluded = -math.inf, (f"更早加载的 session {first_change[era]} 已经改过参数（PLAN D 只用第一次改动之前的"
                                            f"数据），这次加载整段不计")
            elif bad:
                # 1.4：v1.6 的冻结值出自 V16（旧版本的措辞不变）
                cut, excluded = -math.inf, (f"加载时参数不是 {frozen_doc(cfg.ver, cfg.rule)} 冻结值（" + "，".join(bad)
                                            + "）：参数在这次加载之前就改过（滑块改动存进了配置），整段不计")
            if cut is not None and first_change.get(era) is None:
                first_change[era] = ss.label
        cut_of[id(ss.ctx)] = cut
        cfg_of[id(ss.ctx)] = cfg
        if cut is not None and R.d_cut is None:
            R.d_cut = cut
        R.d_rotating = R.d_rotating or cfg.rotating
        mine = [f for f in ss.fires if cut is None or f.t_req < cut]
        fires += mine
        R.d_sess.append(Obj(ss=ss, label=ss.label, cfg=cfg, cut=cut, fires=mine, n_all=len(ss.fires), excluded=excluded,
                            perf=perf_check(ss.data, cut, t_ok=lambda t, cfg=cfg: cfg.state_at(t)[0] is not False)))
    cfgs = [d.cfg for d in R.d_sess if d.cfg.hdr is not None]
    R.d_mode = ("release" if cfgs and all(c.release for c in cfgs) else
                "calibration" if any(c.rotating or c.has_scan for c in cfgs) else "fixed")

    def before_cut(ctx, t):
        cut = cut_of.get(id(ctx))
        return cut is None or t is None or t < cut

    def in_d(ctx, t):
        # D 的范围：第一次参数改动之前，且启用开关开着（关着时不放刀；开关切换本身不截断）
        c = cfg_of.get(id(ctx))
        return before_cut(ctx, t) and (c is None or t is None or c.state_at(t)[0] is not False)

    def ep_in_d(ep):
        # 放过刀的回合按放刀时刻判断在不在 D 里（和放刀计数一致），其余按回合开始
        t_ep = ep.fire.t_req if ep.fire is not None else (ep.t0 if ep.t0 is not None else ep.t_hs0)
        return in_d(getattr(ep, "ctx", None), t_ep)

    contact = [f for f in fires if f.outcome in CONTACT_OUTCOMES]
    k = sum(1 for f in contact if f.outcome == "CATCH")
    R.d_catch = (k, len(contact))
    R.d_whiff = (sum(1 for f in fires if f.outcome == "WHIFF"), sum(1 for f in fires if f.outcome != "UNKNOWN"))
    # 不计先砍中打断：INTERRUPTED 从分子分母都去掉（和 C7 的「不计 INTERRUPTED 版」同一算法）
    R.d_int = sum(1 for f in fires if f.outcome == "WHIFF" and f.sub == "INTERRUPTED")
    R.d_whiff_noint = (R.d_whiff[0] - R.d_int, R.d_whiff[1] - R.d_int)
    R.d_first_hit_other = sum(1 for f in fires if f.outcome == "WHIFF" and f.sub in FIRST_HIT_SUBS)
    R.d_unknown = sum(1 for f in fires if f.outcome == "UNKNOWN")
    per = defaultdict(lambda: Counter())
    for ep in R.episodes:
        if ep.danger and ep_in_d(ep):
            per[emid_of(ep.keys)]["DANGER 回合"] += 1
    for f in fires:
        m = per[emid_of(f.keys)]
        m["放刀"] += 1
        m["有接触"] += f.outcome in CONTACT_OUTCOMES
        m["接住"] += f.outcome == "CATCH"
        m["空放"] += f.outcome == "WHIFF"
    # 覆盖率的漏报（1.1）：含「攻击者全场无预告」—— PLAN 要第 2 轮按怪回答「预告缺失、DANGER 来得太晚各占多少」，
    # 完全没有预告的怪也要出现在表里（覆盖率 0%）。1.0 不计这一类；第 1 轮 B 段里这一类是 0，表的数值不变。
    # 这类攻击者没有回合，按接触记录自带的 em（em<EmID>#<idx>）归到怪物
    miss_by = defaultdict(Counter)
    if R.misses:
        for a, cls in R.misses.detail:
            if not in_d(a.ctx, a.t):
                continue
            ks = a.ctx.ident.expand(a.keys)
            sysk = next((k2 for k2 in sorted(ks) if k2[0] == "sys"), None)
            em = next((emid_of(e.keys) for e in R.episodes if e.ctx is a.ctx and sysk and sysk in e.keys), None)
            if em is None:
                em = emid_of(ks)
            per[em]["漏报"] += 1
            miss_by[em][cls] += 1
    R.d_per = per
    R.d_miss_by = miss_by
    R.d_off = sum(1 for a in (R.misses.off if R.misses else []) if before_cut(a.ctx, a.t))
    # 协议核对（PLAN D：两只出招风格不同的怪、其中一只是新怪、至少一只关掉无限蓄力）
    ems = sorted({emid_of(ep.keys) for ep in R.episodes if ep.danger and ep_in_d(ep)} - {None})
    counted = [e for e in ems if per[e]["DANGER 回合"] >= D_PROTO_MIN_DANGER]
    cal_ems = sorted({emid_of(ep.keys) for ss in R.sessions if ss.calib and not ss.analysis
                      for ep in ss.episodes if ep.danger} - {None})
    inf = []
    for ss in ana:
        h = ss.data.get("pr", "HDR")
        inf.append((ss.label, _cfg_flag(h[-1].get("cfg_guard"), "infinite_charge") if h else None))
    R.d_protocol = Obj(ems=ems, counted=counted, cal_ems=cal_ems,
                       new=[e for e in ems if e not in cal_ems] if cal_ems else None,
                       new_counted=[e for e in counted if e not in cal_ems] if cal_ems else None, inf=inf)
    # STAT 的 v1.5 计数（全程，清零过的按增量累加）
    R.d_stat = []
    for ss in ana:
        st = ss.data.get("rc", "STAT")
        R.d_stat.append(Obj(label=ss.label, replica=stat_total(st, "replica"), readerr=stat_total(st, "readerr"),
                            failopen=stat_total(st, "failopen"),
                            items=[r for r in ss.data.get("rc", "ERR") if str(r.get("mod") or "").lower() == "items"]))
    # 判定
    items = []
    kc, nc = R.d_catch
    items.append(_d_item("有接触的放刀接住率", wilson_str(kc, nc) if nc else "—", f"≥75%（有接触的放刀 n≥{D_N_CONTACT}）",
                         ok=nc >= D_N_CONTACT and kc / nc >= D_CATCH_MIN, insufficient=nc < D_N_CONTACT))
    kw, nw = R.d_whiff
    items.append(_d_item("空放率（PLAN 原口径：先砍中打断计入）", pct(kw, nw), f"≤25%（放刀 n≥{D_N_FIRE}）",
                         ok=nw >= D_N_FIRE and kw / nw <= D_WHIFF_MAX, insufficient=nw < D_N_FIRE))
    shares = [d.perf.share for d in R.d_sess if d.perf is not None and d.perf.share is not None]
    share = max(shares) if shares else None
    items.append(_d_item("帧率不变（按 mod 开销占帧时间估，口径同 C9(d)）",
                         f"开销占比中位数 {fmt(share * 100 if share is not None else None, 2, '%')}", "≤5%",
                         ok=share is not None and share <= OVERHEAD_MAX, insufficient=share is None))
    crash_lines = sum(len(ss.data.info.get("crash") or []) for ss in ana)
    rc_red = [r for r in R.err.red_rows if r.get("_src") == "rc"]
    pr_red = [r for r in R.err.red_rows if r.get("_src") != "rc"]
    items.append(_d_item("关键错误 / 崩溃（放刀模块进入红状态，全程）",
                         f"放刀模块红 {len(rc_red)}，崩溃{'（用户报告）' if R.crashed_flag else ''}迹象 {crash_lines} 行",
                         "关键错误 0、无崩溃", ok=not rc_red and not R.crashed_flag and crash_lines == 0))
    items.append(_d_item("数据质量：探针进入红状态（全程；探针不随发布版发布，不判 v1.5）",
                         f"探针红 {len(pr_red)}" + ("（" + "；".join(f"{r.get('mod')}:{r.get('why')}" for r in pr_red[:3])
                                                  + "）" if pr_red else ""),
                         "0（不为 0：数据可信度存疑，复核日志或补测）", ok=not pr_red, review=bool(pr_red)))
    if R.d_mode == "release":
        items.append(_d_item(f"协议：两只出招风格不同的怪（D 范围内 DANGER 回合 ≥{D_PROTO_MIN_DANGER} 的怪）",
                             "，".join(f"em{e}（{per[e]['DANGER 回合']}）" for e in ems) or "—", "≥2 只",
                             ok=len(counted) >= 2, insufficient=len(counted) < 2))
        if cal_ems:
            nc_ = R.d_protocol.new_counted
            items.append(_d_item("协议：其中一只是新怪（定标 session 里没出现过）", "、".join(f"em{e}" for e in nc_) or "无",
                                 "≥1 只", ok=bool(nc_), insufficient=not nc_))
        else:
            items.append(_d_item("协议：其中一只是新怪", "没有定标 session，无法核对", "用户确认", ok=False, pending=True))
        inf_v = [v for _l, v in inf]
        if any(v is False for v in inf_v):
            items.append(_d_item("协议：至少一只关掉无限蓄力（探针 HDR 里加载时的值）", "有加载时关着的", "≥1 次", ok=True))
        else:
            items.append(_d_item("协议：至少一只关掉无限蓄力（探针 HDR 里加载时的值）",
                                 "读不到" if all(v is None for v in inf_v) else "加载时都是开的（中途改动看不到）",
                                 "用户确认", ok=False, pending=True))
    items.append(_d_item("观感（伤害、火花、顿帧、弹开都是原生的）", "—", "用户确认", ok=False, pending=True))
    R.d_items = items
    offline = [i for i in items if not i.pending]
    if any(not i.ok and not i.insufficient and not i.review for i in offline):
        R.d_verdict = "不通过"
    elif any(i.insufficient for i in offline):
        R.d_verdict = "样本不足"
    elif any(i.review for i in offline):
        R.d_verdict = "需复核"
    else:
        R.d_verdict = "离线各项通过"
    # 1.4：有 1.6 起的发布版 session 时，D 改按 V16 第 9.2 节（acceptance16）；判定项和结论换成它的
    acceptance16(R, ep_in_d, in_d)
    if R.d16 is not None:
        R.d_items, R.d_verdict = R.d16.items, R.d16.verdict
    # 第 2 轮的 C9 复核用同一个数据范围（verdict 的 scope，analyze 在 acceptance 之后再算一遍）
    if R.d_mode == "release":
        dset = {id(f) for f in fires}
        res_d = [s for s in R.res if id(s.f) in dset]
        known = [f for f in fires if f.outcome != "UNKNOWN"]
        fa = (sum(1 for f in known if f.outcome == "WHIFF") / len(known)) if known else None
        shd = [e for e in R.shadows if e.full and in_d(e.ctx, e.t)]
        fsh = (sum(1 for e in shd if e.whiff) / len(shd)) if shd else None
        fs_ = [x for x in (fa, fsh) if x is not None]
        R.d_scope = Obj(fires=fires, cv=cross_validate(res_d, cal, R.dbar) if res_d else None,
                        F=max(fs_) if fs_ else None, F_shadow_n=len(shd), red=len(rc_red), shares=shares)


# ---------------------------------------------------------------- 1.4：v1.6 的 D（B 阶段验收，V16 第 9.2 节）
INT_KINDS = ("INTERRUPTED", "先砍中招式提前结束", "先砍中缺受击动作证据")     # 打断类（先砍中把怪打出硬直、攻击没来）
D16_KINDS = ("CATCH26", "CATCH27", "RECOIL", "FAIL_EARLY", "FAIL_LATE", "FAIL_OTHER", "纯空挥") + INT_KINDS


def d16_kind(f):
    """一刀在 D16 表里的列：CATCH26 / CATCH27 / RECOIL / FAIL_* / 纯空挥 / 打断三类 / UNKNOWN。
    纯空挥 = WHIFF 且放刀到 hs 归零之间没有同一只怪的 EMHIT（classify_fire 的子类为空）；有 EMHIT 的 WHIFF 都归打断类，
    按证据分三列：INTERRUPTED（进了受击类动作）、先砍中招式提前结束、先砍中缺受击动作证据（与 SPEED「63 刀里纯空挥 1 次」同口径）。"""
    o = f.outcome
    if o == "CATCH":
        return f"CATCH{f.tier}" if f.tier in (26, 27) else "CATCH26"
    if o == "WHIFF":
        return {"INTERRUPTED": INT_KINDS[0], SUB_INT_FALLBACK: INT_KINDS[1],
                "先砍中但缺受击动作证据": INT_KINDS[2]}.get(f.sub, "纯空挥")
    return o if o in D16_KINDS else "UNKNOWN"


def apcal_version(data):
    """探针 HDR 的版本（apcal-1.1 → (1, 1)）；没有 HDR 或认不出来返回 (None, 原文)。"""
    h = data.get("pr", "HDR")
    raw = to_str(h[-1].get("ver")) if h else None
    m = re.search(r"apcal-(\d+(?:\.\d+)*)", str(raw or ""), re.I)
    return (tuple(int(x) for x in m.group(1).split(".")) if m else None), raw


def guard_name(v):
    """GuardType 的名字（ENT 写名字或数值）；读不到返回「读不到」。"""
    if v is None:
        return "读不到"
    if isinstance(v, str):
        return v.upper().split(".")[-1]
    return next((n for n, x in ENUMS["GUARD"].items() if x == v), f"未知值 {v}")


def fire_attrs(f, entries_by_sess):
    """触发条目在放刀那一刻的 ENT 属性（探针）；没有探针数据返回 None。"""
    ents = entries_by_sess.get(id(getattr(f, "ctx", None))) or {}
    e = ents.get((f.res, f.ent))
    return entry_attrs(e, f.t_req) if e is not None else None


def fire_consistency(f):
    """V16 第 7 节第 4 条的一致性核对（每个 v1.6 的 FIRE）：|Q0 − (R0 − dX)/mf| ≤ 0.01、|Qe1 − (R0 − A0·(1 − 1/max(1, C1)))| ≤ 0.01、
    L_min ≤ Q0 ≤ L。容差另加记录格式的舍入上界（R0、dX、A0、Q0、Qe1 两位小数，mf、C1 三位小数），否则正确实现也会因为
    写日志时的舍入被误报。返回不符的项（空 = 一致）；字段缺失的单独报「缺字段」。
    1.5：合并版的 FIRE 没有 Qe1（MERGE 第 4.2 节）：只核对 Q0 那一项和 L_min ≤ Q0 ≤ L，C1、A0 只在核对 Qe1 时才必需。"""
    bad = []
    with_qe1 = f.Qe1 is not None
    names = ("R0", "dX", "mf", "Q0", "A0", "C1", "Qe1", "L") if with_qe1 else ("R0", "dX", "mf", "Q0", "L")
    need = tuple(getattr(f, n) for n in names)
    if any(v is None for v in need):
        return ["缺字段：" + "、".join(n for n, v in zip(names, need) if v is None)]
    if f.mf <= 0:
        return [f"mf={f.mf}"]
    q = (f.R0 - f.dX) / f.mf
    tol = 0.01 + 0.005 + 0.01 / f.mf + abs(f.R0 - f.dX) * 0.0005 / (f.mf * f.mf)
    if abs(f.Q0 - q) > tol:
        bad.append(f"Q0={f.Q0:.2f} ≠ (R0−dX)/mf={q:.2f}")
    if with_qe1:
        m1 = max(1.0, f.C1)
        e1 = f.R0 - f.A0 * (1.0 - 1.0 / m1)
        tol1 = 0.01 + 0.005 + 0.005 + 0.005 * (1.0 - 1.0 / m1) + (abs(f.A0) * 0.0005 / (m1 * m1) if f.C1 >= 1.0 else 0.0)
        if abs(f.Qe1 - e1) > tol1:
            bad.append(f"Qe1={f.Qe1:.2f} ≠ R0−A0·(1−1/max(1,C1))={e1:.2f}")
    if not (L_MIN_16 - 0.005 <= f.Q0 <= f.L + 0.005):
        bad.append(f"Q0={f.Q0:.2f} 不在 [L_min={L_MIN_16}, L={_lead_s(f.L)}]")
    return bad


def acceptance16(R, ep_in_d, in_d):
    """1.4：v1.6 的 D（V16 第 9.2 节、第 7 节第 4 条），只对 1.6 起的发布版 session（更早版本的 session 不进来，报告里写明）。
    截断与冻结沿用 1.2 / 1.3（acceptance 里已经按版本算好：1.6 的冻结值 lead 28、L_min 22、W_long 60、H_veto 90、rule=E5c、filter=g1）。
    按怪统计；新怪 = EmID 不在设计集 {18,19,20,23,27}、也不是训练机关 em33（设计集是验收协议的一部分，不进规则）。
    判定（新怪合并）：有接触的放刀接住率（CATCH26+CATCH27）/（接住+RECOIL+FAIL_*）≥75%；纯空挥率 = 纯空挥 /（已分类放刀 − 打断类）
    ≤25%；开销（PERF 周期中位，D 范围内）≤5%；放刀模块 RED = 0（全程：进入红状态、核心模块红错误 ERR level=red / STAT red、
    崩溃迹象都算，审查修订）；样本 = 至少 4 只新怪各有 ≥15 次有接触的放刀，不够判「样本不足」。数据质量（APCal < 1.1、探针 RED、
    sidmis > 0）判「需复核」，不判失败。
    PLAN D 的旧协议行（两只怪、无限蓄力）和观感对 1.6 只报告。"""
    R.d16 = None
    ds = [d for d in R.d_sess if d.cfg is not None and d.cfg.hdr is not None and d.cfg.release and d.cfg.e5c]
    if not ds:
        return
    others = [d for d in R.d_sess if d not in ds]
    ctxs = {id(d.ss.ctx) for d in ds}
    fires = [f for d in ds for f in d.fires]
    ent_by = {id(d.ss.ctx): d.ss.entries for d in ds}
    per = defaultdict(Counter)
    for ep in R.episodes:
        if ep.danger and id(getattr(ep, "ctx", None)) in ctxs and ep_in_d(ep):
            per[emid_of(ep.keys)]["DANGER 回合"] += 1
    for f in fires:
        c = per[emid_of(f.keys)]
        c["放刀"] += 1
        k = d16_kind(f)
        c[k] += 1
        c["有接触"] += f.outcome in CONTACT_OUTCOMES
        c["已分类"] += k != "UNKNOWN"
    # rc 自己记的 SKIP（蓄力中进窗口、被该接过滤挡掉）、UVIEW（按这一刀的怪）、DBG speed_fail（idx → 怪）
    skips, uviews, dbg_on = [], [], False
    for d in ds:
        ctx, data = d.ss.ctx, d.ss.data
        for r in data.get("rc", "SKIP"):
            if in_d(ctx, r.get("t")):
                skips.append((d, r))
                per[emid_of(ident_keys(r.get("em")))]["SKIP " + str(r.get("why") or "?")] += 1
        by_id = {f.id: f for f in d.fires}
        for r in data.get("rc", "UVIEW"):
            f = by_id.get(r.get("id"))
            if f is not None:
                uviews.append((d, r, f))
                per[emid_of(f.keys)]["UVIEW"] += 1
        sys_em = {k[1]: emid_of(ep.keys) for ep in d.ss.episodes for k in ep.keys if k[0] == "sys"}
        for r in data.info.get("dbg") or []:
            dbg_on = True
            if str(r.get("ev") or "") == "speed_fail" and in_d(ctx, to_num(r.get("t"))):
                per[sys_em.get(to_int(r.get("idx")))]["speedfail"] += 1
    # 漏报（覆盖率用），口径同 1.1 的按怪统计。「被该接过滤排除」另和 rc 自己的 SKIP 对一对（V16 第 7 节第 4 条：按 SKIP 和
    # 影子回放判断）：这一招的结果在接触之前有没有 SKIP（没有的多半是 rc 进窗口那几帧没在蓄力，或 rc 和探针读到的属性不同）
    miss_by = defaultdict(Counter)
    skip_res = defaultdict(list)
    for d, r in skips:
        if r.get("res"):
            skip_res[(id(d.ss.ctx), r["res"])].append(r.get("t"))
    g1_miss = [0, 0]
    for a, cls in (R.misses.detail if R.misses else []):
        if id(a.ctx) not in ctxs or not in_d(a.ctx, a.t):
            continue
        if cls == MISS_G1:
            ep_ = a.first.ep
            g1_miss[0] += 1
            g1_miss[1] += ep_ is not None and any(ts is not None and ts <= a.t
                                                  for ts in skip_res.get((id(a.ctx), ep_.obj), []))
        ks = a.ctx.ident.expand(a.keys)
        sysk = next((k2 for k2 in sorted(ks) if k2[0] == "sys"), None)
        em = next((emid_of(e.keys) for e in R.episodes if e.ctx is a.ctx and sysk and sysk in e.keys), None)
        em = emid_of(ks) if em is None else em
        per[em]["漏报"] += 1
        miss_by[em][cls] += 1
    new = sorted(e for e in per if e is not None and e not in DESIGN_EMIDS and e != DUMMY_EMID)
    tot = Counter()
    for e in new:
        tot.update(per[e])
    kc, nc = tot["CATCH26"] + tot["CATCH27"], tot["有接触"]
    n_int = sum(tot[k] for k in INT_KINDS)
    kw, nw = tot["纯空挥"], tot["已分类"] - n_int
    enough = [e for e in new if per[e]["有接触"] >= D16_MIN_CONTACT]
    sample_ok = len(enough) >= D16_MIN_MONSTERS
    shares = [d.perf.share for d in ds if d.perf is not None and d.perf.share is not None]
    share = max(shares) if shares else None
    # 1.5：D 范围里有合并版的 session（没有 STAT、SKIP、UVIEW、VETO）
    merged16 = any(getattr(d.cfg, "merged", False) for d in ds)
    merged_all = all(getattr(d.cfg, "merged", False) for d in ds)
    rc_red = [r for d in ds for r in d.ss.data.get("rc", "RED")]
    crash_lines = sum(len(d.ss.data.info.get("crash") or []) for d in ds)
    # 审查修订（V16 第 7 节第 4 条、第 9.2 节）：「放刀模块 RED = 0」算放刀模块的一切红 —— 进入红状态（RED 记录）、核心模块的红
    # 错误（ERR level=red；JSON 里 ERR 最多 500 条，另取 STAT red 的合计，两者取大）、崩溃迹象。2c 那次单发的
    # caught (...) exception（悬空指针，STAT red=1）正是 RED = 0 要拦的，以前只判「需复核」，和 SPEED 5.7、V16 9.2 对不上
    rc_err_red = [r for d in ds for r in d.ss.data.get("rc", "ERR") if str(r.get("level") or "").lower() == "red"]
    n_err_red = max(len(rc_err_red), sum(v or 0 for v, _n in (stat_total(d.ss.data.get("rc", "STAT"), "red") for d in ds)))
    pr_red = [r for d in ds for r in d.ss.data.get("pr", "RED")]
    apv = [(d.label,) + apcal_version(d.ss.data) for d in ds]
    ap_bad = [(lab, raw) for lab, vt, raw in apv if vt is None or vt < APCAL_MIN]
    sid = [stat_total(d.ss.data.get("rc", "STAT"), "sidmis") for d in ds]
    n_sid = sum(v for v, _n in sid if v)
    items = [
        _d_item("新怪合并：有接触的放刀接住率（CATCH26 + CATCH27）/（接住 + RECOIL + FAIL_*）", cp_str(kc, nc),
                f"≥{D16_CATCH_MIN * 100:.0f}%", ok=sample_ok and nc > 0 and kc / nc >= D16_CATCH_MIN, insufficient=not sample_ok),
        _d_item("新怪合并：纯空挥率 = 纯空挥 /（已分类放刀 − 打断类）", cp_str(kw, nw), f"≤{D16_WHIFF_MAX * 100:.0f}%",
                ok=sample_ok and nw > 0 and kw / nw <= D16_WHIFF_MAX, insufficient=not sample_ok),
        # 1.5：合并版没有 STAT（帧回调、钩子耗时都在 [AutoGuardGS] PERF 行里，本版不解析），这一项判不了 → 只会「样本不足」
        (_d_item("mod 开销（帧回调 + 钩子，PERF 周期中位，D 范围内）",
                 "—（合并版没有 STAT；开销看 [AutoGuardGS] PERF 行）", "≤5%", ok=False, insufficient=True)
         if merged16 else
         _d_item("mod 开销（帧回调 + 钩子，PERF 周期中位，D 范围内）",
                 f"开销占比中位数 {fmt(share * 100 if share is not None else None, 2, '%')}", "≤5%",
                 ok=share is not None and share <= OVERHEAD_MAX, insufficient=share is None)),
        _d_item("放刀模块 RED / 核心模块红错误 / 崩溃（全程，含崩溃迹象）",
                f"进入红状态 {len(rc_red)}，核心模块红错误 {n_err_red}（ERR level=red / STAT red），"
                f"崩溃{'（用户报告）' if R.crashed_flag else ''}迹象 {crash_lines} 行", "0",
                ok=not rc_red and n_err_red == 0 and not R.crashed_flag and crash_lines == 0),
        _d_item(f"样本：新怪 ≥{D16_MIN_MONSTERS} 只，每只有接触的放刀 ≥{D16_MIN_CONTACT}",
                "、".join(f"em{e}（{per[e]['有接触']}）" for e in new) or "没有新怪",
                f"够数的新怪 ≥{D16_MIN_MONSTERS} 只（现在 {len(enough)} 只）", ok=sample_ok, insufficient=not sample_ok),
        _d_item("数据质量：探针版本 ≥ apcal-1.1（引用记账已修，V16 第 5.4 节）",
                "；".join(f"{raw or '没有探针 HDR'}" for _l, _v, raw in apv) or "—", "全部 ≥1.1",
                ok=not ap_bad, review=bool(ap_bad)),
        _d_item("数据质量：探针进入红状态（全程）", str(len(pr_red)), "0", ok=not pr_red, review=bool(pr_red)),
        # 1.5（审查修订）：合并版不记 sidmis（没有 STAT，登记时也不再读发送者地址，MERGE 第 2.7 节 C 类第 1、2 条）。没有数据不能
        # 算「通过」：判「需复核」（数据质量项本来就只判需复核、不判失败），不说成样本不足 —— 样本够不够是另一项
        (_d_item("数据质量：sidmis（首帧怪物地址和发送者对不上的结果数，STAT）",
                 "—（合并版不记：没有 STAT，也不读发送者地址）", "0", ok=False, review=True)
         if merged16 else
         _d_item("数据质量：sidmis（首帧怪物地址和发送者对不上的结果数，STAT）",
                 fmt(n_sid) if any(n for _v, n in sid) else "—（STAT 没有这个字段）", "0", ok=n_sid == 0, review=n_sid > 0)),
    ]
    if any(not i.ok and not i.insufficient and not i.review for i in items):
        verdict_ = "不通过"
    elif any(i.insufficient and not i.ok for i in items):
        verdict_ = "样本不足"
    elif any(i.review and not i.ok for i in items):
        verdict_ = "需复核"
    else:
        verdict_ = "通过"
    flags = {}
    for e, c in per.items():
        n_c = c["有接触"]
        why = []
        if n_c and (c["CATCH26"] + c["CATCH27"]) / n_c < D16_FLAG_CATCH:
            why.append(f"接住 <{D16_FLAG_CATCH * 100:.0f}%")
        if c["FAIL_EARLY"] >= D16_FLAG_EARLY:
            why.append(f"放早 ≥{D16_FLAG_EARLY}")
        if why:
            flags[e] = "左尾诊断（" + "、".join(why) + "）"
    stat = {name: [stat_total(d.ss.data.get("rc", "STAT"), name) for d in ds]
            for name in ("recoils", "speedfail", "speedhold", "clockskip", "vetoq", "fclosed", "excl", "uview", "sidmis",
                         "failopen", "replica", "readerr")}
    stat_sum = {k: (sum(v for v, _n in vs if v) if any(n for _v, n in vs) else None) for k, vs in stat.items()}
    # 只报告项
    gt_out = Counter()
    pb0_recoil, c_out = [], []
    for f in fires:
        a = fire_attrs(f, ent_by)
        e_ = (ent_by.get(id(getattr(f, "ctx", None))) or {}).get((f.res, f.ent))
        # 审查修订：探针 AP 停用之后读不到的属性单独标出来，不当成游戏数据
        unk = e_ is not None and entry_g1x(getattr(f, "ctx", None), e_, f.t_req) == "unk"
        gt_out[("探针 AP 停用（读不到）" if unk else guard_name(a.get("guard")) if a else "没有探针 ENT", d16_kind(f))] += 1
        if f.outcome == "RECOIL" and not (a and a.get("pbreak") is True):
            pb0_recoil.append((f, a, unk))
    fires_all16 = [f for d in ds for f in d.ss.fires_all]
    for f in fires_all16:
        cs = [c for c in (f.C1, f.Cf) if c is not None]
        if any(not (C_SEEN[0] <= c <= C_SEEN[1]) for c in cs):
            c_out.append(f)
    incons = [(f, fire_consistency(f)) for f in fires_all16]
    incons = [(f, b) for f, b in incons if b]
    qe = [(f.Qe1 - f.Q0, f) for f in fires_all16 if f.Qe1 is not None and f.Q0 is not None]
    skip_by = Counter((emid_of(ident_keys(r.get("em"))), r.get("keep"), str(r.get("why") or "?")) for _d, r in skips)
    ems_proto = sorted(e for e in per if e is not None and per[e]["DANGER 回合"] >= D_PROTO_MIN_DANGER)
    inf = []
    for d in ds:
        h = d.ss.data.get("pr", "HDR")
        inf.append((d.label, _cfg_flag(h[-1].get("cfg_guard"), "infinite_charge") if h else None))
    R.d16 = Obj(ds=ds, others=others, fires=fires, per=per, miss_by=miss_by, new=new, tot=tot, enough=enough,
                sample_ok=sample_ok, items=items, verdict=verdict_, flags=flags, kc=kc, nc=nc, kw=kw, nw=nw, n_int=n_int,
                share=share, stat=stat_sum, gt_out=gt_out, pb0_recoil=pb0_recoil, c_out=c_out, incons=incons, qe=qe,
                skip_by=skip_by, uviews=uviews, dbg_on=dbg_on, ems_proto=ems_proto, inf=inf, apv=apv,
                vq=sum(1 for f in fires_all16 if f.vq), fires_all=fires_all16, g1_miss=tuple(g1_miss),
                merged=merged16, merged_all=merged_all)


# ---------------------------------------------------------------- 1.4：E5c 影子回放、G1 只报告项、C 阶段监控（只报告）
def window_class(c, cal):
    """接触时刻（相对 (2,23) 开始）落在窗口哪一侧：早（< W0）/ 窗口内 / 晚（> W1；W1 右删失时是超出已测的上沿）。"""
    if c is None:
        return "无接触"
    if c < cal.W0:
        return "早"
    if c > cal.W1:
        return "晚"
    return "窗口内"


def shadow_gap_reason(ss, f, ep, e5, own, L):
    """1.4 审查修订（第 13 节「1.6 影子对真 FIRE」，V16 第 14 节）：1.6 的真放刀在影子里不触发、没有条目或对不上帧时找原因，
    返回 (原因, 可解释)。可解释 = 探针那边的覆盖问题（没跟到这个回合、读不到首帧 C、没有触发条目的序列或属性、AP 停用）、rc 自己
    那段时间读条目出过错（看不到别的结果的否决条目，照常放刀，例如 mock 的 v15_items_partial）、存活期间 m 变过（影子看不到
    中途变速）。其余都是「原因不明」：探针 ENT 判不该接 / 影子判否决而 rc 没有读错 / 影子的 Q 不在窗口 —— 多半是放刀模块的实现
    偏离规则，B 阶段要逐条核对（mock 的端到端核对把它当问题报）。"""
    if ep is None or not ep.ents:
        return "探针没跟踪到这个回合（无条目）", True
    M = e5.model(ep)
    if M.nofire:
        return f"探针读不到首帧 C（{M.why}）", True
    e = ss.entries.get((f.res, f.ent))
    if e is None:
        return "探针没有触发条目的序列", True
    t = f.t_req
    if entry_shell(e, t) is True or entry_effect(e, t) is True or (own.grab and entry_grab(e, t) is True):
        return "探针 ENT 判弹体 / 效果攻击 / 抓取（旧规则排除），rc 却放了", False
    g = entry_g1x(ss.ctx, e, t) if own.sg else "ok"
    if g not in ("ok", "unk"):
        if entry_attrs(e, t) is None:
            return "探针 ENT 没有这条条目的属性（影子按读不准排除）", True
        return f"探针 ENT 判该接过滤挡掉（{g}），rc 却放了", False
    kind = own.veto_kind_at(t)
    if kind is not None:
        items_err = any(str(r.get("mod") or "").lower() == "items" for r in ss.data.get("rc", "ERR")) \
            or bool(stat_total(ss.data.get("rc", "STAT"), "readerr")[0])
        if items_err:
            return f"影子判否决（{kind}），rc 那段时间读条目出过错（看不到那条否决条目，照常放刀）", True
        return f"影子判否决（{kind}），rc 没有否决", False
    if (f.nchg or 0) > 0:
        return f"存活期间 m 变过（nchg={f.nchg}），影子看不到中途变速", True
    st = entry_state(e, t, lo=ep_lo(ep))
    if st is None:
        return "放刀那一刻探针没有这条条目的读数（SER 过期）", True
    if not is_danger(st[0]):
        return "探针在放刀那一刻读到的条目类型不是 DANGER", False
    q = e5.q(ep, e, t, st[1], st[2])
    if q is None:
        return "影子在放刀那一刻算不出这条条目的 Q", False
    return f"影子 Q={q:.2f} 不在 [{L_MIN_16}, {_lead_s(L)}]（rc 的 Q0={fmt(f.Q0, 2)}）", False


def e5c_replay(R):
    """1.4（V16 第 7 节第 5 条，样本内对照，不进任何判定）：每个分析 session 按 E5c@28（v1.6 的规则：Q 单位 [22, 28]，长窗口和
    抓取否决按原始 hs、W_long 60、H_veto 90）在探针数据上重放：
      · 真放刀逐条：t_req、R0、C1、实际 Q（放刀那一帧触发条目的 E5c Q）、影子触发时刻 t_Q 和读数、
        c_first' = 实际首个接触 − (t_Q + δ) 落在 [W0, W1] 内 / 早 / 晚（假设攻击时刻不因放刀早晚而变，SPEED 3.3）；
      · 候选过滤：v1.6 起的 session 用它自己的规则（加该接过滤、SKILL_GUARD 否决）；更早的 session 用它自己版本的过滤
        （弹体、效果攻击，1.5.1 起再加抓取），另出一列「加该接过滤的假设」（= 完整的 v1.6 规则）；
      · 影子触发、真没放的回合数（启用开关开着、主角在蓄力中）；
      · v1.6 起的 session：影子触发时刻和真 FIRE 对照（nchg = 0 的放刀应在 1 帧内一致：按这个结果的 SER 帧序号比；
        按这一刀 FIRE 自己的 L 重放，滑块改过的放刀也能比）。
    审查修订（V16 第 14 节）：1.6 的「实际 Q」直接用 FIRE 自己记的 Q0（探针的 EMINFO 只在首次 DANGER、PT、接触时采样，影子
    看不到 C 中途的变化，nchg ≠ 0 时影子算的 Q 就是 E1 值），影子算的 Q 另列、给出和 Q0 的差；影子不触发 / 没有条目的真放刀
    不再静默剔除：逐条找原因（shadow_gap_reason），分「可解释」（探针没跟到 / 读不到、rc 自己读条目出过错、存活期间 m 变过）
    和「原因不明」（多半是放刀模块偏离规则，e2e 核对当问题报）。"""
    out = Obj(rows=[], sess=[], cal=R.cal)
    for ss in [s for s in R.sessions if s.analysis]:
        cfg = ss.cfg or rc_config(ss.data, ss.fires_all)
        e5 = ss.e5 or E5c(ss.ctx)
        ss.e5 = e5
        own = Shadow(ss.ctx, ss.entries, L_MIN_16, W_LONG_16, H_VETO_16, grab=cfg.grab, sg=cfg.g1)
        full = own if cfg.g1 else Shadow(ss.ctx, ss.entries, L_MIN_16, W_LONG_16, H_VETO_16, grab=True, sg=True)
        own_extra = g1_extra if cfg.g1 else None
        kw = dict(qfun=e5.q, lmin=L_MIN_16, lmin_q=True)
        srow = Obj(label=ss.label, ver=cfg.ver, g1=cfg.g1, n_fire=0, shadow_only=0, shadow_only_contact=0,
                   shadow_only_h=0, nofire_c1=0, n_ep=0)
        for f in ss.fires:
            ep = f.ep
            row = Obj(f=f, sess=ss.label, g1=cfg.g1, em=emid_of(f.keys), keep=f.keep, c1=None, q_act=None, sh=None,
                      sh_h=None, why=None, c_sh=None, c_sh_h=None, cls_act=None, cls_sh=None, cls_sh_h=None, dframe=None,
                      q_sh=None, gap=None)
            srow.n_fire += 1
            out.rows.append(row)
            t_c = f.c_first_rec.t if getattr(f, "c_first_rec", None) is not None else None
            row.cls_act = window_class(f.c_first, R.cal) if f.outcome not in (None, "UNKNOWN") else "无探针数据"
            if cfg.g1:
                row.q_act = f.Q0          # 审查修订：1.6 的「实际 Q」用 FIRE 自己记的 Q0
            if ep is None or not ep.ents:
                row.why = "这个回合没有条目序列（探针没跟踪到）"
                row.cls_sh = "无条目"
                row.cls_sh_h = None if cfg.g1 else "无条目"
                if cfg.g1:
                    row.gap = shadow_gap_reason(ss, f, ep, e5, own, f.L)
                continue
            M = e5.model(ep)
            row.c1 = M.c1
            if M.nofire:
                row.why = M.why
            e = ss.entries.get((f.res, f.ent))
            st = entry_state(e, f.t_req, lo=ep_lo(ep)) if e is not None else None
            if st is not None:
                q_ = e5.q(ep, e, f.t_req, st[1], st[2])
                if cfg.g1:
                    row.q_sh = q_
                else:
                    row.q_act = q_
            row.sh = own.replay(ep, LEAD_16, extra=own_extra, **kw)
            if not cfg.g1:
                row.sh_h = full.replay(ep, LEAD_16, extra=g1_extra, **kw)
            delta = R.cal.delta
            if row.sh is not None and t_c is not None:
                row.c_sh = t_c - (row.sh.t_L + delta)
            if row.sh_h is not None and t_c is not None:
                row.c_sh_h = t_c - (row.sh_h.t_L + delta)
            row.cls_sh = window_class(row.c_sh, R.cal) if row.sh is not None else "不触发"
            row.cls_sh_h = (window_class(row.c_sh_h, R.cal) if row.sh_h is not None else "不触发") if not cfg.g1 else None
            # 1.6 的影子对真 FIRE：按这一刀自己的 L 重放（集成修订：滑块改过的放刀按 28 比会差几帧到几十帧，被误报成实现
            # 错误）；E5c@28 的影子列和 c_first' 照旧按 28
            sh_cmp = row.sh
            if cfg.g1 and f.L is not None and abs(f.L - LEAD_16) > 1e-9:
                sh_cmp = own.replay(ep, f.L, extra=own_extra, **kw)
            if cfg.g1 and sh_cmp is not None and M.ts:
                i_sh = bisect.bisect_left(M.ts, sh_cmp.t_L - 1e-6)
                j = bisect.bisect_left(M.ts, f.t_req)
                cand = [x for x in (j - 1, j) if 0 <= x < len(M.ts)]
                i_req = min(cand, key=lambda x: abs(M.ts[x] - f.t_req)) if cand else None
                row.dframe = (i_sh - i_req) if i_req is not None else None
            if cfg.g1 and (sh_cmp is None or row.dframe is None):
                row.gap = shadow_gap_reason(ss, f, ep, e5, own, f.L)
        # 影子触发、真没放：启用开关开着、触发时在蓄力中
        for ep in ss.episodes:
            if ep.fire is not None or not ep.danger or not ep.ents:
                continue
            srow.n_ep += 1
            M = e5.model(ep)
            if M.nofire:
                srow.nofire_c1 += 1
            sh = own.replay(ep, LEAD_16, extra=own_extra, **kw)
            if sh is not None and cfg.state_at(sh.t_L)[0] is not False:
                srow.shadow_only += 1
                he = sh.he if sh.he is not None else sh.hs
                if any(ss.ctx.ident.same(ep.keys, c.keys)
                       for c in ss.ctx.contacts_in(sh.t_L, sh.t_L + max(0.0, he) / 60.0 + WHIFF_PAD)):
                    srow.shadow_only_contact += 1
            if not cfg.g1:
                shh = full.replay(ep, LEAD_16, extra=g1_extra, **kw)
                if shh is not None and cfg.state_at(shh.t_L)[0] is not False:
                    srow.shadow_only_h += 1
        out.sess.append(srow)
    R.e5r = out
    return out


def g1_report(R):
    """1.4（V16 第 9.1 节，A 阶段的只报告项；任何版本的探针数据都能出）：
      · 每只怪 DANGER 条目（每个回合每条一次）的 GuardType / _IsParryBreak / DamageType 分布，攻击参数为空（ENT 的 guard、
        dmgtype、pbreak 全空）的比例；
      · SKILL_GUARD 家族是不是只出现在抓取（CATCH 三名）上（V16 第 3.4 节的等价性），不在的逐条列出；
      · PH（抵消检查）状态和当时这只怪正在打的条目的 pbreak 对照（新怪上 pb 是否仍然预示 RECOIL）：条目 = 同一只怪、PH 那一刻
        真实剩余 ≤10 帧、真实结束 ≥−10 帧的条目（不论 DANGER / CAUTION；E5c 的 Q，读不到 C1 时按原始 hs）；反例（pb=0 却 RECOIL、pb=1 却
        WAIT/HIT/SUCCESS）逐条列出。来源按 PH 前 1.3 s 内有没有 rc 的放刀请求分自动 / 手动。"""
    per = defaultdict(lambda: Obj(n=0, guard=Counter(), pb=Counter(), dt=Counter(), ap_nil=0))
    sg_bad, ph_rows, ap_off = [], [], []
    for ss in [s for s in R.sessions if s.analysis]:
        n_unk = 0
        for ep in ss.episodes:
            if not ep.danger or ep.t0 is None:
                continue
            em = emid_of(ep.keys)
            for e in danger_entries(ep):
                a = entry_attrs(e, ep.t0 + 0.05)
                if a is None:
                    continue
                if entry_g1x(ss.ctx, e, ep.t0 + 0.05) == "unk":
                    n_unk += 1          # 审查修订：探针 AP 停用之后探针读不到攻击参数，不是游戏数据，不进分布、不算「攻击参数为空」
                    continue
                o = per[em]
                o.n += 1
                gt, pb, dt = a.get("guard"), a.get("pbreak"), a.get("dmgtype")
                if pb is None and gt is None and dt is None:
                    o.ap_nil += 1
                    continue
                o.guard[guard_name(gt)] += 1
                o.pb["读不到" if pb is None else ("1" if pb else "0")] += 1
                o.dt[str(dt) if dt is not None else "读不到"] += 1
                if gt is not None and any(enum_is(gt, "GUARD", n) for n in SG_GUARDS) \
                        and not (isinstance(dt, str) and any(enum_is(dt, "DT", n) for n in GRAB_DT)):
                    sg_bad.append((ss.label, em, ep.keep, guard_name(gt), dt))
        if getattr(ss.ctx, "ap_off", None) is not None:
            ap_off.append((ss.label, ss.ctx.ap_off, n_unk))
        req = sorted(f.t_req for f in ss.fires_all if f.t_req is not None)
        e5 = ss.e5 or E5c(ss.ctx)
        for p in ss.ctx.ph:
            t = p["t"]
            keys = ss.ctx.ident.expand(ident_keys(p.get("target")))
            pbs = set()
            em_p = None
            for ep in ss.episodes:
                if not ep.danger or ep.t0 is None or not (ep.t0 - 0.05 <= t <= (ep.t1 or ep.t0) + 1.0):
                    continue
                if not ss.ctx.ident.same(ep.keys, keys):
                    continue
                em_p = emid_of(ep.keys) if em_p is None else em_p
                # 条目不论 DANGER / CAUTION：DANGER 只按身体胶囊判，刀上接触的那段那一刻可能是 CAUTION（2b 实测）
                for e in ep.ents:
                    i = bisect.bisect_right(e.ts, t) - 1
                    if i < 0 or t - e.samples[i][0] > 0.5:
                        continue
                    _t, _f, _typ, hs, he, _c = e.samples[i]
                    gap = t - e.samples[i][0]
                    hs2 = hs - 60.0 * gap
                    he2 = (he - 60.0 * gap) if he is not None else hs2
                    # 怪物按 CoreState 倍速走，C>1 时攻击比原始 hs 归零早到（SPEED 2.1）：有 E5c 的 Q 就按 Q 判断条目是不是
                    # 正在打（真实剩余 ≤10 帧、真实结束 ≥−10 帧），读不到 C1 时退回原始 hs
                    qs, qe = e5.q(ep, e, t, hs2), e5.q(ep, e, t, he2)
                    if qs is None or qe is None:
                        qs, qe = hs2, he2
                    if qs <= 10.0 and qe >= -10.0:
                        a = entry_attrs(e, t)
                        pbs.add(None if a is None else a.get("pbreak"))
            pbs.discard(None)
            pbc = ("找不到条目" if not pbs else "pb=1" if pbs == {True} else "pb=0" if pbs == {False} else "混合")
            i = bisect.bisect_right(req, t) - 1
            src = "自动" if i >= 0 and t - req[i] <= CREDIT else "手动"
            st = p.get("state")
            stn = next((n for n in ("WAIT", "HIT", "SUCCESS", "RECOIL", "NONE") if enum_is(st, "PS", n)), str(st))
            bad = (pbc == "pb=0" and stn == "RECOIL") or (pbc == "pb=1" and stn in ("WAIT", "HIT", "SUCCESS"))
            ph_rows.append(Obj(sess=ss.label, t=t, state=stn, pb=pbc, src=src, bad=bad,
                               em=emid_of(keys) if emid_of(keys) is not None else em_p))
    R.g1r = Obj(per=per, sg_bad=sg_bad, ph=ph_rows, ap_off=ap_off)
    return R.g1r


def monitor16(R):
    """1.4（V16 第 7 节第 6 条、第 9.3 节，C 阶段监控，只报告）：1.6 起的 session 按（怪, 招）汇总 FIRE、接住、RECOIL、NOCATCH
    （放刀模块自己的 RES，不开探针也有；有探针时接住 / RECOIL 以离线分类为准），有探针时再分放早 / 纯空挥 / 打断。
    任何 RECOIL、或某一招放早 ≥3、或 NOCATCH ≥3 → 报告开头列出，附这一招的 A0、C1、GuardType、pbreak。"""
    rows = defaultdict(lambda: Obj(fires=[], n=0, catch=0, recoil=0, nocatch=0, early=0, whiff=0, inter=0, a0=[], c1=[],
                                   guard=Counter(), pb=Counter()))
    any16 = False
    for ss in [s for s in R.sessions if s.analysis]:
        cfg = ss.cfg or rc_config(ss.data, ss.fires_all)
        if not cfg.e5c:
            continue
        any16 = True
        for f in ss.fires_all:
            o = rows[(emid_of(f.keys), f.keep)]
            o.fires.append(f)
            o.n += 1
            rco = str(f.rc_outcome or "").upper()
            off = f.outcome if f.entered and f.outcome not in (None, "UNKNOWN") else None
            if off is not None:
                o.catch += off == "CATCH"
                o.recoil += off == "RECOIL"
            else:
                o.catch += rco in ("CATCH26", "CATCH27")
                o.recoil += rco in ("RECOIL", "CATCH25")
            o.nocatch += rco == "NOCATCH"
            o.early += off == "FAIL_EARLY"
            if off == "WHIFF":
                if d16_kind(f) == "纯空挥":
                    o.whiff += 1
                else:
                    o.inter += 1
            if f.A0 is not None:
                o.a0.append(f.A0)
            if f.C1 is not None:
                o.c1.append(f.C1)
            e = ss.entries.get((f.res, f.ent))
            a = entry_attrs(e, f.t_req) if e is not None else None
            if a is not None:
                o.guard[guard_name(a.get("guard"))] += 1
                o.pb["读不到" if a.get("pbreak") is None else ("1" if a.get("pbreak") else "0")] += 1
    for (em, keep), o in rows.items():
        o.alert = [w for w, on in (("RECOIL", o.recoil >= 1), (f"放早 ≥{MON_EARLY}", o.early >= MON_EARLY),
                                   (f"NOCATCH ≥{MON_NOCATCH}", o.nocatch >= MON_NOCATCH)) if on]
    R.mon16 = Obj(rows=rows, any=any16) if any16 else None
    return R.mon16


# ---------------------------------------------------------------- 报告
INSUFF = "样本不足"


def md_table(headers, rows):
    out = ["| " + " | ".join(headers) + " |", "|" + "|".join("---" for _ in headers) + "|"]
    for r in rows:
        out.append("| " + " | ".join(str(x).replace("|", "\\|") for x in r) + " |")
    return "\n".join(out)


def act_str(a):
    return "—" if a is None else f"({a[0]},{a[1]})"


def wilson_str(k, n):
    lo, hi = wilson(k, n)
    return "—" if lo is None else f"{k}/{n} = {100.0 * k / n:.0f}%（80% 区间 {100 * lo:.0f}~{100 * hi:.0f}%）"


def rc_mode_text(cfg):
    """报告头：这个 session 的 rc 是哪一版、参数怎么定的（HDR）。"""
    if cfg is None or cfg.hdr is None:
        return "没有 rc 的 HDR（参数状态未知）"
    p = f"L_min={_lead_s(cfg.lmin)}、W_long={_lead_s(cfg.wlong)}、H_veto={_lead_s(cfg.hveto)}"
    if cfg.release:
        bad = frozen_mismatch(cfg)      # 1.2：加载时就不是冻结值，不能写「冻结」
        doc = frozen_doc(cfg.ver, getattr(cfg, "rule", None))      # 1.4：v1.6 的冻结值出自 V16（旧版本措辞不变）
        frz = "冻结" if not bad else f"——**加载时不是 {doc} 冻结值（" + "，".join(bad) + "），D 整段不计**"
        e16 = (f"（Q 单位；rule={cfg.rule or '—'}、filter={cfg.filter or '—'}、cfg_ver={_lead_s(cfg.cfg_ver)}）"
               if getattr(cfg, "e5c", False) else "")
        return (f"版本 {cfg.ver}，发布版（提前量 L={_lead_s(cfg.lead0)}{e16}、{p} {frz}；不轮换、没有机关扫描；"
                f"加载时启用开关{_onoff(cfg.auto0)}）")
    if cfg.rotating:
        return (f"版本 {cfg.ver}，标定版（L 按 {{{','.join(str(x) for x in ROTATION_LS)}}} 轮换，HDR lead="
                f"{_lead_s(cfg.lead0)} 不生效；{p}" + ("；本轮有机关扫描记录" if cfg.has_scan else "") + "）")
    return f"版本 {cfg.ver}，提前量固定 L={_lead_s(cfg.lead0)}（{p}" + ("；有机关扫描记录" if cfg.has_scan else "") + "）"


def d_scope_text(d):
    """D 的数据范围：这个 session 有没有参数改动、从哪里截断（rc_config 的口径）；1.2：整段不计的原因、启用开关切换。"""
    c = d.cfg
    toggles = getattr(c, "toggles", [])
    n_cfg = len(c.changes) + len(c.noops) + len(toggles)
    if n_cfg:
        src = f"CFG {n_cfg} 条" + (f"（其中和上一状态相同、不算改动的 {len(c.noops)} 条）" if c.noops else "")
    else:
        src = "没有 CFG 记录" + ("（1.5-rc1 不写 CFG）" if "rc" in c.ver.lower() else "")
    tog = ""
    if toggles or c.auto0 is False:
        tog = (f"；启用开关{'加载时关着，' if c.auto0 is False else ''}切换 {len(toggles)} 次（"
               + "；".join(f"t={x.t:.3f} {x.what}" for x in toggles[:5]) + (f" 等" if len(toggles) > 5 else "")
               + "）：开关不改规则参数，不截断；D 不算关着的时段（那时开始的回合、PERF 不计，挨打另计）")
    if getattr(d, "excluded", None):
        return f"参数改动：{src}{tog} → **这次加载整段不计入 D**：{d.excluded}（放刀 0/{d.n_all}）"
    if c.cut is None:
        tail = ("；L 轮换（标定轮），不按 FIRE.L≠HDR.lead 推断" if c.rotating else
                "；也没有 L≠HDR.lead 的放刀" if c.hdr is not None else "；没有 rc 的 HDR，无法推断")
        return f"参数改动：{src}{tail}{tog} → 不截断，D 用全部数据" + ("（开关关着的时段除外）" if tog else "")
    if c.cut_src == "CFG":
        how = f"CFG（{c.changes[0].what}）"
    elif c.cut_src == "推断":
        how = (f"推断：放刀 #{c.f_inf.id} 的 L={_lead_s(c.f_inf.L)} ≠ HDR.lead={_lead_s(c.lead0)}"
               + ("" if not c.changes else "，比第一条 CFG 改动还早"))
    else:
        how = "SLIDER/LEAD 记录"
    detail = ""
    if c.changes:
        detail = "；改动明细：" + "；".join(f"t={x.t:.3f} {x.what}" for x in c.changes[:5]) + \
                 (f" 等 {len(c.changes)} 次" if len(c.changes) > 5 else "")
    return (f"参数改动：{src}；第一次改动 t={c.cut:.3f}，来源 {how} → D 只用这之前的数据（PLAN D）：放刀 "
            f"{len(d.fires)}/{d.n_all}（之后 {d.n_all - len(d.fires)} 次不计）{detail}{tog}")


def d_item_result(i):
    if i.pending:
        return "待用户确认"
    if i.ok:
        return "通过"
    if getattr(i, "review", False):
        return "需复核"
    return INSUFF if i.insufficient else "不通过"


def d_conclusion(R):
    pre = {"calibration": "（标定轮，只作预览）", "fixed": "（rc 固定提前量，不是发布版 v1.5）"}.get(R.d_mode, "")
    items = R.d_items or []
    pend = [i.name for i in items if i.pending]
    # 1.2：探针进入过红状态（数据质量）不判 v1.5 不通过；结论不是「需复核」时也提醒数字要复核
    rev = [i for i in items if getattr(i, "review", False) and not i.ok]
    note = "另外探针进入过红状态，上面的数字可信度存疑，要复核。" if rev else ""
    if R.d_verdict == "离线各项通过":
        if R.d_mode == "calibration":
            return f"**D 结论{pre}：离线各项都在验收线内；正式验收看第 2 轮（v1.5 参数冻结）。**"
        return (f"**D 结论{pre}：离线各项通过；待用户确认：{'；'.join(pend) or '无'}。确认后验收通过。**")
    if R.d_verdict == "不通过":
        return (f"**D 结论{pre}：不通过。** 把上面的数字交给用户决定（PLAN 没有给 D 预设退路，可参照 PLAN C9 的退路："
                f"A 保守模式 / B 提示模式 / C 默认关闭的实验开关）。{note}")
    if R.d_verdict == "样本不足":
        ins = [i.name for i in items if i.insufficient and not i.ok]
        allx = "所有加载都整段不计（原因见上面的参数改动）；" if R.d_sess and all(
            getattr(d, "excluded", None) for d in R.d_sess) else ""
        return (f"**D 结论{pre}：样本不足**（{allx}{'；'.join(ins)}。有接触的放刀 n≥{D_N_CONTACT}、放刀 n≥{D_N_FIRE} 才下结论，"
                f"沿用 C9(b)(c)" + (f"；发布版还要两只怪 D 范围内各有 ≥{D_PROTO_MIN_DANGER} 个 DANGER 回合、有定标 session 时"
                                    f"其中有新怪（PLAN D 的协议）" if R.d_mode == "release" else "")
                + f"），需要补打。{note}")
    if R.d_verdict == "需复核":
        return (f"**D 结论{pre}：需复核。** 离线各项没有不通过，但探针进入过红状态（见上表「数据质量」），数据可信度存疑："
                f"先复核日志里探针出错的时段和原因，必要时补打；这不判 v1.5 不通过（探针不随发布版发布）。")
    return f"**D 结论：{INSUFF}（判定没算出来，见报告头的内部错误）**"


def render(R, strict=False):
    L = []
    w = L.append
    # 1.4：C 阶段监控的提醒放在报告开头（V16 第 7 节第 6 条），E5c 影子回放、G1 只报告项、C 阶段监控全表接在最后（新增的节）
    for fn in (render_head, render_monitor_alert, render_summary, render_sample, render_params, render_c1, render_c2_c3,
               render_c4_c6, render_outcomes, render_attrib, render_gates, render_verdict, render_diag, render_e5c,
               render_g1, render_mon16):
        try:
            fn(R, w)
        except Exception as e:  # noqa: BLE001  一节渲染出错不影响其他节
            if strict:
                raise
            w(f"\n（{fn.__name__} 渲染出错：{type(e).__name__}: {e}）\n")
    return "\n".join(L) + "\n"


def render_head(R, w):
    info = R.info
    # 参数冻结的 v1.5 发布版数据 = 第 2 轮验收；其余（轮换标定、mock）沿用 1.0 的标题。1.3：标题写发布版的版本号
    # （几个版本合并时写最新的；1.5 的数据标题不变）
    rel_vers = [d.cfg.ver for d in (R.d_sess or []) if d.cfg is not None and d.cfg.hdr is not None and d.cfg.release]
    rel_ver = newest_version(rel_vers) or "1.5"
    if R.d_mode == "release" and getattr(R, "d16", None) is not None:
        # 1.4：有 1.6 起的发布版 session = B 阶段验收（V16 第 9.2 节）
        w(f"# 自动放刀 B 阶段验收报告（v{rel_ver} 离线分析）\n")
    else:
        w(f"# 自动放刀第 2 轮验收报告（v{rel_ver} 离线分析）\n" if R.d_mode == "release" else "# 自动放刀第 1 轮离线分析报告\n")
    w(f"- 分析脚本：{ANALYZER_VERSION}（规则按 PLAN.md DECISION RULE B/C/D 与 P23 预注册）")
    w(f"- 脚本修订：{ANALYZER_REV}")
    w(f"- 脚本修订：{ANALYZER_REV_13}")
    w(f"- 脚本修订：{ANALYZER_REV_14}")
    w(f"- 脚本修订：{ANALYZER_REV_14R}")
    w(f"- 脚本修订：{ANALYZER_REV_15}")
    # 1.5：合并版的 session（HDR 带 host）另起一行写明它没有哪些记录（MERGE 第 4.4 节第 3 条）
    hosts = sorted({c.host for c in (getattr(ss, "cfg", None) for ss in (R.sessions or [])) if c is not None and c.merged}
                   | {d.cfg.host for d in (R.d_sess or []) if d.cfg is not None and getattr(d.cfg, "merged", False)})
    if hosts:
        w(f"- 合并版（{'、'.join(hosts)}）放刀日志：只有 HDR、FIRE、RES、ERR、RED；没有 VETO、SKIP、UVIEW、STAT、CFG、FIRE_END、"
          "JSON。依赖这些的项写『—（合并版不记）』")
    if R.d_mode == "release" and len(set(rel_vers)) > 1:
        w(f"- **合并了不同版本的发布版 session**（{'、'.join(sorted(set(rel_vers), key=lambda v: version_tuple(v) or (0,)))}）："
          "冻结参数不同（提前量 " + "/".join(_lead_s(frozen_table(v)[0][2]) for v in
                                     sorted(set(rel_vers), key=lambda v: version_tuple(v) or (0,)))
          + "），D 按各自版本的冻结值判断是否整段不计，但验收数字是合在一起算的；验收某一版只用那一版的 session")
    sessions = R.sessions or []
    if len(sessions) > 1:
        w(f"- **多个 session 合并分析**（每个 session 各自按 os.clock 做时间关联，派生样本再合并；"
          f"定标 = 扫描窗口、T_armor、δ 只取「定标」session）：")
        for ss in sessions:
            role = "、".join(x for x, on in (("分析", ss.analysis), ("定标", ss.calib)) if on)
            w(f"  - {ss.label}（{role}）：放刀 {len(ss.fires)}，扫描样本 {sum(1 for s in ss.scans if s.phase == 'fire')}，"
              f"空挥 {ss.n_swing}，δ 样本 {len(ss.ds)}，DANGER 回合 {sum(1 for e in ss.episodes if e.danger)}")
    for ss in (sessions or [Obj(data=R.data, label="", analysis=True)]):
        info = ss.data.info
        pre = f"[{ss.label}] " if len(sessions) > 1 else ""
        ch = info.get("chosen", {})
        w(f"- {pre}session：APCal = {fmt(ch.get('pr'))}，AutoParryGS = {fmt(ch.get('rc'))}（目标 {fmt(info.get('target'))}；"
          f"全部 APCal {info.get('sessions', {}).get('pr', [])}，AutoParryGS {info.get('sessions', {}).get('rc', [])}）")
        w(f"- {pre}JSON 文件：{len(info.get('files', []))} 个（APCal seq {info.get('seqs', {}).get('pr', [])}，"
          f"AutoParryGS seq {info.get('seqs', {}).get('rc', [])}）；日志：{info.get('log') or '未找到'}")
        if ss.data.get("rc", "HDR") or ss.data.get("rc", "FIRE"):
            cfg = getattr(ss, "cfg", None) or rc_config(ss.data, getattr(ss, "fires_all", []))
            w(f"- {pre}rc：{rc_mode_text(cfg)}")
        for src, name in (("pr", "APCal"), ("rc", "AutoParryGS")):
            if info.get("used_log_only", {}).get(src):
                w(f"- {pre}**{name} 没有 JSON，全部记录取自日志**（{info['log_added'][src]} 条；SER/ANIM/HOLD 只进 JSON，缺失）")
            elif info.get("log_added", {}).get(src):
                w(f"- {pre}{name}：JSON 之外从日志补入 {info['log_added'][src]} 条（JSON 某些 seq 缺失或崩溃前未写出）")
        if info.get("enum_hits"):
            w(f"- {pre}枚举数值：用探针 HDR 的 enums 覆盖了 {info['enum_hits']} 项")
        for p in info.get("problems", []):
            w(f"- {pre}读取问题：{p}")
        for p in info.get("notes", []):
            w(f"- {pre}说明：{p}")
        ctx = getattr(ss, "ctx", None) or R.ctx
        stops = getattr(ctx, "stops", [])
        if stops:
            w(f"- {pre}探针「停止记录」区间 {len(stops)} 段（判定期和它重叠的放刀记 UNKNOWN，不按没看到接触判空放）：" +
              "，".join(f"{a:.1f}~{'结束' if b == math.inf else format(b, '.1f')}" for a, b in stops[:8]))
        dm = getattr(ss, "demote", None)
        if dm is not None and (dm.disjoint or dm.st2_sysidx):
            w(f"- {pre}**攻击者身份警报**：接触侧（CT，_Context._Em.get_SystemIndex）和预告侧（MSG，get_EmSystemIndex）的 "
              f"SystemIndex {'没有任何共同值' if dm.disjoint else ''}{'；自检2 报 sysidx 不一致' if dm.st2_sysidx else ''}"
              f"。{dm.n} 个接触的 sys 键已降级，改按发送者地址/共现学习匹配；P23 结果请结合下面的别名表复核")
        elif dm is not None and dm.n:
            w(f"- {pre}{dm.n} 个接触的 SystemIndex 在预告侧从没出现过（多半是全场无预告的机关或小怪），已降级为只按地址/名字匹配")
    if R.calib_missing:
        w(f"- **定标 session 没读到任何记录**：{'、'.join(fmt(x) for x in R.calib_missing)}（session 号不对，或那一轮的数据"
          f"在别的目录、要加 --calib-dir）。窗口 W0/W1、T_armor、δ 退回先验")
    if R.d_mode == "release":
        used = {ss.data.info.get("chosen", {}).get("rc") for ss in sessions}
        others = sorted(set((R.info.get("sessions") or {}).get("rc", [])) - used)
        if others:
            w(f"- 数据目录里还有别的 rc session {others}（这次没分析）：第 2 轮如果分几次加载（中途 Reset Scripts 或重开游戏），"
              f"用 --session 把它们一起列上合并分析；第 1 轮（标定版）的 session 只能当 --calib-session")
    if R.d_mode == "release" and not R.scan_used and not any(ss.calib and not ss.analysis for ss in sessions):
        w("- **提示**：v1.5 没有机关扫描，这次也没给定标 session，窗口 W0/W1、T_armor、δ 用的是先验（第 1~5 节的窗口相关"
          "数字只作参考）。取第 1 轮的定标：--calib-session 1791644664 --calib-dir tools/out/round1_data。"
          "D 节的接住率、空放率只看有没有该攻击者的接触、有没有进 (2,26)/(2,27)（1.4：(2,25) 算 RECOIL），不依赖窗口")
    if R.crashed_flag:
        w("- **用户报告游戏崩溃过**（--crashed）：C9(d) 判「有崩溃」")
    if R.unclean:
        w(f"- 提示：{'、'.join(R.unclean)} 最后一份 JSON 不是「写出数据」按钮 / Reset 写出的——可能崩溃，也可能忘了点"
          f"「写出数据」（最后不到 60 s 的记录只在日志里）。崩溃请向用户确认后用 --crashed 重跑")
    if R.errors:
        w(f"- **分析脚本内部错误 {len(R.errors)} 处**（对应小节结果不可信）：")
        for e in R.errors[:20]:
            w(f"  - {e}")
    w("")


def render_summary(R, w):
    """第 2 轮（v1.5 发布版）把验收结论放在报告最前面；口径、按怪统计和数字来源见第 11 节 D。其他模式不输出。
    1.4：有 1.6 起的发布版 session 时换成 B 阶段验收（V16 第 9.2 节）的摘要。"""
    if R.d_mode != "release" or not R.d_items:
        return
    if getattr(R, "d16", None) is not None:
        render_summary16(R, w)
        return
    w("## 验收摘要（PLAN D；口径、按怪统计见第 11 节）\n")
    for d in R.d_sess:
        w(f"- {('[' + d.label + '] ') if len(R.d_sess) > 1 else ''}{d_scope_text(d)}")
    w("")
    w(md_table(["项", "数值", "门槛", "结果"], [(i.name, i.value, i.rule, d_item_result(i)) for i in R.d_items]))
    kn, nn = R.d_whiff_noint
    w(f"\n- 参考：不计先砍中打断（INTERRUPTED {R.d_int} 次）的空放率 {pct(kn, nn)}，不作门槛（见第 11 节）")
    w(f"\n{d_conclusion(R)}\n")


def d16_conclusion(R):
    D = R.d16
    items = D.items
    if D.verdict == "通过":
        return ("**D 结论（v1.6 B 阶段，V16 第 9.2 节）：通过。** 新怪合并的接住率、纯空挥率、开销、放刀模块 RED 都在门槛内，"
                "样本够数。通过只说明测过的这几只怪；普适性靠 A 阶段的机制检验加 C 阶段的监控（第 15 节）。")
    if D.verdict == "不通过":
        bad = [i.name for i in items if not i.ok and not i.insufficient and not i.review]
        return ("**D 结论（v1.6 B 阶段）：不通过。**（" + "；".join(bad) + "）按 V16 第 9.2 节「失败时」：接住率不过或有怪被标左尾 → "
                "用 SPEED 7.1 的判据在 B 数据上诊断是机制失败还是左尾，要不要改 L 由用户定（改了是新迭代、换新怪）；RED、崩溃或开销"
                "超标 → 修实现、不改规则参数；只有纯空挥不过 → 用户决定接受还是研究机制层面的闸门。")
    if D.verdict == "样本不足":
        ins = [i.name for i in items if i.insufficient and not i.ok]
        return ("**D 结论（v1.6 B 阶段）：样本不足**（" + "；".join(ins) + f"）。要至少 {D16_MIN_MONSTERS} 只新怪、每只 ≥"
                f"{D16_MIN_CONTACT} 次有接触的放刀（刻意按住蓄力约 12~15 分钟），需要补打。")
    if D.verdict == "需复核":
        rev = [i.name for i in items if i.review and not i.ok]
        return ("**D 结论（v1.6 B 阶段）：需复核。** 判定项没有不通过、样本够数，但数据质量有问题（" + "；".join(rev)
                + "），先复核日志和部署（v1.6 必须和 APCal ≥1.1 一起跑）再下结论；这不判 v1.6 不通过。")
    return f"**D 结论：{INSUFF}（判定没算出来，见报告头的内部错误）**"


def render_summary16(R, w):
    D = R.d16
    w("## 验收摘要（V16 第 9.2 节 B 阶段验收，v1.6；口径、按怪统计见第 11 节）\n")
    for d in D.ds:
        w(f"- {('[' + d.label + '] ') if len(R.d_sess) > 1 else ''}{d_scope_text(d)}")
    for d in D.others:
        w(f"- [{d.label}] 版本 {d.cfg.ver or '—'} 不是 1.6 起的发布版：不进 B 阶段验收（V16 第 7 节第 4 条只对 ≥1.6 的 session）")
    w("")
    w(md_table(["项", "数值", "门槛", "结果"], [(i.name, i.value, i.rule, d_item_result(i)) for i in D.items]))
    t = D.tot
    strict_k = t["纯空挥"] + t[INT_KINDS[1]] + t[INT_KINDS[2]]
    strict_n = t["已分类"] - t[INT_KINDS[0]]
    w(f"\n- 新怪：{'、'.join(f'em{e}' for e in D.new) or '无'}（设计集 em{', em'.join(str(x) for x in DESIGN_EMIDS)} "
      f"和训练机关 em{DUMMY_EMID} 不算）；打断（先砍中把怪打出硬直、攻击没来）{D.n_int} 次，占新怪已分类放刀 "
      f"{pct(D.n_int, t['已分类'])}：不计入空放（用户决定，V16 第 9.2 节），从分子分母都去掉")
    w(f"- 参考（严格版，只把 INTERRUPTED 当打断）：纯空挥率 {cp_str(strict_k, strict_n)}，不作门槛")
    if D.flags:
        w("- 逐只怪标记（只标不判）：" + "；".join(f"em{e} {v}" for e, v in sorted(D.flags.items(), key=lambda kv: (
            kv[0] is None, kv[0] if kv[0] is not None else 0))))
    w(f"\n{d16_conclusion(R)}\n")


def render_sample(R, w):
    ctx = R.ctx
    fires_all = R.fires_all
    n_assumed = sum(1 for f in fires_all if f.entered_assumed)
    scans = R.scans
    sc = Counter((s.phase, s.status) for s in scans)
    m = R.match
    danger_eps = [e for e in R.episodes if e.danger]
    moves = {(emid_of(e.keys), e.keep) for e in danger_eps}
    w("## 0. 样本量与数据质量\n")
    rows = [
        ("rc 放刀请求 FIRE", f"{len(fires_all)}（进入 (2,23) {len(R.fires)}，未进入 {len(fires_all) - len(R.fires)}"
                           + (f"，其中 {n_assumed} 个缺 FIRE_END/ACT 按已进入计" if n_assumed else "") + "）"),
        ("扫描样本 SCAN", "，".join(f"{p or '?'}/{s or '?'} {n}" for (p, s), n in sorted(sc.items())) or "0"),
        ("扫描有效样本（C1 用）", f"{sum(1 for s in R.scan_used if s.label in ('PARRY', 'FAIL'))}"
                             f"（RECOIL 剔除 {sum(1 for s in R.scan_used if s.label == 'RECOIL')}）"),
        ("空挥/空放（无接触、停在 (2,23) ≥2 s；T_armor 用）", R.n_swing),
        ("手动放刀 PT（没对上 rc 请求的 (2,23)/(2,24)）", f"{len(R.manual)}" + (
            "（" + "，".join(f"{k} {v}" for k, v in R.manual_out.items()) + "）" if R.manual_out else "")
         + (f"；另有扫描作废样本的放刀 {len(R.scan_void_pts)}" if R.scan_void_pts else "")),
        ("回合（DANGER/全部）", f"{len(danger_eps)}/{len(R.episodes)}；不同招式 {len(moves)}"),
        ("敌方接触 CT", m.total),
        ("P23 匹配：已匹配 / 未匹配 / 有歧义", f"{m.matched} / {m.unmatched}（其中攻击者全场无预告 {m.no_pred_attacker}） / {m.ambiguous}"),
        ("放刀的首个接触落在自己回合 P23 窗口外（c_first 不经 P23，照样计入）", R.outside_p23),
        ("条目序列来源", R.ser_mode),
        ("卡顿 HITCH/GAP（dt>0.035）", sum(len(ss.ctx.hitch_ts) for ss in R.sessions if ss.analysis) if R.sessions
         else len(ctx.hitch_ts)),
        ("进入红状态 RED（关键错误）/ 核心模块错误 ERR 红 / 可选模块错误 ERR 黄", f"{R.err.red} / {R.err.core} / {R.err.yellow}"),
    ]
    w(md_table(["项目", "数量"], rows))
    for ss in (R.sessions or []):
        if not ss.analysis or ss.ctx is None or not ss.ctx.ident.table:
            continue
        pre = f"（{ss.label}）" if len(R.sessions) > 1 else ""
        w(f"\n攻击者身份别名{pre}（接触侧地址/名字 → 预告侧 em#SystemIndex）：\n")
        w(md_table(["接触侧键", "→ SystemIndex", "次数", "次多者", "方式"],
                   [(f"{k[0]}:{k[1]}", s[1], n, n2, how) for k, s, n, n2, how in ss.ctx.ident.table[:30]]))
    w("")


def render_params(R, w):
    ctx = R.cal
    ws = R.win_scan
    w("## 1. 参数表\n")
    w1_txt = (("≥ " if ctx.cens1 else "") + fmt(ctx.W1))
    # 1.2：第 2 轮（发布版）的「默认」列是 V15 冻结值，不是 rc 的 28/18；样本不足时的回退值同（_analyze_core）。
    # 1.3：冻结的提前量按版本（R.release_dflt：1.5 → 26，1.5.1 → 30）
    rel = R.d_mode == "release"
    rdflt = getattr(R, "release_dflt", None) or V15_DEFAULTS
    # 1.4：最新的发布版是 1.6 起的，冻结值出自 V16（提前量 28 是 Q 单位）；更早的版本措辞不变
    v16 = rel and frozen_doc(getattr(R, "release_ver", None), getattr(R, "release_rule", None)) == "V16"
    dflt, dname = (rdflt, "V16 冻结" if v16 else "V15 冻结") if rel else (DEFAULTS, "默认")
    fb = dflt if getattr(R, "release_all", False) else DEFAULTS
    rows = [
        ("W0（窗口起点，c_first 轴）", fmt(ctx.W0), f"先验 {W_PRIOR[0]}", f"{R.win_source}；扫描 {ws.m0 or INSUFF}"),
        ("W1（窗口终点）", w1_txt, f"先验 {W_PRIOR[1]}", f"{R.win_source}；扫描 {ws.m1 or INSUFF}"),
        ("T_armor（空挥 SUPER_ARMOR 结束）", fmt(R.t_armor), "—", (f"空挥 {R.n_swing} 次，读到 {len(R.t_armor_vals)} 个"
         "（每次取离开 (2,23) 前最后一段持续 sa=0 的起点）") if R.t_armor_vals else INSUFF),
        ("W1_eff = min(W1, T_armor−0.05)", fmt(ctx.W1_eff), "—",
         "**矛盾**：T_armor−0.05 ≤ W0+0.05，T_armor 多半读错，未用它截 W1" if R.t_armor_conflict else ""),
        ("δ = median(t_start − t_req)", fmt(ctx.delta, 4), f"先验 {DELTA_PRIOR}", INSUFF + "（用先验）" if R.delta_prior else f"n={R.delta_n}"),
        ("d̄ = median(L − R0)（只用穿越 L 触发的放刀）", fmt(R.dbar, 2), "—",
         (INSUFF + "（用 0.5）" if R.dbar_prior else f"n={len(R.dbar_vals)}")
         + (f"；晚触发（DANGER 晚出现/晚蓄力/否决刚结束）{R.dbar_late} 次不计入" if R.dbar_late else "")),
        ("Spearman ρ(r, R0) / 斜率 b", f"{fmt(R.model.rho, 2)} / {fmt(R.model.b, 4)}",
         "|ρ|≥0.4 才校正", "已校正（Theil–Sen 斜率）" if R.model.corrected else "不校正"),
        ("L*（提前量，1/60 s）", fmt(R.Lstar), f"{dname} {dflt['L']}",
         f"有接触真放刀 n={len(R.res)}，最大覆盖 {R.Nmax}" if R.Lstar is not None else INSUFF + f"（沿用 {fb['L']}）"),
        ("L_min*", fmt(R.lmin), f"{dname} {dflt['L_min']}",
         f"原始 {fmt(R.lmin_raw)}，夹到 [15, L*−6]" if R.lmin is not None else INSUFF + f"（沿用 {fb['L_min']}，需 n≥4）"),
        ("W_long*", R.wlong, f"{dname} {dflt['W_long']}", f"he−hs∈(30,60] 组接住 {R.wlong_k}/{R.wlong_n}"
         + ("" if R.wlong_n >= 4 else "，" + INSUFF + "（n<4 不调）")),
        ("H_veto", DEFAULTS["H_veto"], "固定", "本轮不标定"),
        ("估计量 / α", c6_choice(R), "V0 / 0", "C6：其他方案 IQR 小 20% 以上才换"),
        ("闸门", ("、".join(g for g, _r in R.gates.chosen) if R.gates and R.gates.chosen else "无")
         + ("；g6 速度缩放（C6 采用）" if c6_choice(R).startswith("g6") else ""), "无",
         f"C8：评估 {R.gates.evaluated if R.gates else 0} 个候选" + ("（+g6 按 C6 IQR 评估）")),
    ]
    w(md_table(["参数", "本轮结果" if R.d_mode == "release" else "第 1 轮结果", "默认/先验", "依据与样本"], rows))
    if R.d_mode == "release":
        # v1.5 的参数已经冻结（V15 第 1 节），这张表是拿第 2 轮数据重估一遍作复核，不改参数。
        # 1.3：1.5 的那行一字不改；1.5.1 起写它自己的冻结值（V15 第 9 节）
        frz = ("V15" if rdflt["L"] == V15_DEFAULTS["L"] else
               f"V15 第 9 节 v{getattr(R, 'release_ver', None) or '1.5.1'}") + \
            f"：L={rdflt['L']}、L_min={rdflt['L_min']}、W_long={rdflt['W_long']}、H_veto={rdflt['H_veto']}"
        if v16:
            frz = (f"V16 v{getattr(R, 'release_ver', None) or '1.6'}：L={rdflt['L']}（Q 单位，真实剩余帧）、"
                   f"L_min={rdflt['L_min']}（Q 单位）、W_long={rdflt['W_long']}、H_veto={rdflt['H_veto']}（原始 hs）、rule=E5c、filter=g1")
        w(f"\n- 第 2 轮参数已冻结（{frz}），上表是用本轮数据按 C 节重估的复核值，"
          "不用来改参数；窗口、T_armor、δ 的来源见第 2 节")
        if v16:
            w("- 1.4：v1.6 的放刀按 FIRE 的 Q0（真实剩余帧）算 C2 残差、C3 覆盖曲线和 d̄（穿越 = Qp > L），和 L、L_min 同一单位；"
              "C6~C8 的影子回放仍按原始 hs（第 1 轮的口径，只作复核），v1.6 规则的影子回放见第 13 节")
    w("")


def c6_choice(R):
    rows = R.c6 or []
    base = next((r for r in rows if r.name.startswith("V0")), None)
    if base is None or base.logo is None or base.n < 8:
        return "V0 / α=0（" + INSUFF + "，维持默认）"
    best = None
    for r in rows:
        if r is base or r.logo is None or r.base_logo is None or r.n < 8:
            continue
        if r.logo <= (1 - IQR_GAIN) * r.base_logo and (best is None or r.logo < best.logo):
            best = r
    return best.name if best else "V0 / α=0"


def render_c1(R, w):
    ctx, ws = R.cal, R.win_scan
    w("## 2. C1 抵消窗口 [W0, W1]\n")
    if not R.scan_used:
        w(f"- 扫描：{INSUFF}（没有 phase=fire、status=OK 且有接触的样本）。窗口暂用先验 W0={W_PRIOR[0]}、W1={W_PRIOR[1]}。")
    else:
        rows = [(fmt(s.X, 2), fmt(s.c_first, 3), s.label, s.t_start_src or "δ") for s in
                sorted(R.scan_used, key=lambda s: s.c_first if s.c_first is not None else 9)]
        w(f"- 扫描有效样本 {ws.n}（PARRY {ws.nP}、FAIL {ws.nF}）：\n")
        w(md_table(["X 目标", "c_first（实测）", "标签", "t_start 来源"], rows))
        w("")
        if not ws.ok:
            w(f"- 扫描窗口：{INSUFF}（至少 2 个 PARRY、共 4 个样本，且 W0<W1）")
        else:
            ci0 = f"，bootstrap 80% 区间 {fmt(ws.ci0[0])}~{fmt(ws.ci0[1])}" if ws.ci0 else ""
            ci1 = f"，bootstrap 80% 区间 {fmt(ws.ci1[0])}~{fmt(ws.ci1[1])}" if ws.ci1 else ""
            w(f"- 扫描窗口：W0 = {fmt(ws.W0)}（{ws.m0}{ci0}）；W1 = {'≥ ' if ws.cens1 else ''}{fmt(ws.W1)}（{ws.m1}{ci1}）")
    n, ok, bad = R.agree
    w(f"- 真怪核对（有接触的真放刀，±0.03 s 内两种标签都算一致，RECOIL 不计）：一致 {pct(ok, n)}"
      + ("" if n >= 10 else f"；n<10，{INSUFF}，不触发改用真怪标签"))
    if R.win_real is not None:
        wr = R.win_real
        w(f"- 一致率 <80%：真怪标签同法估计 W0={fmt(wr.W0)}（{wr.m0}）、W1={fmt(wr.W1)}（{wr.m1}）；最终来源：{R.win_source}")
    if bad:
        w("- 不一致样本（c_first, 是否接住）：" + "，".join(f"({fmt(c)}, {'接住' if k else '未接住'})" for c, k in bad[:20]))
    w(f"- 最终：W0 = {fmt(ctx.W0)}，W1 = {'≥ ' if ctx.cens1 else ''}{fmt(ctx.W1)}，"
      f"T_armor = {fmt(R.t_armor)}，W1_eff = {fmt(ctx.W1_eff)}（来源：{R.win_source}）\n")
    o1 = R.offline1
    if o1 is not None:
        w("离线 1（PLAN）：窗口跟随哪种时钟、是否「先砍中」（只作描述，不改上面的判定）。"
          "wall = 墙钟（上面用的），raw = 动作 _RawTotalElapsedSecond，chara = get_CharaElapsedSecond（含顿帧），"
          "anim = 动画层 Frame/60；接触时主角不在 (2,23) 的样本没有后三种读数。真怪核对按「首个接触前有没有同一只怪的 EMHIT」分组：\n")
        rows = []
        for k, g, win, n, ok in o1.rows:
            wtxt = (f"{fmt(win.W0)} ~ {'≥' if win.cens1 else ''}{fmt(win.W1)}" if win.ok else INSUFF) + f"（扫描 n={o1.scan_n[k]}）"
            rows.append((k, wtxt, "先砍中" if g else "未先砍中", pct(ok, n) if ok is not None else f"—（n={n}）"))
        w(md_table(["时钟", "扫描窗口", "真怪分组", "与窗口一致"], rows))
        w("\n- 残差 r 按分组：" + "；".join(
            f"{'先砍中' if g else '未先砍中'} n={len(v)}，中位数 {fmt(median(v))}，IQR {fmt(iqr(v))}"
            for g, v in o1.res_by.items()))
        w("- C9(a) 不一致数按分组：" + "；".join(f"{'先砍中' if g else '未先砍中'} {b}/{n}" for g, (b, n) in o1.c9a.items()))
        w("")


def render_c2_c3(R, w):
    ctx = R.cal
    rs = [s.r for s in R.res]
    w("## 3. C2 残差 r = c_first − R0/60 + δ\n")
    if not rs:
        w(f"- {INSUFF}：没有「有接触、触发时在蓄力中」的真放刀。")
    else:
        w(f"- n = {len(rs)}；中位数 {fmt(median(rs))}，IQR {fmt(iqr(rs))}，Q25 {fmt(quantile(rs, 0.25))}，"
          f"范围 {fmt(min(rs))} ~ {fmt(max(rs))} s")
        w(f"- Spearman ρ(r, R0) = {fmt(R.model.rho, 2)}；"
          + (f"|ρ|≥0.4，按 Theil–Sen 斜率 b = {fmt(R.model.b, 4)} s/帧 校正 r(L) = r + b·(L−R0)"
             if R.model.corrected else "|ρ|<0.4 或样本 <3，不校正"))
    if R.res_excluded:
        w("- 剔除：" + "，".join(f"{k} {v}" for k, v in R.res_excluded.items()))
    w("")
    w("## 4. C3 覆盖曲线与 L*\n")
    n_late = sum(1 for s in R.res if s.late)
    w(f"- N(L) = Σ 1[W0+0.02 ≤ R_i(L)/60 + r_i(L) − δ ≤ W1_eff−0.03]，区间 [{fmt(ctx.W0 + M_E)}, {fmt(ctx.W1_eff - M_L)}] s，"
      f"d̄ = {fmt(R.dbar, 2)}，δ = {fmt(ctx.delta, 4)}。R_i(L) = 档位 L 下触发时的读数：穿越 L 触发的样本是 L − d̄"
      f"（即 PLAN 的 (L−d̄)）；晚触发的样本（触发前一帧读数已 ≤ L）在 L ≥ R0 时就是它自己的 R0、r 不做斜率校正"
      f"（本轮 {n_late} 个）\n")
    if not R.res:
        w(f"- {INSUFF}，L* 沿用默认 {DEFAULTS['L']}。")
    else:
        mx = max(R.N.values()) or 1
        rows = [(Lv, R.N[Lv], "█" * int(round(20.0 * R.N[Lv] / mx)) + (" ← L*" if Lv == R.Lstar else ""))
                for Lv in L_GRID]
        w(md_table(["L", "N(L)", "覆盖"], rows))
        w(f"\n- L* = {fmt(R.Lstar)}（最大覆盖 {R.Nmax}/{len(R.res)}，平台中点、多平台取小）" if R.Lstar is not None
          else f"\n- 所有 L 的覆盖都是 0：L* 无定义（{INSUFF}或窗口与残差不相容），沿用 {DEFAULTS['L']}")
    # 每个轮换档的实测
    by_L = defaultdict(list)
    for f in R.fires:
        by_L[f.L].append(f)
    if by_L:
        w("\n每个轮换档的实测（真放刀，以 R0 为准的分析见上）：\n")
        rows = []
        for Lv in sorted(by_L, key=lambda x: (x is None, x)):
            fs = by_L[Lv]
            con = [f for f in fs if f.outcome in CONTACT_OUTCOMES]
            k = sum(1 for f in con if f.outcome == "CATCH")
            rows.append((fmt(Lv, 0) if isinstance(Lv, float) else fmt(Lv), len(fs), len(con), wilson_str(k, len(con)),
                         sum(1 for f in fs if f.outcome == "WHIFF"), len({f.ep.id if f.ep else id(f) for f in fs}),
                         len({(emid_of(f.keys), f.keep) for f in fs})))
        w(md_table(["L 档", "放刀", "有接触", "接住率", "空放", "回合数", "不同招式"], rows))
    cv = R.cv
    w("\n留一招式交叉验证（去掉一个 (EmID, KeepActionID) 组，用其余样本重算 L*，看被去掉的组预计落进 [W0, W1_eff] 的比例）：\n")
    if cv is None:
        w(f"- {INSUFF}（至少要 2 个招式组）")
    else:
        w(f"- P_CV = {fmt(cv.p, 2)}（n = {cv.n}，{cv.groups} 组）\n")
        w(md_table(["招式组 (EmID, keep)", "样本", "L*（去掉该组）", "落进窗口"],
                   [(f"em{g[0]} {act_str(g[1])}", n, fmt(Lg) if Lg is not None else f"无定义→{DEFAULTS['L']}", k)
                    for g, n, Lg, k in cv.detail]))
    w("")


def render_c4_c6(R, w):
    w("## 5. C4 L_min*、C5 W_long*、C6 估计量与 α\n")
    if R.lmin is None:
        w(f"- C4：{INSUFF}（需要 L* 有定义且残差 n≥4），L_min 沿用 {DEFAULTS['L_min']}。")
    else:
        w(f"- C4：⌈60·(W0+0.02+δ−Q25(r))⌉ = {R.lmin_raw}，夹到 [15, L*−6] → L_min* = {R.lmin}")
    w(f"- C5：he−hs∈(30,60] 组接住 {R.wlong_k}/{R.wlong_n} → W_long* = {R.wlong}"
      + ("" if R.wlong_n >= 4 else f"（n<4，{INSUFF}，不调）"))
    w(f"- C6：在「全程在蓄力中」的回合上比较（回合开始或接触前 1.5 s 起到首个接触一直在蓄力，接触是自然到达）；"
      f"触发量按 L = {R.L_use} 重放；留一招式中心化 IQR = 残差减去其他招式残差中位数后的 IQR：\n")
    base_n = next((r.n for r in (R.c6 or []) if r.name.startswith("V0")), 0)
    if base_n < 8:
        w(f"  {INSUFF}（V0 共同样本 {base_n} < 8），维持 V0、α=0。说明：第 1 轮按设计基本不可评估 —— B 段 rc 对每个合格的 "
          f"DANGER 回合都会放刀，剩下「全程在蓄力中、接触自然到达」的只有 rc 因否决、L_min 或过滤没放的回合，V0 在 L* 处"
          f"对这些回合同样不触发，共同样本几乎为 0（审查 measurement）。改用真放刀评估要改 PLAN 的 C6 口径，需用户决定。")
    if R.c6 and any(r.n > 0 for r in R.c6):
        w(md_table(["方案", "共同样本", "残差 IQR", "留一招式 IQR", "同样本 V0 留一 IQR", "小 20% 以上?"],
                   [(r.name, r.n, fmt(r.iqr), fmt(r.logo), fmt(r.base_logo),
                     "—" if r.name.startswith("V0") else
                     (INSUFF if r.n < 8 or r.logo is None or r.base_logo is None
                      else ("是" if r.logo <= (1 - IQR_GAIN) * r.base_logo else "否"))) for r in R.c6]))
        w(f"\n  结论：{c6_choice(R)}（样本 <8 的方案不参与比较）")
    w("")


OUTCOME_ORDER = ["CATCH", "RECOIL", "FAIL_EARLY", "FAIL_LATE", "FAIL_OTHER", "WHIFF"]
OUTCOME_SHOW = OUTCOME_ORDER + ["UNKNOWN"]


def rc_says_catch(outcome):
    """1.4：rc 的 RES 自评是不是「接住」：CATCH26 / CATCH27（以及旧写法里别的 CATCH*），但 CATCH25 不算（改判 RECOIL）。"""
    s = str(outcome or "").upper()
    return s.startswith("CATCH") and s != "CATCH25"


def render_outcomes(R, w):
    w("## 6. 结局分类（B，互斥、接住优先）与 C7 空放率\n")
    cnt = Counter(f.outcome for f in R.fires)
    sub = Counter((f.outcome, f.sub) for f in R.fires if f.sub)
    rows = []
    for o in OUTCOME_SHOW:
        if o == "UNKNOWN" and not cnt.get(o):
            continue
        extra = ""
        if o == "CATCH":
            tiers = Counter(f.tier for f in R.fires if f.outcome == "CATCH")
            clean = sum(1 for f in R.fires if f.outcome == "CATCH" and f.clean)
            extra = "档位 " + "，".join(f"(2,{t}) {n}" for t, n in sorted(tiers.items(), key=lambda x: (x[0] is None, x[0]))) \
                    + f"；CLEAN（HP 不掉）{clean}"
        else:
            extra = "，".join(f"{s} {n}" for (oo, s), n in sub.items() if oo == o)
        rows.append((o, cnt.get(o, 0), extra))
    w(md_table(["结局", "次数", "说明"], rows))
    w("\n口径（按优先级取第一个，时刻相对 t_req）：CATCH=进 (2,25..27)；RECOIL=进 *cRecoil 或抵消状态 RECOIL"
      "（这两项都只看 min(t_req+1.3 s, 这一刀离开 (2,23..29), 下一次放刀请求) 之前）；"
      "c_first = t_req 之后该攻击者的首个接触（不经 P23，窗口到 max(上面那个时刻, t_req+he/60+0.3 s)，在下一次放刀请求处截断）；"
      "FAIL_EARLY=c_first<W0；FAIL_LATE=c_first>W1，或离开 (2,23) 前（≤4 s）明确无 SUPER_ARMOR 的身体被打（标「收尾挨打」，优先），"
      "或接触窗口之后、离开 (2,23) 之前的该攻击者接触（「晚到接触」）；FAIL_OTHER=其他有接触未接住（含只有 PH）；"
      "WHIFF=到 t_req+he/60+0.3 s 都没有该攻击者接触也没有 PH"
      f"（INTERRUPTED=先砍中该怪且 hs 归零前怪物进入受击类动作；「{SUB_INT_FALLBACK}」不算 INTERRUPTED）。")
    # 1.4（V16 第 7 节第 3 条）：上一行（1.0 起的口径行）原样保留，紧跟着另起一行写修订；第 1 轮没有 (2,25)，数值不变
    n25 = sum(1 for f in R.fires if f.sub == SUB_RECOIL25)
    n25m = sum(1 for p in R.manual if getattr(p, "recoil25", False))
    w("\n1.4 修订：(2,25) cParrySlashHitS 改判 RECOIL（G1 实测：进 (2,25) 都是抵消状态 RECOIL、随即身体挨打），对所有版本生效；"
      "本行优先于上一行的 (2,25..27)。"
      f"本次数据里进 (2,25) 的放刀 {n25} 次、手动放刀 {n25m} 次（按 1.3 的口径都算 CATCH），现在记 RECOIL（说明栏「{SUB_RECOIL25}」）"
      + ("，其余数值和 1.3 相同" if not n25 and not n25m else ""))
    rc_cmp = [(f.rc_outcome, f.outcome) for f in R.fires if f.rc_outcome]
    if rc_cmp:
        # 1.4：rc 自评的 CATCH25（v1.5.x 把进 (2,25) 记成接住）按 RECOIL 比，即不算接住；v1.6 的 RES 只有 CATCH26/27 算接住
        agree = sum(1 for a, b in rc_cmp if rc_says_catch(a) == (b == "CATCH"))
        w(f"\n- rc 自评 RES 与离线 CATCH 判定一致 {pct(agree, len(rc_cmp))}（离线判定为准）")
        n_c25 = sum(1 for a, _b in rc_cmp if str(a).upper() == "CATCH25")
        if n_c25:
            w(f"- 1.4：rc 自评里的 CATCH25 {n_c25} 次按 RECOIL 比（不算接住）")
    n_known = len(R.fires) - cnt.get("UNKNOWN", 0)
    if cnt.get("UNKNOWN"):
        w(f"- UNKNOWN {cnt['UNKNOWN']} 次：放刀前后 ±6 s 没有任何探针记录，无法分类，不进任何比例的分母")
    w(f"- F_actual = {fmt(R.F_actual, 2)}（WHIFF {cnt.get('WHIFF', 0)}/{n_known}，INTERRUPTED 计入）；"
      f"不计 INTERRUPTED 版 {fmt(R.F_actual_noint, 2)}（INTERRUPTED {R.n_int}）")
    w(f"- F_shadow = {fmt(R.F_shadow, 2)}（在 L={R.L_use} 处会触发、没真放、[t_L, t_L+1.2] 全程在蓄力中的回合 n={R.F_shadow_n}；"
      f"条目序列来源 {R.ser_mode}）" + ("" if R.F_shadow_n else
                                  f"，{INSUFF}（第 1 轮按设计基本不可评估：rc 对合格回合都放了刀，F 实际取 F_actual）"))
    w(f"- **F = max(F_actual, F_shadow) = {fmt(R.F, 2)}**；不计 INTERRUPTED 版 {fmt(R.F_noint, 2)}\n")


def render_attrib(R, w):
    w("## 7. 空放与漏报归因\n")
    out, notes = R.ep_attr
    total = sum(out.values())
    w(f"DANGER 回合结局（9 类，n={total}）：\n")
    w(md_table(["类别", "回合数", "占比"], [(c, out.get(c, 0), pct(out.get(c, 0), total))
                                         for c in EP_CLASSES + ([EP_UNKNOWN] if out.get(EP_UNKNOWN) else [])]))
    if notes:
        w("\n- 激活未观测里：" + "，".join(f"{k} {v}" for k, v in notes.items()))
    w("\n口径（按顺序取第一个）：有刀上接触/接住/RECOIL → 刀上抵消；放刀后收尾挨打 → 收尾挨打；有接触 → 身体命中"
      "（放过刀的回合用这一刀自己的同攻击者接触，没放刀的回合用 P23 匹配进来的接触）；"
      "以下都是没有接触的：DANGER 条目全是弹体 → 弹体；怪物目标键不是 PLAYER/0 → 目标不是我；INTERRUPTED → 被打断；"
      "hs 归零前同一结果的 KeepActionID 变了 → AI 转招；hs0 前后有该怪 ATK+ → 激活但没打中；否则 → 激活未观测。")
    w("")
    ms = R.misses
    if ms is None:
        w(f"漏报归因：{INSUFF}（缺 ACT，无法判断挨打时是否在蓄力中）\n")
    else:
        # 1.3：「被抓取规则否决」只在有 1.5.1 起的 session（或这一类真的有数）时列出，1.5 及更早的报告表格不变
        show_grab = bool(ms.counts.get(MISS_GRAB, 0)) or getattr(R, "grab_rule", False)
        # 1.4：「被该接过滤排除」只在有 1.6 起的 session（或真的有数）时列出，更早版本的报告表格不变
        show_g1 = bool(ms.counts.get(MISS_G1, 0)) or getattr(R, "g1_rule", False)
        w(f"漏报（B 段里蓄力中被打、之前 1.5 s 内没有 rc 请求，n={ms.n}；B 段从第一个 DANGER 回合算起，机关扫描段不算）：\n")
        w(md_table(["类别", "次数", "占比"], [(c, ms.counts.get(c, 0), pct(ms.counts.get(c, 0), ms.n)) for c in MISS_CLASSES
                                           if (c != MISS_GRAB or show_grab) and (c != MISS_G1 or show_g1)
                                           and (c != MISS_G1_UNK or ms.counts.get(MISS_G1_UNK, 0))]))
        w("\n口径（按顺序取第一个）：攻击者全场没有任何预告、或预告从来没有条目（训练机关）→ 没收到消息（全场无预告）；"
          "接触没匹配到回合：±1.5 s 内有该怪 DANGER 回合 → 跨动作，只有非 DANGER 回合 → 只有 CAUTION，都没有 → 没收到消息；"
          "匹配到的回合不是 DANGER → 只有 CAUTION；DANGER 条目全是弹体或 EAR/WIND/QUAKE → 被弹体或效果攻击规则排除；"
          "否则看接触之前 Q 落进 [L_min, L]（L = 当时 rc 的轮换档）的时刻：其中主角在蓄力的时刻全在长窗口否决里"
          "（影子回放按 SER 重建的全局否决区间，跨怪）→ 被长窗口规则否决；有蓄力且没被否决的时刻 → 其他（规则本该触发）；"
          "这些时刻主角都不在蓄力 → 放刀区间内不在蓄力；没有这样的时刻：只有长窗口条目 → 被长窗口规则否决，"
          "首个 DANGER 读数 hs<L_min → 低于 L_min，否则 → 其他。")
        if show_grab:
            w("\n1.5.1 起（V15 第 9 节）另有抓取否决：DamageType ∈ CATCH/CATCH_ZAKO/CATCH_SLINGER（按探针 ENT 的名字认，读不到"
              "按不是抓取）的条目和弹体、效果攻击一样不进候选；这一招的 DANGER 条目全被排除且里面有抓取 → 被抓取规则否决；"
              "Q 落进区间、在蓄力的时刻全被否决，但有的时刻只有抓取在否决（影子回放的抓取区间：hs≤H_veto、he≥0，跨怪）"
              "→ 被抓取规则否决（全在长窗口否决里仍记长窗口）。")
        if show_g1:
            w("\n1.6 起（V16 第 3 节、第 7 节第 4 条）：触发量是 E5c 的 Q（真实剩余帧，L、L_min 都是 Q 单位，影子回放按探针的 EMINFO "
              "和 SER 复算）；「该接」过滤（_IsParryBreak 为真、GuardType 不在 {NORMAL, ALL_RANGE}、攻击参数读不准，按探针 ENT，"
              "读不到按读不准）排除的条目也不进候选；SKILL_GUARD 家族和抓取一样排除并否决（归「被抓取规则否决」）；这一招的 "
              "DANGER 条目全被排除、且有只因该接过滤排除的 → 被该接过滤排除（游戏判定接不住，不算规则漏了）。")
        if ms.counts.get(MISS_G1_UNK, 0):
            w(f"\n审查修订：探针 AP 模块停用之后（加载自检 2 读到空攻击参数就停用），条目的攻击参数探针读不到，不按「读不准」算："
              f"这一招的 DANGER 条目全被排除、且有只因属性不明排除的 → {MISS_G1_UNK}（{ms.counts[MISS_G1_UNK]} 次）。")
        w("")


def render_gates(R, w):
    w("## 8. C8 闸门评估\n")
    G = R.gates
    if G is None:
        w(f"- {INSUFF}\n")
        return
    w(f"- 评估集：真放刀 {G.n_real} + 影子回合 {G.n_shadow}（L={R.L_use} 处会触发、未真放、[t_L, t_L+1.2] 全程在蓄力中）")
    w(f"- 采用条件：有机制解释、去掉空放/失败 ≥{GATE_MIN_REMOVED}、损失潜在接住 ≤{GATE_MAX_LOST}；按净收益（去掉−3×损失）贪心，最多 {GATE_MAX_N} 个")
    n_rec = sum(1 for e in R.gate_events if e.kind == "real" and e.fire is not None and e.fire.outcome == "RECOIL")
    if n_rec:
        w(f"- 1.4：「空放/失败」另含 RECOIL（被弹并随即身体挨打，G1；(2,25) 改判之后才有），本次评估集里 {n_rec} 次")
    w(f"- **评估过的候选总数：{G.evaluated}**（第 1 步 6 个过滤型 + 第 2 步剩余的；g6 改触发量，按 C6 的 IQR 规则另评 1 个）\n")
    w(md_table(["步", "闸门", "条件", "去掉空放/失败", "损失潜在接住", "净收益", "无法判定", "达标"],
               [(r.step, r.gid, r.desc, r.removed, r.lost, r.net, f"{r.unknown}/{r.n}", "是" if r.ok else "否")
                for r in G.table]))
    w("\n机制解释：\n")
    for gid, desc, mech in GATES:
        w(f"- {gid} {desc}：{mech}")
    w(f"\n- 结论：采用 {('、'.join(g for g, _r in G.chosen)) if G.chosen else '无'}\n")


def render_verdict(R, w):
    w("## 9. C9 可行性判定（每项一个门槛）\n")
    w(md_table(["项", "指标", "数值", "门槛", "结果"],
               [(i.key, i.name, i.value, i.rule, (INSUFF if i.insufficient and not i.ok else ("通过" if i.ok else "不通过"))
                 + (f"（{i.note}）" if i.note else "")) for i in R.c9]))
    if R.d_mode == "release":
        scoped = getattr(R, "d_scope", None) is not None
        w("\n- 第 2 轮：C9 是第 1 轮的可行性判定，这里只拿本轮数据复核"
          + ("（数据范围同第 11 节 D：第一次参数改动之前、启用开关开着；(d) 只算放刀模块的 RED、D 范围内的 PERF）"
             if scoped else "") + "；**验收结论以第 11 节 D 为准**")
    if R.c9_pass:
        w("\n**C9 复核全部通过。**\n" if R.d_mode == "release" else "\n**全部通过：v1.5 默认开启。**\n")
    elif R.d_mode == "release":
        # 1.2：第 1 轮的「三选一」退路是定参时的决定，第 2 轮参数已冻结，这里不再给；D 不通过时的处理见第 11 节
        w("\n**C9 复核有未通过（或样本不足）的项**：只作参考，不走第 1 轮的三选一；验收看第 11 节 D。\n")
    else:
        w("\n**未全部通过：把上面的数字交给用户，三选一：**\n")
        kA, dA = R.fbA if R.fbA else (None, None)
        if kA is not None:
            w(f"- A 保守模式（只对单条目、he−hs≤30、DANGER 持续 ≥12 帧的条目放刀）：回放保留 {kA.n} 次，其中空放/失败 {kA.bad}"
              f"（空放 {kA.whiff}），潜在接住 {kA.potential}；去掉 {dA.n} 次（空放/失败 {dA.bad}，潜在接住 {dA.potential}，"
              f"缺条目序列无法判定 {dA.unknown}）")
        else:
            w(f"- A 保守模式：回放 {INSUFF}")
        w(f"- B 提示模式：同一规则，不放刀，只在屏幕上提示松手；提前量取 L+12 = {R.L_use + 12} 帧补人的反应时间")
        w("- C 留作默认关闭的实验开关\n")
    if R.err.red_rows:
        w("关键错误（进入红状态的 RED 记录，前 10 条）：\n")
        for r in R.err.red_rows[:10]:
            w(f"- [{SRC2TAG[r['_src']]}] t={fmt(r.get('t'), 3)} {r.get('mod')}：{r.get('why')}")
        w("")
    if R.err.core_rows:
        w(f"核心模块错误（ERR level=red）{R.err.core} 次：单条不算关键错误、不触发补测，进入红状态（10 s 内 ≥3 次等）"
          f"才算（见上）；附模块和时刻，前 10 条：\n")
        for r in R.err.core_rows[:10]:
            w(f"- [{SRC2TAG[r['_src']]}] t={fmt(r.get('t'), 3)} {r.get('mod')}：{r.get('msg')}")
        w("")
    if R.err.stat_gap:
        n_stat, n_rows = R.err.stat_gap
        w(f"- 注意：rc 的 STAT 计了 {n_stat} 条核心错误，ERR 记录只有 {n_rows} 条，有错误没记下来（旧版 rc 限频时直接丢弃）\n")


def render_diag(R, w):
    ana = [ss for ss in (R.sessions or []) if ss.analysis]
    datas = [ss.data for ss in ana] or [R.data]
    w("## 10. C10 是否补测\n")
    if R.c10:
        w("**需要补测**（只补真怪段约 10 分钟，不重做扫描；分析时用 --session 新 旧 合并、或 --calib-session 旧 取定标）。"
          "命中条件：" + "；".join(R.c10) + "\n")
    else:
        w(f"不需要补测（关键错误 0、有接触的放刀 {R.n_contact} ≥15、DANGER 回合 {R.n_danger} ≥30、数据完整）。\n")
    if R.d_mode == "release":
        w("- 第 2 轮：C10 是第 1 轮的补测条件，这里只作参考；验收的样本够不够看第 11 节 D 的样本量要求\n")
    # 1.4：有 1.6 起的发布版 session 时第 11 节换成 V16 第 9.2 节的 B 阶段验收；更早的版本照旧
    if getattr(R, "d16", None) is not None:
        render_d16(R, w)
    else:
        render_d_old(R, w)
    render_diag12(R, w, ana, datas)


def render_d_old(R, w):
    w("## 11. D 第 2 轮验收口径\n")
    if R.d_rotating:
        w("- 本轮 rc 在轮换 L（标定轮），下面的数字只作预览；第 2 轮参数冻结后按同一口径验收。")
    for d in R.d_sess:
        w(f"- {('[' + d.label + '] ') if len(R.d_sess) > 1 else ''}{d_scope_text(d)}")
    k, n = R.d_catch
    kw, nw = R.d_whiff
    w(f"- 有接触的放刀接住率：{wilson_str(k, n) if n else INSUFF}（验收线 ≥75%）")
    w(f"- 空放率：{pct(kw, nw)}（验收线 ≤25%）")
    kn, nn = R.d_whiff_noint
    w(f"- 空放率（不计先砍中打断）：{pct(kn, nn)}（INTERRUPTED {R.d_int} 次从分子分母都去掉，和 C7 的另一版同一算法）。"
      "先砍中打断 = 上捞斩自己先砍中怪物、把它打出硬直/倒地，攻击被打断、没打过来：没挨打、伤害照吃，不算坏结果"
      "（V15 第 1 节、NOTES「抵消上捞斩」；这里只去掉按预注册口径认定的 INTERRUPTED，即先砍中且 hs 归零前怪物进了受击类动作）。"
      "验收门槛仍按 PLAN 原口径（上一行，计入），这一版只作参考"
      + (f"；另有先砍中但缺受击动作证据的空放 {R.d_first_hit_other} 次，两版都按空放计" if R.d_first_hit_other else ""))
    if R.d_unknown:
        w(f"- 放刀前后没有探针数据（UNKNOWN）{R.d_unknown} 次：不进接住率、空放率的分母")
    for label, p in R.perf:
        pre = f"[{label}] " if len(R.perf) > 1 else ""
        if p is None:
            w(f"- {pre}帧率与开销：{INSUFF}（没有 PERF）")
            continue
        w(f"- {pre}mod 开销占帧时间（C9(d) 用）：中位数 {fmt(p.share * 100 if p.share is not None else None, 2, '%')}，"
          f"最大 {fmt(p.share_max * 100 if p.share_max is not None else None, 2, '%')}（PERF {p.n_share}/{p.n} 个周期有 Lua 耗时；"
          f"rc 的 STAT 带耗时 {p.n_rc} 个，缺 {p.n_rc_missing} 个）；全程 fps 中位数 {fmt(p.med, 1)}")
        dd = next((d for d in R.d_sess if d.label == label), None)
        if dd is not None and (dd.cut is not None or getattr(dd.cfg, "toggles", None) or dd.cfg.auto0 is False):
            # D 的帧率判定只用第一次参数改动之前、启用开关开着的 PERF 周期（关掉开关以后 rc 几乎不干活，全程中位数会偏低）
            pd = dd.perf
            w(f"- {pre}D 只用参数改动前、开关开着的 PERF（判定用）：" + (
                f"开销占比中位数 {fmt(pd.share * 100 if pd.share is not None else None, 2, '%')}，最大 "
                f"{fmt(pd.share_max * 100 if pd.share_max is not None else None, 2, '%')}（{pd.n_share}/{pd.n} 个周期）；"
                f"fps 中位数 {fmt(pd.med, 1)}" if pd is not None else
                f"{INSUFF}（{'这次加载整段不计' if getattr(dd, 'excluded', None) else '改动前没有 PERF'}）"))
        if p.segs:
            w(f"- {pre}fps 按场景分段（只作描述，不当门槛）：" + "；".join(
                f"段{k_}·{ph} n={n_} 中位数 {fmt(m_, 1)}" for k_, ph, n_, m_ in p.segs[:12]))
        if p.hooks:
            w(f"- {pre}各钩子每秒调用次数（中位数；钩子分发开销量不到，只看次数）：" +
              "，".join(f"{k_} {fmt(v, 1)}" for k_, v in sorted(p.hooks.items())))
        if p.actfail or p.readfail:
            w(f"- {pre}读主角/动作 ID 的调用抛错、在 1.5 s 容忍期内按「这一帧不存在」跳过：探针 {p.actfail} 帧，rc {p.readfail} 帧"
              "（零星出现可以忽略；很多的话说明切场景以外也在抛错，要看日志）")
    w("- 观感需用户确认")
    p_ = R.d_protocol
    if R.d_mode == "release" and p_ is not None:
        inf_txt = "；".join(f"{('[' + l_ + '] ') if len(p_.inf) > 1 else ''}{'读不到' if v_ is None else _onoff(v_)}"
                            for l_, v_ in p_.inf)
        new_txt = (f"；定标 session 里出现过 {'、'.join(f'em{e}' for e in p_.cal_ems)}，新怪 "
                   f"{'、'.join(f'em{e}' for e in p_.new) or '无'}") if p_.cal_ems else "；没有定标 session，新怪无法核对"
        w(f"- 协议核对（PLAN D：两只出招风格不同的怪、其中一只是新怪、至少一只关掉无限蓄力；1.2 起进判定，见下表）："
          f"D 范围内有 DANGER 回合的怪 {'、'.join(f'em{e}' for e in p_.ems) or '无'}（{len(p_.ems)} 只，其中 DANGER 回合 "
          f"≥{D_PROTO_MIN_DANGER} 的 {len(p_.counted)} 只）{new_txt}；AutoGuardGS 无限蓄力（探针 HDR 里"
          f"加载时的值，中途改动看不到）：{inf_txt}"
          + ("" if any(v_ is False for _l, v_ in p_.inf) else "——没有哪个 session 加载时是关的，请向用户确认"))
    reps = [(s.label, s.replica[0]) for s in R.d_stat if s.replica[0]]
    if reps:
        w("- **联机副本**：STAT replica 合计 " + "，".join(f"{('[' + l_ + '] ') if len(R.d_stat) > 1 else ''}{v_}"
                                                     for l_, v_ in reps)
          + "：这一轮有怪物是联机副本（本机不是它的主机），它的条目被闸门跳过、不放刀；联机没测过，上面的数字只代表单人部分")
    if R.d_off:
        w(f"- 启用开关关着（按 HDR + CFG）时蓄力中挨打、或这一招的预告在关着时就来了（v1.5 关着时不收消息、之后看不到它）"
          f"{R.d_off} 次：mod 没在工作，不算漏报")
    if R.d_per:
        w("\n按怪物统计（覆盖率 = 放刀 /（放刀 + 漏报））：\n")
        rows = []
        for em, c in sorted(R.d_per.items(), key=lambda kv: (kv[0] is None, kv[0] if kv[0] is not None else 0)):
            cov = c["放刀"] + c["漏报"]
            rows.append((f"em{em}" if em is not None else "未知", c["DANGER 回合"], c["放刀"], c["有接触"], c["接住"],
                         c["空放"], c["漏报"], pct(c["放刀"], cov)))
        w(md_table(["怪物", "DANGER 回合", "放刀", "有接触", "接住", "空放", "漏报", "覆盖率"], rows))
        w("\n- 漏报（B 段、D 范围内）含「没收到消息（攻击者全场无预告）」即预告缺失：完全没有预告的怪也列出（覆盖率 0%），"
          "怪物按接触记录自带的 em 归类，归不出来的记「未知」。各类见下表，口径同第 7 节")
        if R.d_miss_by:
            cols = [c for c in MISS_CLASSES if any(cnt.get(c) for cnt in R.d_miss_by.values())]
            rows = [(f"em{em}" if em is not None else "未知", sum(cnt.values()), *[cnt.get(c, 0) for c in cols])
                    for em, cnt in sorted(R.d_miss_by.items(),
                                          key=lambda kv: (kv[0] is None, kv[0] if kv[0] is not None else 0))]
            w("\n按怪物的漏报归因：\n")
            w(md_table(["怪物", "漏报", *cols], rows))
    if R.d_items:
        w("\nD 验收判定" + ("（标定轮：L 在轮换，只作预览）" if R.d_mode == "calibration" else "")
          + f"（样本量要求沿用 C9(b)(c)：有接触 n≥{D_N_CONTACT}、放刀 n≥{D_N_FIRE}；PLAN D 本身没写）：\n")
        w(md_table(["项", "数值", "门槛", "结果"], [(i.name, i.value, i.rule, d_item_result(i)) for i in R.d_items]))
        w(f"\n{d_conclusion(R)}")


def _dist(xs, nd=3):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return "—"
    return (f"n={len(xs)}，中位数 {fmt(median(xs), nd)}，Q10 {fmt(quantile(xs, 0.1), nd)}，Q90 {fmt(quantile(xs, 0.9), nd)}，"
            f"范围 {fmt(xs[0], nd)}~{fmt(xs[-1], nd)}")


def _em_sort(kv):
    return (kv[0] is None, kv[0] if kv[0] is not None else 0)


def render_d16(R, w):
    """1.4：第 11 节（v1.6 的 B 阶段验收，V16 第 9.2 节、第 7 节第 4 条）。"""
    D = R.d16
    w("## 11. D B 阶段验收（v1.6，V16 第 9.2 节；只对 1.6 起的发布版 session）\n")
    for d in D.ds:
        w(f"- {('[' + d.label + '] ') if len(R.d_sess) > 1 else ''}{d_scope_text(d)}")
    for d in D.others:
        w(f"- [{d.label}] 版本 {d.cfg.ver or '—'}：不是 1.6 起的发布版，不进 B 阶段验收")
    w("- 冻结值（V16 第 1 节）：提前量 28（Q 单位，真实剩余帧）、L_min 22、W_long 60、H_veto 90、rule=E5c、filter=g1；"
      "第一次提前量改动之后不计、加载时不是冻结值的整段不计（沿用 1.2 / 1.3）")
    w(f"- 新怪 = EmID 不在设计集 {{{', '.join(str(x) for x in DESIGN_EMIDS)}}}、也不是训练机关 em{DUMMY_EMID}"
      "（设计集是验收协议的一部分，不进规则）；判定按新怪合并，逐只怪只报告并给 90% Clopper–Pearson 区间")
    w("- 结局口径：CATCH26 / CATCH27 = 进 (2,26) / (2,27)；RECOIL = 进 (2,25) 或 *cRecoil 或抵消状态 RECOIL（算有接触、没接住）；"
      "纯空挥 = WHIFF 且放刀到 hs 归零之间没有同一只怪的 EMHIT；有 EMHIT 的 WHIFF 都是打断（INTERRUPTED、先砍中招式提前结束、"
      "先砍中缺受击动作证据三类分列），不计入空放、从纯空挥率的分子分母都去掉；SKIP = rc 记的「进了窗口却被该接过滤挡掉」"
      "（不算漏报、不算失败）；speedfail 按 rc 的 DBG speed_fail（调试日志开着才有）")
    cols = ["怪物", "新怪", "DANGER 回合", "放刀", "有接触", "CATCH26", "CATCH27", "RECOIL", "FAIL_EARLY", "FAIL_LATE",
            "FAIL_OTHER", "纯空挥", "打断：INTERRUPTED", "打断：先砍中招式提前结束", "打断：先砍中缺受击动作证据",
            "SKIP pb", "SKIP ug", "SKIP fc", "UVIEW", "speedfail", "漏报", "覆盖率", "接住率", "纯空挥率", "标记"]

    NOREC = "—（合并版不记）"
    nr = getattr(D, "merged_all", False)

    def row(name, isnew, c, flag):
        n_int = sum(c[k] for k in INT_KINDS)
        return (name, isnew, c["DANGER 回合"], c["放刀"], c["有接触"], c["CATCH26"], c["CATCH27"], c["RECOIL"],
                c["FAIL_EARLY"], c["FAIL_LATE"], c["FAIL_OTHER"], c["纯空挥"], *[c[k] for k in INT_KINDS],
                *((NOREC,) * 4 if nr else (c["SKIP pb"], c["SKIP ug"], c["SKIP fc"], c["UVIEW"])),
                c["speedfail"] if D.dbg_on else "—", c["漏报"],
                pct(c["放刀"], c["放刀"] + c["漏报"]), cp_str(c["CATCH26"] + c["CATCH27"], c["有接触"]),
                cp_str(c["纯空挥"], c["已分类"] - n_int), flag)
    rows = [row(f"em{e}" if e is not None else "未知", "是" if e in D.new else "否", c, D.flags.get(e, ""))
            for e, c in sorted(D.per.items(), key=_em_sort)]
    if D.new:
        rows.append(row("**新怪合并**", "—", D.tot, ""))
    w("\n按怪物统计（覆盖率 = 放刀 /（放刀 + 漏报））：\n")
    w(md_table(cols, rows))
    if D.miss_by:
        mcols = [c for c in MISS_CLASSES if any(cnt.get(c) for cnt in D.miss_by.values())]
        w("\n按怪物的漏报归因（口径同第 7 节；1.6 起另有「被该接过滤排除」）：\n")
        w(md_table(["怪物", "漏报", *mcols], [(f"em{e}" if e is not None else "未知", sum(cnt.values()),
                                             *[cnt.get(c, 0) for c in mcols])
                                            for e, cnt in sorted(D.miss_by.items(), key=_em_sort)]))
    n_g1, n_g1s = D.g1_miss
    if n_g1:
        w(f"\n- 「被该接过滤排除」{n_g1} 次（影子回放按探针 ENT 判断），其中这一招的结果在接触之前有 rc 的 SKIP 记录的 {n_g1s} 次"
          + ("" if n_g1s == n_g1 else "（没有 SKIP 的多半是 rc 进窗口那几帧没在蓄力，或 rc 和探针读到的属性不同，可对日志）"))
    w("\nD 验收判定（V16 第 9.2 节，新怪合并；数据质量问题判「需复核」，不判失败）：\n")
    w(md_table(["项", "数值", "门槛", "结果"], [(i.name, i.value, i.rule, d_item_result(i)) for i in D.items]))
    w(f"\n{d16_conclusion(R)}")
    w("\n只报告（V16 第 7 节第 4 条，不进判定）：\n")
    t = D.tot
    w(f"- 放早率（新怪合并，FAIL_EARLY / 有接触）：{cp_str(t['FAIL_EARLY'], t['有接触'])}")
    st = D.stat
    w("- 速度读取（STAT 合计，清零过的按增量）：" + "，".join(
        f"{k} {fmt(st.get(k)) if st.get(k) is not None else '—'}" for k in ("speedfail", "speedhold", "clockskip", "sidmis"))
      + "；其他：" + "，".join(f"{k} {fmt(st.get(k)) if st.get(k) is not None else '—'}"
                              for k in ("recoils", "fclosed", "excl", "uview", "vetoq", "failopen", "replica", "readerr")))
    fa = D.fires_all
    w(f"- C1（首帧 C）：{_dist([f.C1 for f in fa])}；Cf（放刀帧 C，读不到的不计）：{_dist([f.Cf for f in fa])}；"
      f"Q0：{_dist([f.Q0 for f in fa], 2)}")
    if D.c_out:
        w(f"- C 超出已验证范围 {C_SEEN[0]}~{C_SEEN[1]} 的放刀（外推）{len(D.c_out)} 次：" + "；".join(
            f"#{f.id} em{emid_of(f.keys)} {act_str(f.keep)} C1={fmt(f.C1)} Cf={fmt(f.Cf)}" for f in D.c_out[:12]))
    else:
        w(f"- C 超出已验证范围 {C_SEEN[0]}~{C_SEEN[1]} 的放刀：0 次")
    if D.gt_out:
        gts = sorted({g for g, _k in D.gt_out})
        kinds = [k for k in D16_KINDS + ("UNKNOWN",) if any(D.gt_out.get((g, k)) for g in gts)]
        w("- 按触发条目 GuardType 分的结局（探针 ENT；该接过滤之后应当只有 NORMAL / ALL_RANGE）：\n")
        w(md_table(["GuardType", *kinds], [(g, *[D.gt_out.get((g, k), 0) for k in kinds]) for g in gts]))
        w("")
    w(f"- pb=0（或读不到 pb）的攻击出现 RECOIL（不应出现）：{len(D.pb0_recoil)} 次" + ("：" + "；".join(
        f"#{f.id} em{emid_of(f.keys)} {act_str(f.keep)} pb={'读不到' if a is None or a.get('pbreak') is None else int(bool(a.get('pbreak')))} "
        f"guard={guard_name(a.get('guard')) if a else '没有 ENT'}{'（探针 AP 停用，属性不明）' if unk else ''}"
        for f, a, unk in D.pb0_recoil[:12]) if D.pb0_recoil else ""))
    if D.skip_by:
        w("- SKIP 按（怪, 招, why）汇总（D 范围内；被该接过滤排除的攻击单列，不算漏报、不算失败）：\n")
        w(md_table(["怪物", "招", "why", "条数"], [(f"em{e}" if e is not None else "未知", act_str(k), why, n)
                                              for (e, k, why), n in sorted(D.skip_by.items(), key=lambda kv: (
                                                  kv[0][0] is None, kv[0][0] or 0, str(kv[0][1]), kv[0][2]))]))
        w("")
    else:
        w("- SKIP：" + ("—（合并版不记）" if nr else "0 条"))
    if D.uviews:
        w(f"- UVIEW（放刀第一帧视野里有不该接的非弹体条目）{len(D.uviews)} 行，逐条附这一刀的结局（下一轮据此评估要不要加否决）：")
        for _d, r, f in D.uviews[:20]:
            w(f"  - #{f.id} t={fmt(r.get('t'), 3)} why={r.get('why')} U：em{emid_of(ident_keys(r.get('em')))} "
              f"{act_str(r.get('keep'))} hs={fmt(r.get('hs'), 2)} he={fmt(r.get('he'), 2)} 同一结果={fmt(r.get('same'))}"
              f" → 这一刀 {d16_kind(f)}（触发 em{emid_of(f.keys)} {act_str(f.keep)}）")
    else:
        w("- UVIEW：" + ("—（合并版不记）" if nr else "0 行"))
    if nr:
        w("- vetoq（按 Q 否决会被挡掉的放刀）：—（合并版不记）")
    else:
        w(f"- vetoq（按 Q 否决会被挡掉的放刀）：FIRE vq=1 {D.vq} 次；STAT vetoq 合计 "
          f"{fmt(st.get('vetoq')) if st.get('vetoq') is not None else '—'}")
    if D.qe:
        big = sorted(D.qe, key=lambda x: -abs(x[0]))
        w(f"- 影子 E1 对 E5c（Qe1 − Q0）：{_dist([d for d, _f in D.qe], 2)}；|差| >0.5 帧的 "
          f"{sum(1 for d, _f in D.qe if abs(d) > 0.5)} 次（存活期间 m 变过，nchg>0 才会有差）" + (
              "：" + "；".join(f"#{f.id} {act_str(f.keep)} 差 {d:+.2f} nchg={f.nchg}" for d, f in big[:8]
                              if abs(d) > 0.5) if any(abs(d) > 0.5 for d, _f in D.qe) else ""))
    w(f"- 一致性核对（每个 v1.6 的 FIRE，{len(D.fires_all)} 行；|Q0 − (R0 − dX)/mf|、|Qe1 − (R0 − A0·(1 − 1/max(1, C1)))| ≤ 0.01"
      f"（另加记录格式的舍入）、L_min ≤ Q0 ≤ L）：" + ("全部一致" if not D.incons else
                                               f"**{len(D.incons)} 行不符（多半是实现错误）**：" + "；".join(
                                                   f"#{f.id} " + "、".join(b) for f, b in D.incons[:12])))
    inf_txt = "；".join(f"{('[' + l_ + '] ') if len(D.inf) > 1 else ''}{'读不到' if v_ is None else _onoff(v_)}"
                        for l_, v_ in D.inf)
    w(f"- PLAN D 的旧协议（1.6 只报告）：D 范围内 DANGER 回合 ≥{D_PROTO_MIN_DANGER} 的怪 "
      f"{'、'.join(f'em{e}' for e in D.ems_proto) or '无'}；AutoGuardGS 无限蓄力（探针 HDR 里加载时的值）：{inf_txt or '—'}；"
      "观感由用户确认")
    for label, p in R.perf:
        dd = next((d for d in D.ds if d.label == label), None)
        if dd is None:
            continue
        pre = f"[{label}] " if len(R.perf) > 1 else ""
        pd = dd.perf
        w(f"- {pre}mod 开销（D 范围内的 PERF，判定用）：" + (
            f"中位数 {fmt(pd.share * 100 if pd.share is not None else None, 2, '%')}，最大 "
            f"{fmt(pd.share_max * 100 if pd.share_max is not None else None, 2, '%')}（{pd.n_share}/{pd.n} 个周期）；"
            f"fps 中位数 {fmt(pd.med, 1)}" if pd is not None else INSUFF)
          + (f"；全程中位数 {fmt(p.share * 100 if p.share is not None else None, 2, '%')}" if p is not None else ""))


def render_diag12(R, w, ana, datas):
    w("\n## 12. 附：诊断\n")
    d_ph = []
    for f in R.fires:
        if f.outcome != "CATCH":
            continue
        ctx = f.ctx
        blade = [c for c in f.contacts if c.cls == "BLADE"]
        i = bisect.bisect_left(ctx.ph_ts, f.t_req)
        if blade and i < len(ctx.ph_ts) and ctx.ph_ts[i] <= f.t_req + CREDIT:
            d_ph.append(ctx.ph_ts[i] - blade[0].t)
    w(f"- PH − 首个刀上接触（裁决 W0 的两种解释）：n={len(d_ph)}，中位数 {fmt(median(d_ph), 4)} s"
      + (f"，范围 {fmt(min(d_ph), 4)}~{fmt(max(d_ph), 4)}" if d_ph else ""))
    delays = [p.get("delay") for ss in ana for p in ss.ctx.ph if p.get("delay") is not None]
    w(f"- PH 当帧怪物 DelayFrame：n={len(delays)}，中位数 {fmt(median(delays), 1)}")
    beta = []
    for ep in R.episodes:
        cts = ep_contacts(ep)
        b = [c.t for c in cts if c.cls == "BLADE"]
        bo = [c.t for c in cts if c.cls == "BODY"]
        if b and bo:
            beta.append(b[0] - bo[0])
    w(f"- β = 刀上接触 − 身体接触（同一回合，只作描述）：n={len(beta)}，中位数 {fmt(median(beta), 4)}")
    th = [pose_theta(p) for ss in ana for p in ss.ctx.pose.recs if str(p.get("when") or "").upper() == "CT"]
    th = [x for x in th if x is not None]
    w(f"- 接触时来向角 θ（核实正负号用）：n={len(th)}，|θ| 中位数 {fmt(median([abs(x) for x in th]), 1)}°，"
      f"θ>0 占 {pct(sum(1 for x in th if x > 0), len(th))}；POSE.theta 单位判为 {R.pose_unit}")
    fb = sum(1 for f in R.fires if str(f.src or "").upper() == "FB")
    w(f"- FB 兜底放刀：{fb} 次" + ("（v1.5 已删掉兜底，应为 0）" if R.d_mode == "release" else "（为 0 时终版删掉兜底）"))
    # PLAN「离线 5」终版简化项的核对（只描述，不参与 C9 判定）
    holds = [to_num(r.get("hold")) for d in datas for r in d.get("pr", "EP")
             if is_danger(r.get("first_type")) or types_have_danger(r.get("types"))]
    holds = [h for h in holds if h is not None]
    n_hi = sum(1 for h in holds if h >= 0.95)
    w(f"- holder 对照（P16）：DANGER 回合 n={len(holds)}，对象在 holder 列表里出现的时间比例中位数 {fmt(median(holds), 2)}，"
      f"≥95% 的 {pct(n_hi, len(holds))}" + ("（全部 ≥95%，终版可改读 holder）" if holds and n_hi == len(holds) else ""))
    n_atk = hit4 = hit5 = 0
    for ep in R.episodes:
        if not ep.danger or ep.t0 is None:
            continue
        rs = set()
        for e in ep.ents:
            a = entry_attrs(e, ep.t0 + 0.05)
            v = to_int(a.get("reqset")) if a else None
            if v is not None:
                rs.add(v)
        if not rs:
            continue
        ctx = ep.ctx
        for a in ctx.atk.window(ep.t0, (ep.t1 if ep.t1 is not None else ep.t0) + 0.5):
            if ctx.ident.same(ep.keys, ident_keys(a.get("em"))):
                n_atk += 1
                hit4 += to_int(a.get("a4")) in rs
                hit5 += to_int(a.get("a5")) in rs
    w(f"- ATK+ 的哪个 UInt32 等于条目的 RequestSetID：同一怪物、回合内的激活 n={n_atk}，"
      f"a4 相等 {pct(hit4, n_atk)}，a5 相等 {pct(hit5, n_atk)}")
    ent_aps = {to_addr(a.get("ap")) for e in R.entries.values() for a in e.attrs_list if a.get("ap")}
    emp = [a for d in datas for a in (to_addr(r.get("ap")) for r in d.get("pr", "EMPARRY")) if a]
    w(f"- EMPARRY 的参数对象是否就是条目的 AttackParam：{pct(sum(1 for a in emp if a in ent_aps), len(emp))}"
      + ("" if ent_aps else "（ENT 没有记到 AttackParam 地址）"))
    eminfo = [r for d in datas for r in d.get("pr", "EMINFO")]
    st2_failed = [str(r.get("failed") or "") for d in datas for r in d.get("pr", "SELFTEST") if r.get("stage") == 2]
    w(f"- get_IsMaster 是否可用（联机闸门）：EMINFO 读到 master 的 {pct(sum(1 for r in eminfo if r.get('master') is not None), len(eminfo))}"
      + (f"；自检2 失败项 {st2_failed[0] or '无'}" if st2_failed else "；没有自检2 记录"))
    snd_n = sum(1 for d in datas for r in d.get("pr", "MSG") if not _is_nil(r.get("snd_em")))
    msg_n = sum(1 for d in datas for r in d.get("pr", "MSG") if to_bool(r.get("tme")))
    w(f"- 发送者是不是怪物本体（P04）：打我的 MSG 里带发送者 EnemyCharacter 地址的 {pct(snd_n, msg_n)}"
      "（有的话 P23 直接按地址比对攻击者，不依赖两侧 SystemIndex 是同一套编号）")
    for d in datas:
        stat = d.get("rc", "STAT")
        if stat:
            s = stat[-1]
            # v1.5 的 STAT 多了 replica / readerr、可能没有 fb（删掉了 closest 兜底）：没有 fb 就不写「兜底」
            v15 = s.get("replica") is not None or s.get("readerr") is not None
            fb_txt = "" if (v15 and s.get("fb") is None) else f"兜底 {s.get('fb')} "
            w(f"- rc 最后一行 STAT：放刀 {s.get('fires')} 接住 {s.get('catches')} 否决 {s.get('vetoes')} "
              f"{fb_txt}fail-open {s.get('failopen')} 错误 {s.get('errors')}（核心 {s.get('red')} 可选 {s.get('yellow')}）"
              f" 读主角抛错跳过 {s.get('readfail')} 帧"
              + (f" 联机副本跳过 {s.get('replica')} 条目读取错误 {s.get('readerr')}" if v15 else ""))
            if s.get("recoils") is not None or s.get("speedfail") is not None:
                # 1.4：v1.6 的 STAT 新计数（V16 第 6.3 节）；catches 只数 (2,26)/(2,27)
                w("  - v1.6 的新计数（同一行 STAT）：" + "，".join(
                    f"{k} {s.get(k) if s.get(k) is not None else '—'}"
                    for k in ("recoils", "speedfail", "speedhold", "clockskip", "vetoq", "fclosed", "excl", "uview",
                              "sidmis")) + "（catches 只数 (2,26)/(2,27)，被弹另计 recoils）")
    # 1.4：v1.6 之前的 rc 自己的 STAT catches 把进 (2,25) 也算接住；离线 1.4 起按 RECOIL 算（只在真有 (2,25) 时写）
    n25 = sum(1 for f in R.fires if f.sub == SUB_RECOIL25 and not getattr(f, "e5c", False))
    if n25:
        w(f"- 注（1.4）：v1.6 之前的 rc 的 STAT catches、RES 的 CATCH25 都把进 (2,25) 算成接住；离线 1.4 起按 RECOIL 算"
          f"（本次 {n25} 刀），所以上面 STAT 的接住数比第 6 节的 CATCH 多")
    # 1.3：VETO 的 why（v1.5.1 起）。只在有 1.5.1 起的 session、或 VETO 真的带 why 时写，1.5 及更早的报告不变
    vw = getattr(R, "veto_why", None) or Counter()
    if getattr(R, "grab_rule", False) or any(k != "—" for k in vw):
        n_v = sum(vw.values())
        # 1.3 修订（第 1 轮审查）：对照的是影子回放按 rc 的口径数出的否决段（shadow_veto_segments），不是漏报数
        sh, sh_rc = getattr(R, "veto_shadow", None), getattr(R, "veto_shadow_rc", None) or Counter()
        # 1.4：v1.6 的 why 多一个 sg（SKILL_GUARD 家族）；两边都没有 sg 时文字和 1.3 一样
        has_sg = bool(vw.get("sg") or (sh or Counter()).get("sg") or sh_rc.get("sg"))
        sg_txt = (lambda c: f"、SKILL_GUARD {c.get('sg', 0)}") if has_sg else (lambda c: "")
        cmp_txt = ""
        if sh is not None:
            same = all(sh.get(k, 0) == sh_rc.get(k, 0) for k in ("long", "grab", "sg")) and not sh_rc.get("—")
            cmp_txt = (f"；影子回放按同一口径（主角在蓄力中、启用开关开着，连续否决的帧合成一段，段首取 hs 最小的触发条目定原因，"
                       f"hs 一样记长窗口）数 1.5.1 起的 session：{sum(sh.values())} 段，长窗口 {sh.get('long', 0)}、"
                       f"抓取 {sh.get('grab', 0)}{sg_txt(sh)}，" + (
                           "和这些 session 的 VETO 一致" if same else
                           f"和这些 session 的 VETO（长窗口 {sh_rc.get('long', 0)}、抓取 {sh_rc.get('grab', 0)}"
                           f"{sg_txt(sh_rc)}）对不上：看日志里那几行 VETO 前后的条目（影子回放按探针的 SER，rc 按自己读到的条目）"))
        w(f"- rc 的 VETO（每个否决 streak 一行，v1.5.1 起带 why，取触发 hs 最小的那条）：{n_v} 行，长窗口 {vw.get('long', 0)}、"
          f"抓取 {vw.get('grab', 0)}{sg_txt(vw)}" + (f"、没有 why {vw['—']}" if vw.get("—") else "") + cmp_txt
          + "（漏报归因的「被抓取规则否决」按漏报计，口径不同，不和这里比）")
    # v1.5 的两个新计数（V15 第 3、4 节）：STAT 是从加载或「清零统计」起的累计数，清零过的按增量累加（stat_total）
    for st in R.d_stat:
        pre = f"[{st.label}] " if len(R.d_stat) > 1 else ""
        rep, n_rep = st.replica
        if n_rep:
            fo, _n = st.failopen
            w(f"- {pre}联机副本闸门（v1.5：发送者怪物 _Context.get_IsMaster()=false 时，这个结果的条目不进候选）：STAT replica "
              f"合计 {rep}（登记时判为联机副本的预告结果数；{n_rep} 行 STAT）" + (
                  "，单人时就该是 0" if rep == 0 else "，**不为 0：这一轮遇到了联机副本怪物，联机没测过**")
              + f"；fail-open 合计 {fmt(fo)}（读不到 ShellIndex / DamageType / IsMaster 时按通过、按主机处理）")
        rde, n_rde = st.readerr
        if n_rde:
            first = st.items[0].get("msg") if st.items else None
            w(f"- {pre}条目逐条读取出错（v1.5 不再退回 closest：出错的结果本帧不参与、不放刀，第一次出错标黄）：STAT readerr "
              f"合计 {rde}（出过读取错误的预告结果数，每个结果计一次）；ERR mod=items {len(st.items)} 条（标黄时写）"
              + (f"，第一条：{str(first)[:80]}" if first else "")
              + ("" if (rde == 0) == (not st.items) else "——计数和 ERR 记录对不上，看日志"))
    # 日志里本 session 范围内的 REF 事件（不当崩溃）
    for ss in ana:
        ev = ss.data.info.get("log_events")
        pre = f"[{ss.label}] " if len(ana) > 1 else ""
        if ev is None or not ev.scoped:
            w(f"- {pre}日志事件：日志里没有这个 session 的 HDR（或没有日志），崩溃迹象、REF 截住的访问冲突无法按 session 统计")
            continue
        if ev.crash:
            w(f"- {pre}**崩溃迹象 {len(ev.crash)} 行**（本 session 日志范围内）：" +
              "；".join(f"第 {e.line} 行 {e.text[:80]}" for e in ev.crash[:3]))
        av = ev.caught_av
        w(f"- {pre}REF 截住的访问冲突（VMContext: Caught exception，转成了 Lua 错误，不算崩溃）：{len(av)} 次" +
          ("：" + "；".join(f"第 {e.line} 行 {e.method or '?'}" for e in av[:5]) if av else ""))
        w(f"- {pre}REF「release attempted to release an object that was not managed by our Lua state」：Reset 时 "
          f"{len(ev.release_reset)} 次，其他时候 {len(ev.release_other)} 次" +
          ("（两个脚本各自 add_ref/release 同一个对象时，第二个 release 会这样告警并多留一份游戏侧引用；每个被双方跟踪过的对象"
           "都出一次就说明 REF 按集合记账，泄漏可接受，写进 NOTES）" if ev.release_other else ""))
    w("")


def _mon_rows(R, only_alert=False):
    M = getattr(R, "mon16", None)
    if M is None:
        return []
    out = []
    for (em, keep), o in sorted(M.rows.items(), key=lambda kv: (kv[0][0] is None, kv[0][0] or 0, str(kv[0][1]))):
        if only_alert and not o.alert:
            continue
        out.append((f"em{em}" if em is not None else "未知", act_str(keep), o.n, o.catch, o.recoil, o.nocatch, o.early,
                    o.whiff, o.inter, "、".join(f"{x:.1f}" for x in sorted(o.a0)[:6]) or "—",
                    "、".join(f"{x:.3f}" for x in sorted(set(o.c1))[:6]) or "—",
                    "，".join(f"{k} {v}" for k, v in sorted(o.guard.items())) or "—",
                    "，".join(f"{k} {v}" for k, v in sorted(o.pb.items())) or "—", "、".join(o.alert) or ""))
    return out


MON_COLS = ["怪物", "招", "FIRE", "接住", "RECOIL", "NOCATCH", "放早", "纯空挥", "打断", "A0", "C1", "GuardType", "pbreak",
            "提醒"]


def render_monitor_alert(R, w):
    """1.4（V16 第 7 节第 6 条）：C 阶段监控的提醒放在报告开头：任何 RECOIL、或某一招放早 / NOCATCH ≥3。没有就不写。"""
    rows = _mon_rows(R, only_alert=True)
    if not rows:
        return
    w("## C 阶段监控提醒（V16 第 9.3 节，只报告、不改参数；全表见第 15 节）\n")
    w(f"- 1.6 起的 session 里有这些招要报告用户：任何 RECOIL、或同一招放早 ≥{MON_EARLY} 次、或 NOCATCH ≥{MON_NOCATCH} 次"
      "（附这一招的 A0、C1、GuardType、pbreak；「该接」定义要不要改、要不要加否决由用户定，改了是新迭代）\n")
    w(md_table(MON_COLS, rows))
    w("")


def render_mon16(R, w):
    M = getattr(R, "mon16", None)
    if M is None:
        return
    w("## 15. C 阶段监控（按怪、按招；1.6 起的 session 全程，不截断；只报告）\n")
    w("- 接住 / RECOIL 有探针时按离线分类，没有探针时按放刀模块自己的 RES（CATCH26/27、RECOIL）；NOCATCH 按 RES；放早、纯空挥、"
      "打断要探针（第 6 节的分类）；A0 / C1 是 FIRE 记的，GuardType / pbreak 是探针 ENT 里触发条目的属性\n")
    w(md_table(MON_COLS, _mon_rows(R)))
    w("")


def render_e5c(R, w):
    """1.4：第 13 节，E5c 影子回放（V16 第 7 节第 5 条）。"""
    E = getattr(R, "e5r", None)
    if E is None:
        return
    cal = E.cal
    w("## 13. E5c 影子回放（样本内对照，不进任何判定）\n")
    w(f"- 规则：v1.6 的 E5c@{LEAD_16}（Q = (hs − (X − X0_e)) / m，m = max(1, C)；{L_MIN_16} ≤ Q ≤ {LEAD_16} 且在蓄力中、没被否决就放刀；"
      f"长窗口和抓取否决按原始 hs，W_long {W_LONG_16}、H_veto {H_VETO_16}）。C1 = 同一只怪在消息后 {C1_WIN:.0f} s 内的第一条 "
      "EMINFO 的 CoreState，之后同一只怪的 EMINFO 按采样时刻分段常数更新；X 沿这个结果的 SER 采样累加；读不到 C1 的结果不触发")
    w(f"- c_first' = 实际首个接触 − (影子触发时刻 t_Q + δ)，δ = {fmt(cal.delta, 4)}；窗口 [W0, W1] = [{fmt(cal.W0)}, "
      f"{'≥ ' if cal.cens1 else ''}{fmt(cal.W1)}]（第 2 节）。**假设攻击时刻不因放刀早晚而变**（SPEED 3.3）；"
      "只回放这一刀自己的回合（别的结果的条目不参与取最小）")
    w("- 候选过滤：1.6 起的 session 用它自己的规则（加该接过滤和 SKILL_GUARD 否决）；更早的 session 用它自己版本的过滤（弹体、"
      "效果攻击，1.5.1 起再加抓取），另出「加该接过滤的假设」一列（= 完整的 v1.6 规则）")
    if any(s_.g1 for s_ in E.sess):
        w("- 1.6 起的 session（审查修订）：「实际 Q」是 FIRE 自己记的 Q0；影子在放刀那一刻算的 Q 和它的差另列一栏。**影子只对 nchg = 0 "
          "的放刀可信**：探针的 EMINFO 只在首次 DANGER、PT、接触时采样，看不到 C 在倒数中途的变化（nchg ≠ 0 时影子的 Q 就是 E1 值）")
    w("")
    rows = []
    for r in E.rows:
        f = r.f
        sh = r.sh
        hyp = "" if r.g1 else ((r.cls_sh_h or "—") + (f"（t_Q−t_req {r.sh_h.t_L - f.t_req:+.3f} s）"
                                                      if r.sh_h is not None else ""))
        qd = "—"
        if r.g1 and r.q_sh is not None:
            qd = f"{r.q_sh:.2f}" + (f"（{r.q_sh - f.Q0:+.2f}）" if f.Q0 is not None else "")
        rows.append((r.sess.split(" / ")[0].replace("APCal ", ""), f.id, f"em{r.em}", act_str(r.keep), fmt(f.t_req, 3),
                     fmt(f.R0, 2), fmt(r.c1), fmt(r.q_act, 2), qd,
                     f"{sh.t_L - f.t_req:+.3f}" if sh is not None else "—", fmt(sh.q, 2) if sh is not None else "—",
                     f"{r.cls_act}" + (f"（{fmt(f.c_first)}）" if f.c_first is not None else ""),
                     (r.cls_sh or "—") + (f"（{fmt(r.c_sh)}）" if r.c_sh is not None else ""), hyp or "—",
                     (f"{r.dframe:+d}" if r.dframe is not None else "—") if r.g1 else "—",
                     "；".join(x for x in (r.why, (r.gap[0] if r.gap else None)) if x)))
    if rows:
        w(md_table(["session", "#", "怪", "招", "t_req", "R0", "C1", "实际 Q", "影子 Q（与 Q0 差，1.6）", "t_Q − t_req（s）",
                    "影子读数 Q", "实际 c_first", "影子 c_first'", "加该接过滤的假设", "帧差（1.6）", "说明"], rows))
    else:
        w("- 没有真放刀")
    # 按段、按怪汇总
    def tally(rs, key):
        c = Counter(getattr(r, key) for r in rs)
        return "，".join(f"{k} {c[k]}" for k in ("窗口内", "早", "晚", "无接触", "不触发", "无条目", "无探针数据")
                        if c.get(k))
    w("\n按段汇总（实际 = 真放刀的 c_first；影子 = E5c@28 回放后的 c_first'）：\n")
    srows = []
    for s in E.sess:
        rs = [r for r in E.rows if r.sess == s.label]
        srows.append((s.label, s.ver or "—", s.n_fire, tally(rs, "cls_act") or "—", tally(rs, "cls_sh") or "—",
                      (tally(rs, "cls_sh_h") or "—") if not s.g1 else "（同左）",
                      f"{s.shadow_only}（其中有该攻击者接触 {s.shadow_only_contact}）",
                      s.shadow_only_h if not s.g1 else "（同左）", f"{s.nofire_c1}/{s.n_ep}"))
    w(md_table(["session", "版本", "真放刀", "实际", "影子 E5c@28", "影子 + 该接过滤（假设）", "影子触发、真没放的回合",
                "同（加该接过滤）", "没放刀的 DANGER 回合里读不到 C1"], srows))
    by_em = defaultdict(list)
    for r in E.rows:
        by_em[r.em].append(r)
    w("\n按怪汇总（所有 session 合并）：\n")
    w(md_table(["怪", "真放刀", "实际", "影子 E5c@28", "影子 + 该接过滤（假设，1.6 起的 session 同左）"],
               [(f"em{e}" if e is not None else "未知", len(rs), tally(rs, "cls_act") or "—", tally(rs, "cls_sh") or "—",
                 tally([r for r in rs if not r.g1], "cls_sh_h") or "—")
                for e, rs in sorted(by_em.items(), key=_em_sort)]))
    a16 = [r for r in E.rows if r.g1]
    g16 = [r for r in a16 if r.dframe is not None]
    if a16:
        bad = [r for r in g16 if abs(r.dframe) > 1 and not (r.f.nchg or 0)]
        chg = [r for r in g16 if (r.f.nchg or 0)]
        gaps = [r for r in a16 if r.dframe is None]
        unexpl = [r for r in gaps if not (r.gap and r.gap[1])]
        qbad = [r for r in g16 if not (r.f.nchg or 0) and r.q_sh is not None and r.f.Q0 is not None
                and abs(r.q_sh - r.f.Q0) > Q_SHADOW_TOL]
        w(f"\n- 1.6 起的 session：影子触发时刻和真 FIRE 对照（按这个结果的 SER 帧序号、这一刀 FIRE 自己的 L）：{len(g16)} 刀，"
          f"nchg = 0 的放刀相差超过 1 帧的 "
          f"{len(bad)} 刀" + ("（应当为 0）：" + "；".join(f"#{r.f.id} 差 {r.dframe:+d} 帧" for r in bad[:10]) if bad else "（应当为 0）"))
        w(f"- 1.6 起的 session：真放刀 {len(a16)} 刀，影子也触发、参与上面对照的 {len(g16)} 刀；影子不触发 / 没有条目的 "
          f"{len(gaps)} 刀，其中原因不明 {len(unexpl)} 刀（应当为 0，多半是放刀模块偏离规则，逐条核对）" + (
              "：" + "；".join(f"#{r.f.id} {r.gap[0] if r.gap else '—'}{'' if (r.gap and r.gap[1]) else '（原因不明）'}"
                              for r in gaps[:12]) if gaps else ""))
        if chg:
            w(f"- nchg ≠ 0 的放刀 {len(chg)} 刀（影子看不到中途变速，帧差只报告、不算不一致）：" + "；".join(
                f"#{r.f.id} 差 {r.dframe:+d} 帧（nchg={r.f.nchg}）" for r in chg[:12]))
        w(f"- 影子在放刀那一刻算的 Q 和 FIRE 的 Q0（nchg = 0 的放刀）：差超过 {Q_SHADOW_TOL} 帧的 {len(qbad)} 刀"
          + ("（应当为 0）：" + "；".join(f"#{r.f.id} 影子 {r.q_sh:.2f} 对 Q0 {r.f.Q0:.2f}" for r in qbad[:10]) if qbad
             else "（应当为 0）"))
    w("")


def render_g1(R, w):
    """1.4：第 14 节，G1「该接」判定的只报告项（V16 第 9.1 节）。"""
    G = getattr(R, "g1r", None)
    if G is None:
        return
    w("## 14. G1「该接」判定：只报告项（V16 第 9.1 节；按探针 ENT / PH，不进判定）\n")
    w(f"- 每只怪 DANGER 条目（每个回合每条一次）的 GuardType / _IsParryBreak / DamageType 分布；攻击参数为空 = 探针 ENT 的 guard、"
      f"dmgtype、pbreak 全空（v1.6 按读不准不放刀）。新怪 = 不在设计集 {{{', '.join(str(x) for x in DESIGN_EMIDS)}}}、"
      f"不是 em{DUMMY_EMID}\n")
    rows = []
    for em, o in sorted(G.per.items(), key=_em_sort):
        rows.append((f"em{em}" if em is not None else "未知", "是" if (em is not None and em not in DESIGN_EMIDS
                                                                    and em != DUMMY_EMID) else "否", o.n,
                     "，".join(f"{k} {v}" for k, v in sorted(o.guard.items())) or "—",
                     "，".join(f"pb={k} {v}" for k, v in sorted(o.pb.items())) or "—",
                     "，".join(f"{k} {v}" for k, v in o.dt.most_common(6)) + ("…" if len(o.dt) > 6 else "") or "—",
                     pct(o.ap_nil, o.n)))
    for lab, t_off, n_unk in getattr(G, "ap_off", []):
        w(f"- **{('[' + lab + '] ') if lab else ''}探针 AP 模块在 t={fmt(t_off, 3)} 停用**（加载自检 2 读到空攻击参数就停用，探针原有行为）："
          f"之后的 ENT 没有 guard / pbreak / dmgtype，那 {n_unk} 条 DANGER 条目不进下表；这个 session 的 G1 相关输出（第 11 节按 "
          "GuardType 分的结局和 pb=0 的 RECOIL、第 13 节的该接过滤、漏报归因）在停用之后不可用，不按「读不准」处理\n")
    if rows:
        w(md_table(["怪物", "新怪", "DANGER 条目", "GuardType", "_IsParryBreak", "DamageType（前 6）", "攻击参数为空"], rows))
    else:
        w("- 没有带 ENT 的 DANGER 条目")
    w(f"\n- SKILL_GUARD 家族只出现在抓取（CATCH 三名）上（V16 第 3.4 节的等价性）：" + (
        "是" if not G.sg_bad else f"**否，{len(G.sg_bad)} 条反例**（报告用户）：" + "；".join(
            f"em{e} {act_str(k)} {g} 伤害类型 {dt}" for _s, e, k, g, dt in G.sg_bad[:10])))
    ph = G.ph
    if ph:
        tab = Counter((p.state, p.pb, p.src) for p in ph)
        w("- PH（抵消检查）状态 × 当时这只怪正在打的条目的 pbreak（条目 = 同一只怪、真实剩余 ≤10 帧、真实结束 ≥−10 帧的条目，"
          "不论 DANGER / CAUTION；按 E5c 的 Q，读不到 C1 时按原始 hs）：\n")
        w(md_table(["PH 状态", "条目 pbreak", "来源", "次数"], [(s, b, src, n) for (s, b, src), n in sorted(tab.items())]))
        bad = [p for p in ph if p.bad]
        w(f"\n- 反例（pb=0 却 RECOIL、pb=1 却 WAIT/HIT/SUCCESS）：" + ("0 次" if not bad else f"**{len(bad)} 次**（报告用户）："
                                                               + "；".join(f"t={p.t:.3f} {p.state} {p.pb}（{p.src}）"
                                                                          for p in bad[:10])))
    else:
        w("- PH（抵消检查）：没有记录")
    w("")


# ---------------------------------------------------------------- 自测：合成数据
ACT_NAMES = {(1, 0): "app.PlayerCommonAction.cIdle", (2, 21): "app.Wp00Action.cIdleToParryCharge",
             (2, 22): "app.Wp00Action.cParryCharge", (2, 23): "app.Wp00Action.cParrySlash",
             (2, 25): "app.Wp00Action.cParryHitS", (2, 26): "app.Wp00Action.cParryHitM",
             (2, 27): "app.Wp00Action.cParryHitL", (2, 28): "app.Wp00Action.cRecoil"}
TRUE_W0, TRUE_W1, TRUE_ARMOR, TRUE_DELTA = 0.330, 0.760, 0.900, 0.012


class Synth:
    """按探针/rc 的记录约定生成一整轮数据：A1 空挥、A2 机关扫描、B 真怪（含各种特殊结局），并记下真值。"""

    def __init__(self, seed=20261010):
        self.rng = random.Random(seed)
        self.recs = {"pr": [], "rc": []}
        self.cur, self.cur_name, self.act_start = (1, 0), ACT_NAMES[(1, 0)], 0.0
        self.n_addr = 0
        self.ids = Counter()
        self.expected = {}          # FIRE id -> (outcome, sub)
        self.planted = Counter()
        self.ct_em = False          # True：每条 CT 都带攻击者的 em（真探针就是这样；1.0 的自测数据不带）

    # -- 基础
    def addr(self):
        self.n_addr += 1
        return format(0x2A0000000000 + self.n_addr * 0x40, "X")

    def nid(self, k):
        self.ids[k] += 1
        return self.ids[k]

    def E(self, _src, _kind, /, **kw):
        self.recs[_src].append((_kind, kw))

    def act(self, t, to, raw_new=0.004):
        name = ACT_NAMES.get(to, "app.Wp00Action.cUnknown")
        self.E("pr", "ACT", t=t, f=int(t * 60), **{"from": self.cur}, to=to, from_name=self.cur_name, to_name=name,
               raw_prev=round(t - self.act_start, 4), raw_new=raw_new, chara_new=raw_new)
        self.cur, self.cur_name, self.act_start = to, name, t - raw_new

    def contact(self, t, mon, cls, sa, dmg=0.0, em=None):
        """em：探针实现的 CT 另带攻击者的 em<EmID>#<idx>（真数据都有）；默认不写，靠别名学习认攻击者。"""
        layer = "ATTACK_PARRY_GET" if cls == "BLADE" else "ATTACK_GET"
        em = em or (mon["em"] if self.ct_em else None)
        extra = {"em": em} if em else {}
        self.E("pr", "CT", t=t, f=int(t * 60), k=1, atk=mon["go"], atk_em=mon["ec"],
               dmgobj="it0000_0002_0" if cls == "BLADE" else "MasterPlayer", layer=layer, cls=cls, ps="WAIT",
               res="SUCCESS", act=self.cur, raw=round(t - self.act_start, 4), sa=sa, shell=False,
               px=1.0, py=0.0, pz=2.0, **extra)
        self.E("pr", "POSE", t=t, when="CT", px=0.0, pz=0.0, fx=0.0, fz=1.0, ex=0.3, ez=2.5, theta=0.12, dist=2.5,
               em=mon["em"])
        if dmg:
            self.E("pr", "DMG", t=t + 0.001, total=dmg, react="cDamageS")

    def p23_check(self, tc, t_hs0, t_he0):
        """埋点：这次接触落不落在它自己回合的 P23 窗口里（落在外面的计入「有预告攻击者的未匹配」）。"""
        if not (t_hs0 - MATCH_PRE <= tc <= t_he0 + MATCH_POST):
            self.planted["unmatched_known"] += 1

    # -- 预告回合：MSG、SER（每帧）、TYP、ENT、EP
    def episode(self, t_m, mon, keep, ents, charge_fn, rtype="DANGER", t_end=None, obj=None):
        """ents: [{ent, hs0, width, type, shell, dmgtype}]；hs 按名义 60/s 倒数。obj 给了就复用这个结果对象地址。"""
        obj = obj or self.addr()
        span = max(e["hs0"] + e["width"] for e in ents)
        t_end = t_end or t_m + (span + 31) / 60.0
        self.E("pr", "MSG", t=t_m, f=int(t_m * 60), obj=obj, new=True, tme=True, em=mon["em"], keep=keep,
               rt=rtype, n=len(ents), mstart=ents[0]["hs0"], mend=ents[0]["hs0"] + ents[0]["width"],
               closest=ents[0]["ent"], fin=False)
        for i, e in enumerate(ents):
            # 1.4：条目可带 guard（名字或数值）、pb（_IsParryBreak）、ap=False（攻击参数为空：guard / dmgtype 写 -，不写 pbreak），
            # 不带时和 1.3 一样（guard 0 = NORMAL、pbreak 0）
            ap_nil = e.get("ap") is False
            self.E("pr", "ENT", t=t_m, obj=obj, ent=e["ent"], idx=i, closest=(i == 0), shell=e.get("shell"),
                   reqset="7", guard="-" if ap_nil else e.get("guard", 0), dmgtype="-" if ap_nil else e.get("dmgtype", 0),
                   dmglv=2, filter="0", vguard=1.0, pbreak=None if ap_nil else e.get("pb", False), pfix=False,
                   pstock=False, tgbreak=False, block=False, name="AtkParam")
            self.E("pr", "TYP", t=t_m, f=int(t_m * 60), obj=obj, ent=e["ent"], type=e.get("type", rtype),
                   hs=e["hs0"], he=e["hs0"] + e["width"])
        k = 0
        while True:
            t = t_m + k / 60.0
            if t > t_end:
                break
            for e in ents:
                hs = e["hs0"] - k
                self.E("pr", "SER", t=t, f=int(t * 60), obj=obj, ent=e["ent"], type=e.get("type", rtype),
                       hs=round(hs, 3), he=round(hs + e["width"], 3), charge=charge_fn(t))
            k += 1
        self.E("pr", "EP", t=t_end, id=self.nid("ep"), obj=obj, epoch=0, em=mon["em"], keep=keep, reason="new",
               n_msg=1, first_type=rtype, first_hs=ents[0]["hs0"], types=rtype[0] + ">S", rate_med=60.0, rate_min=59.0,
               rate_max=61.0, stall=0, maxdt=0.017, charge_all=bool(charge_fn(t_end)) and bool(charge_fn(t_m)),
               atk_on=True, t0=t_m, t1=t_end)
        self.last_obj = obj
        return obj, t_end

    def core(self, t, mon, C, when="DANGER"):
        """1.4：一条带 comp 的 EMINFO（CoreState = C，其余分量 1），影子回放的 E5c 用它当首帧 C。"""
        self.E("pr", "EMINFO", t=t, em=mon["em"], when=when, tgt="PLAYER/0", speed_t=C, speed_f=C, ts=1.0, master=True,
               x=0.3, y=0.0, z=2.5, comp=f"1.000/1.000/{C:.3f}/1.000/1.000/1.000")

    def ent(self, hs0, width, **kw):
        d = {"ent": self.addr(), "hs0": hs0, "width": width}
        d.update(kw)
        return d

    # -- 一次真放刀
    def fired(self, t_m, mon, keep, L, mode, r_true=0.0, width=None, tgt="PLAYER/0", frm=(2, 21), core=None, hs0=None,
              v16=False, tier=None, ent_kw=None, extra_ents=(), uview=None, q_bad=0.0, L_rec=None, qe_bad=0.0):
        """mode: normal / whiff / interrupted / tail / recoil / early / multi / simul / catch / multi_early。
        返回下一段可用时刻。multi_early：两段攻击，前段条目 hs 比后段小 24（触发时 hs<L_min，不是候选），
        后段触发放刀，前段先打在身上 → FAIL_EARLY（以前 c_first 只认 P23 窗口内的接触，判成 FAIL_OTHER）。
        1.4：mode 另有 recoil25（刀上接触、抵消状态 RECOIL、进 (2,25)、随即身体挨打）。core：这只怪的 CoreState（消息后 4 ms 写一条
        带 comp 的 EMINFO）；hs0：触发条目的初值（默认 60 + 随机小数，和 1.3 一样抽随机数）；v16：按 v1.6 写记录 ——
        在 E5c 的 Q（C 不变时 = hs0/m − 帧数）第一次 ≤ L 的那一帧放刀，FIRE 带 C1/Cf/mf/nchg/dX/A0/Q0/Qp/Qe1/mode/vq，RES 写
        CATCH26 / CATCH27 / RECOIL / NOCATCH 和 to；tier：接住进 26 还是 27（不给就抽随机数）；ent_kw：触发条目的属性（guard、pb、
        dmgtype…）；extra_ents：同一个结果里的别的条目；uview：要写的 UVIEW 的 why / same；q_bad：故意把 Q0 写偏（一致性核对用）；
        L_rec：FIRE 里记的 L 和实际触发用的 L 不一样（模拟实现在窗口外放刀，一致性核对用）；qe_bad：故意把 Qe1 写偏。"""
        width = width if width is not None else self.rng.choice([8, 12, 20, 26, 40])
        hs0 = hs0 if hs0 is not None else 60 + round(self.rng.random(), 3)
        e = self.ent(hs0, width, **(ent_kw or {}))
        ents = [e] + list(extra_ents)
        if mode == "multi_early":
            ents = [self.ent(hs0 - 24, 6), e]
        m = max(1.0, core) if (v16 and core is not None) else 1.0
        k = int(math.ceil(hs0 / m - L - 1e-9)) if v16 else int(math.ceil(hs0 - L - 1e-9))
        t_req = t_m + k / 60.0
        R0 = round(hs0 - k, 3)
        d_i = TRUE_DELTA + self.rng.uniform(-0.002, 0.002)
        t_start = t_req + d_i
        t_act = t_req + 1 / 60.0
        self.act(t_m - 0.6, (2, 21))
        if frm == (2, 22):
            self.act(t_m - 0.3, (2, 22))
        obj, t_end = self.episode(t_m, mon, keep, ents, lambda t: t < t_act)
        if core is not None:
            self.core(t_m + 0.004, mon, core)
        fid = self.nid("fire")
        x16 = {}
        if v16:
            # E5c，C 不变：X = 帧数·(m−1)、X0 = 0，Q = (R0 − dX)/m = hs0/m − 帧数；上一帧的 Q 大 1（穿越触发）；影子 E1 和 Q0 相同
            dX = k * (m - 1.0)
            Q0 = (R0 - dX) / m
            x16 = dict(C1=core, Cf=core, mf=round(m, 3), nchg=0, dX=round(dX, 2), A0=hs0, Q0=round(Q0 + q_bad, 2),
                       Qp=round(Q0 + 1.0, 2), Qe1=round(R0 - hs0 * (1.0 - 1.0 / m) + qe_bad, 2), mode="E5c", vq=False)
        self.E("rc", "FIRE", t=t_req, id=fid, L=L if L_rec is None else L_rec, R0=R0, he0=R0 + width, src="V0",
               ent=e["ent"], res=obj, em=mon["em"], keep=keep, **{"from": frm}, **x16)
        if uview is not None:
            u = extra_ents[0] if extra_ents else e
            self.E("rc", "UVIEW", t=t_req, id=fid, hs=round(u["hs0"] - k, 2), he=round(u["hs0"] - k + u["width"], 2),
                   why=uview["why"], em=mon["em"], keep=keep, same=uview.get("same", True), res=obj, ent=u["ent"])
        self.E("rc", "FIRE_END", t=t_act, id=fid, R1=R0 - 1, n=1, entered=True)
        self.E("pr", "EMINFO", t=t_req, em=mon["em"], when="FIRE", tgt=tgt, speed_t=1.0, speed_f=1.0, ts=1.0,
               master=True, x=0.3, y=0.0, z=2.5)
        self.E("pr", "POSE", t=t_req, when="FIRE", px=0.0, pz=0.0, fx=0.0, fz=1.0, ex=0.3, ez=2.5, theta=0.12, dist=2.5,
               em=mon["em"])
        self.act(t_act, (2, 23), raw_new=round(t_act - t_start, 6))
        # 回合的 P23 窗口：起点 = 本回合在 t_req 时最早归零的 DANGER 条目，终点 = 触发条目 he 归零 + 0.3
        t_hs0_ep = t_req + min(en["hs0"] - k for en in ents) / 60.0
        t_he0_ep = t_req + (R0 + width) / 60.0
        self.E("pr", "PT", t=t_act, id=self.nid("pt"), t_obs=t_act, raw0=round(t_act - t_start, 6), t_start=t_start,
               **{"from": frm}, hold=1.0, lv="1", contacts_blade=0, contacts_body=0, ph="-", ps="-", hit_t=None,
               hit_idx=None, recoil=False, emhit=False, dmg=0.0, online_class="?")
        self.E("pr", "ARM", t=t_act, f=int(t_act * 60), act=SLASH, sa=True, ha=False, nd=False, raw=round(t_act - t_start, 4))
        t_att = t_req + R0 / 60.0 + r_true
        c = t_att - t_start
        outcome, sub = None, None
        requested = mode
        if mode == "normal":
            while abs(c - TRUE_W0) < 0.04 or abs(c - TRUE_W1) < 0.04:
                t_att += 0.05
                c = t_att - t_start
            mode = "catch" if TRUE_W0 <= c <= TRUE_W1 else ("early" if c < TRUE_W0 else "late")
        t_idle = t_start + 3.5
        fixed_c = {"catch": 0.55, "multi": 0.50, "simul": 0.52, "recoil": 0.48, "early": 0.20, "other": 0.50,
                   "recoil25": 0.47}
        if requested in fixed_c:
            t_att = t_start + fixed_c[mode] + self.rng.uniform(-0.01, 0.01)
            c = t_att - t_start
        if mode == "multi_early":
            t_att = t_hs0_ep + 0.005
            c = t_att - t_start
        if mode == "late":
            # 晚到的接触：明确没有霸体（c ≥ T_armor）的身体接触标「收尾挨打」（优先）；否则落在 c_first 窗口
            # （max(t_req+CREDIT, he 归零+0.3)）里是 c_first>W1，窗口之后、离开 (2,23) 之前是「晚到接触」
            cw_end = max(t_req + CREDIT, t_req + (R0 + width) / 60.0 + WHIFF_PAD)
            sub_late = "收尾挨打" if c >= TRUE_ARMOR else ("c_first>W1" if t_att <= cw_end else "晚到接触")
        placed = []
        if mode in ("catch", "multi", "simul", "recoil"):
            self.contact(t_att, mon, "BLADE", True)
            placed.append(t_att)
            if mode == "simul":
                self.contact(t_att, mon, "BODY", True, dmg=10.0)
                placed.append(t_att)
            if mode == "recoil":
                self.E("pr", "PS", t=t_att, state=4)
                self.act(t_att + 1 / 60.0, (2, 28))
                outcome = "RECOIL"
            else:
                self.E("pr", "PH", t=t_att + 0.0005, state="SUCCESS", target="Em", raw=round(c, 4), chara=round(c, 4), delay=4)
                # 1.4：(2,25) 是 RECOIL（G1），接住只进 (2,26)/(2,27)。照旧抽一次 randrange(3)，随机数序列和 1.3 一样
                tier = tier if tier is not None else (26, 26, 27)[self.rng.randrange(3)]
                self.act(t_att + 1 / 60.0, (2, tier))
                outcome = "CATCH"
            if mode == "multi":
                self.contact(t_att + 0.12, mon, "BODY", True)
                placed.append(t_att + 0.12)
            t_idle = t_att + 1.2
        elif mode == "recoil25":
            # 1.4（G1 实测的样子，2b 那 3 刀）：刀上接触同一帧 PH=RECOIL，下一帧进 (2,25) HitS，随即身体挨打（伤害 70~103）
            self.contact(t_att, mon, "BLADE", True)
            self.E("pr", "PH", t=t_att + 0.0005, state="RECOIL", target=mon["go"], raw=round(c, 4), chara=round(c, 4),
                   delay=0)
            self.act(t_att + 1 / 60.0, (2, 25))
            self.contact(t_att + 1 / 60.0 + 0.001, mon, "BODY", True, dmg=103.4)
            placed.append(t_att)
            outcome, sub, tier = "RECOIL", SUB_RECOIL25, 25
            t_idle = t_att + 1.4
        elif mode in ("early", "multi_early"):
            self.contact(t_att, mon, "BODY", True, dmg=20.0)
            placed.append(t_att)
            outcome = "FAIL_EARLY"
        elif mode == "other":
            # 时机在窗口里，但打在身上（几何没对上）：有接触没接住 → FAIL_OTHER
            self.contact(t_att, mon, "BODY", True, dmg=20.0)
            placed.append(t_att)
            outcome = "FAIL_OTHER"
        elif mode == "late":
            self.contact(t_att, mon, "BODY", c < TRUE_ARMOR, dmg=20.0)
            placed.append(t_att)
            outcome, sub = "FAIL_LATE", sub_late
        elif mode in ("whiff", "interrupted"):
            outcome = "WHIFF"
            if mode == "interrupted":
                self.E("pr", "EMHIT", t=t_start + 0.32, raw=0.32, chara=0.32, dmgobj="it0000_0002_0", layer="ATTACK_PUT",
                       em=mon["ec"])
                self.E("pr", "EMSTATE", t=t_start + 0.34, em=mon["ec"], act="app.Em0153Action.cDamageFlinch")
                sub = "INTERRUPTED"
        elif mode == "tail":
            self.contact(t_start + 2.0, MON2, "BODY", False, dmg=35.0)
            self.planted["unmatched_known"] += 1
            outcome, sub = "FAIL_LATE", "收尾挨打"
        for tc in placed:
            self.p23_check(tc, t_hs0_ep, t_he0_ep)
        if t_idle > t_start + 0.9 and self.cur == SLASH:
            self.E("pr", "ARM", t=t_start + TRUE_ARMOR, f=int((t_start + TRUE_ARMOR) * 60), act=SLASH, sa=False,
                   ha=False, nd=False, raw=TRUE_ARMOR)
        self.act(t_idle, (1, 0))
        self.expected[fid] = (outcome, sub)
        if v16:
            # v1.6 的 RES（V16 第 4 节）：接住分 26/27、(2,25) 记 RECOIL；to = 离开 (2,23) 后的第一个动作
            res_o = f"CATCH{tier}" if outcome == "CATCH" else ("RECOIL" if tier == 25 else "NOCATCH")
            res_to = (2, tier) if tier in (25, 26, 27) else (1, 0)
        else:
            # v1.5.x 的 rc 把进 (2,25) 也记成接住（CATCH25）
            res_o = f"CATCH{tier}" if (outcome == "CATCH" or tier == 25) else "NOCATCH"
            res_to = None
        self.E("rc", "RES", t=t_req + CREDIT, id=fid, outcome=res_o,
               dt=round(min(CREDIT, max(0.0, t_att - t_req)), 3) if tier is not None else CREDIT,
               **({"to": res_to} if v16 else {}))
        return max(t_idle, t_end) + 1.0

    # -- 没放刀的回合（蓄力中自然挨打或空过）
    def shadow(self, t_m, mon, keep, contact_r=None, ents=None, rtype="DANGER", hold=2.3, tgt=None, veto=False, core=None):
        """core（1.4）：给了就让这条 EMINFO 带 comp（CoreState = core），E5c 的影子回放能读到首帧 C。"""
        ents = ents or [self.ent(60 + round(self.rng.random(), 3), self.rng.choice([10, 16, 24]))]
        self.act(t_m - 0.6, (2, 21))
        t_rel = t_m + hold + max(0.0, (contact_r or 0.0))
        obj, t_end = self.episode(t_m, mon, keep, ents, lambda t: t < t_rel, rtype=rtype)
        self.E("pr", "EMINFO", t=t_m + 0.05, em=mon["em"], when="DANGER", tgt=tgt or "PLAYER/0", speed_t=1.0,
               speed_f=1.0, ts=1.0, master=True, x=0.3, y=0.0, z=2.5,
               **({"comp": f"1.000/1.000/{core:.3f}/1.000/1.000/1.000"} if core is not None else {}))
        if veto:
            self.E("rc", "VETO", t=t_m + 0.2, hs=ents[0]["hs0"] - 12, he=ents[0]["hs0"] - 12 + ents[0]["width"],
                   res=obj, ent=ents[0]["ent"], em=mon["em"])
        if contact_r is not None:
            t_att = t_m + min(e["hs0"] for e in ents) / 60.0 + contact_r
            self.contact(t_att, mon, "BODY", True, dmg=15.0)
        self.act(t_rel, (1, 0))
        return max(t_rel, t_end) + 1.0

    # -- 连续两刀：第一刀（MON1）空放，0.3 s 后玩家输入、0.4 s 重新按住，第二刀（MON2）请求后接住，
    #    第二刀的接住和 PH 都落在第一刀的 1.3 s / 空放判定期内：不能记到第一刀头上（审查 measurement）
    def back_to_back(self, t_m):
        L = 28
        self.act(t_m - 0.6, (2, 21))
        e1 = self.ent(60.4, 30)
        k1 = int(math.ceil(60.4 - L - 1e-9))
        t_req1 = t_m + k1 / 60.0
        R01 = round(60.4 - k1, 3)
        t_start1 = t_req1 + TRUE_DELTA
        t_act1 = t_req1 + 1 / 60.0
        obj1, t_end1 = self.episode(t_m, MON1, (0, 70), [e1], lambda t: t < t_act1)
        t_rehold = t_req1 + 0.40
        t_req2 = t_req1 + 0.50
        e2 = self.ent(60.2, 12)
        k2 = int(math.ceil(60.2 - L - 1e-9))
        t_m2 = t_req2 - k2 / 60.0
        R02 = round(60.2 - k2, 3)
        obj2, t_end2 = self.episode(t_m2, MON2, (0, 71), [e2], lambda t: t_rehold <= t < t_req2 + 1 / 60.0)
        fid1 = self.nid("fire")
        self.E("rc", "FIRE", t=t_req1, id=fid1, L=L, R0=R01, he0=R01 + 30, src="V0", ent=e1["ent"], res=obj1,
               em=MON1["em"], keep=(0, 70), **{"from": (2, 21)})
        self.E("rc", "FIRE_END", t=t_act1, id=fid1, R1=R01 - 1, n=1, entered=True)
        self.E("pr", "EMINFO", t=t_req1, em=MON1["em"], when="FIRE", tgt="PLAYER/0", speed_t=1.0, speed_f=1.0, ts=1.0,
               master=True, x=0.3, y=0.0, z=2.5)
        self.act(t_act1, (2, 23), raw_new=round(t_act1 - t_start1, 6))
        self.E("pr", "PT", t=t_act1, id=self.nid("pt"), t_obs=t_act1, raw0=round(t_act1 - t_start1, 6),
               t_start=t_start1, **{"from": (2, 21)}, hold=1.0, lv="1", dmg=0.0, online_class="?")
        self.E("pr", "ARM", t=t_act1, f=int(t_act1 * 60), act=SLASH, sa=True, ha=False, nd=False, raw=0.005)
        self.act(t_req1 + 0.30, (1, 0))
        self.act(t_rehold, (2, 21))
        fid2 = self.nid("fire")
        t_start2 = t_req2 + TRUE_DELTA
        t_act2 = t_req2 + 1 / 60.0
        self.E("rc", "FIRE", t=t_req2, id=fid2, L=L, R0=R02, he0=R02 + 12, src="V0", ent=e2["ent"], res=obj2,
               em=MON2["em"], keep=(0, 71), **{"from": (2, 21)})
        self.E("rc", "FIRE_END", t=t_act2, id=fid2, R1=R02 - 1, n=1, entered=True)
        self.E("pr", "EMINFO", t=t_req2, em=MON2["em"], when="FIRE", tgt="PLAYER/0", speed_t=1.0, speed_f=1.0, ts=1.0,
               master=True, x=0.3, y=0.0, z=2.5)
        self.act(t_act2, (2, 23), raw_new=round(t_act2 - t_start2, 6))
        self.E("pr", "PT", t=t_act2, id=self.nid("pt"), t_obs=t_act2, raw0=round(t_act2 - t_start2, 6),
               t_start=t_start2, **{"from": (2, 21)}, hold=0.1, lv="1", dmg=0.0, online_class="?")
        self.E("pr", "ARM", t=t_act2, f=int(t_act2 * 60), act=SLASH, sa=True, ha=False, nd=False, raw=0.005)
        t_att = t_start2 + 0.53
        self.contact(t_att, MON2, "BLADE", True)
        self.p23_check(t_att, t_req2 + R02 / 60.0, t_req2 + (R02 + 12) / 60.0)
        self.E("pr", "PH", t=t_att + 0.0005, state="SUCCESS", target="Em", raw=0.53, chara=0.53, delay=4)
        self.act(t_att + 1 / 60.0, (2, 26))
        self.act(t_att + 1.2, (1, 0))
        self.expected[fid1] = ("WHIFF", None)
        self.expected[fid2] = ("CATCH", None)
        self.planted["back_to_back"] = fid1
        return max(t_att + 1.2, t_end1, t_end2) + 1.0

    # -- 漏报：A 怪的长窗口否决期间 B 怪的短招打中（规则 A 的否决是全局的，VETO 的 em 是长窗口那只）
    def cross_veto(self, t_m):
        self.act(t_m - 0.6, (2, 21))
        long_e = self.ent(80.0, 180)
        self.episode(t_m, MON2, (0, 140), [long_e], lambda t: True)
        self.E("rc", "VETO", t=t_m, hs=80.0, he=260.0, res="-", ent=long_e["ent"], em=MON2["em"])
        t_a = t_m + 1.2
        short_e = self.ent(60.0, 10)
        self.episode(t_a, MON1, (0, 41), [short_e], lambda t: True)
        self.contact(t_a + 1.0 + 0.02, MON1, "BODY", True, dmg=15.0)
        self.act(t_m + 5.0, (1, 0))
        return t_m + 8.0

    # -- 1.3（v1.5.1 抓取否决）：蓄力中被抓（没放刀）。why：rc 写的 VETO 的 why（None = 不写 VETO，v1.5 不认抓取）
    def grab_hit(self, t_m, mon, keep, why="grab"):
        self.act(t_m - 0.6, (2, 21))
        g = self.ent(60.0, 10, dmgtype="CATCH")
        obj, _t_end = self.episode(t_m, mon, keep, [g], lambda t: True)
        if why is not None:
            self.E("rc", "VETO", t=t_m + 0.01, hs=60.0, he=70.0, res=obj, ent=g["ent"], em=mon["em"], why=why)
        self.contact(t_m + 1.0 + 0.02, mon, "BODY", True, dmg=259.0)
        self.act(t_m + 2.5, (1, 0))
        return t_m + 4.0

    # -- 1.3：B 怪（MON2）的抓取正在来（hs≤90、he≥0）时，A 怪（MON1）的普通攻击进 [L_min, L]、打中蓄力中的主角
    def grab_cross(self, t_m, why="grab"):
        self.act(t_m - 0.6, (2, 21))
        g = self.ent(80.0, 10, dmgtype="CATCH_ZAKO")
        obj, _t = self.episode(t_m, MON2, (0, 160), [g], lambda t: True)
        if why is not None:
            self.E("rc", "VETO", t=t_m + 0.01, hs=80.0, he=90.0, res=obj, ent=g["ent"], em=MON2["em"], why=why)
        n = self.ent(40.0, 8)
        self.episode(t_m + 0.2, MON1, (0, 161), [n], lambda t: True)
        self.contact(t_m + 0.2 + 40.0 / 60.0 + 0.02, MON1, "BODY", True, dmg=15.0)
        self.act(t_m + 3.0, (1, 0))
        return t_m + 4.5

    # -- 1.3 修订：蓄力中 MON2 的长窗口（hs0=70、he−hs=130）正在来、没有接触，rc 写一行 VETO（1.5.1 起 why=long）。
    #    以前只写这一行 VETO、SER 里没有对应的长窗口条目，影子回放数不出这一段，和 rc 的 VETO 对不上
    def long_hold(self, t_m, why="long"):
        self.act(t_m - 0.6, (2, 21))
        e = self.ent(70.0, 130)
        obj, _t = self.episode(t_m, MON2, (0, 162), [e], lambda t: True)
        self.E("rc", "VETO", t=t_m + 0.01, hs=70.0, he=200.0, res=obj, ent=e["ent"], em=MON2["em"],
               **({"why": why} if why is not None else {}))
        self.act(t_m + 2.5, (1, 0))
        return t_m + 4.5

    # -- 1.3 修订（第 1 轮审查）：影子回放抓取否决区间的三个边界，各配一次 MON1 普通攻击的漏报（Q 在 t_m+0.267~0.4 s
    #    进 [22, 30]，t_m+0.787 打中蓄力中的主角）。rc 在这几段里该写的 VETO 也照写（影子否决段和 rc 的 VETO 对照用）。
    #    返回 (下一段可用时刻, 接触时刻)
    def _edge_victim(self, t_m, keep):
        n = self.ent(40.0, 8)
        self.episode(t_m + 0.1, MON1, keep, [n], lambda t: True)
        tc = t_m + 0.1 + 40.0 / 60.0 + 0.02
        self.contact(tc, MON1, "BODY", True, dmg=15.0)
        self.act(t_m + 3.0, (1, 0))
        return t_m + 4.5, tc

    def grab_far(self, t_m, why="grab"):
        """MON2 的抓取 hs0=130：普通攻击进区间时抓取 hs≈106~114，在 1.5 s 视野外，不否决 → 漏报归「其他（规则未触发）」
        （抓取区间不受 H_veto 限制就会错归抓取）。抓取降到 hs=90（t_m+0.667）才否决，rc 那时写一行 VETO why=grab"""
        self.act(t_m - 0.6, (2, 21))
        g = self.ent(130.0, 10, dmgtype="CATCH")
        obj, _t = self.episode(t_m, MON2, (0, 163), [g], lambda t: True)
        if why is not None:
            self.E("rc", "VETO", t=t_m + 40.0 / 60.0, hs=90.0, he=100.0, res=obj, ent=g["ent"], em=MON2["em"], why=why)
        return self._edge_victim(t_m, (0, 164))

    def grab_past(self, t_m):
        """MON2 的抓取已经打完（hs0=−15、he0=−5），结果还没结束、条目还在 SER 里：不否决 → 漏报归「其他」
        （抓取区间不看 he≥0 就会错归抓取）。rc 不写 VETO"""
        self.act(t_m - 0.6, (2, 21))
        g = self.ent(-15.0, 10, dmgtype="CATCH")
        self.episode(t_m, MON2, (0, 165), [g], lambda t: True, t_end=t_m + 2.0)
        return self._edge_victim(t_m, (0, 166))

    def grab_long_overlap(self, t_m, why="long"):
        """MON2 同一个结果里一条长窗口（hs0=70、he−hs=130）、一条抓取（hs0 也是 70），普通攻击进区间时两种否决都在 →
        漏报归「被长窗口规则否决」（两种都有记长窗口；先判抓取就会错归）。rc 的 VETO：段首两条 hs 一样，同 hs 记 long"""
        self.act(t_m - 0.6, (2, 21))
        lg = self.ent(70.0, 130)
        g = self.ent(70.0, 10, dmgtype="CATCH")
        obj, _t = self.episode(t_m, MON2, (0, 167), [lg, g], lambda t: True)
        if why is not None:
            self.E("rc", "VETO", t=t_m + 0.01, hs=70.0, he=200.0, res=obj, ent=lg["ent"], em=MON2["em"], why=why)
        return self._edge_victim(t_m, (0, 168))

    def grab_rehold(self, t_m, why="grab"):
        """MON2 的抓取（hs0=60）否决到 t_m+70/60；主角 t_m+0.5 松开、t_m+0.9 重新按住：rc 的否决 streak 离开蓄力就断开，
        重新按住时抓取还在否决 → 两段、两行 VETO why=grab（影子否决段也要按蓄力断开）。没有接触、不算漏报"""
        self.act(t_m - 0.6, (2, 21))
        g = self.ent(60.0, 10, dmgtype="CATCH")
        obj, _t = self.episode(t_m, MON2, (0, 169), [g], lambda t: True)
        self.act(t_m + 0.5, (1, 0))
        self.act(t_m + 0.9, (2, 21))
        if why is not None:
            self.E("rc", "VETO", t=t_m + 0.01, hs=60.0, he=70.0, res=obj, ent=g["ent"], em=MON2["em"], why=why)
            self.E("rc", "VETO", t=t_m + 0.9, hs=6.0, he=16.0, res=obj, ent=g["ent"], em=MON2["em"], why=why)
        self.act(t_m + 3.0, (1, 0))
        return t_m + 4.5

    # -- 漏报：Q 落进 [L_min, L] 的时候还没按住蓄力，之后才按住被打（不是规则的问题）
    def late_hold(self, t_m):
        self.act(t_m - 0.6, (1, 0))
        e = self.ent(60.0, 12)
        t_hold = t_m + (60.0 - 14.0) / 60.0
        self.episode(t_m, MON1, (0, 42), [e], lambda t: t >= t_hold)
        self.act(t_hold, (2, 21))
        self.contact(t_m + 1.0 + 0.02, MON1, "BODY", True, dmg=15.0)
        self.act(t_m + 2.5, (1, 0))
        return t_m + 4.0


MON1 = {"em": "em20#3", "ec": "1D2E3F405060", "go": "Em0153_00_000@1D2E3F400000"}
MON2 = {"em": "em7#5", "ec": "1D2E3F40AAAA", "go": "Em0009_00_000@1D2E3F40A000"}
DUMMY = {"em": "em33#9", "ec": "7FF6DD000100", "go": "Em0165_00_000@7FF6DD000200"}


SCAN_XS = [0.24, 0.28, 0.32, 0.36, 0.40, 0.50, 0.60, 0.70, 0.80, 0.90, 1.00,
           0.30, 0.31, 0.33, 0.34, 0.35, 0.72, 0.74, 0.75, 0.77, 0.78, 0.33, 0.76]
KEEPS = [(0, 72), (0, 126), (0, 9), (0, 47), (0, 88), (0, 15)]
KEEP_OFFSET = {(0, 72): -0.04, (0, 126): -0.01, (0, 9): 0.02, (0, 47): 0.04, (0, 88): 0.07, (0, 15): 0.10}


def build_synth(S):
    sy = Synth()
    rng = sy.rng
    sy.E("pr", "HDR", t=99.0, ver="selftest", session=S, net="SOLO", guard_deg=70.0, aim_deg=70.0, overheat_parry=2.5,
         cfg_guard='{"enabled":false}', cfg_parry='{"auto_parry":true}',
         enums="RT{SAFE:0,CAUTION:1,DANGER:2};PS{NONE:0,WAIT:1,HIT:2,SUCCESS:3,RECOIL:4};"
               "LAYER{ATTACK_GET:16,ATTACK_PARRY_GET:18,ATTACK_PUT:?};DT{NONE:-1,NORMAL:0,EAR:2,WIND:4,QUAKE:1};"
               "GT{NORMAL:0,ALL_RANGE:1,UNABLE_GUARD:2};TAK{INVALID:-1,PLAYER:0,OTOMO:2}")
    sy.E("pr", "SELFTEST", t=99.1, stage=1, ok=12, total=12, failed=None)
    sy.E("rc", "HDR", t=99.0, ver="rc-selftest", session=S + 1, auto_parry=True, lead=28, rotation="1", scan=True,
         L_min=18, W_long=60, H_veto=90, credit=1.3)
    sy.E("pr", "ERR", t=99.5, mod="POSE", level="yellow", msg="selftest optional module error")
    # 零星的核心模块错误（没到红）：不算关键错误、不触发补测，单列报告
    sy.E("pr", "ERR", t=99.6, mod="CT", level="red", msg="selftest sporadic core error")
    t = 100.0
    # A1：空挥 3 次（T_armor 真值 0.90）。前两次进 (2,23) 第一帧霸体标志短暂为 0（2 帧后才置位）：
    # T_armor 要取离开 (2,23) 前最后一段持续 sa=0 的起点，不能取第一条 sa=0（否则中位数变成 0.004）
    for i_sw in range(3):
        sy.act(t, (2, 21))
        t_act = t + 1.0
        t_start = t_act - 0.004
        sy.act(t_act, SLASH, raw_new=0.004)
        sy.E("pr", "PT", t=t_act, id=sy.nid("pt"), t_obs=t_act, raw0=0.004, t_start=t_start, **{"from": (2, 21)},
             hold=1.0, lv="1", contacts_blade=0, contacts_body=0, dmg=0.0, online_class="SWING")
        if i_sw < 2:
            sy.E("pr", "ARM", t=t_act, f=int(t_act * 60), act=SLASH, sa=False, ha=False, nd=False, raw=0.004)
            sy.E("pr", "ARM", t=t_act + 2 / 60.0, f=int(t_act * 60) + 2, act=SLASH, sa=True, ha=False, nd=False,
                 raw=round(0.004 + 2 / 60.0, 4))
        else:
            sy.E("pr", "ARM", t=t_act, f=int(t_act * 60), act=SLASH, sa=True, ha=False, nd=False, raw=0.004)
        sy.E("pr", "ARM", t=t_start + TRUE_ARMOR, f=int((t_start + TRUE_ARMOR) * 60), act=SLASH, sa=False, ha=False,
             nd=False, raw=TRUE_ARMOR)
        sy.act(t_start + 3.6, (1, 0))
        t += 6.0
    # A2：机关学习 2 个周期（蓄力中被打，没有预告）
    for _ in range(2):
        sy.act(t, (2, 21))
        sy.contact(t + 1.13, DUMMY, "BODY", True, dmg=5.0)
        sy.planted["dummy_contacts"] += 1
        sy.E("rc", "SCAN", t=t + 1.2, id=sy.nid("scan"), phase="learn", X=None, t0=t, Dc=1.13, t_req=None,
             status="OK", reason=None)
        sy.act(t + 2.0, (1, 0))
        t += 4.6
    # A2：按 X 放刀的扫描样本（窗口真值 [0.330, 0.760]）
    xs = list(SCAN_XS)
    rng.shuffle(xs)
    for X in xs:
        c = X + rng.uniform(-0.006, 0.006)
        sy.act(t, (2, 21))
        t_req = t + 1.0
        t_start = t_req + TRUE_DELTA + rng.uniform(-0.002, 0.002)
        t_act = t_req + 1 / 60.0
        sy.act(t_act, SLASH, raw_new=round(t_act - t_start, 6))
        sy.E("pr", "PT", t=t_act, id=sy.nid("pt"), t_obs=t_act, raw0=round(t_act - t_start, 6), t_start=t_start,
             **{"from": (2, 21)}, hold=1.0, lv="1", dmg=0.0, online_class="SCAN")
        t_c = t_start + c
        if TRUE_W0 <= c <= TRUE_W1:
            sy.contact(t_c, DUMMY, "BLADE", True)
            sy.E("pr", "PH", t=t_c + 0.0005, state=3, target="Em0165", raw=round(c, 4), chara=round(c, 4), delay=0)
            sy.act(t_c + 1 / 60.0, (2, 27))
            t_idle = t_c + 1.0
        else:
            sy.contact(t_c, DUMMY, "BODY", c < TRUE_ARMOR, dmg=8.0)
            sy.E("pr", "ARM", t=t_start + TRUE_ARMOR, f=0, act=SLASH, sa=False, ha=False, nd=False, raw=TRUE_ARMOR)
            t_idle = t_start + 3.0
        sy.planted["dummy_contacts"] += 1
        sy.E("rc", "SCAN", t=t_c + 0.3, id=sy.nid("scan"), phase="fire", X=X, t0=t_req - 0.5, Dc=1.13, t_req=t_req,
             status="OK", reason=None)
        sy.act(t_idle, (1, 0))
        t = t_idle + 2.0
    for _ in range(2):      # 作废样本：1.6 s 内没有接触
        sy.act(t, (2, 21))
        t_req = t + 1.0
        sy.act(t_req + 1 / 60.0, SLASH, raw_new=0.0047)
        sy.E("rc", "SCAN", t=t_req + 1.7, id=sy.nid("scan"), phase="fire", X=0.5, t0=t_req - 0.5, Dc=1.13,
             t_req=t_req, status="VOID", reason="nohit")
        sy.act(t_req + 3.0, (1, 0))
        t += 5.0
    sy.E("rc", "SCAN", t=t, id=sy.nid("scan"), phase="done", X=None, t0=None, Dc=1.13, t_req=None, status="OK",
         reason=None)
    # B：真怪
    t = max(t + 5.0, 400.0)
    for i in range(3):
        t = sy.fired(t, MON2, (0, 30 + i), 32, "catch")
    Ls = []
    for _ in range(6):
        grp = [20, 24, 28, 32, 36]
        rng.shuffle(grp)
        Ls += grp
    for i, L in enumerate(Ls):
        keep = KEEPS[i % 6]
        t = sy.fired(t, MON1, keep, L, "normal", r_true=KEEP_OFFSET[keep] + rng.gauss(0, 0.025),
                     frm=(2, 22) if i % 7 == 3 else (2, 21))
    for i in range(4):
        t = sy.fired(t, MON1, KEEPS[i % 6], 28, "whiff", tgt="OTOMO/0")
    t = sy.fired(t, MON1, KEEPS[1], 28, "whiff")
    t = sy.fired(t, MON1, KEEPS[2], 28, "interrupted")
    t = sy.fired(t, MON1, KEEPS[3], 28, "tail")
    t = sy.fired(t, MON1, KEEPS[4], 28, "catch", tgt="OTOMO/0")
    t = sy.fired(t, MON1, KEEPS[0], 28, "recoil")
    t = sy.fired(t, MON1, KEEPS[5], 28, "recoil")
    t = sy.fired(t, MON1, KEEPS[1], 28, "early")
    t = sy.fired(t, MON1, KEEPS[2], 28, "multi")
    t = sy.fired(t, MON1, KEEPS[3], 28, "simul")
    t = sy.fired(t, MON1, KEEPS[4], 28, "other")
    for i in range(10):      # 蓄力中被自然打到（C6 用；也是「其他」类漏报）
        # 判定窗口宽度固定 16 帧：真值是「接触相对 hs 归零」（V0 正确），α>0 只是整体平移、IQR 不变，按规则必须维持 V0。
        # 宽度随机时 r − α·w/60 的宽度噪声可能碰巧和招式偏移抵消，11 个样本就足以让 α=0.5 偶然小 20%（以前靠 α=0.5
        # 在 L*=34 时样本不足 8 个才没被选中）
        keep = KEEPS[i % 6]
        t = sy.shadow(t, MON1, keep, contact_r=KEEP_OFFSET[keep] + rng.gauss(0, 0.02),
                      ents=[sy.ent(60 + round(rng.random(), 3), 16)])
    for i in range(4):       # 影子空放（F_shadow 用），第一个目标是随从
        t = sy.shadow(t, MON1, KEEPS[i % 6], tgt="OTOMO/0" if i == 0 else None)
    # 歧义：同一只怪两个预告重叠，接触落在两个窗口里
    sy.act(t - 0.6, (2, 21))
    ea, eb = sy.ent(60.2, 14), sy.ent(60.1, 14)
    sy.episode(t, MON1, (0, 60), [ea], lambda x: True)
    sy.episode(t + 0.15, MON1, (0, 61), [eb], lambda x: True)
    sy.contact(t + 60.2 / 60.0 + 0.10, MON1, "BODY", True, dmg=12.0)
    sy.planted["ambiguous"] += 1
    sy.act(t + 2.6, (1, 0))
    t += 4.0
    t = sy.shadow(t, MON1, (0, 50), contact_r=0.05, rtype="CAUTION", ents=[sy.ent(60.2, 12, type="CAUTION")])
    t = sy.shadow(t, MON1, (0, 51), contact_r=0.02, ents=[sy.ent(12.4, 10)])
    t = sy.shadow(t, MON1, (0, 52), contact_r=0.30, ents=[sy.ent(100.0, 80)], veto=True)
    t = sy.shadow(t, MON1, (0, 53), contact_r=0.05, ents=[sy.ent(60.3, 10, shell="2")])
    # 未匹配：蓄力中被打，前后 3 s 都没有这只怪的预告
    sy.act(t, (2, 21))
    sy.contact(t + 1.0, MON1, "BODY", True, dmg=10.0)
    sy.planted["unmatched_known"] += 1
    sy.act(t + 2.0, (1, 0))
    t += 3.0
    # 审查第 1 轮后补的情形
    t = sy.fired(t, MON1, KEEPS[1], 36, "early")        # L=36、早到 r≈−0.39（P23 窗口外）：仍是 FAIL_EARLY
    t = sy.fired(t, MON1, KEEPS[3], 36, "early")
    t = sy.fired(t, MON1, KEEPS[5], 28, "multi_early")  # 多段攻击前段先打中
    t = sy.back_to_back(t)                              # 连续两刀，后一刀的接住不能算到前一刀
    t = sy.cross_veto(t)                                # A 怪长窗口否决期间 B 怪短招打中 → 被长窗口规则否决
    t = sy.late_hold(t)                                 # Q 在 [L_min,L] 时没按住 → 放刀区间内不在蓄力
    # PERF 与 STAT。前 10 s（训练场）fps 150，之后约 80：旧口径「前 10 s 中位数 vs 全程中位数」会算出下降 47%、
    # C9(d) 判否；新口径按 mod 开销占帧时间估（探针 0.12 ms/帧 + 2 ms/s 钩子，rc 0.05 ms/帧 + 1 ms/s）
    tt = 100.0
    while tt < t:
        fps = 150.0 if tt < 110.0 else 80.0 + rng.uniform(-0.8, 0.8)
        sy.E("pr", "PERF", t=tt, fps=fps, maxdt=0.02, hooks="msg:80,ct:1", lua_ms_avg=0.12,
             lua_ms_max=0.6, tracked=2, red=0, yellow=1, hook_ms_ps=2.0)
        if int(tt) % 60 == 0:
            sy.E("rc", "STAT", t=tt, fires=sy.ids["fire"], catches=0, vetoes=1, fb=0, failopen=0, errors=0, red=0,
                 yellow=0, lua_ms_avg=0.05, lua_ms_max=0.3, hook_ms_ps=1.0, readfail=0)
        tt += 5.0
    sy.t_end = t
    return sy


MON3 = {"em": "em99#11", "ec": "1D2E3F40CCCC", "go": "Em0099_00_000@1D2E3F40C000"}   # 全场没有预告的怪（v1.5 自测）
MON4 = {"em": "em42#7", "ec": "1D2E3F40DDDD", "go": "Em0042_00_000@1D2E3F40D000"}    # 第 1 轮没出现过的新怪（v1.5 自测）
V15_PLAN = ["catch"] * 7 + ["whiff", "early"] + ["catch"] * 7 + ["interrupted", "other", "whiff", "interrupted", "whiff"]


def build_synth_v15(S, cfg=True, change_lead=True, lead0=26, start_off=False, mon4_shadows=9, ver="1.5", grab_eps=False,
                    grab_edges=False):
    """第 2 轮（v1.5 发布版）合成数据：HDR ver=1.5、rotation=0、scan=0、lead=26、L_min=22；没有 A1 空挥和 A2 扫描。
    1.3：ver = HDR 的版本号（1.5.1 的冻结提前量是 30）；grab_eps：第一次改动之前另加两个和抓取有关的漏报 ——
      蓄力中被 MON1 的 CATCH 抓（没放刀）、MON2 的 CATCH_ZAKO 正在来时 MON1 的普通攻击打中（跨怪），外加一段蓄力中
      MON2 的长窗口正在来、没接触（long_hold：SER 里有这条长窗口条目，rc 写一行长窗口 VETO）；
      ver≥1.5.1 时 VETO 带 why（两行 grab、一行 long），1.5 时只有那行长窗口 VETO、不带 why（1.5 不认抓取）。
    1.3 修订：grab_edges（要和 grab_eps 一起用）：再加抓取否决区间的三个边界各一次漏报（grab_far / grab_past /
      grab_long_overlap，接触时刻记在 sy.t_edges），外加抓取否决中途松开又按住（grab_rehold，否决段按蓄力断成两段）；
      rc 的 VETO 多 grab 3、long 1。
    第一次改动之前（V15_PLAN，21 刀，L=26）：接住 14（其中 2 次是新怪 MON4）、FAIL_EARLY 1、FAIL_OTHER 1、空放 3、
      先砍中打断 2 → D：接住 14/16、空放 5/21（不计先砍中打断 3/19）；
      中途一条和 HDR 完全相同的 CFG（不算改动）；ERR mod=items 黄 1 条；
      新怪 MON4 另有 mon4_shadows 个没放刀、没接触的 DANGER 回合（1.2 协议：D 范围内 DANGER 回合 ≥10 才算「打过」）；
      漏报：全场无预告的怪 MON3 打中 1 次（预告缺失）、DANGER 出现时 hs=19.5 已低于 L_min=22 的 1 次；
    第一次改动（CFG 提前量 26→30，时刻记在 sy.t_cfg）之后：空放 3、接住 1（算进去空放就是 8/25 > 25%）；
      再关掉启用开关，关着时蓄力挨打 1 次（不算漏报）。
    STAT 每 60 s 一行、没有 fb；中途「清零统计」一次：replica 0,0,2,2 | 0,1,1… → 合计 3，readerr 0,1,1,1 | 0… → 合计 1。
    cfg=False：去掉全部 CFG（D 只能靠 FIRE.L≠HDR.lead 推断）；change_lead=False：改动后的放刀仍是加载时的 L
    （也推断不出来）。lead0：加载时（HDR）的提前量，放刀都按它（1.2：不是冻结值 26 的发布版 session 整段不计）。
    start_off：加载时启用开关关着（HDR auto_parry=0），第一刀之前在菜单打开（CFG 只改开关，1.2 不截断）。"""
    sy = Synth(seed=1515)
    sy.ct_em = True
    sy.E("pr", "HDR", t=99.0, ver="selftest-v15", session=S, net="SOLO", guard_deg=70.0, aim_deg=70.0,
         overheat_parry=2.5, cfg_guard='{"enabled":true,"infinite_charge":false}',
         cfg_parry='{"auto_parry":%s,"parry_lead":%d,"debug_log":false}' % ("false" if start_off else "true", lead0),
         enums="RT{SAFE:0,CAUTION:1,DANGER:2};PS{NONE:0,WAIT:1,HIT:2,SUCCESS:3,RECOIL:4}")
    sy.E("rc", "HDR", t=99.0, ver=ver, session=S + 1, auto_parry=0 if start_off else 1, lead=lead0, rotation=0, scan=0,
         L_min=22, W_long=60, H_veto=90, credit=1.3)
    t = 400.0
    if start_off and cfg:
        sy.t_on = t - 1.0
        sy.E("rc", "CFG", t=sy.t_on, auto_parry=1, lead=lead0)      # 开局在菜单打开：只改开关
        # 打开之前 0.5 s 就来了的预告、接触在打开之后：关着时 v1.5 不收消息、看不到它 → 不算漏报（另计 off）
        t = sy.shadow(sy.t_on - 0.5, MON1, (0, 89), contact_r=0.02)
    for i, mode in enumerate(V15_PLAN):
        if i == 5 and cfg:
            sy.E("rc", "CFG", t=t - 0.5, auto_parry=1, lead=lead0)   # 和上一状态相同：不算改动
        t = sy.fired(t, MON4 if i in (3, 10) else MON1, KEEPS[i % 6], lead0, mode)
    for i in range(mon4_shadows):           # 没按住蓄力（0.1 s 就松开）：不该放刀、也不是影子回合
        t = sy.shadow(t, MON4, (0, 90 + i), hold=0.1)
    sy.E("rc", "ERR", t=t - 0.4, mod="items", level="yellow", msg="selftest entry read error")
    # 漏报：全场无预告的怪（CT 自带 em，按它归到 em99）
    sy.act(t, (2, 21))
    sy.contact(t + 1.0, MON3, "BODY", True, dmg=10.0, em=MON3["em"])
    sy.act(t + 2.0, (1, 0))
    t += 3.0
    # 漏报：DANGER 第一次出现时 hs=19.5，已低于 v1.5 的 L_min=22（1.0 用 C4 重估的 L_min* 会错归成「其他」）
    t = sy.shadow(t, MON1, (0, 80), contact_r=0.02, ents=[sy.ent(19.5, 10)])
    if grab_eps:
        why_ok = (version_tuple(ver) or (0,)) >= GRAB_SINCE
        t = sy.grab_hit(t, MON1, (0, 150), why="grab" if why_ok else None)
        t = sy.grab_cross(t, why="grab" if why_ok else None)
        t = sy.long_hold(t, why="long" if why_ok else None)
        if grab_edges:
            t, tc_far = sy.grab_far(t, why="grab" if why_ok else None)
            t, tc_past = sy.grab_past(t)
            t, tc_both = sy.grab_long_overlap(t, why="long" if why_ok else None)
            t = sy.grab_rehold(t, why="grab" if why_ok else None)
            sy.t_edges = {"far": tc_far, "past": tc_past, "both": tc_both}
    sy.n_pre = sy.ids["fire"]
    sy.t_cfg = t - 0.5
    L2 = lead0 + 4 if change_lead else lead0
    if cfg:
        sy.E("rc", "CFG", t=sy.t_cfg, auto_parry=1, lead=L2)
    for i, mode in enumerate(["whiff", "catch", "whiff", "whiff"]):
        t = sy.fired(t, MON1, KEEPS[i % 6], L2, mode)
    if cfg:
        sy.E("rc", "CFG", t=t - 0.5, auto_parry=0, lead=L2)
    t = sy.shadow(t, MON1, (0, 81), contact_r=0.03)          # 开关关着时被打：不算漏报
    tt, i_st = 100.0, 0
    while tt < t:
        sy.E("pr", "PERF", t=tt, fps=80.0 + sy.rng.uniform(-0.5, 0.5), maxdt=0.02, hooks="msg:80,ct:1", lua_ms_avg=0.1,
             lua_ms_max=0.5, tracked=2, red=0, yellow=0, hook_ms_ps=1.0)
        if int(tt) % 60 == 40:
            rep = (0 if i_st < 2 else 2) if i_st < 4 else (0 if i_st == 4 else 1)
            rde = (0 if i_st < 1 else 1) if i_st < 4 else 0
            sy.E("rc", "STAT", t=tt, fires=sy.ids["fire"], catches=0, vetoes=0, failopen=0, errors=1 if rde else 0,
                 red=0, yellow=1 if rde else 0, lua_ms_avg=0.05, lua_ms_max=0.3, hook_ms_ps=1.0, readfail=0,
                 replica=rep, readerr=rde)
            i_st += 1
        tt += 5.0
    sy.n_stat = i_st
    sy.t_end = t
    return sy


# 1.4：v1.6 自测用的怪。em50~53 是新怪（不在设计集），em27 在设计集里（B 阶段不进合并判定）；第二项是 CoreState
MON50 = {"em": "em50#21", "ec": "1D2E3F405050", "go": "Em0201_00_000@1D2E3F405000"}
MON51 = {"em": "em51#22", "ec": "1D2E3F405151", "go": "Em0202_00_000@1D2E3F405100"}
MON52 = {"em": "em52#23", "ec": "1D2E3F405252", "go": "Em0203_00_000@1D2E3F405200"}
MON53 = {"em": "em53#24", "ec": "1D2E3F405353", "go": "Em0204_00_000@1D2E3F405300"}
MON27 = {"em": "em27#25", "ec": "1D2E3F402727", "go": "Em0160_00_000@1D2E3F402700"}
MON33 = {"em": "em33#26", "ec": "1D2E3F403333", "go": "Em0165_00_000@1D2E3F403300"}    # 训练机关（D16 不算怪）
NEW16 = [(MON50, 1.134), (MON51, 1.0), (MON52, 0.92), (MON53, 1.2)]
V16_PLAN = ["catch26", "catch27"] * 7 + ["early", "recoil25", "whiff", "interrupted"]


def build_synth_v16(S, variant="pass"):
    """1.4：v1.6（B 阶段，V16 第 9.2 节）合成数据。HDR ver=1.6、lead=28、rule=E5c、filter=g1、cfg_ver=3；探针 apcal-1.1。
    4 只新怪（em50 C=1.134、em51 C=1.0、em52 C=0.92 → m=1、em53 C=1.2）各 18 刀（V16_PLAN：接住 14（26、27 各 7）、放早 1、
    进 (2,25) 被弹 1（pb=0，「不应出现」那一类）、纯空挥 1、先砍中打断 1）→ 新怪合并接住 56/64、纯空挥 4/68；设计集 em27 另 3 刀接住
    （不进合并判定）。放刀按 E5c 在 Q 第一次 ≤28 的那一帧，FIRE 带 E5c 字段（C 不变：nchg=0、Qe1=Q0）、RES 带 to。另有：
    em51 一刀同一结果里带一条短窗口 UNABLE_GUARD 条目 → UVIEW why=ug same=1；em50 的 pb=1 攻击打中蓄力中的主角（rc 写 SKIP why=pb）
    → 漏报「被该接过滤排除」；em51 UNABLE_GUARD、em52 攻击参数为空各一招只写 SKIP（ug、fc）；SKILL_GUARD（伤害类型不是抓取）的一招
    在视野内 → VETO why=sg；DBG speed_fail idx=21（em50）一行（日志）。STAT 带 v1.6 的新计数。
    variant：pass（通过）/ fail（em53 只接住 4、放早 12 → 新怪合并 46/64 <75% 不通过；em27 的一刀 Q0 故意写小 0.6，一致性核对要抓到）/
    insufficient（只有 3 只新怪 → 样本不足）/ review（探针 apcal-1.0.1、sidmis=2 → 需复核）/
    red（审查修订：只有一条放刀模块的核心红错误 ERR frame red「caught (...) exception」，STAT red 仍是 0 → RED 项不通过）/
    red_stat（同上，但只有 STAT red=1、ERR 记录没进 JSON → 照样不通过）/
    edge（审查补充，门槛的边界：em50~52 各 11 接住 + 4 次 FAIL_OTHER、em53 12 接住 + 3 次放早 → 每只正好 15 次有接触、合并正好
    45/60 = 75%；另有训练机关 em33 两刀接住，不进新怪合并 → 通过，em53 标「左尾诊断（放早 ≥3）」）。"""
    sy = Synth(seed=1616)
    sy.ct_em = True
    sy.E("pr", "HDR", t=99.0, ver="apcal-1.0.1" if variant == "review" else "apcal-1.1", session=S, net="SOLO",
         guard_deg=70.0, aim_deg=70.0, overheat_parry=2.5, cfg_guard='{"enabled":true,"infinite_charge":false}',
         cfg_parry='{"auto_parry":true,"parry_lead":28,"debug_log":true,"cfg_ver":3}',
         enums="RT{SAFE:0,CAUTION:1,DANGER:2};PS{NONE:0,WAIT:1,HIT:2,SUCCESS:3,RECOIL:4};DT{NONE:-1,NORMAL:0,EAR:2,WIND:4,"
               "QUAKE:1};GT{NORMAL:0,ALL_RANGE:1,UNABLE_GUARD:2,SKILL_GUARD:3,SKILL_GUARD_ALL_RANGE:4}")
    sy.E("rc", "HDR", t=99.0, ver="1.6", session=S + 1, auto_parry=1, lead=28, rotation=0, scan=0, L_min=22, W_long=60,
         H_veto=90, credit=1.3, rule="E5c", filter="g1", cfg_ver=3, c_lo=0.5, c_hi=2.0)
    t = 400.0
    mons = NEW16 if variant != "insufficient" else NEW16[:3]
    sy.v16_fids = {}
    for mon, C in mons:
        plan = list(V16_PLAN)
        if variant == "fail" and mon is MON53:
            plan = ["catch26", "catch27"] * 2 + ["early"] * 12 + ["whiff", "interrupted"]
        if variant == "edge":
            plan = (["catch26", "catch27"] * 6 + ["early"] * 3 if mon is MON53
                    else ["catch26", "catch27"] * 5 + ["catch26"] + ["other"] * 4)
        for j, mode in enumerate(plan):
            m_, tier = (("catch", int(mode[-2:])) if mode.startswith("catch") else (mode, None))
            kw = {}
            if mon is MON51 and j == 0:
                # 同一结果里另有一条短窗口 UNABLE_GUARD（hs 比触发条目小 5、宽 6）：放刀第一帧在视野内 → UVIEW
                kw = dict(hs0=61.0, extra_ents=[sy.ent(56.0, 6, guard="UNABLE_GUARD")], uview={"why": "ug", "same": True})
            t = sy.fired(t, mon, (0, 100 + j % 6), 28, m_, width=12, core=C, v16=True, tier=tier, **kw)
            sy.v16_fids.setdefault(mon["em"], []).append(sy.ids["fire"])
    for j in range(3):          # 设计集 em27：接住 3 刀，不进新怪合并
        # fail 变体：第 2 刀的 Q0 故意写小 0.6（仍在 [22, 28] 里，只有公式核对抓得到）
        t = sy.fired(t, MON27, (0, 110 + j), 28, "catch", width=12, core=1.08, v16=True, tier=27,
                     q_bad=-0.6 if (variant == "fail" and j == 1) else 0.0)
    if variant == "edge":
        for j in range(2):      # 训练机关 em33（Em0165）：不算怪，不进新怪合并（D16 的「新怪」排除它）
            t = sy.fired(t, MON33, (0, 115 + j), 28, "catch", width=12, core=1.0, v16=True, tier=27)
    sy.bad_fid = sy.ids["fire"] - 1 if variant == "fail" else None
    sy.range_fid = sy.qe_fid = None
    if variant == "fail":
        # 再一刀：按 L=30 触发（Q0 在 29~30）、FIRE 却记 L=28 —— 公式各项自洽，只有「L_min ≤ Q0 ≤ L」抓得到
        t = sy.fired(t, MON27, (0, 113), 30, "catch", width=12, core=1.08, v16=True, tier=27, L_rec=28)
        sy.range_fid = sy.ids["fire"]
        # 再一刀：只有影子 E1（Qe1）写偏 0.5，只有 Qe1 那一项抓得到
        t = sy.fired(t, MON27, (0, 114), 28, "catch", width=12, core=1.08, v16=True, tier=27, qe_bad=0.5)
        sy.qe_fid = sy.ids["fire"]
    # em50 的 pb=1 攻击：蓄力中进窗口（Q 在消息后第 25 帧 ≤28）被该接过滤挡掉（rc 写 SKIP why=pb），打中蓄力中的主角 → 漏报
    t_m = t
    t = sy.shadow(t_m, MON50, (0, 120), contact_r=0.02, ents=[sy.ent(60.0, 10, pb=True)], core=1.134)
    sy.E("rc", "SKIP", t=t_m + 25 / 60.0, why="pb", hs=35.0, he=45.0, Q=27.91, em=MON50["em"], keep=(0, 120),
         res=sy.last_obj, ent=None)
    sy.t_miss_g1 = t_m + 1.02
    for mon, why, ekw, C in ((MON51, "ug", {"guard": "UNABLE_GUARD"}, 1.0), (MON52, "fc", {"ap": False}, 0.92)):
        t_m = t
        t = sy.shadow(t_m, mon, (0, 121), ents=[sy.ent(60.0, 10, **ekw)], core=C)
        sy.E("rc", "SKIP", t=t_m + 32 / 60.0, why=why, hs=28.0, he=38.0, Q=28.0, em=mon["em"], keep=(0, 121),
             res=sy.last_obj, ent=None)
    # SKILL_GUARD（伤害类型不是抓取）一招在视野内（hs0=70 ≤ H_veto）：v1.6 否决 why=sg
    t_m = t
    t = sy.shadow(t_m, MON50, (0, 122), ents=[sy.ent(70.0, 10, guard="SKILL_GUARD", dmgtype="SMASH")], core=1.134)
    sy.E("rc", "VETO", t=t_m + 0.01, hs=70.0, he=80.0, res=sy.last_obj, ent=None, em=MON50["em"], why="sg")
    if variant == "red":
        sy.E("rc", "ERR", t=t - 0.5, mod="frame", level="red", msg="caught_(...)_exception")
    tt, n_fire = 100.0, sy.ids["fire"]
    while tt < t:
        sy.E("pr", "PERF", t=tt, fps=80.0 + sy.rng.uniform(-0.5, 0.5), maxdt=0.02, hooks="msg:80,ct:1", lua_ms_avg=0.1,
             lua_ms_max=0.5, tracked=1, red=0, yellow=0, hook_ms_ps=1.0)
        if int(tt) % 60 == 40:
            sy.E("rc", "STAT", t=tt, fires=n_fire, catches=0, vetoes=1, fb=0, failopen=0, errors=0, red=0, yellow=0,
                 lua_ms_avg=0.05, lua_ms_max=0.3, hook_ms_ps=1.0, readfail=0, replica=0, readerr=0, recoils=len(mons),
                 speedfail=1, speedhold=0, clockskip=0, vetoq=0, fclosed=1, excl=2, uview=1,
                 sidmis=2 if variant == "review" else 0)
            if variant == "red_stat":
                sy.recs["rc"][-1][1]["red"] = 1
        tt += 5.0
    sy.dbg = ["[2026-10-10 20:00:00.000] [REFramework] [info] [AutoParryGS] DBG ev=speed_fail t=450.0000 idx=21 why=find"]
    sy.t_end = t
    return sy


def build_synth_v16_lead(S):
    """1.4（集成补充）：v1.6 的 session 中途把滑块拖到 35（CFG 记录）：之前一刀按 L=28、之后一刀按 L=35 触发（FIRE 记各自的 L，
    em50 C=1.134）。第 13 节「影子对真 FIRE」要按这一刀自己的 L 重放：两刀都和影子同一帧（按 28 比，L=35 那刀会差 8 帧）。"""
    sy = Synth(seed=1635)
    sy.ct_em = True
    sy.E("pr", "HDR", t=99.0, ver="apcal-1.1", session=S, net="SOLO", guard_deg=70.0, aim_deg=70.0, overheat_parry=2.5,
         cfg_guard='{"enabled":true,"infinite_charge":false}',
         cfg_parry='{"auto_parry":true,"parry_lead":28,"debug_log":false,"cfg_ver":3}',
         enums="RT{SAFE:0,CAUTION:1,DANGER:2};PS{NONE:0,WAIT:1,HIT:2,SUCCESS:3,RECOIL:4};DT{NONE:-1,NORMAL:0,EAR:2,WIND:4,"
               "QUAKE:1};GT{NORMAL:0,ALL_RANGE:1,UNABLE_GUARD:2,SKILL_GUARD:3,SKILL_GUARD_ALL_RANGE:4}")
    sy.E("rc", "HDR", t=99.0, ver="1.6", session=S + 1, auto_parry=1, lead=28, rotation=0, scan=0, L_min=22, W_long=60,
         H_veto=90, credit=1.3, rule="E5c", filter="g1", cfg_ver=3, c_lo=0.5, c_hi=2.0)
    t = sy.fired(400.0, MON50, (0, 101), 28, "catch", width=12, core=1.134, v16=True, tier=27)
    sy.E("rc", "CFG", t=t - 0.5, auto_parry=1, lead=35)
    t = sy.fired(t, MON50, (0, 102), 35, "catch", width=12, core=1.134, v16=True, tier=27)
    sy.dbg = []
    sy.t_end = t
    return sy


def build_synth_v16_gap(S):
    """1.4 审查修订（V16 第 14 节）：第 13 节「1.6 影子对真 FIRE」不再静默剔除影子不触发的放刀，第 14 节和影子回放认探针 AP 停用。
    em50（C=1.134）四刀：#1 普通（影子同一帧）；#2 rc 放了、探针 ENT 却是 pb=1（影子按该接过滤排除 → 原因不明：实现偏离规则的
    样子）；#3 探针在这一刀之前报了 ERR AP（AP 停用），ENT 三项全空 → 属性不明、影子照样放行（不按读不准），和真 FIRE 同一帧；
    #4 FIRE 记 nchg=1（存活期间 m 变过：mf=1.2，dX、Q0 按 1.2 自洽），影子只看得到首帧 C=1.134 → 帧差只报告、不算不一致，
    「实际 Q」是 FIRE 的 Q0。另有一招在 AP 停用之后没放刀的 DANGER 回合：ENT 三项全空，第 14 节不算「攻击参数为空」。"""
    sy = Synth(seed=1614)
    sy.ct_em = True
    sy.E("pr", "HDR", t=99.0, ver="apcal-1.1", session=S, net="SOLO", guard_deg=70.0, aim_deg=70.0, overheat_parry=2.5,
         cfg_guard='{"enabled":true,"infinite_charge":false}',
         cfg_parry='{"auto_parry":true,"parry_lead":28,"debug_log":false,"cfg_ver":3}',
         enums="RT{SAFE:0,CAUTION:1,DANGER:2};PS{NONE:0,WAIT:1,HIT:2,SUCCESS:3,RECOIL:4};DT{NONE:-1,NORMAL:0,EAR:2,WIND:4,"
               "QUAKE:1};GT{NORMAL:0,ALL_RANGE:1,UNABLE_GUARD:2,SKILL_GUARD:3,SKILL_GUARD_ALL_RANGE:4}")
    sy.E("rc", "HDR", t=99.0, ver="1.6", session=S + 1, auto_parry=1, lead=28, rotation=0, scan=0, L_min=22, W_long=60,
         H_veto=90, credit=1.3, rule="E5c", filter="g1", cfg_ver=3, c_lo=0.5, c_hi=2.0)
    t = sy.fired(400.0, MON50, (0, 101), 28, "catch", width=12, core=1.134, v16=True, tier=27)
    sy.gap_ids = {"ok": sy.ids["fire"]}
    t = sy.fired(t, MON50, (0, 102), 28, "catch", width=12, core=1.134, v16=True, tier=27, ent_kw={"pb": True})
    sy.gap_ids["pb"] = sy.ids["fire"]
    sy.t_ap_off = t
    sy.E("pr", "ERR", t=t, mod="AP", level="yellow", msg="selftest2_ap:_no_value")
    t = sy.fired(t + 0.5, MON50, (0, 103), 28, "catch", width=12, core=1.134, v16=True, tier=27, ent_kw={"ap": False})
    sy.gap_ids["unk"] = sy.ids["fire"]
    t = sy.fired(t, MON50, (0, 104), 28, "catch", width=12, core=1.134, v16=True, tier=27)
    sy.gap_ids["chg"] = fid = sy.ids["fire"]
    for kind, kw in sy.recs["rc"]:
        if kind == "FIRE" and kw.get("id") == fid:
            m2 = 1.2
            dX = round((kw["A0"] - kw["R0"]) * (m2 - 1.0), 2)
            kw.update(mf=m2, Cf=m2, nchg=1, dX=dX, Q0=round((kw["R0"] - dX) / m2, 2))
    t_m = t
    t = sy.shadow(t_m, MON51, (0, 121), ents=[sy.ent(60.0, 10, ap=False)], core=1.0)
    tt = 100.0
    while tt < t:
        sy.E("pr", "PERF", t=tt, fps=80.0, maxdt=0.02, hooks="msg:80", lua_ms_avg=0.1, lua_ms_max=0.5, tracked=1, red=0,
             yellow=0, hook_ms_ps=1.0)
        tt += 5.0
    sy.dbg = []
    sy.t_end = t
    return sy


def build_synth_recoil25(S):
    """1.4：v1.5.1 的发布版 session（rc 把进 (2,25) 记成 CATCH25）上的 (2,25) 改判和 E5c 影子回放：
    #1 em20 接住进 (2,26)；#2 em20 刀上接触、PH RECOIL、进 (2,25)、随即挨打（RES CATCH25）→ 离线 RECOIL；
    #3 em42（CoreState 1.134、A0=120）按原始 hs@30 放刀、放早（c_first 0.20）→ E5c@28 早 12 帧触发，c_first' ≈ 0.40 落进窗口；
    另有一次手动放刀进 (2,25)（PH RECOIL）→ RECOIL。C=1 的那刀 E5c@28 比原始 hs@30 晚 2 帧。"""
    sy = Synth(seed=2525)
    sy.ct_em = True
    sy.E("pr", "HDR", t=99.0, ver="apcal-1.0.1", session=S, net="SOLO", enums="RT{SAFE:0,CAUTION:1,DANGER:2}")
    sy.E("rc", "HDR", t=99.0, ver="1.5.1", session=S + 1, auto_parry=1, lead=30, rotation=0, scan=0, L_min=22,
         W_long=60, H_veto=90, credit=1.3)
    t = 400.0
    t = sy.fired(t, MON1, (0, 72), 30, "catch", width=12, core=1.0, hs0=60.4, tier=26)
    t = sy.fired(t, MON1, (0, 73), 30, "recoil25", width=12, core=1.0, hs0=60.6)
    t = sy.fired(t, MON4, (0, 74), 30, "early", width=12, core=1.134, hs0=120.3)
    # 手动放刀：按住蓄力、自己松手出 (2,23)，刀上接触 PH RECOIL、进 (2,25)
    sy.act(t, (2, 21))
    t_act = t + 1.0
    sy.act(t_act, SLASH, raw_new=0.004)
    sy.E("pr", "PT", t=t_act, id=sy.nid("pt"), t_obs=t_act, raw0=0.004, t_start=t_act - 0.004, **{"from": (2, 21)},
         hold=1.0, lv="1", dmg=0.0, online_class="?")
    sy.contact(t_act + 0.40, MON1, "BLADE", True)
    sy.E("pr", "PH", t=t_act + 0.4005, state="RECOIL", target=MON1["go"], raw=0.40, chara=0.40, delay=0)
    sy.act(t_act + 0.42, (2, 25))
    sy.act(t_act + 2.0, (1, 0))
    t = t_act + 3.0
    tt = 100.0
    while tt < t:
        sy.E("pr", "PERF", t=tt, fps=80.0, maxdt=0.02, hooks="msg:80", lua_ms_avg=0.1, lua_ms_max=0.5, tracked=1, red=0,
             yellow=0, hook_ms_ps=1.0)
        tt += 5.0
    sy.t_end = t
    return sy


def _json_val(v):
    if isinstance(v, tuple):
        return f"{v[0]}_{v[1]}"
    return v


def _log_val(v):
    if v is None:
        return "-"
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, tuple):
        return f"({v[0]},{v[1]})"
    if isinstance(v, float):
        return f"{v:.4f}"
    return str(v).replace(" ", "_")


def _log_line(src, kind, kw, t):
    order = [n for n, _typ in SCHEMA[src].get(kind, [])]
    keys = [k for k in order if k in kw or k == "t"] + [k for k in kw if k not in order and k != "t"]
    if "t" not in order:
        keys = [k for k in keys if k != "t"]
    parts = [f"{k}={_log_val(kw.get(k))}" for k in keys]
    sec = 1760000000 + t
    hh, mm, ss = int(sec // 3600 % 24), int(sec // 60 % 60), sec % 60
    return f"[2026-10-10 {hh:02d}:{mm:02d}:{ss:06.3f}] [REFramework] [info] [{SRC2TAG[src]}] {kind} " + " ".join(parts)


# 真实游戏日志里和「崩溃」字样有关、但不是崩溃的行（2026-10-10 本机日志原样）：REF 启动时拷贝/加载 CrashHandler、
# IntegrityCheckBypass 的 crasher_fn、被 REF 截住的 VMContext 访问冲突；另有两行 release 告警（一行在 Reset 时）
REF_NOISE_LINES = [
    "[2026-10-10 16:03:52.523] [REFramework] [info] Copying DLL file: CrashHandler.dll",
    "[2026-10-10 16:03:52.524] [REFramework] [info]  Full path: C:\\Program Files (x86)\\Steam\\steamapps\\common\\"
    "MonsterHunterWilds\\CrashReportDll.dll",
    "[2026-10-10 16:03:55.430] [REFramework] [info] [IntegrityCheckBypass]: Found crasher_fn!",
    "[2026-10-10 16:06:19.990] [REFramework] [info] VMContext: Caught exception code c0000005",
    "[2026-10-10 16:06:19.990] [REFramework] [info] VMContext: Attempting to handle access violation. Attempting to dump callstack...",
    "[2026-10-10 16:06:19.990] [REFramework] [error] RIP: 149cd8ed4",
    "[2026-10-10 16:06:20.000] [REFramework] [error] Exception thrown in REMethodDefinition::invoke for app.cEnemyBrowser.get_IsDie",
    "[2026-10-10 16:19:01.014] [REFramework] [warning] REManagedObject:release attempted to release an object that was not "
    "managed by our Lua state",
    "[2026-10-10 16:18:37.933] [REFramework] [warning] REManagedObject:release attempted to release an object that was not "
    "managed by our Lua state",
    "[2026-10-10 16:18:37.938] [REFramework] [info] [ScriptRunner] Loading scripts...",
]


def merged_synth(sy, lazy=False):
    """1.5（MERGE 第 4.2 节）：把 v1.6 的合成数据改成合并版（AutoGuardGS v1.5）写的放刀记录：HDR 删 rotation / scan / cfg_ver、
    加 host / enum_skip；FIRE 删 src / Qp / Qe1 / mode / vq；FIRE_END 删掉、entered 并进 RES；没有 VETO、SKIP、UVIEW、STAT、CFG、DBG。
    lazy：HDR 懒写（调试日志中途才打开）—— 写在第一行别的放刀记录之前，而不是加载时。"""
    ends = {kw.get("id"): kw.get("entered") for kind, kw in sy.recs["rc"] if kind == "FIRE_END"}
    out = []
    for kind, kw in sy.recs["rc"]:
        if kind in ("FIRE_END", "VETO", "SKIP", "UVIEW", "STAT", "CFG"):
            continue
        kw = dict(kw)
        if kind == "HDR":
            for k in ("rotation", "scan", "cfg_ver"):
                kw.pop(k, None)
            kw["host"], kw["enum_skip"] = "AutoGuardGS-v1.5", "-"
        elif kind == "FIRE":
            for k in ("src", "Qp", "Qe1", "mode", "vq"):
                kw.pop(k, None)
        elif kind == "RES":
            kw["entered"] = ends.get(kw.get("id"), True)
        out.append((kind, kw))
    if lazy:
        first = min(kw.get("t", 1e18) for kind, kw in out if kind != "HDR")
        for kind, kw in out:
            if kind == "HDR":
                kw["t"] = first - 0.001
    sy.recs["rc"] = out
    sy.dbg = []
    return sy


def write_dataset(sy, out_dir, S, drop_rc_seqs=(2,), probe_json=True, log_name="re2_framework_log.txt", S_rc=None,
                  write_log=True, last_why="reset", extra_log=(), old_session=True, hdr_by_time=False):
    os.makedirs(out_dir, exist_ok=True)
    S_rc = S + 1 if S_rc is None else S_rc
    for src, sess in (("pr", S), ("rc", S_rc)):
        recs = sorted(sy.recs[src], key=lambda kv: kv[1].get("t", 0.0))
        t0 = recs[0][1].get("t", 0.0)
        chunks = defaultdict(list)
        for kind, kw in recs:
            seq = 1 + int((kw.get("t", t0) - t0) // 60.0)
            rec = {"k": kind}
            rec.update({k: _json_val(v) for k, v in kw.items() if v is not None})
            chunks[seq].append(rec)
        seqs = sorted(chunks)
        for n, seq in enumerate(seqs, 1):
            if (src == "rc" and n in drop_rc_seqs) or (src == "pr" and not probe_json):
                continue
            why = last_why if n == len(seqs) else "idle"
            doc = {"kind": SRC2TAG[src], "ver": "selftest", "session": sess, "seq": n, "why": why,
                   "records": chunks[seq]}
            with open(os.path.join(out_dir, f"{SRC2TAG[src]}_{sess}_{n}.json"), "w", encoding="utf-8") as fh:
                json.dump(doc, fh, ensure_ascii=False)
    if old_session:
        # 旧 session：JSON 和日志里各留一点，默认必须选不到它
        old = {"kind": "APCal", "session": S - 5000, "seq": 1,
               "records": [{"k": "MSG", "t": 5.0, "obj": "DEAD01", "em": "em1#1", "rt": 2}]}
        with open(os.path.join(out_dir, f"APCal_{S - 5000}_1.json"), "w", encoding="utf-8") as fh:
            json.dump(old, fh)
    if not write_log:
        return
    lines = ["[2026-10-10 18:00:00.000] [REFramework] [info] REFramework entry",
             _log_line("pr", "HDR", {"ver": "old", "session": S - 5000}, 1.0),
             _log_line("pr", "MSG", {"t": 5.0, "obj": "DEAD02", "em": "em1#1", "rt": "DANGER"}, 5.0),
             # 旧 session 范围里的崩溃字样：不能算到所选 session 头上
             "[2026-10-10 18:00:00.500] [REFramework] [error] Unhandled exception (old session, must be ignored)",
             "[2026-10-10 18:00:01.000] [REFramework] [warning] [OtherMod] FIRE id=999 t=1.0 (别的 mod，不该被解析)"]
    allrecs = [(kw.get("t", 0.0), 0 if kind == "HDR" else 1, src, kind, kw)
               for src in ("pr", "rc") for kind, kw in sy.recs[src] if kind not in JSON_ONLY]
    # hdr_by_time（1.5，合并版的懒写 HDR）：HDR 按自己的时刻排，不提到最前
    allrecs.sort(key=(lambda x: (x[0], x[1])) if hdr_by_time else (lambda x: (x[1], x[0])))
    for t, _pri, src, kind, kw in allrecs:
        lines.append(_log_line(src, kind, kw, t))
    lines += REF_NOISE_LINES + list(extra_log)
    lines.append("[2026-10-10 21:00:00.000] [REFramework] [info] [APCal] 这一行不是记录")
    with open(os.path.join(out_dir, log_name), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


# ---------------------------------------------------------------- 自测：跑完整流程并断言
def selftest(keep=None):
    base = os.path.abspath(keep) if keep else tempfile.mkdtemp(prefix="apcal_selftest_")
    os.makedirs(base, exist_ok=True)
    S = 1760000000
    checks = []

    def chk(name, cond, detail=""):
        checks.append((name, bool(cond), detail))

    try:
        sy = build_synth(S)
        n_fire = sy.ids["fire"]
        exp_whiff = sum(1 for o, _s in sy.expected.values() if o == "WHIFF")

        # 1) 完整数据，但 rc 的第 2 个 JSON 丢了（必须由日志补齐）；另有一个旧 session 不该被选中
        d1 = os.path.join(base, "full")
        write_dataset(sy, d1, S)
        data = load_data(d1)
        R = analyze(data, strict=True)
        rep = render(R, strict=True)
        with open(os.path.join(base, "report_full.md"), "w", encoding="utf-8") as fh:
            fh.write(rep)
        ctx = R.ctx
        chk("session 选最新并配对（APCal=S，AutoParryGS=S+1）", data.info["chosen"] == {"pr": S, "rc": S + 1},
            str(data.info["chosen"]))
        chk("rc 缺失的 seq 由日志补齐、且不重复", data.info["log_added"]["rc"] > 0 and len(R.fires_all) == n_fire
            and len(data.get("rc", "FIRE")) == n_fire, f"补入 {data.info['log_added']['rc']}，FIRE {len(R.fires_all)}/{n_fire}")
        chk("探针 JSON 齐全时日志不重复补入（ENT 无 t 也能去重）", data.info["log_added"]["pr"] == 0,
            f"补入 {data.info['log_added']['pr']}")
        chk("HDR enums（探针的 组{名:值} 写法）全部读到", data.info.get("enum_hits") == 3 + 5 + 3 + 3 + 3,
            str(data.info.get("enum_hits")))
        chk("扫描窗口可分", R.win_scan.ok and R.win_scan.m0 == "可分·中点" and R.win_scan.m1 == "可分·中点",
            f"{R.win_scan.m0} / {R.win_scan.m1}")
        chk("W0 恢复到 ±0.03 s", abs(ctx.W0 - TRUE_W0) <= 0.03, f"W0={ctx.W0:.4f} 真值 {TRUE_W0}")
        chk("W1 恢复到 ±0.03 s 且不是删失", abs(ctx.W1 - TRUE_W1) <= 0.03 and not ctx.cens1, f"W1={ctx.W1:.4f} 真值 {TRUE_W1}")
        chk("T_armor 恢复", R.t_armor is not None and abs(R.t_armor - TRUE_ARMOR) <= 0.005, f"T_armor={R.t_armor}")
        chk("W1_eff = min(W1, T_armor−0.05)", abs(ctx.W1_eff - min(ctx.W1, TRUE_ARMOR - 0.05)) < 1e-6, f"{ctx.W1_eff}")
        chk("δ 恢复到 ±0.003 s", abs(ctx.delta - TRUE_DELTA) <= 0.003, f"δ={ctx.delta:.4f}")
        chk("d̄ 在 [0,1) 帧", 0.0 <= R.dbar < 1.0, f"d̄={R.dbar}")
        mism = [(f.id, (f.outcome, f.sub), sy.expected.get(f.id)) for f in R.fires
                if (f.outcome, f.sub) != sy.expected.get(f.id)]
        chk("每次放刀的结局与真值一致（B 节互斥分类）", not mism, str(mism[:6]))
        cnt = Counter(f.outcome for f in R.fires)
        chk("六类结局都出现", all(cnt[o] > 0 for o in OUTCOME_ORDER), str(dict(cnt)))
        chk("INTERRUPTED 子类 1 次", sum(1 for f in R.fires if f.sub == "INTERRUPTED") == 1)
        chk("接住同帧有身体接触：仍记 CATCH，且不是 CLEAN", any(f.outcome == "CATCH" and f.clean is False for f in R.fires))
        chk("多段攻击：两个接触都匹配到同一回合，按首个接触记", any(len(f.contacts) >= 2 and f.outcome == "CATCH" for f in R.fires))
        chk("P23 歧义计数", R.match.ambiguous == sy.planted["ambiguous"], f"{R.match.ambiguous}/{sy.planted['ambiguous']}")
        chk("P23 未匹配计数（有预告的攻击者）", R.match.unmatched - R.match.no_pred_attacker == sy.planted["unmatched_known"],
            f"{R.match.unmatched - R.match.no_pred_attacker}/{sy.planted['unmatched_known']}")
        chk("P23 未匹配计数（全场无预告的机关）", R.match.no_pred_attacker == sy.planted["dummy_contacts"],
            f"{R.match.no_pred_attacker}/{sy.planted['dummy_contacts']}")
        chk("攻击者别名靠共现学到（EnemyCharacter 地址 → em#idx）",
            ctx.ident.alias.get(("addr", MON1["ec"])) == ("sys", 3) and ctx.ident.alias.get(("addr", MON2["ec"])) == ("sys", 5))
        chk("C3 L* 有定义且在平台上", R.Lstar is not None and R.N[R.Lstar] == R.Nmax, f"L*={R.Lstar}")
        chk("C3 留一招式交叉验证可算", R.cv is not None and R.cv.groups >= 6 and 0.0 <= R.cv.p <= 1.0,
            f"P_CV={R.cv.p if R.cv else None}")
        chk("C4 L_min* 在 [15, L*−6]", R.lmin is not None and 15 <= R.lmin <= max(15, R.Lstar - 6), f"L_min*={R.lmin}")
        chk("C5 W_long* 只取 60 或 30", R.wlong in (30, 60))
        c6n = {r.name.split("（")[0]: r.n for r in R.c6}
        chk("C6 V0/V1/α=0.25/g6 都有 ≥8 个共同样本，且维持 V0", all(c6n.get(k, 0) >= 8 for k in ("V0", "V1", "α=0.25", "g6 速度缩放"))
            and c6_choice(R).startswith("V0"), f"{c6n} → {c6_choice(R)}")
        chk("C7 F_actual", R.F_actual is not None and abs(R.F_actual - exp_whiff / n_fire) < 1e-9, f"{R.F_actual}")
        chk("C7 F_shadow（16 个影子回合里 4 个空放）", R.F_shadow_n == 16 and R.F_shadow is not None
            and abs(R.F_shadow - 0.25) < 1e-9, f"n={R.F_shadow_n} F={R.F_shadow}")
        g1 = next((r for r in R.gates.table if r.step == 1 and r.gid == "g1"), None)
        chk("C8 g1 去掉 5 次空放、损失 1 次潜在接住", g1 is not None and g1.removed == 5 and g1.lost == 1,
            f"{(g1.removed, g1.lost) if g1 else None}")
        chk("C8 只采用 g1", [g for g, _r in R.gates.chosen] == ["g1"], str([g for g, _r in R.gates.chosen]))
        chk("C8 评估候选数 = 6 + 5", R.gates.evaluated == 11, str(R.gates.evaluated))
        mc = R.misses.counts if R.misses else Counter()
        # A2 机关扫描段（第一个 DANGER 回合之前）的接触不算漏报；跨怪的长窗口否决归「被长窗口规则否决」；
        # Q 在 [L_min, L] 时没按住蓄力的单列
        want = {MISS_CLASSES[0]: 0, MISS_CLASSES[1]: 1, MISS_CLASSES[2]: 1, MISS_CLASSES[3]: 1, MISS_CLASSES[5]: 2,
                MISS_CLASSES[6]: 1, MISS_CLASSES[7]: 11, MISS_CLASSES[8]: 1}
        chk("漏报归因（只算 B 段；跨怪否决；不在蓄力单列）", all(mc.get(k, 0) == v for k, v in want.items())
            and sum(mc.values()) == sum(want.values()), str(dict(mc)))
        ea, _notes = R.ep_attr
        chk("回合归因含收尾挨打/被打断/目标不是我", ea.get(EP_CLASSES[2], 0) >= 1 and ea.get(EP_CLASSES[4], 0) == 1
            and ea.get(EP_CLASSES[7], 0) >= 5, str(dict(ea)))
        chk("错误分级：黄 1、红 0、零星核心错误 1（不算关键错误）", R.err.yellow == 1 and R.err.red == 0 and R.err.core == 1,
            f"黄 {R.err.yellow} 红 {R.err.red} 零星 {R.err.core}")
        chk("C10 不需要补测", not R.c10, str(R.c10))
        # c_first 按字面定义（不经 P23）：L=36 早到 r≈−0.39、多段攻击前段先打中，都是 FAIL_EARLY 且进残差
        early36 = [f for f in R.fires if f.L == 36 and sy.expected.get(f.id, (None,))[0] == "FAIL_EARLY"]
        chk("L=36 早到（P23 窗口外）判 FAIL_EARLY、有 c_first、进 C2 残差",
            len(early36) >= 2 and all(f.outcome == "FAIL_EARLY" and f.c_first is not None
                                      and any(s.f is f for s in R.res) for f in early36),
            str([(f.id, f.outcome, f.c_first) for f in early36]))
        chk("放刀首个接触在 P23 窗口外的次数（L=36 早到 2 次）", R.outside_p23 == 2, str(R.outside_p23))
        b2b = sy.planted.get("back_to_back")
        f_b2b = next((f for f in R.fires if f.id == b2b), None)
        chk("连续两刀：后一刀的接住、PH 不算到前一刀（前一刀 WHIFF）", f_b2b is not None and f_b2b.outcome == "WHIFF",
            str(f_b2b and (f_b2b.outcome, f_b2b.sub)))
        chk("T_armor：进 (2,23) 第一帧的瞬时 sa=0 不算（每次空挥/空放都取 0.9）",
            len(R.t_armor_vals) >= 3 and all(abs(v - TRUE_ARMOR) < 1e-6 for v in R.t_armor_vals), str(R.t_armor_vals))
        ev = data.info.get("log_events")
        chk("日志：CrashHandler/crasher_fn/被截住的访问冲突不算崩溃，旧 session 的未处理异常不算到本 session",
            not data.info.get("crash") and ev is not None and ev.scoped and len(ev.caught_av) == 1
            and ev.caught_av[0].method == "app.cEnemyBrowser.get_IsDie",
            f"crash={data.info.get('crash')} av={[e.method for e in ev.caught_av] if ev else None}")
        chk("日志：release 告警分 Reset 时 1 次 / 其他时候 1 次",
            ev is not None and len(ev.release_reset) == 1 and len(ev.release_other) == 1,
            f"{len(ev.release_reset) if ev else '-'} / {len(ev.release_other) if ev else '-'}")
        d9 = next((i for i in R.c9 if i.key == "d"), None)
        chk("C9(d)：场景 fps 150→80 不算 mod 造成的下降（按开销占比，约 1.7%）", d9 is not None and d9.ok,
            d9.value if d9 else None)
        chk("正常收尾（最后一份 JSON 是 reset 写的）", not R.unclean, str(R.unclean))
        chk("C2/C3 的 d̄ 只用穿越样本（合成数据全是穿越）", R.dbar_late == 0 and len(R.dbar_vals) == len(
            [f for f in R.fires if f.L is not None and f.R0 is not None]), f"late={R.dbar_late}")
        for h in ("离线 1", "开销占帧时间", "REF 截住的访问冲突"):
            chk(f"报告含「{h}」", h in rep)
        chk("C9 四项都给出结论", len(R.c9) == 4)
        for h in ("## 1. 参数表", "## 4. C3", "留一招式交叉验证", "## 7. 空放与漏报归因", "## 8. C8", "## 9. C9",
                  "## 10. C10", "## 11. D", "评估过的候选总数"):
            chk(f"报告含「{h}」", h in rep)

        # 2) 探针 JSON 全丢、rc 也缺一个 seq：全靠日志（没有 SER，影子回放用 TYP 近似）
        d2 = os.path.join(base, "logonly")
        write_dataset(sy, d2, S, probe_json=False)
        data2 = load_data(d2)
        R2 = analyze(data2, strict=True)
        rep2 = render(R2, strict=True)
        with open(os.path.join(base, "report_logonly.md"), "w", encoding="utf-8") as fh:
            fh.write(rep2)
        mism2 = [(f.id, (f.outcome, f.sub), sy.expected.get(f.id)) for f in R2.fires
                 if (f.outcome, f.sub) != sy.expected.get(f.id)]
        chk("日志兜底：探针全部取自日志", data2.info["used_log_only"]["pr"] and R2.ser_mode.startswith("TYP"), R2.ser_mode)
        chk("日志兜底：结局分类不变", not mism2 and len(R2.fires) == n_fire, str(mism2[:6]))
        chk("日志兜底：窗口不变（日志 t 只有 4 位小数，容差 1 ms）",
            abs(R2.ctx.W0 - ctx.W0) < 1e-3 and abs(R2.ctx.W1 - ctx.W1) < 1e-3,
            f"W0 {R2.ctx.W0:.5f}/{ctx.W0:.5f} W1 {R2.ctx.W1:.5f}/{ctx.W1:.5f}")
        chk("日志兜底：F_shadow 用 TYP 近似仍可算", R2.F_shadow_n == 16 and abs((R2.F_shadow or 0) - 0.25) < 1e-9,
            f"n={R2.F_shadow_n} F={R2.F_shadow}")
        chk("日志兜底：报告注明全部取自日志", "全部记录取自日志" in rep2)

        # 2b) 只有 rc（探针整份丢了）：不能把「没看到接触」当空放，全记 UNKNOWN，并触发补测
        d2b = os.path.join(base, "rconly")
        os.makedirs(d2b, exist_ok=True)
        for fn in os.listdir(d1):
            if fn.startswith("AutoParryGS_"):
                shutil.copy(os.path.join(d1, fn), d2b)
        with open(os.path.join(d1, "re2_framework_log.txt"), encoding="utf-8") as fh:
            rc_lines = [ln for ln in fh if "[AutoParryGS]" in ln]
        with open(os.path.join(d2b, "ref.log"), "w", encoding="utf-8") as fh:
            fh.writelines(rc_lines)
        R2b = analyze(load_data(d2b), strict=True)
        render(R2b, strict=True)
        chk("只有 rc：全部放刀记 UNKNOWN、不算空放", all(f.outcome == "UNKNOWN" for f in R2b.fires)
            and R2b.F_actual is None and len(R2b.fires) == n_fire, str(Counter(f.outcome for f in R2b.fires)))
        chk("只有 rc：C10 写明探针数据缺失", any("探针" in r for r in R2b.c10), str(R2b.c10))

        # 2c) 探针中途「停止记录」（菜单开关 / 加载满 90 分钟自停）：区间里探针什么都不记。
        #     区间内的放刀要记 UNKNOWN，不能因为 ±6 s 内还有探针记录就按「没看到接触」判成空放；其余结局不变
        fid_stop = min(fid for fid, (o, _s) in sy.expected.items() if o == "CATCH")
        t_fire = next(kw["t"] for kind, kw in sy.recs["rc"] if kind == "FIRE" and kw["id"] == fid_stop)
        t_stop, t_resume = t_fire - 0.3, t_fire + 1.6
        sy_c = Synth()
        sy_c.recs = {"rc": list(sy.recs["rc"]),
                     "pr": [(k, kw) for k, kw in sy.recs["pr"] if not (t_stop <= kw.get("t", -1e9) <= t_resume)]
                     + [("STOP", {"t": t_stop, "why": "menu"}), ("RESUME", {"t": t_resume, "why": "menu"})]}
        d2c = os.path.join(base, "probe_stop")
        write_dataset(sy_c, d2c, S)
        R2c = analyze(load_data(d2c), strict=True)
        rep2c = render(R2c, strict=True)
        got_stop = next((f.outcome for f in R2c.fires if f.id == fid_stop), None)
        others = [(f.id, (f.outcome, f.sub), sy.expected.get(f.id)) for f in R2c.fires
                  if f.id != fid_stop and (f.outcome, f.sub) != sy.expected.get(f.id)]
        chk("探针停止记录区间内的放刀记 UNKNOWN（不当空放）", got_stop == "UNKNOWN" and len(R2c.ctx.stops) == 1
            and "停止记录」区间 1 段" in rep2c, f"#{fid_stop} → {got_stop}，区间 {R2c.ctx.stops}")
        chk("探针停止记录：其余放刀结局不变", not others and len(R2c.fires) == n_fire, str(others[:6]))

        # 2d) 多个 session：C10 补测只补真怪段、不重做扫描。补测 session 单独分析时窗口只能用先验；
        #     --calib-session 指向第 1 轮后，窗口、T_armor、δ 取自第 1 轮；两个 session 合并时各自做时间关联
        #     （补测 session 的 os.clock 从头开始，时间轴和第 1 轮重叠，不能混在一起）
        S2 = S + 7200
        sy2 = Synth(seed=77)
        sy2.E("pr", "HDR", t=99.0, ver="selftest2", session=S2, net="SOLO", enums="RT{SAFE:0,CAUTION:1,DANGER:2}")
        sy2.E("rc", "HDR", t=99.0, ver="rc-selftest2", session=S2 + 1, auto_parry=True, lead=28, rotation="1",
              scan=False, L_min=18, W_long=60, H_veto=90, credit=1.3)
        t2 = 400.0
        for i in range(6):
            kp = KEEPS[i % 6]
            t2 = sy2.fired(t2, MON1, kp, (20, 24, 28, 32, 36)[i % 5], "normal",
                           r_true=KEEP_OFFSET[kp] + sy2.rng.gauss(0, 0.02))
        tt = 100.0
        while tt < t2:
            sy2.E("pr", "PERF", t=tt, fps=80.0, maxdt=0.02, hooks="msg:80", lua_ms_avg=0.1, lua_ms_max=0.5, tracked=1,
                  red=0, yellow=0, hook_ms_ps=1.0)
            tt += 5.0
        d5 = os.path.join(base, "multi")
        os.makedirs(d5, exist_ok=True)
        for fn in os.listdir(d1):
            if fn.endswith(".json") or fn.endswith(".txt"):
                shutil.copy(os.path.join(d1, fn), d5)
        write_dataset(sy2, d5, S2, drop_rc_seqs=(), write_log=False, old_session=False)
        all5 = load_all(d5)
        n2 = sy2.ids["fire"]
        Rb = analyze(session_data(all5, S2), strict=True)
        chk("补测 session 单独分析：没有扫描 → 窗口用先验，放刀只算它自己的",
            Rb.win_prior and len(Rb.fires) == n2 and abs(Rb.cal.W0 - W_PRIOR[0]) < 1e-9,
            f"prior={Rb.win_prior} fires={len(Rb.fires)}/{n2}")
        Rbc = analyze(session_data(all5, S2), strict=True, calib=[session_data(all5, S)])
        chk("--calib-session：窗口、T_armor、δ 取自第 1 轮，放刀只算补测 session 的",
            not Rbc.win_prior and abs(Rbc.cal.W0 - R.win_scan.W0) < 1e-9 and abs(Rbc.cal.W1 - R.win_scan.W1) < 1e-9
            and Rbc.t_armor is not None and abs(Rbc.t_armor - TRUE_ARMOR) < 0.005 and len(Rbc.fires) == n2,
            f"W0={Rbc.cal.W0} W1={Rbc.cal.W1} T_armor={Rbc.t_armor} fires={len(Rbc.fires)}")
        Rab = analyze([session_data(all5, S), session_data(all5, S2)], strict=True)
        rep_ab = render(Rab, strict=True)
        with open(os.path.join(base, "report_multi.md"), "w", encoding="utf-8") as fh:
            fh.write(rep_ab)
        lab2 = Rab.sessions[1].label
        mism_ab = [(f.sess, f.id, (f.outcome, f.sub)) for f in Rab.fires
                   if (f.outcome, f.sub) != (sy2.expected.get(f.id) if f.sess == lab2 else sy.expected.get(f.id))]
        chk("两个 session 合并：放刀数相加、各自的结局不变、窗口仍取自扫描",
            len(Rab.fires) == n_fire + n2 and not mism_ab and abs(Rab.win_scan.W0 - R.win_scan.W0) < 1e-9,
            f"fires={len(Rab.fires)}/{n_fire + n2} mism={mism_ab[:4]}")
        chk("合并报告写明每个 session 的来源", "多个 session 合并分析" in rep_ab and lab2 in rep_ab)

        # 2e) 两侧 SystemIndex 不是同一套编号（CT 的 em 用 _Context._Em.get_SystemIndex，MSG 用 get_EmSystemIndex）：
        #     接触侧的 sys 键降级后改走共现学习 / 发送者地址，匹配数和基线一样，报告头报警
        remap = {MON1["ec"]: "em20#103", MON2["ec"]: "em7#105", DUMMY["ec"]: "em33#109"}
        for with_snd in (False, True):
            sy_s = Synth()
            sy_s.recs = {"rc": list(sy.recs["rc"]), "pr": []}
            for k_, kw in sy.recs["pr"]:
                kw2 = dict(kw)
                if k_ == "CT":
                    kw2["em"] = remap.get(kw2.get("atk_em"))
                if with_snd and k_ in ("MSG", "EP"):
                    mon = MON1 if kw2.get("em") == MON1["em"] else (MON2 if kw2.get("em") == MON2["em"] else None)
                    if mon:
                        kw2["snd_em"], kw2["snd"] = mon["ec"], "EmGO_" + mon["em"]
                sy_s.recs["pr"].append((k_, kw2))
            d6 = os.path.join(base, "sysidx_snd" if with_snd else "sysidx")
            write_dataset(sy_s, d6, S)
            R6 = analyze(load_data(d6), strict=True)
            rep6 = render(R6, strict=True)
            chk(f"SystemIndex 两侧不一致{'（MSG 带发送者地址）' if with_snd else '（靠共现学习）'}：匹配数和基线一样、报告报警",
                R6.match.matched == R.match.matched and "攻击者身份警报" in rep6
                and Counter(f.outcome for f in R6.fires) == Counter(f.outcome for f in R.fires),
                f"matched {R6.match.matched}/{R.match.matched}")

        # 2f) 进入红状态（RED）才算关键错误：补测、C9(d) 不通过；用户报告崩溃（--crashed）、本 session 日志里的
        #     未处理异常也让 C9(d) 不通过；最后一份 JSON 不是按钮/重置写的 → 提示「未正常收尾」
        sy_r = Synth()
        sy_r.recs = {"rc": list(sy.recs["rc"]), "pr": list(sy.recs["pr"]) + [("RED", {"t": 500.0, "mod": "ACT",
                                                                                     "why": "3in10s"})]}
        d7 = os.path.join(base, "red")
        write_dataset(sy_r, d7, S, last_why="idle",
                      extra_log=["[2026-10-10 20:00:00.000] [REFramework] [error] Unhandled exception 0xC0000005 (crash)"])
        data7 = load_data(d7)
        R7 = analyze(data7, strict=True)
        rep7 = render(R7, strict=True)
        d9r = next((i for i in R7.c9 if i.key == "d"), None)
        chk("RED 记录算关键错误：C10 要补测、C9(d) 不通过", R7.err.red == 1 and any("关键错误" in r for r in R7.c10)
            and d9r is not None and not d9r.ok, f"red={R7.err.red} c10={R7.c10}")
        chk("本 session 日志里的未处理异常算崩溃迹象", len(data7.info.get("crash") or []) == 1 and "崩溃迹象 1 行" in rep7,
            str(data7.info.get("crash")))
        chk("最后一份 JSON 是空闲写的 → 提示未正常收尾", bool(R7.unclean) and "忘了点" in rep7, str(R7.unclean))
        R8 = analyze(data, strict=True, crashed=True)
        d9c = next((i for i in R8.c9 if i.key == "d"), None)
        chk("--crashed：C9(d) 判有崩溃", d9c is not None and not d9c.ok and "用户报告" in d9c.value, d9c.value if d9c else None)

        # 2g) 条目对象被怪物复用：同一 (结果, 条目) 地址先是弹体、后来是近战。属性按回合取，DANGER 连续帧数不跨回合
        sy_e = Synth()
        sy_e.E("pr", "HDR", t=99.0, ver="reuse", session=S, net="SOLO", enums="RT{SAFE:0,CAUTION:1,DANGER:2}")
        sy_e.E("rc", "HDR", t=99.0, ver="reuse", session=S + 1, auto_parry=True, lead=28, rotation="0", scan=False,
               L_min=18, W_long=60, H_veto=90, credit=1.3)
        sy_e.act(399.0, (2, 21))
        OBJ, ENT = "2B0000000040", "2B0000000080"
        sy_e.episode(400.0, MON1, (1, 10), [{"ent": ENT, "hs0": 60.0, "width": 10, "shell": "2"}], lambda t: True,
                     obj=OBJ)
        sy_e.episode(403.0, MON1, (0, 55), [{"ent": ENT, "hs0": 60.0, "width": 10}], lambda t: True, obj=OBJ)
        d8 = os.path.join(base, "reuse")
        write_dataset(sy_e, d8, S, drop_rc_seqs=(), old_session=False)
        ents8, _bo = build_entries(load_data(d8))
        e8 = ents8.get((OBJ, ENT))
        chk("条目复用：弹体属性只属于上一招，这一招按自己的 ENT 判", e8 is not None and entry_shell(e8, 400.2) is True
            and entry_shell(e8, 403.2) is False, str(e8 and [a.get("shell") for a in e8.attrs_list]))
        run8 = danger_run_frames(e8, 403.5, lo=403.0 - 0.05) if e8 else None
        run8b = danger_run_frames(e8, 403.5) if e8 else None
        chk("条目复用：DANGER 连续帧数不跨回合（约 31 帧，不是 31+上一招的）", run8 is not None and 25 <= run8 <= 35
            and run8b is not None and 25 <= run8b <= 35, f"lo={run8} 无lo={run8b}")

        # 1.1-a) 第 1 轮（轮换标定）合成数据上的 D：标定轮只作预览、不截断；不计先砍中打断的空放率和 C7 同一算法
        kn_, nn_ = R.d_whiff_noint
        chk("1.1 标定轮：D 模式 calibration、不截断、判定只作预览",
            R.d_mode == "calibration" and R.d_cut is None and "标定轮，只作预览" in rep and "D 验收判定" in rep,
            f"{R.d_mode} cut={R.d_cut}")
        chk("1.1 标定轮：D 不计先砍中打断的空放率 = C7 的不计 INTERRUPTED 版",
            nn_ > 0 and R.F_actual_noint is not None and abs(kn_ / nn_ - R.F_actual_noint) < 1e-9,
            f"{kn_}/{nn_} vs {R.F_actual_noint}")
        chk("1.1 STAT 累计计数：清零过的按增量累加", stat_total([{"x": 0}, {"x": 2}, {"x": 5}, {"x": 1}, {"x": None},
                                                       {"x": 3}], "x") == (8, 5)
            and stat_total([{"y": 1}], "x") == (None, 0))

        # 1.1-b) 第 2 轮（v1.5 发布版）：CFG 截断、发布版 HDR、D 判定、STAT replica/readerr、按 HDR 的 L_min 归因漏报
        S15 = S + 20000
        sy15 = build_synth_v15(S15)
        d15 = os.path.join(base, "v15")
        write_dataset(sy15, d15, S15, drop_rc_seqs=(), old_session=False)
        data15 = load_data(d15)
        R15 = analyze(data15, strict=True)
        rep15 = render(R15, strict=True)
        with open(os.path.join(base, "report_v15.md"), "w", encoding="utf-8") as fh:
            fh.write(rep15)
        c15 = R15.d_sess[0].cfg if R15.d_sess else None
        chk("1.1 v1.5 HDR（ver=1.5、rotation=0、scan=0）认成发布版：报告标题是第 2 轮验收、开头有验收摘要",
            R15.d_mode == "release" and rep15.startswith("# 自动放刀第 2 轮验收报告") and "## 验收摘要" in rep15
            and "发布版（提前量 L=26" in rep15 and "攻击者身份警报" not in rep15, R15.d_mode)
        chk("1.1 CFG：和上一状态相同的那条不算改动，第一次真改动（提前量 26→30）是截断点；最后只关开关的那条不截断（1.2）",
            c15 is not None and c15.cut_src == "CFG" and abs(c15.cut - sy15.t_cfg) < 1e-6 and len(c15.noops) == 1
            and len(c15.changes) == 1 and len(c15.toggles) == 1 and "提前量 26→30" in rep15,
            f"src={c15 and c15.cut_src} cut={c15 and c15.cut} 真值 {sy15.t_cfg} noop={c15 and len(c15.noops)} "
            f"changes={c15 and len(c15.changes)} toggles={c15 and len(c15.toggles)}")
        chk("1.1 D 只用改动前的放刀：接住 14/16、空放 5/21、不计先砍中打断 3/19",
            len(R15.d_sess[0].fires) == sy15.n_pre == len(V15_PLAN) and R15.d_catch == (14, 16)
            and R15.d_whiff == (5, 21) and R15.d_whiff_noint == (3, 19) and R15.d_int == 2,
            f"fires={len(R15.d_sess[0].fires)} catch={R15.d_catch} whiff={R15.d_whiff} noint={R15.d_whiff_noint}")
        # 1.2 的判定项：接住、空放、帧率、放刀模块关键错误、探针数据质量、协议（两只怪、新怪、无限蓄力）、观感
        chk("1.2 D 判定：离线各项通过；协议两只怪（em20、em42 各 ≥10 个 DANGER 回合）和无限蓄力通过，新怪（没有定标 "
            "session）和观感待确认，结论「离线各项通过…确认后验收通过」",
            R15.d_verdict == "离线各项通过" and [d_item_result(i) for i in R15.d_items]
            == ["通过"] * 5 + ["通过", "待用户确认", "通过", "待用户确认"] and R15.d_protocol.counted == [20, 42]
            and "确认后验收通过" in rep15, f"{R15.d_verdict} {[d_item_result(i) for i in R15.d_items]} "
                                       f"counted={R15.d_protocol.counted}")
        chk("1.1 D 的 PERF 只用改动前的周期", R15.d_sess[0].perf is not None and R15.perf[0][1] is not None
            and R15.d_sess[0].perf.n < R15.perf[0][1].n and "D 只用参数改动前、开关开着的 PERF" in rep15)
        chk("1.2 发布版报告：第 9 节只作复核（不出第 1 轮的三选一），参数表默认列是 V15 冻结值",
            "把上面的数字交给用户，三选一" not in rep15 and "V15 冻结 26" in rep15 and "V15 冻结 22" in rep15 and "默认 28" not in rep15
            and "数据范围同第 11 节 D" in rep15)
        mc15 = Counter(cls for a, cls in R15.misses.detail if a.t < c15.cut) if R15.misses else Counter()
        chk("1.1 参数冻结的 session 按 HDR 的 L_min=22 归因漏报：hs=19.5 的那招是「低于 L_min」，不是「其他」",
            mc15.get(MISS_CLASSES[3]) == 1 and not mc15.get(MISS_CLASSES[7]) and R15.sessions[0].miss_params.lmin == 22,
            str(dict(mc15)))
        per15 = R15.d_per
        chk("1.1 按怪覆盖率：全场无预告的怪也列出（em99：放刀 0、漏报 1、覆盖率 0%），新怪 em42 有自己的一行",
            per15.get(99, {}).get("放刀", 0) == 0 and per15.get(99, {}).get("漏报") == 1 and "0%（0/1）" in rep15
            and per15.get(42, {}).get("接住") == 2 and R15.d_miss_by.get(99, {}).get(MISS_CLASSES[0]) == 1,
            str({k: dict(v) for k, v in per15.items()}))
        chk("1.1 启用开关关着时挨打不算漏报（另计）", R15.misses is not None and len(R15.misses.off) == 1
            and R15.d_off == 0, f"off={len(R15.misses.off) if R15.misses else None}")
        st15 = R15.d_stat[0] if R15.d_stat else None
        chk("1.1 STAT replica/readerr：解析、清零后累加（3 / 1）、诊断展示和联机副本警告",
            st15 is not None and st15.replica[0] == 3 and st15.readerr[0] == 1 and len(st15.items) == 1
            and "联机副本闸门" in rep15 and "条目逐条读取出错" in rep15 and "**联机副本**" in rep15
            and "兜底 None" not in rep15 and "联机副本跳过 1 条目读取错误 0" in rep15,
            f"{st15 and (st15.replica, st15.readerr, len(st15.items))}")
        chk("1.1 没给定标 session：提示用 --calib-session/--calib-dir 取第 1 轮", R15.win_prior
            and "--calib-session 1791644664 --calib-dir tools/out/round1_data" in rep15)
        chk("1.1 协议核对：怪物、新怪、无限蓄力（探针 HDR 里是关的）", "协议核对" in rep15
            and R15.d_protocol.ems == [20, 42] and R15.d_protocol.inf[0][1] is False and "请向用户确认" not in rep15,
            str(R15.d_protocol.ems))

        # 1.1-c) --calib-session + --calib-dir：窗口、T_armor、δ 取第 1 轮（另一个目录）；D 的数字不变；新怪核对
        Rc = analyze(load_data(d15), strict=True, calib=[session_data(load_all(d1), S)])
        repc = render(Rc, strict=True)
        chk("1.1 定标取自另一个目录的第 1 轮：窗口、T_armor 同第 1 轮，D 的数字和不定标时一样",
            not Rc.win_prior and abs(Rc.cal.W0 - R.win_scan.W0) < 1e-9 and abs(Rc.cal.W1 - R.win_scan.W1) < 1e-9
            and Rc.t_armor is not None and abs(Rc.t_armor - TRUE_ARMOR) < 0.005 and Rc.d_catch == R15.d_catch
            and Rc.d_whiff == R15.d_whiff and len(Rc.fires) == sy15.ids["fire"] and "**提示**" not in repc,
            f"W0={Rc.cal.W0} T_armor={Rc.t_armor} catch={Rc.d_catch}")
        chk("1.1 协议核对：和定标 session 比出新怪 em42", Rc.d_protocol.new == [42], str(Rc.d_protocol.new))
        out_c = os.path.join(base, "report_v15_calib.md")
        rc_main = main([d15, "--calib-session", str(S), "--calib-dir", d1, "--out", out_c])
        with open(out_c, encoding="utf-8") as fh:
            rep_main = fh.read()
        chk("1.1 命令行 --calib-dir 跑通、报告写明定标 session", rc_main == 0 and "（定标）" in rep_main
            and "## 验收摘要" in rep_main and "**提示**" not in rep_main)
        Rm = analyze(load_data(d15), strict=True, calib=[session_data(load_all(d15), 12345)])
        chk("1.1 定标 session 号不对：报告头写明没读到、退回先验", Rm.calib_missing == [12345] and Rm.win_prior
            and "定标 session 没读到任何记录" in render(Rm, strict=True))

        # 1.1-d) CFG 只在日志里（rc 的 JSON 全丢）：照样解析、截断
        d15l = os.path.join(base, "v15_rclog")
        write_dataset(sy15, d15l, S15, drop_rc_seqs=range(1, 1000), old_session=False)
        R15l = analyze(load_data(d15l), strict=True)
        c15l = R15l.d_sess[0].cfg
        chk("1.1 CFG / STAT 新字段从日志解析（rc 没有 JSON）：截断点和 D 的数字不变",
            R15l.data.info["used_log_only"]["rc"] and c15l.cut_src == "CFG" and abs(c15l.cut - sy15.t_cfg) < 1e-3
            and R15l.d_catch == R15.d_catch and R15l.d_whiff == R15.d_whiff and R15l.d_stat[0].replica[0] == 3,
            f"src={c15l.cut_src} cut={c15l.cut} catch={R15l.d_catch} replica={R15l.d_stat[0].replica}")

        # 1.1-e) 没有 CFG：按 FIRE.L≠HDR.lead 推断截断（1.0 的兜底）；改动后 L 也没变：推断不出来、不截断 → 空放超线
        sy15n = build_synth_v15(S15, cfg=False)
        d15n = os.path.join(base, "v15_nocfg")
        write_dataset(sy15n, d15n, S15, drop_rc_seqs=(), old_session=False)
        R15n = analyze(load_data(d15n), strict=True)
        c15n = R15n.d_sess[0].cfg
        f_first30 = next(f for f in R15n.fires_all if f.L == 30)
        chk("1.1 没有 CFG：按第一个 FIRE.L≠HDR.lead 截断（推断），D 的数字和有 CFG 时一样",
            c15n.cut_src == "推断" and abs(c15n.cut - f_first30.t_req) < 1e-9 and R15n.d_catch == (14, 16)
            and R15n.d_whiff == (5, 21) and "推断：放刀 #" in render(R15n, strict=True),
            f"src={c15n.cut_src} catch={R15n.d_catch} whiff={R15n.d_whiff}")
        sy15x = build_synth_v15(S15, cfg=False, change_lead=False)
        d15x = os.path.join(base, "v15_nocut")
        write_dataset(sy15x, d15x, S15, drop_rc_seqs=(), old_session=False)
        R15x = analyze(load_data(d15x), strict=True)
        rep15x = render(R15x, strict=True)
        chk("1.1 截断不了时全部数据参与：空放 8/25 > 25% → D 不通过；1.2 第 9 节 C9 复核也没过，但不出第 1 轮的三选一",
            R15x.d_sess[0].cut is None and R15x.d_whiff == (8, 25) and R15x.d_verdict == "不通过"
            and "**D 结论：不通过。**" in rep15x and "C9 复核有未通过" in rep15x and "把上面的数字交给用户，三选一" not in rep15x
            and "B 提示模式：同一规则" not in rep15x,
            f"cut={R15x.d_sess[0].cut} whiff={R15x.d_whiff} {R15x.d_verdict}")
        # 同一目录里有两次加载（中途 Reset）：默认只分析最新的，报告头提示用 --session 合并。
        # 1.2：合并时按加载先后，第一次加载里已经改过参数（CFG 26→30），第二次加载整段不计（改动会存进配置带过去）——
        # 1.1 各自截断、把第二次加载改动前的数据也算进来，D 数字是 28/32、10/42
        d15m = os.path.join(base, "v15_two")
        write_dataset(sy15, d15m, S15, drop_rc_seqs=(), old_session=False)
        write_dataset(sy15n, d15m, S15 + 5000, drop_rc_seqs=(), write_log=False, old_session=False)
        all15 = load_all(d15m)
        R15m = analyze(session_data(all15), strict=True)
        rep15m = render(R15m, strict=True)
        R15mm = analyze([session_data(all15, S15 + 5000), session_data(all15, S15)], strict=True)
        rep15mm = render(R15mm, strict=True)
        chk("1.2 两次加载：报告头提示还有别的 session；--session 合并（给的顺序倒过来也一样）按加载先后，第一次已改过参数 → "
            "第二次整段不计，D 只有第一次改动前的 14/16、5/21",
            "还有别的 rc session [1760020001]" in rep15m and len(R15mm.d_sess) == 2
            and [d.cfg.cut_src for d in R15mm.d_sess] == ["CFG", "推断"] and R15mm.d_sess[0].excluded is None
            and "更早加载的 session" in (R15mm.d_sess[1].excluded or "") and R15mm.d_catch == (14, 16)
            and R15mm.d_whiff == (5, 21) and "这次加载整段不计入 D" in rep15mm,
            f"{[d.cfg.cut_src for d in R15mm.d_sess]} {R15mm.d_catch} {R15mm.d_whiff} {R15mm.d_sess[1].excluded}")
        # 1.2：发布版加载时 HDR 的提前量就不是冻结值 26（上次加载拖过滑块、存进了配置）：整段不计
        sy30 = build_synth_v15(S15, cfg=False, change_lead=False, lead0=30)
        d30 = os.path.join(base, "v15_lead30")
        write_dataset(sy30, d30, S15, drop_rc_seqs=(), old_session=False)
        R30 = analyze(load_data(d30), strict=True)
        rep30 = render(R30, strict=True)
        chk("1.2 发布版 HDR lead=30（加载时就不是 V15 冻结值）：整段不计，D 放刀 0 → 样本不足，报告写明原因",
            "不是 V15 冻结值" in (R30.d_sess[0].excluded or "") and "提前量=30（冻结值 26）" in rep30
            and R30.d_catch == (0, 0) and R30.d_whiff == (0, 0) and R30.d_verdict == "样本不足"
            and "这次加载整段不计入 D" in rep30, f"{R30.d_sess[0].excluded} {R30.d_catch} {R30.d_verdict}")
        d30m = os.path.join(base, "v15_then30")
        write_dataset(sy15x, d30m, S15, drop_rc_seqs=(), old_session=False)
        write_dataset(sy30, d30m, S15 + 5000, drop_rc_seqs=(), write_log=False, old_session=False)
        all30 = load_all(d30m)
        R30m = analyze([session_data(all30, S15), session_data(all30, S15 + 5000)], strict=True)
        chk("1.2 两次加载、第一次没改过参数、第二次 HDR lead=30：第二次整段不计，D 只有第一次的 15/17、8/25",
            R30m.d_sess[0].excluded is None and "不是 V15 冻结值" in (R30m.d_sess[1].excluded or "")
            and R30m.d_catch == (15, 17) and R30m.d_whiff == (8, 25),
            f"{[d.excluded for d in R30m.d_sess]} {R30m.d_catch} {R30m.d_whiff}")
        # 1.2：加载时开关关着（第 1 轮后关掉正常玩），开局在菜单打开 —— 只改开关的 CFG 不截断，之后的放刀照常计入 D；
        # 截断点仍是提前量改动；关着那段的 PERF 不进 D 的帧率
        syo = build_synth_v15(S15, start_off=True)
        do = os.path.join(base, "v15_start_off")
        write_dataset(syo, do, S15, drop_rc_seqs=(), old_session=False)
        Ro = analyze(load_data(do), strict=True)
        repo = render(Ro, strict=True)
        co = Ro.d_sess[0].cfg
        po = Ro.d_sess[0].perf
        chk("1.2 加载时开关关、开局在菜单打开（CFG 关→开）：不截断，截断点仍是提前量 26→30，D 和开关一直开着时一样",
            co.cut_src == "CFG" and abs(co.cut - syo.t_cfg) < 1e-6 and len(co.toggles) == 2 and len(co.changes) == 1
            and Ro.d_catch == (14, 16) and Ro.d_whiff == (5, 21) and Ro.d_verdict == "离线各项通过"
            and "加载时关着" in repo,
            f"src={co.cut_src} cut={co.cut} toggles={len(co.toggles)} catch={Ro.d_catch} whiff={Ro.d_whiff} {Ro.d_verdict}")
        po_all = perf_check(load_data(do), co.cut)
        chk("1.2 开关关着那段的 PERF 不进 D 的帧率", po is not None and po_all is not None and po.n < po_all.n,
            f"D {po and po.n} / 改动前全部 {po_all and po_all.n}")
        mo = Counter(cls for a, cls in Ro.misses.detail) if Ro.misses else Counter()
        chk("1.2 预告在开关关着时就来了、接触在打开之后：不算漏报（另计 off；另一次 off 是最后关掉开关后挨打，在截断点之后），"
            "漏报归因和按怪统计都没有它",
            Ro.misses is not None and len(Ro.misses.off) == 2 and Ro.d_off == 1 and not mo.get(MISS_CLASSES[7])
            and "预告在关着时就来了" in repo, f"off={len(Ro.misses.off) if Ro.misses else None} d_off={Ro.d_off} {dict(mo)}")
        # 1.2：D 的关键错误只算放刀模块的 RED；探针的 RED 是数据质量问题 → 需复核（不判 v1.5 不通过）
        for src_red, want in (("pr", "需复核"), ("rc", "不通过")):
            sy_x = Synth()
            sy_x.recs = {"rc": list(sy15.recs["rc"]), "pr": list(sy15.recs["pr"])}
            sy_x.recs[src_red].append(("RED", {"t": 450.0, "mod": "ACT" if src_red == "pr" else "frame", "why": "3in10s"}))
            dx = os.path.join(base, "v15_red_" + src_red)
            write_dataset(sy_x, dx, S15, drop_rc_seqs=(), old_session=False)
            Rx = analyze(load_data(dx), strict=True)
            repx = render(Rx, strict=True)
            chk(f"1.2 {'探针' if src_red == 'pr' else '放刀模块'}进入红状态：D 结论「{want}」",
                Rx.d_verdict == want and (("**D 结论：需复核。**" in repx and "探针红 1" in repx) if src_red == "pr"
                                          else ("放刀模块红 1" in repx and "探针红 0" in repx)),
                f"{Rx.d_verdict} {[d_item_result(i) for i in Rx.d_items]}")
        # 1.2：协议进判定 —— 新怪只打了 2 招（D 范围内 DANGER 回合 <10）：只算打过一只怪 → 样本不足
        sy1 = build_synth_v15(S15, mon4_shadows=0)
        d1m = os.path.join(base, "v15_one_monster")
        write_dataset(sy1, d1m, S15, drop_rc_seqs=(), old_session=False)
        R1m = analyze(load_data(d1m), strict=True)
        rep1m = render(R1m, strict=True)
        chk("1.2 协议：D 范围内只有一只怪打够 10 个 DANGER 回合 → 样本不足（不写「确认后验收通过」）",
            R1m.d_catch == (14, 16) and R1m.d_protocol.counted == [20] and R1m.d_verdict == "样本不足"
            and "确认后验收通过" not in rep1m and "两只出招风格不同的怪" in rep1m,
            f"{R1m.d_protocol.counted} {R1m.d_verdict}")
        Rc1 = analyze(load_data(d1m), strict=True, calib=[session_data(load_all(d1), S)])
        chk("1.2 协议：有定标 session 时，打够的怪里没有新怪（em20 第 1 轮打过）→ 新怪一项样本不足",
            Rc1.d_protocol.new_counted == [] and any(i.name.startswith("协议：其中一只是新怪") and i.insufficient
                                                     for i in Rc1.d_items), str(Rc1.d_protocol.new_counted))

        # 1.3-a) 冻结参数按版本（V15 第 9 节）：1.5 → 26，1.5.1 及以后 → 30；认不出来的版本号按 1.5
        # 1.4：1.6 起是 28（V16 第 7 节第 2 条；1.3 写这条时 1.6 还没有自己的冻结值，沿用 30）
        chk("1.3 冻结的提前量按版本：1.5→26、1.5.1→30、1.6→28（1.4 起）、认不出来按 26；L_min/W_long/H_veto 不变",
            [frozen_table(v)[0][2] for v in ("1.5", "1.5.1", "1.6", "1.5-rc1", "selftest")] == [26, 30, 28, 26, 26]
            and all(frozen_table(v)[1:] == FROZEN[1:] for v in ("1.5", "1.5.1")) and version_tuple("1.5-rc1") is None
            and release_defaults("1.5.1")["L"] == 30 and release_defaults("1.5") == V15_DEFAULTS,
            str([frozen_table(v)[0][2] for v in ("1.5", "1.5.1", "1.6", "1.5-rc1", "selftest")]))
        # 1.3-b) 1.5.1 发布版（HDR lead=30）：冻结、不整段不计；D 的数字同 1.5 的合成数据；标题、参数表按 1.5.1；
        #        抓取：蓄力中被抓、别的怪抓取正在来时被打 → 两次「被抓取规则否决」；VETO 的 why 解析（grab 2、long 1）
        sy151 = build_synth_v15(S15, ver="1.5.1", lead0=30, grab_eps=True)
        d151 = os.path.join(base, "v151")
        write_dataset(sy151, d151, S15, drop_rc_seqs=(), old_session=False)
        R151 = analyze(load_data(d151), strict=True)
        rep151 = render(R151, strict=True)
        with open(os.path.join(base, "report_v151.md"), "w", encoding="utf-8") as fh:
            fh.write(rep151)
        c151 = R151.d_sess[0].cfg if R151.d_sess else None
        chk("1.3 1.5.1 发布版 HDR lead=30：是冻结值、D 不整段不计，标题和参数表按 1.5.1（默认列 30）",
            R151.d_mode == "release" and c151 is not None and c151.grab and R151.d_sess[0].excluded is None
            and rep151.startswith("# 自动放刀第 2 轮验收报告（v1.5.1 离线分析）") and "发布版（提前量 L=30" in rep151
            and "V15 冻结 30" in rep151 and "V15 第 9 节 v1.5.1：L=30" in rep151 and "整段不计入 D" not in rep151
            and R151.d_catch == (14, 16) and R151.d_whiff == (5, 21),
            f"{R151.d_mode} excl={R151.d_sess[0].excluded if R151.d_sess else None} catch={R151.d_catch} whiff={R151.d_whiff}")
        mc151 = Counter(cls for a, cls in R151.misses.detail if a.t < c151.cut) if R151.misses and c151 else Counter()
        chk("1.3 1.5.1 漏报归因：自己被抓 + 跨怪抓取否决 → 「被抓取规则否决」2，hs=19.5 那招仍是「低于 L_min」，没有「其他」",
            mc151.get(MISS_GRAB) == 2 and mc151.get(MISS_CLASSES[3]) == 1 and not mc151.get(MISS_CLASSES[7])
            and "| 被抓取规则否决 | 2 |" in rep151 and "另有抓取否决" in rep151, str(dict(mc151)))
        chk("1.3 VETO 的 why 解析：grab 2、long 1，诊断里写出来",
            R151.veto_why == Counter({"grab": 2, "long": 1}) and "长窗口 1、抓取 2" in rep151
            and all(r.get("why") in ("grab", "long") for r in R151.data.get("rc", "VETO")), str(R151.veto_why))
        # 1.3 修订（第 1 轮审查）：影子回放按 rc 的口径数否决段（蓄力中、开关开着，连续否决合成一段，段首取 hs 最小的条目
        # 定原因），和 rc 的 VETO 并列：合成数据里长窗口那段 SER 里有对应条目（long_hold），两边都是 grab 2、long 1
        chk("1.3 影子否决段按 rc 的口径数：抓取 2、长窗口 1，和 rc 的 VETO 一致，诊断里并列写出（不再拿漏报数去比）",
            R151.veto_shadow == Counter({"grab": 2, "long": 1}) and R151.veto_shadow_n == 1
            and "和这些 session 的 VETO 一致" in rep151 and "可对照" not in rep151,
            f"影子 {R151.veto_shadow} rc {R151.veto_shadow_rc}")
        # 1.3 修订：VETO 的 why 从日志补（带 VETO 的那几份 rc JSON 丢了），解析结果和读 JSON 一样
        rc_sorted = sorted(sy151.recs["rc"], key=lambda kv: kv[1].get("t", 0.0))
        rc_t0 = rc_sorted[0][1].get("t", 0.0)
        rc_seqs = sorted({1 + int((kw.get("t", rc_t0) - rc_t0) // 60.0) for _k, kw in rc_sorted})
        veto_seqs = {1 + int((kw.get("t", rc_t0) - rc_t0) // 60.0) for k, kw in rc_sorted if k == "VETO"}
        d151l = os.path.join(base, "v151_veto_log")
        write_dataset(sy151, d151l, S15, drop_rc_seqs=tuple(rc_seqs.index(s) + 1 for s in sorted(veto_seqs)),
                      old_session=False)
        R151l = analyze(load_data(d151l), strict=True)
        vl = R151l.data.get("rc", "VETO")
        chk("1.3 VETO 的 why 从日志补（带 VETO 的 rc JSON 丢了）：照样解析出 grab 2、long 1，按 1.5.1 归因",
            R151l.veto_why == Counter({"grab": 2, "long": 1}) and len(vl) == 3 and all(r.get("_o") == "log" for r in vl)
            and R151l.d_sess[0].cfg.grab
            and Counter(cls for a, cls in R151l.misses.detail if a.t < R151l.d_sess[0].cfg.cut).get(MISS_GRAB) == 2,
            f"{R151l.veto_why} {[r.get('_o') for r in vl]}")
        # 1.3 修订：HDR 的版本号认不出来（带后缀），但 VETO 带 why → 也认作 1.5.1 起（抓取否决照用）
        sy_vx = Synth()
        sy_vx.recs = {"pr": list(sy151.recs["pr"]),
                      "rc": [(k, dict(kw, ver="1.5.1-test") if k == "HDR" else kw) for k, kw in sy151.recs["rc"]]}
        d_vx = os.path.join(base, "v151_ver_unknown")
        write_dataset(sy_vx, d_vx, S15, drop_rc_seqs=(), old_session=False)
        R_vx = analyze(load_data(d_vx), strict=True)
        c_vx = R_vx.d_sess[0].cfg if R_vx.d_sess else None
        chk("1.3 HDR ver=1.5.1-test（版本号认不出来）但 VETO 带 why：认作有抓取否决，漏报照样归「被抓取规则否决」2",
            c_vx is not None and version_tuple(c_vx.ver) is None and c_vx.grab and R_vx.grab_rule
            and Counter(cls for a, cls in R_vx.misses.detail if a.t < c_vx.cut).get(MISS_GRAB) == 2,
            f"ver={c_vx.ver if c_vx else None} grab={c_vx.grab if c_vx else None}")
        # 1.3 修订：抓取否决区间的三个边界（影子回放）：视野外（hs>H_veto）的抓取、已打完（he<0）的抓取都不否决 →
        # 漏报归「其他」；长窗口和抓取同时在否决 → 归「被长窗口规则否决」；原来那两次仍归「被抓取规则否决」。
        # 影子否决段多出 grab 1（视野外那条降到 90 以后）、long 1（重叠那段，两条 hs 一样记 long）、grab 2（否决中途
        # 松开又按住，按蓄力断成两段），和 rc 的 VETO 一致
        sy151e = build_synth_v15(S15, ver="1.5.1", lead0=30, grab_eps=True, grab_edges=True)
        d151e = os.path.join(base, "v151_edges")
        write_dataset(sy151e, d151e, S15, drop_rc_seqs=(), old_session=False)
        R151e = analyze(load_data(d151e), strict=True)
        rep151e = render(R151e, strict=True)

        def miss_cls(R, tc):
            return [cls for a, cls in (R.misses.detail if R.misses else []) if abs(a.t - tc) < 1e-3]
        te = sy151e.t_edges
        c151e = R151e.d_sess[0].cfg if R151e.d_sess else None
        mc151e = Counter(cls for a, cls in R151e.misses.detail if a.t < c151e.cut) if R151e.misses and c151e else Counter()
        chk("1.3 抓取否决区间的边界：视野外（hs>H_veto）、已打完（he<0）的抓取不否决 → 漏报归「其他」；长窗口和抓取同时否决 → "
            "归「被长窗口规则否决」；原来两次仍归「被抓取规则否决」",
            miss_cls(R151e, te["far"]) == [MISS_CLASSES[7]] and miss_cls(R151e, te["past"]) == [MISS_CLASSES[7]]
            and miss_cls(R151e, te["both"]) == [MISS_CLASSES[5]] and mc151e.get(MISS_GRAB) == 2
            and mc151e.get(MISS_CLASSES[7]) == 2 and mc151e.get(MISS_CLASSES[5]) == 1,
            f"far={miss_cls(R151e, te['far'])} past={miss_cls(R151e, te['past'])} both={miss_cls(R151e, te['both'])} "
            f"{dict(mc151e)}")
        chk("1.3 影子否决段（含三个边界、松开又按住）：抓取 5、长窗口 2，和 rc 的 VETO 一致",
            R151e.veto_shadow == Counter({"grab": 5, "long": 2}) and R151e.veto_why == Counter({"grab": 5, "long": 2})
            and "和这些 session 的 VETO 一致" in rep151e, f"影子 {R151e.veto_shadow} rc {R151e.veto_why}")
        # 1.3-c) 同样的数据当 1.5 的 session（没有抓取否决、VETO 不带 why）：抓取不排除、不否决 → 两次漏报归「其他」，
        #        表里不出「被抓取规则否决」，诊断里不写 VETO 的 why（1.5 的报告和 1.2 一样）
        sy15g = build_synth_v15(S15, ver="1.5", lead0=26, grab_eps=True)
        d15g = os.path.join(base, "v15_grab")
        write_dataset(sy15g, d15g, S15, drop_rc_seqs=(), old_session=False)
        R15g = analyze(load_data(d15g), strict=True)
        rep15g = render(R15g, strict=True)
        c15g = R15g.d_sess[0].cfg if R15g.d_sess else None
        mc15g = Counter(cls for a, cls in R15g.misses.detail if a.t < c15g.cut) if R15g.misses and c15g else Counter()
        chk("1.3 1.5 的 session 不套抓取规则：两次抓取相关的漏报归「其他」，报告没有抓取的行，VETO 不带 why",
            c15g is not None and not c15g.grab and not mc15g.get(MISS_GRAB) and mc15g.get(MISS_CLASSES[7]) == 2
            and "| 被抓取规则否决 |" not in rep15g and "另有抓取否决" not in rep15g and "rc 的 VETO（" not in rep15g
            and R15g.veto_why == Counter({"—": 1})
            and rep15g.startswith("# 自动放刀第 2 轮验收报告（v1.5 离线分析）"), f"{dict(mc15g)} {R15g.veto_why}")
        # 1.3-d) 1.5.1 发布版加载时 HDR lead=26（v1.5 的冻结值，但不是 1.5.1 的）：整段不计
        sy151x = build_synth_v15(S15, cfg=False, change_lead=False, lead0=26, ver="1.5.1")
        d151x = os.path.join(base, "v151_lead26")
        write_dataset(sy151x, d151x, S15, drop_rc_seqs=(), old_session=False)
        R151x = analyze(load_data(d151x), strict=True)
        rep151x = render(R151x, strict=True)
        chk("1.3 1.5.1 发布版 HDR lead=26（不是 1.5.1 的冻结值 30）：整段不计，报告写「提前量=26（冻结值 30）」",
            "不是 V15 冻结值" in (R151x.d_sess[0].excluded or "") and "提前量=26（冻结值 30）" in rep151x
            and R151x.d_catch == (0, 0) and R151x.d_verdict == "样本不足", f"{R151x.d_sess[0].excluded} {R151x.d_verdict}")
        # 1.3-e) 1.5 和 1.5.1 两次加载合并：各按自己版本的冻结值判断（都不整段不计），报告头警告合并了不同版本
        d_mix = os.path.join(base, "v15_v151")
        write_dataset(sy15x, d_mix, S15, drop_rc_seqs=(), old_session=False)
        write_dataset(build_synth_v15(S15, cfg=False, change_lead=False, lead0=30, ver="1.5.1"), d_mix, S15 + 5000,
                      drop_rc_seqs=(), write_log=False, old_session=False)
        all_mix = load_all(d_mix)
        R_mix = analyze([session_data(all_mix, S15), session_data(all_mix, S15 + 5000)], strict=True)
        rep_mix = render(R_mix, strict=True)
        chk("1.3 1.5 + 1.5.1 合并：两次加载都按自己的冻结值（26 / 30）不整段不计，标题写 v1.5.1，报告头警告合并了不同版本",
            [d.excluded for d in R_mix.d_sess] == [None, None] and "合并了不同版本的发布版 session**（1.5、1.5.1）" in rep_mix
            and "提前量 26/30" in rep_mix and rep_mix.startswith("# 自动放刀第 2 轮验收报告（v1.5.1 离线分析）"),
            str([d.excluded for d in R_mix.d_sess]))

        # ======================== 1.4（v1.6，V16 第 7 节）
        # 1.4-a) 版本识别：1.6 → E5c/g1、冻结 28；1.6 之后沿用 1.6；版本号认不出、HDR 带 rule=E5c → 1.6；认不出又没有 rule → 按 1.5；
        #        v1.6 的冻结值另有 rule / filter
        def cfg_of(ver, rule=None, filt="g1", lead=28):
            d_ = Data()
            d_.by[("rc", "HDR")].append({"k": "HDR", "_src": "rc", "_o": "json", "t": 99.0, "ver": ver, "lead": lead,
                                         "L_min": 22.0, "W_long": 60.0, "H_veto": 90.0, "rotation": "0", "scan": False,
                                         "rule": rule, "filter": filt, "auto_parry": True})
            return rc_config(d_)
        c16, c17, cdev, cdev0 = cfg_of("1.6", "E5c"), cfg_of("1.7", "E5c"), cfg_of("1.6-dev", "E5c"), cfg_of("1.6-dev")
        cbadf, c151v = cfg_of("1.6", "E5c", "g0"), cfg_of("1.5.1", None, None, 30)
        chk("1.4 版本识别：1.6 → E5c、该接过滤、冻结提前量 28；1.7 沿用 1.6；1.6-dev 带 rule=E5c 按 1.6；1.6-dev 没有 rule 按 1.5"
            "（26、不是 E5c）；v1.6 的冻结值另核对 rule / filter（filter=g0 判不是冻结值）；1.5.1 不变",
            c16.e5c and c16.g1 and frozen_table(c16.ver, c16.rule)[0][2] == 28 and not frozen_mismatch(c16)
            and c17.e5c and frozen_table("1.7")[0][2] == 28 and not frozen_mismatch(c17)
            and cdev.e5c and cdev.vt == (1, 6) and frozen_table(cdev.ver, cdev.rule)[0][2] == 28
            and not cdev0.e5c and frozen_table(cdev0.ver, cdev0.rule)[0][2] == 26
            and any("filter=g0" in b for b in frozen_mismatch(cbadf))
            and not c151v.e5c and c151v.grab and not frozen_mismatch(c151v),
            f"{(c16.e5c, c17.e5c, cdev.e5c, cdev0.e5c)} {frozen_mismatch(cbadf)} {frozen_mismatch(c151v)}")
        # 1.4-b) 精确二项区间
        cp0, cp5, cp10 = clopper_pearson(0, 10), clopper_pearson(5, 10), clopper_pearson(10, 10)
        chk("1.4 Clopper–Pearson 90% 区间：0/10 → 0~0.2589、5/10 → 0.2224~0.7776、10/10 → 0.7411~1、n=0 没有区间",
            cp0[0] == 0.0 and abs(cp0[1] - 0.25887) < 1e-4 and abs(cp5[0] - 0.22244) < 1e-4 and abs(cp5[1] - 0.77756) < 1e-4
            and cp10[1] == 1.0 and abs(cp10[0] - 0.74113) < 1e-4 and clopper_pearson(0, 0) == (None, None),
            f"{cp0} {cp5} {cp10}")
        # 1.4-c) (2,25) 改判 RECOIL（v1.5.1 的 session：rc 记 CATCH25）、C8 把 RECOIL 算坏结果、E5c 影子回放（v1.5.x 数据）
        S25 = S + 30000
        sy25 = build_synth_recoil25(S25)
        d25 = os.path.join(base, "v151_recoil25")
        write_dataset(sy25, d25, S25, drop_rc_seqs=(), old_session=False)
        R25 = analyze(load_data(d25), strict=True)
        rep25 = render(R25, strict=True)
        with open(os.path.join(base, "report_v151_recoil25.md"), "w", encoding="utf-8") as fh:
            fh.write(rep25)
        f25 = {f.id: f for f in R25.fires}
        mism25 = [(f.id, (f.outcome, f.sub), sy25.expected.get(f.id)) for f in R25.fires
                  if (f.outcome, f.sub) != sy25.expected.get(f.id)]
        chk("1.4 (2,25) 改判 RECOIL，对旧版本（1.5.1）也生效：进 (2,25) 的放刀记 RECOIL（说明「进 (2,25)」）、进 (2,26) 的仍是 CATCH，"
            "手动放刀进 (2,25) 也记 RECOIL；rc 的 CATCH25 按 RECOIL 比（3/3 一致）；第 6 节口径行之后紧跟 1.4 修订行并写明次数",
            not mism25 and len(f25) == 3 and f25[2].outcome == "RECOIL" and f25[2].sub == SUB_RECOIL25
            and f25[1].outcome == "CATCH" and f25[1].tier == 26 and R25.manual_out == Counter({"RECOIL": 1})
            and getattr(R25.manual[0], "recoil25", False)
            and ("1.4 修订：(2,25) cParrySlashHitS 改判 RECOIL（G1 实测：进 (2,25) 都是抵消状态 RECOIL、随即身体挨打），"
                 "对所有版本生效；本行优先于上一行的 (2,25..27)") in rep25
            and "进 (2,25) 的放刀 1 次、手动放刀 1 次" in rep25 and "| RECOIL | 1 | 进 (2,25) 1 |" in rep25
            and "rc 自评 RES 与离线 CATCH 判定一致 100%（3/3）" in rep25 and "rc 自评里的 CATCH25 1 次按 RECOIL 比" in rep25,
            f"{mism25} {R25.manual_out}")
        ev25 = next((e for e in R25.gate_events if e.kind == "real" and e.fire is f25.get(2)), None)
        chk("1.4 C8：RECOIL（被弹并随即挨打）算「空放/失败」，报告写明", ev25 is not None and ev25.bad
            and "「空放/失败」另含 RECOIL" in rep25, str(ev25 and ev25.bad))
        rows25 = {r.f.id: r for r in (R25.e5r.rows if R25.e5r else [])}
        r1_, r3_ = rows25.get(1), rows25.get(3)
        chk("1.4 E5c 影子回放（v1.5.1 数据）：C=1.134、A0=120 的招按原始 hs@30 放早（c_first 0.20）→ E5c@28 早 12 帧触发、c_first' "
            "落进窗口；C=1 的招 E5c@28 比原始 hs@30 晚 2 帧；另出「加该接过滤的假设」一列",
            r3_ is not None and r3_.sh is not None and abs((r3_.sh.t_L - r3_.f.t_req) + 12 / 60.0) < 1e-6
            and r3_.cls_act == "早" and r3_.cls_sh == "窗口内" and abs(r3_.c1 - 1.134) < 1e-9
            and r1_ is not None and r1_.sh is not None and abs((r1_.sh.t_L - r1_.f.t_req) - 2 / 60.0) < 1e-6
            and r3_.cls_sh_h == "窗口内" and "## 13. E5c 影子回放" in rep25 and "加该接过滤的假设" in rep25,
            f"r3 {r3_ and (r3_.sh and r3_.sh.t_L - r3_.f.t_req, r3_.cls_act, r3_.cls_sh)} "
            f"r1 {r1_ and r1_.sh and r1_.sh.t_L - r1_.f.t_req}")
        # 1.4-d) v1.6 的 B 阶段：通过
        S16 = S + 40000
        sy16 = build_synth_v16(S16, "pass")
        d16 = os.path.join(base, "v16_pass")
        write_dataset(sy16, d16, S16, drop_rc_seqs=(), old_session=False, extra_log=sy16.dbg)
        data16 = load_data(d16)
        R16 = analyze(data16, strict=True)
        rep16 = render(R16, strict=True)
        with open(os.path.join(base, "report_v16.md"), "w", encoding="utf-8") as fh:
            fh.write(rep16)
        c16x = R16.d_sess[0].cfg if R16.d_sess else None
        fr16 = {r.get("id"): r for r in data16.get("rc", "FIRE")}
        f1_ = fr16.get(1) or {}
        uv16, sk16 = data16.get("rc", "UVIEW"), data16.get("rc", "SKIP")
        st16 = data16.get("rc", "STAT")
        chk("1.4 v1.6 记录解析：HDR 的 rule/filter/cfg_ver/c_lo/c_hi、FIRE 的 E5c 字段、RES 的 to、STAT 的新计数、UVIEW、SKIP、VETO why=sg",
            c16x is not None and (c16x.rule, c16x.filter, c16x.cfg_ver, c16x.c_lo, c16x.c_hi) == ("E5c", "g1", 3, 0.5, 2.0)
            and all(isinstance(f1_.get(k), float) for k in ("C1", "Cf", "mf", "dX", "A0", "Q0", "Qp", "Qe1"))
            and abs(f1_.get("C1", 0) - 1.134) < 1e-9 and f1_.get("nchg") == 0 and f1_.get("mode") == "E5c"
            and f1_.get("vq") is False and all(isinstance(r.get("to"), tuple) for r in data16.get("rc", "RES"))
            and {r.get("outcome") for r in data16.get("rc", "RES")} == {"CATCH26", "CATCH27", "RECOIL", "NOCATCH"}
            and st16 and st16[-1].get("speedfail") == 1 and st16[-1].get("excl") == 2 and st16[-1].get("uview") == 1
            and st16[-1].get("recoils") == 4 and st16[-1].get("sidmis") == 0
            and len(uv16) == 1 and uv16[0].get("why") == "ug" and uv16[0].get("same") is True and uv16[0].get("id") == 19
            and Counter(r.get("why") for r in sk16) == Counter({"pb": 1, "ug": 1, "fc": 1})
            and [r.get("why") for r in data16.get("rc", "VETO")] == ["sg"],
            f"{c16x and (c16x.rule, c16x.filter, c16x.cfg_ver, c16x.c_lo, c16x.c_hi)} {f1_} {uv16} {len(sk16)}")
        D16 = R16.d16
        chk("1.4 D16 通过（V16 第 9.2 节）：新怪 em50~53 合并接住 56/64、纯空挥 4/68（打断 4 次从分子分母去掉）、开销、RED、样本、数据质量"
            "八项都过；设计集 em27 不进合并；标题是 B 阶段验收、开头有 v1.6 的验收摘要",
            D16 is not None and D16.verdict == "通过" and D16.new == [50, 51, 52, 53] and (D16.kc, D16.nc) == (56, 64)
            and (D16.kw, D16.nw) == (4, 68) and D16.n_int == 4 and D16.sample_ok
            and [d_item_result(i) for i in D16.items] == ["通过"] * 8 and D16.per[27]["CATCH27"] == 3
            and rep16.startswith("# 自动放刀 B 阶段验收报告（v1.6 离线分析）") and "## 验收摘要（V16 第 9.2 节" in rep16
            and "**D 结论（v1.6 B 阶段，V16 第 9.2 节）：通过。**" in rep16 and R16.d_verdict == "通过",
            f"{D16 and (D16.verdict, D16.new, D16.kc, D16.nc, D16.kw, D16.nw, [d_item_result(i) for i in D16.items])}")
        p50, p51, p52 = (D16.per[50], D16.per[51], D16.per[52]) if D16 else (Counter(), Counter(), Counter())
        chk("1.4 D16 按怪表：CATCH26/27、RECOIL、放早、纯空挥、打断三类分列，SKIP pb/ug/fc、UVIEW、speedfail（DBG）、漏报和覆盖率，"
            "末尾一行新怪合并",
            (p50["CATCH26"], p50["CATCH27"], p50["RECOIL"], p50["FAIL_EARLY"], p50["纯空挥"], p50["INTERRUPTED"]) == (7, 7, 1, 1, 1, 1)
            and p50["SKIP pb"] == 1 and p50["speedfail"] == 1 and p50["漏报"] == 1 and p51["UVIEW"] == 1
            and p51["SKIP ug"] == 1 and p52["SKIP fc"] == 1 and D16.dbg_on and "| **新怪合并** |" in rep16
            and "打断：INTERRUPTED" in rep16 and "95%（18/19）" in rep16,
            f"{dict(p50)} {dict(p51)} {dict(p52)}")
        ss16 = R16.sessions[0]
        e1d = []
        for ep in ss16.episodes:
            if ep.fire is None or not ep.ents:
                continue
            for e in ep.ents:
                for s_ in episode_samples(ep, e):
                    q_, q1_ = ss16.e5.q(ep, e, s_[0], s_[3]), ss16.e5.e1(ep, e, s_[0], s_[3])
                    if q_ is not None and q1_ is not None:
                        e1d.append(abs(q_ - q1_))
        rows16 = [r for r in (R16.e5r.rows if R16.e5r else []) if r.g1]
        chk("1.4 E5c 影子回放：C 恒定时 Q 恒等于 E1（每一格 SER）；1.6 的真 FIRE（nchg=0）和影子触发在同一帧",
            e1d and max(e1d) < 1e-6 and len(rows16) == len(R16.fires) and all(r.dframe == 0 for r in rows16)
            and "相差超过 1 帧的 0 刀" in rep16,
            f"max|Q−E1|={max(e1d) if e1d else None} dframe={Counter(r.dframe for r in rows16)}")
        chk("1.4 C2 残差、d̄ 对 v1.6 的放刀按 Q0（真实剩余帧）、穿越按 Qp > L",
            R16.res and all(abs(s_.R0 - s_.f.Q0) < 1e-9 for s_ in R16.res) and R16.dbar_late == 0 and R16.dbar_vals
            and all(0.0 <= v < 1.0 for v in R16.dbar_vals),
            f"{[(s_.R0, s_.f.Q0) for s_ in R16.res[:3]]} late={R16.dbar_late} d̄={R16.dbar_vals[:3]}")
        mc16 = R16.misses.counts if R16.misses else Counter()
        chk("1.4 漏报归因（1.6 起）：pb=1 的攻击打中蓄力中的主角 → 「被该接过滤排除」，报告列出这一类和口径，并和 rc 的 SKIP 对上",
            mc16.get(MISS_G1) == 1 and sum(mc16.values()) == 1 and "| 被该接过滤排除（游戏判定接不住） | 1 |" in rep16
            and "1.6 起（V16 第 3 节" in rep16 and D16.g1_miss == (1, 1)
            and "其中这一招的结果在接触之前有 rc 的 SKIP 记录的 1 次" in rep16, f"{dict(mc16)} {D16.g1_miss}")
        chk("1.4 SKILL_GUARD 家族否决：VETO why=sg 解析，影子否决段按同一口径数出 sg 1、和 rc 的 VETO 一致，诊断里写出",
            R16.veto_why == Counter({"sg": 1}) and R16.veto_shadow == Counter({"sg": 1}) and "SKILL_GUARD 1" in rep16
            and "和这些 session 的 VETO 一致" in rep16, f"rc {R16.veto_why} 影子 {R16.veto_shadow}")
        al16 = _mon_rows(R16, only_alert=True)
        chk("1.4 C 阶段监控：每只新怪进 (2,25) 被弹的那一招列在报告开头（附 A0、C1、GuardType、pbreak），第 15 节有全表",
            len(al16) == 4 and all("RECOIL" in r[-1] and r[-3] == "NORMAL 3" and r[-2] == "0 3" and r[4] == 1 for r in al16)
            and "## C 阶段监控提醒" in rep16 and rep16.index("## C 阶段监控提醒") < rep16.index("## 验收摘要")
            and "## 15. C 阶段监控" in rep16, str(al16[:2]))
        G16 = R16.g1r
        chk("1.4 G1 只报告项：SKILL_GUARD 不在抓取上的反例 1 条；PH RECOIL 时正在打的条目 pb=0 的反例 4 次（每只新怪进 (2,25) 那刀）",
            G16 is not None and len(G16.sg_bad) == 1 and sum(1 for p in G16.ph if p.bad) == 4
            and "**否，1 条反例**" in rep16 and "**4 次**" in rep16,
            f"{G16 and (G16.sg_bad, [(p.state, p.pb) for p in G16.ph if p.bad])}")
        # 只有日志（rc 的 JSON 全丢）：v1.6 的新字段、新记录种类从日志解析，D16 的数字不变
        d16l = os.path.join(base, "v16_rclog")
        write_dataset(sy16, d16l, S16, drop_rc_seqs=range(1, 1000), old_session=False, extra_log=sy16.dbg)
        R16l = analyze(load_data(d16l), strict=True)
        D16l = R16l.d16
        chk("1.4 v1.6 记录从日志解析（rc 没有 JSON）：UVIEW、SKIP、FIRE 的 E5c 字段、RES 的 to 都读到，D16 的数字和判定不变",
            R16l.data.info["used_log_only"]["rc"] and D16l is not None and D16l.verdict == "通过"
            and (D16l.kc, D16l.nc, D16l.kw, D16l.nw) == (D16.kc, D16.nc, D16.kw, D16.nw)
            and len(R16l.data.get("rc", "UVIEW")) == 1 and len(R16l.data.get("rc", "SKIP")) == 3
            and all(f.Q0 is not None and f.C1 is not None for f in R16l.fires)
            and all(isinstance(r.get("to"), tuple) for r in R16l.data.get("rc", "RES")),
            f"{D16l and (D16l.verdict, D16l.kc, D16l.nc)}")
        # 1.4-e) D16 不通过 / 样本不足 / 需复核
        res16 = {}
        for var in ("fail", "insufficient", "review", "red", "red_stat", "edge"):
            syv = build_synth_v16(S16, var)
            dv = os.path.join(base, "v16_" + var)
            write_dataset(syv, dv, S16, drop_rc_seqs=(), old_session=False, extra_log=syv.dbg)
            Rv = analyze(load_data(dv), strict=True)
            res16[var] = (syv, Rv, render(Rv, strict=True))
        syf, Rf, repf = res16["fail"]
        Df = Rf.d16
        chk("1.4 D16 不通过：em53 只接住 4/16 → 新怪合并 46/64 <75%；em53 标「左尾诊断」（只标不判）",
            Df is not None and Df.verdict == "不通过" and (Df.kc, Df.nc) == (46, 64) and 53 in Df.flags
            and "左尾诊断" in Df.flags[53] and "**D 结论（v1.6 B 阶段）：不通过。**" in repf
            and d_item_result(Df.items[0]) == "不通过",
            f"{Df and (Df.verdict, Df.kc, Df.nc, Df.flags)}")
        inc_f = {f.id: b for f, b in (Df.incons if Df else [])}
        chk("1.4 一致性核对：Q0 故意写小 0.6（仍在 [22, 28] 里）的 FIRE 被 |Q0 − (R0 − dX)/mf| 抓到、逐条列出（多半是实现错误）；"
            "通过的那份数据全部一致",
            sorted(inc_f) == sorted([syf.bad_fid, syf.range_fid, syf.qe_fid]) and len(inc_f.get(syf.bad_fid, [])) == 1
            and "≠ (R0−dX)/mf" in inc_f[syf.bad_fid][0] and not D16.incons
            and "**3 行不符（多半是实现错误）**" in repf and "全部一致" in rep16,
            f"{inc_f} 通过那份 {D16.incons}")
        chk("1.4 一致性核对（范围）：公式自洽、却在 L 之外放刀（Q0 在 29~30，FIRE 记 L=28）的 FIRE 被「L_min ≤ Q0 ≤ L」抓到",
            len(inc_f.get(syf.range_fid, [])) == 1 and "不在 [L_min=22, L=28]" in inc_f[syf.range_fid][0],
            str(inc_f.get(syf.range_fid)))
        chk("1.4 一致性核对（Qe1）：只有影子 E1 写偏 0.5 的 FIRE 被 |Qe1 − (R0 − A0·(1 − 1/max(1, C1)))| 抓到",
            len(inc_f.get(syf.qe_fid, [])) == 1 and "Qe1=" in inc_f[syf.qe_fid][0], str(inc_f.get(syf.qe_fid)))
        _syi, Ri, repi = res16["insufficient"]
        chk("1.4 D16 样本不足：只有 3 只新怪（每只 16 次有接触）→ 样本不足，不写通过",
            Ri.d16 is not None and Ri.d16.verdict == "样本不足" and Ri.d16.new == [50, 51, 52] and not Ri.d16.sample_ok
            and "**D 结论（v1.6 B 阶段）：样本不足**" in repi, f"{Ri.d16 and (Ri.d16.verdict, Ri.d16.new)}")
        _syr, Rr, repr_ = res16["review"]
        rev_items = [i.name for i in (Rr.d16.items if Rr.d16 else []) if i.review and not i.ok]
        chk("1.4 D16 需复核：探针 apcal-1.0.1、sidmis=2 → 两项数据质量判需复核，判定项没有不通过",
            Rr.d16 is not None and Rr.d16.verdict == "需复核" and len(rev_items) == 2
            and any("apcal-1.1" in n for n in rev_items) and any("sidmis" in n for n in rev_items)
            and "**D 结论（v1.6 B 阶段）：需复核。**" in repr_,
            f"{Rr.d16 and Rr.d16.verdict} {rev_items}")
        # 审查修订（V16 第 7 节第 4 条、第 9.2 节）：单发的核心红错误（2c 那类 caught (...) exception）算「放刀模块 RED」，判不通过；
        # ERR 记录没进 JSON、只有 STAT red 的也一样
        for var, what in (("red", "ERR frame red 1 条（STAT red 0）"), ("red_stat", "只有 STAT red=1（没有 ERR 记录）")):
            _sy, Rv_, repv_ = res16[var]
            Dv_ = Rv_.d16
            bad_ = [i.name for i in (Dv_.items if Dv_ else []) if not i.ok and not i.insufficient and not i.review]
            chk(f"1.4 D16 RED（审查修订）：{what} → 「放刀模块 RED / 核心模块红错误 / 崩溃」不通过，其余各项照常通过",
                Dv_ is not None and Dv_.verdict == "不通过" and len(bad_) == 1 and "RED" in bad_[0]
                and "核心模块红错误 1" in next(i.value for i in Dv_.items if "RED" in i.name)
                and "**D 结论（v1.6 B 阶段）：不通过。**" in repv_, f"{Dv_ and Dv_.verdict} {bad_}")
        # 审查补充（tests-analysis #7）：门槛的边界
        _sye, Re, repe = res16["edge"]
        De = Re.d16
        chk("1.4 D16 边界（审查补充）：新怪合并接住正好 45/60 = 75% 判通过；每只新怪正好 15 次有接触算够数；em53 放早正好 3 次打"
            "「左尾诊断」标记、其余不标；训练机关 em33 的放刀不进新怪合并",
            De is not None and De.verdict == "通过" and (De.kc, De.nc) == (45, 60) and De.new == [50, 51, 52, 53]
            and len(De.enough) == 4 and all(De.per[e]["有接触"] == 15 for e in (50, 51, 52, 53))
            and 53 in De.flags and "放早" in De.flags[53] and not any(e in De.flags for e in (50, 51, 52))
            and De.per[33]["CATCH27"] == 2 and d_item_result(De.items[0]) == "通过",
            f"{De and (De.verdict, De.kc, De.nc, De.new, len(De.enough), De.flags, dict(De.per[33]))}")
        # 1.4-f) 先 1.5.1（中途拖过滑块）后 1.6 两次加载合并：1.5.1 的改动带不进 1.6（v1.6 加载时把 cfg_ver<3 的配置迁成 28），
        #        1.6 不整段不计；1.5.1 的 session 不进 B 阶段验收
        d_mx = os.path.join(base, "v151_then_v16")
        write_dataset(build_synth_v15(S16 - 20000, ver="1.5.1", lead0=30), d_mx, S16 - 20000, drop_rc_seqs=(),
                      old_session=False)
        write_dataset(sy16, d_mx, S16, drop_rc_seqs=(), old_session=False, write_log=False)
        all_mx = load_all(d_mx)
        R_mx = analyze([session_data(all_mx, S16 - 20000), session_data(all_mx, S16 + 1)], strict=True)
        rep_mx = render(R_mx, strict=True)
        chk("1.4 先 1.5.1（拖过滑块）后 1.6 合并：1.6 不因为 1.5.1 的改动整段不计，B 阶段验收只用 1.6 的 session（数字同单独分析）",
            R_mx.d16 is not None and [d.excluded for d in R_mx.d_sess] == [None, None] and len(R_mx.d16.others) == 1
            and R_mx.d16.verdict == "通过" and (R_mx.d16.kc, R_mx.d16.nc) == (D16.kc, D16.nc)
            and "不进 B 阶段验收" in rep_mx, f"{[d.excluded for d in R_mx.d_sess]} {R_mx.d16 and R_mx.d16.verdict}")
        # 1.4-g)（集成补充）滑块改过的 v1.6 session：第 13 节「影子对真 FIRE」按这一刀自己的 L 重放；E5c@28 那一列照旧按 28
        S_l = S + 50000
        sy_l = build_synth_v16_lead(S_l)
        d_l = os.path.join(base, "v16_lead35")
        write_dataset(sy_l, d_l, S_l, drop_rc_seqs=(), old_session=False)
        R_l = analyze(load_data(d_l), strict=True)
        rep_l = render(R_l, strict=True)
        rows_l = sorted((r for r in (R_l.e5r.rows if R_l.e5r else []) if r.g1), key=lambda r: r.f.t_req)
        chk("1.4 影子对真 FIRE 按这一刀自己的 L：滑块拖到 35 之后那刀（FIRE L=35）和按 35 重放的影子同一帧；"
            "E5c@28 那一列照旧按 28（比真放刀晚 7 帧）",
            len(rows_l) == 2 and [r.f.L for r in rows_l] == [28, 35] and all(r.dframe == 0 for r in rows_l)
            and all(r.sh is not None for r in rows_l) and abs(rows_l[1].sh.t_L - rows_l[1].f.t_req - 7 / 60.0) < 1e-6
            and "相差超过 1 帧的 0 刀" in rep_l,
            f"{[(r.f.L, r.dframe, r.sh and round(r.sh.t_L - r.f.t_req, 4)) for r in rows_l]}")
        # 1.4-h)（审查修订）第 13 节：影子不触发的真放刀逐条给原因（可解释 / 原因不明）；「实际 Q」= FIRE 的 Q0；探针 AP 停用之后
        #        属性不明的条目影子照样放行（不按读不准），第 14 节不算「攻击参数为空」
        S_g = S + 60000
        sy_g = build_synth_v16_gap(S_g)
        d_g = os.path.join(base, "v16_gap")
        write_dataset(sy_g, d_g, S_g, drop_rc_seqs=(), old_session=False)
        R_g = analyze(load_data(d_g), strict=True)
        rep_g = render(R_g, strict=True)
        rows_g = {r.f.id: r for r in (R_g.e5r.rows if R_g.e5r else []) if r.g1}
        rg_ok, rg_pb, rg_unk, rg_chg = (rows_g.get(sy_g.gap_ids[k]) for k in ("ok", "pb", "unk", "chg"))
        chk("1.4 第 13 节（审查修订）：影子不触发的真放刀不再静默剔除 —— ENT 判 pb=1 却放了的那刀列为「原因不明」（应当为 0）；"
            "探针 AP 停用后属性不明的那刀照样和影子同一帧；nchg=1 的那刀单列、影子 Q 和 Q0 的差不算不一致；1.6 的「实际 Q」是 FIRE 的 Q0",
            None not in (rg_ok, rg_pb, rg_unk, rg_chg) and rg_ok.dframe == 0 and rg_unk.dframe == 0
            and rg_pb.dframe is None and rg_pb.gap is not None and rg_pb.gap[1] is False and "pb" in rg_pb.gap[0]
            and rg_chg.dframe is not None and rg_chg.q_act is not None and abs(rg_chg.q_act - rg_chg.f.Q0) < 1e-9
            and rg_chg.q_sh is not None and abs(rg_chg.q_sh - rg_chg.f.Q0) > 0.5
            and "真放刀 4 刀，影子也触发、参与上面对照的 3 刀；影子不触发 / 没有条目的 1 刀，其中原因不明 1 刀" in rep_g
            and "nchg ≠ 0 的放刀 1 刀" in rep_g and "相差超过 1 帧的 0 刀" in rep_g
            and f"差超过 {Q_SHADOW_TOL} 帧的 0 刀" in rep_g,
            f"{[(k, r and (r.dframe, r.gap, r.q_act, r.q_sh)) for k, r in zip(('ok', 'pb', 'unk', 'chg'), (rg_ok, rg_pb, rg_unk, rg_chg))]}")
        G_g = R_g.g1r
        chk("1.4 第 14 节（审查修订）：探针 AP 停用（ERR AP）之后 ENT 三项全空的条目不进分布、不算「攻击参数为空」，报告写明停用时刻和影响",
            G_g is not None and len(G_g.ap_off) == 1 and abs(G_g.ap_off[0][1] - sy_g.t_ap_off) < 1e-6 and G_g.ap_off[0][2] == 2
            and all(o.ap_nil == 0 for o in G_g.per.values()) and "探针 AP 模块在 t=" in rep_g,
            f"{G_g and (G_g.ap_off, {e: o.ap_nil for e, o in G_g.per.items()})}")
        # E5c 影子参数的单元核对（审查补充，tests-analysis #2、#7）：固定输入、手算的期望值
        def e5_case(series, sers, t_msg=500.0, sysidx=77):
            ctx_ = Obj(eminfo=Obj(recs=[{"t": t_, "em": f"em60#{sysidx}", "comp": f"1/1/{c_:.4f}/1/1/1"} for t_, c_ in series]))
            ent_ = Obj(ent="E1", approx=False, samples=sers, ts=[x[0] for x in sers])
            ep_ = Obj(msgs=[{"t": t_msg}], t0=t_msg, t1=sers[-1][0] + 1.0, keys={("sys", sysidx), ("em", 60)}, ents=[ent_])
            return E5c(ctx_), ep_, ent_

        def ser_(t_msg, A0, ks):
            return [(t_msg + k / 60.0, None, "DANGER", A0 - k, A0 - k + 8, True) for k in ks]

        # (a) C 在倒数中途变（EMINFO 1.0 → 1.5，第 30 帧那一格之前采到）：跨这一格的那一对读数乘的是上一格的 m=1.0，之后每格 +0.5
        e5a, epa, ea = e5_case([(500.004, 1.0), (500.0 + 29.5 / 60.0, 1.5)], ser_(500.0, 150.0, range(1, 61)))
        qa = e5a.q(epa, ea, 500.0 + 40 / 60.0, 150.0 - 40)
        want_a = (110.0 - 10 * 0.5) / 1.5          # 第 30 格那一对乘 1.0（不加），第 31~40 格各加 0.5
        # (b) SER 每 4 帧一格、C=1.2 恒定：两格之间的时刻按名义倒数外推 X，Q 恒等于 E1
        e5b, epb, eb = e5_case([(500.004, 1.2)], ser_(500.0, 150.0, range(1, 61, 4)))
        qb = e5b.q(epb, eb, 500.0 + 23 / 60.0, 150.0 - 23)
        want_b = (150.0 - 23) - 149.0 * (1.0 - 1.0 / 1.2)       # A0 = 第一格 SER 的 hs（第 1 帧，149）
        # (c) 首帧 C 取消息之后的第一条 EMINFO（消息前 0.5 s 那条不算），消息后 2 s 内都算首帧；2.5 s 才有的算读不到
        e5c1, epc1, _e = e5_case([(499.5, 1.5), (500.1, 1.1)], ser_(500.0, 150.0, range(1, 10)))
        e5c2, epc2, _e = e5_case([(501.0, 1.1)], ser_(500.0, 150.0, range(1, 10)))
        e5c3, epc3, _e = e5_case([(502.5, 1.1)], ser_(500.0, 150.0, range(1, 10)))
        Mc1, Mc2, Mc3 = e5c1.model(epc1), e5c2.model(epc2), e5c3.model(epc3)
        # (d) SER 断档 0.6 s（一对读数 hs 掉 36 > 30）：上限按隔开的时间放宽，照常累加，Q 仍等于 E1
        e5d, epd, ed = e5_case([(500.004, 1.264)], ser_(500.0, 150.0, list(range(1, 20)) + list(range(56, 70))))
        qd = e5d.q(epd, ed, 500.0 + 60 / 60.0, 150.0 - 60)
        want_d = (150.0 - 60) - 149.0 * (1.0 - 1.0 / 1.264)
        chk("1.4 E5c 影子的参数（审查补充）：中途变速那一对读数乘上一格的 m；两格之间按名义倒数外推 X；首帧 C 取消息后的第一条、"
            "2 s 内都算；SER 断档（Δhs=36）按隔开的时间放宽上限、照常累加",
            qa is not None and abs(qa - want_a) < 1e-6 and qb is not None and abs(qb - want_b) < 1e-6
            and Mc1.c1 == 1.1 and not Mc2.nofire and Mc2.c1 == 1.1 and Mc3.nofire
            and qd is not None and abs(qd - want_d) < 1e-6 and e5d.model(epd).skip == 0,
            f"a {qa} vs {want_a}；b {qb} vs {want_b}；c {Mc1.c1} {Mc2.nofire, Mc2.c1} {Mc3.nofire}；d {qd} vs {want_d} "
            f"skip={e5d.model(epd).skip}")
        chk("1.4 g1_class「确定的原因优先」（V16 第 3.2 节集成澄清）：pb=1 又是 SKILL_GUARD 记 sg；pb 读不到的 UNABLE_GUARD 记 ug；"
            "只读到 pb=1 记 pb；伤害类型读不到的 NORMAL 记 fc",
            g1_class({"pbreak": True, "guard": "SKILL_GUARD", "dmgtype": "SMASH"}) == "sg"
            and g1_class({"pbreak": None, "guard": "UNABLE_GUARD", "dmgtype": "SMASH"}) == "ug"
            and g1_class({"pbreak": True, "guard": None, "dmgtype": None}) == "pb"
            and g1_class({"pbreak": False, "guard": "NORMAL", "dmgtype": None}) == "fc"
            and g1_class({"pbreak": False, "guard": "ALL_RANGE", "dmgtype": "SMASH"}) == "ok")
        # 一致性核对的容差（V16 第 7 节第 4 条集成修订）：正确实现、只是记录格式取整的 FIRE 不能被误报。C 真值 1.076×1.114 =
        # 1.198664 记成 C1=mf=1.199、A0=400.37：只因 C1 取整，Qe1 的复算就差约 0.09（固定 0.01 会误报）
        m_t, a0_t = 1.076 * 1.114, 400.37
        r0_t = 27.6 + a0_t * (1.0 - 1.0 / m_t)
        dx_t = (a0_t - r0_t) * (m_t - 1.0)
        f_ok = Obj(R0=round(r0_t, 2), dX=round(dx_t, 2), mf=round(m_t, 3), Q0=round((r0_t - dx_t) / m_t, 2), A0=a0_t,
                   C1=round(m_t, 3), Qe1=round(r0_t - a0_t * (1.0 - 1.0 / m_t), 2), L=28)
        f_bad = Obj(**dict(f_ok.__dict__, Qe1=round(f_ok.Qe1 + 0.25, 2)))
        e1_raw = abs(f_ok.Qe1 - (f_ok.R0 - f_ok.A0 * (1.0 - 1.0 / f_ok.C1)))
        chk("1.4 一致性核对的容差含记录格式的舍入：C1 取整让 Qe1 复算差 0.09 的正确 FIRE 不报；Qe1 真写偏 0.25 的照样报",
            e1_raw > 0.05 and fire_consistency(f_ok) == [] and len(fire_consistency(f_bad)) == 1,
            f"复算差 {e1_raw:.4f} ok={fire_consistency(f_ok)} bad={fire_consistency(f_bad)}")

        # 1.5-a) 合并版（AutoGuardGS v1.5，MERGE 第 4.4 节第 4 条）：只有日志、没有 JSON；HDR 带 host / enum_skip，FIRE 没有 src / Qp /
        #        Qe1 / mode / vq，RES 带 entered，没有 FIRE_END / VETO / SKIP / UVIEW / STAT / CFG / DBG。第 1 刀的 RES 写 entered=0、
        #        探针 ACT 却进了 (2,23)：entered 要先取 RES（ACT 只在 FIRE_END、RES 都没有时兜底）
        S_m = S + 70000
        sy_m = merged_synth(build_synth_v16(S_m, "pass"))
        for kind_, kw_ in sy_m.recs["rc"]:
            if kind_ == "RES" and kw_.get("id") == 1:
                kw_["entered"] = False
        d_m = os.path.join(base, "merged_pass")
        write_dataset(sy_m, d_m, S_m, drop_rc_seqs=range(1, 1000), old_session=False)
        data_m = load_data(d_m)
        R_m = analyze(data_m, strict=True)
        rep_m = render(R_m, strict=True)
        with open(os.path.join(base, "report_merged.md"), "w", encoding="utf-8") as fh:
            fh.write(rep_m)
        cfg_m = rc_config(data_m)
        fa_m = {f.id: f for f in R_m.fires_all}
        f1m = fa_m.get(1)
        chk("1.5 合并版（只有日志、没有 JSON）能解析：HDR 的 host / enum_skip、ver=1.6 按 1.6 的冻结值；FIRE 没有 Qe1；没有 FIRE_END 时 "
            "entered 从 RES 取（RES 写 0 的那一刀优先于探针 ACT），其余的不按「缺 FIRE_END/ACT 按已进入计」",
            data_m.info["used_log_only"].get("rc") and cfg_m.merged and cfg_m.host == "AutoGuardGS-v1.5"
            and cfg_m.enum_skip is None and cfg_m.e5c and cfg_m.g1 and cfg_m.release and cfg_m.rotating is False
            and frozen_mismatch(cfg_m) == [] and not data_m.get("rc", "FIRE_END") and not data_m.get("rc", "STAT")
            and len(fa_m) == sy_m.ids["fire"] and all(f.Qe1 is None and f.Q0 is not None for f in fa_m.values())
            and f1m is not None and f1m.entered is False and not any(f.entered_assumed for f in fa_m.values())
            and all(f.entered is True for i, f in fa_m.items() if i != 1),
            f"{cfg_m.host, cfg_m.enum_skip, cfg_m.e5c, frozen_mismatch(cfg_m)} n={len(fa_m)} "
            f"f1={f1m and (f1m.entered, f1m.entered_assumed)}")
        D_m = R_m.d16
        chk("1.5 合并版：没有 Qe1 的一致性核对全部一致；报告头有「合并版」那一行；D16 的开销项写「—（合并版没有 STAT…）」、"
            "sidmis 写「—（合并版不记…）」判需复核、SKIP / UVIEW 写「—（合并版不记）」，结论不会是「通过」（只会样本不足或需复核）",
            D_m is not None and D_m.incons == [] and len(D_m.fires_all) == len(fa_m)
            and "- 合并版（AutoGuardGS-v1.5）放刀日志：只有 HDR、FIRE、RES、ERR、RED" in rep_m
            and "—（合并版没有 STAT；开销看 [AutoGuardGS] PERF 行）" in rep_m and "- SKIP：—（合并版不记）" in rep_m
            and "- UVIEW：—（合并版不记）" in rep_m and D_m.verdict in ("样本不足", "需复核") and R_m.d_verdict != "通过"
            and f"- 脚本修订：{ANALYZER_REV_15}" in rep_m
            # 审查修订：sidmis 合并版不记，这一项不能判通过（判需复核）
            and any(i.name.startswith("数据质量：sidmis") and not i.ok and i.review and "合并版不记" in str(i.value)
                    for i in D_m.items),
            f"incons={D_m and D_m.incons[:2]} verdict={D_m and D_m.verdict}")
        # 1.5-a') Q0 故意写偏 0.6、Q0 落在 [L_min, L] 外的两刀：没有 Qe1 也照样抓到；只有 Qe1 写偏的那一刀（合并版没有 Qe1）不再报
        S_mf = S + 70600
        sy_mf = merged_synth(build_synth_v16(S_mf, "fail"))
        d_mf = os.path.join(base, "merged_fail")
        write_dataset(sy_mf, d_mf, S_mf, drop_rc_seqs=range(1, 1000), old_session=False)
        R_mf = analyze(load_data(d_mf), strict=True)
        inc_mf = {f.id: b for f, b in (R_mf.d16.incons if R_mf.d16 else [])}
        chk("1.5 合并版的一致性核对（没有 Qe1）：Q0 写偏 0.6 的那一刀、Q0 不在 [L_min, L] 的那一刀都抓到，不报「缺字段」",
            set(inc_mf) == {sy_mf.bad_fid, sy_mf.range_fid} and not any("缺字段" in x for b in inc_mf.values() for x in b)
            and any("Q0=" in x and "(R0−dX)/mf" in x for x in inc_mf.get(sy_mf.bad_fid, []))
            and any("不在 [L_min" in x for x in inc_mf.get(sy_mf.range_fid, [])),
            f"{inc_mf} 期望 {sy_mf.bad_fid, sy_mf.range_fid}")
        # 1.5-b、c) 同一份日志里先是一个独立 v1.6 session（JSON + 日志），后是一个合并版 session（只有日志；调试日志中途才打开，
        #          HDR 懒写在第一行 FIRE 之前，它前面这次加载没有任何 [AutoParryGS] 行）：session 按最近的 HDR 切分不串；两个一起分析
        #          都按 1.6 的规则，冻结值都是 lead 28、L_min 22、W_long 60、H_veto 90、rule=E5c、filter=g1
        S_a, S_b = S + 80000, S + 80600
        sy_a = build_synth_v16(S_a, "pass")
        sy_b = merged_synth(build_synth_v16(S_b, "pass"), lazy=True)
        d_ab = os.path.join(base, "v16_and_merged")
        write_dataset(sy_a, d_ab, S_a, drop_rc_seqs=(), old_session=False, log_name="a.log", extra_log=sy_a.dbg)
        write_dataset(sy_b, d_ab, S_b, drop_rc_seqs=range(1, 1000), old_session=False, log_name="b.log", hdr_by_time=True)
        with open(os.path.join(d_ab, "re2_framework_log.txt"), "w", encoding="utf-8") as fo:
            for nm in ("a.log", "b.log"):
                with open(os.path.join(d_ab, nm), encoding="utf-8") as fi:
                    fo.write(fi.read())
                os.remove(os.path.join(d_ab, nm))
        src_ab = load_all(d_ab, None)
        da_, db_ = session_data(src_ab, S_a), session_data(src_ab, S_b)
        with open(os.path.join(d_ab, "re2_framework_log.txt"), encoding="utf-8") as fh:
            lines_b = fh.read().splitlines()
        i_hdr = next(i for i, l in enumerate(lines_b) if "[AutoParryGS] HDR" in l and f"session={S_b + 1}" in l)
        i_pr = next(i for i, l in enumerate(lines_b) if "[APCal] HDR" in l and f"session={S_b} " in l)
        between = [l for l in lines_b[i_pr:i_hdr] if "[AutoParryGS]" in l]
        nxt = next((l for l in lines_b[i_hdr + 1:] if "[AutoParryGS]" in l), "")
        ca_, cb_ = rc_config(da_), rc_config(db_)
        R_ab = analyze([da_, db_], strict=True)
        rep_ab = render(R_ab, strict=True)
        chk("1.5 合并版的 HDR 懒写：这次加载的探针 HDR 之后、合并版 HDR 之前没有 [AutoParryGS] 行，HDR 紧接着就是第一行 FIRE；"
            "两个 session 按 HDR 切分不串（各自的 FIRE 条数对得上）",
            i_pr < i_hdr and not between and " FIRE " in nxt
            and sum(1 for l in lines_b[i_pr:i_hdr] if "[APCal]" in l) > 10
            and len(da_.get("rc", "FIRE")) == sy_a.ids["fire"] and len(db_.get("rc", "FIRE")) == sy_b.ids["fire"]
            and not db_.get("rc", "FIRE_END") and len(da_.get("rc", "FIRE_END")) == sy_a.ids["fire"]
            and da_.info["chosen"] == {"pr": S_a, "rc": S_a + 1} and db_.info["chosen"] == {"pr": S_b, "rc": S_b + 1},
            f"pr {i_pr} hdr {i_hdr} between={len(between)} next={nxt[:60]} FIRE {len(da_.get('rc', 'FIRE'))}/"
            f"{len(db_.get('rc', 'FIRE'))}")
        chk("1.5 独立 v1.6 和合并版的 session 一起分析：两个都按 1.6 规则（E5c、g1），冻结值都是 lead 28、L_min 22、W_long 60、"
            "H_veto 90、rule=E5c、filter=g1；报告头有「合并版」那一行",
            (not ca_.merged) and cb_.merged and all(c.vt == (1, 6) and c.e5c and c.g1 and c.release and frozen_mismatch(c) == []
                                                    and (c.lead0, c.lmin, c.wlong, c.hveto, c.rule, c.filter)
                                                    == (28, 22, 60, 90, "E5c", "g1") for c in (ca_, cb_))
            and len(R_ab.d_sess) == 2 and all(d.cfg.e5c for d in R_ab.d_sess)
            and "- 合并版（AutoGuardGS-v1.5）放刀日志" in rep_ab,
            f"a {ca_.vt, ca_.merged, frozen_mismatch(ca_)} b {cb_.vt, cb_.merged, frozen_mismatch(cb_)}")

        # 3) 几乎没数据：只有 HDR（mock 场景可能就是这样），以及完全空目录
        d3 = os.path.join(base, "empty")
        os.makedirs(d3, exist_ok=True)
        with open(os.path.join(d3, "ref.log"), "w", encoding="utf-8") as fh:
            fh.write(_log_line("pr", "HDR", {"ver": "x", "session": S}, 0.0) + "\n")
            fh.write(_log_line("rc", "HDR", {"ver": "x", "session": S, "lead": 28}, 0.0) + "\n")
        R3 = analyze(load_data(d3), strict=True)
        rep3 = render(R3, strict=True)
        chk("样本不足时不崩溃并如实写「样本不足」", INSUFF in rep3 and R3.c10, str(R3.c10))
        d4 = os.path.join(base, "nothing")
        os.makedirs(d4, exist_ok=True)
        R4 = analyze(load_data(d4), strict=True)
        rep4 = render(R4, strict=True)
        chk("完全没有数据：C10 写明日志和 JSON 都没有", any("都没有数据" in r for r in R4.c10) and INSUFF in rep4)
    finally:
        failed = [c for c in checks if not c[1]]
        for name, ok, detail in checks:
            print(("  ok   " if ok else "  FAIL ") + name + (f"  [{detail}]" if detail and not ok else ""))
        print(f"selftest：{len(checks) - len(failed)}/{len(checks)} 通过" + (f"，输出保留在 {base}" if keep else ""))
        if not keep:
            shutil.rmtree(base, ignore_errors=True)
    return 0 if checks and not failed else 1


# ---------------------------------------------------------------- 入口
def main(argv=None):
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    ap = argparse.ArgumentParser(description="自动放刀第 1 轮离线分析（PLAN.md DECISION RULE B/C/D、P23）")
    ap.add_argument("data_dir", nargs="?", help="含 APCal_*.json / AutoParryGS_*.json 的目录（会递归找）")
    ap.add_argument("--log", help="re2_framework_log.txt 路径（默认在数据目录及其上两级找 re2_framework_log.txt / ref.log）")
    ap.add_argument("--session", type=int, nargs="+",
                    help="指定 session（默认最新）；给多个就合并分析：每个 session 各自做时间关联（游戏重启后 os.clock 归零，"
                         "时间轴不能直接合并），派生样本（放刀结局、残差、回合、漏报、扫描点）再合在一起算 C1~C10")
    ap.add_argument("--calib-session", type=int, nargs="+",
                    help="只从这些 session 取定标量（扫描窗口、T_armor、δ），默认用全部 --session。"
                         "C10 补测（只补真怪段、不重做扫描）时用：--session 新 --calib-session 旧；"
                         "第 2 轮（v1.5 没有扫描）用第 1 轮的：--calib-session 1791644664 --calib-dir tools/out/round1_data")
    ap.add_argument("--calib-dir",
                    help="定标 session 的数据在另一个目录时用（例如第 1 轮的 tools/out/round1_data）；"
                         "只给这个、不给 --calib-session 时取该目录里最新的 session")
    ap.add_argument("--calib-log", help="--calib-dir 的日志（默认在该目录及其上两级找 re2_framework_log.txt / ref.log）")
    ap.add_argument("--crashed", action="store_true", help="用户报告游戏崩溃过（C9(d) 判有崩溃）")
    ap.add_argument("--out", help="报告写到这个 Markdown 文件（默认打印到标准输出）")
    ap.add_argument("--strict", action="store_true", help="任何一节计算出错就直接抛异常（调试用）")
    ap.add_argument("--selftest", action="store_true", help="生成合成数据跑完整流程并断言")
    ap.add_argument("--keep", help="--selftest 时把合成数据和报告留在这个目录")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest(a.keep)
    if not a.data_dir and not a.log:
        ap.error("需要数据目录（或至少 --log）")
    src_all = load_all(a.data_dir or ".", a.log)
    datas = [session_data(src_all, s) for s in (a.session or [None])]
    if a.calib_dir:
        # 定标数据在别的目录（第 2 轮 v1.5 没有机关扫描，窗口、T_armor、δ 取第 1 轮的）：单独读一遍，日志也用那边的
        if not os.path.isdir(a.calib_dir):
            ap.error(f"--calib-dir 不是目录：{a.calib_dir}")
        src_cal = load_all(a.calib_dir, a.calib_log)
        calib = [session_data(src_cal, s) for s in (a.calib_session or [None])]
    else:
        calib = [session_data(src_all, s) for s in a.calib_session] if a.calib_session else None
    R = analyze(datas if len(datas) > 1 else datas[0], strict=a.strict, calib=calib, crashed=a.crashed)
    text = render(R, strict=a.strict)
    if a.out:
        with open(a.out, "w", encoding="utf-8") as fh:
            fh.write(text)
        mode = {"release": "第 2 轮验收", "calibration": "标定轮预览", "fixed": "固定提前量"}.get(R.d_mode, R.d_mode)
        print(f"报告已写到 {a.out}（{len(text.splitlines())} 行；内部错误 {len(R.errors)} 处；"
              f"放刀 {len(R.fires)}，DANGER 回合 {R.n_danger}，C10 {'需要补测' if R.c10 else '不需要补测'}"
              + (f"；D（{mode}）{R.d_verdict}" if R.d_verdict else "") + "）")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
