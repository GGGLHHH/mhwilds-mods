-- AutoGuardWarnProbe：验证游戏的「怪物攻击预告」准不准（只记录，不改任何东西）
--
-- 游戏有一套给 NPC 支援猎人 AI 用的预告系统：怪物出招前，把这一招的攻击范围和时机
-- 发给猎人，存在 HunterCharacter.get_AttackAreaResult()（mcHunterAttackAreaResultHolder）
-- 的 _AttackAreaResultList 里。每条 app.AttackAreaResult：
--   TargetCharacter        这一招瞄准谁
--   ResultType             SAFE / CAUTION / DANGER（会不会打中目标）
--   getClosestDetectedData().HitStartRemainFrame / HitEndRemainFrame
--                          距离攻击判定开始 / 结束还剩多少帧
-- 要回答：
--   1. 预告最早提前多少帧出现？HitStartRemainFrame 是不是在每帧倒数？
--   2. 拿「预告说还剩 N 帧」对比「实际过了几帧才被打中（DMG）/ 判定激活（ATK+）」，准不准？
--   3. 打得中的招 DANGER、打不中的招 SAFE/CAUTION，分得清吗？
-- 每条预告从出现到消失，结束时写一行日志（带整条倒数曲线）。

local TAG = "[AGWarn] "
local HunterCharacter = sdk.find_type_definition("app.HunterCharacter")
local ColliderSwitcher = sdk.find_type_definition("app.ColliderSwitcher")
local RESULT_TYPE = sdk.find_type_definition("app.AttackAreaResult.RESULT_TYPE")
local T_CharacterBase = sdk.typeof("app.CharacterBase")

local RT_NAME = {}
for _, n in ipairs({ "SAFE", "CAUTION", "DANGER" }) do RT_NAME[RESULT_TYPE:get_field(n):get_data(nil)] = n:sub(1, 1) end  -- S / C / D

local frame = 0
local tracked = {}    -- [地址] = { id, first_frame, em, target_me, series = { "f:类型:剩余帧" ... } }
local next_id = 1
local events = {}

local function push(text)
    local line = string.format("f%d %s", frame, text)
    table.insert(events, 1, line)
    if #events > 25 then table.remove(events) end
    log.info(TAG .. line)
end

local function master_hunter()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local p = pm and pm:call("getMasterPlayer")
    return p and p:call("get_Character")
end

local function enemy_name(go)
    if not go then return nil end
    local c = go:call("getComponent(System.Type)", T_CharacterBase)
    if c and c:get_type_definition():is_a("app.EnemyCharacter") then return go:call("get_Name") end
    return nil
end

local function finish(t)
    push(string.format("WARN#%d end  em=%s targetMe=%s firstSeen=f%d frames=%d msgs=%d | %s",
        t.id, t.em, tostring(t.target_me), t.first_frame, frame - t.first_frame, t.msgs, table.concat(t.series, " ")))
end

-- 预告来源：主玩家收到的 cMsgEmAttackAreaResult 消息。
-- （猎人身上的 mcHunterAttackAreaResultHolder 对玩家是未激活的：_IsDestroy=True、列表恒为空，
--   所以不能读它，只能从消息里拿。）
-- 消息里的 AttackAreaResult 是怪物那边的对象，要跨帧持有：add_ref 防止被回收，停止追踪时 release。
local MasterEntity = sdk.find_type_definition("app.cMasterPlayerControllerEntity")
local TRACK_MAX_FRAMES = 300   -- 最多追踪 300 帧（约 3~5 秒），防止对象一直不结束

