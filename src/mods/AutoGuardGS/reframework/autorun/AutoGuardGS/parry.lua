-- AutoGuardGS/parry：自动放刀（原 AutoParryGS v1.6，放刀规则一处没改，有逐刀等价测试为证）
--
-- 按住抵消蓄力 (2,21)/(2,22) 时读怪物发给主角的攻击预告 cMsgEmAttackAreaResult，「打我的」DANGER 条目里最早一段的
--   真实剩余帧 Q 落进 [L_min, L] 就在帧开头请求 (2,23) 上捞斩；抵消、伤害、弹开全部来自刀和攻击的原生碰撞。
-- 时机 E5c（V16 第 2 节；机制 SPEED 第 1~2 节，实测）：hs 的初值是怪物 1 倍速下的名义帧、在接收端按真实时间每秒减 60，
--   怪物却按 CoreState 倍速推进，C > 1 时攻击早到约 A·(1−1/C)/60 s。
--     m = max(1, C)（疲劳 C < 1 按 1）；X += Δhs·(m_上帧 − 1)（用条目 hs 自己的递减当时钟：卡顿时游戏把扣减钳在约 0.133 s，
--     墙钟会漂）；Q = (hs − (X − X0_e)) / m，X0_e = 条目首见时的 X。
--   C 从登记后第一个帧回调起每帧读、不在钩子里读（CoreState 恰在发消息那一帧按招切换，钩子里读到的是上一招的值）；
--   首帧读不到的结果永不放刀、照样参与否决，中途读不到沿用上一帧的 m；不回退到原始 hs（会放早）。
-- 候选：L_min ≤ Q ≤ L、0 ≤ he−hs ≤ 60、不是联机副本、通过「该接」过滤，取 Q 最小的；连续成立的帧合并成一次放刀，不设超时。
-- 「该接」（V16 第 3 节，游戏自己的抵消判定 G1，没有按怪、按招的表）：不是弹体；_IsParryBreak 为假（被弹开 4/4 是 pb=1，
--   实测）；GuardType 是 NORMAL / ALL_RANGE；不是咆哮、风压、震动、抓取。读不准就不放（放错比不放糟：pb=1 上放刀被弹开加
--   挨打，抓取上放刀被抓 259 伤害，实测）。
-- 否决（按原始 hs）：视野（hs ≤ 90、he ≥ 0）里有长窗口、抓取或 SKILL_GUARD 家族的攻击就整帧不放；否决侧读不到类型按不是抓取。
-- 提前量 L 默认 28（Q 单位，滑块 23~45），L_min 22。抵消窗口（实测）：首个接触 < 0.328 s 接不住、0.331~≥0.944 s 全接住。
-- 结局（只用于菜单统计和调试日志）：放刀后 1.3 s 内进 (2,26)/(2,27) 记接住；进 (2,25) 记被弹开（会随即挨打，实测）。
-- 引用记账（NOTES「跨帧持有与 REF 的引用记账」）：REF 按地址给整个 Lua 状态记一份游戏侧引用、所有脚本共用，谁先手动扣，
--   同时持有的另一个脚本就拿着悬空指针（实测）。所以登记时只 add_ref、丢弃时只删 Lua 引用，等 userdata 回收时 REF 自动扣；
--   本文件不调任何手动扣引用的接口。
-- 唯一有副作用的游戏调用是 changeActionRequest(0, (2,23), false)；只钩 receiveGameMessage 一个函数。
-- 联机没测过：发送者怪物 _Context:get_IsMaster() 为 false（副本）的只参与否决、不放刀，读不到按主机处理。
--
-- 本模块里的读取顺序、次数和 v1.6 逐项相同（出故障时报黄的时刻、放不放刀都靠它），改结构时别调换语句顺序；
-- 改完跑 tools/test.sh，mock 的合并模式逐刀和归档的 v1.6 比。
-- 攻击预告的读取（条目、弹体、联机闸门）在 lib/wilds/forecast；预告跟踪和 E5c 计时以后别的武器多半也要用，等第二个用户
-- 出现时再提升到库里（docs/ARCHITECTURE.md「还没进库的」）。
--
-- 对外（new 的返回值）：tick、reset、draw、enum_skip（加载时没读到的抓取名、黑名单名，写进 HDR）
local LIB = "AutoGuardGS.lib."
local util = require(LIB .. "util")
local ref = require(LIB .. "ref")
local COLOR = require(LIB .. "ui").COLOR
local Action = require(LIB .. "wilds.action")
local Enemy = require(LIB .. "wilds.enemy")
local Forecast = require(LIB .. "wilds.forecast")
local K = require("AutoGuardGS.const")

