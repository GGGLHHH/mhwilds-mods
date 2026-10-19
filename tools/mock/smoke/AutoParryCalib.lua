-- tools/mock/smoke/AutoParryCalib.lua：冒烟测试用的最小测量探针
--
-- 只给 tools/mock 自检用（lua tools/mock/run.lua --smoke）；不是正式的 probes/AutoParryCalib.lua。
-- 只记录，不改游戏。覆盖 run.lua 会核对的记录：HDR、HITCH/GAP、MSG、SER★、ACT、PT、CT、DMG、PH/PS、
-- EMHIT、EMINFO（可选）、POSE（可选）、SIG（可选）、ERR，以及 JSON 写出和 HUD/菜单。

local TAG = "[APCal] "
local VER = "smoke-1"
local session = os.time()
local seq, records, last_flush = 0, {}, os.clock()
local f = 0

local function safe_fmt(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    if ok then return s end
    return "FMT_ERR " .. fmt
end

local function sval(v)
    if v == nil then return "-" end
    if v == true then return "1" end
    if v == false then return "0" end
    return (tostring(v):gsub("%s", "_"))
end

local function emit(kind, fields, json_only)
    local parts = { TAG .. kind }
    local rec = { k = kind }
    for _, x in ipairs(fields) do
        parts[#parts + 1] = x[1] .. "=" .. sval(x[2])
        local jv = x[3]
        if jv == nil then jv = x[2] end
        if type(jv) == "number" and (jv ~= jv or math.abs(jv) == math.huge) then jv = nil end
        -- JSON 的 k 是记录种类；CT 的「本帧第几次」字段 k 在 JSON 里改叫 kf（和正式探针一致）
        rec[x[1] == "k" and "kf" or x[1]] = jv
    end
    if not json_only then log.info(table.concat(parts, " ")) end
    records[#records + 1] = rec
end

local function T(v) return safe_fmt("%.4f", v), v end

local function flush()
    if #records == 0 or seq >= 300 then return end
    seq = seq + 1
    local ok = json.dump_file(safe_fmt("APCal_%s_%s.json", tostring(session), tostring(seq)),
        { kind = "APCal", ver = VER, session = session, seq = seq, records = records })
    records = {}
    last_flush = os.clock()
    return ok
end

-- ---------- 错误分级 ----------
local CORE = { HDR = true, CLOCK = true, MSG = true, SER = true, ACT = true, PT = true, CT = true, DMG = true, PH = true,
    EMHIT = true, JSON = true }
local disabled, hist, err_lines, err_last = {}, {}, 0, -10
local red_n, yellow_n = 0, 0
local function mod_error(mod, err)
    local now = os.clock()
    local level
    if CORE[mod] then
        hist[#hist + 1] = now
        while hist[1] and now - hist[1] > 10 do table.remove(hist, 1) end
        if #hist >= 3 then
            level = "red"
            red_n = red_n + 1
        else
            level = "yellow"
        end
    else
        level = "yellow"
        yellow_n = yellow_n + 1
        disabled[mod] = true
    end
    if err_lines < 20 and (now - err_last >= 1.0 or level == "yellow") then
        err_lines = err_lines + 1
        err_last = now
        emit("ERR", { { "mod", mod }, { "level", level }, { "msg", tostring(err):sub(1, 100) } })
    end
end
local function run(mod, fn, ...)
    if disabled[mod] then return nil end
    local ok, r = pcall(fn, ...)
    if not ok then
        mod_error(mod, r)
        return nil
    end
    return r
end

-- ---------- 常量 ----------
local HC = sdk.find_type_definition("app.HunterCharacter")
local EC = sdk.find_type_definition("app.EnemyCharacter")
local Handling = sdk.find_type_definition("app.cHunterWeaponHandlingBase")
local Entity = sdk.find_type_definition("app.cMasterPlayerControllerEntity")
local RT = sdk.find_type_definition("app.AttackAreaResult.RESULT_TYPE")
local RT_DANGER = RT:get_field("DANGER"):get_data(nil)
local LAYER = sdk.find_type_definition("app.CollisionFilter.LAYER")
local L_GET = LAYER:get_field("ATTACK_GET"):get_data(nil)
local L_PARRY = LAYER:get_field("ATTACK_PARRY_GET"):get_data(nil)
local SF = sdk.find_type_definition("app.HunterDef.STATUS_FLAG")
local SA = SF:get_field("SUPER_ARMOR"):get_data(nil)
local T_ENEMY = sdk.typeof("app.EnemyCharacter")
local T_MOTION = sdk.typeof("via.motion.Motion")

local function enum_text(td)
    local parts = {}
    for _, fld in ipairs(td:get_fields()) do
        if fld:is_static() then parts[#parts + 1] = fld:get_name() .. ":" .. tostring(fld:get_data(nil)) end
    end
    return table.concat(parts, ",")
end

local function hex(o) return o and safe_fmt("%X", math.tointeger(o:get_address()) or 0) or "-" end
local function name_of(go) return go and go:call("get_Name") or "-" end

local me, me_go_addr, me_handling_addr = nil, nil, nil
local cache = { cat = nil, idx = nil, raw = 0, chara = 0, name = "-" }

-- ---------- HDR ----------
run("HDR", function()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local net = pm and pm:get_field("_CurrentNetworkPosition")
    local param = pm and pm:call("get_Catalog"):call("getWeaponActionParam(app.WeaponDef.TYPE)", 0)
    local function cfg_text(path)
        local ok, t = pcall(json.load_file, path)
        if not ok or type(t) ~= "table" then return "-" end
        return (json.dump_string(t) or "-"):gsub("%s", "")
    end
    emit("HDR", { { "ver", VER }, { "session", session }, { "net", net },
        { "guard_deg", param and safe_fmt("%.1f", param:get_field("_GuardDegree")) },
        { "aim_deg", param and safe_fmt("%.1f", param:get_field("_AimGuardDegree")) },
        { "overheat_parry", param and safe_fmt("%.2f", param:get_field("_ChargeParam_Parry"):get_field("_OverheatTime")) },
        { "cfg_guard", cfg_text("AutoGuardGS.json") }, { "cfg_parry", cfg_text("AutoParryGS.json") },
        { "enums", "RT=" .. enum_text(RT) } })
end)

emit("SELFTEST", { { "stage", 1 }, { "ok", 1 }, { "total", 1 }, { "failed", nil } })
local st2_done = false

-- ---------- MSG + 跟踪（SER 用） ----------
local tracked = {}
local ep_id = 0
local function ep_close(tr, reason, now)
    ep_id = ep_id + 1
    emit("EP", { { "id", ep_id }, { "obj", tr.hex }, { "epoch", 1 }, { "em", tr.em }, { "keep", tr.keep }, { "reason", reason },
        { "n_msg", tr.n_msg }, { "first_type", nil }, { "first_hs", nil }, { "types", nil }, { "rate_med", nil },
        { "rate_min", nil }, { "rate_max", nil }, { "stall", nil }, { "maxdt", nil }, { "charge_all", nil }, { "atk_on", nil },
        { "t0", T(tr.t0) }, { "t1", T(now) } })
end
local function release_all()
    for k, tr in pairs(tracked) do
        pcall(tr.obj.release, tr.obj)
        tracked[k] = nil
    end
end

sdk.hook(Entity:get_method("receiveGameMessage(ace.cGameMessage)"), function(args)
    run("MSG", function()
        local msg = sdk.to_managed_object(args[3])
        if not msg then return end
        local tn = msg:get_type_definition():get_full_name()
        if tn == "app.game_message.cMsgParrySuccess" then
            emit("PMSG", { { "t", T(os.clock()) }, { "state", msg:call("get_State") } })
            return
        end
        if tn ~= "app.game_message.cMsgEmAttackAreaResult" or not me then return end
        local r = msg:call("get_AttackAreaResult")
        if not r then return end
        local now = os.clock()
        local tme = r:call("get_TargetCharacter")
        tme = tme ~= nil and tme:get_address() == me:get_address()
        local key = r:get_address()
        local new = tracked[key] == nil
        local keep = r:call("get_KeepActionID")
        local list = r:call("get_DetectedDataList")
        local area = r:call("get_MergedAreaData")
        local rt = r:call("get_ResultType")
        emit("MSG", { { "t", T(now) }, { "f", f }, { "obj", hex(r) }, { "new", new }, { "tme", tme },
            { "em", safe_fmt("em%s#%s", r:call("get_EmID"), r:call("get_EmSystemIndex")) },
            { "keep", safe_fmt("%s_%s", keep:get_field("_Category"), keep:get_field("_Index")) }, { "rt", rt },
            { "n", list and list:call("get_Count") }, { "mstart", area and safe_fmt("%.1f", area:get_field("AttackStartFrame")) },
            { "mend", area and safe_fmt("%.1f", area:get_field("AttackEndFrame")) },
            { "closest", hex(r:call("getClosestDetectedData")) }, { "fin", r:call("get_IsAttackFinished") } })
        if tme then
            if new then
                r:add_ref()
                tracked[key] = { obj = r, t_msg = now, t0 = now, n_msg = 1, hex = hex(r),
                    em = safe_fmt("em%s#%s", r:call("get_EmID"), r:call("get_EmSystemIndex")),
                    keep = safe_fmt("%s_%s", keep:get_field("_Category"), keep:get_field("_Index")) }
            else
                tracked[key].t_msg = now
                tracked[key].n_msg = tracked[key].n_msg + 1
            end
            if rt == RT_DANGER and not st2_done then
                st2_done = true
                emit("SELFTEST", { { "stage", 2 }, { "ok", 1 }, { "total", 1 }, { "failed", nil } })
            end
            if rt == RT_DANGER then
                -- EMINFO（可选）：怪物速度、目标、主从
                run("EMINFO", function()
                    local go = msg:call("get_SendGameObject")
                    local enemy = go and go:call("getComponent(System.Type)", T_ENEMY)
                    if not enemy then return end
                    local ctx = enemy:get_field("_Context")
                    local tgt = ctx:get_field("_Em"):get_field("Target"):call("getTarget(System.Boolean, app.cEmModuleTarget.TARGET_ORDER)", false, 0)
                    local pos = go:call("get_Transform"):call("get_Position")
                    emit("EMINFO", { { "t", T(now) }, { "em", r:call("get_EmID") }, { "when", "DANGER" },
                        { "tgt", safe_fmt("%s/%s", tgt:get_field("Category"), tgt:get_field("UniqueIndex")) },
                        { "speed_t", safe_fmt("%.3f", enemy:call("calcMotionSpeedTotal(System.Boolean)", true)) },
                        { "speed_f", safe_fmt("%.3f", enemy:call("calcMotionSpeedTotal(System.Boolean)", false)) },
                        { "ts", safe_fmt("%.3f", go:call("get_TimeScale")) }, { "master", ctx:call("get_IsMaster") },
                        { "x", safe_fmt("%.2f", pos.x) }, { "y", safe_fmt("%.2f", pos.y) }, { "z", safe_fmt("%.2f", pos.z) } })
                end)
            end
        end
    end)
end, nil)

-- ---------- PT ----------
local pt, pt_id = nil, 0
local function pt_close(now)
    if not pt then return end
    local cls
    if pt.hit_idx then cls = "CATCH"
    elseif pt.blade + pt.body == 0 then cls = "WHIFF"
    else cls = "FAIL_OTHER" end
    emit("PT", { { "id", pt.id }, { "t_obs", T(pt.t_obs) }, { "raw0", safe_fmt("%.4f", pt.raw0), pt.raw0 },
        { "t_start", T(pt.t_start) }, { "from", pt.from }, { "hold", nil }, { "lv", nil },
        { "contacts_blade", pt.blade }, { "contacts_body", pt.body }, { "ph", pt.ph }, { "ps", pt.ps },
        { "hit_t", pt.hit_t and safe_fmt("%.3f", pt.hit_t) }, { "hit_idx", pt.hit_idx }, { "recoil", false },
        { "emhit", pt.emhit }, { "dmg", safe_fmt("%.1f", pt.dmg), pt.dmg }, { "online_class", cls } })
    pt = nil
end

-- ---------- CT / DMG / PH / PS / EMHIT ----------
local ct_stack = {}
sdk.hook(HC:get_method("evHit_DamagePreProcess(app.HitInfo)"), function(args)
    ct_stack[#ct_stack + 1] = false
    run("CT", function()
        if not me or sdk.to_managed_object(args[2]) ~= me then return end
        local info = sdk.to_managed_object(args[3])
        local owner = info:call("get_AttackOwner")
        local enemy = owner and owner:call("getComponent(System.Type)", T_ENEMY)
        if not enemy then return end
        local dobj = info:call("get_DamageObj")
        local layer = info:call("get_CollisionLayer")
        local dname = name_of(dobj)
        local cls = (dname == "it0000_0002_0" and layer == L_PARRY) and "BLADE" or (layer == L_GET and "BODY" or "OTHER")
        local flags = me:call("get_HunterStatus"):get_field("_HunterStatusFlag")
        ct_stack[#ct_stack] = { t = os.clock(), atk = name_of(owner), em = hex(enemy), dobj = dname, layer = layer, cls = cls,
            ps = me:call("get_WeaponHandling"):call("get_ParryState"), sa = flags:call("check(System.UInt32)", SA) }
    end)
end, function(retval)
    local c = table.remove(ct_stack)
    if c then
        run("CT", function()
            local res = sdk.to_int64(retval) & 0xFFFFFFFF
            emit("CT", { { "t", T(c.t) }, { "f", f }, { "k", 1 }, { "atk", c.atk }, { "atk_em", c.em }, { "dmgobj", c.dobj },
                { "layer", c.layer }, { "cls", c.cls }, { "ps", c.ps }, { "res", res },
                { "act", safe_fmt("%s_%s", cache.cat, cache.idx) }, { "raw", safe_fmt("%.4f", cache.raw), cache.raw },
                { "sa", c.sa }, { "shell", false }, { "px", nil }, { "py", nil }, { "pz", nil } })
            if pt then
                if c.cls == "BLADE" then pt.blade = pt.blade + 1 elseif c.cls == "BODY" then pt.body = pt.body + 1 end
            end
        end)
    end
    return retval
end)

sdk.hook(HC:get_method("evHit_Damage(app.HitInfo)"), nil, function(retval)
    run("DMG", function()
        if not me then return end
        local di = me:call("get_DamageInfo")
        local total = di:get_field("_TotalDamage")
        emit("DMG", { { "t", T(os.clock()) }, { "total", safe_fmt("%.1f", total), total }, { "react", di:get_field("_GuardReaction") } })
        if pt then pt.dmg = pt.dmg + total end
    end)
    return retval
end)

sdk.hook(Handling:get_method("onParryHit(app.HunterDef.PARRY_STATE, via.GameObject, via.vec3)"), function(args)
    run("PH", function()
        if sdk.to_managed_object(args[2]):get_address() ~= me_handling_addr then return end
        local st = sdk.to_int64(args[3]) & 0xFFFFFFFF
        emit("PH", { { "t", T(os.clock()) }, { "state", st }, { "target", name_of(sdk.to_managed_object(args[4])) },
            { "raw", safe_fmt("%.4f", cache.raw), cache.raw }, { "chara", safe_fmt("%.4f", cache.chara), cache.chara },
            { "delay", nil } })
        if pt then pt.ph = st end
    end)
end, nil)

sdk.hook(Handling:get_method("onParrySuccess(app.HunterDef.PARRY_STATE)"), function(args)
    run("PH", function()
        if sdk.to_managed_object(args[2]):get_address() ~= me_handling_addr then return end
        local st = sdk.to_int64(args[3]) & 0xFFFFFFFF
        emit("PS", { { "t", T(os.clock()) }, { "state", st } })
        if pt then pt.ps = st end
    end)
end, nil)

sdk.hook(EC:get_method("evHit_DamagePreProcess(app.HitInfo)"), function(args)
    run("EMHIT", function()
        if not me or not cache.idx or cache.cat ~= 2 or cache.idx < 23 or cache.idx > 29 then return end
        local info = sdk.to_managed_object(args[3])
        local owner = info:call("get_AttackOwner")
        if not owner or owner:get_address() ~= me_go_addr then return end
        emit("EMHIT", { { "t", T(os.clock()) }, { "raw", safe_fmt("%.4f", cache.raw), cache.raw },
            { "chara", safe_fmt("%.4f", cache.chara), cache.chara }, { "dmgobj", name_of(info:call("get_DamageObj")) },
            { "layer", info:call("get_CollisionLayer") }, { "em", hex(sdk.to_managed_object(args[2])) } })
        if pt then pt.emhit = pt.emhit + 1 end
    end)
end, nil)

-- ---------- 每帧 ----------
local last_now = os.clock()
local item_ok = true
local perf = { t = os.clock(), n = 0, maxdt = 0 }

local function frame()
    f = f + 1
    local now = os.clock()
    local dt = now - last_now
    last_now = now
    run("CLOCK", function()
        perf.n, perf.maxdt = perf.n + 1, math.max(perf.maxdt, dt)
        if now - perf.t >= 5.0 then
            local tn = 0
            for _ in pairs(tracked) do tn = tn + 1 end
            emit("PERF", { { "t", T(now) }, { "fps", safe_fmt("%.1f", perf.n / (now - perf.t)) },
                { "maxdt", safe_fmt("%.4f", perf.maxdt) }, { "hooks", "-" }, { "lua_ms_avg", nil }, { "lua_ms_max", nil },
                { "tracked", tn }, { "red", red_n }, { "yellow", yellow_n } })
            perf.t, perf.n, perf.maxdt = now, 0, 0
        end
        if dt > 0.1 then
            emit("GAP", { { "t", T(now) }, { "f", f }, { "dt", safe_fmt("%.4f", dt), dt } })
        elseif dt > 0.035 then
            emit("HITCH", { { "t", T(now) }, { "f", f }, { "dt", safe_fmt("%.4f", dt), dt } })
        end
    end)
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local p = pm and pm:call("getMasterPlayer")
    local h = p and p:call("get_Character")
    if not h or (me and h:get_address() ~= me:get_address()) then
        release_all()
        pt_close(now)
        cache.cat, cache.idx = nil, nil
    end
    me = h
    if not me then return end
    me_go_addr = me:call("get_GameObject"):get_address()
    me_handling_addr = me:call("get_WeaponHandling"):get_address()
    run("ACT", function()
        local ctrl = me:call("get_BaseActionController")
        local id = ctrl and ctrl:call("get_CurrentActionID")
        if not id then return end      -- 动作控制器暂时读不到（切场景头几帧）：这一帧不记 ACT
        local act = ctrl:call("get_CurrentAction")
        local cat, idx = id:get_field("_Category"), id:get_field("_Index")
        local raw = act:get_field("_RawTotalElapsedSecond")
        local chara = act:call("get_CharaElapsedSecond")
        local name = act:get_type_definition():get_name()
        if cat ~= cache.cat or idx ~= cache.idx then
            emit("ACT", { { "t", T(now) }, { "f", f }, { "from", safe_fmt("%s_%s", cache.cat, cache.idx) },
                { "to", safe_fmt("%s_%s", cat, idx) }, { "from_name", cache.name }, { "to_name", name },
                { "raw_prev", safe_fmt("%.4f", cache.raw), cache.raw }, { "raw_new", safe_fmt("%.4f", raw), raw },
                { "chara_new", safe_fmt("%.4f", chara), chara } })
            local in_family = cat == 2 and idx >= 23 and idx <= 29
            if pt and not in_family then pt_close(now) end
            if cat == 2 and (idx == 23 or idx == 24) then
                pt_close(now)
                pt_id = pt_id + 1
                pt = { id = pt_id, t_obs = now, raw0 = raw, t_start = now - raw,
                    from = safe_fmt("%s_%s", cache.cat, cache.idx), blade = 0, body = 0, emhit = 0, dmg = 0 }
                run("POSE", function()
                    local axis = me:call("get_GameObject"):call("get_Transform"):call("get_AxisZ")
                    pt.fx, pt.fz = axis.x, axis.z
                end)
            end
            if pt and cat == 2 and idx >= 25 and idx <= 27 and not pt.hit_idx then
                pt.hit_idx = idx
                pt.hit_t = now - pt.t_start
            end
        end
        if pt and now - pt.t_start > 4.0 then pt_close(now) end
        cache.cat, cache.idx, cache.raw, cache.chara, cache.name = cat, idx, raw, chara, name
    end)
    -- SIG（可选）：抵消动作族里读动画层
    if cache.cat == 2 and cache.idx and cache.idx >= 21 and cache.idx <= 29 then
        run("SIG", function()
            local motion = me:call("get_GameObject"):call("getComponent(System.Type)", T_MOTION)
            local layer = motion:call("getLayer(System.UInt32)", 0)
            emit("ANIM", { { "t", T(now) }, { "raw", safe_fmt("%.4f", cache.raw), cache.raw },
                { "frame", safe_fmt("%.2f", layer:call("get_Frame")) }, { "speed", safe_fmt("%.2f", layer:call("get_Speed")) },
                { "motion", layer:call("get_MotionID") } }, true)
        end)
    end
    -- SER★：逐条读，读不了退回 closest 并标黄（P05）
    run("SER", function()
        local charge = cache.cat == 2 and (cache.idx == 21 or cache.idx == 22)
        for key, tr in pairs(tracked) do
            local r = tr.obj
            local fin = r:call("get_IsAttackFinished")
            if fin or now - tr.t_msg >= 8.0 then
                ep_close(tr, fin and "fin" or "stale", now)
                pcall(r.release, r)
                tracked[key] = nil
            else
                local ents = {}
                if item_ok then
                    local ok, err = pcall(function()
                        local list = r:call("get_DetectedDataList")
                        for i = 0, list:call("get_Count") - 1 do ents[#ents + 1] = list:call("get_Item(System.Int32)", i) end
                    end)
                    if not ok then
                        item_ok = false
                        ents = {}
                        emit("ERR", { { "mod", "SER_ITEM" }, { "level", "yellow" }, { "msg", tostring(err):sub(1, 80) } })
                    end
                end
                if not item_ok then ents = { r:call("getClosestDetectedData") } end
                for _, d in ipairs(ents) do
                    emit("SER", { { "t", T(now) }, { "f", f }, { "obj", hex(r) }, { "ent", hex(d) }, { "type", d:call("get_ResultType") },
                        { "hs", safe_fmt("%.2f", d:call("get_HitStartRemainFrame")), d:call("get_HitStartRemainFrame") },
                        { "he", safe_fmt("%.2f", d:call("get_HitEndRemainFrame")), d:call("get_HitEndRemainFrame") },
                        { "charge", charge } }, true)
                end
            end
        end
    end)
    local busy = cache.cat == 2 and cache.idx and cache.idx >= 21 and cache.idx <= 29
    if not busy and not pt and next(tracked) == nil and now - last_flush >= 60 then run("JSON", flush) end
end

re.on_pre_application_entry("UpdateBehavior", function()
    local ok, err = pcall(frame)
    if not ok then mod_error("CLOCK", err) end
end)

re.on_frame(function()
    local stage = pt and "放刀中" or "等待"
    local ok = pcall(draw.text, safe_fmt("APCal 自检 OK 错误 %s/%s | %s", red_n, yellow_n, stage), 20, 20, 0xFFFFFFFF)
    if not ok then
        if imgui.begin_window("APCal##APCal_hud", true, 0) then
            imgui.text("APCal")
            imgui.end_window()
        end
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("APCal 测量探针##APCal") then return end
    imgui.text(safe_fmt("错误 红 %s / 黄 %s", red_n, yellow_n))
    if imgui.button("写出数据##APCal_dump") then run("JSON", flush) end
    imgui.tree_pop()
end)

re.on_script_reset(function()
    release_all()
    pt_close(os.clock())
    run("JSON", flush)
end)