sdk.hook(MasterEntity:get_method("receiveGameMessage(ace.cGameMessage)"), function(args)
    pcall(function()
        local msg = sdk.to_managed_object(args[3])
        if not msg or msg:get_type_definition():get_full_name() ~= "app.game_message.cMsgEmAttackAreaResult" then return end
        local r = msg:call("get_AttackAreaResult")
        if not r then return end

        -- 收到消息的这一刻就把内容读出来：实测下一帧再读，对象已经被重置（SAFE + 已结束 + 无数据），
        -- 说明怪物那边在复用这个对象
        local now_text = "?"
        pcall(function()
            local list = r:call("get_DetectedDataList")
            local n = list and list:call("get_Count") or -1
            local dd = r:call("getClosestDetectedData")
            local area = r:call("get_MergedAreaData")
            local keep = r:call("get_KeepActionID")
            now_text = string.format("type=%s detected=%d remain=%.0f-%.0f area=%.0f-%.0f keepAct=(%d,%d) fin=%s",
                RT_NAME[r:call("get_ResultType")] or "?", n,
                dd and dd:call("get_HitStartRemainFrame") or -1, dd and dd:call("get_HitEndRemainFrame") or -1,
                area and area:get_field("AttackStartFrame") or -1, area and area:get_field("AttackEndFrame") or -1,
                keep:get_field("_Category"), keep:get_field("_Index"),
                tostring(r:call("get_IsAttackFinished")))
        end)
        push("MSG " .. now_text)

        local key = r:get_address()
        local t = tracked[key]
        if t then
            t.msgs = t.msgs + 1        -- 同一个预告对象又发了一次消息（刷新）
            table.insert(t.series, string.format("%d:MSG", frame - t.first_frame))
            return
        end
        pcall(function() r:add_ref() end)
        local hunter = master_hunter()
        local target = r:call("get_TargetCharacter")
        tracked[key] = {
            obj = r, id = next_id, first_frame = frame, series = {}, last = nil, msgs = 1,
            em = tostring(r:call("get_EmID")),
            target_me = hunter ~= nil and target ~= nil and target:get_address() == hunter:get_address(),
        }
        next_id = next_id + 1
    end)
end, nil)

local function stop(key, t)
    finish(t)
    pcall(function() t.obj:release() end)
    tracked[key] = nil
end

-- 每帧：读每个被追踪预告的当前状态，只在变化时记一格
-- 格式：相对帧:类型[F=已打完]:剩余开始帧-剩余结束帧
re.on_pre_application_entry("UpdateBehavior", function()
    frame = frame + 1
    for key, t in pairs(tracked) do
        local ok, err = pcall(function()
            local r = t.obj
            local rt = RT_NAME[r:call("get_ResultType")] or "?"
            local dd = r:call("getClosestDetectedData")
            local s = dd and dd:call("get_HitStartRemainFrame") or -1
            local e = dd and dd:call("get_HitEndRemainFrame") or -1
            local finished = r:call("get_IsAttackFinished")
            local cur = string.format("%s%s:%.0f-%.0f", rt, finished and "F" or "", s, e)
            if cur ~= t.last then
                table.insert(t.series, string.format("%d:%s", frame - t.first_frame, cur))
                t.last = cur
            end
            if finished or frame - t.first_frame > TRACK_MAX_FRAMES then stop(key, t) end
        end)
        if not ok then
            table.insert(t.series, "ERR:" .. tostring(err))
            stop(key, t)
        end
    end
end)

-- 实际事件：怪物攻击判定激活
sdk.hook(ColliderSwitcher:get_method("activateAttack(System.Boolean, System.UInt32, System.UInt32, System.Nullable`1<System.Boolean>, app.Hit.HIT_ID_GROUP, System.Nullable`1<System.Single>, System.Nullable`1<System.Single>)"),
    function(args)
        if (sdk.to_int64(args[3]) & 1) == 0 then return end
        pcall(function()
            local switcher = sdk.to_managed_object(args[2])
            local name = enemy_name(switcher:get_field("_HitController"):call("get_Owner"))
            if name then push(string.format("ATK+ req=%d", sdk.to_int64(args[5]) & 0xFFFFFFFF)) end
        end)
    end, nil)

-- 实际事件：玩家被怪物打中
sdk.hook(HunterCharacter:get_method("evHit_DamagePreProcess(app.HitInfo)"), function(args)
    pcall(function()
        local hunter = sdk.to_managed_object(args[2])
        if not hunter:call("get_IsMaster") then return end
        if enemy_name(sdk.to_managed_object(args[3]):call("get_AttackOwner")) then push("DMG") end
    end)
end, nil)

re.on_draw_ui(function()
    if not imgui.tree_node("AutoGuardWarnProbe") then return end
    local n = 0
    for _ in pairs(tracked) do n = n + 1 end
    imgui.text("Active warnings: " .. n)
    for _, e in ipairs(events) do imgui.text(e:sub(1, 160)) end
    imgui.tree_pop()
end)

log.info(TAG .. "loaded")