local M = {}

-- ctx：config、stats、F（util.formatter）、R（lib/record，放刀记录）、H（lib/health，错误分级）、prof（lib/prof）
function M.new(ctx)
    local config, stats, F, R, H, prof = ctx.config, ctx.stats, ctx.F, ctx.R, ctx.H, ctx.prof
    local Pa = { enum_skip = nil }
    local SPEED_FAIL_STREAK = 5         -- 连续这么多个新结果首帧读不到 C 就报黄
    local CLOCK_DMAX = 30               -- 时钟条目一对读数之间 hs 递减的上限：30 + 60 × 两次读数隔开的秒数（单帧 dt 钳在 0.133 s）
    local TRACK_MAX, TRACK_STALE = 32, 8.0   -- 最多跟踪 32 条；距最后一条消息 8 s 丢弃（实测最长预告 402 帧，约 6.7 s）
    local PAST_HE, PAST_AGE = -30, 1.0  -- 全部条目 he < -30 且距消息 ≥1 s：这一招早就打完了
    local CAT_ATTACK, IDX_SLASH, IDX_SLASH_FWD = 2, 23, 24   -- (2,23) cParrySlash 上捞斩；(2,24) 前进版
    local PARRY_CHARGE = { [21] = true, [22] = true }       -- 从 (2,22) 放刀也会被接受（v1.6 试打 7 刀里 3 刀，实测）
    local PARRY_OUT = { [25] = "RECOIL", [26] = "CATCH26", [27] = "CATCH27" }   -- 游戏自己切的结局动作（G1：(2,25) 是被弹）
    local STOP_FRAMES = 30              -- 帧逻辑连续出错这么多帧就自停
    -- 读主角/动作 ID 的调用抛错（切场景时对象正在销毁）：1.5 s 内按「这一帧不存在」处理，否则一次 0.1 s 的瞬时异常
    -- 3 帧内就会标红；间隔不到 0.5 s 的零星失败算同一段，间歇故障照样会在 1.5 s 后升级成错误
    local READ_FAIL_TOL, READ_FAIL_GAP = 1.5, 0.5

    local RT_DANGER, SLASH_ID = nil, nil   -- app.AttackAreaResult.RESULT_TYPE.DANGER；ace.ACTION_ID (2,23)
    local EFFECT_DAMAGE = {}    -- app.HitDef.DAMAGE_TYPE 的 EAR/WIND/QUAKE：咆哮、风压、震动不是能抵消的打击
    local effect_partial = false   -- 效果攻击有名字没读到：认不出的伤害类型可能就是它（候选侧按读不准处理）
    local GRAB_DAMAGE = {}      -- app.HitDef.DAMAGE_TYPE 的 CATCH/CATCH_ZAKO/CATCH_SLINGER：抓取，刀碰到了也抵消不了（实测）
    -- 攻击的防御类型 app.Hit.GUARD_TYPE（2026-10-11 MCP 核对：NORMAL、ALL_RANGE、UNABLE_GUARD、SKILL_GUARD、
    -- SKILL_GUARD_ALL_RANGE、MAX）：白名单 = 该接；SKILL_GUARD 家族同抓取（否决、不进候选）；UNABLE_GUARD 和其余值不该接
    local HIT_GUARD_WHITE, HIT_GUARD_SG, HIT_GUARD_UG = {}, {}, nil
    local filter_enum_missing = nil   -- 读不到的过滤枚举名（效果名、白名单名），状态行写清缺了哪个
    local T_ENEMY = nil         -- sdk.typeof("app.EnemyCharacter")：联机闸门从发送者身上取怪物

    local function self_stop_init(err)     -- 核心类型或钩子拿不到，规则无法运行：直接自停并标红（防御照常）
        H.note("frame", err)
        H.set_red(os.clock(), "frame", "init")
        H.stopped = true
    end

    -- 唯一有副作用的游戏调用：帧开头请求上捞斩，走动作控制器的正常进入流程（NOTES「改动作」实测）
    local function request_slash(hunter)
        local ok, err = pcall(Action.request, hunter, SLASH_ID)
        if not ok then H.note("fire", err) end
    end

    -- 预告跟踪。跨帧只持有结果对象 tr.obj（登记时 add_ref、丢弃时只删 Lua 引用）；条目、怪物、主角对象只在当帧用，
    -- 跨帧只存地址和数值
    local tracks, n_tracks = {}, 0      -- [结果地址] = 跟踪记录（字段见 on_message）
    local me_addr, me_gs = nil, false   -- 主角 HunterCharacter 地址、是不是大剑（每帧更新）
    local function drop_track(key) if tracks[key] then tracks[key], n_tracks = nil, n_tracks - 1 end end
    local function release_all_tracks() tracks, n_tracks = {}, 0 end
    -- 满了丢 t_msg 最旧的（最久没收到消息的），不按登记先后
    local function drop_oldest()
        local old_key, old_t = nil, nil
        for key, tr in pairs(tracks) do
            if not old_t or tr.t_msg < old_t then old_key, old_t = key, tr.t_msg end
        end
        if old_key then drop_track(old_key) end
    end

    -- 钩子里不读速度（见头注释），只存 SystemIndex。每个结果对象只发一条消息（1620/1620，实测）；万一已跟踪的结果又来消息
    -- 只刷新 t_msg：E5c 按条目首见时刻记 X0，不用重置（重置反而会清掉已经累加的 X）
    local function on_message(args)
        if not config.auto_parry or H.stopped or not me_addr or not me_gs then return end
        local msg = sdk.to_managed_object(args[3])
        if not msg or msg:get_type_definition():get_full_name() ~= Forecast.MSG_TYPE then return end
        local r = msg:call("get_AttackAreaResult")
        if not r then return end
        local key, now = r:get_address(), os.clock()
        if tracks[key] then
            tracks[key].t_msg = now
            return
        end
        local target = r:call("get_TargetCharacter")
        if not target or target:get_address() ~= me_addr then return end
        if r:call("get_IsAttackFinished") then return end   -- 到达时就已结束的不跟踪（训练机关每个周期都发空预告）
        local idx = r:call("get_EmSystemIndex")
        -- get_EmID 必须在登记时读（不能挪到写 FIRE 时）：它抛错会让整条预告不登记，挪走就改了出故障时放不放刀
        local em = "em" .. F.int(r:call("get_EmID")) .. "#" .. F.int(idx)
        -- 是不是主机只在登记时读一次。读不到按主机处理（fail-open，单人时恒为 true）；抛错第一次标黄并停用这项读取
        local master = nil
        if not H.off.master then
            local ok, m = pcall(Forecast.read_master, msg, T_ENEMY)
            if ok then master = m else H.note("master", m) end
        end
        if n_tracks >= TRACK_MAX then drop_oldest() end
        r:add_ref()
        -- E5c：X = 怪物比计时器多走的名义帧；x0 / a0 = 条目首见时的 X、hs；hs_prev / t_prev = 上次读到的 [条目地址] = hs 和
        -- 时刻；c1 / cf = 首帧 / 本帧原始 C，nchg = m 变了几次（这三个和 a0 只给 FIRE 用：诊断放早）
        tracks[key] = { obj = r, t_msg = now, em = em, master = master ~= false, idx = math.tointeger(idx), first = true,
            m = nil, X = 0.0, x0 = {}, a0 = {}, hs_prev = nil, clock = nil, nchg = 0, c1 = nil, cf = nil, nofire = false }
        n_tracks = n_tracks + 1
    end

    -- 速度（E5c，V16 第 2 节）。speed_cache[SystemIndex] = 本帧读到的 { c = C 或 nil }，每帧清空；spd = 首帧连续读不到的
    -- 结果数、≥5 的状态（状态行用）
    local speed_cache = {}
    local spd = { streak = 0, x5 = false, x5_ever = false, err = false }
    -- 读路径照抄 APCal 的 find_enemy（实测）。2026-10-11 MCP get_type 核对：findEnemy_SystemIndex(System.Int32) →
    -- app.cEnemyManageInfo；get_Character() → app.EnemyCharacter；CoreState → System.Single
    local function core_read(idx)
        local enemy = Enemy.by_system_index(idx)
        if not enemy then return nil end
        local c = enemy:call("get_MotionSpeed_CoreState")
        if not util.finite(c) or c < K.C_LO or c > K.C_HI then return nil end
        return c
    end
    -- 读 C 抛错不算帧逻辑错误（不进 frame 的红计数、不进 30 帧自停）：第一次报黄 speed，不停用读取
    local function core_of(idx)
        if idx == nil then return nil end
        local s = speed_cache[idx]
        if not s then
            local ok, c = pcall(core_read, idx)
            if not ok and not spd.err then
                spd.err = true
                H.note("speed", c)
            end
            s = { c = ok and c or nil }
            speed_cache[idx] = s
        end
        return s.c
    end
    -- 时钟条目两帧之间 hs 的递减：优先沿用上一帧用过的那条；不在了按条目表顺序找第一条两帧都有的，并改记 tr.clock
    local function clock_delta(tr, list, cur)
        local prev, c = tr.hs_prev, tr.clock
        if c and cur[c] and prev[c] then return prev[c] - cur[c] end
        for _, e in ipairs(list) do
            if prev[e.key] then tr.clock = e.key; return prev[e.key] - e.hs end
        end
    end
    -- 每帧每个结果（不论在不在蓄力，X 要从登记起连续累加）。list 为 nil（读出错）的帧不累加、不记 X0，C 照读。之后那一对
    -- 读数（读主角抛错的容忍期同样）跨好几帧：乘最后的 m（近似），上限按隔开的时间放宽（固定 30 时断档 ≥0.5 s 整段不累加）
    local function speed_step(tr, list, now)
        local C = core_of(tr.idx)
        local cur = list and {} or nil
        for _, e in ipairs(list or {}) do cur[e.key] = e.hs end
        -- (a) 累加：上一帧的 m × 同一条条目两帧之间 hs 的递减（写成「在区间里才累加」，NaN 也不累加）
        if cur and tr.hs_prev and tr.m then
            local d = clock_delta(tr, list, cur)
            if d and d >= 0 and d <= CLOCK_DMAX + 60.0 * (now - tr.t_prev) then tr.X = tr.X + d * (tr.m - 1.0) end
        end
        -- (b) m：登记后第一个帧回调 = 离线验证的采样点
        if tr.first then
            tr.first = false
            if C then
                tr.m, tr.c1 = math.max(1.0, C), C
                spd.streak, spd.x5 = 0, false
            else
                tr.nofire, spd.streak = true, spd.streak + 1
                if spd.streak >= SPEED_FAIL_STREAK and not spd.x5 then   -- 每次进入这个状态报一次黄，不停用读取
                    spd.x5, spd.x5_ever = true, true
                    H.note("speed", "first_frame_fail_x5")
                end
            end
        elseif tr.m and C then   -- 中途读不到：沿用上一帧的 m
            local m = math.max(1.0, C)
            if math.abs(m - tr.m) > 1e-4 then tr.nchg = tr.nchg + 1 end
            tr.m = m
        end
        tr.cf = C
        -- (c) 首次读到的条目记 X0、A0（之后不重置，即使中途消失再出现）
        if cur then
            for _, e in ipairs(list) do
                if tr.x0[e.key] == nil then tr.x0[e.key], tr.a0[e.key] = tr.X, e.hs end
            end
            tr.hs_prev, tr.t_prev = cur, now
        end
    end

    -- 条目读取与「该接」过滤（V16 第 3 节）
    -- 过滤字段读取出错（抛错、类型不对、ShellIndex 形态不认识）：第一次报黄 filter，不停用读取（停用就再也放不了刀）
    local function filter_error(err)
        if not H.off.filter then H.note("filter", err) end
    end
    -- 弹体（lib/wilds/forecast 的 has_shell）：返回 true / false / nil（读不准）；本帧结果缓存在条目表上
    local function shell_of(e)
        if e.s == nil then
            local ok, v = pcall(Forecast.has_shell, e.d)
            if ok then e.s = v else
                filter_error(v)
                e.s = "?"
            end
        end
        if e.s == "?" then return nil end
        return e.s
    end
    -- 读攻击参数的一个字段（每个字段单独 pcall：_GuardType 读坏了不能连带丢掉只靠 _DamageType 的抓取否决）。
    -- 整数字段返回整数、布尔字段返回布尔；抛错或类型不对报 filter、返回 nil
    local function ap_field(ap, name, want_bool)
        local ok, v = pcall(ap.get_field, ap, name)
        if ok and want_bool and type(v) == "boolean" then return v end
        local iv = ok and not want_bool and math.tointeger(v) or nil
        if iv then return iv end
        filter_error(ok and (name .. "=" .. tostring(v)) or v)
        return nil
    end
    -- 攻击参数 cAttackParamEm（字段 2026-10-11 MCP 核对）→ c：dmg_ok、grab、effect（nil = 效果名缺认不出）、guard_ok、
    -- g（white | ug | sg | unknown）、pb（nil = 读不准）。攻击参数为 nil 是数据情况（em27 个别条目），不报黄。
    -- 本帧缓存在条目上（否决、候选共用）
    local function classify(e)
        if e.c then return e.c end
        local c = { dmg_ok = false, guard_ok = false }
        e.c = c
        local ok, ap = pcall(e.d.call, e.d, "get_AttackParam")
        if not ok then filter_error(ap) end
        if not ok or ap == nil then return c end
        local t = ap_field(ap, "_DamageType")
        if t then
            c.dmg_ok, c.grab = true, GRAB_DAMAGE[t] ~= nil
            if EFFECT_DAMAGE[t] then c.effect = true elseif not effect_partial then c.effect = false end
        end
        local g = ap_field(ap, "_GuardType")
        if g then
            c.guard_ok = true
            c.g = HIT_GUARD_WHITE[g] and "white" or (g == HIT_GUARD_UG and "ug") or (HIT_GUARD_SG[g] and "sg") or "unknown"
        end
        c.pb = ap_field(ap, "_IsParryBreak", true)
        return c
    end
    -- 该接 = 下面几条同时成立，哪一条读不准都按不该接（fail-closed）。和 v1.6 的 filter_reason(...) == nil 逐项等价（MERGE 2.7）。
    -- 弹体放在最后读：只对前面全部通过的条目读 ShellIndex，和 v1.6 对该接条目的读取顺序相同
    local function catchable(e)
        local c = classify(e)
        if not (c.dmg_ok and c.guard_ok) then return false end      -- 伤害类型或防御类型读不准
        if c.grab or c.effect ~= false then return false end        -- 抓取；效果攻击（true）；效果名缺、认不出（nil）
        if c.g ~= "white" then return false end                     -- SKILL_GUARD 家族、UNABLE_GUARD、未知值
        if c.pb ~= false then return false end                      -- _IsParryBreak 为真，或读不准
        return shell_of(e) == false                                 -- 是弹体，或读不准
    end

    -- 规则（V16 2.4）。每条 DANGER 条目：否决按原始 hs（读不到类型 → 不否决）；候选按 Q。否决只记有没有：放不放只看这一帧
    -- 有没有否决。否决侧对视野内每条 DANGER 条目都读 classify，见到一个否决也不提前停：读取的顺序和次数要和 v1.6 一样
    -- （否则出故障时报黄的时刻会变）
    local function consider(tr, list, ev)
        local L = ev.L
        for _, e in ipairs(list) do
            if e.rt == RT_DANGER then
                local hs, he = e.hs, e.he
                local w = he - hs
                local x0 = tr.x0[e.key]
                local Q = (tr.m and not tr.nofire and x0) and (hs - (tr.X - x0)) / tr.m or nil
                if hs <= K.VETO_HORIZON and he >= 0 then
                    local c = classify(e)
                    -- SKILL_GUARD 家族同抓取；两者都永远不进候选
                    if w > K.LONG_WINDOW or (c.dmg_ok and c.grab) or (c.guard_ok and c.g == "sg") then ev.veto = true end
                end
                -- catchable 在区间条件之后、比较 Q 之前：条目一落进窗口就做过滤读取（同 v1.6）
                if Q and tr.master and w >= 0 and w <= K.LONG_WINDOW and Q >= K.LEAD_MIN and Q <= L and catchable(e) then
                    if not ev.best or Q < ev.best.Q then ev.best = { tr = tr, e = e, Q = Q } end
                end
            end
        end
    end

    -- 每帧每条预告（V16 2.3 的顺序）：清理 → 读条目（每帧都读，不论在不在蓄力）→ 速度 → 打完了 → ev 非 nil 时参与规则求值
    local function process_track(tr, now, ev)
        local age, r = now - tr.t_msg, tr.obj
        if age >= TRACK_STALE then return "stale" end
        if r:call("get_IsAttackFinished") then return "finished" end
        local ok, list = pcall(Forecast.read_items, r)
        if not ok then
            -- 逐条读取出错：本帧不放刀、不否决、不按 he 丢弃，速度照读；第一次标黄但不停用（停用就再也放不了刀）
            if not H.off.items then H.note("items", list) end
            list = nil
        end
        speed_step(tr, list, now)
        if not list then return nil end
        -- 「全部条目 he < -30」只对非空列表成立：未结束、暂时没有条目的结果要继续持有到 8 s
        if age >= PAST_AGE and #list > 0 then
            local past = true
            for _, e in ipairs(list) do
                if not (e.he < PAST_HE) then past = false break end
            end
            if past then return "past" end
        end
        if ev then
            local target = r:call("get_TargetCharacter")
            if target and target:get_address() == me_addr then consider(tr, list, ev) end
        end
    end

    -- 清理全部跟踪；L 非 nil 时同时求值，返回 ev = { L, veto, best }。单条预告读坏了就丢掉它、计一次帧逻辑错误
    local function evaluate(now, L)
        local ev = L and { L = L } or nil
        for key, tr in pairs(tracks) do
            local ok, why = pcall(process_track, tr, now, ev)
            if not ok then H.note("frame", why) end
            if not ok or why then drop_track(key) end
        end
        return ev
    end

    -- 放刀 streak 与结局。写 FIRE / RES 的代码只读状态、不写状态：next_id、计数、res_wait 的记账都不看调试日志开没开，
    -- 调试日志开着和关着放刀完全一样（MERGE 2.7 B 类）
    local streak = nil          -- { id, t }：条件连续成立的帧合并为一次放刀
    local res_wait = nil        -- { id, t, to, entered }：等 CREDIT 秒内进 (2,25..27)
    local next_id = 1           -- 每次放刀都递增，FIRE 和 RES 靠它对上
    local function keep_text(r)
        local k = r:call("get_KeepActionID")
        return k and ("(" .. F.int(k:get_field("_Category")) .. "," .. F.int(k:get_field("_Index")) .. ")") or nil
    end
    local function keep_or_nil(r)   -- keep 只是 FIRE 的诊断字段：读不到写 -，不算错误
        local ok, k = pcall(keep_text, r)
        return ok and k or nil
    end
    local function finish_res(now, outcome)
        local w = res_wait
        res_wait = nil
        if outcome == "CATCH26" then stats.catch26 = stats.catch26 + 1
        elseif outcome == "CATCH27" then stats.catch27 = stats.catch27 + 1
        elseif outcome == "RECOIL" then stats.recoils = stats.recoils + 1
        else stats.nocatch = stats.nocatch + 1 end
        if config.debug_log then R.emit("RES", { w.id, now, outcome, now - w.t, w.to, w.entered }) end
    end
    local function start_streak(now, ev, idx)
        if res_wait then finish_res(now, "NOCATCH") end   -- 又回到蓄力了，上一刀不可能再接住
        streak = { id = next_id, t = now }
        next_id, stats.fires = next_id + 1, stats.fires + 1
        if config.debug_log then
            local b = ev.best
            local tr, e = b.tr, b.e
            R.emit("FIRE", { streak.id, now, ev.L, e.hs, e.he, e.key, ref.addr_of(tr.obj), tr.em, keep_or_nil(tr.obj),
                "(" .. F.int(CAT_ATTACK) .. "," .. F.int(idx) .. ")", tr.c1, tr.cf, tr.m, tr.nchg, tr.X - tr.x0[e.key],
                tr.a0[e.key], b.Q })
        end
    end
    -- 每次放刀都有一行 RES（离线一一对应）：没放出去（entered = false）当场结算成 NOCATCH；放出去了等结局
    local function end_streak(now, entered)
        local s = streak
        streak = nil
        if res_wait then finish_res(now, "NOCATCH") end
        res_wait = { id = s.id, t = s.t, to = nil, entered = entered }
        if not entered then finish_res(now, "NOCATCH") end
    end

    local function update_fire(hunter, now, cat, idx)
        -- 请求被接受，下一帧就在 (2,23) 里了（实测都是下一帧）
        if streak and cat == CAT_ATTACK and idx == IDX_SLASH then end_streak(now, true) end
        if res_wait and not streak then
            -- RES 的 to：进 (2,23) 后第一次看到的、不是 (2,23)/(2,24) 的动作（粗分「停在 (2,23)」和「被打出去」，V16 第 4 节）
            if not res_wait.to and cat ~= nil and idx ~= nil
                and not (cat == CAT_ATTACK and (idx == IDX_SLASH or idx == IDX_SLASH_FWD)) then
                res_wait.to = "(" .. F.int(cat) .. "," .. F.int(idx) .. ")"
            end
            if cat == CAT_ATTACK and PARRY_OUT[idx] then finish_res(now, PARRY_OUT[idx])
            elseif now - res_wait.t >= K.CREDIT then finish_res(now, "NOCATCH") end
        end
        -- 前提：开关、大剑、基础层在 (2,21)/(2,22)；任一不满足就结束 streak（清理和速度照常做）
        local active = config.auto_parry and not H.stopped and me_gs
            and cat == CAT_ATTACK and PARRY_CHARGE[idx] == true
        local ev = evaluate(now, active and config.parry_lead or nil)
        if not active then
            if streak then end_streak(now, false) end
            return
        end
        if ev.best and not ev.veto then
            -- Q ≤ L 已在 consider 里保证；不设超时：Q 单调递减（m 变化那一帧跳一下），离开 [L_min, L] 自然停
            if not streak then start_streak(now, ev, idx) end
            request_slash(hunter)
        elseif streak then
            end_streak(now, false)
        end
    end

    local consec_err = 0
    local read_fail = { t0 = nil, t_last = nil }
    local function lose_hunter(now)    -- 主角为 nil 或换了（换场景等）：全部丢弃
        release_all_tracks()
        if streak then end_streak(now, false) end
        if res_wait then finish_res(now, "NOCATCH") end
        me_addr = nil
    end
    -- 读主角抛错时：容忍期内返回 false（这一帧跳过），超过容忍期返回 true（按帧逻辑出错处理）
    local function read_failed(now)
        local F = read_fail
        if not F.t0 or now - F.t_last > READ_FAIL_GAP then F.t0 = now end
        F.t_last = now
        return now - F.t0 >= READ_FAIL_TOL
    end

    -- 帧开头（快照之后、防御段之后）。rok = 读主角没抛错；rok 为 false 时 hunter 是错误信息
    local function parry_frame(now, rok, hunter, addr, gs, cat, idx)
        if not rok then
            if read_failed(now) then error(hunter, 0) end
            return      -- 容忍期内：这一帧不存在（不求值、不放刀，streak、跟踪和 E5c 的状态都保持原样）
        end
        if read_fail.t0 and now - read_fail.t_last > READ_FAIL_GAP then read_fail.t0 = nil end
        if not hunter then
            if me_addr or n_tracks > 0 then lose_hunter(now) end
            me_gs = false
            return
        end
        if me_addr and addr ~= me_addr then lose_hunter(now) end
        me_addr, me_gs = addr, gs
        if not config.auto_parry and n_tracks > 0 then release_all_tracks() end   -- 关开关时全部丢弃（菜单里只改配置）
        if next(speed_cache) ~= nil then speed_cache = {} end
        -- 主角在、动作 ID 暂时读不到（cat / idx 为 nil：切场景、加载的头几帧）：update_fire 里按「不在蓄力」处理，
        -- 不算帧逻辑出错（否则满 30 帧就自停）
        update_fire(hunter, now, cat, idx)
    end

    local function self_stop(now)
        H.stopped = true
        H.set_red(now, "frame", "self_stop")
        local ok, err = pcall(function()
            release_all_tracks()
            if streak then end_streak(now, false) end
            if res_wait then finish_res(now, "NOCATCH") end   -- 自停后帧逻辑不再跑、没人结算：每次放刀都要有结局
        end)
        if not ok then H.note("frame", err) end
    end

    function Pa.tick(now, rok, hunter, addr, gs, cat, idx)
        local ok, err = pcall(parry_frame, now, rok, hunter, addr, gs, cat, idx)
        consec_err = ok and 0 or consec_err + 1
        if not ok then H.note("frame", err) end
        if consec_err >= STOP_FRAMES then self_stop(now) end
    end

    -- Reset：丢弃预告跟踪（只删 Lua 引用，REF 回收 userdata 时自动扣引用，这里不手动扣），结算没结束的放刀和结局
    function Pa.reset(now)
        local ok, err = pcall(release_all_tracks)
        if not ok then H.note("frame", err) end
        ok, err = pcall(function()
            if streak then end_streak(now, false) end
            if res_wait then finish_res(now, "NOCATCH") end
        end)
        if not ok then H.note("frame", err) end
    end

    -- 类型、枚举、消息钩子。读的顺序同 v1.6；出错照 v1.6 分级（核心的拿不到就自停，防御照常）
    local function init()
        local ok, err = pcall(function()
            RT_DANGER = ref.enum_value("app.AttackAreaResult.RESULT_TYPE", "DANGER")
            SLASH_ID = Action.id(CAT_ATTACK, IDX_SLASH)
        end)
        if not ok then self_stop_init(err) end
        -- 效果名或白名单名缺任何一个：报黄 filter_enum，读不准的条目一律不放（缺效果名 = 不放刀了；缺 NORMAL = NORMAL 全不放）
        local missing = {}
        local e1 = ref.enum_into("app.HitDef.DAMAGE_TYPE", { "EAR", "WIND", "QUAKE" }, EFFECT_DAMAGE, missing)
        effect_partial = #missing > 0
        local e2 = ref.enum_into("app.Hit.GUARD_TYPE", { "NORMAL", "ALL_RANGE" }, HIT_GUARD_WHITE, missing)
        if #missing > 0 then
            filter_enum_missing = table.concat(missing, ",")
            H.note("filter_enum", filter_enum_missing .. " " .. tostring(e1 or e2))
        end
        -- 抓取名、黑名单名缺：只是少认一种抓取 / SG 否决（候选侧白名单已经排除），不报黄，记进 HDR 的 enum_skip
        local skipped, ug = {}, {}
        ref.enum_into("app.HitDef.DAMAGE_TYPE", { "CATCH", "CATCH_ZAKO", "CATCH_SLINGER" }, GRAB_DAMAGE, skipped)
        ref.enum_into("app.Hit.GUARD_TYPE", { "UNABLE_GUARD" }, ug, skipped)
        HIT_GUARD_UG = next(ug)
        ref.enum_into("app.Hit.GUARD_TYPE", { "SKILL_GUARD", "SKILL_GUARD_ALL_RANGE" }, HIT_GUARD_SG, skipped)
        if #skipped > 0 then Pa.enum_skip = table.concat(skipped, ",") end
        ok, err = pcall(function() T_ENEMY = sdk.typeof("app.EnemyCharacter") end)
        if not ok or not T_ENEMY then H.note("master", ok and "typeof app.EnemyCharacter = nil" or err) end
        ok, err = pcall(function()
            local td = sdk.find_type_definition("app.cMasterPlayerControllerEntity")
            sdk.hook(td:get_method("receiveGameMessage(ace.cGameMessage)"), prof.timed("msg", function(args)
                local ok2, err2 = pcall(on_message, args)
                if not ok2 then H.note("msg", err2) end
            end), nil)
        end)
        if not ok then self_stop_init(err) end
    end

    local ok, err = pcall(init)
    if not ok then self_stop_init(err) end

    -- 状态行。报黄但不停用读取的模块各有自己的措辞，不算「有可选模块停用，自动放刀照常」（那句只给 master、cfg、ui 等）
    local SOFT_MODS = { "items", "speed", "filter", "filter_enum" }
    local function draw_status()
        local E, p = H, {}
        local n_off = E.yellow
        for _, m in ipairs(SOFT_MODS) do if H.off[m] then n_off = n_off - 1 end end
        p[#p + 1] = E.stopped and "已自停（帧逻辑连续出错）" or E.red and "核心模块出错"
            or n_off > 0 and ("有可选模块停用（黄 " .. F.int(n_off) .. "），自动放刀照常") or nil
        if H.off.items then p[#p + 1] = "条目读取出过错：读不出条目的预告不放刀" end
        p[#p + 1] = spd.x5 and "速度读不到，已停止自动放刀" or spd.x5_ever and "速度曾读不到，已恢复" or nil
        if H.off.filter then p[#p + 1] = "过滤字段读取出过错：读不准的条目不放刀" end
        if H.off.filter_enum then
            p[#p + 1] = "过滤用的枚举读不到（缺 " .. tostring(filter_enum_missing) .. "）：这些攻击一律不放刀"
        end
        imgui.text("状态：" .. (#p > 0 and table.concat(p, "；") or "正常"))
        if E.red then imgui.text_colored("出错了：请把 re2_framework_log.txt 发给开发者，然后 Reset Scripts", COLOR.RED) end
    end

    local function draw_full()
        local changed, v = imgui.checkbox("自动放刀（实验）##ap_enabled", config.auto_parry)
        if changed then config.auto_parry = v == true end   -- 预告的丢弃、streak 的结束都在下一帧的帧逻辑里做
        imgui.text_colored("按住抵消蓄力时，危险攻击快到就自动放出抵消上捞斩；伤害、火花、弹开都是游戏原生的", COLOR.GRAY)
        draw_status()
        changed, v = imgui.slider_int("提前量（真实剩余帧，1/60 秒）##ap_lead", config.parry_lead, K.LEAD_LO, K.LEAD_HI)
        if changed and util.finite(v) then config.parry_lead = K.clamp_lead(v) end
        imgui.text_colored("已按怪物速度修正。越小越常出抵消动作；太小会被先打到。默认 " .. F.int(K.LEAD_DEFAULT), COLOR.GRAY)
    end

    function Pa.draw()   -- 出过错（ERR mod=ui）之后只画状态行和红字，同 v1.6 的简化菜单
        local ok2, err2 = pcall(H.off.ui and draw_status or draw_full)
        if not ok2 then H.note("ui", err2) end
    end
    return Pa
end

return M
