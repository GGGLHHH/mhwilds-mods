-- AutoGuardGS/const：入口、防御、放刀几处都要用的常量。只放常量，不放状态
local K = {}

K.TAG, K.REC_TAG = "[AutoGuardGS] ", "[AutoParryGS]"
K.VERSION = "v1.5"
-- 放刀规则的版本，写进 HDR 的 ver：规则（何时放、放不放）变了才改，只改代码结构或日志格式不改。
-- 不能写成 1.5：分析脚本会把它当成旧的 AutoParryGS v1.5（L = 26、hs 口径）去判
K.PARRY_RULE = "1.6"
K.HOST = "AutoGuardGS-" .. K.VERSION    -- HDR 的 host：标明放刀记录是合并版写的
K.CONFIG_PATH = "AutoGuardGS.json"
K.LEGACY_PARRY_CONFIG = "AutoParryGS.json"   -- 旧的独立放刀脚本的配置：首次加载迁移一次（入口 §3），只读不写

K.ANGLE_MIN, K.ANGLE_MAX = 30.0, 360.0
K.GUARD_WARN_MAX = 20           -- 防御的警告每类每次加载最多写这么多行（出错时不至于每帧刷一行）
-- 放刀里配置、HDR、错误分级也要用的常量（其余在 parry.lua）。剩余帧单位 1/60 s、是 System.Single，格式化一律 %.Nf
K.LEAD_DEFAULT, K.LEAD_LO, K.LEAD_HI = 28, 23, 45   -- L（Q 单位）默认值与滑块范围（下限 23：[L_min, L] 至少 1 帧宽）
K.LEGACY_CFG_VER = 3            -- 旧 AutoParryGS.json 的 cfg_ver ≥ 3 时 parry_lead 才是 Q 单位（V16 2.7）
K.LEAD_MIN, K.LONG_WINDOW, K.VETO_HORIZON = 22, 60, 90   -- L_min（Q 单位）；W_long、H_veto（原始帧，只参与否决）
K.C_LO, K.C_HI = 0.5, 2.0       -- CoreState 合法范围：只剔除坏值（NaN、0、乱码）
K.CREDIT = 1.3                  -- 放刀后 1.3 s 内进 (2,25..27) 才算结局（刀攻击判定顿帧时最晚约 1.22 s 关，G1 实测）
K.RED_WINDOW, K.RED_COUNT, K.ERR_LOG_MAX = 10.0, 3, 20   -- 核心模块 10 s 内出错 3 次标红；ERR 每次加载最多写 20 行

function K.clamp_lead(v) return math.max(K.LEAD_LO, math.min(K.LEAD_HI, math.floor(v + 0.5))) end

return K
