-- AutoParryPredictProbe：测量怪物攻击预告的准确度（只记录，不改任何东西）
--
-- 【作废，不要部署】第 119 行用 %d 格式化 HitStartRemainFrame（System.Single，几乎总带小数），
-- Lua 5.4 会抛错，导致每条危险预告都被记成 FP+FN；误差的定义也对放刀决策没有意义。
-- 由 probes/AutoParryCalib.lua 取代，设计见 docs/autoparry/PLAN.md。
--
-- 目的：重做「预判放刀」之前，先量清楚游戏内置的攻击预告够不够用。
-- 预告来源（v1.3 已验证）：怪物换动作时给主角发 cMsgEmAttackAreaResult，里面的 app.AttackAreaResult：
--   TargetCharacter / ResultType（SAFE/CAUTION/DANGER）/ getClosestDetectedData().HitStartRemainFrame（1/60 秒）
--   训练机关没有预告数据，必须拿真怪测。
-- 统计（只看「打我的」预告）：
--   TP  危险预告 + 预测时刻附近真的挨打
--   FP  危险预告，但到预测时刻过后也没挨打（闪开了 / 打偏了）
--   FN  挨打了，但当时没有任何危险预告
--   err 实际命中时刻 - 预测命中时刻（秒；按最后一次读到的危险剩余帧算）
--   DOWN 危险预告在命中前被降级（不再是 DANGER），用来决定要不要保留 v1.3 的「粘住」
-- 用法：正常打真怪几分钟，站桩挨打、翻滚躲开都可以；菜单里看汇总，日志里看每一条。

local TAG = "[APPredict] "
local HunterCharacter = sdk.find_type_definition("app.HunterCharacter")
local MasterEntity = sdk.find_type_definition("app.cMasterPlayerControllerEntity")
local RESULT = sdk.find_type_definition("app.AttackAreaResult.RESULT_TYPE")
local RT_DANGER = RESULT:get_field("DANGER"):get_data(nil)
local T_CharacterBase = sdk.typeof("app.CharacterBase")

local MATCH_WINDOW = 0.35   -- 挨打时刻离预测命中时刻多近算「对上了」（秒）
local FP_GRACE = 0.5        -- 预测命中时刻过后这么久还没挨打，算误报（秒）
local MAX_AGE = 6.0         -- 预告最多跟踪多久（秒）
local HIT_DEDUP = 0.25      -- 一招多个碰撞体同时命中，这段时间内只算一次（秒）

local warnings = {}         -- [地址] = { obj, t0, act, danger, pred_t, first_lead, downgraded, hit, em }
local stats = { tp = 0, fp = 0, fn = 0, down = 0, err_sum = 0, err_abs_max = 0, warn = 0 }
local events = {}
local last_hit_t = -10

local function push(text)
    table.insert(events, 1, text)
    if #events > 30 then table.remove(events) end
    log.info(TAG .. text)
end

local function master_hunter()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local p = pm and pm:call("getMasterPlayer")
    return p and p:call("get_Character")
end

local function go_name(go) return go and go:call("get_Name") or "-" end

local function drop(key, w)
    pcall(function() w.obj:release() end)
    warnings[key] = nil
end

-- 预告结束时结算：曾是危险、没挨打 → 误报
local function finish(key, w, why)
    if w.danger and not w.hit then
        stats.fp = stats.fp + 1
        push(string.format("FP  %s act=%s lead=%.2fs (%s)", w.em, w.act_text or "?", w.first_lead or -1, why))
    end
    drop(key, w)
end

-- 收到预告：记下对象（怪物那边的，跨帧持有要 add_ref）
sdk.hook(MasterEntity:get_method("receiveGameMessage(ace.cGameMessage)"), function(args)
    pcall(function()
        local msg = sdk.to_managed_object(args[3])
        if not msg or msg:get_type_definition():get_full_name() ~= "app.game_message.cMsgEmAttackAreaResult" then return end
        local r = msg:call("get_AttackAreaResult")
        if not r then return end
        local key = r:get_address()
        if warnings[key] then return end
        r:add_ref()
        warnings[key] = { obj = r, t0 = os.clock() }
    end)
end, nil)

