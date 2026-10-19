-- tools/mock/smoke/AutoParryGS.lua：冒烟测试用的最小 rc
--
-- 只给 tools/mock 自检用（lua tools/mock/run.lua --smoke），验证 mock、场景和断言能跑通；
-- 不是正式的 src/reframework/autorun/AutoParryGS.lua，也不部署。
-- 规则按 PLAN「DECISION RULE · A」最小实现；机关扫描按 P20 简化（固定 X 序列，不做边界细化）。

local TAG = "[AutoParryGS] "
local VER = "smoke-1"
local CFG_PATH = "AutoParryGS.json"
local LEAD_MIN, LONG_WINDOW, VETO_HORIZON, CREDIT = 18, 60, 90, 1.3
local TRACK_MAX, TRACK_STALE = 32, 8.0
local ROT = { 20, 24, 28, 32, 36 }
local SCAN_X = { 0.24, 0.28, 0.32, 0.36, 0.40, 0.50, 0.60, 0.70, 0.80, 0.90, 1.00,
    0.34, 0.38, 0.44, 0.56, 0.64, 0.76, 0.84, 0.30, 0.46, 0.54, 0.66, 0.74, 0.86 }
local SCAN_DELTA = 0.012

local cfg = { auto_parry = true, parry_lead = 28, lead_rotation = true, scan = false, debug_log = true }
do
    local ok, loaded = pcall(json.load_file, CFG_PATH)
    if ok and type(loaded) == "table" then
        for k, v in pairs(loaded) do
            if cfg[k] ~= nil and type(v) == type(cfg[k]) then cfg[k] = v end
        end
    end
    cfg.parry_lead = math.max(20, math.min(45, cfg.parry_lead))
end

local session = os.time()
math.randomseed(session)
local seq, records, last_flush = 0, {}, os.clock()
local stats = { fires = 0, catches = 0, vetoes = 0, fb = 0, failopen = 0, errors = 0 }