-- 每帧：更新每条「打我的」预告
re.on_pre_application_entry("UpdateBehavior", function()
    local ok, err = pcall(function()
        local hunter = master_hunter()
        if not hunter then
            for key, w in pairs(warnings) do drop(key, w) end
            return
        end
        local me = hunter:get_address()
        local now = os.clock()
        for key, w in pairs(warnings) do
            local ok2, res = pcall(function()
                local r = w.obj
                if now - w.t0 > MAX_AGE then return "age" end
                if r:call("get_IsAttackFinished") then return "finished" end
                local target = r:call("get_TargetCharacter")
                if not target or target:get_address() ~= me then return nil end

                -- 怪物换了动作（预告对象被复用）：上一招结算掉，从头跟踪
                local kid = r:call("get_KeepActionID")
                local act = kid:get_field("_Category") * 100000 + kid:get_field("_Index")
                if w.act and w.act ~= act then
                    if w.danger and not w.hit then
                        stats.fp = stats.fp + 1
                        push(string.format("FP  %s act=%s lead=%.2fs (action changed)", w.em, w.act_text, w.first_lead or -1))
                    end
                    w.danger, w.pred_t, w.first_lead, w.downgraded, w.hit = nil, nil, nil, nil, nil
                end
                if w.act ~= act then
                    w.act = act
                    w.act_text = string.format("(%d,%d)", kid:get_field("_Category"), kid:get_field("_Index"))
                    w.em = string.format("em%d#%d", r:call("get_EmID"), r:call("get_EmSystemIndex"))
                    stats.warn = stats.warn + 1
                end

                local is_danger = r:call("get_ResultType") == RT_DANGER
                local remain = nil
                if is_danger then
                    local dd = r:call("getClosestDetectedData")
                    remain = dd and dd:call("get_HitStartRemainFrame")
                end
                if is_danger and remain and remain >= 0 then
                    if not w.danger then
                        w.danger = true
                        w.first_lead = remain / 60
                        push(string.format("DANGER %s act=%s remain=%d (%.2fs)", w.em, w.act_text, remain, remain / 60))
                    end
                    w.pred_t = now + remain / 60
                elseif w.danger and not w.hit and not w.downgraded and w.pred_t and now < w.pred_t then
                    w.downgraded = true
                    stats.down = stats.down + 1
                    push(string.format("DOWN %s act=%s %.2fs before predicted hit", w.em, w.act_text, w.pred_t - now))
                end
                -- 预测时刻过了很久还没挨打 → 误报
                if w.danger and not w.hit and w.pred_t and now > w.pred_t + FP_GRACE then
                    stats.fp = stats.fp + 1
                    push(string.format("FP  %s act=%s lead=%.2fs (no hit %.1fs after predicted)", w.em, w.act_text, w.first_lead or -1, FP_GRACE))
                    w.hit = true   -- 记过了，不再重复计
                end
                return nil
            end)
            if not ok2 then finish(key, w, "error: " .. tostring(res))
            elseif res then finish(key, w, res) end
        end
    end)
    if not ok then log.warn(TAG .. "frame err: " .. tostring(err)) end
end)

-- 挨打：找时间对得上的危险预告
sdk.hook(HunterCharacter:get_method("evHit_DamagePreProcess(app.HitInfo)"), function(args)
    pcall(function()
        local hunter = sdk.to_managed_object(args[2])
        if not hunter:call("get_IsMaster") then return end
        local info = sdk.to_managed_object(args[3])
        local owner = info:call("get_AttackOwner")
        local c = owner and owner:call("getComponent(System.Type)", T_CharacterBase)
        if not (c and c:get_type_definition():is_a("app.EnemyCharacter")) then return end
        local now = os.clock()
        if now - last_hit_t < HIT_DEDUP then return end
        last_hit_t = now

        local best, best_err = nil, nil
        for _, w in pairs(warnings) do
            if w.danger and w.pred_t then
                local e = now - w.pred_t
                if math.abs(e) <= MATCH_WINDOW and (not best_err or math.abs(e) < math.abs(best_err)) then
                    best, best_err = w, e
                end
            end
        end
        if best and not best.hit then
            best.hit = true
            stats.tp = stats.tp + 1
            stats.err_sum = stats.err_sum + best_err
            stats.err_abs_max = math.max(stats.err_abs_max, math.abs(best_err))
            push(string.format("TP  %s act=%s err=%+.3fs lead=%.2fs%s", best.em, best.act_text, best_err,
                best.first_lead or -1, best.downgraded and " (was downgraded)" or ""))
        elseif not best then
            stats.fn = stats.fn + 1
            push(string.format("FN  hit by %s with no matching danger warning", go_name(owner)))
        end
    end)
end, nil)

re.on_script_reset(function()
    for key, w in pairs(warnings) do drop(key, w) end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("攻击预告准确度 (probe)##APPredict") then return end
    local n = stats.tp + stats.fp + stats.fn
    imgui.text(string.format("对上 TP %d  误报 FP %d  漏报 FN %d  （共 %d）", stats.tp, stats.fp, stats.fn, n))
    imgui.text(string.format("降级 %d  平均误差 %+.3f 秒  最大误差 %.3f 秒", stats.down,
        stats.tp > 0 and stats.err_sum / stats.tp or 0, stats.err_abs_max))
    if imgui.button("清零##APPredict_clear") then
        stats = { tp = 0, fp = 0, fn = 0, down = 0, err_sum = 0, err_abs_max = 0, warn = 0 }
        events = {}
    end
    for _, e in ipairs(events) do imgui.text(e) end
    imgui.tree_pop()
end)

log.info(TAG .. "loaded")