local function safe_fmt(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    if ok then return s end
    stats.errors = stats.errors + 1
    return "FMT_ERR " .. fmt
end

local function sval(v)
    if v == nil then return "-" end
    if v == true then return "1" end
    if v == false then return "0" end
    return (tostring(v):gsub("%s", "_"))
end

-- fields：{ {名字, 日志里的值, JSON 里的值（省略则同日志值）}, ... }
local function emit(kind, fields)
    local parts = { TAG .. kind }
    local rec = { k = kind }
    for _, f in ipairs(fields) do
        parts[#parts + 1] = f[1] .. "=" .. sval(f[2])
        local jv = f[3]
        if jv == nil then jv = f[2] end
        if type(jv) == "number" and (jv ~= jv or math.abs(jv) == math.huge) then jv = nil end
        rec[f[1]] = jv
    end
    log.info(table.concat(parts, " "))
    records[#records + 1] = rec
end

local function flush()
    if #records == 0 or seq >= 300 then return end
    seq = seq + 1
    local ok = json.dump_file(safe_fmt("AutoParryGS_%s_%s.json", tostring(session), tostring(seq)),
        { kind = "AutoParryGS", ver = VER, session = session, seq = seq, records = records })
    if not ok then stats.errors = stats.errors + 1 end
    records = {}
    last_flush = os.clock()
end

-- ---------- 错误分级（核心：10 s 内 ≥3 次标红；帧逻辑连续 30 帧出错自停） ----------
local err_hist, err_lines, err_last = {}, 0, -10
local red, stopped = false, false
local function on_error(mod, err)
    stats.errors = stats.errors + 1
    local now = os.clock()
    err_hist[#err_hist + 1] = now
    while err_hist[1] and now - err_hist[1] > 10 do table.remove(err_hist, 1) end
    if #err_hist >= 3 then red = true end
    if err_lines < 20 and now - err_last >= 1.0 then
        err_lines = err_lines + 1
        err_last = now
        emit("ERR", { { "mod", mod }, { "level", red and "red" or "yellow" }, { "msg", tostring(err):sub(1, 100) } })
    end
end

-- ---------- 类型与常量 ----------
local HunterCharacter = sdk.find_type_definition("app.HunterCharacter")
local RT_DANGER = sdk.find_type_definition("app.AttackAreaResult.RESULT_TYPE"):get_field("DANGER"):get_data(nil)
local EXCL = {}
do
    local DT = sdk.find_type_definition("app.HitDef.DAMAGE_TYPE")
    for _, n in ipairs({ "EAR", "WIND", "QUAKE" }) do EXCL[DT:get_field(n):get_data(nil)] = true end
end
local SLASH_ID = ValueType.new(sdk.find_type_definition("ace.ACTION_ID"))
SLASH_ID:set_field("_Category", 2)
SLASH_ID:set_field("_Index", 23)
local T_ENEMY = sdk.typeof("app.EnemyCharacter")

-- ---------- 预告跟踪 ----------
local tracked, tracked_n = {}, 0
local me_addr = nil

local function release_one(key)
    local tr = tracked[key]
    if not tr then return end
    pcall(tr.obj.release, tr.obj)
    tracked[key] = nil
    tracked_n = tracked_n - 1
end
local function release_all()
    for k in pairs(tracked) do release_one(k) end
end

sdk.hook(sdk.find_type_definition("app.cMasterPlayerControllerEntity"):get_method("receiveGameMessage(ace.cGameMessage)"),
    function(args)
        local ok, err = pcall(function()
            if not cfg.auto_parry or not me_addr then return end
            local msg = sdk.to_managed_object(args[3])
            if not msg or msg:get_type_definition():get_full_name() ~= "app.game_message.cMsgEmAttackAreaResult" then return end
            local r = msg:call("get_AttackAreaResult")
            if not r then return end
            local tgt = r:call("get_TargetCharacter")
            if not tgt or tgt:get_address() ~= me_addr then return end
            local key, now = r:get_address(), os.clock()
            local tr = tracked[key]
            if tr then
                tr.t_msg = now
                return
            end
            if tracked_n >= TRACK_MAX then
                local oldest, ot
                for k, x in pairs(tracked) do
                    if not ot or x.t_add < ot then oldest, ot = k, x.t_add end
                end
                release_one(oldest)
            end
            r:add_ref()
            tracked[key] = { obj = r, t_msg = now, t_add = now }
            tracked_n = tracked_n + 1
        end)
        if not ok then on_error("msg", err) end
    end, nil)

-- 逐条读；读不了就退回 closest（src=FB）
local function entries_of(r)
    local ok, res = pcall(function()
        local list = r:call("get_DetectedDataList")
        local out = {}
        for i = 0, list:call("get_Count") - 1 do out[#out + 1] = list:call("get_Item(System.Int32)", i) end
        return out
    end)
    if ok then return res, "V0" end
    return { r:call("getClosestDetectedData") }, "FB"
end

local function cleanup(now)
    for key, tr in pairs(tracked) do
        local ok, drop = pcall(function()
            local r = tr.obj
            if r:call("get_IsAttackFinished") then return true end
            if now - tr.t_msg >= TRACK_STALE then return true end
            if now - tr.t_msg >= 1.0 then
                local list = entries_of(r)
                if #list == 0 then return false end
                for _, d in ipairs(list) do
                    if d:call("get_HitEndRemainFrame") >= -30 then return false end
                end
                return true
            end
            return false
        end)
        if not ok or drop then release_one(key) end
    end
end

local function pass_shell(d)
    local ok, res = pcall(function()
        local sh = d:call("get_ShellIndex")
        if sh == nil then return true end
        return not sh:get_field("_HasValue")
    end)
    if ok then return res end
    stats.failopen = stats.failopen + 1
    return true
end

local function pass_dmg(d)
    local ok, res = pcall(function()
        local ap = d:call("get_AttackParam")
        return not (ap and EXCL[ap:get_field("_DamageType")])
    end)
    if ok then return res end
    stats.failopen = stats.failopen + 1
    return true
end

-- 规则：逐条取 DANGER、去弹体和效果攻击、去长窗口，长窗口 1.5 s 内到来就否决
local function earliest()
    local best = nil
    local veto = nil
    for _, tr in pairs(tracked) do
        local r = tr.obj
        if not r:call("get_IsAttackFinished") then
            local tgt = r:call("get_TargetCharacter")
            if tgt and tgt:get_address() == me_addr then
                local list, src = entries_of(r)
                if src == "FB" then
                    if r:call("get_ResultType") == RT_DANGER then stats.fb = stats.fb + 1 else list = {} end
                end
                for _, d in ipairs(list) do
                    if d:call("get_ResultType") == RT_DANGER then
                        local hs = d:call("get_HitStartRemainFrame")
                        local he = d:call("get_HitEndRemainFrame")
                        local span = he - hs
                        if span > LONG_WINDOW and hs <= VETO_HORIZON and he >= 0 and not veto then
                            veto = { hs = hs, he = he, d = d, r = r }
                        end
                        if hs >= LEAD_MIN and span >= 0 and span <= LONG_WINDOW and pass_shell(d) and pass_dmg(d) then
                            if not best or hs < best.q then best = { q = hs, he = he, d = d, r = r, src = src } end
                        end
                    end
                end
            end
        end
    end
    return best, veto
end

-- ---------- 轮换 ----------
local rot_order, rot_pos = {}, 1
local function new_group()
    rot_order = { ROT[1], ROT[2], ROT[3], ROT[4], ROT[5] }
    for i = 5, 2, -1 do
        local j = math.random(1, i)
        rot_order[i], rot_order[j] = rot_order[j], rot_order[i]
    end
    rot_pos = 1
end
new_group()
local function cur_L() if cfg.lead_rotation then return rot_order[rot_pos] end return cfg.parry_lead end
local function advance()
    rot_pos = rot_pos + 1
    if rot_pos > 5 then new_group() end
end

local function hex(o) return o and safe_fmt("%X", math.tointeger(o:get_address()) or 0) or "-" end

-- ---------- 扫描（简化版 P20） ----------
local scan = { machine = nil, machine_addr = nil, cycle = nil, last_name = nil, dcs = {}, queue = {}, tries = {},
    samples = 0, ok = 0, started = os.clock(), id = 0 }
for _, x in ipairs(SCAN_X) do scan.queue[#scan.queue + 1] = x end

sdk.hook(HunterCharacter:get_method("evHit_DamagePreProcess(app.HitInfo)"), function(args)
    if not cfg.scan then return end
    local ok, err = pcall(function()
        local info = sdk.to_managed_object(args[3])
        local owner = info and info:call("get_AttackOwner")
        local enemy = owner and owner:call("getComponent(System.Type)", T_ENEMY)
        if not enemy then return end
        if not scan.machine then
            scan.machine = enemy:add_ref()
            scan.machine_addr = enemy:get_address()
        end
        if enemy:get_address() ~= scan.machine_addr then return end
        local cy = scan.cycle
        if cy and not cy.contact then cy.contact = os.clock() end
    end)
    if not ok then on_error("scan", err) end
end, function(retval) return retval end)

local function median(list)
    local c = {}
    for i, v in ipairs(list) do c[i] = v end
    table.sort(c)
    return c[(#c + 1) // 2]
end

local function scan_done(now)
    emit("SCAN", { { "id", scan.id }, { "t", safe_fmt("%.4f", now), now }, { "phase", "done" }, { "X", nil },
        { "t0", nil }, { "Dc", nil }, { "t_req", nil }, { "status", nil }, { "reason", safe_fmt("ok%s_n%s", scan.ok, scan.samples) } })
    cfg.scan = false
    if scan.machine then pcall(scan.machine.release, scan.machine) end
    scan.machine = nil
end

local function scan_frame(me, now, dt, cat, idx)
    if not scan.machine then return end
    local act = scan.machine:call("getCurrentAction()")
    local name = act and act:get_type_definition():get_full_name() or "-"
    local small = name:match("%.cSmallAttack$") ~= nil
    local allowed = small or name:match("%.cToSmallAttack$") ~= nil
    if small and scan.last_name ~= name then
        local cy = { t0 = now, valid = true }
        if #scan.dcs >= 2 and #scan.queue > 0 then
            cy.X = table.remove(scan.queue, 1)
            cy.Dc = median(scan.dcs)
            cy.t_req = now + cy.Dc - cy.X - SCAN_DELTA
        end
        scan.cycle = cy
    end
    scan.last_name = name
    local cy = scan.cycle
    if not cy then return end
    if not allowed and not cy.contact then
        cy.valid = false
        cy.reason = "em_action"
    end
    if cy.X and cy.t_req and now >= cy.t_req and dt > 0.035 then cy.hitch = true end
    if cy.X and not cy.req_done then
        if now >= cy.t_req and now <= cy.t_req + 0.05 then
            if cat == 2 and (idx == 21 or idx == 22) then
                me:call("changeActionRequest(app.AppActionDef.LAYER, ace.ACTION_ID, System.Boolean)", 0, SLASH_ID, false)
                cy.req_t = cy.req_t or now
            elseif cat == 2 and idx == 23 then
                cy.req_done = true
            elseif not cy.req_t then
                cy.req_done = true
                cy.valid = false
                cy.reason = "not_charging"
            end
        elseif now > cy.t_req + 0.05 then
            cy.req_done = true
        end
    end
    if cy.contact or now - cy.t0 > 1.6 then
        scan.cycle = nil
        if not cy.X then
            if cy.contact and cy.valid and #scan.dcs < 5 then
                scan.dcs[#scan.dcs + 1] = cy.contact - cy.t0
                scan.id = scan.id + 1
                emit("SCAN", { { "id", scan.id }, { "t", safe_fmt("%.4f", now), now }, { "phase", "learn" }, { "X", nil },
                    { "t0", safe_fmt("%.4f", cy.t0), cy.t0 }, { "Dc", safe_fmt("%.3f", cy.contact - cy.t0), cy.contact - cy.t0 },
                    { "t_req", nil }, { "status", "OK" }, { "reason", nil } })
            end
            return
        end
        local ok = cy.contact and cy.valid and not cy.hitch and cy.req_t ~= nil
        local reason = (not cy.contact and "no_contact") or (cy.hitch and "hitch") or cy.reason
            or ((not cy.req_t) and "no_request") or nil
        scan.samples = scan.samples + 1
        scan.id = scan.id + 1
        if ok then
            scan.ok = scan.ok + 1
        else
            scan.tries[cy.X] = (scan.tries[cy.X] or 0) + 1
            if scan.tries[cy.X] < 3 then scan.queue[#scan.queue + 1] = cy.X end
        end
        emit("SCAN", { { "id", scan.id }, { "t", safe_fmt("%.4f", now), now }, { "phase", "fire" },
            { "X", safe_fmt("%.3f", cy.X), cy.X }, { "t0", safe_fmt("%.4f", cy.t0), cy.t0 }, { "Dc", safe_fmt("%.3f", cy.Dc), cy.Dc },
            { "t_req", safe_fmt("%.4f", cy.t_req), cy.t_req }, { "status", ok and "OK" or "VOID" }, { "reason", reason } })
        if scan.ok >= 24 or scan.samples >= 36 or #scan.queue == 0 or now - scan.started > 600 then scan_done(now) end
    end
end

-- ---------- 每帧 ----------
local streak, veto_on, res_wait = nil, false, nil
local next_id, consec_err = 1, 0
local cur_cat, cur_idx, last_now = nil, nil, os.clock()
local last_stat = os.clock()

local function end_streak(now, entered)
    if not streak then return end
    emit("FIRE_END", { { "id", streak.id }, { "t", safe_fmt("%.4f", now), now }, { "R1", safe_fmt("%.2f", streak.R1), streak.R1 },
        { "n", streak.n }, { "entered", entered } })
    if entered then
        if cfg.lead_rotation then advance() end
        res_wait = { id = streak.id, t = streak.t }
    end
    streak = nil
end

local function frame()
    local now = os.clock()
    local dt = now - last_now
    last_now = now
    cur_cat, cur_idx = nil, nil
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local p = pm and pm:call("getMasterPlayer")
    local me = p and p:call("get_Character")
    if not me then
        if me_addr then release_all() end
        me_addr = nil
        end_streak(now, false)
        return
    end
    if me:get_address() ~= me_addr then
        release_all()
        me_addr = me:get_address()
        streak = nil
    end
    cleanup(now)
    local ctrl = me:call("get_BaseActionController")
    local id = ctrl and ctrl:call("get_CurrentActionID")
    if not id then                     -- 动作控制器暂时读不到（切场景头几帧）：按不在蓄力处理，不算出错
        end_streak(now, false)
        veto_on = false
        return
    end
    local cat, idx = id:get_field("_Category"), id:get_field("_Index")
    cur_cat, cur_idx = cat, idx
    if res_wait then
        if cat == 2 and idx >= 25 and idx <= 27 then
            stats.catches = stats.catches + 1
            emit("RES", { { "id", res_wait.id }, { "t", safe_fmt("%.4f", now), now }, { "outcome", "CATCH" .. idx },
                { "dt", safe_fmt("%.3f", now - res_wait.t), now - res_wait.t } })
            res_wait = nil
        elseif now - res_wait.t > CREDIT then
            emit("RES", { { "id", res_wait.id }, { "t", safe_fmt("%.4f", now), now }, { "outcome", "NOCATCH" },
                { "dt", safe_fmt("%.3f", now - res_wait.t), now - res_wait.t } })
            res_wait = nil
        end
    end
    if streak and cat == 2 and idx == 23 then end_streak(now, true) end
    if cfg.scan then
        scan_frame(me, now, dt, cat, idx)
        return
    end
    local charging = cat == 2 and (idx == 21 or idx == 22) and me:call("get_WeaponType") == 0
    if not cfg.auto_parry or stopped or not charging then
        end_streak(now, false)
        veto_on = false
        return
    end
    local best, veto = earliest()
    if veto then
        if not veto_on then
            stats.vetoes = stats.vetoes + 1
            emit("VETO", { { "t", safe_fmt("%.4f", now), now }, { "hs", safe_fmt("%.2f", veto.hs), veto.hs },
                { "he", safe_fmt("%.2f", veto.he), veto.he }, { "res", hex(veto.r) }, { "ent", hex(veto.d) },
                { "em", safe_fmt("em%s#%s", veto.r:call("get_EmID"), veto.r:call("get_EmSystemIndex")) } })
        end
        veto_on = true
    else
        veto_on = false
    end
    local L = cur_L()
    if not veto and best and best.q <= L then
        if not streak then
            local keep = best.r:call("get_KeepActionID")
            streak = { id = next_id, t = now, L = L, n = 0 }
            next_id = next_id + 1
            stats.fires = stats.fires + 1
            emit("FIRE", { { "id", streak.id }, { "t", safe_fmt("%.4f", now), now }, { "L", L },
                { "R0", safe_fmt("%.2f", best.q), best.q }, { "he0", safe_fmt("%.2f", best.he), best.he }, { "src", best.src },
                { "ent", hex(best.d) }, { "res", hex(best.r) },
                { "em", safe_fmt("em%s#%s", best.r:call("get_EmID"), best.r:call("get_EmSystemIndex")) },
                { "keep", safe_fmt("(%s,%s)", keep:get_field("_Category"), keep:get_field("_Index")) },
                { "from", safe_fmt("(%s,%s)", cat, idx) } })
        end
        streak.n = streak.n + 1
        streak.R1 = best.q
        me:call("changeActionRequest(app.AppActionDef.LAYER, ace.ACTION_ID, System.Boolean)", 0, SLASH_ID, false)
    else
        end_streak(now, false)
    end
end

re.on_pre_application_entry("UpdateBehavior", function()
    local ok, err = pcall(frame)
    if ok then
        consec_err = 0
    else
        consec_err = consec_err + 1
        on_error("frame", err)
        if consec_err >= 30 and not stopped then
            stopped = true
            red = true
            streak = nil
        end
    end
    local now = os.clock()
    if now - last_stat >= 60 then
        last_stat = now
        emit("STAT", { { "fires", stats.fires }, { "catches", stats.catches }, { "vetoes", stats.vetoes }, { "fb", stats.fb },
            { "failopen", stats.failopen }, { "errors", stats.errors }, { "t", safe_fmt("%.4f", now), now } })
    end
    local busy = cur_cat == 2 and cur_idx and cur_idx >= 21 and cur_idx <= 29
    if not busy and tracked_n == 0 and now - last_flush >= 60 then flush() end
end)

local hud_window = false
re.on_frame(function()
    local text = red and "自动放刀 rc 出错，停下发日志"
        or safe_fmt("自动放刀 rc L=%s 放刀 %s 接住 %s 否决 %s", tostring(cur_L()), stats.fires, stats.catches, stats.vetoes)
    if not hud_window and pcall(draw.text, text, 20, 40, 0xFFFFFFFF) then return end
    hud_window = true
    imgui.begin_window("自动放刀 rc##APGS_hud", nil, 0)
    imgui.text(text)
    imgui.end_window()
end)

re.on_script_reset(function()
    release_all()
    if scan.machine then pcall(scan.machine.release, scan.machine) end
    scan.machine = nil
    flush()
end)

re.on_draw_ui(function()
    if not imgui.tree_node("自动放刀 rc##AutoParryGS") then return end
    local changed, v = imgui.checkbox("启用##auto_parry", cfg.auto_parry)
    if changed then
        cfg.auto_parry = v
        if not v then release_all() end
    end
    imgui.text(safe_fmt("放刀 %s 接住 %s 否决 %s 兜底 %s fail-open %s 错误 %s", stats.fires, stats.catches, stats.vetoes, stats.fb,
        stats.failopen, stats.errors))
    if imgui.button("写出数据##APGS_dump") then flush() end
    imgui.tree_pop()
end)

emit("HDR", { { "ver", VER }, { "session", session }, { "auto_parry", cfg.auto_parry }, { "lead", cfg.parry_lead },
    { "rotation", cfg.lead_rotation }, { "scan", cfg.scan }, { "L_min", LEAD_MIN }, { "W_long", LONG_WINDOW },
    { "H_veto", VETO_HORIZON }, { "credit", safe_fmt("%.1f", CREDIT), CREDIT } })
